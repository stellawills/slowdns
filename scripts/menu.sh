#!/usr/bin/env bash
set -euo pipefail

CONFIG_PATH="${SLOWDNS_ONLY_CONFIG:-/opt/slowdns-only/config/config.json}"
API_HOST="${SLOWDNS_ONLY_API_HOST:-127.0.0.1}"
API_SCHEME="${SLOWDNS_ONLY_API_SCHEME:-http}"
API_PORT=""
API_BASE=""
DOMAIN=""
PUBLIC_IP=""
API_RESPONSE=""
API_STATUS=""
API_ERROR=""

need_commands() {
  command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 1; }
  command -v python3 >/dev/null 2>&1 || { echo "python3 is required" >&2; exit 1; }
}

load_config() {
  [[ -f "$CONFIG_PATH" ]] || { echo "config not found at $CONFIG_PATH" >&2; exit 1; }
  local cfg=()
  mapfile -t cfg < <(python3 - "$CONFIG_PATH" <<'PY'
import json, sys
c = json.load(open(sys.argv[1], encoding="utf-8"))
print(c.get("port", 8091))
print(c.get("hostname", ""))
print(c.get("public_ip", ""))
PY
  )
  API_PORT="${cfg[0]:-8091}"
  DOMAIN="${cfg[1]:-}"
  PUBLIC_IP="${cfg[2]:-}"
  API_BASE="${API_SCHEME}://${API_HOST}:${API_PORT}"
}

ask() {
  local prompt="$1" default="${2:-}" reply=""
  if [[ -n "$default" ]]; then
    read -r -p "$prompt [$default]: " reply
    reply="${reply:-$default}"
  else
    read -r -p "$prompt: " reply
  fi
  printf '%s\n' "$reply"
}

pause() {
  echo
  read -r -p "Press Enter to continue..." _
}

json_kv() {
  python3 - "$@" <<'PY'
import json
import sys

payload = {}
for item in sys.argv[1:]:
    if "=" not in item:
        continue
    key, value = item.split("=", 1)
    if value.lower() in {"true", "false"}:
        payload[key] = value.lower() == "true"
        continue
    try:
        payload[key] = int(value)
        continue
    except ValueError:
        payload[key] = value
print(json.dumps(payload))
PY
}

api_request() {
  local method="$1" route="$2" body="${3:-}"
  local output_file error_file curl_rc
  output_file="$(mktemp)"
  error_file="$(mktemp)"
  local args=(-sS -X "$method" "${API_BASE}${route}" -H "Content-Type: application/json" -o "$output_file" -w "%{http_code}")
  if [[ -n "$body" ]]; then
    args+=(-d "$body")
  fi
  set +e
  API_STATUS="$(curl "${args[@]}" 2>"$error_file")"
  curl_rc=$?
  set -e
  API_RESPONSE="$(cat "$output_file" 2>/dev/null || true)"
  API_ERROR="$(cat "$error_file" 2>/dev/null || true)"
  rm -f "$output_file" "$error_file"
  if (( curl_rc != 0 )); then
    return "$curl_rc"
  fi
  return 0
}

print_json() {
  PAYLOAD="${1:-}" python3 - <<'PY'
import json
import os
raw = os.environ.get("PAYLOAD", "")
if not raw:
    raise SystemExit(0)
try:
    obj = json.loads(raw)
except Exception:
    print(raw)
    raise SystemExit(0)
print(json.dumps(obj, indent=2, ensure_ascii=False))
PY
}

show_api_result() {
  if [[ -n "$API_ERROR" ]]; then
    echo
    echo "API request failed."
    echo "Error: $API_ERROR"
    echo "Try: slowdns-service restart"
    return 1
  fi
  if [[ -z "$API_STATUS" || ! "$API_STATUS" =~ ^[0-9]{3}$ ]]; then
    echo
    echo "API returned an invalid response."
    [[ -n "$API_RESPONSE" ]] && printf '%s\n' "$API_RESPONSE"
    return 1
  fi
  echo
  print_json "$API_RESPONSE"
  [[ "$API_STATUS" =~ ^2[0-9][0-9]$ ]]
}

api_health_ok() {
  if ! api_request GET "/api/v2/healthz"; then
    return 1
  fi
  [[ "$API_STATUS" == "200" ]]
}

list_users() {
  api_request GET "/api/v2/vps/accounts/ssh" || true
  show_api_result || true
}

