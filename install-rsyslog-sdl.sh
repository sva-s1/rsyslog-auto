#!/usr/bin/env bash
set -Eeuo pipefail

# Deterministic rsyslog -> SDL HEC setup for mixed Cisco/Meraki-ish syslog on one port.
# - Removes OpenTelemetry Collector artifacts/packages if present.
# - Refuses to proceed if TCP/UDP 5514 is already owned by a non-rsyslog process.
# - Enables rsyslog UDP+TCP 5514 listeners (comment TCP input in generated config if not needed).
# - Routes Catalyst, Meraki-style, and unknown catch-all to local files + SDL HEC.
# - Reads credentials from ./.env if present; otherwise prompts for HEC write token/endpoint.
# - SDL read token/endpoint are optional; if present, the installer validates test messages via /api/query.

PORT="${SDL_SYSLOG_PORT:-5514}"
CONF="/etc/rsyslog.d/60-sdl-hec.conf"
ENV_FILE="/etc/rsyslog.d/sdl-hec.env"
HELPER="/usr/local/bin/rsyslog-sdl-hec.py"
LOG_DIR="/var/log/sdl-rsyslog"
STATE_DIR="/var/spool/rsyslog/sdl-hec"
LOGROTATE="/etc/logrotate.d/sdl-rsyslog"
SOURCE_ENV="./.env"
SYSCTL_FILE="/etc/sysctl.d/60-sdl-rsyslog.conf"
UDP_RCVBUF="${SDL_UDP_RCVBUF:-8m}"               # imudp SO_RCVBUF request
UDP_RMEM_MAX="${SDL_UDP_RMEM_MAX:-16777216}"     # 16 MiB host cap the above needs
PYBIN="${SDL_PYTHON:-/usr/bin/python3}"          # absolute interpreter for the helper

log() { printf '[%s] %s\n' "$(date -Is)" "$*"; }
fail() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
need_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || fail "run as root"; }

write_env_template() {
  # Drop a fill-in-the-blanks .env next to where the installer was run so a
  # user who curl|bash'd before creating one is told exactly what to do.
  [[ -e "$SOURCE_ENV" ]] && return 0
  umask 077
  cat > "$SOURCE_ENV" <<'EOF'
# SDL credentials for install-rsyslog-sdl.sh.
# Fill in the two required values below, then re-run the same install command.
SDL_HEC_ENDPOINT=https://YOUR-SDL-HOST/services/collector/event
SDL_HEC_TOKEN=PASTE-YOUR-HEC-WRITE-TOKEN-HERE
# Optional: enables post-install upstream validation. Leave blank to skip.
SDL_READ_ENDPOINT=
SDL_READ_TOKEN=
EOF
}

