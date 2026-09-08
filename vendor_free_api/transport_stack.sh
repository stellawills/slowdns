#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-install}"
CONFIG_PATH="${IPTUNNEL_CONFIG_PATH:-/etc/iptunnel/config.json}"
DOMAIN="${IPTUNNEL_DOMAIN:-}"
PUBLIC_IP="${IPTUNNEL_PUBLIC_IP:-}"
CERT_DIR="${IPTUNNEL_CERT_DIR:-/usr/sbin/iptunnel/cert}"
API_PORT="${IPTUNNEL_API_PORT:-8080}"
INSTALL_NGINX="${IPTUNNEL_INSTALL_NGINX:-1}"
IPTUNNEL_ENABLE_HYSTERIA_SET="${IPTUNNEL_ENABLE_HYSTERIA+x}"
IPTUNNEL_ENABLE_OPENVPN_SET="${IPTUNNEL_ENABLE_OPENVPN+x}"
ENABLE_HYSTERIA="${IPTUNNEL_ENABLE_HYSTERIA:-0}"
ENABLE_OPENVPN="${IPTUNNEL_ENABLE_OPENVPN:-0}"

XRAY_DIR="/etc/iptunnel/xray"
XRAY_LOG_DIR="/var/log/iptunnel/xray"
WEB_ROOT="/var/www/html"
OPENVPN_EASYRSA_DIR="/etc/openvpn/easy-rsa"
OPENVPN_SERVER_DIR="/etc/openvpn/server"
OPENVPN_CIPHER="AES-192-CBC"
OPENVPN_TLS_CIPHER="TLS-DHE-RSA-WITH-AES-256-CBC-SHA256"
OPENVPN_AUTH_DIGEST="SHA512"
HYSTERIA_DIR="/etc/hysteria"
HYSTERIA_INFO_FILE="${WEB_ROOT}/hysteria-info.txt"
HYSTERIA_PORT="${IPTUNNEL_HYSTERIA_PORT:-5666}"
HYSTERIA_PROTOCOL="udp"
HYSTERIA_CA_CERT="${HYSTERIA_DIR}/hysteria.ca.crt"
HYSTERIA_PUBLIC_CA="${WEB_ROOT}/hysteria.ca.crt"
HYSTERIA_SERVICE="iptunnel-hysteria"
HYSTERIA_VENDOR_SERVICE="hysteria-server"
HYSTERIA_VENDOR_SCRIPT="/opt/iptunnel/hysteria_vendor.sh"
HYSTERIA_LEGACY_SYSCTL="/etc/sysctl.d/99-iptunnel-hysteria.conf"
HYSTERIA_OBFS="${IPTUNNEL_HYSTERIA_OBFS:-}"
HYSTERIA_PASSWORD="${IPTUNNEL_HYSTERIA_PASSWORD:-}"
HYSTERIA_HOP_RANGE="10000:65000"
SLOWDNS_DIR="/etc/iptunnel/slowdns"
SLOWDNS_ENV="${SLOWDNS_DIR}/slowdns.env"
SLOWDNS_PUBLIC_KEY="${SLOWDNS_DIR}/server.pub"
SLOWDNS_PRIVATE_KEY="${SLOWDNS_DIR}/server.key"
SLOWDNS_INFO_FILE="${WEB_ROOT}/slowdns-info.txt"
SLOWDNS_ZONE=""
SLOWDNS_NS_HOST=""
SLOWDNS_PUBLIC_HOSTNAME="${IPTUNNEL_SLOWDNS_PUBLIC_HOSTNAME:-}"
SLOWDNS_TUNNEL_DOMAIN="${IPTUNNEL_SLOWDNS_TUNNEL_DOMAIN:-}"
SLOWDNS_LISTEN_UDP=":5300"
SLOWDNS_INTERNAL_PORT="5300"
SLOWDNS_PUBLIC_PORT="53"
SLOWDNS_LOCAL_PORT="8000"
SLOWDNS_TARGET_PROXY_PORT="111"
SLOWDNS_TARGET_REAL_DEST="127.0.0.1:22"
SLOWDNS_TARGET="${IPTUNNEL_SLOWDNS_TARGET:-${SLOWDNS_TARGET_REAL_DEST}}"
SLOWDNS_TARGET_PROXY_SERVICE="iptunnel-slowdns-target"
SLOWDNS_UDP53_MODE="${IPTUNNEL_SLOWDNS_UDP53_MODE:-slowdns}"
SLOWDNS_DEFAULT_MTU="1232"
SLOWDNS_MTU="${IPTUNNEL_SLOWDNS_MTU:-}"
SLOWDNS_SERVER_URL="${IPTUNNEL_SLOWDNS_SERVER_URL:-}"
SLOWDNS_CLIENT_URL="${IPTUNNEL_SLOWDNS_CLIENT_URL:-}"
SLOWDNS_API_KEY="${IPTUNNEL_SLOWDNS_API_KEY:-}"
SLOWDNS_DNSTT_REF="${IPTUNNEL_SLOWDNS_DNSTT_REF:-}"
SLOWDNS_DNSTT_SNAPSHOT_URL="${IPTUNNEL_SLOWDNS_DNSTT_SNAPSHOT_URL:-https://www.bamsoftware.com/software/dnstt/dnstt-20241021.zip}"
GO_TOOLCHAIN_BOOTSTRAP_STATE="not-attempted"
UDP53_MUX_SCRIPT="/opt/iptunnel/udp53_mux.py"
UDP53_MUX_ENV="/etc/iptunnel/udp53-mux.env"
UDP53_MUX_SERVICE="iptunnel-udp53-mux"
UDP53_LISTEN_HOST="${IPTUNNEL_UDP53_LISTEN_HOST:-0.0.0.0}"
SSH_WS_PATH="/sshws"
SSH_WS_PATH_ALIASES="${IPTUNNEL_SSH_WS_PATH_ALIASES:-}"
SSH_WS_PATHS_CSV=""
SSH_WS_LOCAL_PORT="19080"
SSH_WS_SCRIPT="/opt/iptunnel/ssh_ws_bridge.py"
EDGE_PROXY_LOCAL_PORT="${IPTUNNEL_EDGE_PROXY_LOCAL_PORT:-700}"
EDGE_PROXY_SCRIPT="/opt/iptunnel/edge_proxy.py"
EDGE_PROXY_SERVICE="iptunnel-edge-proxy"
FRONTING_PROXY_LOCAL_PORT="${IPTUNNEL_FRONTING_PROXY_LOCAL_PORT:-701}"
FRONTING_PROXY_SCRIPT="/opt/iptunnel/fronting_proxy.py"
FRONTING_PROXY_SERVICE="iptunnel-fronting-proxy"
SSH_SSL_CONFIG="/etc/stunnel/iptunnel-ssh.conf"
SSH_SSL_PEM="${CERT_DIR}/stunnel.pem"
SSH_SSL_PUBLIC_8443="0.0.0.0:8443"
SSH_SSL_PUBLIC_2083="0.0.0.0:2083"
NGINX_HTTP_LOCAL_PORT="${IPTUNNEL_NGINX_HTTP_LOCAL_PORT:-8880}"
NGINX_TLS_LOCAL_PORT="${IPTUNNEL_NGINX_TLS_LOCAL_PORT:-9443}"
HAPROXY_INTERNAL_DECRYPT_PORT="${IPTUNNEL_HAPROXY_INTERNAL_DECRYPT_PORT:-10443}"
OPENVPN_UDP_INTERNAL_PORT="25000"
OPENVPN_UDP_PUBLIC_PORT="53"
OPENVPN_UDP_PUBLIC_PORTS="${IPTUNNEL_OPENVPN_UDP_PUBLIC_PORTS:-}"
OPENVPN_UDP_PREVIOUS_PORTS="${IPTUNNEL_OPENVPN_UDP_PREVIOUS_PORTS:-}"
DROPBEAR_VERSION="2019.78"
MAIN_IFACE="$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')"

xr_bin=""
go_bin=""

config_get() {
  local field="$1"
  python3 - "$CONFIG_PATH" "$field" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
field = sys.argv[2]
if not path.exists():
    raise SystemExit(0)

try:
    config = json.loads(path.read_text(encoding="utf-8"))
except Exception:
    raise SystemExit(0)

value = config
for part in field.split("."):
    if isinstance(value, dict):
        value = value.get(part)
    else:
        value = None
        break

if value is None:
    raise SystemExit(0)
if isinstance(value, list):
    print(",".join(str(item) for item in value if item is not None))
elif isinstance(value, bool):
    print("true" if value else "false")
else:
    print(value)
PY
}

normalize_udp_port_csv() {
  local raw="${1:-}"
  local item=""
  local normalized=""
  local -a items=()
  IFS=',' read -r -a items <<< "${raw}"
  for item in "${items[@]}"; do
    item="${item//[[:space:]]/}"
    [[ "${item}" =~ ^[0-9]+$ ]] || continue
    (( item >= 1 && item <= 65535 )) || continue
    case ",${normalized}," in
      *",${item},"*) ;;
      *) normalized="${normalized:+${normalized},}${item}" ;;
    esac
  done
  printf '%s' "${normalized}"
}

udp_port_csv_has() {
  local ports=",$(normalize_udp_port_csv "${1:-}"),"
  local port="${2:-}"
  [[ "${ports}" == *",${port},"* ]]
}

udp_port_csv_add() {
  local ports=""
  ports="$(normalize_udp_port_csv "${1:-}")"
  if ! udp_port_csv_has "${ports}" "${2:-}"; then
    ports="${ports:+${ports},}${2:-}"
  fi
  normalize_udp_port_csv "${ports}"
}

udp_port_csv_remove() {
  local raw="${1:-}"
  local remove_port="${2:-}"
  local item=""
  local result=""
  local -a items=()
  IFS=',' read -r -a items <<< "$(normalize_udp_port_csv "${raw}")"
  for item in "${items[@]}"; do
    [[ "${item}" == "${remove_port}" ]] && continue
    result="${result:+${result},}${item}"
  done
  printf '%s' "${result}"
}

refresh_openvpn_primary_port() {
  local remaining_ports=""
  OPENVPN_UDP_PUBLIC_PORTS="$(normalize_udp_port_csv "${OPENVPN_UDP_PUBLIC_PORTS}")"
  if udp_port_csv_has "${OPENVPN_UDP_PUBLIC_PORTS}" "53"; then
    remaining_ports="$(udp_port_csv_remove "${OPENVPN_UDP_PUBLIC_PORTS}" "53")"
    OPENVPN_UDP_PUBLIC_PORTS="53${remaining_ports:+,${remaining_ports}}"
    OPENVPN_UDP_PUBLIC_PORT="53"
  elif [[ -n "${OPENVPN_UDP_PUBLIC_PORTS}" ]]; then
    OPENVPN_UDP_PUBLIC_PORT="${OPENVPN_UDP_PUBLIC_PORTS%%,*}"
  else
    OPENVPN_UDP_PUBLIC_PORT="53"
  fi
}

reconcile_openvpn_ports_with_udp53_mode() {
  case "$(normalize_udp53_mode "${SLOWDNS_UDP53_MODE}")" in
    openvpn|shared)
      OPENVPN_UDP_PUBLIC_PORTS="$(udp_port_csv_add "${OPENVPN_UDP_PUBLIC_PORTS}" "53")"
      ;;
    *)
      OPENVPN_UDP_PUBLIC_PORTS="$(udp_port_csv_remove "${OPENVPN_UDP_PUBLIC_PORTS}" "53")"
      ;;
  esac
  refresh_openvpn_primary_port
}

load_runtime_context() {
  local configured_public_hostname="" configured_tunnel_domain=""
  local configured_ws_path="" configured_ws_aliases=""
  local configured_ns_prefix="" configured_zone_prefix=""
  local configured_mtu="" configured_target="" configured_udp53_mode="" configured_openvpn_udp_public_port=""
  local configured_openvpn_udp_public_ports=""
  if [[ -z "${DOMAIN}" ]]; then
    DOMAIN="$(config_get hostname)"
  fi
  if [[ -z "${PUBLIC_IP}" ]]; then
    PUBLIC_IP="$(config_get public_ip)"
  fi
  if [[ -z "${SLOWDNS_PUBLIC_HOSTNAME}" ]]; then
    configured_public_hostname="$(config_get slowdns.public_hostname || true)"
    SLOWDNS_PUBLIC_HOSTNAME="${configured_public_hostname}"
  fi
  if [[ -z "${SLOWDNS_TUNNEL_DOMAIN}" ]]; then
    configured_tunnel_domain="$(config_get slowdns.tunnel_domain || true)"
    SLOWDNS_TUNNEL_DOMAIN="${configured_tunnel_domain}"
  fi
  configured_ns_prefix="$(config_get slowdns.ns_prefix || true)"
  configured_zone_prefix="$(config_get slowdns.zone_prefix || true)"
  configured_mtu="$(config_get slowdns.mtu || true)"
  configured_target="$(config_get slowdns.target || true)"
  configured_udp53_mode="$(config_get slowdns.udp53_mode || true)"
  configured_openvpn_udp_public_port="$(config_get openvpn.udp_public_port || true)"
  configured_openvpn_udp_public_ports="$(config_get openvpn.udp_public_ports || true)"
  configured_ws_path="$(config_get ssh.ws_path || true)"
  if [[ -n "${configured_ws_path}" ]]; then
    SSH_WS_PATH="${configured_ws_path}"
  fi
  if [[ -z "${SSH_WS_PATH_ALIASES}" ]]; then
    configured_ws_aliases="$(config_get ssh.ws_path_aliases || true)"
    SSH_WS_PATH_ALIASES="${configured_ws_aliases}"
  fi
  if [[ -z "${DOMAIN}" ]]; then
    echo "IPTunnel domain is required." >&2
    exit 1
  fi
  if [[ -z "${PUBLIC_IP}" ]]; then
    echo "IPTunnel public IP is required." >&2
    exit 1
  fi
  if [[ -z "${SLOWDNS_PUBLIC_HOSTNAME}" ]]; then
    if [[ -n "${configured_ns_prefix}" ]]; then
      SLOWDNS_PUBLIC_HOSTNAME="${configured_ns_prefix}.${DOMAIN}"
    else
      SLOWDNS_PUBLIC_HOSTNAME="${DOMAIN}"
    fi
  fi
  if [[ -z "${SLOWDNS_TUNNEL_DOMAIN}" ]]; then
    if [[ -n "${configured_zone_prefix}" ]]; then
      SLOWDNS_TUNNEL_DOMAIN="${configured_zone_prefix}.${DOMAIN}"
    else
      SLOWDNS_TUNNEL_DOMAIN="dns.${DOMAIN}"
    fi
  fi
  SLOWDNS_PUBLIC_HOSTNAME="${SLOWDNS_PUBLIC_HOSTNAME#.}"
  SLOWDNS_PUBLIC_HOSTNAME="${SLOWDNS_PUBLIC_HOSTNAME%.}"
  SLOWDNS_TUNNEL_DOMAIN="${SLOWDNS_TUNNEL_DOMAIN#.}"
  SLOWDNS_TUNNEL_DOMAIN="${SLOWDNS_TUNNEL_DOMAIN%.}"
  SLOWDNS_NS_HOST="${SLOWDNS_PUBLIC_HOSTNAME}"
  SLOWDNS_ZONE="${SLOWDNS_TUNNEL_DOMAIN}"
  if [[ -n "${configured_target}" ]]; then
    SLOWDNS_TARGET="${configured_target}"
  fi
  if [[ -n "${configured_udp53_mode}" ]]; then
    SLOWDNS_UDP53_MODE="${configured_udp53_mode}"
  fi
  if [[ -n "${configured_openvpn_udp_public_ports}" ]]; then
    OPENVPN_UDP_PUBLIC_PORTS="$(normalize_udp_port_csv "${configured_openvpn_udp_public_ports}")"
  elif [[ -n "${configured_openvpn_udp_public_port}" ]]; then
    OPENVPN_UDP_PUBLIC_PORTS="$(normalize_udp_port_csv "${configured_openvpn_udp_public_port}")"
  fi
  if [[ -z "${SLOWDNS_MTU}" ]]; then
    SLOWDNS_MTU="${configured_mtu}"
  fi
  case "${SLOWDNS_MTU}" in
    ''|0|auto|default) SLOWDNS_MTU="${SLOWDNS_DEFAULT_MTU}" ;;
    *)
      if ! [[ "${SLOWDNS_MTU}" =~ ^[0-9]+$ ]] || (( SLOWDNS_MTU < 128 || SLOWDNS_MTU > 1500 )); then
        SLOWDNS_MTU="${SLOWDNS_DEFAULT_MTU}"
      fi
      ;;
  esac
  SSH_WS_PATH="$(normalize_http_path "${SSH_WS_PATH}")"
  if [[ -z "${SSH_WS_PATH_ALIASES}" ]]; then
    SSH_WS_PATH_ALIASES="/ssh"
  fi
  SSH_WS_PATHS_CSV="$(normalize_http_path_csv "${SSH_WS_PATH},${SSH_WS_PATH_ALIASES}")"
  SLOWDNS_UDP53_MODE="$(normalize_udp53_mode "${SLOWDNS_UDP53_MODE}")"
  reconcile_openvpn_ports_with_udp53_mode
}

