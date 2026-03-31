#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALL_DIR="/opt/slowdns"
LEGACY_INSTALL_DIR="/opt/slowdns-only"
CONFIG_DIR="$INSTALL_DIR/config"
BIN_DIR="$INSTALL_DIR/bin"
API_DIR="$INSTALL_DIR/api"
SCRIPTS_DIR="$INSTALL_DIR/scripts"
LOG_DIR="$INSTALL_DIR/logs"
TOOLCHAIN_DIR="$INSTALL_DIR/toolchain"
SYSTEMD_DIR="/etc/systemd/system"

DNSTT_SOURCE_URL="${DNSTT_SOURCE_URL:-https://www.bamsoftware.com/software/dnstt/dnstt-20241021.zip}"
DNSTT_SERVER_URL="${DNSTT_SERVER_URL:-}"
DNSTT_CLIENT_URL="${DNSTT_CLIENT_URL:-}"
GO_MIN_VERSION="${GO_MIN_VERSION:-1.21.0}"
GO_BOOTSTRAP_VERSION="${GO_BOOTSTRAP_VERSION:-1.22.12}"
GO_BOOTSTRAP_BASE_URL="${GO_BOOTSTRAP_BASE_URL:-https://go.dev/dl}"
INSTALLER_VERSION="${INSTALLER_VERSION:-2026.03.30}"
DEFAULT_LICENSE_URL="https://license.internetshub.com"
LICENSE_URL="$DEFAULT_LICENSE_URL"
LICENSE_PRODUCT="slowdns"
INSTALL_CODE="${SLOWDNS_INSTALL_CODE:-${SLOWDNS_LICENSE_KEY:-}}"
LICENSE_PAGE_URL="${LICENSE_URL%/}/slowdns"
CONFIG_HOSTNAME=""
CONFIG_TUNNEL_DOMAIN=""
CONFIG_PUBLIC_IP=""
CONFIG_NS_HOST=""
GO_CMD=""
LICENSE_METADATA_PATH="$CONFIG_DIR/license.json"
LICENSE_ACTIVATION_ID=""
LICENSE_INSTALL_TOKEN=""
INSTALL_CODE_HINT=""
LICENSE_PRECHECK_TOKEN=""
LICENSE_CONFIRMED="false"
DNSTT_BUILD_TMPDIR=""
LICENSE_BANNER_SHOWN="false"
LICENSE_LAST_HTTP_STATUS=""
LICENSE_LAST_ERROR_CODE=""
LICENSE_LAST_ERROR_MESSAGE=""
LICENSE_MACHINE_ID=""
LICENSE_SSH_FINGERPRINT=""

# ANSI color codes — cleared automatically when stdout is not a terminal
_c_reset=$'\033[0m'
_c_bold=$'\033[1m'
_c_green=$'\033[38;5;114m'
_c_yellow=$'\033[38;5;220m'
_c_cyan=$'\033[38;5;116m'
_c_red=$'\033[38;5;210m'
_c_muted=$'\033[38;5;243m'
if [[ ! -t 1 ]]; then
  _c_reset='' _c_bold='' _c_green='' _c_yellow='' _c_cyan='' _c_red='' _c_muted=''
fi

trim() {
  local value="${1:-}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

lower() {
  printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]'
}

print_section() {
  local title="${1:-}"
  if [[ -z "$title" ]]; then
    return 0
  fi
  printf '\n%s============================================================%s\n' "$_c_bold" "$_c_reset"
  printf '%s %s%s\n' "$_c_bold" "$title" "$_c_reset"
  printf '%s============================================================%s\n' "$_c_bold" "$_c_reset"
}

is_true() {
  case "$(lower "${1:-}")" in
    1|true|yes|on)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

is_ipv4() {
  local ip="$1"
  local IFS=.
  local -a octets=()
  read -r -a octets <<<"$ip"
  [[ "${#octets[@]}" -eq 4 ]] || return 1
  for octet in "${octets[@]}"; do
    [[ "$octet" =~ ^[0-9]+$ ]] || return 1
    (( octet >= 0 && octet <= 255 )) || return 1
  done
}

prompt_required() {
  local __var_name="$1"
  local prompt_text="$2"
  local default_value="${3:-}"
  local reply=""

  if [[ ! -t 0 && -z "$default_value" ]]; then
    echo "$prompt_text is required in non-interactive mode" >&2
    exit 1
  fi

  while true; do
    if [[ -n "$default_value" ]]; then
      read -r -p "$prompt_text [$default_value]: " reply
      reply="${reply:-$default_value}"
    else
      read -r -p "$prompt_text: " reply
    fi
    reply="$(trim "$reply")"
    if [[ -n "$reply" ]]; then
      printf -v "$__var_name" '%s' "$reply"
      return 0
    fi
    echo "A value is required." >&2
  done
}

prompt_public_ip() {
  local default_value="${1:-}"
  local reply=""

  if [[ ! -t 0 ]]; then
    if [[ -n "$default_value" ]] && is_ipv4 "$default_value"; then
      CONFIG_PUBLIC_IP="$default_value"
      return 0
    fi
    echo "Public IPv4 is required in non-interactive mode. Pass SLOWDNS_PUBLIC_IP." >&2
    exit 1
  fi

  while true; do
    if [[ -n "$default_value" ]]; then
      read -r -p "Public IPv4 for this VPS [$default_value]: " reply
      reply="${reply:-$default_value}"
    else
      read -r -p "Public IPv4 for this VPS: " reply
    fi
    reply="$(trim "$reply")"
    if is_ipv4 "$reply"; then
      CONFIG_PUBLIC_IP="$reply"
      return 0
    fi
    echo "Enter a valid IPv4 address." >&2
  done
}