load_or_prompt_env() {
  # Credential precedence, so the public one-liner works every way it
  # might be run:
  #   1. exported env vars  ->  curl ... | sudo SDL_HEC_TOKEN=x SDL_HEC_ENDPOINT=y bash
  #   2. ./.env in CWD      ->  drop a .env, then curl ... | sudo bash
  #   3. prior install      ->  re-run with no input at all
  #   4. interactive prompt ->  answer one masked token prompt
  #   5. none + no TTY      ->  write a .env template and tell them what to fill
  if [[ -n "${SDL_HEC_ENDPOINT:-}" && -n "${SDL_HEC_TOKEN:-}" ]]; then
    log "Using SDL credentials from the environment (no prompts)"
  elif [[ -f "$SOURCE_ENV" ]]; then
    log "Loading credentials from $SOURCE_ENV (no prompts)"
    set -a; . "$SOURCE_ENV"; set +a
  elif [[ -f "$ENV_FILE" ]]; then
    log "Reusing credentials from previous install ($ENV_FILE)"
    set -a; . "$ENV_FILE"; set +a
  elif (exec </dev/tty) 2>/dev/null; then
    # /dev/tty can exist as a node yet not be openable (headless curl|bash over
    # a non-interactive ssh). Test by actually opening it, not with -e.
    log "No credentials found; prompting (paste the values from SDL)"
    read -r -p "SDL HEC endpoint (e.g. https://.../services/collector/event): " SDL_HEC_ENDPOINT </dev/tty
    read -r -s -p "SDL HEC write token: " SDL_HEC_TOKEN </dev/tty; printf '\n' >/dev/tty
    read -r -p "SDL read endpoint or /api/query URL (optional, Enter to skip): " SDL_READ_ENDPOINT </dev/tty || true
    read -r -s -p "SDL read token (optional, Enter to skip): " SDL_READ_TOKEN </dev/tty || true; printf '\n' >/dev/tty
  else
    write_env_template
    fail "No SDL credentials supplied. Wrote a template to $(pwd)/$SOURCE_ENV — open it, set SDL_HEC_TOKEN and SDL_HEC_ENDPOINT, then re-run the same command."
  fi

  # Reject empty or untouched-template values with an actionable message.
  case "${SDL_HEC_ENDPOINT:-}" in ''|*YOUR-SDL-HOST*) fail "SDL_HEC_ENDPOINT is not set (still the placeholder?). Edit $SOURCE_ENV and re-run." ;; esac
  case "${SDL_HEC_TOKEN:-}" in ''|*PASTE-YOUR-HEC*) fail "SDL_HEC_TOKEN is not set (still the placeholder?). Edit $SOURCE_ENV and re-run." ;; esac
  if [[ -z "${SDL_READ_ENDPOINT:-}" || -z "${SDL_READ_TOKEN:-}" ]]; then
    log "WARNING: SDL_READ_ENDPOINT/SDL_READ_TOKEN missing; install will skip SDL API validation and only validate local files."
  fi
}

remove_otel() {
  log "Removing OpenTelemetry Collector if present"
  systemctl stop otelcol-contrib.service otelcol.service 2>/dev/null || true
  systemctl disable otelcol-contrib.service otelcol.service 2>/dev/null || true
  pkill -x otelcol-contrib 2>/dev/null || true
  pkill -x otelcol 2>/dev/null || true

  if command -v apt-get >/dev/null 2>&1; then
    for pkg in otelcol-contrib otelcol; do
      if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed'; then
        local unit="${pkg}.service"
        # Some prior cleanup may have removed the unit file before package
        # purge. The upstream prerm hard-fails if systemctl cannot stop/disable
        # the unit, so create a temporary inert unit to let dpkg finish cleanly.
        if ! systemctl list-unit-files "$unit" --no-legend 2>/dev/null | grep -q "$unit"; then
          cat > "/etc/systemd/system/$unit" <<UNIT
[Unit]
Description=Temporary inert unit for $pkg purge
[Service]
Type=oneshot
ExecStart=/bin/true
RemainAfterExit=yes
UNIT
          systemctl daemon-reload 2>/dev/null || true
        fi
        DEBIAN_FRONTEND=noninteractive apt-get purge -y "$pkg" >/dev/null
      fi
    done
    DEBIAN_FRONTEND=noninteractive apt-get autoremove -y >/dev/null 2>&1 || true
  fi

  rm -rf \
    /etc/otelcol /etc/otelcol-contrib /etc/default/otelcol /etc/default/otelcol-contrib \
    /etc/systemd/system/otelcol.service /etc/systemd/system/otelcol-contrib.service \
    /usr/lib/systemd/system/otelcol.service /usr/lib/systemd/system/otelcol-contrib.service \
    /lib/systemd/system/otelcol.service /lib/systemd/system/otelcol-contrib.service \
    /var/lib/otelcol /var/lib/otelcol-contrib /var/log/otelcol /var/log/otelcol-contrib \
    /opt/otelcol /opt/otelcol-contrib
  systemctl daemon-reload 2>/dev/null || true
}

install_packages() {
  log "Installing/enabling rsyslog prerequisites"
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update >/dev/null
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends rsyslog ca-certificates python3 netcat-openbsd curl >/dev/null
  fi
  command -v rsyslogd >/dev/null 2>&1 || fail "rsyslogd not found after install"
}

port_users() {
  local proto="$1"
  if [[ "$proto" == "tcp" ]]; then
    ss -H -ltnp "( sport = :$PORT )" 2>/dev/null || true
  else
    ss -H -lunp "( sport = :$PORT )" 2>/dev/null || true
  fi
}

