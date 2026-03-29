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
    apt-get install -y python3 curl unzip openssh-server ca-certificates
    if ! command -v go >/dev/null 2>&1; then
      apt-get install -y golang-go
    fi
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

copy_project() {
  mkdir -p "$BIN_DIR" "$CONFIG_DIR" "$API_DIR" "$SCRIPTS_DIR" "$LOG_DIR"
  install -m 0755 "$PROJECT_DIR/api/slowdns_only_api.py" "$API_DIR/slowdns_only_api.py"
  install -m 0755 "$PROJECT_DIR/scripts/run-api.sh" "$SCRIPTS_DIR/run-api.sh"
  install -m 0755 "$PROJECT_DIR/scripts/run-dnstt.sh" "$SCRIPTS_DIR/run-dnstt.sh"
  install -m 0755 "$PROJECT_DIR/scripts/control.sh" "$SCRIPTS_DIR/control.sh"
  install -m 0755 "$PROJECT_DIR/scripts/expire-sync.sh" "$SCRIPTS_DIR/expire-sync.sh"
  install -m 0755 "$PROJECT_DIR/scripts/menu.sh" "$SCRIPTS_DIR/menu.sh"
  ln -sf "$SCRIPTS_DIR/menu.sh" /usr/local/bin/slowdns-menu
  ln -sf "$SCRIPTS_DIR/control.sh" /usr/local/bin/slowdns-service
}

render_config() {
  local hostname public_ip listen_port api_bind api_port mtu zone_prefix ns_prefix local_port
  hostname="$(detect_hostname)"
  public_ip="$(detect_public_ip)"
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
  require_root
  install_packages
  copy_project
  render_config
  build_dnstt
  generate_keys
  write_units
  start_services
  echo "slowdns-only installed under $INSTALL_DIR"
  echo "api: systemctl status slowdns-only-api"
  echo "dnstt: systemctl status slowdns-only-dnstt"
  echo "menu: slowdns-menu"
}

main "$@"
