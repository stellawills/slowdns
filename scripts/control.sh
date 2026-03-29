#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-status}"

case "$ACTION" in
  start|stop|restart|status)
    systemctl "$ACTION" slowdns-only-api.service slowdns-only-dnstt.service slowdns-only-udp53-redirect.service
    systemctl status slowdns-only-expire-sync.timer --no-pager || true
    ;;
  logs)
    tail -n 100 /opt/slowdns-only/logs/api.log /opt/slowdns-only/logs/dnstt.log
    ;;
  *)
    echo "usage: $0 {start|stop|restart|status|logs}" >&2
    exit 1
    ;;
esac