normalize_http_path() {
  local path="${1:-/}"
  path="${path%%\?*}"
  if [[ -z "${path}" ]]; then
    path="/"
  fi
  if [[ "${path}" != /* ]]; then
    path="/${path}"
  fi
  if [[ "${path}" != "/" ]]; then
    while [[ "${path}" == */ ]]; do
      path="${path%/}"
    done
  fi
  printf '%s\n' "${path:-/}"
}

normalize_http_path_csv() {
  local raw="$1" out="" seen="," candidate normalized
  IFS=',' read -r -a candidates <<<"${raw}"
  for candidate in "${candidates[@]}"; do
    [[ -n "${candidate}" ]] || continue
    normalized="$(normalize_http_path "${candidate}")"
    if [[ "${seen}" != *",${normalized},"* ]]; then
      out="${out:+${out},}${normalized}"
      seen="${seen}${normalized},"
    fi
  done
  printf '%s\n' "${out}"
}

normalize_udp53_mode() {
  local mode
  mode="$(printf '%s' "${1:-slowdns}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  case "${mode}" in
    openvpn|openvpn-only|udp|udp-only|ovpnudp)
      printf 'openvpn\n'
      ;;
    shared|both|mux|hybrid)
      printf 'shared\n'
      ;;
    *)
      printf 'slowdns\n'
      ;;
  esac
}

ssh_ws_exec_args() {
  local csv="$1" path seen=","
  IFS=',' read -r -a paths <<<"${csv}"
  paths+=("/")
  for path in "${paths[@]}"; do
    [[ -n "${path}" ]] || continue
    path="$(normalize_http_path "${path}")"
    if [[ "${seen}" == *",${path},"* ]]; then
      continue
    fi
    seen="${seen}${path},"
    printf ' --path %s' "${path}"
  done
}

ssh_ws_nginx_locations() {
  local csv="$1" path
  IFS=',' read -r -a paths <<<"${csv}"
  for path in "${paths[@]}"; do
    [[ -n "${path}" ]] || continue
    cat <<EOF
    location = ${path} {
        proxy_pass http://127.0.0.1:${EDGE_PROXY_LOCAL_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_socket_keepalive on;
        proxy_read_timeout 86400;
        proxy_send_timeout 86400;
    }

EOF
  done
}

ssh_ws_root_nginx_location() {
  local named_location="$1"
  cat <<EOF
    location = / {
        error_page 418 = ${named_location};
        if (\$http_upgrade ~* "websocket") {
            return 418;
        }
        try_files /index.html =404;
    }

    location ${named_location} {
        proxy_pass http://127.0.0.1:${FRONTING_PROXY_LOCAL_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_socket_keepalive on;
        proxy_read_timeout 86400;
        proxy_send_timeout 86400;
    }
EOF
}

xray_ws_nginx_locations() {
  cat <<EOF
    location = /vmess {
        proxy_pass http://127.0.0.1:10080;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_socket_keepalive on;
        proxy_read_timeout 86400;
        proxy_send_timeout 86400;
    }

    location = /vless {
        proxy_pass http://127.0.0.1:11080;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_socket_keepalive on;
        proxy_read_timeout 86400;
        proxy_send_timeout 86400;
    }

    location = /trojan {
        proxy_pass http://127.0.0.1:12080;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_socket_keepalive on;
        proxy_read_timeout 86400;
        proxy_send_timeout 86400;
    }

    location = /trojan-ws {
        proxy_pass http://127.0.0.1:12080/trojan;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_socket_keepalive on;
        proxy_read_timeout 86400;
        proxy_send_timeout 86400;
    }

    location = /upvmess {
        proxy_pass http://127.0.0.1:10082;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_socket_keepalive on;
        proxy_read_timeout 86400;
        proxy_send_timeout 86400;
    }

    location = /upvless {
        proxy_pass http://127.0.0.1:11082;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_socket_keepalive on;
        proxy_read_timeout 86400;
        proxy_send_timeout 86400;
    }

    location = /uptrojan {
        proxy_pass http://127.0.0.1:12082;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_socket_keepalive on;
        proxy_read_timeout 86400;
        proxy_send_timeout 86400;
    }
EOF
}

xray_grpc_nginx_locations() {
  cat <<EOF
    location /vmess {
        grpc_set_header X-Real-IP \$remote_addr;
        grpc_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        grpc_pass grpc://127.0.0.1:10081;
    }

    location /vless {
        grpc_set_header X-Real-IP \$remote_addr;
        grpc_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        grpc_pass grpc://127.0.0.1:11081;
    }

    location /trojan {
        grpc_set_header X-Real-IP \$remote_addr;
        grpc_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        grpc_pass grpc://127.0.0.1:12081;
    }
EOF
}

config_bool_enabled() {
  local value="$1"
  case "${value,,}" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

current_hysteria_enabled() {
  local value=""
  value="$(config_get hysteria.enabled || true)"
  if config_bool_enabled "$value"; then
    echo "1"
    return 0
  fi
  if systemctl is-active --quiet "${HYSTERIA_VENDOR_SERVICE}" 2>/dev/null; then
    echo "1"
  else
    echo "0"
  fi
}

current_openvpn_enabled() {
  local enabled_value="" udp_port=""
  enabled_value="$(config_get openvpn.enabled || true)"
  if config_bool_enabled "$enabled_value"; then
    echo "1"
    return 0
  fi
  udp_port="$(config_get ssh.ports.ovpnudp || true)"
  if [[ "${udp_port:-"-"}" != "-" ]]; then
    echo "1"
    return 0
  fi
  if systemctl is-active --quiet openvpn-server@iptunnel-udp 2>/dev/null; then
    echo "1"
  else
    echo "0"
  fi
}

set_kv() {
  local file="$1"
  local key="$2"
  local value="$3"
  if grep -qE "^[#[:space:]]*${key}[[:space:]]+" "$file"; then
    sed -i "s|^[#[:space:]]*${key}[[:space:]].*|${key} ${value}|" "$file"
  else
    printf '%s %s\n' "$key" "$value" >>"$file"
  fi
}

ensure_shell_entry() {
  local shell_path="$1"
  if ! grep -qxF "$shell_path" /etc/shells 2>/dev/null; then
    printf '%s\n' "$shell_path" >>/etc/shells
  fi
}

install_transport_packages() {
  apt-get install -y \
    openssh-server \
    squid \
    openvpn \
    easy-rsa \
    vnstat \
    iptables \
    iptables-persistent \
    netfilter-persistent \
    unzip \
    wget \
    git \
    socat \
    stunnel4 \
    python3-websockets \
    haproxy \
    build-essential \
    zlib1g-dev \
    bzip2 \
    libcap2-bin
}

read_existing_hysteria_value() {
  local field="$1"
  python3 - "$field" "$CONFIG_PATH" <<'PY'
import json
import pathlib
import sys

field = sys.argv[1]
config_path = pathlib.Path(sys.argv[2])
candidates = [
    ("iptunnel", config_path),
    ("hysteria", pathlib.Path("/etc/hysteria/config.json")),
]

for kind, path in candidates:
    if not path.exists():
        continue
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        continue

    value = ""
    if kind == "iptunnel":
        value = str((data.get("hysteria") or {}).get(field) or "")
    elif field == "obfs":
        value = str(data.get("obfs") or "")
    elif field == "password":
        auth = data.get("auth") or {}
        config = auth.get("config") or []
        if config:
            value = str(config[0] or "")

    if value:
        print(value)
        break
PY
}

ensure_hysteria_secrets() {
  if [[ -z "${HYSTERIA_OBFS}" ]]; then
    HYSTERIA_OBFS="$(read_existing_hysteria_value obfs)"
  fi
  if [[ -z "${HYSTERIA_OBFS}" ]]; then
    HYSTERIA_OBFS="$(openssl rand -hex 8)"
  fi
  if [[ -z "${HYSTERIA_PASSWORD}" ]]; then
    HYSTERIA_PASSWORD="$(read_existing_hysteria_value password)"
  fi
  if [[ -z "${HYSTERIA_PASSWORD}" ]]; then
    HYSTERIA_PASSWORD="$(openssl rand -hex 12)"
  fi
}

configure_hysteria() {
  ensure_hysteria_secrets
  if [[ ! -x "${HYSTERIA_VENDOR_SCRIPT}" ]]; then
    echo "Missing embedded Hysteria installer at ${HYSTERIA_VENDOR_SCRIPT}" >&2
    exit 1
  fi

  # Clean up the earlier custom Hysteria experiment before handing off to the
  # standalone installer flow that the user already trusts.
  systemctl disable --now "${HYSTERIA_SERVICE}" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/${HYSTERIA_SERVICE}.service"
  rm -f "${HYSTERIA_LEGACY_SYSCTL}"
  if [[ -n "${MAIN_IFACE}" ]]; then
    while iptables -t nat -D PREROUTING -i "${MAIN_IFACE}" -p udp --dport 10000:24999 -j DNAT --to-destination ":${HYSTERIA_PORT}" >/dev/null 2>&1; do :; done
    while iptables -t nat -D PREROUTING -i "${MAIN_IFACE}" -p udp --dport 25001:65000 -j DNAT --to-destination ":${HYSTERIA_PORT}" >/dev/null 2>&1; do :; done
    while ip6tables -t nat -D PREROUTING -i "${MAIN_IFACE}" -p udp --dport 10000:24999 -j DNAT --to-destination ":${HYSTERIA_PORT}" >/dev/null 2>&1; do :; done
    while ip6tables -t nat -D PREROUTING -i "${MAIN_IFACE}" -p udp --dport 25001:65000 -j DNAT --to-destination ":${HYSTERIA_PORT}" >/dev/null 2>&1; do :; done
  else
    while iptables -t nat -D PREROUTING -p udp --dport 10000:24999 -j DNAT --to-destination ":${HYSTERIA_PORT}" >/dev/null 2>&1; do :; done
    while iptables -t nat -D PREROUTING -p udp --dport 25001:65000 -j DNAT --to-destination ":${HYSTERIA_PORT}" >/dev/null 2>&1; do :; done
    while ip6tables -t nat -D PREROUTING -p udp --dport 10000:24999 -j DNAT --to-destination ":${HYSTERIA_PORT}" >/dev/null 2>&1; do :; done
    while ip6tables -t nat -D PREROUTING -p udp --dport 25001:65000 -j DNAT --to-destination ":${HYSTERIA_PORT}" >/dev/null 2>&1; do :; done
  fi
  netfilter-persistent save >/dev/null 2>&1 || true
  systemctl daemon-reload >/dev/null 2>&1 || true

  DOMAIN="${DOMAIN}" \
  OBFS="${HYSTERIA_OBFS}" \
  PASSWORD="${HYSTERIA_PASSWORD}" \
  UDP_PORT=":${HYSTERIA_PORT}" \
  HYSTERIA_USER="root" \
  HYSTERIA_HOME_DIR="/root" \
  "${HYSTERIA_VENDOR_SCRIPT}"

  mkdir -p "${WEB_ROOT}"
  if [[ -f "${HYSTERIA_CA_CERT}" ]]; then
    cp "${HYSTERIA_CA_CERT}" "${HYSTERIA_PUBLIC_CA}"
    chmod 644 "${HYSTERIA_PUBLIC_CA}"
  fi

  if [[ -f "/etc/systemd/system/${HYSTERIA_VENDOR_SERVICE}.service" ]]; then
    ln -sf "/etc/systemd/system/${HYSTERIA_VENDOR_SERVICE}.service" "/etc/systemd/system/${HYSTERIA_SERVICE}.service"
  fi
  systemctl daemon-reload >/dev/null 2>&1 || true

  cat >"${HYSTERIA_INFO_FILE}" <<EOF
IPTunnel Hysteria
=================
Host         : ${DOMAIN}
Port         : ${HYSTERIA_PORT}
Protocol     : ${HYSTERIA_PROTOCOL}
Obfs         : ${HYSTERIA_OBFS}
Password     : ${HYSTERIA_PASSWORD}
CA cert      : ${HYSTERIA_PUBLIC_CA}
Service      : ${HYSTERIA_VENDOR_SERVICE}
Hop range    : ${HYSTERIA_HOP_RANGE}

Notes:
- Import ${HYSTERIA_PUBLIC_CA} into the client if it verifies certificates strictly.
- If the client supports insecure/self-signed mode, you can use that instead of importing the CA.
- This uses the exact standalone Hysteria installer flow that already works on your other server.
EOF

  systemctl enable "${HYSTERIA_VENDOR_SERVICE}" >/dev/null 2>&1 || true
  systemctl restart "${HYSTERIA_VENDOR_SERVICE}"
}

disable_hysteria() {
  systemctl disable --now "${HYSTERIA_SERVICE}" >/dev/null 2>&1 || true
  systemctl disable --now "${HYSTERIA_VENDOR_SERVICE}" >/dev/null 2>&1 || true
  if [[ -n "${MAIN_IFACE}" ]]; then
    while iptables -t nat -D PREROUTING -i "${MAIN_IFACE}" -p udp --dport "${HYSTERIA_HOP_RANGE}" -j DNAT --to-destination ":${HYSTERIA_PORT}" >/dev/null 2>&1; do :; done
    while ip6tables -t nat -D PREROUTING -i "${MAIN_IFACE}" -p udp --dport "${HYSTERIA_HOP_RANGE}" -j DNAT --to-destination ":${HYSTERIA_PORT}" >/dev/null 2>&1; do :; done
    while iptables -t nat -D PREROUTING -i "${MAIN_IFACE}" -p udp --dport 10000:24999 -j DNAT --to-destination ":${HYSTERIA_PORT}" >/dev/null 2>&1; do :; done
    while iptables -t nat -D PREROUTING -i "${MAIN_IFACE}" -p udp --dport 25001:65000 -j DNAT --to-destination ":${HYSTERIA_PORT}" >/dev/null 2>&1; do :; done
    while ip6tables -t nat -D PREROUTING -i "${MAIN_IFACE}" -p udp --dport 10000:24999 -j DNAT --to-destination ":${HYSTERIA_PORT}" >/dev/null 2>&1; do :; done
    while ip6tables -t nat -D PREROUTING -i "${MAIN_IFACE}" -p udp --dport 25001:65000 -j DNAT --to-destination ":${HYSTERIA_PORT}" >/dev/null 2>&1; do :; done
  else
    while iptables -t nat -D PREROUTING -p udp --dport "${HYSTERIA_HOP_RANGE}" -j DNAT --to-destination ":${HYSTERIA_PORT}" >/dev/null 2>&1; do :; done
    while ip6tables -t nat -D PREROUTING -p udp --dport "${HYSTERIA_HOP_RANGE}" -j DNAT --to-destination ":${HYSTERIA_PORT}" >/dev/null 2>&1; do :; done
    while iptables -t nat -D PREROUTING -p udp --dport 10000:24999 -j DNAT --to-destination ":${HYSTERIA_PORT}" >/dev/null 2>&1; do :; done
    while iptables -t nat -D PREROUTING -p udp --dport 25001:65000 -j DNAT --to-destination ":${HYSTERIA_PORT}" >/dev/null 2>&1; do :; done
    while ip6tables -t nat -D PREROUTING -p udp --dport 10000:24999 -j DNAT --to-destination ":${HYSTERIA_PORT}" >/dev/null 2>&1; do :; done
    while ip6tables -t nat -D PREROUTING -p udp --dport 25001:65000 -j DNAT --to-destination ":${HYSTERIA_PORT}" >/dev/null 2>&1; do :; done
  fi
  netfilter-persistent save >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/${HYSTERIA_SERVICE}.service"
  rm -f "${HYSTERIA_LEGACY_SYSCTL}"
  rm -f "${HYSTERIA_INFO_FILE}" "${HYSTERIA_PUBLIC_CA}"
  systemctl daemon-reload >/dev/null 2>&1 || true
}

configure_ssh() {
  local sshd_config="/etc/ssh/sshd_config"
  touch "$sshd_config"
  set_kv "$sshd_config" "PasswordAuthentication" "yes"
  set_kv "$sshd_config" "UseDNS" "no"
  set_kv "$sshd_config" "PermitTunnel" "yes"
  ensure_shell_entry "/bin/false"
  ensure_shell_entry "/usr/sbin/nologin"
  printf 'Welcome to IPTunnel\n' >/etc/issue.net
  systemctl enable ssh >/dev/null 2>&1 || true
  systemctl restart ssh >/dev/null 2>&1 || systemctl restart sshd >/dev/null 2>&1 || true
}

configure_dropbear() {
  local source_url="https://matt.ucc.asn.au/dropbear/releases/dropbear-${DROPBEAR_VERSION}.tar.bz2"
  local src_dir="/tmp/dropbear-${DROPBEAR_VERSION}"
  local archive="/tmp/dropbear-${DROPBEAR_VERSION}.tar.bz2"
  local dropbear_bin="/usr/local/sbin/dropbear"
  local dropbear_keygen="/usr/local/bin/dropbearkey"

  if [[ -x "${dropbear_bin}" ]] && ("${dropbear_bin}" -V 2>&1 || true) | grep -q "${DROPBEAR_VERSION}"; then
    :
  else
    rm -rf "${src_dir}" "${archive}"
    curl -fsSL "${source_url}" -o "${archive}"
    tar -xjf "${archive}" -C /tmp
    (
      cd "${src_dir}"
      ./configure --prefix=/usr/local
      make PROGRAMS="dropbear dropbearkey dbclient dropbearconvert" MULTI=1
      make PROGRAMS="dropbear dropbearkey dbclient dropbearconvert" MULTI=1 install
    )
    rm -rf "${src_dir}" "${archive}"
  fi

  mkdir -p /etc/dropbear
  if [[ ! -f /etc/dropbear/dropbear_rsa_host_key ]]; then
    "${dropbear_keygen}" -t rsa -f /etc/dropbear/dropbear_rsa_host_key >/dev/null 2>&1
  fi
  if [[ ! -f /etc/dropbear/dropbear_ecdsa_host_key ]]; then
    "${dropbear_keygen}" -t ecdsa -f /etc/dropbear/dropbear_ecdsa_host_key >/dev/null 2>&1
  fi

  cat >/etc/systemd/system/dropbear.service <<EOF
[Unit]
Description=Dropbear SSH server (${DROPBEAR_VERSION})
After=network.target ssh.service

[Service]
Type=simple
ExecStart=${dropbear_bin} -F -E -r /etc/dropbear/dropbear_rsa_host_key -r /etc/dropbear/dropbear_ecdsa_host_key -p 109 -p 143 -b /etc/issue.net -W 65536
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable dropbear >/dev/null 2>&1 || true
  systemctl restart dropbear >/dev/null 2>&1 || true
}

go_toolchain_usable() {
  local candidate="$1"
  local version=""
  local major=""
  local minor=""

  [[ -x "${candidate}" ]] || return 1
  version="$("${candidate}" env GOVERSION 2>/dev/null || true)"
  version="${version#go}"
  major="${version%%.*}"
  version="${version#*.}"
  minor="${version%%.*}"
  [[ "${major}" =~ ^[0-9]+$ && "${minor}" =~ ^[0-9]+$ ]] || return 1
  (( major > 1 || (major == 1 && minor >= 21) ))
}

install_go_toolchain() {
  local release_info=""
  local go_arch=""
  local fallback_filename=""
  local fallback_sha256=""
  local go_filename=""
  local go_sha256=""
  local download_base=""
  local archive_path="/tmp/iptunnel-go-toolchain.tar.gz"
  local stage_dir="/usr/local/.iptunnel-go-stage-$$"
  local backup_dir="/usr/local/.iptunnel-go-backup-$$"
  local installed="0"
  local seen="|"
  local existing_go=""
  local -a download_bases=(
    "https://go.dev/dl"
    "https://storage.googleapis.com/golang"
    "https://mirrors.aliyun.com/golang"
    "https://mirrors.ustc.edu.cn/golang"
  )

  if go_toolchain_usable /usr/local/go/bin/go; then
    go_bin="/usr/local/go/bin/go"
    GO_TOOLCHAIN_BOOTSTRAP_STATE="ready"
    return 0
  fi
  existing_go="$(command -v go 2>/dev/null || true)"
  if [[ -n "${existing_go}" ]] && go_toolchain_usable "${existing_go}"; then
    go_bin="${existing_go}"
    GO_TOOLCHAIN_BOOTSTRAP_STATE="ready"
    return 0
  fi
  if [[ "${GO_TOOLCHAIN_BOOTSTRAP_STATE}" == "failed" ]]; then
    echo "Go toolchain bootstrap already failed during this run; skipping duplicate downloads" >&2
    return 1
  fi
  GO_TOOLCHAIN_BOOTSTRAP_STATE="attempting"

  if command -v apt-get >/dev/null 2>&1; then
    echo "[*] Trying the distribution-signed Go toolchain package"
    if apt-get install -y golang-go; then
      for existing_go in /usr/bin/go "$(command -v go 2>/dev/null || true)"; do
        if [[ -n "${existing_go}" ]] && go_toolchain_usable "${existing_go}"; then
          go_bin="${existing_go}"
          GO_TOOLCHAIN_BOOTSTRAP_STATE="ready"
          return 0
        fi
      done
      echo "[!] The distribution Go package is older than the required Go 1.21; trying verified archives" >&2
    else
      echo "[!] The distribution Go package was unavailable; trying verified archives" >&2
    fi
  fi

  case "$(uname -m)" in
    x86_64|amd64)
      go_arch="amd64"
      fallback_filename="go1.24.9.linux-amd64.tar.gz"
      fallback_sha256="5b7899591c2dd6e9da1809fde4a2fad842c45d3f6b9deb235ba82216e31e34a6"
      ;;
    aarch64|arm64)
      go_arch="arm64"
      fallback_filename="go1.24.9.linux-arm64.tar.gz"
      fallback_sha256="9aa1243d51d41e2f93e895c89c0a2daf7166768c4a4c3ac79db81029d295a540"
      ;;
    *)
      echo "Unsupported architecture for Go toolchain: $(uname -m)" >&2
      GO_TOOLCHAIN_BOOTSTRAP_STATE="failed"
      return 1
      ;;
  esac

  release_info="$(python3 - "${go_arch}" <<'PY' 2>/dev/null || true