check_ports_available_or_rsyslog() {
  log "Checking TCP/UDP $PORT ownership before configuring rsyslog"
  local offenders=""
  local lines line
  for proto in tcp udp; do
    lines="$(port_users "$proto")"
    [[ -z "$lines" ]] && continue
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      if [[ "$line" == *"rsyslogd"* ]]; then
        log "$proto/$PORT currently owned by rsyslogd; stopping for deterministic reconfigure"
        systemctl stop rsyslog 2>/dev/null || true
      else
        offenders+=$'\n'"$proto/$PORT: $line"
      fi
    done <<< "$lines"
  done
  if [[ -n "$offenders" ]]; then
    fail "Port $PORT is already in use by a non-rsyslog app:$offenders"
  fi
}

write_env() {
  log "Writing $ENV_FILE"
  install -d -m 0755 /etc/rsyslog.d
  umask 077
  cat > "$ENV_FILE" <<EOF
SDL_HEC_ENDPOINT=${SDL_HEC_ENDPOINT}
SDL_HEC_TOKEN=${SDL_HEC_TOKEN}
SDL_READ_ENDPOINT=${SDL_READ_ENDPOINT:-}
SDL_READ_TOKEN=${SDL_READ_TOKEN:-}
EOF
  chown root:adm "$ENV_FILE" 2>/dev/null || true
  chmod 0640 "$ENV_FILE"
}

write_helper() {
  log "Writing HEC helper $HELPER"
  cat > "$HELPER" <<'PY'
#!/usr/bin/env python3
import json, os, re, socket, sys, time, urllib.request
from pathlib import Path

ENV_FILE = Path('/etc/rsyslog.d/sdl-hec.env')
LOG_FILE = Path('/var/log/sdl-rsyslog/hec-forwarder.log')
LOG_FILE.parent.mkdir(parents=True, exist_ok=True)

def log(msg):
    with LOG_FILE.open('a') as f:
        f.write(time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()) + ' ' + msg + '\n')

def load_env(path):
    env = {}
    if path.exists():
        for line in path.read_text().splitlines():
            line=line.strip()
            if not line or line.startswith('#') or '=' not in line: continue
            k,v=line.split('=',1)
            env[k]=v
    return env

source_type = sys.argv[1] if len(sys.argv) > 1 else 'unknown'
sourcetype = sys.argv[2] if len(sys.argv) > 2 else 'lab_unknown'
hec_source = sys.argv[3] if len(sys.argv) > 3 else f'/var/log/sdl-rsyslog/{source_type}.log'
collector = socket.getfqdn() or socket.gethostname()

def primary_lan_ip():
    # Resolve the collector's own routable LAN IP without shelling out. A UDP
    # connect() sets the local endpoint via the kernel routing table but sends
    # nothing, so it returns the real LAN IP even on a box whose hostname maps
    # to loopback. This is what populates metadata.log.collector_ip; it is the
    # collector's identity, distinct from the per-message sender (fromhost-ip).
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            s.connect(('10.255.255.255', 1))
            return s.getsockname()[0]
        finally:
            s.close()
    except Exception:
        return ''

ROUTE_FIELDS = {
    'catalyst': {
        'dataSource.name': 'Cisco Catalyst',
        'dataSource.vendor': 'Cisco',
        'dataSource.category': 'security',
        'metadata.product.name': 'Catalyst',
        'metadata.product.vendor_name': 'Cisco',
    },
    'meraki': {
        'dataSource.name': 'Cisco Meraki',
        'dataSource.vendor': 'Cisco',
        'dataSource.category': 'security',
        'metadata.product.name': 'Meraki',
        'metadata.product.vendor_name': 'Cisco',
    },
}