read_existing_config_value() {
  local key="$1"
  local path="$CONFIG_DIR/config.json"
  if [[ ! -f "$path" && -f "$LEGACY_INSTALL_DIR/config/config.json" ]]; then
    path="$LEGACY_INSTALL_DIR/config/config.json"
  fi
  if [[ ! -f "$path" ]]; then
    return 0
  fi
  # python3 -c passes source via CLI arg, keeping stdin free (consistent with
  # the rest of this installer that reads data through stdin or sys.argv).
  python3 -c '
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
key  = sys.argv[2]
try:
    cfg = json.loads(path.read_text(encoding="utf-8"))
except Exception:
    raise SystemExit(0)
value = cfg
for part in key.split("."):
    if not isinstance(value, dict):
        value = ""
        break
    value = value.get(part, "")
if value is None:
    value = ""
if isinstance(value, bool):
    print(str(value).lower())
else:
    print(str(value))
' "$path" "$key"
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "run as root" >&2
    exit 1
  fi
}

install_packages() {
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y python3 curl unzip tar openssh-server ca-certificates iptables screen
  fi
}

maybe_reexec_in_screen() {
  local session_name cmd
  if [[ ! -t 0 || ! -t 1 ]]; then
    return 0
  fi
  if [[ -n "${SLOWDNS_SCREEN_ATTACHED:-}" || -n "${SCREEN:-}" || -n "${TMUX:-}" ]]; then
    return 0
  fi
  if [[ -z "${SSH_CONNECTION:-}" ]]; then
    return 0
  fi
  if is_true "${SLOWDNS_DISABLE_SCREEN_AUTOSTART:-false}"; then
    return 0
  fi
  command -v screen >/dev/null 2>&1 || return 0

  session_name="slowdns-install"
  printf '%sLaunching installer inside screen session %s so it can survive SSH drops.%s\n' "$_c_muted" "$session_name" "$_c_reset"
  printf '%sIf you disconnect, reattach with: screen -r %s%s\n\n' "$_c_muted" "$session_name" "$_c_reset"
  printf -v cmd 'cd %q && SLOWDNS_SCREEN_ATTACHED=true %q' "$PROJECT_DIR" "$SCRIPT_DIR/install.sh"
  exec screen -D -RR -S "$session_name" bash -lc "$cmd"
}

license_requested() {
  return 0
}

validate_license_settings() {
  if ! license_requested; then
    return 0
  fi
  if [[ -z "$LICENSE_URL" ]]; then
    printf '%sERROR: SlowDNS install-code activation is not configured with a license server.%s\n' "$_c_red" "$_c_reset" >&2
    exit 1
  fi
  if [[ "$LICENSE_URL" != "$DEFAULT_LICENSE_URL" ]]; then
    printf '%sERROR: This installer is locked to %s and cannot use an alternate license server.%s\n' "$_c_red" "$DEFAULT_LICENSE_URL" "$_c_reset" >&2
    exit 1
  fi
}

check_installer_version() {
  # Silently skip if curl is not yet available (runs after install_packages in main).
  command -v curl >/dev/null 2>&1 || return 0
  local version_url="https://raw.githubusercontent.com/stellawills/slowdns/main/VERSION"
  local latest=""
  latest="$(curl -4fsSL --max-time 8 "$version_url" 2>/dev/null | tr -d '[:space:]' || true)"
  if [[ -z "$latest" || "$latest" == "$INSTALLER_VERSION" ]]; then
    return 0
  fi
  printf '%sWarning: This installer (%s) is outdated. Latest version: %s%s\n' \
    "$_c_yellow" "$INSTALLER_VERSION" "$latest" "$_c_reset" >&2
  printf '  Download the latest installer from: %shttps://github.com/stellawills/slowdns%s\n' \
    "$_c_cyan" "$_c_reset" >&2
  printf '\n'
}

detect_public_ip() {
  if [[ -n "${SLOWDNS_PUBLIC_IP:-}" ]]; then
    printf '%s\n' "$SLOWDNS_PUBLIC_IP"
    return
  fi
  if command -v curl >/dev/null 2>&1; then
    curl -4fsSL https://api.ipify.org 2>/dev/null || true
  fi
}

detect_hostname() {
  if [[ -n "${SLOWDNS_HOSTNAME:-}" ]]; then
    printf '%s\n' "$SLOWDNS_HOSTNAME"
    return
  fi
  hostname -f 2>/dev/null || hostname 2>/dev/null || true
}

derive_sibling_host() {
  local host="${1:-}"
  local label="${2:-}"
  local rest=""
  host="$(trim "$host")"
  label="$(trim "$label")"
  if [[ -z "$host" || -z "$label" ]]; then
    printf '%s\n' "$host"
    return
  fi
  if [[ "$host" == "$label" || "$host" == "$label".* ]]; then
    printf '%s\n' "$host"
    return
  fi
  rest="$host"
  if [[ "$host" == *.*.* ]]; then
    rest="${host#*.}"
  fi
  printf '%s.%s\n' "$label" "$rest"
}

resolve_install_values() {
  local detected_host existing_host existing_tunnel_domain host_default tunnel_default
  local ns_default
  local detected_ip existing_ip ip_default

  mkdir -p "$CONFIG_DIR"

  detected_host="$(trim "$(detect_hostname)")"
  existing_host="$(trim "$(read_existing_config_value hostname)")"
  existing_tunnel_domain="$(trim "$(read_existing_config_value slowdns.tunnel_domain)")"
  detected_ip="$(trim "$(detect_public_ip)")"
  existing_ip="$(trim "$(read_existing_config_value public_ip)")"

  host_default="${SLOWDNS_HOSTNAME:-$existing_host}"
  if [[ -z "$host_default" || "$host_default" == "localhost" ]]; then
    if [[ -n "$detected_host" && "$detected_host" != "localhost" ]]; then
      host_default="$detected_host"
    else
      host_default=""
    fi
  fi

  if [[ -t 0 ]]; then
    prompt_required CONFIG_HOSTNAME "SlowDNS public hostname (A record host)" "$host_default"
  else
    if [[ -z "$host_default" ]]; then
      echo "SlowDNS public hostname is required in non-interactive mode. Pass SLOWDNS_HOSTNAME." >&2
      exit 1
    fi
    CONFIG_HOSTNAME="$host_default"
  fi

  tunnel_default="${SLOWDNS_TUNNEL_DOMAIN:-$existing_tunnel_domain}"
  if [[ -z "$tunnel_default" ]]; then
    tunnel_default="$(derive_sibling_host "$CONFIG_HOSTNAME" "slowdns")"
  fi
  if [[ -t 0 ]]; then
    prompt_required CONFIG_TUNNEL_DOMAIN "SlowDNS delegated tunnel domain" "$tunnel_default"
  else
    CONFIG_TUNNEL_DOMAIN="$tunnel_default"
  fi

  ns_default="${SLOWDNS_NS_HOST:-}"
  if [[ -n "$ns_default" ]]; then
    CONFIG_NS_HOST="$ns_default"
  else
    CONFIG_NS_HOST="$CONFIG_HOSTNAME"
  fi

  ip_default="${SLOWDNS_PUBLIC_IP:-$existing_ip}"
  if [[ -z "$ip_default" ]]; then
    ip_default="$detected_ip"
  fi
  prompt_public_ip "$ip_default"
}