create_user() {
  echo
  local username password days limit_ip quota body
  username="$(ask "Username")"
  password="$(ask "Password")"
  days="$(ask "Days until expiry" "30")"
  limit_ip="$(ask "IP limit" "1")"
  quota="$(ask "Quota GB" "0")"
  body="$(json_kv "username=$username" "password=$password" "expires_in_days=$days" "limit_ip=$limit_ip" "quota_gb=$quota")"
  api_request POST "/api/v2/vps/accounts/ssh" "$body" || true
  show_api_result || true
}

create_trial() {
  echo
  local duration password body
  duration="$(ask "Duration (30m, 1h, 1d)" "1h")"
  password="$(ask "Password (blank = auto)" "")"
  if [[ -n "$password" ]]; then
    body="$(json_kv "duration=$duration" "password=$password")"
  else
    body="$(json_kv "duration=$duration")"
  fi
  api_request POST "/api/v2/vps/accounts/ssh/trials" "$body" || true
  show_api_result || true
}

show_config() {
  echo
  local username
  username="$(ask "Username")"
  api_request GET "/api/v2/vps/accounts/ssh/${username}" || true
  show_api_result || true
}

renew_user() {
  echo
  local username days quota body
  username="$(ask "Username")"
  days="$(ask "Add days" "30")"
  quota="$(ask "New quota GB (blank = keep)" "")"
  if [[ -n "$quota" ]]; then
    body="$(json_kv "expires_in_days=$days" "quota_gb=$quota")"
  else
    body="$(json_kv "expires_in_days=$days")"
  fi
  api_request PATCH "/api/v2/vps/accounts/ssh/${username}" "$body" || true
  show_api_result || true
}

delete_user() {
  echo
  local username confirm
  username="$(ask "Username")"
  confirm="$(ask "Type YES to delete")"
  [[ "$confirm" == "YES" ]] || { echo "Cancelled."; return; }
  api_request DELETE "/api/v2/vps/accounts/ssh/${username}" || true
  show_api_result || true
}

lock_user() {
  echo
  local username body
  username="$(ask "Username")"
  body="$(json_kv "locked=true")"
  api_request PATCH "/api/v2/vps/accounts/ssh/${username}" "$body" || true
  show_api_result || true
}

unlock_user() {
  echo
  local username password body
  username="$(ask "Username")"
  password="$(ask "New password")"
  body="$(json_kv "locked=false" "unlock_password=$password")"
  api_request PATCH "/api/v2/vps/accounts/ssh/${username}" "$body" || true
  show_api_result || true
}

service_status() {
  echo
  /opt/slowdns-only/scripts/control.sh status || true
}

restart_services() {
  echo
  /opt/slowdns-only/scripts/control.sh restart || true
}

view_logs() {
  echo
  /opt/slowdns-only/scripts/control.sh logs || true
}

print_header() {
  clear
  echo "=============================================="
  echo " SlowDNS Only Menu"
  echo "=============================================="
  echo " Domain : ${DOMAIN:-unknown}"
  echo " IP     : ${PUBLIC_IP:-unknown}"
  echo " API    : ${API_BASE}"
  if api_health_ok; then
    echo " Status : API online"
  else
    echo " Status : API offline"
    [[ -n "$API_ERROR" ]] && echo " Error  : $API_ERROR"
  fi
  echo
}

main_menu() {
  while true; do
    print_header
    echo " 1) List users"
    echo " 2) Create user"
    echo " 3) Create trial"
    echo " 4) Show user config"
    echo " 5) Renew user"
    echo " 6) Delete user"
    echo " 7) Lock user"
    echo " 8) Unlock user"
    echo " 9) Service status"
    echo "10) Restart services"
    echo "11) View logs"
    echo " 0) Exit"
    echo
    case "$(ask "Choose")" in
      1) list_users; pause ;;
      2) create_user; pause ;;
      3) create_trial; pause ;;
      4) show_config; pause ;;
      5) renew_user; pause ;;
      6) delete_user; pause ;;
      7) lock_user; pause ;;
      8) unlock_user; pause ;;
      9) service_status; pause ;;
      10) restart_services; pause ;;
      11) view_logs; pause ;;
      0) exit 0 ;;
      *) echo "Invalid choice"; pause ;;
    esac
  done
}

need_commands
load_config
main_menu
