#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-apply}"
CONFIG_PATH="${SLOWDNS_CONFIG_PATH:-/opt/slowdns-only/config/config.json}"

readarray -t VALUES < <(/usr/bin/env python3 - "$CONFIG_PATH" <<'PY'
import json
import sys
from pathlib import Path

cfg = json.loads(Path(sys.argv[1]).read_text())
slow = cfg.get("slowdns") or {}
listen_port = int(slow.get("listen_port", 5300))
public_port = int(slow.get("public_port", listen_port))
redirect_enabled = bool(slow.get("redirect_53", public_port == 53 and listen_port != 53))
print(listen_port)
print(public_port)
print("true" if redirect_enabled else "false")
PY
)

LISTEN_PORT="${VALUES[0]}"
PUBLIC_PORT="${VALUES[1]}"
REDIRECT_ENABLED="${VALUES[2]}"

remove_rule() {
  local table="$1"
  shift
  if [[ -n "$table" ]]; then
    while iptables -t "$table" -C "$@" 2>/dev/null; do
      iptables -t "$table" -D "$@"
    done
  else
    while iptables -C "$@" 2>/dev/null; do
      iptables -D "$@"
    done
  fi
}

clear_rules() {
  remove_rule "" INPUT -p udp --dport "$LISTEN_PORT" -j ACCEPT
  remove_rule nat PREROUTING -p udp --dport "$PUBLIC_PORT" -j REDIRECT --to-ports "$LISTEN_PORT"
}

apply_rules() {
  clear_rules
  if [[ "$REDIRECT_ENABLED" != "true" || "$PUBLIC_PORT" == "$LISTEN_PORT" ]]; then
    return 0
  fi
  iptables -I INPUT -p udp --dport "$LISTEN_PORT" -j ACCEPT
  iptables -t nat -I PREROUTING -p udp --dport "$PUBLIC_PORT" -j REDIRECT --to-ports "$LISTEN_PORT"
}

case "$ACTION" in
  apply)
    apply_rules
    ;;
  clear|stop)
    clear_rules
    ;;
  *)
    echo "usage: $0 {apply|clear}" >&2
    exit 1
    ;;
esac