detect_machine_id() {
  local path value=""
  for path in /etc/machine-id /var/lib/dbus/machine-id; do
    if [[ -f "$path" ]]; then
      value="$(tr -d '[:space:]' < "$path" 2>/dev/null || true)"
      [[ -n "$value" ]] && break
    fi
  done
  if [[ -z "$value" ]] && command -v hostnamectl >/dev/null 2>&1; then
    value="$(hostnamectl --machine-id 2>/dev/null | tr -d '[:space:]' || true)"
  fi
  if [[ -z "$value" ]]; then
    echo "unable to detect machine-id for license activation" >&2
    exit 1
  fi
  printf '%s' "$value"
}

detect_ssh_fingerprint() {
  local key_path fingerprint=""
  for key_path in \
    /etc/ssh/ssh_host_ed25519_key.pub \
    /etc/ssh/ssh_host_ecdsa_key.pub \
    /etc/ssh/ssh_host_rsa_key.pub; do
    if [[ -f "$key_path" ]]; then
      fingerprint="$(ssh-keygen -l -E sha256 -f "$key_path" 2>/dev/null | awk '{print $2}' | head -n1)"
      [[ -n "$fingerprint" ]] && break
    fi
  done
  if [[ -z "$fingerprint" ]]; then
    echo "unable to detect SSH host fingerprint for license activation" >&2
    exit 1
  fi
  printf '%s' "$fingerprint"
}

license_error_message() {
  local page_url="${1:-}"
  # python3 -c keeps stdin free for sys.stdin.read() to receive the here-string body.
  python3 -c '
import json, sys
page_url = sys.argv[1]
raw = sys.stdin.read().strip()
if not raw:
    print("SlowDNS activation failed.")
    raise SystemExit(0)
try:
    data = json.loads(raw)
except Exception:
    print("SlowDNS activation failed.")
    raise SystemExit(0)
error = data.get("error") or {}
code = str(error.get("code") or "").strip()
message = str(error.get("message") or "").strip()
known = {
    "install_code_used": f"Install code already used. Generate a fresh code at {page_url}.",
    "install_code_expired": f"Install code expired. Generate a fresh code at {page_url}.",
    "install_code_not_found": f"Install code not found. Generate a fresh code at {page_url}.",
    "install_code_max_activations": f"Install code exceeded max activation attempts. Generate a new code at {page_url}.",
    "rate_limit_exceeded": "Too many requests from this IP. Wait a while and try again.",
    "validation_error": message or "Install code was invalid.",
    "browser_session_required": f"Open {page_url} first, then request a code from that page before installing.",
    "browser_session_invalid": f"Your SlowDNS browser session expired. Refresh {page_url} and generate a new code.",
    "precheck_token_invalid": "Install code validation expired or no longer matches this machine. Re-run validation with a fresh code.",
    "token_invalid": "Activation token was rejected by the license server.",
    "token_mismatch": "Activation confirmation did not match the issued token.",
    "activation_not_found": "Activation session was not found on the license server.",
}
if code in known:
    print(known[code])
elif message:
    print(message)
else:
    print("SlowDNS activation failed.")
' "$page_url"
}

license_error_code() {
  # python3 -c keeps stdin free for sys.stdin.read() to receive the here-string body.
  python3 -c '
import json, sys
raw = sys.stdin.read().strip()
if not raw:
    raise SystemExit(1)
try:
    data = json.loads(raw)
except Exception:
    raise SystemExit(1)
error = data.get("error") or {}
code = str(error.get("code") or "").strip()
if not code:
    raise SystemExit(1)
print(code)
'
}

show_license_banner() {
  if [[ "$LICENSE_BANNER_SHOWN" == "true" ]]; then
    return 0
  fi
  LICENSE_BANNER_SHOWN="true"
  print_section "SlowDNS Install Code"
  printf ' Generate code at: %s%s%s\n' "$_c_cyan" "$LICENSE_PAGE_URL" "$_c_reset"
  printf ' %sThis code is single-use and expires quickly.%s\n\n' "$_c_muted" "$_c_reset"
}

license_prompt_key() {
  if ! license_requested; then
    return 0
  fi
  if [[ -n "$INSTALL_CODE" ]]; then
    if [[ -n "${SLOWDNS_INSTALL_CODE:-${SLOWDNS_LICENSE_KEY:-}}" ]]; then
      show_license_banner
      printf ' Using install code from environment: %s%s%s\n' "$_c_yellow" "$INSTALL_CODE" "$_c_reset"
    fi
    return 0
  fi
  if [[ ! -t 0 ]]; then
    echo "SLOWDNS_INSTALL_CODE is required in non-interactive mode." >&2
    exit 1
  fi
  show_license_banner
  printf ' Enter install code: '
  local _ic_reply=""
  while [[ -z "$_ic_reply" ]]; do
    read -r _ic_reply
    _ic_reply="$(trim "$_ic_reply")"
    [[ -z "$_ic_reply" ]] && printf ' %sA value is required.%s Enter install code: ' "$_c_red" "$_c_reset"
  done
  INSTALL_CODE="$_ic_reply"
}

