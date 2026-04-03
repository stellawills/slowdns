#!/usr/bin/env bash
set -euo pipefail

CONFIG_PATH="${SLOWDNS_CONFIG:-${SLOWDNS_ONLY_CONFIG:-/opt/slowdns/config/config.json}}"
SLOWDNS_HOME="${SLOWDNS_HOME:-/opt/slowdns}"
API_HOST="${SLOWDNS_ONLY_API_HOST:-127.0.0.1}"
API_SCHEME="${SLOWDNS_ONLY_API_SCHEME:-http}"
API_PORT=""
API_BASE=""
DOMAIN=""
PUBLIC_IP=""
API_RESPONSE=""
API_STATUS=""
API_ERROR=""
API_CONNECT_TIMEOUT="${SLOWDNS_API_CONNECT_TIMEOUT:-3}"
API_MAX_TIME="${SLOWDNS_API_MAX_TIME:-30}"
MENU_VERSION="2026.03.30"

C_BOLD=$'\033[1m'
C_RESET=$'\033[0m'
C_RED=$'\033[38;5;210m'
C_GREEN=$'\033[38;5;114m'
C_BLUE=$'\033[38;5;110m'
C_CYAN=$'\033[38;5;116m'
C_MUTED=$'\033[38;5;243m'
C_WHITE=$'\033[38;5;255m'
C_SURFACE=$'\033[38;5;238m'
W=68

_rep() {
  local count="$1" char="$2" out=""
  local i
  for ((i = 0; i < count; i++)); do
    out="${out}${char}"
  done
  printf '%s' "$out"
}

hr() {
  printf '  %s%s%s\n' "$C_SURFACE" "$(_rep "$W" '-')" "$C_RESET"
}

section() {
  local title="$1"
  echo
  printf '  %s%s%s\n' "$C_BOLD" "$title" "$C_RESET"
  printf '  %s%s%s\n' "$C_SURFACE" "$(_rep "${#title}" '=')" "$C_RESET"
}

mi() {
  local num="$1" title="$2" desc="${3:-}"
  if [[ -n "$desc" ]]; then
    printf '  %s[%s%s%s]%s  %-24s %s%s%s\n' \
      "$C_SURFACE" "$C_BLUE" "$num" "$C_SURFACE" "$C_RESET" \
      "$title" "$C_MUTED" "$desc" "$C_RESET"
  else
    printf '  %s[%s%s%s]%s  %s\n' \
      "$C_SURFACE" "$C_BLUE" "$num" "$C_SURFACE" "$C_RESET" "$title"
  fi
}

dot_ok() {
  printf '%sOK%s' "$C_GREEN" "$C_RESET"
}

dot_err() {
  printf '%sFAIL%s' "$C_RED" "$C_RESET"
}

ask() {
  local reply=""
  if [[ -e /dev/tty ]]; then
    printf '\n  %s>%s ' "$C_BLUE" "$C_RESET" > /dev/tty
    IFS= read -r reply < /dev/tty
  else
    printf '\n  %s>%s ' "$C_BLUE" "$C_RESET"
    IFS= read -r reply
  fi
  printf '%s\n' "$reply"
}

ask_prompt() {
  local prompt="$1" default="${2:-}" reply=""
  if [[ -e /dev/tty ]]; then
    if [[ -n "$default" ]]; then
      printf '  %s%s%s [%s]: ' "$C_MUTED" "$prompt" "$C_RESET" "$default" > /dev/tty
    else
      printf '  %s%s%s: ' "$C_MUTED" "$prompt" "$C_RESET" > /dev/tty
    fi
    IFS= read -r reply < /dev/tty
  else
    if [[ -n "$default" ]]; then
      printf '  %s%s%s [%s]: ' "$C_MUTED" "$prompt" "$C_RESET" "$default"
    else
      printf '  %s%s%s: ' "$C_MUTED" "$prompt" "$C_RESET"
    fi
    IFS= read -r reply
  fi
  reply="${reply:-$default}"
  printf '%s\n' "$reply"
}

pause() {
  echo
  if [[ -e /dev/tty ]]; then
    printf '  %sPress Enter to continue...%s' "$C_MUTED" "$C_RESET" > /dev/tty
    IFS= read -r _ < /dev/tty
  else
    printf '  %sPress Enter to continue...%s' "$C_MUTED" "$C_RESET"
    IFS= read -r _
  fi
}

need_commands() {
  command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 1; }
  command -v python3 >/dev/null 2>&1 || { echo "python3 is required" >&2; exit 1; }
}

