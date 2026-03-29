#!/usr/bin/env bash
set -euo pipefail

readarray -t VALUES < <(/usr/bin/env python3 - <<'PY'
import json
from pathlib import Path

cfg = json.loads(Path("/opt/slowdns-only/config/config.json").read_text())
slow = cfg["slowdns"]
host = str(cfg.get("hostname", "")).strip(".")
zone_prefix = str(slow.get("zone_prefix", "")).strip(".")
zone = f"{zone_prefix}.{host}" if zone_prefix else host
print(int(slow.get("listen_port", 53)))
print(int(slow.get("mtu", 512)))
print(str(slow.get("private_key_path", "/opt/slowdns-only/config/server.key")))
print(zone)
print(str(slow.get("target", "127.0.0.1:22")))
PY
)

LISTEN_PORT="${VALUES[0]}"
MTU="${VALUES[1]}"
PRIVKEY="${VALUES[2]}"
ZONE="${VALUES[3]}"
TARGET="${VALUES[4]}"

exec /opt/slowdns-only/bin/dnstt-server -udp ":${LISTEN_PORT}" -mtu "${MTU}" -privkey-file "${PRIVKEY}" "${ZONE}" "${TARGET}" >>/opt/slowdns-only/logs/dnstt.log 2>&1
