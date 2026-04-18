#!/usr/bin/env bash
set -euo pipefail

CONFIG_PATH="${SLOWDNS_CONFIG_PATH:-/opt/slowdns-only/config/config.json}"
API_BASE=""
PUBLIC_HOST=""
TUNNEL_DOMAIN=""
PUBLIC_IP=""
API_RESPONSE=""
API_STATUS=""

load_context() {
  readarray -t VALUES < <(/usr/bin/env python3 - "$CONFIG_PATH" <<'PY'
import json
import sys
from pathlib import Path

cfg = json.loads(Path(sys.argv[1]).read_text())
slow = cfg.get("slowdns") or {}
bind = str(cfg.get("bind") or "127.0.0.1")
port = int(cfg.get("port") or 8091)
public_host = str(slow.get("public_hostname") or cfg.get("hostname") or "").strip(".")
tunnel_domain = str(slow.get("tunnel_domain") or "").strip(".")
if not tunnel_domain:
    zone_prefix = str(slow.get("zone_prefix") or "").strip(".")
    host = str(cfg.get("hostname") or "").strip(".")
    tunnel_domain = f"{zone_prefix}.{host}" if zone_prefix else host
print(f"http://{bind}:{port}")
print(public_host)
print(tunnel_domain)
print(str(cfg.get("public_ip") or ""))
PY
  )
  API_BASE="${VALUES[0]}"
  PUBLIC_HOST="${VALUES[1]}"
  TUNNEL_DOMAIN="${VALUES[2]}"
  PUBLIC_IP="${VALUES[3]}"
}

pause() {
  echo
  read -r -p "Press Enter to continue..." _
}

json_body() {
  /usr/bin/env python3 - "$@" <<'PY'
import json
import sys

payload = {}
numeric_keys = {"expired", "limitip", "kuota", "expires_in_days", "quota_gb"}
for item in sys.argv[1:]:
    key, value = item.split("=", 1)
    lowered = value.strip().lower()
    if lowered in {"true", "false"}:
        payload[key] = lowered == "true"
    elif key in numeric_keys:
        payload[key] = int(value)
    else:
        payload[key] = value
print(json.dumps(payload, separators=(",", ":")))
PY
}

api_request() {
  local method="$1" path="$2" body="${3:-}" tmp
  tmp="$(mktemp)"
  if [[ -n "$body" ]]; then
    API_STATUS="$(curl -ksS -o "$tmp" -w "%{http_code}" -X "$method" -H "Content-Type: application/json" --data "$body" "${API_BASE}${path}" || true)"
  else
    API_STATUS="$(curl -ksS -o "$tmp" -w "%{http_code}" -X "$method" "${API_BASE}${path}" || true)"
  fi
  API_RESPONSE="$(cat "$tmp")"
  rm -f "$tmp"
}

print_header() {
  local health="offline"
  load_context
  api_request GET /api/v2/healthz
  if [[ "$API_STATUS" =~ ^2[0-9][0-9]$ ]]; then
    health="online"
  fi
  clear
  echo "============================================="
  echo " SlowDNS Menu"
  echo "============================================="
  printf ' Public Host  : %s\n' "${PUBLIC_HOST:-unknown}"
  printf ' Tunnel Domain: %s\n' "${TUNNEL_DOMAIN:-unknown}"
  printf ' Public IP    : %s\n' "${PUBLIC_IP:-unknown}"
  printf ' API          : %s\n' "${API_BASE}"
  printf ' Status       : %s\n' "$health"
  echo
}

print_api_error() {
  local fallback="${1:-Request failed.}"
  PAYLOAD="$API_RESPONSE" /usr/bin/env python3 - "$fallback" <<'PY'
import json
import os
import sys

fallback = sys.argv[1]
raw = os.environ.get("PAYLOAD", "").strip()
message = fallback
try:
    payload = json.loads(raw)
except Exception:
    if raw:
        message = raw
    print(message)
    raise SystemExit(0)

error = payload.get("error")
if isinstance(error, dict) and error.get("message"):
    message = str(error["message"])
meta = payload.get("meta")
if isinstance(meta, dict) and meta.get("message"):
    message = str(meta["message"])
print(message)
PY
}