json_query() {
  local path="$1"
  # python3 -c keeps stdin free for sys.stdin.read() to receive the piped response.
  python3 -c '
import json, sys
path = sys.argv[1]
raw = sys.stdin.read()
if not raw.strip():
    raise SystemExit(1)
data = json.loads(raw)
value = data
for part in path.split("."):
    if isinstance(value, dict):
        value = value.get(part)
    else:
        value = None
        break
if value is None:
    raise SystemExit(1)
if isinstance(value, bool):
    print("true" if value else "false")
elif isinstance(value, (dict, list)):
    print(json.dumps(value, separators=(",", ":")))
else:
    print(value)
' "$path"
}

license_post_json() {
  local route="$1" payload="$2"
  local tmp status body curl_rc
  tmp="$(mktemp)"
  LICENSE_LAST_HTTP_STATUS=""
  LICENSE_LAST_ERROR_CODE=""
  LICENSE_LAST_ERROR_MESSAGE=""
  set +e
  status="$(curl -4sS -o "$tmp" -w "%{http_code}" \
    -H "Content-Type: application/json" \
    -X POST \
    -d "$payload" \
    "${LICENSE_URL%/}${route}")"
  curl_rc=$?
  set -e
  body="$(cat "$tmp")"
  rm -f "$tmp"

  if [[ "$curl_rc" -ne 0 ]]; then
    LICENSE_LAST_ERROR_CODE="network_error"
    LICENSE_LAST_ERROR_MESSAGE="Could not reach the license server at ${LICENSE_URL%/}. Check network access and try again."
    return 1
  fi

  if [[ "$status" != 2* ]]; then
    LICENSE_LAST_HTTP_STATUS="$status"
    LICENSE_LAST_ERROR_CODE="$(license_error_code <<<"$body" 2>/dev/null || true)"
    LICENSE_LAST_ERROR_MESSAGE="$(license_error_message "$LICENSE_PAGE_URL" <<<"$body")"
    [[ -n "$LICENSE_LAST_ERROR_MESSAGE" ]] || LICENSE_LAST_ERROR_MESSAGE="License request failed with HTTP $status."
    return 1
  fi

  printf '%s' "$body"
}

license_precheck() {
  local payload response _resp_tmp _resp_rc

  if ! license_requested; then
    return 0
  fi

  LICENSE_MACHINE_ID="$(detect_machine_id)"
  LICENSE_SSH_FINGERPRINT="$(detect_ssh_fingerprint)"

  while true; do
    license_prompt_key
    printf '%sValidating install code...%s\n' "$_c_muted" "$_c_reset"

    payload="$(python3 - "$INSTALL_CODE" "$LICENSE_PRODUCT" "$LICENSE_MACHINE_ID" "$LICENSE_SSH_FINGERPRINT" "$INSTALLER_VERSION" <<'PY'
import json
import sys

payload = {
    "install_code": sys.argv[1].strip().upper(),
    "license_key": sys.argv[1].strip().upper(),
    "product": sys.argv[2].strip().lower(),
    "machine_id": sys.argv[3].strip(),
    "ssh_fingerprint": sys.argv[4].strip(),
    "installer_version": sys.argv[5].strip(),
}
print(json.dumps(payload, separators=(",", ":")))
PY
)"

    _resp_tmp="$(mktemp)"
    _resp_rc=0
    license_post_json "/api/v2/slowdns/install/precheck" "$payload" > "$_resp_tmp" || _resp_rc=$?
    response="$(cat "$_resp_tmp")"
    rm -f "$_resp_tmp"
    if [[ "$_resp_rc" -ne 0 ]]; then
      printf '%s%s%s\n' "$_c_red" "${LICENSE_LAST_ERROR_MESSAGE:-SlowDNS precheck failed.}" "$_c_reset" >&2
      if [[ -n "$LICENSE_LAST_HTTP_STATUS" ]]; then
        printf '%sHTTP %s%s\n' "$_c_muted" "$LICENSE_LAST_HTTP_STATUS" "$_c_reset" >&2
      fi
      if [[ -t 0 ]]; then
        case "$LICENSE_LAST_ERROR_CODE" in
          install_code_used|install_code_expired|install_code_not_found|validation_error|install_code_max_activations|network_error|browser_session_required|browser_session_invalid)
            printf '%sTry again with a fresh install code from %s%s\n' "$_c_muted" "$LICENSE_PAGE_URL" "$_c_reset" >&2
            INSTALL_CODE=""
            continue
            ;;
        esac
      fi
      exit 1
    fi

    LICENSE_PRECHECK_TOKEN="$(printf '%s' "$response" | json_query "data.precheck_token" 2>/dev/null || true)"
    INSTALL_CODE_HINT="$(printf '%s' "$response" | json_query "data.install_code_hint" 2>/dev/null || true)"
    if [[ -z "$INSTALL_CODE_HINT" ]]; then
      INSTALL_CODE_HINT="$(printf '%s' "$response" | json_query "data.install_code" 2>/dev/null || true)"
    fi
    if [[ -z "$LICENSE_PRECHECK_TOKEN" ]]; then
      printf '%sLicense server returned an invalid precheck response.%s\n' "$_c_red" "$_c_reset" >&2
      if [[ -t 0 ]]; then
        printf '%sTry again with a fresh install code from %s%s\n' "$_c_muted" "$LICENSE_PAGE_URL" "$_c_reset" >&2
        INSTALL_CODE=""
        continue
      fi
      exit 1
    fi

    printf '%s Install code accepted.%s Continue with the SlowDNS host prompts.\n' "$_c_green" "$_c_reset"
    break
  done
}

