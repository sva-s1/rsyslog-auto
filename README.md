# rsyslog-auto

One-shot installer that turns a fresh Ubuntu host (bare metal, VM, or LXC) into a
self-contained **rsyslog → Splunk-style HEC** collector for mixed Cisco-ish
syslog arriving on a single port. It removes any prior OpenTelemetry Collector
setup, configures rsyslog, writes local rotated copies, forwards every event to
your HEC endpoint, and validates itself end-to-end — in one run, no editing.

## Quick start

```bash
# Fully non-interactive:
curl -fsSL https://raw.githubusercontent.com/sva-s1/rsyslog-auto/main/install-rsyslog-sdl.sh \
  | sudo SDL_HEC_TOKEN=<write-token> SDL_HEC_ENDPOINT=https://<your-hec-host>/services/collector/event bash
```

Or drop a `.env` next to where you run it and let the installer read it:

```bash
cd /etc/rsyslog.d
sudo tee .env >/dev/null <<'EOF'
SDL_HEC_ENDPOINT=https://<your-hec-host>/services/collector/event
SDL_HEC_TOKEN=<write-token>
# optional — enables upstream read-back validation after install:
SDL_READ_ENDPOINT=
SDL_READ_TOKEN=
EOF
curl -fsSL https://raw.githubusercontent.com/sva-s1/rsyslog-auto/main/install-rsyslog-sdl.sh | sudo bash
```

If no credentials are found and there's no terminal to prompt at, the installer
writes a fill-in-the-blanks `.env` template and exits telling you what to set.

## Credential precedence

Resolved in this order, so the one-liner works however you run it:

1. Exported env vars (`SDL_HEC_TOKEN` / `SDL_HEC_ENDPOINT`)
2. `./.env` in the current directory
3. Credentials from a previous install (`/etc/rsyslog.d/sdl-hec.env`) — re-run with zero input
4. Interactive prompt
5. None + headless → writes a template `.env` and exits with instructions

No secrets are baked into the script; it's safe to host publicly.

## What it configures

- **Listeners:** UDP + TCP on port `5514` (override with `SDL_SYSLOG_PORT`). UDP
  is the primary path for devices that can't do TCP.
- **Routing by message body** (not hostname/IP, which Cisco-ish gear doesn't set
  reliably):
  - Catalyst IOS/NX signature `%FACILITY-SEV-MNEMONIC:` → `cisco_catalyst`
  - Wireless/AP bodies containing ` events type=` → `cisco_meraki`
  - everything else → catch-all `unknown`
- **Local copies** in `/var/log/sdl-rsyslog/{catalyst,meraki,unknown}.log` with a
  12-month `logrotate` policy.
- **HEC forwarding** via a small Python helper (`omprog`) that emits one JSON
  event per line, stamping `metadata.log.collector_ip` with the collector's
  own LAN IP (auto-detected at runtime, refreshed periodically; override with
  `SDL_COLLECTOR_IP`).
- **UDP receive buffer** tuning (`rcvbufSize` + `net.core.rmem_max`) to reduce
  silent drops during bursts. On an unprivileged LXC the kernel cap is owned by
  the host; the installer detects this and prints the one host-side command to
  run — it never pretends a clamp didn't happen.

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

- Ubuntu (tested on 24.04 LTS); `apt`, `systemd`, root.
- Outbound HTTPS to your HEC endpoint.

## Tuning knobs (env vars)

| Var | Default | Purpose |
|---|---|---|
| `SDL_HEC_ENDPOINT` / `SDL_HEC_TOKEN` | — | HEC write target (required) |
| `SDL_READ_ENDPOINT` / `SDL_READ_TOKEN` | — | optional upstream read-back validation |
| `SDL_SYSLOG_PORT` | `5514` | ingest port |
| `SDL_COLLECTOR_IP` | auto | pin the advertised collector IP |
| `SDL_UDP_RCVBUF` | `8m` | imudp socket buffer request |
| `SDL_UDP_RMEM_MAX` | `16777216` | host `net.core.rmem_max` target |