load_config() {
  [[ -f "$CONFIG_PATH" ]] || { echo "config not found at $CONFIG_PATH" >&2; exit 1; }
  local cfg=()
  mapfile -t cfg < <(python3 - "$CONFIG_PATH" <<'PY'
import json
import sys
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

urlencode() {
  python3 - "$1" <<'PY'
import sys
import urllib.parse
print(urllib.parse.quote(sys.argv[1], safe=""))
PY
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
    low = value.lower()
    if low in {"true", "false"}:
        payload[key] = low == "true"
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
  local args=(
    -sS
    --connect-timeout "$API_CONNECT_TIMEOUT"
    --max-time "$API_MAX_TIME"
    -X "$method"
    "${API_BASE}${route}"
    -H "Content-Type: application/json"
    -o "$output_file"
    -w "%{http_code}"
  )
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

json_message() {
  PAYLOAD="${1:-}" python3 - <<'PY'
import json
import os

raw = os.environ.get("PAYLOAD", "")
if not raw:
    raise SystemExit(0)
try:
    payload = json.loads(raw)
except Exception:
    raise SystemExit(0)

message = ""
meta = payload.get("meta")
if isinstance(meta, dict):
    message = str(meta.get("message") or "").strip()
if not message:
    error = payload.get("error")
    if isinstance(error, dict):
        message = str(error.get("message") or error.get("detail") or error.get("code") or "").strip()
print(message)
PY
}

render_api_body() {
  PAYLOAD="${1:-}" python3 - <<'PY'
import json
import os

raw = os.environ.get("PAYLOAD", "")
if not raw:
    print("  No response body.")
    raise SystemExit(0)

try:
    payload = json.loads(raw)
except Exception:
    print("  Response was not valid JSON.")
    raise SystemExit(0)

data = payload.get("data")

def show(label, value):
    if value is None:
        value = "-"
    if value == "":
        value = "-"
    print(f"  {label:<18} {value}")

def show_header(title):
    print(f"  {title}")
    print(f"  {'-' * len(title)}")

def bool_word(value):
    return "Yes" if value else "No"

def render_accounts(rows):
    if not rows:
        print("  No accounts found.")
        return
    print("  USERNAME             EXPIRES      IP  LOCKED    STATUS      QUOTA")
    print("  ------------------------------------------------------------------")
    for row in rows:
        username = str(row.get("username", "-"))[:20]
        expires = str(row.get("expires_on", "-"))[:12]
        limit_ip = int(row.get("limit_ip", 0) or 0)
        locked = "LOCKED" if row.get("locked") else "OPEN"
        status = str(row.get("status", "-"))[:10]
        quota = str(row.get("max_human", "-"))[:10]
        print(f"  {username:<20} {expires:<12} {limit_ip:>3}  {locked:<8}  {status:<10} {quota:<10}")

def render_slowdns(slowdns):
    if not isinstance(slowdns, dict) or not slowdns:
        return
    usage = slowdns.get("usage") or {}
    records = slowdns.get("records") or {}
    record_a = records.get("a") or {}
    record_ns = records.get("ns") or {}
    print()
    show_header("SlowDNS")
    show("Connect Host", usage.get("connect_host") or slowdns.get("tunnel_domain"))
    show("Connect Port", usage.get("connect_port") or slowdns.get("public_port") or slowdns.get("listen_port"))
    show("Tunnel Domain", slowdns.get("tunnel_domain"))
    show("NS Target Host", slowdns.get("ns_host"))
    show("Internal Port", slowdns.get("listen_port"))
    show("Public Port", slowdns.get("public_port") or slowdns.get("listen_port"))
    show("A Record", f"{record_a.get('name', '-')} -> {record_a.get('value', '-')}")
    show("NS Record", f"{record_ns.get('name', '-')} -> {record_ns.get('value', '-')}")
    show("Client Local", f"{usage.get('client_local_host', '127.0.0.1')}:{usage.get('client_local_port', '-')}")
    show("Target", slowdns.get("target"))
    summary = str(usage.get("summary") or "").strip()
    if summary:
        show("DNS Layout", summary)
    public_key = str(slowdns.get("public_key") or "")
    if public_key:
        show("Public Key", public_key)

def render_config(cfg):
    if not isinstance(cfg, dict):
        print("  No config available.")
        return
    ports = cfg.get("port") or {}
    print()
    show_header("Connection")
    show("Username", cfg.get("username"))
    show("Password", cfg.get("password"))
    show("Expires", cfg.get("exp"))
    show("Hostname", cfg.get("hostname"))
    show("SSH Port", ports.get("ssh"))
    show("SlowDNS Port", ports.get("slowdns"))
    render_slowdns(cfg.get("slowdns"))

def render_account_detail(item):
    account = item.get("account") or {}
    print("  Account")
    print("  -------")
    show("Username", account.get("username"))
    show("Expires", account.get("expires_on"))
    show("Days", account.get("days"))
    show("IP Limit", account.get("limit_ip"))
    show("Locked", bool_word(account.get("locked")))
    show("Status", account.get("status"))
    show("Quota", account.get("max_human"))
    show("Trial", bool_word(account.get("trial")))
    render_config(item.get("config") or {})

def render_services(services):
    if not services:
        print("  No services found.")
        return
    print("  SERVICE                           ACTIVE       ENABLED")
    print("  ------------------------------------------------------")
    for service in services:
        name = str(service.get("name", "-"))[:32]
        active = str(service.get("active", "-"))[:12]
        enabled = str(service.get("enabled", "-"))[:12]
        print(f"  {name:<32} {active:<12} {enabled:<12}")

def render_runtime(runtime):
    show("Version", runtime.get("version"))
    show("Hostname", runtime.get("hostname"))
    show("Public IP", runtime.get("public_ip"))
    render_slowdns(runtime.get("slowdns"))
    services = runtime.get("services") or []
    if services:
        print()
        show_header("Services")
        render_services(services)

def render_result(result):
    if not isinstance(result, dict) or not result:
        print("  Done.")
        return
    for key, value in result.items():
        label = str(key).replace("_", " ").title()
        show(label, value)

if not isinstance(data, dict):
    print("  No data returned.")
elif "accounts" in data:
    render_accounts(data.get("accounts") or [])
elif "account" in data and "config" in data:
    render_account_detail(data)
elif "protocol" in data and "config" in data:
    render_config(data.get("config") or {})
elif "services" in data and ("hostname" in data or "slowdns" in data or "version" in data):
    render_runtime(data)
elif "services" in data:
    render_services(data.get("services") or [])
elif "deleted" in data:
    show("Username", data.get("username"))
    show("Deleted", bool_word(data.get("deleted")))
elif "result" in data:
    render_result(data.get("result"))
else:
    rendered = False
    for key, value in data.items():
        if isinstance(value, (str, int, float, bool)) or value is None:
            show(str(key).replace("_", " ").title(), value)
            rendered = True
    if not rendered:
        print("  Request completed.")
PY
}

show_api_result() {
  local message
  message="$(json_message "$API_RESPONSE")"
  echo
  if [[ -n "$API_ERROR" ]]; then
    printf '  %s  API request failed\n' "$(dot_err)"
    printf '  Error             %s\n' "$API_ERROR"
    printf '  Hint              slowdns-service restart\n'
    return 1
  fi
  if [[ -z "$API_STATUS" || ! "$API_STATUS" =~ ^[0-9]{3}$ ]]; then
    printf '  %s  Invalid API response\n' "$(dot_err)"
    return 1
  fi
  if [[ "$API_STATUS" =~ ^2[0-9][0-9]$ ]]; then
    printf '  %s  Request succeeded\n' "$(dot_ok)"
  else
    printf '  %s  Request failed\n' "$(dot_err)"
  fi
  [[ -n "$message" ]] && printf '  Message           %s\n' "$message"
  printf '  HTTP              %s\n' "$API_STATUS"
  hr
  render_api_body "$API_RESPONSE"
  [[ "$API_STATUS" =~ ^2[0-9][0-9]$ ]]
}

api_health_ok() {
  if ! api_request GET "/api/v2/healthz"; then
    return 1
  fi
  [[ "$API_STATUS" == "200" ]]
}

print_header() {
  clear 2>/dev/null || true
  echo
  printf '  %sSlowDNS Menu%s\n' "$C_BOLD" "$C_RESET"
  printf '  %sVersion%s  %s\n' "$C_MUTED" "$C_RESET" "$MENU_VERSION"
  hr
  printf '  %-12s %s%s%s\n' "Domain" "$C_WHITE" "${DOMAIN:-unknown}" "$C_RESET"
  printf '  %-12s %s%s%s\n' "Public IP" "$C_CYAN" "${PUBLIC_IP:-unknown}" "$C_RESET"
  printf '  %-12s %s\n' "API" "$API_BASE"
  if api_health_ok; then
    printf '  %-12s %s\n' "Status" "$(dot_ok)"
  else
    printf '  %-12s %s\n' "Status" "$(dot_err)"
    [[ -n "$API_ERROR" ]] && printf '  %-12s %s\n' "Error" "$API_ERROR"
  fi
}

list_accounts() {
  section "SSH Accounts"
  api_request GET "/api/v2/vps/accounts/ssh" || true
  show_api_result || true
}

create_account() {
  local username password days limit_ip quota body
  section "SSH - Create Account"
  echo
  username="$(ask_prompt "Username")"
  password="$(ask_prompt "Password")"
  days="$(ask_prompt "Days until expiry" "30")"
  limit_ip="$(ask_prompt "IP limit" "1")"
  quota="$(ask_prompt "Quota GB" "0")"
  body="$(json_kv "username=$username" "password=$password" "expires_in_days=$days" "limit_ip=$limit_ip" "quota_gb=$quota")"
  api_request POST "/api/v2/vps/accounts/ssh" "$body" || true
  show_api_result || true
}

create_trial() {
  local duration password body
  section "SSH - Trial Account"
  echo
  duration="$(ask_prompt "Duration (30m / 1h / 1d)" "1h")"
  password="$(ask_prompt "Password [auto]")"
  if [[ -n "$password" ]]; then
    body="$(json_kv "duration=$duration" "password=$password")"
  else
    body="$(json_kv "duration=$duration")"
  fi
  api_request POST "/api/v2/vps/accounts/ssh/trials" "$body" || true
  show_api_result || true
}

show_account() {
  local username
  section "SSH - Account Details"
  echo
  username="$(ask_prompt "Username")"
  api_request GET "/api/v2/vps/accounts/ssh/$(urlencode "$username")" || true
  show_api_result || true
}

renew_account() {
  local username days quota body_items=()
  section "SSH - Renew Account"
  echo
  username="$(ask_prompt "Username")"
  days="$(ask_prompt "Add days" "30")"
  quota="$(ask_prompt "New quota GB [keep]")"
  body_items+=("expires_in_days=$days")
  [[ -n "$quota" ]] && body_items+=("quota_gb=$quota")
  api_request PATCH "/api/v2/vps/accounts/ssh/$(urlencode "$username")" "$(json_kv "${body_items[@]}")" || true
  show_api_result || true
}

delete_account() {
  local username confirm
  section "SSH - Delete Account"
  echo
  username="$(ask_prompt "Username")"
  printf '  %sDelete "%s"?%s\n' "$C_RED" "$username" "$C_RESET"
  confirm="$(ask_prompt "Type yes to confirm")"
  [[ "$confirm" == "yes" ]] || { printf '  %sCancelled.%s\n' "$C_MUTED" "$C_RESET"; return; }
  api_request DELETE "/api/v2/vps/accounts/ssh/$(urlencode "$username")" || true
  show_api_result || true
}

lock_or_unlock() {
  local username action password
  section "SSH - Lock / Unlock"
  echo
  username="$(ask_prompt "Username")"
  echo
  mi 1 "Lock account"
  mi 2 "Unlock account"
  action="$(ask)"
  case "$action" in
    1)
      api_request PATCH "/api/v2/vps/accounts/ssh/$(urlencode "$username")" "$(json_kv "locked=true")" || true
      ;;
    2)
      password="$(ask_prompt "New password for unlock")"
      api_request PATCH "/api/v2/vps/accounts/ssh/$(urlencode "$username")" "$(json_kv "locked=false" "unlock_password=$password")" || true
      ;;
    *)
      printf '  %sInvalid choice.%s\n' "$C_RED" "$C_RESET"
      return
      ;;
  esac
  show_api_result || true
}