require_success() {
  local fallback="${1:-Request failed.}"
  if [[ "$API_STATUS" =~ ^2[0-9][0-9]$ ]]; then
    return 0
  fi
  echo
  print_api_error "$fallback"
  pause
  return 1
}

list_users() {
  api_request GET /api/v2/vps/accounts/ssh
  require_success "Could not fetch users." || return 0
  echo
  PAYLOAD="$API_RESPONSE" /usr/bin/env python3 - <<'PY'
import json
import os
import sys

payload = json.loads(os.environ.get("PAYLOAD", ""))
accounts = (((payload.get("data") or {}).get("accounts")) or [])
if not accounts:
    print("No users found.")
    raise SystemExit(0)
print(f"{'Username':<20} {'Expiry':<12} {'Limit IP':<8} {'Status':<10} {'Locked':<6}")
print("-" * 62)
for item in accounts:
    print(f"{str(item.get('username','')):<20} {str(item.get('expires_on','')):<12} {str(item.get('limit_ip',0)):<8} {str(item.get('status','')):<10} {str(item.get('locked',False)):<6}")
PY
  pause
}

create_user() {
  local username password days limit_ip quota body
  echo
  read -r -p "Username: " username
  read -r -p "Password: " password
  read -r -p "Days until expiry [30]: " days
  read -r -p "IP limit [1]: " limit_ip
  read -r -p "Quota GB [0]: " quota
  days="${days:-30}"
  limit_ip="${limit_ip:-1}"
  quota="${quota:-0}"
  body="$(json_body "username=$username" "password=$password" "expired=$days" "limitip=$limit_ip" "kuota=$quota")"
  api_request POST /api/v2/vps/accounts/ssh "$body"
  require_success "Could not create user." || return 0
  echo
  PAYLOAD="$API_RESPONSE" /usr/bin/env python3 - <<'PY'
import json
import os
import sys

payload = json.loads(os.environ.get("PAYLOAD", ""))
config = ((payload.get("data") or {}).get("config")) or {}
slowdns = config.get("slowdns") or {}
print("Account created")
print("------------------------------")
print(f"Username      : {config.get('username','')}")
print(f"Password      : {config.get('password','')}")
print(f"Expires       : {config.get('exp','')}")
print(f"SSH Port      : {(config.get('port') or {}).get('ssh','22')}")
print(f"SlowDNS Port  : {(config.get('port') or {}).get('slowdns','53')}")
print(f"Public Host   : {slowdns.get('public_hostname') or config.get('hostname','')}")
print(f"Tunnel Domain : {slowdns.get('tunnel_domain','')}")
print(f"Public Key    : {slowdns.get('public_key','')}")
PY
  pause
}

create_trial() {
  local timelimit body
  echo
  read -r -p "Trial duration [1d]: " timelimit
  timelimit="${timelimit:-1d}"
  body="$(json_body "timelimit=$timelimit")"
  api_request POST /api/v2/vps/accounts/ssh/trials "$body"
  require_success "Could not create trial user." || return 0
  echo
  PAYLOAD="$API_RESPONSE" /usr/bin/env python3 - <<'PY'
import json
import os
import sys

payload = json.loads(os.environ.get("PAYLOAD", ""))
config = ((payload.get("data") or {}).get("config")) or {}
slowdns = config.get("slowdns") or {}
print("Trial account created")
print("------------------------------")
print(f"Username      : {config.get('username','')}")
print(f"Password      : {config.get('password','')}")
print(f"Expires       : {config.get('exp','')}")
print(f"Tunnel Domain : {slowdns.get('tunnel_domain','')}")
print(f"Public Key    : {slowdns.get('public_key','')}")
PY
  pause
}

