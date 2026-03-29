#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-status}"
SLOWDNS_HOME="${SLOWDNS_HOME:-/opt/slowdns}"

SERVICES=(
  "slowdns-api.service|API"
  "slowdns-dnstt.service|SlowDNS Tunnel"
  "slowdns-udp53-redirect.service|UDP 53 Redirect"
  "slowdns-expire-sync.timer|Expiry Sync Timer"
)

service_field() {
  local unit="$1" field="$2"
  local value=""
  value="$(systemctl "$field" "$unit" 2>/dev/null || true)"
  value="$(printf '%s' "$value" | tr -d '\r' | head -n1)"
  printf '%s' "${value:-unknown}"
}

show_status() {
  printf '  %-26s %-12s %-12s\n' "SERVICE" "ACTIVE" "ENABLED"
  printf '  %-26s %-12s %-12s\n' "--------------------------" "------------" "------------"

  local item unit label active enabled
  for item in "${SERVICES[@]}"; do
    unit="${item%%|*}"
    label="${item##*|}"
    active="$(service_field "$unit" is-active)"
    enabled="$(service_field "$unit" is-enabled)"
    printf '  %-26s %-12s %-12s\n' "$label" "$active" "$enabled"
  done
}

restart_all() {
  systemctl restart slowdns-api.service slowdns-dnstt.service slowdns-udp53-redirect.service
  systemctl restart slowdns-expire-sync.timer >/dev/null 2>&1 || true
  echo "  Services restarted."
}

start_all() {
  systemctl start slowdns-api.service slowdns-dnstt.service slowdns-udp53-redirect.service
  systemctl start slowdns-expire-sync.timer >/dev/null 2>&1 || true
  echo "  Services started."
}

stop_all() {
  systemctl stop slowdns-dnstt.service slowdns-api.service slowdns-udp53-redirect.service
  systemctl stop slowdns-expire-sync.timer >/dev/null 2>&1 || true
  echo "  Services stopped."
}

show_logs() {
  if command -v journalctl >/dev/null 2>&1; then
    journalctl -u slowdns-api.service -u slowdns-dnstt.service -u slowdns-udp53-redirect.service --no-pager -n 80
    return 0
  fi

  tail -n 100 \
    "$SLOWDNS_HOME/logs/api.log" \
    "$SLOWDNS_HOME/logs/dnstt.log"
}

case "$ACTION" in
  start)
    start_all
    ;;
  stop)
    stop_all
    ;;
  restart)
    restart_all
    ;;
  status)
    show_status
    ;;
  logs)
    show_logs
    ;;
  *)
    echo "usage: $0 {start|stop|restart|status|logs}" >&2
    exit 1
    ;;
esac