def event_time_from(message, timereported):
    # Prefer an explicit epoch.nanoseconds value embedded in Meraki-style
    # payloads, e.g. "1782259132.111222333 <host> events type=...".
    m = re.match(r'^\s*(?:<\d+>1\s+)?(\d{10}(?:\.\d{1,9})?)\s+\S+\s+events\s+type=', message)
    if m:
        try:
            return float(m.group(1))
        except ValueError:
            pass
    # Otherwise use rsyslog's timereported, which preserves the syslog message
    # timestamp when it can parse one and falls back to receive time otherwise.
    try:
        ts = float(timereported)
        if ts > 0:
            return ts
    except Exception:
        pass
    return None

env = load_env(ENV_FILE)
# Set SDL_HEC_DRYRUN=1 to print each HEC payload to stdout instead of POSTing.
# Used by the local test harness to validate the JSON shape without an endpoint.
DRYRUN = bool(env.get('SDL_HEC_DRYRUN') or os.environ.get('SDL_HEC_DRYRUN'))
endpoint = env.get('SDL_HEC_ENDPOINT') or os.environ.get('SDL_HEC_ENDPOINT')
token = env.get('SDL_HEC_TOKEN') or os.environ.get('SDL_HEC_TOKEN')
if not DRYRUN and (not endpoint or not token):
    log('fatal missing SDL_HEC_ENDPOINT or SDL_HEC_TOKEN')
    sys.exit(2)
# Advertised collector IP. A static SDL_COLLECTOR_IP override always wins
# (pin it for multi-homed hosts). Otherwise the helper re-derives the box's
# primary LAN IP at runtime and re-checks every IP_REFRESH_SECONDS, so a DHCP
# lease change is picked up without restarting rsyslog. Nothing is hardcoded.
IP_OVERRIDE = env.get('SDL_COLLECTOR_IP') or os.environ.get('SDL_COLLECTOR_IP')
IP_REFRESH_SECONDS = 60
_ip_cache = {'ip': '', 'ts': 0.0}

def collector_ip_now():
    if IP_OVERRIDE:
        return IP_OVERRIDE
    now = time.time()
    if not _ip_cache['ip'] or (now - _ip_cache['ts']) > IP_REFRESH_SECONDS:
        ip = primary_lan_ip()
        if ip:
            _ip_cache['ip'], _ip_cache['ts'] = ip, now
    return _ip_cache['ip']

headers = {'Content-Type': 'application/json', 'Authorization': 'Splunk ' + (token or '')}

def post(payload):
    data=json.dumps(payload, separators=(',', ':')).encode()
    if DRYRUN:
        sys.stdout.write(data.decode() + '\n')
        return
    req=urllib.request.Request(endpoint, data=data, headers=headers, method='POST')
    with urllib.request.urlopen(req, timeout=15) as resp:
        body=resp.read().decode(errors='replace')
        if resp.status < 200 or resp.status >= 300:
            raise RuntimeError(f'HTTP {resp.status}: {body[:500]}')
        try:
            j=json.loads(body) if body else {}
            if str(j.get('code', 0)) not in ('0', 'None') and j.get('text') not in (None, 'Success'):
                log('warning HEC response: ' + body[:500])
        except Exception:
            pass

for line in sys.stdin:
    line=line.rstrip('\n')
    if not line: continue
    try:
        # Template format from rsyslog:
        # fromhost-ip<TAB>syslog-hostname<TAB>timereported_epoch<TAB>message
        parts = line.split('\t', 3)
        fromhost = parts[0] if len(parts) > 0 else ''
        sysloghost = parts[1] if len(parts) > 1 else ''
        timereported = parts[2] if len(parts) > 2 else ''
        message = parts[3] if len(parts) > 3 else line
        fields = {
            's1.source_type': source_type,
            'log.file.name': Path(hec_source).name,
            'log.file.path': hec_source,
            'collector.fromhost_ip': fromhost,
            'syslog.hostname': sysloghost,
            'rsyslog.timereported': timereported,
            'metadata.log.collector': 'rsyslog',
        }
        cip = collector_ip_now()
        if cip:
            fields['metadata.log.collector_ip'] = cip
        fields.update(ROUTE_FIELDS.get(source_type, {}))
        payload = {
            'host': collector,
            'source': hec_source,
            'sourcetype': sourcetype,
            'event': message,
            'fields': fields,
        }
        event_time = event_time_from(message, timereported)
        if event_time is not None:
            payload['time'] = event_time
        post(payload)
    except Exception as e:
        log('send_failed ' + repr(e) + ' line=' + line[:1000])
        # Keep running so rsyslog can continue forwarding future events.