license_activate() {
  local payload response _resp_tmp _resp_rc

  if ! license_requested; then
    return 0
  fi

  while true; do
    if [[ -z "$LICENSE_PRECHECK_TOKEN" ]]; then
      echo "license precheck token missing" >&2
      exit 1
    fi

    payload="$(python3 - "$INSTALL_CODE" "$LICENSE_PRECHECK_TOKEN" "$LICENSE_PRODUCT" "$CONFIG_HOSTNAME" "$CONFIG_PUBLIC_IP" "$LICENSE_MACHINE_ID" "$LICENSE_SSH_FINGERPRINT" "$INSTALLER_VERSION" <<'PY'
import json
import sys

payload = {
    "install_code": sys.argv[1].strip().upper(),
    "license_key": sys.argv[1].strip().upper(),
    "precheck_token": sys.argv[2].strip(),
    "product": sys.argv[3].strip().lower(),
    "hostname": sys.argv[4].strip().lower(),
    "public_ip": sys.argv[5].strip(),
    "machine_id": sys.argv[6].strip(),
    "ssh_fingerprint": sys.argv[7].strip(),
    "requested_ref": "main",
    "installer_version": sys.argv[8].strip(),
}
print(json.dumps(payload, separators=(",", ":")))
PY
)"

    printf '%sBinding activation to the selected host and IP...%s\n' "$_c_muted" "$_c_reset"
    _resp_tmp="$(mktemp)"
    _resp_rc=0
    license_post_json "/api/v2/slowdns/install/activate" "$payload" > "$_resp_tmp" || _resp_rc=$?
    response="$(cat "$_resp_tmp")"
    rm -f "$_resp_tmp"
    if [[ "$_resp_rc" -ne 0 ]]; then
      printf '%s%s%s\n' "$_c_red" "${LICENSE_LAST_ERROR_MESSAGE:-SlowDNS activation failed.}" "$_c_reset" >&2
      if [[ -n "$LICENSE_LAST_HTTP_STATUS" ]]; then
        printf '%sHTTP %s%s\n' "$_c_muted" "$LICENSE_LAST_HTTP_STATUS" "$_c_reset" >&2
      fi
      if [[ -t 0 ]]; then
        case "$LICENSE_LAST_ERROR_CODE" in
          precheck_token_invalid|install_code_used|install_code_expired|install_code_not_found|install_code_max_activations|validation_error)
            printf '%sRe-validating the install code before activation...%s\n' "$_c_muted" "$_c_reset" >&2
            LICENSE_PRECHECK_TOKEN=""
            INSTALL_CODE=""
            INSTALL_CODE_HINT=""
            license_precheck
            continue
            ;;
        esac
      fi
      exit 1
    fi

    LICENSE_ACTIVATION_ID="$(printf '%s' "$response" | json_query "data.activation_id" 2>/dev/null || true)"
    LICENSE_INSTALL_TOKEN="$(printf '%s' "$response" | json_query "data.install_token" 2>/dev/null || true)"
    if [[ -z "$LICENSE_ACTIVATION_ID" || -z "$LICENSE_INSTALL_TOKEN" ]]; then
      printf '%sLicense server returned an invalid activation response.%s\n' "$_c_red" "$_c_reset" >&2
      exit 1
    fi
    break
  done
}

license_confirm() {
  local payload response _resp_tmp _resp_rc
  if [[ -z "$LICENSE_ACTIVATION_ID" || -z "$LICENSE_INSTALL_TOKEN" ]]; then
    return 0
  fi
  payload="$(python3 - "$LICENSE_ACTIVATION_ID" "$LICENSE_INSTALL_TOKEN" <<'PY'
import json
import sys

print(json.dumps({
    "activation_id": sys.argv[1].strip(),
    "install_token": sys.argv[2].strip(),
}, separators=(",", ":")))
PY
)"
  printf '%sConfirming activation...%s\n' "$_c_muted" "$_c_reset"
  _resp_tmp="$(mktemp)"
  _resp_rc=0
  license_post_json "/api/v2/slowdns/install/confirm" "$payload" > "$_resp_tmp" || _resp_rc=$?
  response="$(cat "$_resp_tmp")"
  rm -f "$_resp_tmp"
  if [[ "$_resp_rc" -ne 0 ]]; then
    printf '%s%s%s\n' "$_c_red" "${LICENSE_LAST_ERROR_MESSAGE:-Activation confirmation failed.}" "$_c_reset" >&2
    [[ -n "$LICENSE_LAST_HTTP_STATUS" ]] && printf '%sHTTP %s%s\n' "$_c_muted" "$LICENSE_LAST_HTTP_STATUS" "$_c_reset" >&2
    exit 1
  fi
  if ! printf '%s' "$response" | json_query "data.status" >/dev/null 2>&1; then
    printf '%sLicense server returned an invalid confirmation response.%s\n' "$_c_red" "$_c_reset" >&2
    exit 1
  fi
  LICENSE_CONFIRMED="true"
  printf '%s Activation confirmed.%s\n' "$_c_green" "$_c_reset"
}

license_release() {
  local payload
  if [[ -z "$LICENSE_ACTIVATION_ID" || -z "$INSTALL_CODE" || "$LICENSE_CONFIRMED" == "true" ]]; then
    return 0
  fi
  payload="$(python3 - "$LICENSE_ACTIVATION_ID" "$INSTALL_CODE" <<'PY'
import json
import sys

print(json.dumps({
    "activation_id": sys.argv[1].strip(),
    "license_key": sys.argv[2].strip().upper(),
    "install_code": sys.argv[2].strip().upper(),
}, separators=(",", ":")))
PY
)"
  license_post_json "/api/v2/slowdns/install/release" "$payload" >/dev/null 2>&1 || true
}

