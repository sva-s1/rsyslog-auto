# rsyslog-auto

One-shot installer that turns a fresh Ubuntu host (bare metal, VM, or LXC) into a
self-contained **rsyslog → HEC** collector for mixed Cisco-ish syslog arriving on
a single port. It removes any prior OpenTelemetry Collector setup, configures
rsyslog, writes local rotated copies, forwards every event to your HEC endpoint,
and validates itself end-to-end — in one run, no editing.

## Quick start

The customer supplies only the **HEC write token** — endpoints default to the
US1 region (`ingest.us1.sentinelone.net` / `xdr.us1.sentinelone.net`).

```bash
# Fully non-interactive:
curl -fsSL https://raw.githubusercontent.com/sva-s1/rsyslog-auto/main/install-rsyslog-sdl.sh \
  | sudo SDL_HEC_TOKEN=<write-token> bash
```

Or drop a `.env` next to where you run it and let the installer read it:

```bash
cd /etc/rsyslog.d
sudo tee .env >/dev/null <<'EOF'
SDL_HEC_TOKEN=<write-token>
# optional — read token enables upstream read-back validation after install:
SDL_READ_TOKEN=
# optional — region if not US1 (e.g. eu1, ap1):
#SDL_REGION=us1
EOF
curl -fsSL https://raw.githubusercontent.com/sva-s1/rsyslog-auto/main/install-rsyslog-sdl.sh | sudo bash
```

If no token is found and there's no terminal to prompt at, the installer writes a
fill-in-the-blanks `.env` template and exits telling you what to set.

## Credential precedence

The only required input is the HEC write token (endpoints are derived from
`SDL_REGION`, default `us1`; set `SDL_HEC_ENDPOINT`/`SDL_READ_ENDPOINT` to
override). The token is resolved in this order, so the one-liner works however
you run it:

1. Exported env var (`SDL_HEC_TOKEN`)
2. `./.env` in the current directory
3. A previous install (`/etc/rsyslog.d/sdl-hec.env`) — re-run with zero input
4. Interactive prompt (one masked token entry)
5. None + headless → writes a template `.env` and exits with instructions

No secrets are baked into the script; it's safe to host publicly.

## What it configures

- **Listeners:** UDP + TCP on port `5514` (override with `SDL_SYSLOG_PORT`). UDP
  is the primary path for devices that can't do TCP.
- **Routing by message body** (not hostname/IP, which Cisco-ish gear doesn't set
  reliably):
  - Catalyst IOS/NX signature `%FACILITY-SEV-MNEMONIC:` → `cisco_catalyst`
  - Wireless/AP bodies containing ` events type=` → `cisco_meraki`
  - everything else → catch-all (`lab_unknown`)

  Each route's HEC sourcetype is overridable so you can point it at a different
  SDL parser without editing the script: `SDL_CATALYST_SOURCETYPE`,
  `SDL_MERAKI_SOURCETYPE`, `SDL_UNKNOWN_SOURCETYPE`.
- **Local copies** in `/var/log/sdl-rsyslog/{catalyst,meraki,unknown}.log` with a
  12-month `logrotate` policy.
- **HEC forwarding** via a small Python helper (`omprog`) that emits one JSON
  event per line. The HEC `host` (→ SDL **serverHost**) is the **originating
  device** (its syslog hostname, falling back to the sender IP), never the relay
  — so events attribute to the real appliance, not the collector. The collector
  is recorded separately in fields: `metadata.log.collector_host` (its hostname)
  and `metadata.log.collector_ip` (its LAN IP, auto-detected and refreshed;
  override with `SDL_COLLECTOR_IP`). Force a fixed `host` with `SDL_HEC_HOST`.
- **UDP receive buffer** tuning (`rcvbufSize` + `net.core.rmem_max`) to reduce
  silent drops during bursts. On an unprivileged LXC the kernel cap is owned by
  the host; the installer detects this and prints the one host-side command to
  run — it never pretends a clamp didn't happen.

## See it at rest

The installer builds the rsyslog config on the fly, but reference copies live in
[`examples/`](examples/) so you can read them without running anything:

- [`examples/60-sdl-hec.conf`](examples/60-sdl-hec.conf) — the generated rsyslog config.
- [`examples/sample-hec-event.json`](examples/sample-hec-event.json) — one HEC event as sent.

Note: extra fields you may see on an event in SDL (e.g. `field1`, `field2`,
`Log Provider`) are added by the **SDL-side parser** bound to the sourcetype, not
by this pipeline — the payload above is exactly what we send.

## Verifying

The install runs its own smoke test (UUID-tagged events across all three routes,
checked locally and — if `SDL_READ_*` is set — read back from the HEC API). After
install:

```bash
tail -f /var/log/sdl-rsyslog/*.log            # local routing
ss -lnutp | grep 5514                          # confirm rsyslog owns the port
./send-rsyslog-sdl-test.sh <collector-ip> 5514 # re-run the smoke test
```

