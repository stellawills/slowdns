#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-start}"
CONFIG_PATH="${SLOWDNS_CONFIG:-${SLOWDNS_ONLY_CONFIG:-/opt/slowdns/config/config.json}}"

need_iptables() {
  command -v iptables >/dev/null 2>&1 || { echo "iptables is required for UDP 53 redirect" >&2; exit 1; }
}

load_config() {
  python3 - "$CONFIG_PATH" <<'PY'
import json
import sys
from pathlib import Path

cfg = json.loads(Path(sys.argv[1]).read_text())
slow = cfg.get("slowdns") or {}
print(int(slow.get("listen_port", 53)))
print(int(slow.get("public_port", slow.get("listen_port", 53))))
print("1" if bool(slow.get("redirect_53", False)) else "0")
PY
}

add_nat_rule() {
  local chain="$1"
  shift
  if ! iptables -t nat -C "$chain" "$@" 2>/dev/null; then
    iptables -t nat -A "$chain" "$@"
  fi
}

add_filter_rule() {
  local chain="$1"
  shift
  if ! iptables -C "$chain" "$@" 2>/dev/null; then
    iptables -A "$chain" "$@"
  fi
}

del_nat_rule() {
  local chain="$1"
  shift
  while iptables -t nat -C "$chain" "$@" 2>/dev/null; do
    iptables -t nat -D "$chain" "$@"
  done
}

del_filter_rule() {
  local chain="$1"
  shift
  while iptables -C "$chain" "$@" 2>/dev/null; do
    iptables -D "$chain" "$@"
  done
}

main() {
  local values=()
  mapfile -t values < <(load_config)
  local listen_port="${values[0]:-53}"
  local public_port="${values[1]:-53}"
  local redirect_flag="${values[2]:-0}"

  if [[ "$redirect_flag" != "1" || "$public_port" != "53" || "$listen_port" == "53" ]]; then
    exit 0
  fi

  need_iptables

  case "$ACTION" in
    start|restart)
      add_filter_rule INPUT -p udp --dport "$listen_port" -j ACCEPT
      add_nat_rule PREROUTING -p udp --dport 53 -j REDIRECT --to-ports "$listen_port"
      ;;
    stop)
      del_filter_rule INPUT -p udp --dport "$listen_port" -j ACCEPT
      del_nat_rule PREROUTING -p udp --dport 53 -j REDIRECT --to-ports "$listen_port"
      ;;
    status)
      iptables -S INPUT | grep -- "--dport $listen_port " || true
      iptables -t nat -S PREROUTING | grep -- "--dport 53 .*--to-ports $listen_port" || true
      ;;
    *)
      echo "usage: $0 {start|stop|restart|status}" >&2
      exit 1
      ;;
  esac
}

main "$@"