write_license_metadata() {
  if [[ "$LICENSE_CONFIRMED" != "true" ]]; then
    rm -f "$LICENSE_METADATA_PATH"
    return 0
  fi
  python3 - "$LICENSE_METADATA_PATH" "$LICENSE_URL" "$LICENSE_PRODUCT" "$INSTALL_CODE_HINT" "$LICENSE_ACTIVATION_ID" "$CONFIG_HOSTNAME" "$CONFIG_PUBLIC_IP" <<'PY'
import datetime as dt
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
payload = {
    "license_url": sys.argv[2],
    "product": sys.argv[3],
    "install_code_hint": sys.argv[4],
    "activation_id": sys.argv[5],
    "hostname": sys.argv[6],
    "public_ip": sys.argv[7],
    "confirmed_at": dt.datetime.now(dt.timezone.utc).isoformat(),
}
path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
PY
}

cleanup_on_exit() {
  local code=$?
  set +e
  if [[ -n "${DNSTT_BUILD_TMPDIR:-}" && -d "${DNSTT_BUILD_TMPDIR}" ]]; then
    rm -rf "${DNSTT_BUILD_TMPDIR}"
    DNSTT_BUILD_TMPDIR=""
  fi
  if [[ "$code" -ne 0 ]]; then
    license_release
  fi
}

copy_project() {
  mkdir -p "$BIN_DIR" "$CONFIG_DIR" "$API_DIR" "$SCRIPTS_DIR" "$LOG_DIR" "$TOOLCHAIN_DIR"
  install -m 0755 "$PROJECT_DIR/api/slowdns_only_api.py" "$API_DIR/slowdns_only_api.py"
  install -m 0755 "$PROJECT_DIR/scripts/run-api.sh" "$SCRIPTS_DIR/run-api.sh"
  install -m 0755 "$PROJECT_DIR/scripts/run-dnstt.sh" "$SCRIPTS_DIR/run-dnstt.sh"
  install -m 0755 "$PROJECT_DIR/scripts/control.sh" "$SCRIPTS_DIR/control.sh"
  install -m 0755 "$PROJECT_DIR/scripts/expire-sync.sh" "$SCRIPTS_DIR/expire-sync.sh"
  install -m 0755 "$PROJECT_DIR/scripts/menu.sh" "$SCRIPTS_DIR/menu.sh"
  install -m 0755 "$PROJECT_DIR/scripts/udp53-redirect.sh" "$SCRIPTS_DIR/udp53-redirect.sh"
  ln -sf "$SCRIPTS_DIR/menu.sh" /usr/local/bin/slowdns-menu
  ln -sf "$SCRIPTS_DIR/control.sh" /usr/local/bin/slowdns-service
  if [[ ! -e /usr/local/bin/menu ]]; then
    ln -sf "$SCRIPTS_DIR/menu.sh" /usr/local/bin/menu
  elif [[ -L /usr/local/bin/menu ]]; then
    local current_menu=""
    current_menu="$(readlink /usr/local/bin/menu || true)"
    if [[ "$current_menu" == "/opt/slowdns-only/scripts/menu.sh" || "$current_menu" == "/opt/slowdns/scripts/menu.sh" ]]; then
      ln -sf "$SCRIPTS_DIR/menu.sh" /usr/local/bin/menu
    fi
  fi
  if [[ ! -e "$LEGACY_INSTALL_DIR" ]]; then
    ln -s "$INSTALL_DIR" "$LEGACY_INSTALL_DIR"
  fi
}

write_legacy_shims() {
  if [[ -L "$LEGACY_INSTALL_DIR" ]]; then
    return 0
  fi

  mkdir -p "$LEGACY_INSTALL_DIR/scripts"

  cat >"$LEGACY_INSTALL_DIR/scripts/menu.sh" <<'SH'
#!/usr/bin/env bash
exec /opt/slowdns/scripts/menu.sh "$@"
SH

  cat >"$LEGACY_INSTALL_DIR/scripts/control.sh" <<'SH'
#!/usr/bin/env bash
exec /opt/slowdns/scripts/control.sh "$@"
SH

  chmod 0755 "$LEGACY_INSTALL_DIR/scripts/menu.sh" "$LEGACY_INSTALL_DIR/scripts/control.sh"
}

migrate_legacy_state() {
  local legacy_config_dir="$LEGACY_INSTALL_DIR/config"
  [[ -d "$legacy_config_dir" ]] || return 0

  if [[ ! -f "$CONFIG_DIR/slowdns.db" ]]; then
    if [[ -f "$legacy_config_dir/slowdns.db" ]]; then
      cp -f "$legacy_config_dir/slowdns.db" "$CONFIG_DIR/slowdns.db"
    elif [[ -f "$legacy_config_dir/slowdns-only.db" ]]; then
      cp -f "$legacy_config_dir/slowdns-only.db" "$CONFIG_DIR/slowdns.db"
    fi
  fi

  [[ -f "$CONFIG_DIR/server.key" ]] || [[ ! -f "$legacy_config_dir/server.key" ]] || cp -f "$legacy_config_dir/server.key" "$CONFIG_DIR/server.key"
  [[ -f "$CONFIG_DIR/server.pub" ]] || [[ ! -f "$legacy_config_dir/server.pub" ]] || cp -f "$legacy_config_dir/server.pub" "$CONFIG_DIR/server.pub"
}

normalize_go_version() {
  local value="$1"
  local major minor patch
  IFS=. read -r major minor patch <<<"$value"
  major="${major:-0}"
  minor="${minor:-0}"
  patch="${patch:-0}"
  printf '%d' "$((10#$major * 1000000 + 10#$minor * 1000 + 10#$patch))"
}

go_version_from_binary() {
  local binary="$1"
  local version=""
  version="$("$binary" version 2>/dev/null | sed -n 's/^go version go\([0-9][0-9.]*\).*/\1/p' | head -n1)"
  printf '%s' "$version"
}

go_version_ok() {
  local binary="$1"
  local current required current_num required_num
  current="$(go_version_from_binary "$binary")"
  [[ -n "$current" ]] || return 1
  required="$GO_MIN_VERSION"
  current_num="$(normalize_go_version "$current")"
  required_num="$(normalize_go_version "$required")"
  (( current_num >= required_num ))
}

