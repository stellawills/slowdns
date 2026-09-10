#!/usr/bin/env bash
set -euo pipefail

SLOWDNS_HOME="${SLOWDNS_HOME:-/opt/slowdns}"
CONFIG_PATH="${SLOWDNS_CONFIG:-$SLOWDNS_HOME/config/config.json}"
API_UNIT="slowdns-api.service"
DNSTT_UNIT="slowdns-dnstt.service"
REDIRECT_UNIT="slowdns-udp53-redirect.service"

log() {
  local message="$1"
  if command -v logger >/dev/null 2>&1; then
    logger -t slowdns-healthcheck -- "$message"
  fi
  printf '%s\n' "$message"
}

load_config() {
  [[ -f "$CONFIG_PATH" ]] || { log "SlowDNS config is missing: $CONFIG_PATH"; exit 1; }
  mapfile -t VALUES < <(/usr/bin/env python3 - "$CONFIG_PATH" <<'PY'
import json
import sys
from pathlib import Path

cfg = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
slow = cfg.get("slowdns") or {}
print(int(slow.get("listen_port", 53)))
print(int(slow.get("public_port", slow.get("listen_port", 53))))
print("1" if bool(slow.get("redirect_53", False)) else "0")
print(str(cfg.get("bind") or "127.0.0.1"))
print(int(cfg.get("port") or 8091))
PY
  )

  LISTEN_PORT="${VALUES[0]:-}"
  PUBLIC_PORT="${VALUES[1]:-}"
  REDIRECT_ENABLED="${VALUES[2]:-}"
  API_BIND="${VALUES[3]:-}"
  API_PORT="${VALUES[4]:-}"
  [[ "$LISTEN_PORT" =~ ^[0-9]+$ && "$PUBLIC_PORT" =~ ^[0-9]+$ && "$API_PORT" =~ ^[0-9]+$ ]] || {
    log "SlowDNS config contains invalid port values"
    exit 1
  }
}

add_issue() {
  ISSUES+=("$1")
}

check_api() {
  local host="$API_BIND"
  case "$host" in
    ""|0.0.0.0) host="127.0.0.1" ;;
    ::|"[::]") host="[::1]" ;;
  esac

  systemctl is-active --quiet "$API_UNIT" || add_issue "api-service"
  curl -fsS --connect-timeout 3 --max-time 5 "http://${host}:${API_PORT}/healthz" -o /dev/null \
    || add_issue "api-health"
}

check_dnstt() {
  systemctl is-active --quiet "$DNSTT_UNIT" || add_issue "dnstt-service"
  if ! command -v ss >/dev/null 2>&1; then
    add_issue "missing-ss"
  elif ! ss -H -u -l -n | awk -v port="$LISTEN_PORT" '$(NF - 1) ~ (":" port "$") { found=1 } END { exit !found }'; then
    add_issue "udp-listener"
  fi
}

check_redirect() {
  [[ "$REDIRECT_ENABLED" == "1" && "$PUBLIC_PORT" == "53" && "$LISTEN_PORT" != "53" ]] || return 0

  if ! command -v iptables >/dev/null 2>&1; then
    add_issue "missing-iptables"
    return 0
  fi
  iptables -C INPUT -p udp --dport "$LISTEN_PORT" -j ACCEPT 2>/dev/null || add_issue "udp-input-rule"
  iptables -t nat -C PREROUTING -p udp --dport 53 -j REDIRECT --to-ports "$LISTEN_PORT" 2>/dev/null \
    || add_issue "udp53-redirect-rule"
}

check_runtime() {
  ISSUES=()
  check_api
  check_dnstt
  check_redirect
}

recover() {
  local issue joined
  joined="$(IFS=,; printf '%s' "${ISSUES[*]}")"
  log "SlowDNS health check failed ($joined); repairing affected services"

  systemctl reset-failed "$API_UNIT" "$DNSTT_UNIT" "$REDIRECT_UNIT" || true

  for issue in "${ISSUES[@]}"; do
    case "$issue" in
      api-service|api-health)
        systemctl restart "$API_UNIT" || true
        ;;
      dnstt-service|udp-listener|udp-input-rule|udp53-redirect-rule)
        systemctl restart "$DNSTT_UNIT" || true
        systemctl restart "$REDIRECT_UNIT" || true
        ;;
    esac
  done
}

main() {
  local attempt
  load_config
  check_runtime
  ((${#ISSUES[@]} == 0)) && exit 0

  recover
  sleep 2
  for attempt in 1 2; do
    check_runtime
    ((${#ISSUES[@]} == 0)) && { log "SlowDNS health recovered"; exit 0; }
    sleep 2
  done

  log "SlowDNS health recovery failed: $(IFS=,; printf '%s' "${ISSUES[*]}")"
  exit 1
}

main "$@"