import json
import sys
import urllib.request

arch = sys.argv[1]

with urllib.request.urlopen("https://go.dev/dl/?mode=json", timeout=30) as response:
    releases = json.load(response)

for release in releases:
    if not release.get("stable"):
        continue
    for file_info in release.get("files", []):
        if file_info.get("os") == "linux" and file_info.get("arch") == arch and file_info.get("kind") == "archive":
            filename = str(file_info.get("filename") or "")
            sha256 = str(file_info.get("sha256") or "")
            if filename and sha256:
                print(f"{filename}|{sha256}")
PY
)"
  release_info="${release_info}"$'\n'"${fallback_filename}|${fallback_sha256}"

  rm -rf "${stage_dir}" "${backup_dir}"
  rm -f "${archive_path}"
  while IFS='|' read -r go_filename go_sha256; do
    [[ -n "${go_filename}" && -n "${go_sha256}" ]] || continue
    [[ "${seen}" != *"|${go_filename}|"* ]] || continue
    seen="${seen}${go_filename}|"

    for download_base in "${download_bases[@]}"; do
      rm -f "${archive_path}"
      echo "[*] Downloading Go toolchain ${go_filename} from ${download_base}"
      if ! curl -4fsSL --connect-timeout 20 --max-time 240 --retry 2 --retry-connrefused --retry-delay 2 \
        "${download_base}/${go_filename}" -o "${archive_path}"; then
        continue
      fi
      if ! printf '%s  %s\n' "${go_sha256}" "${archive_path}" | sha256sum -c - >/dev/null 2>&1; then
        echo "[!] Go archive checksum mismatch from ${download_base}; trying another source" >&2
        continue
      fi

      rm -rf "${stage_dir}"
      mkdir -p "${stage_dir}"
      if ! tar -C "${stage_dir}" -xzf "${archive_path}" || ! go_toolchain_usable "${stage_dir}/go/bin/go"; then
        echo "[!] Go archive from ${download_base} failed validation; trying another source" >&2
        rm -rf "${stage_dir}"
        continue
      fi

      if [[ -e /usr/local/go ]]; then
        mv /usr/local/go "${backup_dir}" || return 1
      fi
      if mv "${stage_dir}/go" /usr/local/go && go_toolchain_usable /usr/local/go/bin/go; then
        rm -rf "${backup_dir}"
        installed="1"
        GO_TOOLCHAIN_BOOTSTRAP_STATE="ready"
      else
        rm -rf /usr/local/go
        if [[ -e "${backup_dir}" ]]; then
          if ! mv "${backup_dir}" /usr/local/go; then
            echo "Failed to restore the previous Go toolchain; it remains at ${backup_dir}" >&2
            rm -rf "${stage_dir}"
            rm -f "${archive_path}"
            return 1
          fi
        fi
      fi
      break
    done
    [[ "${installed}" == "1" ]] && break
  done <<< "${release_info}"

  rm -rf "${stage_dir}" "${backup_dir}"
  rm -f "${archive_path}"
  if [[ "${installed}" != "1" ]]; then
    GO_TOOLCHAIN_BOOTSTRAP_STATE="failed"
    echo "Failed to download and verify a supported Go toolchain from all configured sources" >&2
    return 1
  fi

  ln -sf /usr/local/go/bin/go /usr/local/bin/go || return 1
  ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt || return 1
  go_bin="/usr/local/go/bin/go"
  return 0
}

slowdns_binary_looks_valid() {
  local path="$1"
  shift || true
  local magic=""
  local help_output=""
  local marker=""

  [[ -s "${path}" ]] || return 1
  magic="$(od -An -N4 -tx1 "${path}" 2>/dev/null | tr -d ' \n')"
  [[ "${magic}" == "7f454c46" ]] || return 1
  if [[ "$#" -eq 0 ]]; then
    return 0
  fi
  help_output="$("${path}" -h 2>&1 || true)"
  [[ -n "${help_output}" ]] || return 1
  for marker in "$@"; do
    [[ "${help_output}" == *"${marker}"* ]] || return 1
  done
  return 0
}

install_slowdns_pair_from_urls() {
  local server_url="$1"
  local client_url="$2"
  local api_key="${3:-}"
  local curl_args=(-fsSL)

  [[ -n "${server_url}" && -n "${client_url}" ]] || return 1
  if [[ -n "${api_key}" ]]; then
    curl_args+=(-H "x-api-key: ${api_key}")
  fi

  rm -f /usr/local/bin/iptunnel-dns-server /usr/local/bin/iptunnel-dns-client
  if ! curl "${curl_args[@]}" "${server_url}" -o /usr/local/bin/iptunnel-dns-server; then
    rm -f /usr/local/bin/iptunnel-dns-server /usr/local/bin/iptunnel-dns-client
    return 1
  fi
  if ! curl "${curl_args[@]}" "${client_url}" -o /usr/local/bin/iptunnel-dns-client; then
    rm -f /usr/local/bin/iptunnel-dns-server /usr/local/bin/iptunnel-dns-client
    return 1
  fi

  chmod 755 /usr/local/bin/iptunnel-dns-server /usr/local/bin/iptunnel-dns-client
  if slowdns_binary_looks_valid /usr/local/bin/iptunnel-dns-server "-gen-key" "-udp" "privkey-file" && \
     slowdns_binary_looks_valid /usr/local/bin/iptunnel-dns-client "-pubkey-file" "-doh"; then
    return 0
  fi

  rm -f /usr/local/bin/iptunnel-dns-server /usr/local/bin/iptunnel-dns-client
  return 1
}

build_slowdns_from_source_dir() {
  local src_dir="$1"

  [[ -d "${src_dir}/dnstt-server" && -d "${src_dir}/dnstt-client" ]] || return 1

  if ! (
    cd "${src_dir}/dnstt-server"
    "${go_bin}" build -trimpath -o /usr/local/bin/iptunnel-dns-server
  ); then
    rm -f /usr/local/bin/iptunnel-dns-server /usr/local/bin/iptunnel-dns-client
    return 1
  fi
  if ! (
    cd "${src_dir}/dnstt-client"
    "${go_bin}" build -trimpath -o /usr/local/bin/iptunnel-dns-client
  ); then
    rm -f /usr/local/bin/iptunnel-dns-server /usr/local/bin/iptunnel-dns-client
    return 1
  fi

  chmod 755 /usr/local/bin/iptunnel-dns-server /usr/local/bin/iptunnel-dns-client || return 1
  slowdns_binary_looks_valid /usr/local/bin/iptunnel-dns-server "-gen-key" "-udp" "privkey-file" && \
    slowdns_binary_looks_valid /usr/local/bin/iptunnel-dns-client "-pubkey-file" "-doh"
}

install_slowdns_from_snapshot() {
  local snapshot_url="$1"

  [[ -n "${snapshot_url}" ]] || return 1

  install_go_toolchain || return 1
  rm -rf /tmp/dnstt-src /tmp/dnstt-release /tmp/dnstt-release.zip
  if ! curl -fsSL "${snapshot_url}" -o /tmp/dnstt-release.zip; then
    rm -rf /tmp/dnstt-src /tmp/dnstt-release /tmp/dnstt-release.zip
    return 1
  fi

  local extracted_root=""
  extracted_root="$(
    python3 - /tmp/dnstt-release.zip <<'PY'
import pathlib
import shutil
import sys
import zipfile

zip_path = pathlib.Path(sys.argv[1])
extract_root = pathlib.Path("/tmp/dnstt-release")
source_root = pathlib.Path("/tmp/dnstt-src")

shutil.rmtree(extract_root, ignore_errors=True)
shutil.rmtree(source_root, ignore_errors=True)
extract_root.mkdir(parents=True, exist_ok=True)

with zipfile.ZipFile(zip_path) as archive:
    archive.extractall(extract_root)

candidates = []
for server_dir in extract_root.rglob("dnstt-server"):
    if not server_dir.is_dir():
        continue
    root = server_dir.parent
    if (root / "dnstt-client").is_dir():
        candidates.append(root)

if not candidates:
    raise SystemExit(1)

candidates.sort(key=lambda path: (len(path.parts), str(path)))
shutil.move(str(candidates[0]), str(source_root))
print(source_root, end="")
PY
  )" || {
    rm -rf /tmp/dnstt-src /tmp/dnstt-release /tmp/dnstt-release.zip
    return 1
  }

  if ! build_slowdns_from_source_dir "${extracted_root}"; then
    rm -f /usr/local/bin/iptunnel-dns-server /usr/local/bin/iptunnel-dns-client
    rm -rf /tmp/dnstt-src /tmp/dnstt-release /tmp/dnstt-release.zip
    return 1
  fi

  rm -rf /tmp/dnstt-src /tmp/dnstt-release /tmp/dnstt-release.zip
  return 0
}

install_slowdns_binaries() {
  if [[ -x /usr/local/bin/iptunnel-dns-server && -x /usr/local/bin/iptunnel-dns-client ]] && \
     slowdns_binary_looks_valid /usr/local/bin/iptunnel-dns-server "-gen-key" "-udp" "privkey-file" && \
     slowdns_binary_looks_valid /usr/local/bin/iptunnel-dns-client "-pubkey-file" "-doh"; then
    return 0
  fi

  # Preserve working legacy installs when upgrading in place.
  if [[ -x /usr/sbin/dns-server && -x /usr/sbin/dns-client ]] && \
     slowdns_binary_looks_valid /usr/sbin/dns-server "-gen-key" "-udp" "privkey-file" && \
     slowdns_binary_looks_valid /usr/sbin/dns-client "-pubkey-file" "-doh"; then
    install -m 755 /usr/sbin/dns-server /usr/local/bin/iptunnel-dns-server
    install -m 755 /usr/sbin/dns-client /usr/local/bin/iptunnel-dns-client
    return 0
  fi

  if install_slowdns_pair_from_urls "${SLOWDNS_SERVER_URL}" "${SLOWDNS_CLIENT_URL}" "${SLOWDNS_API_KEY}"; then
    return 0
  fi

  if install_slowdns_from_snapshot "${SLOWDNS_DNSTT_SNAPSHOT_URL}"; then
    return 0
  fi

  if ! install_go_toolchain; then
    echo "Unable to install the Go toolchain required to build SlowDNS" >&2
    return 1
  fi
  rm -rf /tmp/dnstt-src
  if ! git clone --depth 1 https://www.bamsoftware.com/git/dnstt.git /tmp/dnstt-src; then
    rm -rf /tmp/dnstt-src
    if ! git clone https://www.bamsoftware.com/git/dnstt.git /tmp/dnstt-src; then
      rm -rf /tmp/dnstt-src
      echo "Unable to download the SlowDNS source after all binary and snapshot fallbacks failed" >&2
      return 1
    fi
  fi
  if [[ -n "${SLOWDNS_DNSTT_REF}" ]]; then
    (
      cd /tmp/dnstt-src
      git fetch --depth 1 origin "${SLOWDNS_DNSTT_REF}" >/dev/null 2>&1 || true
      git checkout -q "${SLOWDNS_DNSTT_REF}"
    )
  fi
  if ! build_slowdns_from_source_dir /tmp/dnstt-src; then
    rm -rf /tmp/dnstt-src
    echo "Unable to build valid SlowDNS server and client binaries" >&2
    return 1
  fi
  rm -rf /tmp/dnstt-src
  return 0
}