show_status() {
  section "Service Status"
  echo
  "$SLOWDNS_HOME/scripts/control.sh" status || true
}

show_runtime_info() {
  section "Runtime Info"
  api_request GET "/api/v2/vps/runtime" || true
  show_api_result || true
}

restart_services() {
  section "Restart Services"
  echo
  "$SLOWDNS_HOME/scripts/control.sh" restart || true
  echo
  "$SLOWDNS_HOME/scripts/control.sh" status || true
}

view_logs() {
  section "Recent Logs"
  echo
  "$SLOWDNS_HOME/scripts/control.sh" logs || true
}

main_menu() {
  while true; do
    print_header

    section "Account Management"
    echo
    mi 1 "List accounts"      "View all users"
    mi 2 "Create account"     "New user with expiry and limits"
    mi 3 "Create trial"       "Time-limited trial account"
    mi 4 "Account details"    "Check a specific user"
    mi 5 "Renew account"      "Extend expiry date"
    mi 6 "Delete account"     "Permanently remove a user"
    mi 7 "Lock / Unlock"      "Suspend or reactivate access"

    section "Server"
    echo
    mi 8  "Service status"    "Check all running services"
    mi 9  "Runtime info"      "Domain, ports, DNS records"
    mi 10 "Restart services"  "Restart API and SlowDNS"
    mi 11 "View logs"         "Tail API and dnstt logs"
    echo
    mi 0 "Exit"

    case "$(ask)" in
      1) print_header; list_accounts; pause ;;
      2) print_header; create_account; pause ;;
      3) print_header; create_trial; pause ;;
      4) print_header; show_account; pause ;;
      5) print_header; renew_account; pause ;;
      6) print_header; delete_account; pause ;;
      7) print_header; lock_or_unlock; pause ;;
      8) print_header; show_status; pause ;;
      9) print_header; show_runtime_info; pause ;;
      10) print_header; restart_services; pause ;;
      11) print_header; view_logs; pause ;;
      0)
        echo
        printf '  %sGoodbye.%s\n\n' "$C_MUTED" "$C_RESET"
        exit 0
        ;;
      *)
        echo
        printf '  %sInvalid choice.%s\n' "$C_RED" "$C_RESET"
        pause
        ;;
    esac
  done
}

need_commands
load_config
main_menu
