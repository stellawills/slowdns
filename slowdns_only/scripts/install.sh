#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALL_DIR="/opt/slowdns-only"
CONFIG_DIR="$INSTALL_DIR/config"
BIN_DIR="$INSTALL_DIR/bin"
API_DIR="$INSTALL_DIR/api"
SCRIPTS_DIR="$INSTALL_DIR/scripts"
LOG_DIR="$INSTALL_DIR/logs"
SYSTEMD_DIR="/etc/systemd/system"

DNSTT_SOURCE_URL="${DNSTT_SOURCE_URL:-https://www.bamsoftware.com/software/dnstt/dnstt-20241021.zip}"
DNSTT_SERVER_URL="${DNSTT_SERVER_URL:-}"
DNSTT_CLIENT_URL="${DNSTT_CLIENT_URL:-}"

# ── License / Activation ─────────────────────────────────────────
INSTALLER_VERSION="${INSTALLER_VERSION:-2026.03.30}"
DEFAULT_LICENSE_URL="${DEFAULT_LICENSE_URL:-https://license.internetshub.com}"
LICENSE_URL="${SLOWDNS_LICENSE_URL:-$DEFAULT_LICENSE_URL}"
LICENSE_PRODUCT="${SLOWDNS_LICENSE_PRODUCT:-slowdns}"
INSTALL_CODE="${SLOWDNS_INSTALL_CODE:-${SLOWDNS_LICENSE_KEY:-}}"
LICENSE_PAGE_URL="${SLOWDNS_LICENSE_PAGE_URL:-${LICENSE_URL%/}/slowdns}"
LICENSE_METADATA_PATH="$CONFIG_DIR/license.json"
LICENSE_ACTIVATION_ID=""
LICENSE_INSTALL_TOKEN=""
INSTALL_CODE_HINT=""
LICENSE_CONFIRMED="false"
LICENSE_BANNER_SHOWN="false"
LICENSE_LAST_HTTP_STATUS=""
LICENSE_LAST_ERROR_CODE=""
LICENSE_LAST_ERROR_MESSAGE=""
CONFIG_HOSTNAME=""
CONFIG_PUBLIC_IP=""

# ── Utilities ────────────────────────────────────────────────────

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
  [[ -z "$title" ]] && return 0
  printf '\n============================================================\n'
  printf ' %s\n' "$title"
  printf '============================================================\n'
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "run as root" >&2
    exit 1
  fi
}

# ── Package install ──────────────────────────────────────────────

install_packages() {
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y python3 curl unzip openssh-server ca-certificates
    if ! command -v go >/dev/null 2>&1; then
      apt-get install -y golang-go
    fi
  fi
}

# ── Detection helpers ────────────────────────────────────────────

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

# ── License error parsers ────────────────────────────────────────

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
    "validation_error": message or "Install code was invalid.",
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

# ── JSON query helper ────────────────────────────────────────────

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

# ── License HTTP helper ──────────────────────────────────────────

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

# ── License UI ───────────────────────────────────────────────────

show_license_banner() {
  if [[ "$LICENSE_BANNER_SHOWN" == "true" ]]; then
    return 0
  fi
  LICENSE_BANNER_SHOWN="true"
  print_section "SlowDNS Install Code"
  printf ' Generate code at: %s\n' "$LICENSE_PAGE_URL"
  printf ' This code is single-use and expires quickly.\n\n'
}

license_prompt_key() {
  if [[ -n "$INSTALL_CODE" ]]; then
    if [[ -n "${SLOWDNS_INSTALL_CODE:-${SLOWDNS_LICENSE_KEY:-}}" ]]; then
      show_license_banner
      printf ' Using install code from environment.\n'
    fi
    return 0
  fi
  if [[ ! -t 0 ]]; then
    echo "SLOWDNS_INSTALL_CODE is required in non-interactive mode." >&2
    exit 1
  fi
  show_license_banner
  while true; do
    read -r -p "SlowDNS install code: " INSTALL_CODE
    INSTALL_CODE="$(trim "$INSTALL_CODE")"
    [[ -n "$INSTALL_CODE" ]] && break
    echo "A value is required." >&2
  done
}

validate_license_settings() {
  if [[ -z "$LICENSE_URL" ]]; then
    echo "SLOWDNS_LICENSE_URL is required for SlowDNS install-code activation." >&2
    exit 1
  fi
}

# ── License activate / confirm / release ────────────────────────

