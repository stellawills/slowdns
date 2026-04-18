#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-status}"

pick_unit() {
  local preferred="$1" legacy="${2:-}" unit=""
  if systemctl cat "$preferred" >/dev/null 2>&1; then
    unit="$preferred"
  elif [[ -n "$legacy" ]] && systemctl cat "$legacy" >/dev/null 2>&1; then
    unit="$legacy"
  else
    unit="$preferred"
  fi
  printf '%s' "$unit"
}

API_UNIT="$(pick_unit slowdns-api.service slowdns-only-api.service)"
DNSTT_UNIT="$(pick_unit slowdns-dnstt.service slowdns-only-dnstt.service)"
REDIRECT_UNIT="$(pick_unit slowdns-udp53-redirect.service slowdns-only-udp53-redirect.service)"
TIMER_UNIT="$(pick_unit slowdns-expire-sync.timer slowdns-only-expire-sync.timer)"

case "$ACTION" in
  start|stop|restart|status)
    systemctl "$ACTION" "$API_UNIT" "$DNSTT_UNIT" "$REDIRECT_UNIT"
    systemctl status "$TIMER_UNIT" --no-pager || true
    ;;
  logs)
    tail -n 100 /opt/slowdns-only/logs/api.log /opt/slowdns-only/logs/dnstt.log
    ;;
  *)
    echo "usage: $0 {start|stop|restart|status|logs}" >&2
    exit 1
    ;;
esac