detect_go_archive_name() {
  local arch=""
  case "$(uname -m)" in
    x86_64|amd64)
      arch="amd64"
      ;;
    aarch64|arm64)
      arch="arm64"
      ;;
    *)
      echo "unsupported architecture for Go bootstrap: $(uname -m)" >&2
      exit 1
      ;;
  esac
  printf 'go%s.linux-%s.tar.gz' "$GO_BOOTSTRAP_VERSION" "$arch"
}

bootstrap_go_toolchain() {
  local archive_name archive_url tmpdir archive_path
  archive_name="$(detect_go_archive_name)"
  archive_url="${GO_BOOTSTRAP_BASE_URL}/${archive_name}"
  tmpdir="$(mktemp -d)"
  archive_path="$tmpdir/$archive_name"
  curl -fsSL "$archive_url" -o "$archive_path"
  rm -rf "$TOOLCHAIN_DIR/go"
  mkdir -p "$TOOLCHAIN_DIR"
  tar -xzf "$archive_path" -C "$TOOLCHAIN_DIR"
  GO_CMD="$TOOLCHAIN_DIR/go/bin/go"
  rm -rf "$tmpdir"
}

ensure_go() {
  local local_go system_go
  local_go="$TOOLCHAIN_DIR/go/bin/go"
  if [[ -x "$local_go" ]] && go_version_ok "$local_go"; then
    GO_CMD="$local_go"
    return 0
  fi

  system_go="$(command -v go 2>/dev/null || true)"
  if [[ -n "$system_go" ]] && go_version_ok "$system_go"; then
    GO_CMD="$system_go"
    return 0
  fi

  bootstrap_go_toolchain
  if ! go_version_ok "$GO_CMD"; then
    echo "failed to prepare a Go toolchain >= $GO_MIN_VERSION" >&2
    exit 1
  fi
}

render_config() {
  local hostname public_ip listen_port public_port redirect_53 api_bind api_port mtu zone_prefix ns_prefix local_port ns_host tunnel_domain
  local existing_listen_port existing_public_port existing_redirect existing_api_bind existing_api_port existing_mtu existing_local_port
  hostname="$CONFIG_HOSTNAME"
  tunnel_domain="$CONFIG_TUNNEL_DOMAIN"
  ns_host="$CONFIG_NS_HOST"
  public_ip="$CONFIG_PUBLIC_IP"
  existing_listen_port="$(trim "$(read_existing_config_value slowdns.listen_port)")"
  existing_public_port="$(trim "$(read_existing_config_value slowdns.public_port)")"
  existing_redirect="$(trim "$(read_existing_config_value slowdns.redirect_53)")"
  existing_api_bind="$(trim "$(read_existing_config_value bind)")"
  existing_api_port="$(trim "$(read_existing_config_value port)")"
  existing_mtu="$(trim "$(read_existing_config_value slowdns.mtu)")"
  existing_local_port="$(trim "$(read_existing_config_value slowdns.local_port)")"
  listen_port="${SLOWDNS_LISTEN_PORT:-${existing_listen_port:-5300}}"
  public_port="${SLOWDNS_PUBLIC_PORT:-$existing_public_port}"
  if [[ -z "$public_port" ]]; then
    if [[ "$listen_port" == "53" ]]; then
      public_port="53"
    else
      public_port="53"
    fi
  fi
  redirect_53="${SLOWDNS_REDIRECT_53:-$existing_redirect}"
  if [[ -z "$redirect_53" ]]; then
    if [[ "$public_port" == "53" && "$listen_port" != "53" ]]; then
      redirect_53="true"
    else
      redirect_53="false"
    fi
  fi
  api_bind="${SLOWDNS_API_BIND:-${existing_api_bind:-127.0.0.1}}"
  api_port="${SLOWDNS_API_PORT:-${existing_api_port:-8091}}"
  mtu="${SLOWDNS_MTU:-${existing_mtu:-512}}"
  zone_prefix="${SLOWDNS_ZONE_PREFIX:-}"
  ns_prefix="${SLOWDNS_NS_PREFIX:-}"
  local_port="${SLOWDNS_CLIENT_LOCAL_PORT:-${existing_local_port:-8000}}"

  cat >"$CONFIG_DIR/config.json" <<JSON
{
  "bind": "$api_bind",
  "port": $api_port,
  "db_path": "$CONFIG_DIR/slowdns.db",
  "hostname": "$hostname",
  "public_ip": "$public_ip",
  "city": "",
  "isp": "",
  "ssh": {
    "manage_system_users": true,
    "shell": "/bin/false",
    "ws_path": "/sshws",
    "ports": {
      "any": "22,$public_port",
      "none": "-",
      "ssh": "22",
      "dropbear": "-",
      "ssl": "-",
      "ws": "-",
      "slowdns": "$public_port",
      "squid": "-",
      "hysteria": "-",
      "ovpnohp": "-",
      "ovpntcp": "-",
      "ovpnudp": "-"
    }
  },
  "slowdns": {
    "enabled": true,
    "service": "slowdns-dnstt",
    "listen_port": $listen_port,
    "public_port": $public_port,
    "redirect_53": $redirect_53,
    "local_port": $local_port,
    "target": "127.0.0.1:22",
    "tunnel_domain": "$tunnel_domain",
    "ns_host": "$ns_host",
    "zone_prefix": "$zone_prefix",
    "ns_prefix": "$ns_prefix",
    "mtu": $mtu,
    "public_key_path": "$CONFIG_DIR/server.pub",
    "private_key_path": "$CONFIG_DIR/server.key"
  }
}
JSON
}

