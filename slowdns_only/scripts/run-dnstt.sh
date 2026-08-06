#!/usr/bin/env bash
set -euo pipefail

readarray -t VALUES < <(/usr/bin/env python3 - <<'PY'
import json
from pathlib import Path

cfg = json.loads(Path("/opt/slowdns-only/config/config.json").read_text())
slow = cfg["slowdns"]
host = str(cfg.get("hostname", "")).strip(".")
tunnel_domain = str(slow.get("tunnel_domain", "")).strip(".")
if not tunnel_domain:
    zone_prefix = str(slow.get("zone_prefix", "")).strip(".")
    tunnel_domain = f"{zone_prefix}.{host}" if zone_prefix else host
print(int(slow.get("listen_port", 5300)))
mtu = int(slow.get("mtu") or 1232)
print(mtu if 128 <= mtu <= 1500 else 1232)
print(str(slow.get("private_key_path", "/opt/slowdns-only/config/server.key")))
print(tunnel_domain)
print(str(slow.get("target", "127.0.0.1:22")))
PY
)

LISTEN_PORT="${VALUES[0]}"
MTU="${VALUES[1]}"
PRIVKEY="${VALUES[2]}"
ZONE="${VALUES[3]}"
TARGET="${VALUES[4]}"

exec /opt/slowdns-only/bin/dnstt-server -udp ":${LISTEN_PORT}" -mtu "${MTU}" -privkey-file "${PRIVKEY}" "${ZONE}" "${TARGET}"
