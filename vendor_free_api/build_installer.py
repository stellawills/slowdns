#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path


ROOT = Path(__file__).resolve().parent


def read_text(name: str) -> str:
    return (ROOT / name).read_text(encoding="utf-8").rstrip() + "\n"


API = read_text("iptunnel_api.py")
MENU = read_text("iptunnel_menu.sh")
SCHEMA = read_text("schema.sql")
SERVICE = read_text("iptunnel-api.service")
TRANSPORT_STACK = read_text("transport_stack.sh")
PAM_CHECK = read_text("iptunnel-pam-check.sh")
DEVICE_CREDENTIALS = read_text("device_credentials.py")
DEVICE_SSH = read_text("device_ssh.py")
DEVICE_CERTIFICATES = read_text("device_certificates.py")
DEVICE_XRAY = read_text("device_xray.py")
PROVISIONING_SETUP = read_text("provisioning_setup.py")
MANAGED_SSH_CONFIG = read_text("managed-ssh.conf")
PROVISIONING_MONITOR = read_text("provisioning_monitor.py")
PROVISIONING_SERVICE = read_text("iptunnel-provisioning.service")

# ── License server URL — hardcoded into every installer build ──────
# Copied scripts will always phone home here. Without a valid
# --license-token they get no server_id, and the service shuts
# down after 24 hours (grace period for unregistered servers).
HARDCODED_LICENSE_URL = "https://license.internetshub.com"
HYSTERIA_SOURCE = ROOT.parent.parent / "Hysteria" / "hysteria" / "hysteria.sh"
if not HYSTERIA_SOURCE.exists():
    HYSTERIA_SOURCE = ROOT / "hysteria_vendor.reference.sh"
HYSTERIA_VENDOR = HYSTERIA_SOURCE.read_text(encoding="utf-8").rstrip() + "\n"

# Patch vendor script: add -fL and retry flags to curl so GitHub
# redirects are followed and HTTP errors are detected.
HYSTERIA_VENDOR = HYSTERIA_VENDOR.replace(
    "curl -R -H 'Cache-Control: no-cache'",
    "curl -fL -R -H 'Cache-Control: no-cache' --retry 5 --retry-delay 10 --retry-max-time 60",
)

# Patch install_content to propagate failures instead of silently continuing.
HYSTERIA_VENDOR = HYSTERIA_VENDOR.replace(
    '\tif install "$_install_flags" "$_tmpfile" "$_destination"; then\n'
    '\t\techo -e "ok"\n'
    '\t\tfi\n'
    '\n'
    '\t\trm -f "$_tmpfile"\n',
    '\tif install "$_install_flags" "$_tmpfile" "$_destination"; then\n'
    '\t\techo -e "ok"\n'
    '\telse\n'
    '\t\trm -f "$_tmpfile"\n'
    '\t\terror "Failed to install $_destination"\n'
    '\t\treturn 1\n'
    '\tfi\n'
    '\n'
    '\trm -f "$_tmpfile"\n',
)


