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
TOOLCHAIN_DIR="$INSTALL_DIR/toolchain"
SYSTEMD_DIR="/etc/systemd/system"

DNSTT_SOURCE_URL="${DNSTT_SOURCE_URL:-https://www.bamsoftware.com/software/dnstt/dnstt-20241021.zip}"
DNSTT_SERVER_URL="${DNSTT_SERVER_URL:-}"
DNSTT_CLIENT_URL="${DNSTT_CLIENT_URL:-}"
GO_MIN_VERSION="${GO_MIN_VERSION:-1.21.0}"
GO_BOOTSTRAP_VERSION="${GO_BOOTSTRAP_VERSION:-1.22.12}"
GO_BOOTSTRAP_BASE_URL="${GO_BOOTSTRAP_BASE_URL:-https://go.dev/dl}"
CONFIG_HOSTNAME=""
CONFIG_PUBLIC_IP=""
CONFIG_NS_HOST=""
GO_CMD=""

trim() {
  local value="${1:-}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
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
  if [[ ! -f "$path" ]]; then
    return 0
  fi
  python3 - "$path" "$key" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
key = sys.argv[2]
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
print(str(value))
PY
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
    apt-get install -y python3 curl unzip tar openssh-server ca-certificates
  fi
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

resolve_install_values() {
  local detected_host existing_host existing_tunnel_domain host_default
  local existing_ns_host ns_default
  local detected_ip existing_ip ip_default

  mkdir -p "$CONFIG_DIR"

  detected_host="$(trim "$(detect_hostname)")"
  existing_host="$(trim "$(read_existing_config_value hostname)")"
  existing_tunnel_domain="$(trim "$(read_existing_config_value slowdns.tunnel_domain)")"
  existing_ns_host="$(trim "$(read_existing_config_value slowdns.ns_host)")"
  detected_ip="$(trim "$(detect_public_ip)")"
  existing_ip="$(trim "$(read_existing_config_value public_ip)")"

  host_default="${SLOWDNS_TUNNEL_DOMAIN:-${SLOWDNS_HOSTNAME:-$existing_tunnel_domain}}"
  if [[ -z "$host_default" ]]; then
    host_default="$existing_host"
  fi
  if [[ -z "$host_default" || "$host_default" == "localhost" ]]; then
    if [[ -n "$detected_host" && "$detected_host" != "localhost" ]]; then
      host_default="$detected_host"
    else
      host_default=""
    fi
  fi

  if [[ -t 0 ]]; then
    prompt_required CONFIG_HOSTNAME "SlowDNS tunnel domain" "$host_default"
  else
    if [[ -z "$host_default" ]]; then
      echo "SlowDNS tunnel domain is required in non-interactive mode. Pass SLOWDNS_TUNNEL_DOMAIN or SLOWDNS_HOSTNAME." >&2
      exit 1
    fi
    CONFIG_HOSTNAME="$host_default"
  fi

  ns_default="${SLOWDNS_NS_HOST:-$existing_ns_host}"
  if [[ -z "$ns_default" ]]; then
    ns_default="$CONFIG_HOSTNAME"
  fi
  if [[ -t 0 ]]; then
    prompt_required CONFIG_NS_HOST "SlowDNS nameserver host" "$ns_default"
  else
    CONFIG_NS_HOST="$ns_default"
  fi

  ip_default="${SLOWDNS_PUBLIC_IP:-$existing_ip}"
  if [[ -z "$ip_default" ]]; then
    ip_default="$detected_ip"
  fi
  prompt_public_ip "$ip_default"
}

copy_project() {
  mkdir -p "$BIN_DIR" "$CONFIG_DIR" "$API_DIR" "$SCRIPTS_DIR" "$LOG_DIR" "$TOOLCHAIN_DIR"
  install -m 0755 "$PROJECT_DIR/api/slowdns_only_api.py" "$API_DIR/slowdns_only_api.py"
  install -m 0755 "$PROJECT_DIR/scripts/run-api.sh" "$SCRIPTS_DIR/run-api.sh"
  install -m 0755 "$PROJECT_DIR/scripts/run-dnstt.sh" "$SCRIPTS_DIR/run-dnstt.sh"
  install -m 0755 "$PROJECT_DIR/scripts/control.sh" "$SCRIPTS_DIR/control.sh"
  install -m 0755 "$PROJECT_DIR/scripts/expire-sync.sh" "$SCRIPTS_DIR/expire-sync.sh"
  install -m 0755 "$PROJECT_DIR/scripts/menu.sh" "$SCRIPTS_DIR/menu.sh"
  ln -sf "$SCRIPTS_DIR/menu.sh" /usr/local/bin/slowdns-menu
  ln -sf "$SCRIPTS_DIR/control.sh" /usr/local/bin/slowdns-service
  if ! command -v menu >/dev/null 2>&1; then
    ln -sf "$SCRIPTS_DIR/menu.sh" /usr/local/bin/menu
  fi
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
  local hostname public_ip listen_port api_bind api_port mtu zone_prefix ns_prefix local_port ns_host tunnel_domain
  hostname="$CONFIG_HOSTNAME"
  tunnel_domain="$CONFIG_HOSTNAME"
  ns_host="$CONFIG_NS_HOST"
  public_ip="$CONFIG_PUBLIC_IP"
  listen_port="${SLOWDNS_LISTEN_PORT:-53}"
  api_bind="${SLOWDNS_API_BIND:-127.0.0.1}"
  api_port="${SLOWDNS_API_PORT:-8091}"
  mtu="${SLOWDNS_MTU:-512}"
  zone_prefix="${SLOWDNS_ZONE_PREFIX:-}"
  ns_prefix="${SLOWDNS_NS_PREFIX:-}"
  local_port="${SLOWDNS_CLIENT_LOCAL_PORT:-8000}"

  cat >"$CONFIG_DIR/config.json" <<JSON
{
  "bind": "$api_bind",
  "port": $api_port,
  "db_path": "$CONFIG_DIR/slowdns-only.db",
  "hostname": "$hostname",
  "public_ip": "$public_ip",
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
  (cd "$srcdir/dnstt-server" && "$GO_CMD" build -o "$BIN_DIR/dnstt-server")
  (cd "$srcdir/dnstt-client" && "$GO_CMD" build -o "$BIN_DIR/dnstt-client")
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

ensure_service_active() {
  local service="$1"
  if ! systemctl is-active --quiet "$service"; then
    echo "service failed to start: $service" >&2
    systemctl status "$service" --no-pager >&2 || true
    exit 1
  fi
}

main() {
  require_root
  install_packages
  resolve_install_values
  copy_project
  render_config
  build_dnstt
  generate_keys
  write_units
  start_services
  ensure_service_active slowdns-only-api.service
  ensure_service_active slowdns-only-dnstt.service
  echo "slowdns-only installed under $INSTALL_DIR"
  echo "api: systemctl status slowdns-only-api"
  echo "dnstt: systemctl status slowdns-only-dnstt"
  echo "menu: slowdns-menu"
}

main "$@"