## Requirements

- Ubuntu (tested on 24.04 LTS "noble"); `apt`, `systemd`, root.
- Outbound HTTPS to your HEC endpoint.

## rsyslog version matters

rsyslog config syntax and module behavior are **version-specific**. Ubuntu
24.04 LTS ships **rsyslog 8.2312.0**, so this tool targets the rsyslog
**v8-stable** docs. Check what you actually have first:

```bash
rsyslogd -v            # 8.2312.0 on Ubuntu 24.04 LTS
apt policy rsyslog
```

If you're on a different Ubuntu release, confirm the directives used here
(`module(load="imudp" ...)`, `rcvbufSize`, `omprog`) against the matching docs.

- rsyslog 8-stable docs: https://www.rsyslog.com/doc/v8-stable/
- `imudp` (UDP input, `rcvbufSize`): https://www.rsyslog.com/doc/v8-stable/configuration/modules/imudp.html
- `omprog` (how the HEC helper is run): https://www.rsyslog.com/doc/v8-stable/configuration/modules/omprog.html
- Ubuntu noble package (exact version): https://packages.ubuntu.com/noble/rsyslog

## Troubleshooting

Look here first — local files are written before anything is forwarded, so they
separate "rsyslog isn't receiving" from "HEC isn't accepting":

```bash
tail -f /var/log/sdl-rsyslog/*.log              # are events arriving + routing?
cat /var/log/sdl-rsyslog/hec-forwarder.log      # helper's HEC send errors (if any)
journalctl -u rsyslog -e                        # rsyslog service log
ss -lnutp | grep 5514                            # is rsyslog bound to the port?
```

| Symptom | Likely cause / fix |
|---|---|
| Installer halts: "port 5514 in use by `<app>`" | Another process owns the port. Stop it, or re-run with `SDL_SYSLOG_PORT=<other>`. |
| Local logs fill, but **nothing reaches SDL** | HEC token/endpoint wrong, or no outbound HTTPS. Check `hec-forwarder.log`. |
| **Remote** devices send but nothing arrives (local test works) | Host firewall. The installer auto-allows `5514/udp+tcp` in ufw and pre-stages the rule even when ufw is *off* — but verify: `ufw status verbose` and `ufw show added`. UDP drops are **silent** (no ack), so a closed port looks like "nothing happening." |
| Was working, broke after a reboot/update | A reboot or package update can **re-enable ufw**. Because the allow rule is pre-staged, `5514` should still pass — confirm with `ufw show added`. |
| UDP events drop under bursts | Receive buffer clamped. On an unprivileged LXC, raise `net.core.rmem_max` on the **host**: `sysctl -w net.core.rmem_max=16777216` and persist in `/etc/sysctl.d/`. |
| `rsyslog` won't start / was disabled | The installer unmasks + enables it. Check `systemctl status rsyslog` and the validation in `/tmp/rsyslog-sdl-validate.log`. |
| Python/helper errors | The helper runs under `/usr/bin/python3 -I` (isolated, stdlib-only) to dodge a polluted Python env. Override the interpreter with `SDL_PYTHON=/path/to/python3`. |
| Events show wrong/no time in SDL | The HEC `time` is taken from an `epoch.nanos` prefix in Meraki-style bodies, else rsyslog's `timereported`. |

## Tuning knobs (env vars)

| Var | Default | Purpose |
|---|---|---|
| `SDL_HEC_TOKEN` | — | HEC write token (**only required input**) |
| `SDL_REGION` | `us1` | region → `ingest.<region>.sentinelone.net` / `xdr.<region>.sentinelone.net` |
| `SDL_READ_TOKEN` | — | optional; enables upstream read-back validation |
| `SDL_HEC_ENDPOINT` / `SDL_READ_ENDPOINT` | from region | override the full endpoints |
| `SDL_CATALYST_SOURCETYPE` | `cisco_catalyst` | Catalyst route sourcetype (SDL parser) |
| `SDL_MERAKI_SOURCETYPE` | `cisco_meraki` | Meraki route sourcetype (SDL parser) |
| `SDL_UNKNOWN_SOURCETYPE` | `lab_unknown` | catch-all route sourcetype (SDL parser) |
| `SDL_SYSLOG_PORT` | `5514` | ingest port |
| `SDL_COLLECTOR_IP` | auto | pin the advertised collector IP |
| `SDL_HEC_HOST` | source device | force the HEC `host` (SDL serverHost); default is the originating device, never the relay |
| `SDL_UDP_RCVBUF` | `8m` | imudp socket buffer request |
| `SDL_UDP_RMEM_MAX` | `16777216` | host `net.core.rmem_max` target |
| `SDL_PYTHON` | `/usr/bin/python3` | interpreter for the HEC helper |

## License

MIT — see [LICENSE](LICENSE).