configure_slowdns() {
  if ! install_slowdns_binaries; then
    echo "SlowDNS installation failed; stopping before service configuration" >&2
    return 1
  fi
  mkdir -p "${SLOWDNS_DIR}" "${WEB_ROOT}"
  local mtu_args=""
  local udp53_mode=""
  local slowdns_public_path=""
  udp53_mode="$(normalize_udp53_mode "${SLOWDNS_UDP53_MODE}")"
  case "${udp53_mode}" in
    openvpn)
      if [[ "${ENABLE_OPENVPN}" == "1" ]]; then
        slowdns_public_path="assigned to OpenVPN UDP on public 53"
      else
        slowdns_public_path="reserved for OpenVPN UDP (OpenVPN currently disabled)"
      fi
      ;;
    shared)
      if [[ "${ENABLE_OPENVPN}" == "1" ]]; then
        slowdns_public_path="shared with OpenVPN via ${UDP53_MUX_SERVICE}"
      else
        slowdns_public_path="direct redirect 53 -> ${SLOWDNS_INTERNAL_PORT} (shared-mode fallback)"
      fi
      ;;
    *)
      slowdns_public_path="direct redirect 53 -> ${SLOWDNS_INTERNAL_PORT}"
      ;;
  esac

  if [[ ! -f "${SLOWDNS_PRIVATE_KEY}" || ! -f "${SLOWDNS_PUBLIC_KEY}" ]]; then
    /usr/local/bin/iptunnel-dns-server -gen-key -privkey-file "${SLOWDNS_PRIVATE_KEY}" -pubkey-file "${SLOWDNS_PUBLIC_KEY}"
  fi
  if [[ -n "${SLOWDNS_MTU}" ]]; then
    mtu_args=" -mtu ${SLOWDNS_MTU}"
  fi

  cat >"${SLOWDNS_ENV}" <<EOF
LISTEN_SERVER=${SLOWDNS_LISTEN_UDP}
LISTEN_CLIENT=127.0.0.1:${SLOWDNS_LOCAL_PORT}
CONFIG_PRIV=${SLOWDNS_PRIVATE_KEY}
CONFIG_PUB=${SLOWDNS_PUBLIC_KEY}
NAMESERVER=${SLOWDNS_ZONE}
NS_HOST=${SLOWDNS_NS_HOST}
SERVICE_SERVER=${SLOWDNS_TARGET}
SERVICE_CLIENT=127.0.0.1:${SLOWDNS_LOCAL_PORT}
PUBLIC_PORT=${SLOWDNS_PUBLIC_PORT}
MTU=${SLOWDNS_MTU}
EOF

  cat >/etc/systemd/system/iptunnel-slowdns.service <<EOF
[Unit]
Description=IPTunnel SlowDNS
Documentation=https://www.bamsoftware.com/software/dnstt/
After=network.target nss-lookup.target

[Service]
User=root
EnvironmentFile=${SLOWDNS_ENV}
Restart=on-failure
ExecStart=/usr/local/bin/iptunnel-dns-server -udp \$LISTEN_SERVER -privkey-file \$CONFIG_PRIV${mtu_args} \$NAMESERVER \$SERVICE_SERVER
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

  cat >"${SLOWDNS_INFO_FILE}" <<EOF
IPTunnel SlowDNS
================
Tunnel domain : ${SLOWDNS_ZONE}
Nameserver    : ${SLOWDNS_NS_HOST}
Public host   : ${SLOWDNS_PUBLIC_HOSTNAME}
Public UDP    : ${SLOWDNS_PUBLIC_PORT} ${slowdns_public_path}
Internal UDP  : ${SLOWDNS_INTERNAL_PORT}
Local SSH port: ${SLOWDNS_LOCAL_PORT}
Target        : ${SLOWDNS_TARGET}
Proxy target  : ${SLOWDNS_TARGET_REAL_DEST}
UDP53 mode    : ${udp53_mode}
Server MTU    : ${SLOWDNS_MTU:-${SLOWDNS_DEFAULT_MTU}}

Create these DNS records:
1. A    ${SLOWDNS_PUBLIC_HOSTNAME} -> ${PUBLIC_IP}
2. NS   ${SLOWDNS_ZONE} -> ${SLOWDNS_NS_HOST}

Important:
- Create the NS record on the parent zone (${DOMAIN}), not inside the delegated subdomain.
- Keep ${SLOWDNS_NS_HOST} as DNS-only if your DNS provider supports proxying.
- Use ${SLOWDNS_ZONE} in your client. ${SLOWDNS_NS_HOST} is the delegated nameserver host.
- Default MTU is ${SLOWDNS_MTU:-${SLOWDNS_DEFAULT_MTU}}. Use a lower value only if your resolver path drops fragmented DNS responses.

Public key:
$(cat "${SLOWDNS_PUBLIC_KEY}")

Example client command:
dnstt-client -doh https://1.1.1.1/dns-query -pubkey-file server.pub ${SLOWDNS_ZONE} 127.0.0.1:${SLOWDNS_LOCAL_PORT}

SSH example after the tunnel is up:
ssh -p ${SLOWDNS_LOCAL_PORT} user@127.0.0.1

Quick checks:
dig +short A ${SLOWDNS_PUBLIC_HOSTNAME}
dig +short NS ${SLOWDNS_ZONE}
EOF

  systemctl daemon-reload
  systemctl enable iptunnel-slowdns >/dev/null 2>&1 || true
  systemctl restart iptunnel-slowdns >/dev/null 2>&1 || true
}

disable_slowdns_runtime() {
  systemctl disable --now iptunnel-slowdns >/dev/null 2>&1 || true
  systemctl disable --now "${SLOWDNS_TARGET_PROXY_SERVICE}" >/dev/null 2>&1 || true
  cat >"${SLOWDNS_INFO_FILE}" <<EOF
IPTunnel SlowDNS
================
Status       : disabled
Reason       : UDP53 is assigned to OpenVPN only
Tunnel domain: ${SLOWDNS_ZONE}
Public host  : ${SLOWDNS_PUBLIC_HOSTNAME}
EOF
}

configure_slowdns_target_proxy() {
  local socat_bin=""
  socat_bin="$(command -v socat || true)"
  if [[ -z "${socat_bin}" ]]; then
    echo "socat binary not found after install" >&2
    exit 1
  fi

  cat >/etc/systemd/system/${SLOWDNS_TARGET_PROXY_SERVICE}.service <<EOF
[Unit]
Description=IPTunnel SlowDNS local SSH proxy
After=network.target ssh.service dropbear.service

[Service]
Type=simple
ExecStart=${socat_bin} TCP-LISTEN:${SLOWDNS_TARGET_PROXY_PORT},bind=127.0.0.1,reuseaddr,fork TCP:${SLOWDNS_TARGET_REAL_DEST}
Restart=always
RestartSec=2
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "${SLOWDNS_TARGET_PROXY_SERVICE}" >/dev/null 2>&1 || true
  systemctl restart "${SLOWDNS_TARGET_PROXY_SERVICE}" >/dev/null 2>&1 || true
}