build_dnstt() {
  if [[ -x "$BIN_DIR/dnstt-server" && -x "$BIN_DIR/dnstt-client" ]]; then
    return
  fi

  if [[ -n "$DNSTT_SERVER_URL" && -n "$DNSTT_CLIENT_URL" ]]; then
    curl -fsSL "$DNSTT_SERVER_URL" -o "$BIN_DIR/dnstt-server"
    curl -fsSL "$DNSTT_CLIENT_URL" -o "$BIN_DIR/dnstt-client"
    chmod 0755 "$BIN_DIR/dnstt-server" "$BIN_DIR/dnstt-client"
    return
  fi

  ensure_go

  local srcdir
  DNSTT_BUILD_TMPDIR="$(mktemp -d)"
  curl -fsSL "$DNSTT_SOURCE_URL" -o "$DNSTT_BUILD_TMPDIR/dnstt.zip"
  unzip -q "$DNSTT_BUILD_TMPDIR/dnstt.zip" -d "$DNSTT_BUILD_TMPDIR"
  srcdir="$(find "$DNSTT_BUILD_TMPDIR" -maxdepth 1 -type d -name 'dnstt-*' | head -n1)"
  if [[ -z "$srcdir" ]]; then
    echo "failed to unpack dnstt source" >&2
    exit 1
  fi
  (cd "$srcdir/dnstt-server" && "$GO_CMD" build -o "$BIN_DIR/dnstt-server")
  (cd "$srcdir/dnstt-client" && "$GO_CMD" build -o "$BIN_DIR/dnstt-client")
  chmod 0755 "$BIN_DIR/dnstt-server" "$BIN_DIR/dnstt-client"
  rm -rf "$DNSTT_BUILD_TMPDIR"
  DNSTT_BUILD_TMPDIR=""
}

generate_keys() {
  if [[ ! -f "$CONFIG_DIR/server.key" || ! -f "$CONFIG_DIR/server.pub" ]]; then
    "$BIN_DIR/dnstt-server" -gen-key -privkey-file "$CONFIG_DIR/server.key" -pubkey-file "$CONFIG_DIR/server.pub"
    chmod 0600 "$CONFIG_DIR/server.key"
    chmod 0644 "$CONFIG_DIR/server.pub"
  fi
}

write_units() {
  cat >"$SYSTEMD_DIR/slowdns-api.service" <<UNIT
[Unit]
Description=SlowDNS API
After=network-online.target ssh.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/opt/slowdns/scripts/run-api.sh
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT

  cat >"$SYSTEMD_DIR/slowdns-dnstt.service" <<UNIT
[Unit]
Description=SlowDNS dnstt Server
After=network-online.target ssh.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/opt/slowdns/scripts/run-dnstt.sh
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT

  cat >"$SYSTEMD_DIR/slowdns-udp53-redirect.service" <<UNIT
[Unit]
Description=SlowDNS UDP 53 redirect
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/opt/slowdns/scripts/udp53-redirect.sh start
ExecStop=/opt/slowdns/scripts/udp53-redirect.sh stop

[Install]
WantedBy=multi-user.target
UNIT

  cat >"$SYSTEMD_DIR/slowdns-expire-sync.service" <<UNIT
[Unit]
Description=SlowDNS expiry synchronizer
After=slowdns-api.service

[Service]
Type=oneshot
ExecStart=/opt/slowdns/scripts/expire-sync.sh
UNIT

  cat >"$SYSTEMD_DIR/slowdns-expire-sync.timer" <<UNIT
[Unit]
Description=Run SlowDNS expiry sync every 15 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=15min
Unit=slowdns-expire-sync.service

[Install]
WantedBy=timers.target
UNIT
}

cleanup_legacy_units() {
  local units=(
    "slowdns-only-api.service"
    "slowdns-only-dnstt.service"
    "slowdns-only-udp53-redirect.service"
    "slowdns-only-expire-sync.service"
    "slowdns-only-expire-sync.timer"
  )
  local unit
  for unit in "${units[@]}"; do
    systemctl disable --now "$unit" >/dev/null 2>&1 || true
    rm -f "$SYSTEMD_DIR/$unit"
  done
}

start_services() {
  systemctl daemon-reload
  systemctl enable --now slowdns-udp53-redirect.service
  systemctl enable --now slowdns-api.service
  systemctl enable --now slowdns-dnstt.service
  systemctl enable --now slowdns-expire-sync.timer
}

ensure_service_active() {
  local service="$1"
  if ! systemctl is-active --quiet "$service"; then
    echo "service failed to start: $service" >&2
    systemctl status "$service" --no-pager >&2 || true
    exit 1
  fi
}

main() {
  trap cleanup_on_exit EXIT
  require_root
  validate_license_settings
  install_packages
  maybe_reexec_in_screen
  check_installer_version
  license_precheck
  resolve_install_values
  license_activate
  printf '%sPreparing SlowDNS files...%s\n' "$_c_muted" "$_c_reset"
  copy_project
  render_config
  migrate_legacy_state
  write_legacy_shims
  build_dnstt
  generate_keys
  write_units
  cleanup_legacy_units
  printf '%sStarting SlowDNS services...%s\n' "$_c_muted" "$_c_reset"
  start_services
  ensure_service_active slowdns-udp53-redirect.service
  ensure_service_active slowdns-api.service
  ensure_service_active slowdns-dnstt.service
  license_confirm
  write_license_metadata
  printf '\n%s============================================================%s\n' "$_c_green" "$_c_reset"
  printf '%s SlowDNS installed successfully%s\n' "$_c_green$_c_bold" "$_c_reset"
  printf '%s============================================================%s\n' "$_c_green" "$_c_reset"
  printf '  Installed at:  %s\n' "$INSTALL_DIR"
  printf '  API status:    %ssystemctl status slowdns-api%s\n' "$_c_cyan" "$_c_reset"
  printf '  dnstt status:  %ssystemctl status slowdns-dnstt%s\n' "$_c_cyan" "$_c_reset"
  printf '  Menu:          %sslowdns-menu%s\n' "$_c_cyan" "$_c_reset"
  if [[ "$LICENSE_CONFIRMED" == "true" ]]; then
    printf '  Install code:  %s%s%s activated via %s\n' "$_c_yellow" "${INSTALL_CODE_HINT}" "$_c_reset" "${LICENSE_URL}"
  fi
  printf '\n'
}

main "$@"