license_activate() {
  local machine_id ssh_fingerprint payload response _resp_tmp _resp_rc

  machine_id="$(detect_machine_id)"
  ssh_fingerprint="$(detect_ssh_fingerprint)"

  while true; do
    license_prompt_key
    printf 'Validating install code...\n'

    payload="$(python3 - "$INSTALL_CODE" "$LICENSE_PRODUCT" "$CONFIG_HOSTNAME" "$CONFIG_PUBLIC_IP" "$machine_id" "$ssh_fingerprint" "$INSTALLER_VERSION" <<'PY'
import json
import sys

payload = {
    "install_code": sys.argv[1].strip().upper(),
    "license_key": sys.argv[1].strip().upper(),
    "product": sys.argv[2].strip().lower(),
    "hostname": sys.argv[3].strip().lower(),
    "public_ip": sys.argv[4].strip(),
    "machine_id": sys.argv[5].strip(),
    "ssh_fingerprint": sys.argv[6].strip(),
    "requested_ref": "main",
    "installer_version": sys.argv[7].strip(),
}
print(json.dumps(payload, separators=(",", ":")))
PY
)"

    # Call license_post_json without command substitution so that
    # LICENSE_LAST_* variables are set in the current shell, not a subshell.
    _resp_tmp="$(mktemp)"
    _resp_rc=0
    license_post_json "/api/v2/slowdns/install/activate" "$payload" > "$_resp_tmp" || _resp_rc=$?
    response="$(cat "$_resp_tmp")"
    rm -f "$_resp_tmp"

    if [[ "$_resp_rc" -ne 0 ]]; then
      [[ -n "$LICENSE_LAST_ERROR_MESSAGE" ]] && echo "$LICENSE_LAST_ERROR_MESSAGE" >&2
      if [[ -n "$LICENSE_LAST_HTTP_STATUS" ]]; then
        echo "License request failed with HTTP $LICENSE_LAST_HTTP_STATUS." >&2
      fi
      if [[ -t 0 ]]; then
        case "$LICENSE_LAST_ERROR_CODE" in
          install_code_used|install_code_expired|install_code_not_found|validation_error|network_error)
            echo "Try again with a fresh SlowDNS install code." >&2
            INSTALL_CODE=""
            continue
            ;;
        esac
      fi
      exit 1
    fi

    LICENSE_ACTIVATION_ID="$(printf '%s' "$response" | json_query "data.activation_id" 2>/dev/null || true)"
    LICENSE_INSTALL_TOKEN="$(printf '%s' "$response" | json_query "data.install_token" 2>/dev/null || true)"
    INSTALL_CODE_HINT="$(printf '%s' "$response" | json_query "data.install_code" 2>/dev/null || true)"
    if [[ -z "$LICENSE_ACTIVATION_ID" || -z "$LICENSE_INSTALL_TOKEN" ]]; then
      echo "License server returned an invalid activation response." >&2
      if [[ -t 0 ]]; then
        echo "Try again with a fresh SlowDNS install code." >&2
        INSTALL_CODE=""
        continue
      fi
      exit 1
    fi
    printf 'Install code accepted. Continuing setup...\n'
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
  printf 'Confirming activation...\n'
  _resp_tmp="$(mktemp)"
  _resp_rc=0
  license_post_json "/api/v2/slowdns/install/confirm" "$payload" > "$_resp_tmp" || _resp_rc=$?
  response="$(cat "$_resp_tmp")"
  rm -f "$_resp_tmp"
  if [[ "$_resp_rc" -ne 0 ]]; then
    [[ -n "$LICENSE_LAST_ERROR_MESSAGE" ]] && echo "$LICENSE_LAST_ERROR_MESSAGE" >&2
    if [[ -n "$LICENSE_LAST_HTTP_STATUS" ]]; then
      echo "License request failed with HTTP $LICENSE_LAST_HTTP_STATUS." >&2
    fi
    exit 1
  fi
  if ! printf '%s' "$response" | json_query "data.status" >/dev/null 2>&1; then
    echo "License server returned an invalid confirmation response." >&2
    exit 1
  fi
  LICENSE_CONFIRMED="true"
  printf 'Activation confirmed.\n'
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
  if [[ "$code" -ne 0 ]]; then
    license_release
  fi
}

# ── Project files ────────────────────────────────────────────────

copy_project() {
  mkdir -p "$BIN_DIR" "$CONFIG_DIR" "$API_DIR" "$SCRIPTS_DIR" "$LOG_DIR"
  install -m 0755 "$PROJECT_DIR/api/slowdns_only_api.py" "$API_DIR/slowdns_only_api.py"
  install -m 0755 "$PROJECT_DIR/scripts/run-api.sh" "$SCRIPTS_DIR/run-api.sh"
  install -m 0755 "$PROJECT_DIR/scripts/run-dnstt.sh" "$SCRIPTS_DIR/run-dnstt.sh"
  install -m 0755 "$PROJECT_DIR/scripts/control.sh" "$SCRIPTS_DIR/control.sh"
  install -m 0755 "$PROJECT_DIR/scripts/expire-sync.sh" "$SCRIPTS_DIR/expire-sync.sh"
}

