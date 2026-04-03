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

service_states() {
  local field="$1"
  shift
  local output=() line
  if ! output=($(systemctl "$field" "$@" 2>/dev/null)); then
    :
  fi
  if ((${#output[@]} == 0)); then
    local unit
    for unit in "$@"; do
      printf '%s\n' "unknown"
    done
    return 0
  fi
  for line in "${output[@]}"; do
    printf '%s\n' "${line:-unknown}"
  done
}

show_status() {
  printf '  %-26s %-12s %-12s\n' "SERVICE" "ACTIVE" "ENABLED"
  printf '  %-26s %-12s %-12s\n' "--------------------------" "------------" "------------"

  local units=() active_states=() enabled_states=()
  local item unit label index active enabled
  for item in "${SERVICES[@]}"; do
    units+=("${item%%|*}")
  done

  while IFS= read -r line; do
    active_states+=("$line")
  done < <(service_states is-active "${units[@]}")

  while IFS= read -r line; do
    enabled_states+=("$line")
  done < <(service_states is-enabled "${units[@]}")

  for index in "${!SERVICES[@]}"; do
    item="${SERVICES[$index]}"
    label="${item##*|}"
    active="${active_states[$index]:-unknown}"
    enabled="${enabled_states[$index]:-unknown}"
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