PY
  chmod 0755 "$HELPER"
}

write_apparmor_policy() {
  # Ubuntu's rsyslog AppArmor profile blocks arbitrary omprog helpers by
  # default. Add a narrow local include for the HEC helper when AppArmor is
  # active. No-op on systems without AppArmor.
  command -v apparmor_parser >/dev/null 2>&1 || return 0
  [[ -d /etc/apparmor.d/rsyslog.d ]] || return 0
  log "Writing rsyslog AppArmor allowance for HEC helper"
  cat > /etc/apparmor.d/rsyslog.d/sdl-hec <<EOF
  # Allow rsyslog omprog to execute the SDL HEC helper and let that helper
  # read credentials, write its own log, resolve DNS, and connect to HTTPS HEC.
  $HELPER rix,
  /usr/bin/python3 ix,
  /usr/bin/python3.* ix,
  /etc/rsyslog.d/sdl-hec.env r,
  $LOG_DIR/ rw,
  $LOG_DIR/** rwk,
  /etc/ssl/openssl.cnf r,
  /etc/ssl/certs/ r,
  /etc/ssl/certs/** r,
  /usr/lib/python3*/** r,
  /usr/lib/x86_64-linux-gnu/** mr,
  network inet stream,
  network inet6 stream,
EOF
  apparmor_parser -r /etc/apparmor.d/usr.sbin.rsyslogd >/dev/null 2>&1 || true
}

json_escape() {
  python3 -c 'import json,sys; print(json.dumps(sys.argv[1])[1:-1])' "$1"
}

write_rsyslog_config() {
  log "Writing rsyslog config $CONF"
  install -d -o syslog -g adm -m 0750 "$LOG_DIR"
  install -d -o syslog -g adm -m 0750 "$STATE_DIR"
  local collector_host
  collector_host="$(hostname -f 2>/dev/null || hostname)"

  # Run the helper with an absolute interpreter in isolated mode (-I): ignores
  # PYTHONPATH, PYTHON* env, the user site-dir, and cwd on sys.path, and bypasses
  # any pyenv/conda shim on PATH. The helper is stdlib-only, so this is more
  # robust than a venv and needs no extra packages or AppArmor entries.
  local pybin="$PYBIN"
  [[ -x "$pybin" ]] || pybin="$(command -v python3 || echo /usr/bin/python3)"
  local pyrun="$pybin -I $HELPER"
  log "HEC helper will run as: $pyrun <route> <sourcetype> <logfile>"

  cat > "$CONF" <<EOF
# SDL mixed Cisco/Meraki syslog ingest on a single port.
# Managed by install-rsyslog-sdl.sh. Local copies are in $LOG_DIR.

# imudp: 2 receiver threads so a burst on one socket cannot starve the other.
module(load="imudp" threads="2")
module(load="imtcp")
module(load="omprog")

# UDP is required because some source devices can only emit UDP syslog. UDP has no
# delivery ack, so a burst (e.g. a reassociation storm) that overruns the
# kernel socket buffer is dropped silently. rcvbufSize requests a larger
# SO_RCVBUF, but rsyslog does NOT use SO_RCVBUFFORCE, so the kernel caps it at
# net.core.rmem_max. The installer raises that where permitted; inside an
# unprivileged LXC it is owned by the host and must be set there (the installer
# detects this and prints the exact host command). No rate limiting
# (ratelimit.interval default 0) so we never deliberately discard events.
input(type="imudp" port="$PORT" ruleset="sdl_ingest" name="sdl_udp_$PORT" rcvbufSize="$UDP_RCVBUF")

# TCP is enabled for lab/future support. If your sources cannot use TCP or you
# want UDP only, comment out the next line and restart rsyslog.
input(type="imtcp" port="$PORT" ruleset="sdl_ingest" name="sdl_tcp_$PORT")

template(name="sdlLocalLine" type="string" string="%timegenerated% host=$collector_host from=%fromhost-ip% sysloghost=%hostname% timereported=%timereported:::date-rfc3339% msg=%msg%\\n")
template(name="sdlProgLine" type="string" string="%fromhost-ip%\t%hostname%\t%timereported:::date-unixtimestamp%\t%msg%\\n")

ruleset(name="sdl_ingest") {
  # Catalyst IOS/NX-ish body signature: %FACILITY-SEV-MNEMONIC:
  if re_match(msg, "%[A-Z0-9_]+-[0-9]+-[A-Z0-9_]+:") then {
    action(type="omfile" file="$LOG_DIR/catalyst.log" template="sdlLocalLine")
    action(type="omprog" name="sdl_hec_catalyst" binary="$pyrun catalyst cisco_catalyst $LOG_DIR/catalyst.log" template="sdlProgLine")
    stop
  }

  # Meraki-style wireless/AP event body. Keep this intentionally broad:
  # in practice these messages are syslog-ish but not reliably parsed
  # as RFC3164/RFC5424, so body matching is safer than hostname/IP fields.
  if msg contains " events type=" then {
    action(type="omfile" file="$LOG_DIR/meraki.log" template="sdlLocalLine")
    action(type="omprog" name="sdl_hec_meraki" binary="$pyrun meraki cisco_meraki $LOG_DIR/meraki.log" template="sdlProgLine")
    stop
  }

  # Catch-all: still write locally and forward to SDL unknown parser.
  action(type="omfile" file="$LOG_DIR/unknown.log" template="sdlLocalLine")
  action(type="omprog" name="sdl_hec_unknown" binary="$pyrun unknown lab_unknown $LOG_DIR/unknown.log" template="sdlProgLine")
}
EOF
  # The heredoc uses STX placeholders so bash does not expand rsyslog variables.
  perl -0pi -e 's/\x02/\$/g' "$CONF"
}

write_logrotate() {
  log "Writing logrotate policy $LOGROTATE"
  cat > "$LOGROTATE" <<EOF
$LOG_DIR/*.log {
    monthly
    rotate 12
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
    create 0640 syslog adm
}
EOF
}

tune_udp_buffers() {
  # rsyslog imudp uses SO_RCVBUF (not SO_RCVBUFFORCE), so its rcvbufSize is
  # capped by net.core.rmem_max. Persist + apply a larger cap. In an
  # unprivileged LXC this sysctl is owned by the host and read-only here; we try
  # and tolerate failure, then verify_udp_rcvbuf() reports whether it stuck.
  log "Requesting net.core.rmem_max=$UDP_RMEM_MAX (for imudp rcvbufSize=$UDP_RCVBUF)"
  cat > "$SYSCTL_FILE" <<EOF
# Managed by install-rsyslog-sdl.sh. rsyslog imudp uses SO_RCVBUF, capped by
# net.core.rmem_max; raise it so a UDP burst is not dropped at the socket.
net.core.rmem_max = $UDP_RMEM_MAX
EOF
  if ! sysctl -q -w net.core.rmem_max="$UDP_RMEM_MAX" 2>/dev/null; then
    log "NOTE: net.core.rmem_max is not writable here (unprivileged LXC; the host owns it)."
    log "      Larger UDP buffers need this ONE command on the LXC HOST, then no further action:"
    log "        sysctl -w net.core.rmem_max=$UDP_RMEM_MAX && echo net.core.rmem_max=$UDP_RMEM_MAX >/etc/sysctl.d/60-sdl-rsyslog.conf"
  fi
}

verify_udp_rcvbuf() {
  # Read the actual SO_RCVBUF the kernel granted the live UDP socket and say
  # plainly whether tuning took effect. Never fail the install on this.
  local rb
  rb="$(ss -lunpm "( sport = :$PORT )" 2>/dev/null | grep -om1 'rb[0-9]\+' | tr -dc 0-9)"
  [[ -n "$rb" ]] || return 0
  if (( rb < 1048576 )); then
    log "WARNING: UDP receive buffer is only ${rb} bytes (kernel default); rcvbufSize=$UDP_RCVBUF was clamped."
    log "         Normal in an unprivileged LXC. Set net.core.rmem_max on the HOST (see note above) to enlarge it."
    log "         Acceptable for steady traffic; only matters if a burst exceeds ~${rb} bytes in flight."
  else
    log "UDP receive buffer is ${rb} bytes; imudp buffer tuning is effective."
  fi
}

validate_and_start_rsyslog() {
  log "Validating rsyslog config"
  rsyslogd -N1 -f /etc/rsyslog.conf >/tmp/rsyslog-sdl-validate.log 2>&1 || {
    cat /tmp/rsyslog-sdl-validate.log >&2
    fail "rsyslog config validation failed"
  }
  # Some hosts ship rsyslog disabled or masked (a common lock-down). Normalize
  # the unit before starting: unmask if masked, then enable so it survives
  # reboot, then (re)start.
  local enabled_state
  enabled_state="$(systemctl is-enabled rsyslog 2>/dev/null || true)"
  if [[ "$enabled_state" == "masked" ]]; then
    log "rsyslog unit is masked; unmasking"
    systemctl unmask rsyslog >/dev/null 2>&1 || true
  elif [[ "$enabled_state" != "enabled" ]]; then
    log "rsyslog unit state is '${enabled_state:-unknown}'; enabling for boot"
  fi
  log "Enabling and restarting rsyslog"
  if ! systemctl enable rsyslog >/dev/null 2>&1; then
    # enable can still fail if the unit was masked under an alias; force it.
    systemctl unmask rsyslog >/dev/null 2>&1 || true
    systemctl enable rsyslog >/dev/null 2>&1 || log "WARNING: could not 'systemctl enable rsyslog'; it may not auto-start on reboot"
  fi
  systemctl restart rsyslog
  sleep 2
  systemctl is-active --quiet rsyslog || fail "rsyslog failed to start (check: systemctl status rsyslog)"
  systemctl is-enabled --quiet rsyslog && log "rsyslog is enabled (will start on boot)" || log "NOTE: rsyslog is active but not enabled for boot"
  check_ports_bound
}

check_ports_bound() {
  local tcp udp
  tcp="$(port_users tcp)"
  udp="$(port_users udp)"
  [[ "$tcp" == *"rsyslogd"* ]] || fail "rsyslog is not listening on TCP/$PORT. Output: ${tcp:-none}"
  [[ "$udp" == *"rsyslogd"* ]] || fail "rsyslog is not listening on UDP/$PORT. Output: ${udp:-none}"
  log "rsyslog is listening on TCP/$PORT and UDP/$PORT"
}

write_test_sender() {
  cat > ./send-rsyslog-sdl-test.sh <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
HOST="${1:-127.0.0.1}"
PORT="${2:-5514}"
if command -v uuidgen >/dev/null 2>&1; then
  UUID="$(uuidgen | tr '[:upper:]' '[:lower:]')"
elif [[ -r /proc/sys/kernel/random/uuid ]]; then
  UUID="$(cat /proc/sys/kernel/random/uuid)"
else
  UUID="$(date +%s)-$$-$RANDOM"
fi
STAMP="$(date +%s)"
printf '%s\n' "<134>1 rsysbox SDL_VALIDATION_UUID=${UUID} SDL_VALIDATION_TEST_UNKNOWN unknown-route smoke test" | nc -u -w1 "$HOST" "$PORT"
printf '%s\n' "<134>1 ${STAMP}.111222333 host1 events type=association radio='1' vap='2' client_mac='AA:BB:CC:DD:EE:04' band='5' channel='140' SDL_VALIDATION_UUID=${UUID} SDL_VALIDATION_TEST_MERAKI" | nc -u -w1 "$HOST" "$PORT"
printf '%s\n' "<188>1 61001 host2 Jun 23 23:30:01.000: %DMI-5-AUTH_PASSED: SDL_VALIDATION_UUID=${UUID} SDL_VALIDATION_TEST_CATALYST" | nc -u -w1 "$HOST" "$PORT"
printf '%s\n' "<188>1 61002 host2 Jun 23 23:30:02.000: %DMI-5-AUTH_PASSED: SDL_VALIDATION_UUID=${UUID} SDL_VALIDATION_TEST_TCP_CATALYST" | nc -w2 "$HOST" "$PORT" || true
echo "$UUID"
EOF
  chmod 0755 ./send-rsyslog-sdl-test.sh
}

query_sdl() {
  local uuid="$1"
  [[ -n "${SDL_READ_ENDPOINT:-}" && -n "${SDL_READ_TOKEN:-}" ]] || return 0
  local endpoint="${SDL_READ_ENDPOINT%/}"
  [[ "$endpoint" == */api/query ]] || endpoint="$endpoint/api/query"
  python3 - "$endpoint" "$SDL_READ_TOKEN" "$uuid" <<'PY'