render_config() {
  local listen_port api_bind api_port mtu zone_prefix ns_prefix local_port
  listen_port="${SLOWDNS_LISTEN_PORT:-53}"
  api_bind="${SLOWDNS_API_BIND:-127.0.0.1}"
  api_port="${SLOWDNS_API_PORT:-8091}"
  mtu="${SLOWDNS_MTU:-512}"
  zone_prefix="${SLOWDNS_ZONE_PREFIX:-dns}"
  ns_prefix="${SLOWDNS_NS_PREFIX:-}"
  local_port="${SLOWDNS_CLIENT_LOCAL_PORT:-8000}"

  if [[ ! -f "$CONFIG_DIR/config.json" ]]; then
    cat >"$CONFIG_DIR/config.json" <<JSON
{
  "bind": "$api_bind",
  "port": $api_port,
  "db_path": "$CONFIG_DIR/slowdns-only.db",
  "hostname": "$CONFIG_HOSTNAME",
  "public_ip": "$CONFIG_PUBLIC_IP",
  "city": "",
  "isp": "",
  "ssh": {
    "manage_system_users": true,
    "shell": "/bin/false",
    "ws_path": "/sshws",
    "ports": {
      "any": "22,$listen_port",
      "none": "-",
      "ssh": "22",
      "dropbear": "-",
      "ssl": "-",
      "ws": "-",
      "slowdns": "$listen_port",
      "squid": "-",
      "hysteria": "-",
      "ovpnohp": "-",
      "ovpntcp": "-",
      "ovpnudp": "-"
    }
  },
  "slowdns": {
    "enabled": true,
    "service": "slowdns-only-dnstt",
    "listen_port": $listen_port,
    "local_port": $local_port,
    "target": "127.0.0.1:22",
    "zone_prefix": "$zone_prefix",
    "ns_prefix": "$ns_prefix",
    "mtu": $mtu,
    "public_key_path": "$CONFIG_DIR/server.pub",
    "private_key_path": "$CONFIG_DIR/server.key"
  }
}
JSON
  fi
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

  if ! command -v go >/dev/null 2>&1; then
    echo "go is required to build dnstt" >&2
    exit 1
  fi

  local tmpdir srcdir
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' EXIT
  curl -fsSL "$DNSTT_SOURCE_URL" -o "$tmpdir/dnstt.zip"
  unzip -q "$tmpdir/dnstt.zip" -d "$tmpdir"
  srcdir="$(find "$tmpdir" -maxdepth 1 -type d -name 'dnstt-*' | head -n1)"
  if [[ -z "$srcdir" ]]; then
    echo "failed to unpack dnstt source" >&2
    exit 1
  fi
  (cd "$srcdir/dnstt-server" && go build -o "$BIN_DIR/dnstt-server")
  (cd "$srcdir/dnstt-client" && go build -o "$BIN_DIR/dnstt-client")
  chmod 0755 "$BIN_DIR/dnstt-server" "$BIN_DIR/dnstt-client"
}

generate_keys() {
  if [[ ! -f "$CONFIG_DIR/server.key" || ! -f "$CONFIG_DIR/server.pub" ]]; then
    "$BIN_DIR/dnstt-server" -gen-key -privkey-file "$CONFIG_DIR/server.key" -pubkey-file "$CONFIG_DIR/server.pub"
    chmod 0600 "$CONFIG_DIR/server.key"
    chmod 0644 "$CONFIG_DIR/server.pub"
  fi
}

write_units() {
  cat >"$SYSTEMD_DIR/slowdns-only-api.service" <<UNIT
[Unit]
Description=SlowDNS Only API
After=network-online.target ssh.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/opt/slowdns-only/scripts/run-api.sh
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT

  cat >"$SYSTEMD_DIR/slowdns-only-dnstt.service" <<UNIT
[Unit]
Description=SlowDNS Only dnstt Server
After=network-online.target ssh.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/opt/slowdns-only/scripts/run-dnstt.sh
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT

  cat >"$SYSTEMD_DIR/slowdns-only-expire-sync.service" <<UNIT
[Unit]
Description=SlowDNS Only expiry synchronizer
After=slowdns-only-api.service

[Service]
Type=oneshot
ExecStart=/opt/slowdns-only/scripts/expire-sync.sh
UNIT

  cat >"$SYSTEMD_DIR/slowdns-only-expire-sync.timer" <<UNIT
[Unit]
Description=Run SlowDNS Only expiry sync every 15 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=15min
Unit=slowdns-only-expire-sync.service

[Install]
WantedBy=timers.target
UNIT
}

start_services() {
  systemctl daemon-reload
  systemctl enable --now slowdns-only-api.service
  systemctl enable --now slowdns-only-dnstt.service
  systemctl enable --now slowdns-only-expire-sync.timer
}

main() {
  trap cleanup_on_exit EXIT
  require_root
  validate_license_settings
  install_packages
  CONFIG_HOSTNAME="$(trim "$(detect_hostname)")"
  CONFIG_PUBLIC_IP="$(trim "$(detect_public_ip)")"
  license_prompt_key
  license_activate
  printf 'Preparing SlowDNS files...\n'
  copy_project
  render_config
  build_dnstt
  generate_keys
  write_units
  start_services
  license_confirm
  write_license_metadata
  echo "slowdns-only installed under $INSTALL_DIR"
  echo "api: systemctl status slowdns-only-api"
  echo "dnstt: systemctl status slowdns-only-dnstt"
  if [[ "$LICENSE_CONFIRMED" == "true" ]]; then
    echo "install code: ${INSTALL_CODE_HINT} activated via ${LICENSE_URL}"
  fi
}

main "$@"