configure_udp53_mux() {
  local udp53_mode=""
  local mux_listen_host=""
  local cleanup_ports=""
  local public_port=""
  local -a cleanup_port_items=()
  local -a openvpn_port_items=()
  udp53_mode="$(normalize_udp53_mode "${SLOWDNS_UDP53_MODE}")"
  mkdir -p /etc/iptunnel /opt/iptunnel
  mux_listen_host="${UDP53_LISTEN_HOST}"
  if [[ "${udp53_mode}" == "shared" && ( "${mux_listen_host}" == "0.0.0.0" || -z "${mux_listen_host}" ) ]]; then
    # systemd-resolved commonly binds 127.0.0.53:53. Binding UDP 0.0.0.0:53
    # conflicts with that, so shared mode listens only on the public address.
    mux_listen_host="${PUBLIC_IP}"
  fi

  cat >"${UDP53_MUX_ENV}" <<EOF
LISTEN_HOST=${mux_listen_host}
LISTEN_PORT=53
SLOWDNS_BACKEND=127.0.0.1:${SLOWDNS_INTERNAL_PORT}
SLOWDNS_ZONE=${SLOWDNS_ZONE}
OPENVPN_BACKEND=127.0.0.1:${OPENVPN_UDP_INTERNAL_PORT}
OPENVPN_ENABLED=${ENABLE_OPENVPN}
SESSION_IDLE_TIMEOUT=180
EOF

  cat >"${UDP53_MUX_SCRIPT}" <<'PY'
#!/usr/bin/env python3
import argparse
import asyncio
import contextlib
import time


def parse_host_port(value: str) -> tuple[str, int]:
    host, port = value.rsplit(":", 1)
    return host, int(port)


def skip_dns_name(packet: bytes, offset: int) -> int | None:
    seen_pointers: set[int] = set()
    consumed_offset: int | None = None

    while True:
        if offset >= len(packet):
            return None

        length = packet[offset]

        # Support compressed names; some resolvers use pointers in questions/additional records.
        if length & 0xC0 == 0xC0:
            if offset + 1 >= len(packet):
                return None
            pointer = ((length & 0x3F) << 8) | packet[offset + 1]
            if pointer >= len(packet) or pointer in seen_pointers:
                return None
            seen_pointers.add(pointer)
            if consumed_offset is None:
                consumed_offset = offset + 2
            offset = pointer
            continue

        if length & 0xC0:
            return None

        offset += 1
        if length == 0:
            return consumed_offset if consumed_offset is not None else offset

        if length > 63 or offset + length > len(packet):
            return None
        offset += length


def skip_dns_rr(packet: bytes, offset: int) -> int | None:
    offset = skip_dns_name(packet, offset)
    if offset is None or offset + 10 > len(packet):
        return None

    rdlength = int.from_bytes(packet[offset + 8 : offset + 10], "big")
    offset += 10
    if offset + rdlength > len(packet):
        return None

    return offset + rdlength


def read_dns_name(packet: bytes, offset: int) -> tuple[str, int] | tuple[None, None]:
    labels: list[str] = []
    consumed_offset: int | None = None
    seen_pointers: set[int] = set()

    while True:
        if offset >= len(packet):
            return None, None

        length = packet[offset]

        if length & 0xC0 == 0xC0:
            if offset + 1 >= len(packet):
                return None, None
            pointer = ((length & 0x3F) << 8) | packet[offset + 1]
            if pointer >= len(packet) or pointer in seen_pointers:
                return None, None
            seen_pointers.add(pointer)
            if consumed_offset is None:
                consumed_offset = offset + 2
            offset = pointer
            continue

        if length & 0xC0:
            return None, None

        offset += 1
        if length == 0:
            end_offset = consumed_offset if consumed_offset is not None else offset
            return ".".join(labels).lower(), end_offset

        if length > 63 or offset + length > len(packet):
            return None, None

        label = packet[offset : offset + length]
        try:
            labels.append(label.decode("ascii").strip().lower())
        except UnicodeDecodeError:
            return None, None
        offset += length


def looks_like_dns_query(packet: bytes) -> bool:
    if len(packet) < 12:
        return False

    flags = int.from_bytes(packet[2:4], "big")
    qr = (flags >> 15) & 0x1
    opcode = (flags >> 11) & 0xF
    rcode = flags & 0xF
    if qr != 0 or opcode > 5 or rcode != 0:
        return False

    qdcount = int.from_bytes(packet[4:6], "big")
    ancount = int.from_bytes(packet[6:8], "big")
    nscount = int.from_bytes(packet[8:10], "big")
    arcount = int.from_bytes(packet[10:12], "big")
    if qdcount < 1 or qdcount > 8 or ancount != 0 or nscount != 0:
        return False

    offset = 12
    for _ in range(qdcount):
        offset = skip_dns_name(packet, offset)
        if offset is None:
            return False
        if offset + 4 > len(packet):
            return False
        qclass = int.from_bytes(packet[offset + 2 : offset + 4], "big")
        if qclass not in {1, 255}:
            return False
        offset += 4

    for _ in range(arcount):
        offset = skip_dns_rr(packet, offset)
        if offset is None:
            return False

    return offset == len(packet)


def dns_question_name(packet: bytes) -> str:
    if len(packet) < 12:
        return ""
    qdcount = int.from_bytes(packet[4:6], "big")
    if qdcount < 1:
        return ""
    name, _ = read_dns_name(packet, 12)
    return name or ""


class BackendSession(asyncio.DatagramProtocol):
    def __init__(self, mux: "Udp53MuxProtocol", session_key: tuple[tuple[str, int], str]):
        self.mux = mux
        self.session_key = session_key
        self.client_addr = session_key[0]
        self.transport: asyncio.DatagramTransport | None = None

    def connection_made(self, transport: asyncio.BaseTransport) -> None:
        self.transport = transport  # type: ignore[assignment]

    def datagram_received(self, data: bytes, addr) -> None:
        self.mux.touch(self.session_key)
        if self.mux.server_transport is not None:
            self.mux.server_transport.sendto(data, self.client_addr)

    def error_received(self, exc: Exception) -> None:
        self.mux.drop(self.session_key)

    def connection_lost(self, exc: Exception | None) -> None:
        self.mux.drop(self.session_key)


class Udp53MuxProtocol(asyncio.DatagramProtocol):
    def __init__(
        self,
        loop: asyncio.AbstractEventLoop,
        slowdns_backend: tuple[str, int],
        slowdns_zone: str,
        openvpn_backend: tuple[str, int],
        openvpn_enabled: bool,
        idle_timeout: float,
    ) -> None:
        self.loop = loop
        self.slowdns_backend = slowdns_backend
        self.slowdns_zone = slowdns_zone.strip(".").lower()
        self.openvpn_backend = openvpn_backend
        self.openvpn_enabled = openvpn_enabled
        self.idle_timeout = idle_timeout
        self.server_transport: asyncio.DatagramTransport | None = None
        self.sessions: dict[tuple[tuple[str, int], str], dict[str, object]] = {}

    def connection_made(self, transport: asyncio.BaseTransport) -> None:
        self.server_transport = transport  # type: ignore[assignment]

    def datagram_received(self, data: bytes, addr) -> None:
        self.loop.create_task(self.handle_packet(data, addr))

    def touch(self, session_key: tuple[tuple[str, int], str]) -> None:
        session = self.sessions.get(session_key)
        if session is not None:
            session["last_seen"] = time.monotonic()

    def drop(self, session_key: tuple[tuple[str, int], str]) -> None:
        session = self.sessions.pop(session_key, None)
        if not session:
            return
        transport = session.get("transport")
        if transport is not None:
            transport.close()

    def classify_backend(self, data: bytes) -> tuple[str, tuple[str, int]]:
        if self.openvpn_enabled:
            if self.slowdns_zone:
                question_name = dns_question_name(data)
                if question_name and (
                    question_name == self.slowdns_zone
                    or question_name.endswith("." + self.slowdns_zone)
                ):
                    return "slowdns", self.slowdns_backend
                return "openvpn", self.openvpn_backend
            if looks_like_dns_query(data):
                return "slowdns", self.slowdns_backend
            return "openvpn", self.openvpn_backend
        if self.slowdns_zone:
            question_name = dns_question_name(data)
            if question_name and (
                question_name == self.slowdns_zone
                or question_name.endswith("." + self.slowdns_zone)
            ):
                return "slowdns", self.slowdns_backend
        if looks_like_dns_query(data):
            return "slowdns", self.slowdns_backend
        return "slowdns", self.slowdns_backend

    async def ensure_session(self, addr: tuple[str, int], data: bytes) -> dict[str, object]:
        backend_name, backend_addr = self.classify_backend(data)
        session_key = (addr, backend_name)
        session = self.sessions.get(session_key)
        if session is not None:
            session["last_seen"] = time.monotonic()
            return session

        protocol = BackendSession(self, session_key)
        transport, _ = await self.loop.create_datagram_endpoint(
            lambda: protocol,
            remote_addr=backend_addr,
        )
        session = {
            "transport": transport,
            "last_seen": time.monotonic(),
        }
        self.sessions[session_key] = session
        return session

    async def handle_packet(self, data: bytes, addr: tuple[str, int]) -> None:
        session = await self.ensure_session(addr, data)
        transport = session["transport"]
        transport.sendto(data)  # type: ignore[union-attr]
        session["last_seen"] = time.monotonic()

    async def reap_sessions(self) -> None:
        while True:
            await asyncio.sleep(30)
            now = time.monotonic()
            for addr, session in list(self.sessions.items()):
                if now - float(session.get("last_seen", now)) > self.idle_timeout:
                    self.drop(addr)


async def main_async(args: argparse.Namespace) -> None:
    loop = asyncio.get_running_loop()
    protocol = Udp53MuxProtocol(
        loop,
        parse_host_port(args.slowdns_backend),
        str(args.slowdns_zone or ""),
        parse_host_port(args.openvpn_backend),
        args.enable_openvpn,
        args.idle_timeout,
    )
    transport, _ = await loop.create_datagram_endpoint(
        lambda: protocol,
        local_addr=(args.listen_host, args.listen_port),
    )
    reap_task = asyncio.create_task(protocol.reap_sessions())
    try:
        await asyncio.Future()
    finally:
        reap_task.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await reap_task
        transport.close()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--listen-host", default="0.0.0.0")
    parser.add_argument("--listen-port", type=int, default=53)
    parser.add_argument("--slowdns-backend", default="127.0.0.1:5300")
    parser.add_argument("--slowdns-zone", default="")
    parser.add_argument("--openvpn-backend", default="127.0.0.1:25000")
    parser.add_argument("--openvpn-enabled", default="0")
    parser.add_argument("--idle-timeout", type=float, default=180.0)
    args = parser.parse_args()
    args.enable_openvpn = str(args.openvpn_enabled).strip().lower() in {"1", "true", "yes", "on"}
    asyncio.run(main_async(args))


if __name__ == "__main__":
    main()
PY
  chmod 755 "${UDP53_MUX_SCRIPT}"

  cat >/etc/systemd/system/${UDP53_MUX_SERVICE}.service <<EOF
[Unit]
Description=IPTunnel UDP 53 Demultiplexer
After=network.target iptunnel-slowdns.service openvpn-server@iptunnel-udp.service
Wants=iptunnel-slowdns.service openvpn-server@iptunnel-udp.service

[Service]
Type=simple
EnvironmentFile=${UDP53_MUX_ENV}
ExecStart=/usr/bin/python3 ${UDP53_MUX_SCRIPT} --listen-host \$LISTEN_HOST --listen-port \$LISTEN_PORT --slowdns-backend \$SLOWDNS_BACKEND --slowdns-zone \$SLOWDNS_ZONE --openvpn-backend \$OPENVPN_BACKEND --openvpn-enabled \$OPENVPN_ENABLED --idle-timeout \$SESSION_IDLE_TIMEOUT
Restart=always
RestartSec=2
LimitNOFILE=1048576
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

  cleanup_ports="$(normalize_udp_port_csv "53,${OPENVPN_UDP_PUBLIC_PORTS},${OPENVPN_UDP_PREVIOUS_PORTS}")"
  IFS=',' read -r -a cleanup_port_items <<< "${cleanup_ports}"
  for public_port in "${cleanup_port_items[@]}"; do
    [[ -n "${public_port}" ]] || continue
    if [[ -n "${MAIN_IFACE}" ]]; then
      while iptables -t nat -D PREROUTING -i "${MAIN_IFACE}" -p udp --dport "${public_port}" -j REDIRECT --to-ports ${OPENVPN_UDP_INTERNAL_PORT} >/dev/null 2>&1; do :; done
    fi
    while iptables -t nat -D PREROUTING -p udp --dport "${public_port}" -j REDIRECT --to-ports ${OPENVPN_UDP_INTERNAL_PORT} >/dev/null 2>&1; do :; done
    while iptables -D INPUT -p udp --dport "${public_port}" -j ACCEPT >/dev/null 2>&1; do :; done
  done
  if [[ -n "${MAIN_IFACE}" ]]; then
    while iptables -t nat -D PREROUTING -i "${MAIN_IFACE}" -p udp --dport 53 -j REDIRECT --to-ports ${SLOWDNS_INTERNAL_PORT} >/dev/null 2>&1; do :; done
  fi
  while iptables -t nat -D PREROUTING -p udp --dport 53 -j REDIRECT --to-ports ${SLOWDNS_INTERNAL_PORT} >/dev/null 2>&1; do :; done
  systemctl daemon-reload
  while iptables -C INPUT -p udp --dport 53 -j ACCEPT >/dev/null 2>&1; do
    iptables -D INPUT -p udp --dport 53 -j ACCEPT
  done
  while iptables -C INPUT -p udp --dport ${SLOWDNS_INTERNAL_PORT} -j ACCEPT >/dev/null 2>&1; do
    iptables -D INPUT -p udp --dport ${SLOWDNS_INTERNAL_PORT} -j ACCEPT
  done
  while iptables -C INPUT -p udp --dport ${OPENVPN_UDP_INTERNAL_PORT} -j ACCEPT >/dev/null 2>&1; do
    iptables -D INPUT -p udp --dport ${OPENVPN_UDP_INTERNAL_PORT} -j ACCEPT
  done
  if [[ "${ENABLE_OPENVPN}" == "1" ]]; then
    iptables -C INPUT -p udp --dport ${OPENVPN_UDP_INTERNAL_PORT} -j ACCEPT >/dev/null 2>&1 || \
      iptables -A INPUT -p udp --dport ${OPENVPN_UDP_INTERNAL_PORT} -j ACCEPT
    IFS=',' read -r -a openvpn_port_items <<< "$(normalize_udp_port_csv "${OPENVPN_UDP_PUBLIC_PORTS}")"
    for public_port in "${openvpn_port_items[@]}"; do
      [[ -n "${public_port}" && "${public_port}" != "53" ]] || continue
      iptables -C INPUT -p udp --dport "${public_port}" -j ACCEPT >/dev/null 2>&1 || \
        iptables -A INPUT -p udp --dport "${public_port}" -j ACCEPT
      if [[ -n "${MAIN_IFACE}" ]]; then
        iptables -t nat -C PREROUTING -i "${MAIN_IFACE}" -p udp --dport "${public_port}" -j REDIRECT --to-ports ${OPENVPN_UDP_INTERNAL_PORT} >/dev/null 2>&1 || \
          iptables -t nat -A PREROUTING -i "${MAIN_IFACE}" -p udp --dport "${public_port}" -j REDIRECT --to-ports ${OPENVPN_UDP_INTERNAL_PORT}
      else
        iptables -t nat -C PREROUTING -p udp --dport "${public_port}" -j REDIRECT --to-ports ${OPENVPN_UDP_INTERNAL_PORT} >/dev/null 2>&1 || \
          iptables -t nat -A PREROUTING -p udp --dport "${public_port}" -j REDIRECT --to-ports ${OPENVPN_UDP_INTERNAL_PORT}
      fi
    done
  fi

  case "${udp53_mode}" in
    openvpn)
      if [[ "${ENABLE_OPENVPN}" == "1" ]]; then
        iptables -C INPUT -p udp --dport 53 -j ACCEPT >/dev/null 2>&1 || \
          iptables -A INPUT -p udp --dport 53 -j ACCEPT
        iptables -C INPUT -p udp --dport ${OPENVPN_UDP_INTERNAL_PORT} -j ACCEPT >/dev/null 2>&1 || \
          iptables -A INPUT -p udp --dport ${OPENVPN_UDP_INTERNAL_PORT} -j ACCEPT
        if [[ -n "${MAIN_IFACE}" ]]; then
          iptables -t nat -C PREROUTING -i "${MAIN_IFACE}" -p udp --dport 53 -j REDIRECT --to-ports ${OPENVPN_UDP_INTERNAL_PORT} >/dev/null 2>&1 || \
            iptables -t nat -A PREROUTING -i "${MAIN_IFACE}" -p udp --dport 53 -j REDIRECT --to-ports ${OPENVPN_UDP_INTERNAL_PORT}
        else
          iptables -t nat -C PREROUTING -p udp --dport 53 -j REDIRECT --to-ports ${OPENVPN_UDP_INTERNAL_PORT} >/dev/null 2>&1 || \
            iptables -t nat -A PREROUTING -p udp --dport 53 -j REDIRECT --to-ports ${OPENVPN_UDP_INTERNAL_PORT}
        fi
      fi
      systemctl disable --now "${UDP53_MUX_SERVICE}" >/dev/null 2>&1 || true
      ;;
    shared)
      if [[ "${ENABLE_OPENVPN}" == "1" ]]; then
        iptables -C INPUT -p udp --dport 53 -j ACCEPT >/dev/null 2>&1 || \
          iptables -A INPUT -p udp --dport 53 -j ACCEPT
        iptables -C INPUT -p udp --dport ${SLOWDNS_INTERNAL_PORT} -j ACCEPT >/dev/null 2>&1 || \
          iptables -A INPUT -p udp --dport ${SLOWDNS_INTERNAL_PORT} -j ACCEPT
        iptables -C INPUT -p udp --dport ${OPENVPN_UDP_INTERNAL_PORT} -j ACCEPT >/dev/null 2>&1 || \
          iptables -A INPUT -p udp --dport ${OPENVPN_UDP_INTERNAL_PORT} -j ACCEPT
        systemctl enable "${UDP53_MUX_SERVICE}" >/dev/null 2>&1 || true
        systemctl restart "${UDP53_MUX_SERVICE}"
        systemctl is-active --quiet "${UDP53_MUX_SERVICE}"
      else
        iptables -C INPUT -p udp --dport ${SLOWDNS_INTERNAL_PORT} -j ACCEPT >/dev/null 2>&1 || \
          iptables -A INPUT -p udp --dport ${SLOWDNS_INTERNAL_PORT} -j ACCEPT
        if [[ -n "${MAIN_IFACE}" ]]; then
          iptables -t nat -C PREROUTING -i "${MAIN_IFACE}" -p udp --dport 53 -j REDIRECT --to-ports ${SLOWDNS_INTERNAL_PORT} >/dev/null 2>&1 || \
            iptables -t nat -A PREROUTING -i "${MAIN_IFACE}" -p udp --dport 53 -j REDIRECT --to-ports ${SLOWDNS_INTERNAL_PORT}
        else
          iptables -t nat -C PREROUTING -p udp --dport 53 -j REDIRECT --to-ports ${SLOWDNS_INTERNAL_PORT} >/dev/null 2>&1 || \
            iptables -t nat -A PREROUTING -p udp --dport 53 -j REDIRECT --to-ports ${SLOWDNS_INTERNAL_PORT}
        fi
        systemctl disable --now "${UDP53_MUX_SERVICE}" >/dev/null 2>&1 || true
      fi
      ;;
    *)
      iptables -C INPUT -p udp --dport ${SLOWDNS_INTERNAL_PORT} -j ACCEPT >/dev/null 2>&1 || \
        iptables -A INPUT -p udp --dport ${SLOWDNS_INTERNAL_PORT} -j ACCEPT
      if [[ -n "${MAIN_IFACE}" ]]; then
        iptables -t nat -C PREROUTING -i "${MAIN_IFACE}" -p udp --dport 53 -j REDIRECT --to-ports ${SLOWDNS_INTERNAL_PORT} >/dev/null 2>&1 || \
          iptables -t nat -A PREROUTING -i "${MAIN_IFACE}" -p udp --dport 53 -j REDIRECT --to-ports ${SLOWDNS_INTERNAL_PORT}
      else
        iptables -t nat -C PREROUTING -p udp --dport 53 -j REDIRECT --to-ports ${SLOWDNS_INTERNAL_PORT} >/dev/null 2>&1 || \
          iptables -t nat -A PREROUTING -p udp --dport 53 -j REDIRECT --to-ports ${SLOWDNS_INTERNAL_PORT}
      fi
      systemctl disable --now "${UDP53_MUX_SERVICE}" >/dev/null 2>&1 || true
      ;;
  esac
  netfilter-persistent save >/dev/null 2>&1 || true
}

install_xray_binary() {
  xr_bin="$(command -v xray || true)"
  if [[ -n "$xr_bin" ]]; then
    return 0
  fi
  curl -fsSL https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh -o /tmp/iptunnel-install-xray.sh
  bash /tmp/iptunnel-install-xray.sh install
  rm -f /tmp/iptunnel-install-xray.sh
  xr_bin="$(command -v xray || true)"
  if [[ -z "$xr_bin" ]]; then
    echo "Failed to install Xray" >&2
    exit 1
  fi
}

write_xray_configs() {
  mkdir -p "$XRAY_DIR" "$XRAY_LOG_DIR"

  cat >"$XRAY_DIR/vmess.json" <<'EOF'
{
  "log": {
    "access": "none",
    "error": "/var/log/iptunnel/xray/vmess-error.log",
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": 10080,
      "protocol": "vmess",
      "settings": {
        "clients": []
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "/vmess"
        }
      }
    },
    {
      "listen": "127.0.0.1",
      "port": 10081,
      "protocol": "vmess",
      "settings": {
        "clients": []
      },
      "streamSettings": {
        "network": "grpc",
        "grpcSettings": {
          "serviceName": "vmess"
        }
      }
    },
    {
      "listen": "127.0.0.1",
      "port": 10082,
      "protocol": "vmess",
      "settings": {
        "clients": []
      },
      "streamSettings": {
        "network": "httpupgrade",
        "httpupgradeSettings": {
          "acceptProxyProtocol": true,
          "path": "/upvmess"
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {}
    },
    {
      "protocol": "blackhole",
      "settings": {},
      "tag": "blocked"
    }
  ]
}
EOF

  cat >"$XRAY_DIR/vless.json" <<'EOF'
{
  "log": {
    "access": "none",
    "error": "/var/log/iptunnel/xray/vless-error.log",
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": 11080,
      "protocol": "vless",
      "settings": {
        "clients": [],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "/vless"
        }
      }
    },
    {
      "listen": "127.0.0.1",
      "port": 11081,
      "protocol": "vless",
      "settings": {
        "clients": [],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "grpc",
        "grpcSettings": {
          "serviceName": "vless"
        }
      }
    },
    {
      "listen": "127.0.0.1",
      "port": 11082,
      "protocol": "vless",
      "settings": {
        "clients": [],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "httpupgrade",
        "httpupgradeSettings": {
          "acceptProxyProtocol": true,
          "path": "/upvless"
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {}
    },
    {
      "protocol": "blackhole",
      "settings": {},
      "tag": "blocked"
    }
  ]
}
EOF

  cat >"$XRAY_DIR/trojan.json" <<'EOF'
{
  "log": {
    "access": "none",
    "error": "/var/log/iptunnel/xray/trojan-error.log",
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": 12080,
      "protocol": "trojan",
      "settings": {
        "clients": []
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "/trojan"
        }
      }
    },
    {
      "listen": "127.0.0.1",
      "port": 12081,
      "protocol": "trojan",
      "settings": {
        "clients": []
      },
      "streamSettings": {
        "network": "grpc",
        "grpcSettings": {
          "serviceName": "trojan"
        }
      }
    },
    {
      "listen": "127.0.0.1",
      "port": 12082,
      "protocol": "trojan",
      "settings": {
        "clients": []
      },
      "streamSettings": {
        "network": "httpupgrade",
        "httpupgradeSettings": {
          "acceptProxyProtocol": true,
          "path": "/uptrojan"
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {}
    },
    {
      "protocol": "blackhole",
      "settings": {},
      "tag": "blocked"
    }
  ]
}
EOF
}

write_xray_units() {
  cat >/etc/systemd/system/iptunnel-vmess.service <<EOF
[Unit]
Description=IPTunnel VMess
After=network.target

[Service]
Type=simple
ExecStart=${xr_bin} run -config ${XRAY_DIR}/vmess.json
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

  cat >/etc/systemd/system/iptunnel-vless.service <<EOF
[Unit]
Description=IPTunnel VLESS
After=network.target

[Service]
Type=simple
ExecStart=${xr_bin} run -config ${XRAY_DIR}/vless.json
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

  cat >/etc/systemd/system/iptunnel-trojan.service <<EOF
[Unit]
Description=IPTunnel Trojan
After=network.target

[Service]
Type=simple
ExecStart=${xr_bin} run -config ${XRAY_DIR}/trojan.json
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
}

configure_squid() {
  cat >/etc/squid/squid.conf <<EOF
http_port 0.0.0.0:3128
http_port 0.0.0.0:8080
visible_hostname ${DOMAIN}
acl Safe_ports port 22
acl Safe_ports port 80
acl Safe_ports port 21
acl Safe_ports port 443
acl Safe_ports port 109
acl Safe_ports port 143
acl Safe_ports port 2083
acl Safe_ports port 8443
acl Safe_ports port 70
acl Safe_ports port 210
acl Safe_ports port 1025-65535
acl Safe_ports port 280
acl Safe_ports port 488
acl Safe_ports port 591
acl Safe_ports port 777
acl CONNECT method CONNECT
http_access deny !Safe_ports
http_access deny CONNECT !Safe_ports
http_access allow all
cache deny all
dns_v4_first on
shutdown_lifetime 1 seconds
via off
forwarded_for off
request_header_access X-Forwarded-For deny all
request_header_access Via deny all
request_header_access Cache-Control deny all
coredump_dir /var/spool/squid
EOF
  systemctl enable squid >/dev/null 2>&1 || true
  systemctl restart squid >/dev/null 2>&1 || true
}