import json, sys, urllib.request, urllib.error, time
endpoint, token, uuid = sys.argv[1:4]
# Search by raw message text UUID and explicitly exclude source=scalyr so the
# validation does not depend on upstream parser fields being present.
filter_expr = f'message contains "{uuid}" source != "scalyr"'
payload = {"token": token, "queryType": "log", "filter": filter_expr, "startTime": "10m", "maxCount": 20, "pageMode": "tail", "priority": "low"}
for attempt in range(1, 7):
    req = urllib.request.Request(endpoint, data=json.dumps(payload).encode(), headers={"Content-Type":"application/json"}, method="POST")
    try:
        raw = urllib.request.urlopen(req, timeout=30).read().decode()
        data = json.loads(raw)
        matches = data.get("matches", [])
        if len(matches) >= 4:
            print(f"SDL validation: filter={filter_expr!r} status={data.get('status')} matches={len(matches)}")
            for m in matches[-10:]:
                attrs = m.get('attributes', {})
                print({k: attrs.get(k) for k in ['host','source','sourcetype','s1.source_type','dataSource.name','dataSource.vendor','metadata.product.name','metadata.product.vendor_name','metadata.log.collector','metadata.log.collector_ip','log.file.name','log.file.path','collector.fromhost_ip','syslog.hostname','rsyslog.timereported'] if attrs.get(k)}, m.get('message','')[:180])
            sys.exit(0)
        print(f"SDL validation attempt {attempt}: matches={len(matches)}; waiting for 4 UUID events")
    except Exception as e:
        print(f"SDL validation attempt {attempt} failed: {e}")
    time.sleep(5)