INSTALLER = f"""#!/usr/bin/env bash
set -euo pipefail

DOMAIN=""
API_KEY=""
HYSTERIA_OBFS=""
HYSTERIA_PASSWORD=""
PUBLIC_IP=""
BIND="127.0.0.1"
PORT="8080"
NAME_CLIENT="IPTunnel"
STATUS_LABEL="selfhosted"
INSTALL_NGINX="1"
GENERATE_SELF_SIGNED="1"
ENABLE_HYSTERIA="0"
ENABLE_OPENVPN="0"
SLOWDNS_UDP53_MODE=""
OPENVPN_UDP_PORTS=""
LICENSE_URL="{HARDCODED_LICENSE_URL}"
LICENSE_TOKEN=""
HMAC_SECRET=""

usage() {{
  cat <<'EOF'
Usage:
  bash iptunnel-install.sh [--domain api.example.com] [--api-key secret] [--public-ip 1.2.3.4]

Options:
  --domain DOMAIN          Public domain for this VPS API and generated links. Prompted if omitted.
  --api-key KEY            API key for the Authorization header. Generated if omitted.
  --hysteria-obfs VALUE    Hysteria obfs string. Preserved or generated if omitted.
  --hysteria-password VAL  Hysteria password/auth value. Preserved or generated if omitted.
  --public-ip IP           VPS public IPv4. Prompted if omitted, with auto-detection as the default.
  --bind HOST              Local bind host for the API. Default: 127.0.0.1
  --port PORT              Local port for the API. Default: 8080
  --name-client NAME       Value stored in the servers table. Default: IPTunnel
  --status-label LABEL     Value stored in servers.status. Default: selfhosted
  --enable-hysteria        Start with Hysteria enabled after install.
  --disable-hysteria       Leave Hysteria installed but disabled. Default.
  --enable-openvpn         Start with OpenVPN enabled after install.
  --disable-openvpn        Leave OpenVPN installed but disabled. Default.
  --udp53-mode MODE        Preserve/set UDP53 mode: slowdns, openvpn, or shared.
  --openvpn-udp-ports LIST Comma-separated OpenVPN UDP ports, e.g. 53,1194.
  --license-url URL        License server URL (e.g. http://license.internetshub.com:9090)
  --license-token TOKEN    Client/master token. If omitted, auto-detected via IP whitelist.
  --hmac-secret SECRET     HMAC secret for session-token auth. Generated if omitted.
  --skip-nginx             Do not write the nginx vhost.
  --skip-self-signed       Do not generate a self-signed cert when no cert exists.
  --help                   Show this help.
EOF
}}

trim() {{
  local value="${{1:-}}"
  value="${{value#"${{value%%[![:space:]]*}}"}}"
  value="${{value%"${{value##*[![:space:]]}}"}}"
  printf '%s' "$value"
}}

prompt_required() {{
  local __var_name="$1"
  local prompt_text="$2"
  local default_value="${{3:-}}"
  local reply=""

  while true; do
    if [[ -n "$default_value" ]]; then
      read -r -p "$prompt_text [$default_value]: " reply
      reply="${{reply:-$default_value}}"
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
}}

is_ipv4() {{
  local ip="$1"
  local IFS=.
  local -a octets=()
  read -r -a octets <<<"$ip"
  [[ "${{#octets[@]}}" -eq 4 ]] || return 1
  for octet in "${{octets[@]}}"; do
    [[ "$octet" =~ ^[0-9]+$ ]] || return 1
    (( octet >= 0 && octet <= 255 )) || return 1
  done
}}

detect_public_ip() {{
  local detected=""
  detected="$(curl -4fsSL https://api.ipify.org 2>/dev/null || true)"
  if [[ -z "$detected" ]]; then
    detected="$(hostname -I 2>/dev/null | awk '{{print $1}}' || true)"
  fi
  if [[ -z "$detected" ]]; then
    detected="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{{print $7; exit}}' || true)"
  fi
  detected="$(trim "$detected")"
  if [[ -n "$detected" ]] && ! is_ipv4 "$detected"; then
    detected=""
  fi
  printf '%s' "$detected"
}}

prompt_public_ip() {{
  local detected_default="${{1:-}}"
  local reply=""

  while true; do
    if [[ -n "$detected_default" ]]; then
      read -r -p "Public IPv4 for this VPS [$detected_default]: " reply
      reply="${{reply:-$detected_default}}"
    else
      read -r -p "Public IPv4 for this VPS: " reply
    fi
    reply="$(trim "$reply")"
    if is_ipv4 "$reply"; then
      PUBLIC_IP="$reply"
      return 0
    fi
    echo "Enter a valid IPv4 address." >&2
  done
}}

generate_hex() {{
  local bytes="$1"
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex "$bytes"
  else
    python3 - "$bytes" <<'PY'
import secrets
import sys

print(secrets.token_hex(int(sys.argv[1])))
PY
  fi
}}

read_existing_hysteria_value() {{
  local field="$1"
  python3 - "$field" <<'PY'
import json
import pathlib
import sys

field = sys.argv[1]
candidates = [
    ("iptunnel", pathlib.Path("/etc/iptunnel/config.json")),
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
        value = str((data.get("hysteria") or {{}}).get(field) or "")
    elif field == "obfs":
        value = str(data.get("obfs") or "")
    elif field == "password":
        auth = data.get("auth") or {{}}
        config = auth.get("config") or []
        if config:
            value = str(config[0] or "")

    if value:
        print(value)
        break
PY
}}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain)
      DOMAIN="${{2:-}}"
      shift 2
      ;;
    --api-key)
      API_KEY="${{2:-}}"
      shift 2
      ;;
    --hysteria-obfs)
      HYSTERIA_OBFS="${{2:-}}"
      shift 2
      ;;
    --hysteria-password)
      HYSTERIA_PASSWORD="${{2:-}}"
      shift 2
      ;;
    --public-ip)
      PUBLIC_IP="${{2:-}}"
      shift 2
      ;;
    --bind)
      BIND="${{2:-}}"
      shift 2
      ;;
    --port)
      PORT="${{2:-}}"
      shift 2
      ;;
    --name-client)
      NAME_CLIENT="${{2:-}}"
      shift 2
      ;;
    --status-label)
      STATUS_LABEL="${{2:-}}"
      shift 2
      ;;
    --enable-hysteria)
      ENABLE_HYSTERIA="1"
      shift
      ;;
    --disable-hysteria)
      ENABLE_HYSTERIA="0"
      shift
      ;;
    --enable-openvpn)
      ENABLE_OPENVPN="1"
      shift
      ;;
    --disable-openvpn)
      ENABLE_OPENVPN="0"
      shift
      ;;
    --udp53-mode)
      SLOWDNS_UDP53_MODE="${{2:-}}"
      shift 2
      ;;
    --openvpn-udp-ports)
      OPENVPN_UDP_PORTS="${{2:-}}"
      shift 2
      ;;
    --license-url)
      LICENSE_URL="${{2:-}}"
      shift 2
      ;;
    --license-token)
      LICENSE_TOKEN="${{2:-}}"
      shift 2
      ;;
    --hmac-secret)
      HMAC_SECRET="${{2:-}}"
      shift 2
      ;;
    --skip-nginx)
      INSTALL_NGINX="0"
      shift
      ;;
    --skip-self-signed)
      GENERATE_SELF_SIGNED="0"
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

DOMAIN="$(trim "$DOMAIN")"
if [[ -z "$DOMAIN" ]]; then
  prompt_required DOMAIN "Domain for this VPS"
fi

if [[ -z "$API_KEY" ]]; then
  API_KEY="$(generate_hex 24)"
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y python3 sqlite3 nginx openssl ca-certificates curl iproute2

if [[ -z "$PUBLIC_IP" ]]; then
  DETECTED_PUBLIC_IP="$(detect_public_ip)"
  if [[ -n "$DETECTED_PUBLIC_IP" ]]; then
    echo "Detected public IPv4: $DETECTED_PUBLIC_IP"
  else
    echo "Could not auto-detect the public IPv4 address."
  fi
  prompt_public_ip "$DETECTED_PUBLIC_IP"
else
  PUBLIC_IP="$(trim "$PUBLIC_IP")"
  if ! is_ipv4 "$PUBLIC_IP"; then
    echo "Invalid --public-ip: $PUBLIC_IP" >&2
    exit 1
  fi
fi

if [[ -z "$HYSTERIA_OBFS" ]]; then
  HYSTERIA_OBFS="$(read_existing_hysteria_value obfs)"
fi
if [[ -z "$HYSTERIA_OBFS" ]]; then
  HYSTERIA_OBFS="$(generate_hex 8)"
fi

if [[ -z "$HYSTERIA_PASSWORD" ]]; then
  HYSTERIA_PASSWORD="$(read_existing_hysteria_value password)"
fi
if [[ -z "$HYSTERIA_PASSWORD" ]]; then
  HYSTERIA_PASSWORD="$(generate_hex 12)"
fi

if [[ "$ENABLE_HYSTERIA" == "1" && -t 0 ]]; then
  echo "Hysteria is server-wide. Choose the obfs/password all Hysteria clients will use on this VPS."
  prompt_required HYSTERIA_OBFS "Hysteria obfs" "$HYSTERIA_OBFS"
  prompt_required HYSTERIA_PASSWORD "Hysteria password" "$HYSTERIA_PASSWORD"
fi

if [[ -z "$HMAC_SECRET" ]]; then
  HMAC_SECRET="$(generate_hex 16)"
fi

mkdir -p /opt/iptunnel /etc/iptunnel /usr/sbin/iptunnel /usr/sbin/iptunnel/cert
mkdir -p /etc/iptunnel/xray

sqlite3 /usr/sbin/iptunnel/iptunnel.db <<'SQL'
{SCHEMA.rstrip()}
SQL

export IPTUNNEL_DB_PATH="/usr/sbin/iptunnel/iptunnel.db"
export IPTUNNEL_SERVER_ADDRESS="$PUBLIC_IP"
export IPTUNNEL_SERVER_KEY="$API_KEY"
export IPTUNNEL_SERVER_DOMAIN="$DOMAIN"
export IPTUNNEL_SERVER_NAME="$NAME_CLIENT"
export IPTUNNEL_SERVER_STATUS="$STATUS_LABEL"

python3 - <<'PY'
import os
import sqlite3

with sqlite3.connect(os.environ["IPTUNNEL_DB_PATH"]) as conn:
    conn.execute("DELETE FROM servers")
    conn.execute(
        "INSERT INTO servers (address, key, auth, domain, name_client, status) VALUES (?, ?, ?, ?, ?, ?)",
        (
            os.environ["IPTUNNEL_SERVER_ADDRESS"],
            os.environ["IPTUNNEL_SERVER_KEY"],
            "",
            os.environ["IPTUNNEL_SERVER_DOMAIN"],
            os.environ["IPTUNNEL_SERVER_NAME"],
            os.environ["IPTUNNEL_SERVER_STATUS"],
        ),
    )
    conn.commit()
PY

unset IPTUNNEL_DB_PATH IPTUNNEL_SERVER_ADDRESS IPTUNNEL_SERVER_KEY IPTUNNEL_SERVER_DOMAIN IPTUNNEL_SERVER_NAME IPTUNNEL_SERVER_STATUS

cat >/opt/iptunnel/iptunnel_api.py <<'PYCODE'
{API.rstrip()}
PYCODE
chmod 755 /opt/iptunnel/iptunnel_api.py

cat >/opt/iptunnel/device_credentials.py <<'DEVICE_CREDENTIALS'
{DEVICE_CREDENTIALS.rstrip()}
DEVICE_CREDENTIALS
cat >/opt/iptunnel/device_certificates.py <<'DEVICE_CERTIFICATES'
{DEVICE_CERTIFICATES.rstrip()}
DEVICE_CERTIFICATES
chmod 644 /opt/iptunnel/device_certificates.py
cat >/opt/iptunnel/device_xray.py <<'DEVICE_XRAY'
{DEVICE_XRAY.rstrip()}
DEVICE_XRAY
chmod 644 /opt/iptunnel/device_xray.py
cat >/opt/iptunnel/provisioning_setup.py <<'PROVISIONING_SETUP'
{PROVISIONING_SETUP.rstrip()}
PROVISIONING_SETUP
chmod 700 /opt/iptunnel/provisioning_setup.py
cat >/opt/iptunnel/device_ssh.py <<'DEVICE_SSH'
{DEVICE_SSH.rstrip()}
DEVICE_SSH
cat >/opt/iptunnel/managed-ssh.conf <<'MANAGED_SSH_CONFIG'
{MANAGED_SSH_CONFIG.rstrip()}
MANAGED_SSH_CONFIG
chmod 644 /opt/iptunnel/device_ssh.py /opt/iptunnel/managed-ssh.conf
cat >/opt/iptunnel/provisioning_monitor.py <<'PROVISIONING_MONITOR'
{PROVISIONING_MONITOR.rstrip()}
PROVISIONING_MONITOR
chmod 644 /opt/iptunnel/device_credentials.py /opt/iptunnel/provisioning_monitor.py
cat >/etc/systemd/system/iptunnel-provisioning.service <<'PROVISIONING_SERVICE'
{PROVISIONING_SERVICE.rstrip()}
PROVISIONING_SERVICE
install -d -m 700 /var/lib/iptunnel-provisioning /run/iptunnel-provisioning
cat >/etc/tmpfiles.d/iptunnel-provisioning.conf <<'PROVISIONING_TMPFILES'
d /run/iptunnel-provisioning 0700 root root -
d /var/lib/iptunnel-provisioning 0700 root root -
PROVISIONING_TMPFILES
# Deliberately do not enable/start provisioning: explicit managed activation only.

cat >/usr/local/bin/iptunnel-menu <<'MENU'
{MENU.rstrip()}
MENU
chmod 755 /usr/local/bin/iptunnel-menu
ln -sf /usr/local/bin/iptunnel-menu /usr/local/bin/menu

cat >/opt/iptunnel/hysteria_vendor.sh <<'HYSTERIA'
{HYSTERIA_VENDOR.rstrip()}
HYSTERIA
chmod 755 /opt/iptunnel/hysteria_vendor.sh

cat >/etc/iptunnel/config.json <<EOF
{{
  "bind": "${{BIND}}",
  "port": ${{PORT}},
  "api_key": "${{API_KEY}}",
  "db_path": "/usr/sbin/iptunnel/iptunnel.db",
  "hostname": "${{DOMAIN}}",
  "public_ip": "${{PUBLIC_IP}}",
  "city": "",
  "isp": "",
  "allow_legacy_db_key": true,
    "ssh": {{
      "manage_system_users": true,
      "shell": "/bin/false",
      "ws_path": "/sshws",
      "ws_path_aliases": ["/ssh"],
      "ports": {{
        "any": "22,53,80,109,143,443,2082,2083,3128,8080,8443",
        "none": "-",
        "ssh": "22,443",
        "dropbear": "109,143",
        "ssl": "443,2082",
        "ws": "80,443,2082",
        "slowdns": "53",
        "squid": "3128,8080",
      "hysteria": "-",
      "ovpnohp": "-",
      "ovpntcp": "-",
      "ovpnudp": "-"
    }}
  }},
  "slowdns": {{
    "enabled": true,
    "service": "iptunnel-slowdns",
    "mux_service": "iptunnel-udp53-mux",
    "listen_port": 5300,
    "public_port": 53,
    "local_port": 8000,
    "target": "127.0.0.1:111",
    "public_hostname": "${{DOMAIN}}",
    "ns_host": "${{DOMAIN}}",
    "tunnel_domain": "dns.${{DOMAIN}}",
    "zone_prefix": "dns",
    "ns_prefix": "",
    "public_key_path": "/etc/iptunnel/slowdns/server.pub",
    "private_key_path": "/etc/iptunnel/slowdns/server.key",
    "info_path": "/var/www/html/slowdns-info.txt",
    "mtu": 1232
  }},
  "hysteria": {{
    "enabled": false,
    "service": "hysteria-server",
    "port": 5666,
    "protocol": "udp",
    "hop_enabled": false,
    "hop_ports": "-",
    "obfs": "",
    "password": "",
    "sni": "",
    "ca_cert_path": "/var/www/html/hysteria.ca.crt",
    "info_path": "/var/www/html/hysteria-info.txt"
  }},
  "license": {{
    "enabled": $(if [[ -n "$LICENSE_URL" ]]; then echo "true"; else echo "false"; fi),
    "url": "${{LICENSE_URL}}",
    "master_token": "${{LICENSE_TOKEN}}",
    "server_id": "",
    "server_id_path": "/etc/iptunnel/license.id",
    "checkin_interval": 86400,
    "hmac_secret": "${{HMAC_SECRET}}",
    "session_ttl": 60
  }},
  "xray": {{
    "restart_services": true,
    "ports": {{
      "any": "80,443",
      "none": "80",
      "tls": "443"
    }},
    "paths": {{
      "vmess": {{
        "primary": "/vmess",
        "grpc": "vmess",
        "multi": "/vmess",
        "stn": "/vmess",
        "up": "/upvmess"
      }},
      "vless": {{
        "primary": "/vless",
        "grpc": "vless",
        "multi": "/vless",
        "stn": "/vless",
        "up": "/upvless"
      }},
      "trojan": {{
        "primary": "/trojan",
        "grpc": "trojan",
        "multi": "/trojan",
        "stn": "/trojan",
        "up": "/uptrojan"
      }}
    }},
    "configs": {{
      "vmess": "/etc/iptunnel/xray/vmess.json",
      "vless": "/etc/iptunnel/xray/vless.json",
      "trojan": "/etc/iptunnel/xray/trojan.json"
    }},
    "services": {{
      "vmess": "iptunnel-vmess",
      "vless": "iptunnel-vless",
      "trojan": "iptunnel-trojan"
    }}
  }}
}}
EOF
chmod 600 /etc/iptunnel/config.json

for f in /etc/iptunnel/xray/vmess.json /etc/iptunnel/xray/vless.json /etc/iptunnel/xray/trojan.json; do
  if [[ ! -f "$f" ]]; then
    cat >"$f" <<'EOF'
{{
  "inbounds": [
    {{
      "settings": {{
        "clients": []
      }}
    }}
  ]
}}
EOF
  fi
done

cat >/etc/systemd/system/iptunnel-api.service <<'UNIT'
{SERVICE.rstrip()}
UNIT

if [[ ! -f /usr/sbin/iptunnel/cert/cert.crt || ! -f /usr/sbin/iptunnel/cert/cert.key ]]; then
  if [[ "$GENERATE_SELF_SIGNED" == "1" ]]; then
    openssl req -x509 -nodes -newkey rsa:2048 -days 825 \
      -keyout /usr/sbin/iptunnel/cert/cert.key \
      -out /usr/sbin/iptunnel/cert/cert.crt \
      -subj "/CN=${{DOMAIN}}" \
      -addext "subjectAltName=DNS:${{DOMAIN}}"
  fi
fi

cat >/opt/iptunnel/transport_stack.sh <<'STACK'
{TRANSPORT_STACK.rstrip()}
STACK
chmod 755 /opt/iptunnel/transport_stack.sh

IPTUNNEL_DOMAIN="${{DOMAIN}}" \
IPTUNNEL_PUBLIC_IP="${{PUBLIC_IP}}" \
IPTUNNEL_CERT_DIR="/usr/sbin/iptunnel/cert" \
IPTUNNEL_API_PORT="${{PORT}}" \
IPTUNNEL_INSTALL_NGINX="${{INSTALL_NGINX}}" \
IPTUNNEL_ENABLE_HYSTERIA="${{ENABLE_HYSTERIA}}" \
IPTUNNEL_ENABLE_OPENVPN="${{ENABLE_OPENVPN}}" \
IPTUNNEL_SLOWDNS_UDP53_MODE="${{SLOWDNS_UDP53_MODE}}" \
IPTUNNEL_OPENVPN_UDP_PUBLIC_PORTS="${{OPENVPN_UDP_PORTS}}" \
IPTUNNEL_HYSTERIA_OBFS="${{HYSTERIA_OBFS}}" \
IPTUNNEL_HYSTERIA_PASSWORD="${{HYSTERIA_PASSWORD}}" \
  /opt/iptunnel/transport_stack.sh

# --- PAM auth script (disabled by default for rollout) ---
if [[ "${{IPTUNNEL_ENABLE_PAM_AUTH:-0}}" == "1" ]]; then
cat >/usr/local/bin/iptunnel-pam-check <<'PAMSCRIPT'
{PAM_CHECK.rstrip()}
PAMSCRIPT
chmod 755 /usr/local/bin/iptunnel-pam-check

# Insert PAM rule if not already present
PAM_LINE="auth requisite pam_exec.so expose_authtok quiet /usr/local/bin/iptunnel-pam-check"
if ! grep -qF "iptunnel-pam-check" /etc/pam.d/sshd 2>/dev/null; then
  # Insert before @include common-auth (so it runs first)
  if grep -q "@include common-auth" /etc/pam.d/sshd; then
    sed -i "/@include common-auth/i $PAM_LINE" /etc/pam.d/sshd
  else
    echo "$PAM_LINE" >> /etc/pam.d/sshd
  fi
  echo "[+] PAM auth script installed"
fi
else
  sed -i '/iptunnel-pam-check/d' /etc/pam.d/sshd 2>/dev/null || true
  rm -f /usr/local/bin/iptunnel-pam-check
fi

# --- SSH pre-auth banner (visible to ALL SSH clients before password prompt) ---
BANNER_FILE="/etc/ssh/iptunnel-banner.txt"
cat >"$BANNER_FILE" <<'BANNER'
==========================================================
  This server is exclusively for IPTunnel VPN users.
  Unauthorised access attempts are logged and blocked.
  Download the IPTunnel app from the Google Play Store.
==========================================================
BANNER
# Add Banner directive to sshd_config if not already set
if grep -qE "^#?Banner" /etc/ssh/sshd_config 2>/dev/null; then
  sed -i "s|^#*Banner.*|Banner $BANNER_FILE|" /etc/ssh/sshd_config
else
  echo "Banner $BANNER_FILE" >> /etc/ssh/sshd_config
fi
echo "[+] SSH pre-auth banner configured"

# --- License: check for existing registration (reinstall) ---
EXISTING_SID=""
if [[ -f /etc/iptunnel/license.id ]]; then
  EXISTING_SID="$(cat /etc/iptunnel/license.id 2>/dev/null | tr -d '[:space:]')"
fi

if [[ -n "$EXISTING_SID" ]]; then
  echo "[*] Reinstall detected — existing server_id: $EXISTING_SID"
  echo "[*] Preserving license registration (skipping re-registration)"
  python3 - "$EXISTING_SID" <<'PY'
import json, sys, pathlib
sid = sys.argv[1]
p = pathlib.Path("/etc/iptunnel/config.json")
cfg = json.loads(p.read_text())
cfg.setdefault("license", {{}})["server_id"] = sid
p.write_text(json.dumps(cfg, indent=2))
PY
  echo "[+] server_id $EXISTING_SID written to config"
else
  # --- License: auto-authorize via IP if no token provided ---
  if [[ -n "$LICENSE_URL" && -z "$LICENSE_TOKEN" ]]; then
    echo "[*] No --license-token provided — checking IP authorization via API v2..."
    AUTH_RESP=$(curl -4 -sf -X POST "$LICENSE_URL/api/v2/install-tickets/issue" \
      -H "Content-Type: application/json" \
      -d "{{}}" \
      --max-time 15 2>/dev/null) || AUTH_RESP=""
    AUTO_TOKEN=$(echo "$AUTH_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('data',{{}}).get('ticket',''))" 2>/dev/null || echo "")
    AUTO_CLIENT=$(echo "$AUTH_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin).get('data',{{}}).get('client',{{}}); print(d.get('name',''))" 2>/dev/null || echo "")

    if [[ -z "$AUTO_TOKEN" ]]; then
      AUTH_RESP=$(curl -4 -sf -X GET "$LICENSE_URL/authorize" \
        --max-time 15 2>/dev/null) || AUTH_RESP=""
      AUTO_TOKEN=$(echo "$AUTH_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('token',''))" 2>/dev/null || echo "")
      AUTO_CLIENT=$(echo "$AUTH_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('client',''))" 2>/dev/null || echo "")
    fi

    if [[ -n "$AUTO_TOKEN" ]]; then
      LICENSE_TOKEN="$AUTO_TOKEN"
      echo "[+] IP authorized — client: $AUTO_CLIENT"
    else
      echo "[!] IP not pre-authorized. Options:"
      echo "    1. Ask admin to add $PUBLIC_IP at $LICENSE_URL/admin.php?page=clients"
      echo "    2. Re-run with: bash iptunnel-install.sh --license-token YOUR_TOKEN"
      echo "    Running without license — service shuts down after 24h without registration."
    fi
  fi

  # --- License registration ---
  if [[ -n "$LICENSE_URL" && -n "$LICENSE_TOKEN" ]]; then
    echo "[*] Registering with license server at $LICENSE_URL ..."
    LICENSE_RESP=$(curl -4 -sf -X POST "$LICENSE_URL/api/v2/servers/register" \
      -H "Content-Type: application/json" \
      -d "{{\\\"token\\\": \\\"$LICENSE_TOKEN\\\", \\\"ip\\\": \\\"$PUBLIC_IP\\\", \\\"hostname\\\": \\\"$DOMAIN\\\"}}" \
      --max-time 15 2>/dev/null) || LICENSE_RESP=""

    SERVER_ID=$(echo "$LICENSE_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('data',{{}}).get('server_id',''))" 2>/dev/null || echo "")

    if [[ -z "$SERVER_ID" ]]; then
      LICENSE_RESP=$(curl -4 -sf -X POST "$LICENSE_URL/register" \
        -H "Content-Type: application/json" \
        -d "{{\\\"token\\\": \\\"$LICENSE_TOKEN\\\", \\\"ip\\\": \\\"$PUBLIC_IP\\\", \\\"hostname\\\": \\\"$DOMAIN\\\"}}" \
        --max-time 15 2>/dev/null) || LICENSE_RESP=""
      SERVER_ID=$(echo "$LICENSE_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('server_id',''))" 2>/dev/null || echo "")
    fi

    if [[ -n "$SERVER_ID" ]]; then
      echo "$SERVER_ID" > /etc/iptunnel/license.id
      python3 - "$SERVER_ID" <<'PY'
import json, sys, pathlib
sid = sys.argv[1]
p = pathlib.Path("/etc/iptunnel/config.json")
cfg = json.loads(p.read_text())
cfg.setdefault("license", {{}})["server_id"] = sid
p.write_text(json.dumps(cfg, indent=2))
PY
      echo "[+] License registered — server_id: $SERVER_ID"
    else
      echo "[!] License registration failed — running on 24h grace period"
      echo "    Response: $LICENSE_RESP"
    fi
  fi
fi

systemctl daemon-reload
systemctl enable iptunnel-api >/dev/null 2>&1 || true
systemctl restart iptunnel-api

if [[ "$INSTALL_NGINX" == "1" ]]; then
  nginx -t
  if systemctl is-active --quiet nginx; then
    systemctl reload nginx
  else
    systemctl restart nginx
  fi
fi

echo
echo "IPTunnel install complete"
echo "Domain     : $DOMAIN"
echo "IP         : $PUBLIC_IP"
echo "API key    : $API_KEY"
echo "HMAC secret: $HMAC_SECRET"
if [[ -n "$LICENSE_URL" ]]; then
  echo "License URL: $LICENSE_URL"
  echo "Server ID  : $(cat /etc/iptunnel/license.id 2>/dev/null || echo 'not registered')"
fi
echo
echo "Note:"
echo "  This installer sets up the IPTunnel API, database, and the main VPS transport stack."
echo "  It installs the full stack, including Hysteria and OpenVPN support files."
echo "  SSH, SlowDNS, Squid, and Xray start enabled by default."
echo "  Hysteria and OpenVPN are installed but left disabled by default; activate them later from menu settings."
echo "  Add the A and NS records from /var/www/html/slowdns-info.txt if you want SlowDNS publicly."
echo "  Hysteria connection details are written to /var/www/html/hysteria-info.txt when Hysteria is enabled."
  echo "  Use /sshws as the primary SSH-over-WebSocket path; /ssh stays enabled on 80, 443, and 2082, root GET / websocket upgrades are accepted on 80, 443, and 2082, and port 443 now splits plain SSH from TLS so WSS/HTTPS reaches nginx regardless of SNI."
echo "  OpenVPN UDP, when enabled, is exposed on public 53 through the UDP53 mux."
echo "  Shadowsocks is still not included."
echo
echo "Health check:"
echo "  curl -sk https://$DOMAIN/api/v2/healthz"
echo
echo "Menu:"
echo "  menu"
echo "  iptunnel-menu"
echo
echo "Users endpoint:"
echo "  curl -sk -H 'Authorization: $API_KEY' https://$DOMAIN/api/v2/vps/accounts/ssh"
"""


def main() -> int:
    out = ROOT / "iptunnel-install.sh"
    with out.open("w", encoding="utf-8", newline="\n") as handle:
        handle.write(INSTALLER)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