configure_ssh_ws() {
  cat >"${SSH_WS_SCRIPT}" <<'PY'
#!/usr/bin/env python3
import argparse
import asyncio
import base64
import contextlib
import hashlib
import socket


MAX_HEADER_SIZE = 16384


def tune_stream(writer: asyncio.StreamWriter) -> None:
    sock = writer.get_extra_info("socket")
    if sock is None:
        return
    with contextlib.suppress(OSError):
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    with contextlib.suppress(OSError):
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)


def normalize_path(value: str) -> str:
    path = (value or "").strip().split("?", 1)[0]
    if not path:
        path = "/"
    if not path.startswith("/"):
        path = "/" + path
    if len(path) > 1:
        path = path.rstrip("/")
    return path or "/"


def websocket_accept_value(key: str) -> str:
    seed = (key.strip() + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode("utf-8")
    return base64.b64encode(hashlib.sha1(seed).digest()).decode("ascii")


async def read_http_request(reader: asyncio.StreamReader) -> tuple[str, dict[str, str], bytes]:
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = await reader.read(4096)
        if not chunk:
            break
        data += chunk
        if len(data) > MAX_HEADER_SIZE:
            raise ValueError("request header too large")

    head, separator, rest = data.partition(b"\r\n\r\n")
    if not separator:
        raise ValueError("incomplete request")

    lines = head.decode("iso-8859-1", errors="replace").split("\r\n")
    if not lines or len(lines[0].split()) < 3:
        raise ValueError("invalid request line")

    method, path, _version = lines[0].split(None, 2)
    if method.upper() != "GET":
        raise ValueError("method not allowed")

    headers: dict[str, str] = {}
    for line in lines[1:]:
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        headers[key.strip().lower()] = value.strip()

    return path, headers, rest


async def pipe_stream(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    while True:
        payload = await reader.read(65535)
        if not payload:
            break
        writer.write(payload)
        await writer.drain()


async def write_error(writer: asyncio.StreamWriter, status: str, message: str) -> None:
    body = (message + "\n").encode("utf-8")
    response = (
        f"HTTP/1.1 {status}\r\n"
        "Content-Type: text/plain\r\n"
        f"Content-Length: {len(body)}\r\n"
        "Connection: close\r\n"
        "\r\n"
    ).encode("utf-8") + body
    writer.write(response)
    await writer.drain()
    writer.close()
    with contextlib.suppress(Exception):
        await writer.wait_closed()


async def handle_client(
    client_reader: asyncio.StreamReader,
    client_writer: asyncio.StreamWriter,
    target_host: str,
    target_port: int,
    allowed_paths: set[str],
) -> None:
    upstream_writer: asyncio.StreamWriter | None = None
    try:
        tune_stream(client_writer)
        request_path, headers, leftover = await read_http_request(client_reader)
        request_path = normalize_path(request_path)

        if allowed_paths and request_path not in allowed_paths:
            await write_error(client_writer, "404 Not Found", "invalid websocket path")
            return

        upgrade = headers.get("upgrade", "").lower()
        connection = headers.get("connection", "").lower()
        if upgrade != "websocket" or "upgrade" not in connection:
            await write_error(client_writer, "400 Bad Request", "missing websocket upgrade headers")
            return

        upstream_reader, upstream_writer = await asyncio.open_connection(target_host, target_port)
        tune_stream(upstream_writer)

        accept_value = websocket_accept_value(headers.get("sec-websocket-key", ""))

        response = (
            "HTTP/1.1 101 Switching Protocols\r\n"
            "Connection: Upgrade\r\n"
            "Upgrade: websocket\r\n"
            f"Sec-WebSocket-Accept: {accept_value}\r\n"
            "\r\n"
        ).encode("utf-8")
        client_writer.write(response)
        await client_writer.drain()

        if leftover:
            upstream_writer.write(leftover)
            await upstream_writer.drain()

        tasks = {
            asyncio.create_task(pipe_stream(client_reader, upstream_writer)),
            asyncio.create_task(pipe_stream(upstream_reader, client_writer)),
        }
        done, pending = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
        for task in pending:
            task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await task
        for task in done:
            with contextlib.suppress(Exception):
                await task
    except Exception as exc:
        if not client_writer.is_closing():
            await write_error(client_writer, "400 Bad Request", str(exc))
        return
    finally:
        if upstream_writer is not None:
            upstream_writer.close()
            with contextlib.suppress(Exception):
                await upstream_writer.wait_closed()
        if not client_writer.is_closing():
            client_writer.close()
            with contextlib.suppress(Exception):
                await client_writer.wait_closed()


async def run_server(args: argparse.Namespace) -> None:
    allowed_paths = {normalize_path(path) for path in (args.path or ["/sshws"])}
    server = await asyncio.start_server(
        lambda reader, writer: handle_client(
            reader,
            writer,
            args.target_host,
            args.target_port,
            allowed_paths,
        ),
        args.listen,
        args.port,
        backlog=4096,
    )
    async with server:
        await server.serve_forever()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--listen", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=19080)
    parser.add_argument("--target-host", default="127.0.0.1")
    parser.add_argument("--target-port", type=int, default=22)
    parser.add_argument("--path", action="append", default=[])
    args = parser.parse_args()
    asyncio.run(run_server(args))


if __name__ == "__main__":
    main()
PY
  chmod 755 "${SSH_WS_SCRIPT}"

  cat >/etc/systemd/system/iptunnel-ssh-ws.service <<EOF
[Unit]
Description=IPTunnel SSH over WebSocket
After=network.target ssh.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 ${SSH_WS_SCRIPT} --listen 127.0.0.1 --port ${SSH_WS_LOCAL_PORT} --target-host 127.0.0.1 --target-port 22$(ssh_ws_exec_args "${SSH_WS_PATHS_CSV}")
Restart=always
RestartSec=2
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable iptunnel-ssh-ws >/dev/null 2>&1 || true
  systemctl restart iptunnel-ssh-ws >/dev/null 2>&1 || true
}

configure_edge_proxy() {
  cat >/etc/systemd/system/${EDGE_PROXY_SERVICE}.service <<EOF
[Unit]
Description=IPTunnel shared edge proxy
After=network.target ssh.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 ${SSH_WS_SCRIPT} --listen 127.0.0.1 --port ${EDGE_PROXY_LOCAL_PORT} --target-host 127.0.0.1 --target-port 22$(ssh_ws_exec_args "${SSH_WS_PATHS_CSV}")
Restart=always
RestartSec=2
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "${EDGE_PROXY_SERVICE}" >/dev/null 2>&1 || true
  systemctl restart "${EDGE_PROXY_SERVICE}" >/dev/null 2>&1 || true
}

configure_fronting_proxy() {
  cat >"${FRONTING_PROXY_SCRIPT}" <<'PY'
#!/usr/bin/env python3
import argparse
import asyncio
import contextlib
import socket
from urllib.parse import urlsplit


MAX_HEADER_SIZE = 65535
DEFAULT_TARGET = "127.0.0.1:22"
LOCAL_TARGET_HOSTS = {"127.0.0.1", "localhost"}
RESPONSE = (
    "HTTP/1.1 101 Switching Protocols\r\n"
    "Connection: Upgrade\r\n"
    "Upgrade: websocket\r\n"
    "Sec-WebSocket-Accept: foo\r\n"
    "\r\n"
).encode("utf-8")


def tune_stream(writer: asyncio.StreamWriter) -> None:
    sock = writer.get_extra_info("socket")
    if sock is None:
        return
    with contextlib.suppress(OSError):
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    with contextlib.suppress(OSError):
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)


def parse_host_port(value: str) -> tuple[str, int]:
    host, sep, port = value.rpartition(":")
    if not sep:
        return value.strip(), 443
    return host.strip(), int(port)


def normalize_target(value: str) -> str:
    raw = (value or "").strip()
    if not raw:
        return ""
    if "://" in raw:
        parsed = urlsplit(raw)
        if parsed.scheme and parsed.netloc:
            raw = parsed.netloc
        elif parsed.scheme and parsed.path:
            raw = parsed.path
    host, port = parse_host_port(raw)
    if not host:
        return ""
    return f"{host}:{port}"



async def read_http_request(reader: asyncio.StreamReader) -> tuple[str, str, dict[str, str], bytes]:
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = await reader.read(4096)
        if not chunk:
            break
        data += chunk
        if len(data) > MAX_HEADER_SIZE:
            raise ValueError("request header too large")
    head, separator, rest = data.partition(b"\r\n\r\n")
    if not separator:
        raise ValueError("incomplete request")
    lines = head.decode("iso-8859-1", errors="replace").split("\r\n")
    if not lines or len(lines[0].split()) < 3:
        raise ValueError("invalid request line")
    method, path, _version = lines[0].split(None, 2)
    headers: dict[str, str] = {}
    for line in lines[1:]:
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        headers[key.strip().lower()] = value.strip()
    return method.upper(), path, headers, rest


def target_from_request(method: str, path: str, headers: dict[str, str], default_target: str) -> str:
    candidates = [
        headers.get("x-real-host", ""),
        headers.get("x-online-host", ""),
        headers.get("x-forward-host", ""),
    ]
    if method == "CONNECT":
        candidates.append(path)
    elif path.startswith("http://") or path.startswith("https://"):
        candidates.append(path)
    candidates.append(default_target)
    for candidate in candidates:
        normalized = normalize_target(candidate)
        if not normalized:
            continue
        host, port = parse_host_port(normalized)
        if host.lower() in LOCAL_TARGET_HOSTS:
            return f"{host}:{port}"
    return normalize_target(default_target) or DEFAULT_TARGET


async def pipe_stream(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    while True:
        payload = await reader.read(65535)
        if not payload:
            break
        writer.write(payload)
        await writer.drain()


async def write_error(writer: asyncio.StreamWriter, status: str, message: str) -> None:
    body = (message + "\n").encode("utf-8")
    response = (
        f"HTTP/1.1 {status}\r\n"
        "Content-Type: text/plain\r\n"
        f"Content-Length: {len(body)}\r\n"
        "Connection: close\r\n"
        "\r\n"
    ).encode("utf-8") + body
    writer.write(response)
    await writer.drain()
    writer.close()
    with contextlib.suppress(Exception):
        await writer.wait_closed()


async def handle_client(
    client_reader: asyncio.StreamReader,
    client_writer: asyncio.StreamWriter,
    default_target: str,
) -> None:
    upstream_writer: asyncio.StreamWriter | None = None
    try:
        tune_stream(client_writer)
        method, path, headers, leftover = await read_http_request(client_reader)
        target = target_from_request(method, path, headers, default_target)
        target_host, target_port = parse_host_port(target)
        upstream_reader, upstream_writer = await asyncio.open_connection(target_host, target_port)
        tune_stream(upstream_writer)
        client_writer.write(RESPONSE)
        await client_writer.drain()
        if leftover:
            upstream_writer.write(leftover)
            await upstream_writer.drain()
        tasks = {
            asyncio.create_task(pipe_stream(client_reader, upstream_writer)),
            asyncio.create_task(pipe_stream(upstream_reader, client_writer)),
        }
        done, pending = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
        for task in pending:
            task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await task
        for task in done:
            with contextlib.suppress(Exception):
                await task
    except Exception as exc:
        if not client_writer.is_closing():
            await write_error(client_writer, "400 Bad Request", str(exc))
        return
    finally:
        if upstream_writer is not None:
            upstream_writer.close()
            with contextlib.suppress(Exception):
                await upstream_writer.wait_closed()
        if not client_writer.is_closing():
            client_writer.close()
            with contextlib.suppress(Exception):
                await client_writer.wait_closed()


async def run_server(args: argparse.Namespace) -> None:
    server = await asyncio.start_server(
        lambda reader, writer: handle_client(reader, writer, args.default_target),
        args.listen,
        args.port,
        backlog=4096,
    )
    async with server:
        await server.serve_forever()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--listen", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=701)
    parser.add_argument("--default-target", default=DEFAULT_TARGET)
    args = parser.parse_args()
    asyncio.run(run_server(args))


if __name__ == "__main__":
    main()
PY
  chmod 755 "${FRONTING_PROXY_SCRIPT}"

  cat >/etc/systemd/system/${FRONTING_PROXY_SERVICE}.service <<EOF
[Unit]
Description=IPTunnel fronting compatibility proxy
After=network.target ssh.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 ${FRONTING_PROXY_SCRIPT} --listen 127.0.0.1 --port ${FRONTING_PROXY_LOCAL_PORT} --default-target 127.0.0.1:22
Restart=always
RestartSec=2
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "${FRONTING_PROXY_SERVICE}" >/dev/null 2>&1 || true
  systemctl restart "${FRONTING_PROXY_SERVICE}" >/dev/null 2>&1 || true
}

configure_ssh_ssl() {
  local stunnel_bin=""

  stunnel_bin="$(command -v stunnel4 || command -v stunnel || true)"
  if [[ -z "${stunnel_bin}" ]]; then
    echo "stunnel binary not found after install" >&2
    exit 1
  fi

  cat "${CERT_DIR}/cert.crt" "${CERT_DIR}/cert.key" >"${SSH_SSL_PEM}"
  chmod 600 "${SSH_SSL_PEM}"

  mkdir -p /etc/stunnel
  cat >"${SSH_SSL_CONFIG}" <<EOF
foreground = yes
pid =
debug = notice
cert = ${SSH_SSL_PEM}
sslVersionMin = TLSv1
sslVersionMax = TLSv1.2
options = NO_SSLv2
options = NO_SSLv3
socket = l:TCP_NODELAY=1
socket = r:TCP_NODELAY=1

[iptunnel-ssh-ssl-8443]
accept = ${SSH_SSL_PUBLIC_8443}
connect = 127.0.0.1:22

[iptunnel-ssh-ssl-2083]
accept = ${SSH_SSL_PUBLIC_2083}
connect = 127.0.0.1:109
EOF

  cat >/etc/systemd/system/iptunnel-ssh-ssl.service <<EOF
[Unit]
Description=IPTunnel SSH over SSL
After=network.target ssh.service dropbear.service

[Service]
Type=simple
ExecStart=${stunnel_bin} ${SSH_SSL_CONFIG}
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable iptunnel-ssh-ssl >/dev/null 2>&1 || true
  systemctl restart iptunnel-ssh-ssl >/dev/null 2>&1 || true
}

configure_ssl_mux() {
  cat >/etc/haproxy/haproxy.cfg <<EOF
global
    log /dev/log local0
    log /dev/log local1 notice
    chroot /var/lib/haproxy
    stats socket /run/haproxy/admin.sock mode 660 level admin expose-fd listeners
    stats timeout 30s
    maxconn 200000
    tune.bufsize 32768
    user haproxy
    group haproxy
    daemon

defaults
    log global
    mode tcp
    option tcplog
    option dontlognull
    timeout connect 5s
    timeout client 24h
    timeout server 24h
    timeout client-fin 30s
    timeout server-fin 30s
    timeout tunnel 24h

# ====================================================================
# TIER 1: PORT 80 (Cleartext payloads & raw SSH)
# ====================================================================
frontend iptunnel_mux_80
    bind *:80
    mode tcp
    tcp-request inspect-delay 1s

    acl is_ssh payload(0,7) -m bin 5353482d322e30

    tcp-request content accept if is_ssh
    tcp-request content accept if HTTP

    use_backend direct_ssh if is_ssh
    default_backend nginx_cleartext

# ====================================================================
# TIER 1: PORT 443 (TLS web, SSL payloads, raw SSH)
# ====================================================================
frontend iptunnel_mux_443
    bind *:443
    mode tcp
    tcp-request inspect-delay 1s

    acl is_ssh payload(0,7) -m bin 5353482d322e30
    acl is_tls req.ssl_hello_type 1
    acl has_web_alpn req.ssl_alpn -m sub h2 http/1.1

    tcp-request content accept if is_ssh
    tcp-request content accept if HTTP
    tcp-request content accept if is_tls

    use_backend direct_ssh if is_ssh
    use_backend nginx_cleartext if HTTP
    use_backend nginx_tls if is_tls has_web_alpn
    default_backend loopback_ssl_terminator

# ====================================================================
# TIER 1: PORT 2082 (same edge behavior as 443 for WS compatibility)
# ====================================================================
frontend iptunnel_mux_2082
    bind *:2082
    mode tcp
    tcp-request inspect-delay 1s

    acl is_ssh payload(0,7) -m bin 5353482d322e30
    acl is_tls req.ssl_hello_type 1
    acl has_web_alpn req.ssl_alpn -m sub h2 http/1.1

    tcp-request content accept if is_ssh
    tcp-request content accept if HTTP
    tcp-request content accept if is_tls

    use_backend direct_ssh if is_ssh
    use_backend nginx_cleartext if HTTP
    use_backend nginx_tls if is_tls has_web_alpn
    default_backend loopback_ssl_terminator

# ====================================================================
# TIER 2: INTERNAL DECRYPTOR (Any-SNI SSH-TLS fallback)
# ====================================================================
frontend iptunnel_internal_decryptor
    bind 127.0.0.1:${HAPROXY_INTERNAL_DECRYPT_PORT} ssl crt ${SSH_SSL_PEM}
    mode tcp
    tcp-request inspect-delay 1s

    acl is_ssh payload(0,7) -m bin 5353482d322e30
    tcp-request content accept if is_ssh
    tcp-request content accept if HTTP

    use_backend direct_ssh if is_ssh
    default_backend nginx_cleartext

backend direct_ssh
    mode tcp
    server ssh_server 127.0.0.1:22

backend nginx_cleartext
    mode tcp
    server nginx_http 127.0.0.1:${NGINX_HTTP_LOCAL_PORT}

backend nginx_tls
    mode tcp
    server nginx_tls 127.0.0.1:${NGINX_TLS_LOCAL_PORT}

backend loopback_ssl_terminator
    mode tcp
    server haproxy_ssl 127.0.0.1:${HAPROXY_INTERNAL_DECRYPT_PORT}
EOF

  systemctl disable --now iptunnel-sslh >/dev/null 2>&1 || true
  systemctl enable haproxy >/dev/null 2>&1 || true
  systemctl restart haproxy >/dev/null 2>&1 || true
}

enable_ip_forwarding() {
  cat >/etc/sysctl.d/99-iptunnel.conf <<'EOF'
net.ipv4.ip_forward=1
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_tw_reuse=1
net.ipv4.ip_local_port_range=10240 65535
net.core.somaxconn=65535
net.core.netdev_max_backlog=250000
net.core.rmem_max=134217728
net.core.wmem_max=134217728
net.ipv4.tcp_rmem=4096 87380 134217728
net.ipv4.tcp_wmem=4096 65536 134217728
net.ipv4.udp_rmem_min=8192
net.ipv4.udp_wmem_min=8192
EOF
  sysctl --system >/dev/null 2>&1 || true
}

configure_service_limits() {
  local unit
  for unit in nginx.service haproxy.service squid.service openvpn-server@.service; do
    mkdir -p "/etc/systemd/system/${unit}.d"
    cat >"/etc/systemd/system/${unit}.d/99-iptunnel-performance.conf" <<'EOF'
[Service]
LimitNOFILE=1048576
TasksMax=infinity
EOF
  done
  systemctl daemon-reload
}

configure_openvpn_certs() {
  if [[ -f "${OPENVPN_SERVER_DIR}/ca.crt" && -f "${OPENVPN_SERVER_DIR}/server.crt" && -f "${OPENVPN_SERVER_DIR}/server.key" ]]; then
    mkdir -p "${OPENVPN_SERVER_DIR}"
    if [[ ! -f "${OPENVPN_SERVER_DIR}/tls-auth.key" ]]; then
      openvpn --genkey secret "${OPENVPN_SERVER_DIR}/tls-auth.key"
    fi
    return 0
  fi

  rm -rf "${OPENVPN_EASYRSA_DIR}"
  mkdir -p "${OPENVPN_EASYRSA_DIR}"
  cp -R /usr/share/easy-rsa/* "${OPENVPN_EASYRSA_DIR}/"

  (
    cd "${OPENVPN_EASYRSA_DIR}"
    EASYRSA_BATCH=1 ./easyrsa init-pki
    EASYRSA_BATCH=1 EASYRSA_REQ_CN="iptunnel-ca" ./easyrsa build-ca nopass
    EASYRSA_BATCH=1 EASYRSA_REQ_CN="${DOMAIN}" ./easyrsa gen-req server nopass
    EASYRSA_BATCH=1 ./easyrsa sign-req server server
    EASYRSA_BATCH=1 EASYRSA_REQ_CN="iptunnel-client" ./easyrsa gen-req client nopass
    EASYRSA_BATCH=1 ./easyrsa sign-req client client
    EASYRSA_BATCH=1 ./easyrsa gen-dh
  )

  mkdir -p "${OPENVPN_SERVER_DIR}"
  cp "${OPENVPN_EASYRSA_DIR}/pki/ca.crt" "${OPENVPN_SERVER_DIR}/ca.crt"
  cp "${OPENVPN_EASYRSA_DIR}/pki/issued/server.crt" "${OPENVPN_SERVER_DIR}/server.crt"
  cp "${OPENVPN_EASYRSA_DIR}/pki/private/server.key" "${OPENVPN_SERVER_DIR}/server.key"
  cp "${OPENVPN_EASYRSA_DIR}/pki/dh.pem" "${OPENVPN_SERVER_DIR}/dh.pem"
  cp "${OPENVPN_EASYRSA_DIR}/pki/issued/client.crt" "${OPENVPN_SERVER_DIR}/client.crt"
  cp "${OPENVPN_EASYRSA_DIR}/pki/private/client.key" "${OPENVPN_SERVER_DIR}/client.key"
  openvpn --genkey secret "${OPENVPN_SERVER_DIR}/tls-auth.key"
  (
    cd "${OPENVPN_EASYRSA_DIR}"
    EASYRSA_BATCH=1 ./easyrsa gen-crl
  ) >/dev/null 2>&1 || true
  if [[ -f "${OPENVPN_EASYRSA_DIR}/pki/crl.pem" ]]; then
    cp "${OPENVPN_EASYRSA_DIR}/pki/crl.pem" "${OPENVPN_SERVER_DIR}/crl.pem"
  fi
}

configure_openvpn_server() {
  configure_openvpn_certs
  enable_ip_forwarding

  cat >"${OPENVPN_SERVER_DIR}/iptunnel-tcp.conf" <<EOF
port 1194
proto tcp
dev tun
topology subnet
server 10.8.0.0 255.255.255.0
ifconfig-pool-persist /var/log/openvpn-ipp-tcp.txt
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 1.1.1.1"
push "dhcp-option DNS 8.8.8.8"
remote-cert-eku "TLS Web Client Authentication"
keepalive 10 120
sndbuf 0
rcvbuf 0
push "sndbuf 0"
push "rcvbuf 0"
txqueuelen 1000
persist-key
persist-tun
client-to-client
duplicate-cn
ca ${OPENVPN_SERVER_DIR}/ca.crt
cert ${OPENVPN_SERVER_DIR}/server.crt
key ${OPENVPN_SERVER_DIR}/server.key
dh ${OPENVPN_SERVER_DIR}/dh.pem
tls-version-min 1.2
tls-cipher ${OPENVPN_TLS_CIPHER}
tls-server
tls-auth ${OPENVPN_SERVER_DIR}/tls-auth.key 0
auth ${OPENVPN_AUTH_DIGEST}
cipher ${OPENVPN_CIPHER}
data-ciphers ${OPENVPN_CIPHER}:AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305
data-ciphers-fallback ${OPENVPN_CIPHER}
user nobody
group nogroup
verb 0
status /var/log/openvpn-status-tcp.log
EOF

  cat >"${OPENVPN_SERVER_DIR}/iptunnel-udp.conf" <<EOF
port 25000
proto udp
dev tun
topology subnet
server 10.9.0.0 255.255.255.0
ifconfig-pool-persist /var/log/openvpn-ipp-udp.txt
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 1.1.1.1"
push "dhcp-option DNS 8.8.8.8"
remote-cert-eku "TLS Web Client Authentication"
keepalive 10 120
fast-io
sndbuf 0
rcvbuf 0
push "sndbuf 0"
push "rcvbuf 0"
txqueuelen 1000
persist-key
persist-tun
client-to-client
duplicate-cn
ca ${OPENVPN_SERVER_DIR}/ca.crt
cert ${OPENVPN_SERVER_DIR}/server.crt
key ${OPENVPN_SERVER_DIR}/server.key
dh ${OPENVPN_SERVER_DIR}/dh.pem
tls-version-min 1.2
tls-cipher ${OPENVPN_TLS_CIPHER}
tls-server
tls-auth ${OPENVPN_SERVER_DIR}/tls-auth.key 0
auth ${OPENVPN_AUTH_DIGEST}
cipher ${OPENVPN_CIPHER}
data-ciphers ${OPENVPN_CIPHER}:AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305
data-ciphers-fallback ${OPENVPN_CIPHER}
user nobody
group nogroup
verb 0
status /var/log/openvpn-status-udp.log
explicit-exit-notify 1
EOF

  python3 /opt/iptunnel/provisioning_monitor.py --config "${CONFIG_PATH}" --configure-directory "${OPENVPN_SERVER_DIR}"

  if [[ -n "${MAIN_IFACE}" ]]; then
    iptables -t nat -C POSTROUTING -s 10.8.0.0/24 -o "${MAIN_IFACE}" -j MASQUERADE >/dev/null 2>&1 || \
      iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o "${MAIN_IFACE}" -j MASQUERADE
    iptables -t nat -C POSTROUTING -s 10.9.0.0/24 -o "${MAIN_IFACE}" -j MASQUERADE >/dev/null 2>&1 || \
      iptables -t nat -A POSTROUTING -s 10.9.0.0/24 -o "${MAIN_IFACE}" -j MASQUERADE
    netfilter-persistent save >/dev/null 2>&1 || true
  fi

  write_openvpn_profiles
}

enable_openvpn_udp_runtime() {
  systemctl enable openvpn-server@iptunnel-udp >/dev/null 2>&1 || true
  systemctl restart openvpn-server@iptunnel-udp >/dev/null 2>&1 || true
}

disable_openvpn_udp_runtime() {
  systemctl disable --now openvpn-server@iptunnel-udp >/dev/null 2>&1 || true
  rm -f \
    "${WEB_ROOT}/iptunnel-openvpn-udp.ovpn" \
    "${WEB_ROOT}"/iptunnel-udp-*.ovpn
}

disable_openvpn_tcp_runtime() {
  systemctl disable --now openvpn-server@iptunnel-tcp >/dev/null 2>&1 || true
  rm -f "${WEB_ROOT}/iptunnel-tcp-1194.ovpn"
}

disable_openvpn() {
  systemctl disable --now openvpn-server@iptunnel-tcp >/dev/null 2>&1 || true
  systemctl disable --now openvpn-server@iptunnel-udp >/dev/null 2>&1 || true
  if [[ -n "${MAIN_IFACE}" ]]; then
    while iptables -t nat -D POSTROUTING -s 10.8.0.0/24 -o "${MAIN_IFACE}" -j MASQUERADE >/dev/null 2>&1; do :; done
    while iptables -t nat -D POSTROUTING -s 10.9.0.0/24 -o "${MAIN_IFACE}" -j MASQUERADE >/dev/null 2>&1; do :; done
    netfilter-persistent save >/dev/null 2>&1 || true
  fi
  rm -f \
    "${OPENVPN_SERVER_DIR}/iptunnel-tcp.conf" \
    "${OPENVPN_SERVER_DIR}/iptunnel-udp.conf" \
    "${WEB_ROOT}/iptunnel-tcp-1194.ovpn" \
    "${WEB_ROOT}/iptunnel-openvpn-udp.ovpn" \
    "${WEB_ROOT}/iptunnel-udp-25000.ovpn" \
    "${WEB_ROOT}/iptunnel-udp-53.ovpn" \
    "${WEB_ROOT}"/iptunnel-udp-*.ovpn
}

write_openvpn_profile() {
  local proto="$1"
  local port="$2"
  local name="$3"

  mkdir -p "${WEB_ROOT}"
  cat >"${WEB_ROOT}/${name}" <<EOF
client
dev tun
proto ${proto}
remote ${DOMAIN} ${port}
resolv-retry infinite
nobind
persist-key
persist-tun
sndbuf 0
rcvbuf 0
setenv opt block-outside-dns
remote-cert-tls server
verify-x509-name ${DOMAIN} name
auth ${OPENVPN_AUTH_DIGEST}
cipher ${OPENVPN_CIPHER}
data-ciphers ${OPENVPN_CIPHER}:AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305
data-ciphers-fallback ${OPENVPN_CIPHER}
tls-version-min 1.2
tls-client
tls-cipher ${OPENVPN_TLS_CIPHER}
verb 0
<ca>
$(cat "${OPENVPN_SERVER_DIR}/ca.crt")
</ca>
<cert>
$(cat "${OPENVPN_SERVER_DIR}/client.crt")
</cert>
<key>
$(cat "${OPENVPN_SERVER_DIR}/client.key")
</key>
key-direction 1
<tls-auth>
$(cat "${OPENVPN_SERVER_DIR}/tls-auth.key")
</tls-auth>
EOF
  python3 /opt/iptunnel/provisioning_monitor.py --config "${CONFIG_PATH}" --profile "${WEB_ROOT}/${name}"
  chmod 644 "${WEB_ROOT}/${name}"
}

write_openvpn_profiles() {
  local public_port=""
  local primary_profile=""
  local -a public_ports=()
  mkdir -p "${WEB_ROOT}"
  rm -f "${WEB_ROOT}"/iptunnel-udp-*.ovpn
  rm -f "${WEB_ROOT}/iptunnel-openvpn-udp.ovpn"
  refresh_openvpn_primary_port
  IFS=',' read -r -a public_ports <<< "${OPENVPN_UDP_PUBLIC_PORTS}"
  for public_port in "${public_ports[@]}"; do
    [[ -n "${public_port}" ]] || continue
    write_openvpn_profile udp "${public_port}" "iptunnel-udp-${public_port}.ovpn"
  done
  primary_profile="${WEB_ROOT}/iptunnel-udp-${OPENVPN_UDP_PUBLIC_PORT}.ovpn"
  [[ -f "${primary_profile}" ]] || return 0
  cp -f "${primary_profile}" "${WEB_ROOT}/iptunnel-openvpn-udp.ovpn"
  chmod 644 "${WEB_ROOT}/iptunnel-openvpn-udp.ovpn"
}

sync_runtime_config() {
  if [[ ! -f "${CONFIG_PATH}" ]]; then
    return 0
  fi

  python3 - "${CONFIG_PATH}" "${DOMAIN}" "${PUBLIC_IP}" "${ENABLE_HYSTERIA}" "${HYSTERIA_OBFS}" "${HYSTERIA_PASSWORD}" "${ENABLE_OPENVPN}" "${HYSTERIA_HOP_RANGE}" "${SLOWDNS_UDP53_MODE}" "${OPENVPN_UDP_PUBLIC_PORTS}" <<'PY'
import json
import pathlib
import sys

config_path = pathlib.Path(sys.argv[1])
domain = sys.argv[2]
public_ip = sys.argv[3]
hysteria_enabled = sys.argv[4] == "1"
hysteria_obfs = sys.argv[5]
hysteria_password = sys.argv[6]
openvpn_enabled = sys.argv[7] == "1"
hysteria_hop_range = sys.argv[8]
udp53_mode = str(sys.argv[9] or "slowdns").strip().lower()
openvpn_udp_public_ports_raw = str(sys.argv[10] or "").strip()


def normalize_http_path(value: object, default: str = "/") -> str:
    path = str(value or default).strip().split("?", 1)[0]
    if not path:
        path = default
    if not path.startswith("/"):
        path = "/" + path
    if len(path) > 1:
        path = path.rstrip("/")
    return path or "/"


def dedupe_paths(values: list[object], default: str = "/") -> list[str]:
    normalized: list[str] = []
    for value in values:
        if value is None:
            continue
        path = normalize_http_path(value, default=default)
        if path not in normalized:
            normalized.append(path)
    if normalized:
        return normalized
    return [normalize_http_path(default, default=default)]

if udp53_mode not in {"slowdns", "openvpn", "shared"}:
    udp53_mode = "slowdns"
openvpn_udp_public_ports = []
for raw_port in openvpn_udp_public_ports_raw.split(","):
    try:
        port = int(raw_port.strip())
    except ValueError:
        continue
    if 1 <= port <= 65535 and port not in openvpn_udp_public_ports:
        openvpn_udp_public_ports.append(port)
if udp53_mode in {"openvpn", "shared"}:
    openvpn_udp_public_ports = [53, *[port for port in openvpn_udp_public_ports if port != 53]]
else:
    openvpn_udp_public_ports = [port for port in openvpn_udp_public_ports if port != 53]
openvpn_udp_public_port_int = 53 if 53 in openvpn_udp_public_ports else (openvpn_udp_public_ports[0] if openvpn_udp_public_ports else 53)
effective_openvpn_udp_public_ports = openvpn_udp_public_ports if openvpn_enabled else []

data = json.loads(config_path.read_text(encoding="utf-8"))
data["hostname"] = domain
data["public_ip"] = public_ip

ssh = data.setdefault("ssh", {})
raw_ws_aliases = ssh.get("ws_path_aliases")
if isinstance(raw_ws_aliases, str):
    ws_aliases = [part.strip() for part in raw_ws_aliases.split(",") if part.strip()]
elif isinstance(raw_ws_aliases, list):
    ws_aliases = list(raw_ws_aliases)
else:
    ws_aliases = []
ws_paths = dedupe_paths([ssh.get("ws_path") or "/sshws", *ws_aliases, "/ssh"], default="/sshws")
ssh["ws_path"] = ws_paths[0]
ssh["ws_path_aliases"] = ws_paths[1:]
ports = ssh.setdefault("ports", {})
any_ports = ["22", "80", "109", "143", "443", "2083", "3128", "8080", "8443"]
ports["none"] = "-"
ports["ssh"] = "22"
ports["dropbear"] = "109,143"
ports["ssl"] = "443,2082"
any_ports.insert(6, "2082")
ports["ws"] = "80,443,2082"
ports["slowdns"] = "53" if udp53_mode != "openvpn" else "-"
ports["squid"] = "3128,8080"
ports["ovpnohp"] = "-"

if hysteria_enabled:
    ports["hysteria"] = "5666"
    any_ports.append("5666")
else:
    ports["hysteria"] = "-"

if openvpn_enabled:
    ports["ovpntcp"] = "-"
    ports["ovpnudp"] = ",".join(str(port) for port in effective_openvpn_udp_public_ports) or "-"
    if ports["ovpnudp"] != "-":
        any_ports.extend(str(port) for port in effective_openvpn_udp_public_ports)
else:
    ports["ovpntcp"] = "-"
    ports["ovpnudp"] = "-"

if udp53_mode != "openvpn" or openvpn_enabled:
    any_ports.insert(1, "53")

deduped_any_ports = []
for port in any_ports:
    port = str(port)
    if port and port not in deduped_any_ports:
        deduped_any_ports.append(port)
ports["any"] = ",".join(deduped_any_ports)

slowdns = data.setdefault("slowdns", {})
public_hostname = str(slowdns.get("public_hostname") or slowdns.get("ns_host") or "").strip(".")
if not public_hostname:
    ns_prefix = str(slowdns.get("ns_prefix") or "").strip(".")
    public_hostname = f"{ns_prefix}.{domain}" if ns_prefix else domain
tunnel_domain = str(slowdns.get("tunnel_domain") or "").strip(".")
if not tunnel_domain:
    zone_prefix = str(slowdns.get("zone_prefix") or "dns").strip(".")
    tunnel_domain = f"{zone_prefix}.{domain}" if zone_prefix else domain
slowdns["enabled"] = udp53_mode != "openvpn"
slowdns["service"] = "iptunnel-slowdns"
slowdns["mux_service"] = "iptunnel-udp53-mux"
slowdns["listen_port"] = 5300
slowdns["public_port"] = 53
slowdns["local_port"] = 8000
slowdns["target"] = str(slowdns.get("target") or "127.0.0.1:22")
slowdns["udp53_mode"] = udp53_mode
slowdns["public_hostname"] = public_hostname
slowdns["ns_host"] = public_hostname
slowdns["tunnel_domain"] = tunnel_domain
slowdns["zone_prefix"] = ""
slowdns["ns_prefix"] = ""
slowdns["public_key_path"] = "/etc/iptunnel/slowdns/server.pub"
slowdns["private_key_path"] = "/etc/iptunnel/slowdns/server.key"
slowdns["info_path"] = "/var/www/html/slowdns-info.txt"
try:
    configured_mtu = int(slowdns.get("mtu") or 0)
    slowdns["mtu"] = configured_mtu if 128 <= configured_mtu <= 1500 else 1232
except Exception:
    slowdns["mtu"] = 1232

openvpn = data.setdefault("openvpn", {})
openvpn["enabled"] = openvpn_enabled
openvpn["tcp_public_port"] = 1194
openvpn["udp_public_port"] = openvpn_udp_public_port_int
openvpn["udp_public_ports"] = openvpn_udp_public_ports
openvpn["udp_internal_port"] = 25000

hysteria = data.setdefault("hysteria", {})
hysteria["enabled"] = hysteria_enabled
hysteria["service"] = "hysteria-server"
hysteria["port"] = 5666
hysteria["protocol"] = "udp"
hysteria["hop_enabled"] = hysteria_enabled
hysteria["hop_ports"] = hysteria_hop_range
hysteria["obfs"] = hysteria_obfs
hysteria["password"] = hysteria_password
hysteria["sni"] = domain
hysteria["ca_cert_path"] = "/var/www/html/hysteria.ca.crt"
hysteria["info_path"] = "/var/www/html/hysteria-info.txt"

config_path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
PY
}

configure_vnstat() {
  systemctl enable vnstat >/dev/null 2>&1 || true
  systemctl start vnstat >/dev/null 2>&1 || true
  if [[ -n "${MAIN_IFACE}" ]]; then
    vnstat --add -i "${MAIN_IFACE}" >/dev/null 2>&1 || true
  fi
  systemctl restart vnstat >/dev/null 2>&1 || true
}

configure_nginx() {
  if [[ "${INSTALL_NGINX}" != "1" ]]; then
    return 0
  fi

  mkdir -p /etc/nginx/conf.d /etc/nginx/sites-enabled
  rm -f /etc/nginx/sites-enabled/default
  rm -f /etc/nginx/conf.d/default.conf

  if [[ -f /etc/nginx/conf.d/aus-cloud-proxy.conf ]]; then
    mv /etc/nginx/conf.d/aus-cloud-proxy.conf /etc/nginx/conf.d/aus-cloud-proxy.conf.disabled-by-iptunnel
  fi

  cat >/etc/nginx/conf.d/iptunnel-api.conf <<EOF
server {
    listen 127.0.0.1:${NGINX_HTTP_LOCAL_PORT} default_server;
    listen [::1]:${NGINX_HTTP_LOCAL_PORT} default_server;
    server_name ${DOMAIN};
    root ${WEB_ROOT};
    index index.html;
    access_log off;
    client_header_timeout 15s;
    client_body_timeout 15s;
    reset_timedout_connection on;
    keepalive_timeout 65s;
    keepalive_requests 10000;

    location /vps/ {
        proxy_pass http://127.0.0.1:${API_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Authorization \$http_authorization;
    }

    location /api/v2/ {
        proxy_pass http://127.0.0.1:${API_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Authorization \$http_authorization;
    }

    location = /healthz {
        proxy_pass http://127.0.0.1:${API_PORT}/healthz;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

$(ssh_ws_nginx_locations "${SSH_WS_PATHS_CSV}")

    location /swagger/ {
        proxy_pass http://127.0.0.1:${API_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Authorization \$http_authorization;
    }

$(xray_ws_nginx_locations)

$(ssh_ws_root_nginx_location "@iptunnel_ssh_ws_root_http")

    location / {
        try_files \$uri \$uri/ =404;
    }
}

server {
    listen 127.0.0.1:${NGINX_TLS_LOCAL_PORT} ssl http2;
    listen [::1]:${NGINX_TLS_LOCAL_PORT} ssl http2;
    server_name ${DOMAIN};
    root ${WEB_ROOT};
    index index.html;
    access_log off;
    client_header_timeout 15s;
    client_body_timeout 15s;
    reset_timedout_connection on;
    ssl_session_cache shared:IPTunnelSSL:10m;
    ssl_session_timeout 1d;
    keepalive_timeout 65s;
    keepalive_requests 10000;

    ssl_certificate ${CERT_DIR}/cert.crt;
    ssl_certificate_key ${CERT_DIR}/cert.key;

    location /vps/ {
        proxy_pass http://127.0.0.1:${API_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Authorization \$http_authorization;
    }

    location /api/v2/ {
        proxy_pass http://127.0.0.1:${API_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Authorization \$http_authorization;
    }

    location = /healthz {
        proxy_pass http://127.0.0.1:${API_PORT}/healthz;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

$(ssh_ws_nginx_locations "${SSH_WS_PATHS_CSV}")

    location /swagger/ {
        proxy_pass http://127.0.0.1:${API_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Authorization \$http_authorization;
    }

$(xray_ws_nginx_locations)
$(xray_grpc_nginx_locations)

$(ssh_ws_root_nginx_location "@iptunnel_ssh_ws_root_tls")

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

  mkdir -p "${WEB_ROOT}"
  printf 'IPTunnel is running on %s\n' "${DOMAIN}" >"${WEB_ROOT}/index.html"
  systemctl enable nginx >/dev/null 2>&1 || true
  nginx -t
  systemctl restart nginx >/dev/null 2>&1 || true
}

main() {
  load_runtime_context
  if [[ -z "${IPTUNNEL_ENABLE_HYSTERIA_SET}" ]]; then
    ENABLE_HYSTERIA="$(current_hysteria_enabled)"
  fi
  if [[ -z "${IPTUNNEL_ENABLE_OPENVPN_SET}" ]]; then
    ENABLE_OPENVPN="$(current_openvpn_enabled)"
  fi
  if [[ "${ENABLE_OPENVPN}" == "1" && -z "${OPENVPN_UDP_PUBLIC_PORTS}" ]]; then
    OPENVPN_UDP_PUBLIC_PORTS="1194"
    reconcile_openvpn_ports_with_udp53_mode
  fi
  install_transport_packages
  configure_service_limits
  configure_ssh
  configure_dropbear
  configure_ssh_ws
  configure_slowdns_target_proxy
  configure_edge_proxy
  configure_fronting_proxy
  configure_ssh_ssl
  if [[ "${ENABLE_HYSTERIA}" == "1" ]]; then
    configure_hysteria
  else
    disable_hysteria
  fi
  configure_slowdns
  configure_udp53_mux
  install_xray_binary
  write_xray_configs
  write_xray_units
  systemctl daemon-reload
  systemctl enable iptunnel-vmess >/dev/null 2>&1 || true
  systemctl enable iptunnel-vless >/dev/null 2>&1 || true
  systemctl enable iptunnel-trojan >/dev/null 2>&1 || true
  systemctl restart iptunnel-vmess >/dev/null 2>&1 || true
  systemctl restart iptunnel-vless >/dev/null 2>&1 || true
  systemctl restart iptunnel-trojan >/dev/null 2>&1 || true
  configure_squid
  configure_openvpn_server
  if [[ "${ENABLE_OPENVPN}" != "1" ]]; then
    disable_openvpn
  else
    enable_openvpn_udp_runtime
    disable_openvpn_tcp_runtime
  fi
  configure_vnstat
  configure_nginx
  configure_ssl_mux
  sync_runtime_config
}

enable_hysteria_module() {
  load_runtime_context
  ENABLE_OPENVPN="$(current_openvpn_enabled)"
  ENABLE_HYSTERIA="1"
  configure_hysteria
  sync_runtime_config
}

disable_hysteria_module() {
  load_runtime_context
  ENABLE_OPENVPN="$(current_openvpn_enabled)"
  ENABLE_HYSTERIA="0"
  disable_hysteria
  sync_runtime_config
}

enable_openvpn_module() {
  load_runtime_context
  ENABLE_HYSTERIA="$(current_hysteria_enabled)"
  ENABLE_OPENVPN="1"
  if [[ -z "${OPENVPN_UDP_PUBLIC_PORTS}" ]]; then
    OPENVPN_UDP_PUBLIC_PORTS="1194"
    reconcile_openvpn_ports_with_udp53_mode
  fi
  configure_openvpn_server
  enable_openvpn_udp_runtime
  disable_openvpn_tcp_runtime
  configure_slowdns
  configure_udp53_mux
  sync_runtime_config
}

disable_openvpn_module() {
  load_runtime_context
  # If OpenVPN owned UDP53 (openvpn or shared mode), hand port 53 back to SlowDNS.
  # Without this reset, sync_runtime_config would write slowdns.enabled=false because
  # it derives that flag from udp53_mode, leaving both services disabled.
  if [[ "${SLOWDNS_UDP53_MODE}" == "openvpn" || "${SLOWDNS_UDP53_MODE}" == "shared" ]]; then
    SLOWDNS_UDP53_MODE="slowdns"
  fi
  OPENVPN_UDP_PUBLIC_PORTS="$(udp_port_csv_remove "${OPENVPN_UDP_PUBLIC_PORTS}" "53")"
  refresh_openvpn_primary_port
  ENABLE_HYSTERIA="$(current_hysteria_enabled)"
  ENABLE_OPENVPN="0"
  disable_openvpn
  configure_slowdns
  configure_udp53_mux
  sync_runtime_config
}

set_udp53_mode_module() {
  local requested_mode=""
  requested_mode="$(normalize_udp53_mode "${1:-}")"
  load_runtime_context
  ENABLE_HYSTERIA="$(current_hysteria_enabled)"
  ENABLE_OPENVPN="$(current_openvpn_enabled)"
  SLOWDNS_UDP53_MODE="${requested_mode}"
  disable_openvpn_tcp_runtime
  if [[ "${requested_mode}" == "openvpn" || "${requested_mode}" == "shared" ]]; then
    ENABLE_OPENVPN="1"
    OPENVPN_UDP_PUBLIC_PORTS="$(udp_port_csv_add "${OPENVPN_UDP_PUBLIC_PORTS}" "53")"
    refresh_openvpn_primary_port
    configure_openvpn_server
    enable_openvpn_udp_runtime
  else
    OPENVPN_UDP_PUBLIC_PORTS="$(udp_port_csv_remove "${OPENVPN_UDP_PUBLIC_PORTS}" "53")"
    refresh_openvpn_primary_port
    if [[ -n "${OPENVPN_UDP_PUBLIC_PORTS}" && "${ENABLE_OPENVPN}" == "1" ]]; then
      configure_openvpn_server
      enable_openvpn_udp_runtime
    else
      ENABLE_OPENVPN="0"
      disable_openvpn_udp_runtime
    fi
  fi
  if [[ "${requested_mode}" == "openvpn" ]]; then
    disable_slowdns_runtime
  else
    configure_slowdns
  fi
  configure_udp53_mux
  sync_runtime_config
}

refresh_domain_module() {
  load_runtime_context
  ENABLE_HYSTERIA="$(current_hysteria_enabled)"
  ENABLE_OPENVPN="$(current_openvpn_enabled)"
  configure_ssh_ssl
  if [[ "${ENABLE_HYSTERIA}" == "1" ]]; then
    configure_hysteria
  fi
  configure_slowdns_target_proxy
  configure_slowdns
  configure_udp53_mux
  if [[ "${ENABLE_OPENVPN}" == "1" ]]; then
    write_openvpn_profiles
  fi
  configure_nginx
  configure_ssl_mux
  sync_runtime_config
}

refresh_openvpn_udp_port_module() {
  load_runtime_context
  ENABLE_HYSTERIA="$(current_hysteria_enabled)"
  ENABLE_OPENVPN="$(current_openvpn_enabled)"
  if [[ "${ENABLE_OPENVPN}" == "1" ]]; then
    configure_openvpn_server
    enable_openvpn_udp_runtime
    disable_openvpn_tcp_runtime
  fi
  configure_udp53_mux
  sync_runtime_config
}

refresh_slowdns_mtu_module() {
  load_runtime_context
  ENABLE_HYSTERIA="$(current_hysteria_enabled)"
  ENABLE_OPENVPN="$(current_openvpn_enabled)"
  if [[ "${SLOWDNS_UDP53_MODE}" != "openvpn" ]]; then
    configure_slowdns
  fi
  sync_runtime_config
}

dispatch_action() {
  local requested_action="${1:-install}"
  case "${requested_action}" in
    install)
      main
      ;;
    enable-hysteria)
      enable_hysteria_module
      ;;
    disable-hysteria)
      disable_hysteria_module
      ;;
    enable-openvpn)
      enable_openvpn_module
      ;;
    disable-openvpn)
      disable_openvpn_module
      ;;
    set-udp53-mode)
      set_udp53_mode_module "${2:-}"
      ;;
    refresh-config)
      load_runtime_context
      configure_slowdns_target_proxy
      configure_slowdns
      configure_udp53_mux
      sync_runtime_config
      ;;
    refresh-domain)
      refresh_domain_module
      ;;
    refresh-openvpn-udp-port)
      refresh_openvpn_udp_port_module
      ;;
    refresh-slowdns-mtu)
      refresh_slowdns_mtu_module
      ;;
    *)
      echo "Unknown action: ${requested_action}" >&2
      return 1
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  dispatch_action "$@"
fi