print("WARNING: SDL validation found no matches; local validation may still have succeeded.")
PY
}

run_smoke_test() {
  log "Sending local smoke-test messages"
  write_test_sender
  local uuid
  uuid="$(./send-rsyslog-sdl-test.sh 127.0.0.1 "$PORT" | tail -1)"
  sleep 5
  grep -q "SDL_VALIDATION_UUID=${uuid}.*SDL_VALIDATION_TEST_CATALYST" "$LOG_DIR/catalyst.log" || fail "Catalyst local smoke test did not reach $LOG_DIR/catalyst.log"
  grep -q "SDL_VALIDATION_UUID=${uuid}.*SDL_VALIDATION_TEST_MERAKI" "$LOG_DIR/meraki.log" || fail "Meraki local smoke test did not reach $LOG_DIR/meraki.log"
  grep -q "SDL_VALIDATION_UUID=${uuid}.*SDL_VALIDATION_TEST_UNKNOWN" "$LOG_DIR/unknown.log" || fail "Unknown local smoke test did not reach $LOG_DIR/unknown.log"
  log "Local smoke test passed with UUID $uuid"
  query_sdl "$uuid" || true
}

main() {
  need_root
  load_or_prompt_env
  remove_otel
  install_packages
  check_ports_available_or_rsyslog
  write_env
  write_helper
  write_apparmor_policy
  write_rsyslog_config
  write_logrotate
  tune_udp_buffers
  validate_and_start_rsyslog
  verify_udp_rcvbuf
  run_smoke_test
  log "DONE. rsyslog SDL ingest is active on TCP/UDP $PORT; local logs: $LOG_DIR"
  log "To test externally: ./send-rsyslog-sdl-test.sh <collector-ip> $PORT"
}

main "$@"