show_user_config() {
  local username
  echo
  read -r -p "Username: " username
  api_request GET "/api/v2/vps/accounts/ssh/${username}"
  require_success "Could not load user config." || return 0
  echo
  PAYLOAD="$API_RESPONSE" /usr/bin/env python3 - <<'PY'
import json
import os
import sys

payload = json.loads(os.environ.get("PAYLOAD", ""))
data = payload.get("data") or {}
account = data.get("account") or {}
config = data.get("config") or {}
slowdns = config.get("slowdns") or {}
print("Account")
print("------------------------------")
print(f"Username      : {account.get('username','')}")
print(f"Password      : {config.get('password','')}")
print(f"Expires       : {account.get('expires_on','')}")
print(f"Limit IP      : {account.get('limit_ip',0)}")
print(f"Status        : {account.get('status','')}")
print(f"Locked        : {account.get('locked',False)}")
print()
print("SlowDNS")
print("------------------------------")
print(f"A Record      : {((slowdns.get('records') or {}).get('a') or {}).get('name','')} -> {((slowdns.get('records') or {}).get('a') or {}).get('value','')}")
print(f"NS Record     : {((slowdns.get('records') or {}).get('ns') or {}).get('name','')} -> {((slowdns.get('records') or {}).get('ns') or {}).get('value','')}")
print(f"Tunnel Domain : {slowdns.get('tunnel_domain','')}")
print(f"Public Host   : {slowdns.get('public_hostname') or slowdns.get('ns_host','')}")
print(f"Public Key    : {slowdns.get('public_key','')}")
PY
  pause
}

renew_user() {
  local username days quota body
  echo
  read -r -p "Username: " username
  read -r -p "Extend by days: " days
  read -r -p "Quota GB [leave blank to keep]: " quota
  if [[ -n "${quota:-}" ]]; then
    body="$(json_body "expires_in_days=$days" "quota_gb=$quota")"
  else
    body="$(json_body "expires_in_days=$days")"
  fi
  api_request PATCH "/api/v2/vps/accounts/ssh/${username}" "$body"
  require_success "Could not renew user." || return 0
  echo "Account renewed."
  pause
}

delete_user() {
  local username confirm
  echo
  read -r -p "Username: " username
  read -r -p "Delete ${username}? [y/N]: " confirm
  [[ "${confirm,,}" == "y" ]] || return 0
  api_request DELETE "/api/v2/vps/accounts/ssh/${username}"
  require_success "Could not delete user." || return 0
  echo "Account deleted."
  pause
}

lock_user() {
  local username body
  echo
  read -r -p "Username: " username
  body="$(json_body "locked=true")"
  api_request PATCH "/api/v2/vps/accounts/ssh/${username}" "$body"
  require_success "Could not lock user." || return 0
  echo "Account locked."
  pause
}

unlock_user() {
  local username password body
  echo
  read -r -p "Username: " username
  read -r -p "New password [leave blank to keep current]: " password
  if [[ -n "$password" ]]; then
    body="$(json_body "locked=false" "unlock_password=$password")"
  else
    body="$(json_body "locked=false")"
  fi
  api_request PATCH "/api/v2/vps/accounts/ssh/${username}" "$body"
  require_success "Could not unlock user." || return 0
  echo "Account unlocked."
  pause
}

service_status() {
  echo
  /opt/slowdns-only/scripts/control.sh status || true
  pause
}

restart_services() {
  echo
  /opt/slowdns-only/scripts/control.sh restart || true
  pause
}

view_logs() {
  echo
  /opt/slowdns-only/scripts/control.sh logs || true
  pause
}

show_dns_info() {
  echo
  printf 'A  %s  %s\n' "$PUBLIC_HOST" "$PUBLIC_IP"
  printf 'NS %s  %s\n' "$TUNNEL_DOMAIN" "$PUBLIC_HOST"
  pause
}

main_menu() {
  while true; do
    print_header
    echo "1) List users"
    echo "2) Create user"
    echo "3) Create trial"
    echo "4) Show user config"
    echo "5) Renew user"
    echo "6) Delete user"
    echo "7) Lock user"
    echo "8) Unlock user"
    echo "9) Service status"
    echo "10) Restart services"
    echo "11) View logs"
    echo "12) Show DNS info"
    echo "0) Exit"
    echo
    read -r -p "Choose: " choice
    case "$choice" in
      1) list_users ;;
      2) create_user ;;
      3) create_trial ;;
      4) show_user_config ;;
      5) renew_user ;;
      6) delete_user ;;
      7) lock_user ;;
      8) unlock_user ;;
      9) service_status ;;
      10) restart_services ;;
      11) view_logs ;;
      12) show_dns_info ;;
      0) exit 0 ;;
      *) echo "Invalid choice."; pause ;;
    esac
  done
}

main_menu
