#!/usr/bin/env bash
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
LICENSE_URL="https://license.internetshub.com"
LICENSE_TOKEN=""
HMAC_SECRET=""

usage() {
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
}

trim() {
  local value="${1:-}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

prompt_required() {
  local __var_name="$1"
  local prompt_text="$2"
  local default_value="${3:-}"
  local reply=""

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

detect_public_ip() {
  local detected=""
  detected="$(curl -4fsSL https://api.ipify.org 2>/dev/null || true)"
  if [[ -z "$detected" ]]; then
    detected="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  fi
  if [[ -z "$detected" ]]; then
    detected="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' || true)"
  fi
  detected="$(trim "$detected")"
  if [[ -n "$detected" ]] && ! is_ipv4 "$detected"; then
    detected=""
  fi
  printf '%s' "$detected"
}

prompt_public_ip() {
  local detected_default="${1:-}"
  local reply=""

  while true; do
    if [[ -n "$detected_default" ]]; then
      read -r -p "Public IPv4 for this VPS [$detected_default]: " reply
      reply="${reply:-$detected_default}"
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
}

generate_hex() {
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
}

read_existing_hysteria_value() {
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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain)
      DOMAIN="${2:-}"
      shift 2
      ;;
    --api-key)
      API_KEY="${2:-}"
      shift 2
      ;;
    --hysteria-obfs)
      HYSTERIA_OBFS="${2:-}"
      shift 2
      ;;
    --hysteria-password)
      HYSTERIA_PASSWORD="${2:-}"
      shift 2
      ;;
    --public-ip)
      PUBLIC_IP="${2:-}"
      shift 2
      ;;
    --bind)
      BIND="${2:-}"
      shift 2
      ;;
    --port)
      PORT="${2:-}"
      shift 2
      ;;
    --name-client)
      NAME_CLIENT="${2:-}"
      shift 2
      ;;
    --status-label)
      STATUS_LABEL="${2:-}"
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
      SLOWDNS_UDP53_MODE="${2:-}"
      shift 2
      ;;
    --openvpn-udp-ports)
      OPENVPN_UDP_PORTS="${2:-}"
      shift 2
      ;;
    --license-url)
      LICENSE_URL="${2:-}"
      shift 2
      ;;
    --license-token)
      LICENSE_TOKEN="${2:-}"
      shift 2
      ;;
    --hmac-secret)
      HMAC_SECRET="${2:-}"
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
CREATE TABLE IF NOT EXISTS servers (
  address TEXT,
  key TEXT,
  auth TEXT,
  domain TEXT,
  name_client TEXT,
  status TEXT
);

CREATE TABLE IF NOT EXISTS account_sshs (
  username VARCHAR(20) PRIMARY KEY NOT NULL,
  password VARCHAR(36) NOT NULL,
  date_exp VARCHAR(10) NOT NULL,
  date_time BIGINT NOT NULL DEFAULT 0,
  days BIGINT NOT NULL DEFAULT 1,
  limit_ip BIGINT DEFAULT 0 NOT NULL,
  at_trial BIGINT DEFAULT 0 NOT NULL,
  at_banned BIGINT DEFAULT 0 NOT NULL,
  max_bw BIGINT DEFAULT 0 NOT NULL,
  use_bw BIGINT DEFAULT 0 NOT NULL,
  max_bw_hum TEXT NOT NULL DEFAULT '0',
  use_bw_hum TEXT NOT NULL DEFAULT '0',
  type TEXT NOT NULL DEFAULT 'NORMAL',
  protocol TEXT NOT NULL DEFAULT 'ALL',
  status_lock TEXT NOT NULL DEFAULT 'UNLOCKED',
  status TEXT NOT NULL DEFAULT 'AKTIF'
);

CREATE TABLE IF NOT EXISTS account_vmesses (
  username VARCHAR(20) PRIMARY KEY NOT NULL,
  uuid VARCHAR(36) NOT NULL,
  date_exp VARCHAR(10) NOT NULL,
  date_time BIGINT NOT NULL DEFAULT 0,
  days BIGINT NOT NULL DEFAULT 1,
  tls TEXT,
  ntls TEXT,
  grpc TEXT,
  tcptls TEXT,
  tcpntls TEXT,
  reality TEXT,
  upgradetls TEXT,
  upgradentls TEXT,
  limit_ip BIGINT DEFAULT 0 NOT NULL,
  at_trial BIGINT DEFAULT 0 NOT NULL,
  at_banned BIGINT DEFAULT 0 NOT NULL,
  max_bw BIGINT DEFAULT 0 NOT NULL,
  use_bw BIGINT DEFAULT 0 NOT NULL,
  max_bw_hum TEXT NOT NULL DEFAULT '0',
  use_bw_hum TEXT NOT NULL DEFAULT '0',
  type TEXT NOT NULL DEFAULT 'NORMAL',
  protocol TEXT NOT NULL DEFAULT 'ALL',
  status_lock TEXT NOT NULL DEFAULT 'UNLOCKED',
  status TEXT NOT NULL DEFAULT 'AKTIF'
);

CREATE TABLE IF NOT EXISTS account_vlesses (
  username VARCHAR(20) PRIMARY KEY NOT NULL,
  uuid VARCHAR(36) NOT NULL,
  date_exp VARCHAR(10) NOT NULL,
  date_time BIGINT NOT NULL DEFAULT 0,
  days BIGINT NOT NULL DEFAULT 1,
  tls TEXT,
  ntls TEXT,
  grpc TEXT,
  tcptls TEXT,
  tcpntls TEXT,
  reality TEXT,
  upgradetls TEXT,
  upgradentls TEXT,
  limit_ip BIGINT DEFAULT 0 NOT NULL,
  at_trial BIGINT DEFAULT 0 NOT NULL,
  at_banned BIGINT DEFAULT 0 NOT NULL,
  max_bw BIGINT DEFAULT 0 NOT NULL,
  use_bw BIGINT DEFAULT 0 NOT NULL,
  max_bw_hum TEXT NOT NULL DEFAULT '0',
  use_bw_hum TEXT NOT NULL DEFAULT '0',
  type TEXT NOT NULL DEFAULT 'NORMAL',
  protocol TEXT NOT NULL DEFAULT 'ALL',
  status_lock TEXT NOT NULL DEFAULT 'UNLOCKED',
  status TEXT NOT NULL DEFAULT 'AKTIF'
);

CREATE TABLE IF NOT EXISTS account_trojans (
  username VARCHAR(20) PRIMARY KEY NOT NULL,
  uuid VARCHAR(36) NOT NULL,
  date_exp VARCHAR(10) NOT NULL,
  date_time BIGINT NOT NULL DEFAULT 0,
  days BIGINT NOT NULL DEFAULT 1,
  tls TEXT,
  ntls TEXT,
  grpc TEXT,
  tcptls TEXT,
  tcpntls TEXT,
  reality TEXT,
  upgradetls TEXT,
  upgradentls TEXT,
  limit_ip BIGINT DEFAULT 0 NOT NULL,
  at_trial BIGINT DEFAULT 0 NOT NULL,
  at_banned BIGINT DEFAULT 0 NOT NULL,
  max_bw BIGINT DEFAULT 0 NOT NULL,
  use_bw BIGINT DEFAULT 0 NOT NULL,
  max_bw_hum TEXT NOT NULL DEFAULT '0',
  use_bw_hum TEXT NOT NULL DEFAULT '0',
  type TEXT NOT NULL DEFAULT 'NORMAL',
  protocol TEXT NOT NULL DEFAULT 'ALL',
  status_lock TEXT NOT NULL DEFAULT 'UNLOCKED',
  status TEXT NOT NULL DEFAULT 'AKTIF'
);
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
#!/usr/bin/env python3
from __future__ import annotations

import argparse
import base64
import copy
import datetime as dt
import hashlib
import hmac
import http.server
import json
import os
import pathlib
import re
import secrets
import shlex
import shutil
import sqlite3
import ssl
import subprocess
import sys
import threading
import time
import traceback
import urllib.error
import urllib.parse
import urllib.request
import uuid
from dataclasses import dataclass
from typing import Any


DEFAULT_CONFIG: dict[str, Any] = {
    "provisioning": {"enabled": False},
    "bind": "127.0.0.1",
    "port": 8080,
    "config_path": "/etc/iptunnel/config.json",
    "api_key": "CHANGE_ME",
    "db_path": "/usr/sbin/iptunnel/iptunnel.db",
    "hostname": "",
    "public_ip": "",
    "city": "",
    "isp": "",
    "allow_legacy_db_key": True,
    "license": {
        "enabled": False,
        "url": "",
        "master_token": "",
        "server_id": "",
        "server_id_path": "/etc/iptunnel/license.id",
        "checkin_interval": 86400,
        "hmac_secret": "",
        "session_ttl": 60,
        "session_rate_limit_per_minute": 10,
    },
    "ssh": {
        "manage_system_users": True,
        "shell": "/bin/false",
        "ws_path": "/sshws",
        "ws_path_aliases": ["/ssh"],
        "ports": {
            "any": "22,53,80,109,143,443,2082,2083,3128,8080,8443",
            "none": "-",
            "ssh": "22",
            "dropbear": "109,143",
            "ssl": "443,2082",
            "ws": "80,443,2082",
            "slowdns": "53",
            "squid": "3128,8080",
            "hysteria": "-",
            "ovpnohp": "-",
            "ovpntcp": "-",
            "ovpnudp": "-",
        },
    },
        "slowdns": {
            "enabled": True,
            "service": "iptunnel-slowdns",
            "mux_service": "iptunnel-udp53-mux",
            "listen_port": 5300,
            "public_port": 53,
            "local_port": 8000,
            "target": "127.0.0.1:22",
            "udp53_mode": "slowdns",
            "public_hostname": "",
            "ns_host": "",
            "tunnel_domain": "",
        "zone_prefix": "dns",
        "ns_prefix": "",
        "public_key_path": "/etc/iptunnel/slowdns/server.pub",
        "private_key_path": "/etc/iptunnel/slowdns/server.key",
        "info_path": "/var/www/html/slowdns-info.txt",
        "mtu": 1232,
    },
    "hysteria": {
        "enabled": False,
        "service": "hysteria-server",
        "port": 5666,
        "protocol": "udp",
        "hop_enabled": False,
        "hop_ports": "-",
        "obfs": "",
        "password": "",
        "sni": "",
        "ca_cert_path": "/var/www/html/hysteria.ca.crt",
        "info_path": "/var/www/html/hysteria-info.txt",
    },
    "openvpn": {
        "enabled": False,
        "tcp_public_port": 1194,
        "udp_public_port": 53,
        "udp_public_ports": [],
        "udp_internal_port": 25000,
    },
    "xray": {
        "restart_services": True,
        "ports": {
            "any": "80,443",
            "none": "80",
            "tls": "443",
        },
        "paths": {
            "vmess": {
                "primary": "/vmess",
                "grpc": "vmess",
                "multi": "/vmess",
                "stn": "/vmess",
                "up": "/upvmess",
            },
            "vless": {
                "primary": "/vless",
                "grpc": "vless",
                "multi": "/vless",
                "stn": "/vless",
                "up": "/upvless",
            },
            "trojan": {
                "primary": "/trojan",
                "grpc": "trojan",
                "multi": "/trojan",
                "stn": "/trojan",
                "up": "/uptrojan",
            },
        },
        "configs": {
            "vmess": "/etc/iptunnel/xray/vmess.json",
            "vless": "/etc/iptunnel/xray/vless.json",
            "trojan": "/etc/iptunnel/xray/trojan.json",
        },
        "services": {
            "vmess": "iptunnel-vmess",
            "vless": "iptunnel-vless",
            "trojan": "iptunnel-trojan",
        },
    },
}


PROTOCOLS: dict[str, dict[str, Any]] = {
    "sshvpn": {
        "table": "account_sshs",
        "secret_column": "password",
        "kind": "ssh",
        "create_route": "/vps/sshvpn",
        "trial_route": "/vps/trialsshvpn",
        "recovery_route": "/vps/recoverysshvpn",
        "list_route": "/vps/listuserssshvpn",
        "list_recovery_route": "/vps/listrecoverysshvpn",
        "modify_route": "/vps/modifysshvpn",
        "limit_ip_route": "/vps/changelimipsshvpn",
        "limit_ip_all_route": "/vps/changelimipallsshvpn",
        "delete_pattern": re.compile(r"^/vps/deletesshvpn/(?P<username>[^/]+)$"),
        "check_pattern": re.compile(r"^/vps/checkconfigsshvpn/(?P<username>[^/]+)$"),
        "renew_pattern": re.compile(r"^/vps/renewsshvpn/(?P<username>[^/]+)/(?P<expired>\d+)$"),
        "lock_pattern": re.compile(r"^/vps/locksshvpn/(?P<username>[^/]+)$"),
        "unlock_pattern": re.compile(r"^/vps/unlocksshvpn/(?P<username>[^/]+)/(?P<password>[^/]+)$"),
    },
    "vmess": {
        "table": "account_vmesses",
        "secret_column": "uuid",
        "kind": "xray",
        "xray_protocol": "vmess",
        "create_route": "/vps/vmessall",
        "trial_route": "/vps/trialvmessall",
        "recovery_route": "/vps/recoveryvmess",
        "list_route": "/vps/listusersvmess",
        "list_recovery_route": "/vps/listrecoveryvmess",
        "modify_route": "/vps/modifyvmess",
        "limit_ip_route": "/vps/changelimipvmess",
        "limit_ip_all_route": "/vps/changelimipallvmess",
        "limit_bw_route": "/vps/changelimbwvmess",
        "limit_bw_all_route": "/vps/changelimbwallvmess",
        "delete_pattern": re.compile(r"^/vps/deletevmess/(?P<username>[^/]+)$"),
        "check_pattern": re.compile(r"^/vps/checkconfigvmess/(?P<username>[^/]+)$"),
        "renew_pattern": re.compile(r"^/vps/renewvmess/(?P<username>[^/]+)/(?P<expired>\d+)$"),
        "lock_pattern": re.compile(r"^/vps/lockvmess/(?P<username>[^/]+)$"),
        "unlock_pattern": re.compile(r"^/vps/unlockvmess/(?P<username>[^/]+)$"),
    },
    "vless": {
        "table": "account_vlesses",
        "secret_column": "uuid",
        "kind": "xray",
        "xray_protocol": "vless",
        "create_route": "/vps/vlessall",
        "trial_route": "/vps/trialvlessall",
        "recovery_route": "/vps/recoveryvless",
        "list_route": "/vps/listusersvless",
        "list_recovery_route": "/vps/listrecoveryvless",
        "modify_route": "/vps/modifyvless",
        "limit_ip_route": "/vps/changelimipvless",
        "limit_ip_all_route": "/vps/changelimipallvless",
        "limit_bw_route": "/vps/changelimbwvless",
        "limit_bw_all_route": "/vps/changelimbwallvless",
        "delete_pattern": re.compile(r"^/vps/deletevless/(?P<username>[^/]+)$"),
        "check_pattern": re.compile(r"^/vps/checkconfigvless/(?P<username>[^/]+)$"),
        "renew_pattern": re.compile(r"^/vps/renewvless/(?P<username>[^/]+)/(?P<expired>\d+)$"),
        "lock_pattern": re.compile(r"^/vps/lockvless/(?P<username>[^/]+)$"),
        "unlock_pattern": re.compile(r"^/vps/unlockvless/(?P<username>[^/]+)$"),
    },
    "trojan": {
        "table": "account_trojans",
        "secret_column": "uuid",
        "kind": "xray",
        "xray_protocol": "trojan",
        "create_route": "/vps/trojanall",
        "trial_route": "/vps/trialtrojanall",
        "recovery_route": "/vps/recoverytrojan",
        "list_route": "/vps/listuserstrojan",
        "list_recovery_route": "/vps/listrecoverytrojan",
        "modify_route": "/vps/modifytrojan",
        "limit_ip_route": "/vps/changelimiptrojan",
        "limit_ip_all_route": "/vps/changelimipalltrojan",
        "limit_bw_route": "/vps/changelimbwtrojan",
        "limit_bw_all_route": "/vps/changelimbwalltrojan",
        "delete_pattern": re.compile(r"^/vps/deletetrojan/(?P<username>[^/]+)$"),
        "check_pattern": re.compile(r"^/vps/checkconfigtrojan/(?P<username>[^/]+)$"),
        "renew_pattern": re.compile(r"^/vps/renewtrojan/(?P<username>[^/]+)/(?P<expired>\d+)$"),
        "lock_pattern": re.compile(r"^/vps/locktrojan/(?P<username>[^/]+)$"),
        "unlock_pattern": re.compile(r"^/vps/unlocktrojan/(?P<username>[^/]+)$"),
    },
}

V2_PROTOCOL_ALIASES: dict[str, str] = {
    "ssh": "sshvpn",
    "vmess": "vmess",
    "vless": "vless",
    "trojan": "trojan",
}


USERNAME_RE = re.compile(r"^[A-Za-z0-9._-]{1,20}$")
DOMAIN_RE = re.compile(r"^(?=.{1,253}$)(?!-)(?:[A-Za-z0-9-]{1,63}\.)+[A-Za-z]{2,63}$")
MAX_BODY_BYTES = 1_048_576
APP_VERSION = "2026.09.06.1"


class ApiError(Exception):
    def __init__(self, status: int, message: str) -> None:
        super().__init__(message)
        self.status = status
        self.message = message


@dataclass
class ServerInfo:
    address: str = ""
    domain: str = ""
    key: str = ""
    auth: str = ""
    name_client: str = ""
    status: str = ""


def deep_merge(base: dict[str, Any], override: dict[str, Any]) -> dict[str, Any]:
    result = copy.deepcopy(base)
    for key, value in override.items():
        if isinstance(value, dict) and isinstance(result.get(key), dict):
            result[key] = deep_merge(result[key], value)
        else:
            result[key] = value
    return result


def load_config(config_path: pathlib.Path | None) -> dict[str, Any]:
    config = copy.deepcopy(DEFAULT_CONFIG)
    if config_path and config_path.exists():
        override = json.loads(config_path.read_text(encoding="utf-8"))
        config = deep_merge(config, override)
        config["config_path"] = str(config_path)
    env_key = os.getenv("IPTUNNEL_API_KEY")
    if env_key:
        config["api_key"] = env_key
    env_db = os.getenv("IPTUNNEL_API_DB_PATH")
    if env_db:
        config["db_path"] = env_db
    env_host = os.getenv("IPTUNNEL_API_HOSTNAME")
    if env_host:
        config["hostname"] = env_host
    env_bind = os.getenv("IPTUNNEL_API_BIND")
    if env_bind:
        config["bind"] = env_bind
    env_port = os.getenv("IPTUNNEL_API_PORT")
    if env_port:
        config["port"] = int(env_port)
    return config


def utc_now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


def normalize_http_path(value: Any, default: str = "/") -> str:
    path = str(value or default).strip()
    if not path:
        path = default
    path = path.split("?", 1)[0].strip()
    if not path:
        path = default
    if not path.startswith("/"):
        path = "/" + path
    if len(path) > 1:
        path = path.rstrip("/")
    return path or "/"


def normalize_http_paths(values: list[Any] | tuple[Any, ...], default: str = "/") -> list[str]:
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


def compare_release_versions(left: str, right: str) -> int:
    def tokenize(value: str) -> list[int | str]:
        parts = re.findall(r"\d+|[A-Za-z]+", str(value or ""))
        tokens: list[int | str] = []
        for part in parts:
            if part.isdigit():
                tokens.append(int(part))
            else:
                tokens.append(part.lower())
        return tokens

    left_tokens = tokenize(left)
    right_tokens = tokenize(right)
    limit = max(len(left_tokens), len(right_tokens))
    for index in range(limit):
        left_value: int | str = left_tokens[index] if index < len(left_tokens) else 0
        right_value: int | str = right_tokens[index] if index < len(right_tokens) else 0
        if isinstance(left_value, int) and isinstance(right_value, int):
            if left_value < right_value:
                return -1
            if left_value > right_value:
                return 1
            continue
        left_text = str(left_value)
        right_text = str(right_value)
        if left_text < right_text:
            return -1
        if left_text > right_text:
            return 1
    return 0


def parse_duration(value: str) -> dt.timedelta:
    value = value.strip().lower()
    match = re.fullmatch(r"(\d+)([mhd])", value)
    if not match:
        raise ApiError(400, "timelimit must look like 10m, 1h, or 1d")
    amount = int(match.group(1))
    unit = match.group(2)
    if unit == "m":
        return dt.timedelta(minutes=amount)
    if unit == "h":
        return dt.timedelta(hours=amount)
    return dt.timedelta(days=amount)


def quota_to_storage(kuota: int) -> tuple[int, str]:
    if kuota <= 0:
        return 0, "0 GB"
    return kuota * 1024 * 1024 * 1024, f"{kuota} GB"


def parse_reset_flag(value: Any) -> bool:
    return str(value).strip().lower() in {"1", "true", "yes", "y", "reset", "on"}


def safe_username(value: str) -> str:
    if not USERNAME_RE.fullmatch(value):
        raise ApiError(400, "username must be 1-20 chars using letters, numbers, dot, dash, or underscore")
    return value


def random_username(prefix: str = "trial") -> str:
    return f"{prefix}{secrets.token_hex(3)}"[:20]


def random_password(length: int = 8) -> str:
    alphabet = "abcdefghjkmnpqrstuvwxyz23456789"
    return "".join(secrets.choice(alphabet) for _ in range(length))


def get_optional(payload: dict[str, Any], *names: str, default: Any = None) -> Any:
    for name in names:
        if name in payload:
            return payload[name]
    return default


def get_required(payload: dict[str, Any], *names: str) -> str:
    value = get_optional(payload, *names, default=None)
    if value is None or str(value).strip() == "":
        raise ApiError(400, f"missing required field: {names[0]}")
    return str(value).strip()


def get_int(payload: dict[str, Any], *names: str) -> int:
    value = get_required(payload, *names)
    try:
        return int(value)
    except ValueError as exc:
        raise ApiError(400, f"{names[0]} must be an integer") from exc


def get_optional_int(payload: dict[str, Any], *names: str, default: int | None = None) -> int | None:
    value = get_optional(payload, *names, default=None)
    if value is None or str(value).strip() == "":
        return default
    try:
        return int(str(value).strip())
    except ValueError as exc:
        raise ApiError(400, f"{names[0]} must be an integer") from exc


def expiry_timestamp(expires_on: str) -> int:
    return int(dt.datetime.fromisoformat(f"{expires_on}T00:00:00+00:00").timestamp())


def bytes_to_human(num_bytes: int) -> str:
    if num_bytes <= 0:
        return "0 B"
    units = ["B", "KB", "MB", "GB", "TB"]
    value = float(num_bytes)
    unit = units[0]
    for unit in units:
        if value < 1024 or unit == units[-1]:
            break
        value /= 1024.0
    if unit == "B":
        return f"{int(value)} {unit}"
    return f"{value:.2f} {unit}"


class IptunnelState:
    def __init__(self, config: dict[str, Any], dry_run: bool = False) -> None:
        self.config = config
        self.dry_run = dry_run
        self.db_path = pathlib.Path(config["db_path"])
        self._xray_locks = {
            protocol: threading.Lock()
            for protocol in (self.config.get("xray", {}).get("configs") or {})
        }
        # -- Session token store (in-memory, short-lived) ---
        self._session_tokens: dict[str, float] = {}  # token → expiry_unix
        self._session_lock = threading.Lock()
        self._session_issue_windows: dict[str, list[float]] = {}

    def refresh_config(self) -> None:
        config_path_value = str(self.config.get("config_path") or DEFAULT_CONFIG["config_path"])
        config_path = pathlib.Path(config_path_value)
        refreshed = load_config(config_path if config_path.exists() else None)
        refreshed["config_path"] = config_path_value
        refreshed["bind"] = self.config.get("bind", refreshed.get("bind", DEFAULT_CONFIG["bind"]))
        refreshed["port"] = self.config.get("port", refreshed.get("port", DEFAULT_CONFIG["port"]))
        self.config = refreshed
        for protocol in (self.config.get("xray", {}).get("configs") or {}):
            self._xray_locks.setdefault(protocol, threading.Lock())

    def save_config(self) -> None:
        config_path = pathlib.Path(str(self.config.get("config_path") or DEFAULT_CONFIG["config_path"]))
        config_path.parent.mkdir(parents=True, exist_ok=True)
        payload = copy.deepcopy(self.config)
        payload.pop("config_path", None)
        config_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

    @staticmethod
    def clean_domain(value: Any, field: str) -> str:
        domain = str(value or "").strip().strip(".").lower()
        if not domain or not DOMAIN_RE.fullmatch(domain):
            raise ApiError(400, f"{field} must be a valid domain name")
        return domain

    # ── Session Tokens (HMAC client-auth layer) ──────────────
    def issue_session_token(self) -> tuple[str, int]:
        """Generate a one-time session token for SSH auth.
        Returns (token, ttl_seconds)."""
        lic = self.config.get("license", {})
        ttl = int(lic.get("session_ttl", 60) or 60)
        token = secrets.token_hex(16)
        expiry = time.time() + ttl
        with self._session_lock:
            self._session_tokens[token] = expiry
            # Garbage-collect expired tokens
            now = time.time()
            self._session_tokens = {
                t: e for t, e in self._session_tokens.items() if e > now
            }
        return token, ttl

    def allow_session_issue(self, ip_address: str) -> bool:
        lic = self.config.get("license", {})
        limit = int(lic.get("session_rate_limit_per_minute", 10) or 10)
        now = time.time()
        with self._session_lock:
            window = [ts for ts in self._session_issue_windows.get(ip_address, []) if now - ts < 60]
            if len(window) >= limit:
                self._session_issue_windows[ip_address] = window
                return False
            window.append(now)
            self._session_issue_windows[ip_address] = window
        return True

    def verify_session_token(self, token: str) -> bool:
        """Check and consume a one-time session token."""
        with self._session_lock:
            expiry = self._session_tokens.pop(token, None)
        if expiry is None:
            return False
        return time.time() < expiry

    # ── HMAC password verification (for PAM) ─────────────────
    def verify_hmac_password(self, password: str) -> bool:
        """Verify an HMAC-signed password from the IPTunnel app.
        Format: HMAC(secret, floor(unix/300) || hostname)
        Accepts current window and ±1 window (15-minute total)."""
        lic = self.config.get("license", {})
        secret = lic.get("hmac_secret", "")
        if not secret:
            return False
        host = self.hostname()
        now_window = int(time.time()) // 300
        for offset in (-1, 0, 1):
            window = now_window + offset
            message = f"{window}{host}"
            expected = hmac.new(
                secret.encode("utf-8"),
                message.encode("utf-8"),
                hashlib.sha256,
            ).hexdigest()
            if secrets.compare_digest(password, expected):
                return True
        return False

    def connect(self) -> sqlite3.Connection:
        conn = sqlite3.connect(str(self.db_path))
        conn.row_factory = sqlite3.Row
        return conn

    def server_info(self) -> ServerInfo:
        try:
            with self.connect() as conn:
                row = conn.execute(
                    "SELECT address, key, auth, domain, name_client, status FROM servers LIMIT 1"
                ).fetchone()
        except sqlite3.Error:
            row = None
        if not row:
            return ServerInfo()
        return ServerInfo(
            address=row["address"] or "",
            key=row["key"] or "",
            auth=row["auth"] or "",
            domain=row["domain"] or "",
            name_client=row["name_client"] or "",
            status=row["status"] or "",
        )

    def hostname(self) -> str:
        return self.config.get("hostname") or self.server_info().domain or "localhost"

    def public_ip(self) -> str:
        return self.config.get("public_ip") or self.server_info().address or "127.0.0.1"

    def accepted_keys(self) -> list[str]:
        keys: list[str] = []
        config_key = str(self.config.get("api_key") or "").strip()
        if config_key and config_key != "CHANGE_ME":
            keys.append(config_key)
        if self.config.get("allow_legacy_db_key", True):
            legacy = self.server_info().key.strip()
            if legacy:
                keys.append(legacy)
        return list(dict.fromkeys(keys))

    def slowdns_config(self) -> dict[str, Any]:
        return dict(self.config.get("slowdns") or {})

    def ssh_config(self) -> dict[str, Any]:
        return dict(self.config.get("ssh") or {})

    def ssh_ws_paths(self) -> list[str]:
        ssh = self.ssh_config()
        aliases = ssh.get("ws_path_aliases") or []
        if isinstance(aliases, str):
            alias_values = [part.strip() for part in aliases.split(",") if part.strip()]
        elif isinstance(aliases, (list, tuple)):
            alias_values = list(aliases)
        else:
            alias_values = []
        if not alias_values:
            alias_values = ["/ssh"]
        return normalize_http_paths([ssh.get("ws_path", "/sshws"), *alias_values], default="/sshws")

    def slowdns_enabled(self) -> bool:
        return bool(self.slowdns_config().get("enabled", False))

    def slowdns_legacy_tunnel_domain(self) -> str:
        prefix = str(self.slowdns_config().get("zone_prefix") or "").strip(".")
        host = self.hostname().strip(".")
        return f"{prefix}.{host}" if prefix else host

    def slowdns_legacy_ns_host(self) -> str:
        prefix = str(self.slowdns_config().get("ns_prefix") or "").strip(".")
        host = self.hostname().strip(".")
        return f"{prefix}.{host}" if prefix else host

    def slowdns_public_hostname(self) -> str:
        value = str(self.slowdns_config().get("public_hostname") or "").strip(".")
        if value:
            return value
        return self.slowdns_legacy_ns_host()

    def slowdns_tunnel_domain(self) -> str:
        value = str(self.slowdns_config().get("tunnel_domain") or "").strip(".")
        if value:
            return value
        return self.slowdns_legacy_tunnel_domain()

    def slowdns_zone(self) -> str:
        return self.slowdns_tunnel_domain()

    def slowdns_ns_host(self) -> str:
        value = str(self.slowdns_config().get("ns_host") or "").strip(".")
        if value:
            return value
        return self.slowdns_public_hostname()

    def slowdns_public_port(self) -> int:
        return int(self.slowdns_config().get("public_port", 53))

    def slowdns_public_key(self) -> str:
        path_value = self.slowdns_config().get("public_key_path")
        if not path_value:
            return ""
        path = pathlib.Path(str(path_value))
        if not path.exists():
            return ""
        return path.read_text(encoding="utf-8").strip()

    def slowdns_info(self) -> dict[str, Any] | None:
        if not self.slowdns_enabled():
            return None
        config = self.slowdns_config()
        public_hostname = self.slowdns_public_hostname()
        tunnel_domain = self.slowdns_tunnel_domain()
        ns_host = self.slowdns_ns_host()
        public_port = self.slowdns_public_port()
        return {
            "enabled": True,
            "listen_port": int(config.get("listen_port", 5300)),
            "public_port": public_port,
            "local_port": int(config.get("local_port", 8000)),
            "public_hostname": public_hostname,
            "public_ip": self.public_ip(),
            "ns_host": ns_host,
            "public_key": self.slowdns_public_key(),
            "records": {
                "a": {
                    "type": "A",
                    "name": public_hostname,
                    "value": self.public_ip(),
                },
                "ns": {
                    "type": "NS",
                    "name": tunnel_domain,
                    "value": ns_host,
                },
            },
            "service": str(config.get("service") or ""),
            "mux_service": str(config.get("mux_service") or ""),
            "target": str(config.get("target") or ""),
            "tunnel_domain": tunnel_domain,
            "mtu": int(config.get("mtu", 0) or 0),
            "usage": {
                "summary": (
                    f"Create A {public_hostname} -> {self.public_ip()} and "
                    f"NS {tunnel_domain} -> {ns_host} on the parent zone."
                ),
                "connect_host": tunnel_domain,
                "connect_port": public_port,
                "client_local_host": "127.0.0.1",
                "client_local_port": int(config.get("local_port", 8000)),
            },
        }

    def hysteria_config(self) -> dict[str, Any]:
        return dict(self.config.get("hysteria") or {})

    def hysteria_enabled(self) -> bool:
        return bool(self.hysteria_config().get("enabled", False))

    def _read_hysteria_runtime_secret(self, field: str) -> str:
        path = pathlib.Path("/etc/hysteria/config.json")
        if not path.exists():
            return ""
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except Exception:
            return ""
        if field == "obfs":
            return str(data.get("obfs") or "")
        if field == "password":
            auth = data.get("auth") or {}
            config = auth.get("config") or []
            if config:
                return str(config[0] or "")
        return ""

    def hysteria_info(self) -> dict[str, Any] | None:
        if not self.hysteria_enabled():
            return None
        config = self.hysteria_config()
        host = self.hostname()
        port = int(config.get("port", 5666) or 5666)
        obfs = str(config.get("obfs") or "") or self._read_hysteria_runtime_secret("obfs")
        password = str(config.get("password") or "") or self._read_hysteria_runtime_secret("password")
        params = []
        if obfs:
            params.append(f"obfs={urllib.parse.quote(obfs, safe='')}")
        if password:
            params.append(f"auth={urllib.parse.quote(password, safe='')}")
        params.append("insecure=1")
        uri = f"hysteria://{host}:{port}?{'&'.join(params)}"
        return {
            "enabled": True,
            "host": host,
            "port": port,
            "protocol": str(config.get("protocol") or "udp"),
            "hop_enabled": bool(config.get("hop_enabled", True)),
            "hop_ports": str(config.get("hop_ports") or "10000:65000"),
            "obfs": obfs,
            "password": password,
            "uri": uri,
            "sni": str(config.get("sni") or host),
            "service": str(config.get("service") or "hysteria-server"),
            "ca_cert_path": str(config.get("ca_cert_path") or ""),
            "info_path": str(config.get("info_path") or ""),
        }

    def _configured_openvpn_udp_ports(
        self,
        openvpn_config: dict[str, Any] | None = None,
        *,
        active_only: bool = True,
    ) -> list[int]:
        config = dict(openvpn_config or self.config.get("openvpn") or {})
        raw_ports = config.get("udp_public_ports")
        if isinstance(raw_ports, str):
            candidates: list[Any] = raw_ports.split(",")
        elif isinstance(raw_ports, (list, tuple)):
            candidates = list(raw_ports)
        else:
            candidates = []
        if not candidates and config.get("udp_public_port") not in {None, "", "-"}:
            candidates = [config.get("udp_public_port")]

        ports: list[int] = []
        for candidate in candidates:
            try:
                port = int(str(candidate).strip())
            except (TypeError, ValueError):
                continue
            if 1 <= port <= 65535 and port not in ports:
                ports.append(port)

        udp53_mode = str((self.config.get("slowdns") or {}).get("udp53_mode", "slowdns") or "slowdns")
        if udp53_mode in {"openvpn", "shared"}:
            ports = [53, *[port for port in ports if port != 53]]
        else:
            ports = [port for port in ports if port != 53]
        if active_only and not bool(config.get("enabled", False)):
            return []
        return ports

    def _derive_openvpn_ports(self) -> tuple[str, str, list[int], dict[str, Any]]:
        ssh_ports = dict((self.config.get("ssh") or {}).get("ports") or {})
        openvpn_config = dict(self.config.get("openvpn") or {})
        tcp_port = str(ssh_ports.get("ovpntcp", "-") or "-")
        udp_ports = self._configured_openvpn_udp_ports(openvpn_config)
        udp_port = ",".join(str(port) for port in udp_ports) or "-"
        return tcp_port, udp_port, udp_ports, openvpn_config

    def _openvpn_udp_profile_paths(self, udp_port: str) -> tuple[pathlib.Path, pathlib.Path]:
        suffix = "53" if udp_port == "53" else udp_port
        web_root = pathlib.Path("/var/www/html")
        return web_root / f"iptunnel-udp-{suffix}.ovpn", web_root / "iptunnel-openvpn-udp.ovpn"

    def _repair_openvpn_udp_profiles(self, udp_ports: list[int]) -> None:
        if self.dry_run or os.name != "posix" or not udp_ports:
            return
        active_path = pathlib.Path("/var/www/html/iptunnel-openvpn-udp.ovpn")
        profile_paths = [self._openvpn_udp_profile_paths(str(port))[0] for port in udp_ports]
        if active_path.exists() and all(path.exists() for path in profile_paths):
            return
        env = os.environ.copy()
        env["IPTUNNEL_CONFIG_PATH"] = str(self.config.get("config_path") or "/etc/iptunnel/config.json")
        result = subprocess.run(
            ["/opt/iptunnel/transport_stack.sh", "refresh-openvpn-udp-port"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
            env=env,
        )
        if result.returncode == 0:
            self.refresh_config()

    def openvpn_info(self) -> dict[str, Any] | None:
        tcp_port, udp_port, udp_ports, openvpn_config = self._derive_openvpn_ports()
        if udp_ports:
            self._repair_openvpn_udp_profiles(udp_ports)
            tcp_port, udp_port, udp_ports, openvpn_config = self._derive_openvpn_ports()
        enabled = tcp_port != "-" or udp_port != "-"
        if not enabled:
            return None
        host = self.hostname()
        profiles: dict[str, dict[str, Any]] = {}
        if tcp_port != "-":
            profiles["tcp"] = {
                "port": int(tcp_port),
                "file": "iptunnel-tcp-1194.ovpn",
                "url_http": f"http://{host}/iptunnel-tcp-1194.ovpn",
                "url_https": f"https://{host}/iptunnel-tcp-1194.ovpn",
            }
        udp_profiles: list[dict[str, Any]] = []
        for port in udp_ports:
            udp_port_value = str(port)
            filename = f"iptunnel-udp-{udp_port_value}.ovpn"
            profile_path, _ = self._openvpn_udp_profile_paths(udp_port_value)
            profile = {
                "port": port,
                "label": "FastDNS (OpenVPN UDP 53)" if port == 53 else f"OpenVPN UDP {port}",
                "file": filename,
                "path": str(profile_path),
                "exists": profile_path.exists(),
                "url_http": f"http://{host}/{filename}",
                "url_https": f"https://{host}/{filename}",
            }
            udp_profiles.append(profile)
            profiles[f"udp_{port}"] = profile
        if udp_profiles:
            profiles["udp"] = udp_profiles[0]
            active_path = pathlib.Path("/var/www/html/iptunnel-openvpn-udp.ovpn")
            profiles["active_udp"] = {
                "port": udp_profiles[0]["port"],
                "file": "iptunnel-openvpn-udp.ovpn",
                "path": str(active_path),
                "exists": active_path.exists(),
                "url_http": f"http://{host}/iptunnel-openvpn-udp.ovpn",
                "url_https": f"https://{host}/iptunnel-openvpn-udp.ovpn",
            }
        return {
            "enabled": True,
            "host": host,
            "udp_public_port": udp_ports[0] if udp_ports else int(openvpn_config.get("udp_public_port", 53) or 53),
            "udp_public_ports": udp_ports,
            "udp_internal_port": int(openvpn_config.get("udp_internal_port", 25000) or 25000),
            "profiles": profiles,
            "udp_profiles": udp_profiles,
        }

    def license_state(self) -> dict[str, Any]:
        license_config = dict(self.config.get("license") or {})
        server_id_path = pathlib.Path(str(license_config.get("server_id_path") or "/etc/iptunnel/license.id"))
        server_id = ""
        if server_id_path.exists():
            try:
                server_id = server_id_path.read_text(encoding="utf-8").strip()
            except OSError:
                server_id = ""
        return {
            "enabled": bool(license_config.get("enabled")),
            "url": str(license_config.get("url") or ""),
            "server_id": server_id or str(license_config.get("server_id") or ""),
            "checkin_interval": int(license_config.get("checkin_interval", 86400) or 86400),
        }

    def runtime_summary(self) -> dict[str, Any]:
        ssh = self.ssh_config()
        ssh_ports = dict(ssh.get("ports") or {})
        return {
            "hostname": self.hostname(),
            "public_ip": self.public_ip(),
            "city": self.config.get("city", ""),
            "isp": self.config.get("isp", ""),
            "license": self.license_state(),
            "ssh": {
                "manage_system_users": bool(ssh.get("manage_system_users", True)),
                "ws_path": self.ssh_ws_paths()[0],
                "ws_paths": self.ssh_ws_paths(),
                "ports": ssh_ports,
            },
            "xray": {
                "ports": self._xray_ports(),
                "paths": copy.deepcopy((self.config.get("xray") or {}).get("paths") or {}),
                "services": copy.deepcopy((self.config.get("xray") or {}).get("services") or {}),
            },
            "slowdns": self.slowdns_info(),
            "hysteria": self.hysteria_info(),
            "openvpn": {
                "tcp": ssh_ports.get("ovpntcp", "-"),
                "udp": ssh_ports.get("ovpnudp", "-"),
                "enabled": str(ssh_ports.get("ovpntcp", "-")) != "-" or str(ssh_ports.get("ovpnudp", "-")) != "-",
            },
        }

    def _systemctl_query(self, *args: str) -> str:
        if os.name != "posix":
            return "unsupported"
        try:
            result = subprocess.run(
                ["systemctl", *args],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=False,
            )
        except OSError:
            return "unknown"
        value = (result.stdout or result.stderr).strip()
        return value or "unknown"

    def service_summary(self) -> list[dict[str, Any]]:
        services = [
            "iptunnel-api",
            "iptunnel-ssh-ws",
            "iptunnel-edge-proxy",
            "iptunnel-fronting-proxy",
            "iptunnel-ssh-ssl",
            "iptunnel-udp53-mux",
            "iptunnel-vmess",
            "iptunnel-vless",
            "iptunnel-trojan",
            "iptunnel-slowdns",
            "iptunnel-slowdns-target",
            "nginx",
            "dropbear",
            "ssh",
        ]
        if self.hysteria_enabled():
            services.extend(["iptunnel-hysteria", str(self.hysteria_config().get("service") or "hysteria-server")])
        ssh_ports = dict((self.config.get("ssh") or {}).get("ports") or {})
        if str(ssh_ports.get("ovpntcp", "-")) != "-" or str(ssh_ports.get("ovpnudp", "-")) != "-":
            services.extend(["openvpn-server@iptunnel-tcp", "openvpn-server@iptunnel-udp"])
        deduped = list(dict.fromkeys(services))
        summary: list[dict[str, Any]] = []
        for service in deduped:
            active = self._systemctl_query("is-active", service)
            enabled = self._systemctl_query("is-enabled", service)
            summary.append(
                {
                    "name": service,
                    "active": active,
                    "enabled": enabled,
                }
            )
        return summary

    def bandwidth_summary(self) -> dict[str, Any]:
        totals = {"used_bytes": 0, "max_bytes": 0, "accounts": 0}
        by_protocol: dict[str, Any] = {}
        with self.connect() as conn:
            for protocol_name, spec in PROTOCOLS.items():
                rows = conn.execute(
                    f"SELECT username, use_bw, max_bw, use_bw_hum, max_bw_hum, date_exp, limit_ip, status_lock, status FROM {spec['table']} ORDER BY username ASC"
                ).fetchall()
                accounts: list[dict[str, Any]] = []
                protocol_used = 0
                protocol_max = 0
                for row in rows:
                    used_bw = int(row["use_bw"] or 0)
                    max_bw = int(row["max_bw"] or 0)
                    protocol_used += used_bw
                    protocol_max += max_bw
                    totals["used_bytes"] += used_bw
                    totals["max_bytes"] += max_bw
                    totals["accounts"] += 1
                    accounts.append(
                        {
                            "username": row["username"],
                            "used_bytes": used_bw,
                            "used_human": row["use_bw_hum"] or bytes_to_human(used_bw),
                            "max_bytes": max_bw,
                            "max_human": row["max_bw_hum"] or bytes_to_human(max_bw),
                            "expires_on": row["date_exp"],
                            "limit_ip": int(row["limit_ip"] or 0),
                            "locked": str(row["status_lock"] or "").upper() == "LOCKED",
                            "status": row["status"],
                        }
                    )
                by_protocol[protocol_name] = {
                    "accounts": accounts,
                    "used_bytes": protocol_used,
                    "used_human": bytes_to_human(protocol_used),
                    "max_bytes": protocol_max,
                    "max_human": bytes_to_human(protocol_max),
                }
        totals["used_human"] = bytes_to_human(int(totals["used_bytes"]))
        totals["max_human"] = bytes_to_human(int(totals["max_bytes"]))
        return {"totals": totals, "protocols": by_protocol}

    def transport_action(self, transport: str, enable: bool) -> dict[str, Any]:
        action_map = {
            ("hysteria", True): "enable-hysteria",
            ("hysteria", False): "disable-hysteria",
            ("openvpn", True): "enable-openvpn",
            ("openvpn", False): "disable-openvpn",
        }
        if transport not in {"hysteria", "openvpn"}:
            raise ApiError(400, "unsupported transport")
        action = action_map[(transport, enable)]
        if os.name != "posix":
            raise ApiError(500, "transport actions require a Linux host")
        env = os.environ.copy()
        env["IPTUNNEL_CONFIG_PATH"] = str(self.config.get("config_path") or "/etc/iptunnel/config.json")
        result = subprocess.run(
            ["/opt/iptunnel/transport_stack.sh", action],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
            env=env,
        )
        if result.returncode != 0:
            raise ApiError(400, (result.stderr or result.stdout or "transport action failed").strip())
        self.refresh_config()
        openvpn = self.openvpn_info() or {}
        profiles = openvpn.get("profiles") or {}
        return {
            "transport": transport,
            "enabled": enable,
            "ports": {
                "tcp": (profiles.get("tcp") or {}).get("port"),
                "udp": ",".join(str(port) for port in openvpn.get("udp_public_ports") or []),
                "udp_ports": openvpn.get("udp_public_ports") or [],
            } if transport == "openvpn" else {},
            "openvpn": openvpn if transport == "openvpn" else None,
            "stdout": (result.stdout or "").strip(),
        }

    def set_udp53_mode(self, mode: str) -> dict[str, Any]:
        normalized = str(mode or "").strip().lower()
        alias_map = {
            "slowdns": "slowdns",
            "slowdns-only": "slowdns",
            "openvpn": "openvpn",
            "openvpn-only": "openvpn",
            "ovpnudp": "openvpn",
            "shared": "shared",
            "both": "shared",
            "mux": "shared",
        }
        resolved = alias_map.get(normalized, "")
        if not resolved:
            raise ApiError(400, "unsupported udp53 mode")
        self._ensure_linux()

        slowdns_config = self.config.setdefault("slowdns", {})
        openvpn_config = self.config.setdefault("openvpn", {})
        previous_slowdns = copy.deepcopy(slowdns_config)
        previous_openvpn = copy.deepcopy(openvpn_config)
        previous_mode = str(previous_slowdns.get("udp53_mode") or "slowdns")

        udp_ports = self._configured_openvpn_udp_ports(openvpn_config, active_only=False)
        if resolved in {"openvpn", "shared"}:
            udp_ports = [53, *[port for port in udp_ports if port != 53]]
            openvpn_config["enabled"] = True
        else:
            udp_ports = [port for port in udp_ports if port != 53]
            if not udp_ports:
                openvpn_config["enabled"] = False

        slowdns_config["udp53_mode"] = resolved
        slowdns_config["enabled"] = resolved != "openvpn"
        openvpn_config["udp_public_ports"] = udp_ports
        openvpn_config["udp_public_port"] = udp_ports[0] if udp_ports else 53
        self.save_config()

        env = os.environ.copy()
        env["IPTUNNEL_CONFIG_PATH"] = str(self.config.get("config_path") or "/etc/iptunnel/config.json")
        env["IPTUNNEL_SLOWDNS_UDP53_MODE"] = resolved
        result = subprocess.run(
            ["/opt/iptunnel/transport_stack.sh", "set-udp53-mode", resolved],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
            env=env,
        )
        if result.returncode != 0:
            self.config["slowdns"] = previous_slowdns
            self.config["openvpn"] = previous_openvpn
            self.save_config()
            rollback_env = env.copy()
            rollback_env["IPTUNNEL_SLOWDNS_UDP53_MODE"] = previous_mode
            subprocess.run(
                ["/opt/iptunnel/transport_stack.sh", "set-udp53-mode", previous_mode],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=False,
                env=rollback_env,
            )
            raise ApiError(400, (result.stderr or result.stdout or "UDP53 mode change failed").strip())

        self.refresh_config()
        slowdns = self.slowdns_config()
        persisted_mode = str(slowdns.get("udp53_mode") or "slowdns")
        if persisted_mode != resolved:
            self.config["slowdns"] = previous_slowdns
            self.config["openvpn"] = previous_openvpn
            self.save_config()
            rollback_env = env.copy()
            rollback_env["IPTUNNEL_SLOWDNS_UDP53_MODE"] = previous_mode
            subprocess.run(
                ["/opt/iptunnel/transport_stack.sh", "set-udp53-mode", previous_mode],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=False,
                env=rollback_env,
            )
            self.refresh_config()
            raise ApiError(500, f"UDP53 mode did not persist: requested {resolved}, found {persisted_mode}")

        openvpn = self.openvpn_info()
        return {
            "udp53_mode": persisted_mode,
            "udp_public_port": (openvpn or {}).get("udp_public_port"),
            "udp_public_ports": (openvpn or {}).get("udp_public_ports") or [],
            "openvpn": openvpn,
            "stdout": (result.stdout or "").strip(),
        }

    def set_openvpn_udp_ports(self, value: Any) -> dict[str, Any]:
        self._ensure_linux()
        if isinstance(value, (list, tuple)):
            candidates = list(value)
        else:
            candidates = str(value or "").split(",")
        public_ports: list[int] = []
        for candidate in candidates:
            try:
                public_port = int(str(candidate).strip())
            except ValueError:
                raise ApiError(400, "ports must be comma-separated numbers")
            if public_port < 1 or public_port > 65535:
                raise ApiError(400, "each port must be between 1 and 65535")
            if public_port in {22, 80, 109, 143, 443, 2082, 2083, 3128, 8080, 8443, 5666, 25000}:
                raise ApiError(400, f"port {public_port} conflicts with an existing IPTunnel service")
            if public_port not in public_ports:
                public_ports.append(public_port)
        if not public_ports:
            raise ApiError(400, "at least one OpenVPN UDP port is required")

        udp53_mode = str(self.slowdns_config().get("udp53_mode") or "slowdns")
        if udp53_mode in {"openvpn", "shared"}:
            public_ports = [53, *[port for port in public_ports if port != 53]]
        elif 53 in public_ports:
            raise ApiError(400, "port 53 currently belongs to SlowDNS; select OpenVPN-only or Shared UDP53 mode first")

        openvpn = self.config.setdefault("openvpn", {})
        previous_openvpn = copy.deepcopy(openvpn)
        previous_ports = self._configured_openvpn_udp_ports(openvpn)
        openvpn["enabled"] = True
        openvpn["udp_public_port"] = public_ports[0]
        openvpn["udp_public_ports"] = public_ports
        self.save_config()

        env = os.environ.copy()
        env["IPTUNNEL_CONFIG_PATH"] = str(self.config.get("config_path") or "/etc/iptunnel/config.json")
        env["IPTUNNEL_OPENVPN_UDP_PREVIOUS_PORTS"] = ",".join(str(port) for port in previous_ports)
        result = subprocess.run(
            ["/opt/iptunnel/transport_stack.sh", "refresh-openvpn-udp-port"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
            env=env,
        )
        if result.returncode != 0:
            self.config["openvpn"] = previous_openvpn
            self.save_config()
            rollback_env = env.copy()
            rollback_env["IPTUNNEL_OPENVPN_UDP_PREVIOUS_PORTS"] = ",".join(str(port) for port in public_ports)
            rollback = subprocess.run(
                ["/opt/iptunnel/transport_stack.sh", "refresh-openvpn-udp-port"],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=False,
                env=rollback_env,
            )
            self.refresh_config()
            message = (result.stderr or result.stdout or "OpenVPN UDP port change failed").strip()
            if rollback.returncode != 0:
                rollback_message = (rollback.stderr or rollback.stdout or "runtime rollback failed").strip()
                message = f"{message}; previous settings restored but runtime rollback failed: {rollback_message}"
            raise ApiError(400, message)
        self.refresh_config()
        openvpn_info = self.openvpn_info()
        return {
            "transport": "openvpn",
            "udp_public_port": public_ports[0],
            "udp_public_ports": public_ports,
            "udp53_mode": str(self.slowdns_config().get("udp53_mode") or "slowdns"),
            "openvpn": openvpn_info,
            "stdout": (result.stdout or "").strip(),
        }

    def set_openvpn_udp_port(self, port: Any) -> dict[str, Any]:
        return self.set_openvpn_udp_ports(port)

    def set_slowdns_mtu(self, mtu: Any) -> dict[str, Any]:
        self._ensure_linux()
        try:
            requested_mtu = int(str(mtu or "").strip())
        except ValueError:
            raise ApiError(400, "MTU must be a number")
        if requested_mtu < 128 or requested_mtu > 1500:
            raise ApiError(400, "MTU must be between 128 and 1500")

        slowdns = self.config.setdefault("slowdns", {})
        previous_mtu = slowdns.get("mtu", 1232)
        slowdns["mtu"] = requested_mtu
        self.save_config()

        env = os.environ.copy()
        env["IPTUNNEL_CONFIG_PATH"] = str(self.config.get("config_path") or "/etc/iptunnel/config.json")
        result = subprocess.run(
            ["/opt/iptunnel/transport_stack.sh", "refresh-slowdns-mtu"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
            env=env,
        )
        if result.returncode != 0:
            slowdns["mtu"] = previous_mtu
            self.save_config()
            raise ApiError(400, (result.stderr or result.stdout or "SlowDNS MTU update failed").strip())

        self.refresh_config()
        return {
            "transport": "slowdns",
            "mtu": int(self.slowdns_config().get("mtu", requested_mtu) or requested_mtu),
            "recommended": 512,
            "service_restarted": str(self.slowdns_config().get("udp53_mode") or "slowdns") != "openvpn",
            "stdout": (result.stdout or "").strip(),
        }

    def update_domains(self, body: dict[str, Any]) -> dict[str, Any]:
        self._ensure_linux()
        old_hostname = self.hostname()
        hostname = self.clean_domain(
            body.get("hostname") or body.get("a_record") or self.hostname(),
            "hostname",
        )
        tunnel_domain = self.clean_domain(
            body.get("tunnel_domain") or body.get("ns_record") or f"dns.{hostname}",
            "tunnel_domain",
        )
        public_hostname = hostname
        ns_host = hostname
        if tunnel_domain == hostname:
            raise ApiError(400, "NS record cannot be the same as the A record domain")

        self.config["hostname"] = hostname
        slowdns = self.config.setdefault("slowdns", {})
        slowdns["public_hostname"] = public_hostname
        slowdns["ns_host"] = ns_host
        slowdns["tunnel_domain"] = tunnel_domain
        hysteria = self.config.setdefault("hysteria", {})
        if hysteria.get("sni") in {"", None, old_hostname}:
            hysteria["sni"] = hostname
        self.save_config()

        env = os.environ.copy()
        env["IPTUNNEL_CONFIG_PATH"] = str(self.config.get("config_path") or "/etc/iptunnel/config.json")
        result = subprocess.run(
            ["/opt/iptunnel/transport_stack.sh", "refresh-domain"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
            env=env,
        )
        if result.returncode != 0:
            raise ApiError(400, (result.stderr or result.stdout or "domain refresh failed").strip())
        self.refresh_config()
        return {
            "hostname": hostname,
            "public_hostname": public_hostname,
            "ns_host": ns_host,
            "tunnel_domain": tunnel_domain,
            "public_ip": self.public_ip(),
            "records": [
                {"type": "A", "name": hostname, "value": self.public_ip()},
                {"type": "NS", "name": tunnel_domain, "value": hostname},
            ],
            "stdout": (result.stdout or "").strip(),
        }

    def backup_configs(self) -> dict[str, Any]:
        self._ensure_linux()
        timestamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%d-%H%M%S")
        output_path = pathlib.Path(f"/root/iptunnel-backup-{timestamp}.tar.gz")
        command = [
            "tar",
            "-czf",
            str(output_path),
            "--ignore-failed-read",
            "/etc/iptunnel",
            "/opt/iptunnel",
            "/usr/sbin/iptunnel",
            "/etc/nginx/conf.d/iptunnel-api.conf",
            "/etc/systemd/system/iptunnel-api.service",
            "/etc/systemd/system/iptunnel-vmess.service",
            "/etc/systemd/system/iptunnel-vless.service",
            "/etc/systemd/system/iptunnel-trojan.service",
            "/etc/systemd/system/iptunnel-slowdns.service",
            "/etc/systemd/system/iptunnel-slowdns-target.service",
            "/etc/systemd/system/iptunnel-edge-proxy.service",
            "/etc/systemd/system/iptunnel-fronting-proxy.service",
            "/etc/systemd/system/iptunnel-ssh-ssl.service",
            "/etc/systemd/system/hysteria-server.service",
            "/usr/local/bin/iptunnel-menu",
        ]
        if not self.dry_run:
            result = subprocess.run(
                command,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=False,
            )
            if result.returncode != 0:
                raise ApiError(500, (result.stderr or result.stdout or "backup failed").strip())
        return {
            "path": str(output_path),
            "created": not self.dry_run,
            "version": APP_VERSION,
        }

    def restore_configs(self, backup_path: str) -> dict[str, Any]:
        self._ensure_linux()
        path = pathlib.Path(backup_path)
        if not path.is_file():
            raise ApiError(404, "backup file not found")
        if not self.dry_run:
            extract = subprocess.run(
                ["tar", "-xzf", str(path), "-C", "/"],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=False,
            )
            if extract.returncode != 0:
                raise ApiError(400, (extract.stderr or extract.stdout or "restore failed").strip())
            subprocess.run(
                ["systemctl", "daemon-reload"],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=False,
            )
            subprocess.run(
                ["systemctl", "restart", "nginx"],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=False,
            )
        return {
            "path": str(path),
            "restored": not self.dry_run,
            "api_restart_required": True,
            "note": "Restart iptunnel-api manually if restored files changed the API service or code.",
        }

    def letsencrypt_status(self) -> dict[str, Any]:
        self._ensure_linux()
        domain = self.hostname().strip()
        if not domain or domain == "localhost":
            raise ApiError(400, "domain is not configured")

        live_dir = pathlib.Path(f"/etc/letsencrypt/live/{domain}")
        cert_target = pathlib.Path("/usr/sbin/iptunnel/cert/cert.crt")
        key_target = pathlib.Path("/usr/sbin/iptunnel/cert/cert.key")
        stunnel_bundle = pathlib.Path("/usr/sbin/iptunnel/cert/stunnel.pem")
        installed = cert_target.is_file() and key_target.is_file()
        status: dict[str, Any] = {
            "domain": domain,
            "installed": installed,
            "active": installed,
            "certificate_path": str(cert_target),
            "private_key_path": str(key_target),
            "stunnel_bundle_path": str(stunnel_bundle) if stunnel_bundle.exists() else "",
            "live_directory": str(live_dir) if live_dir.exists() else "",
            "issuer": "",
            "subject": "",
            "valid_from": "",
            "valid_until": "",
            "days_remaining": 0,
        }
        if not installed:
            return status

        try:
            decoded = ssl._ssl._test_decode_cert(str(cert_target))
        except Exception:
            return status

        def flatten_name(values: Any) -> str:
            pairs: list[str] = []
            for entry in values or []:
                if isinstance(entry, (tuple, list)):
                    for item in entry:
                        if isinstance(item, (tuple, list)) and len(item) >= 2:
                            pairs.append(f"{item[0]}={item[1]}")
            return ", ".join(pairs)

        def parse_cert_time(value: Any) -> str:
            text = str(value or "").strip()
            if not text:
                return ""
            try:
                parsed = dt.datetime.strptime(text, "%b %d %H:%M:%S %Y %Z")
                return parsed.replace(tzinfo=dt.timezone.utc).isoformat()
            except ValueError:
                return text

        valid_from = parse_cert_time(decoded.get("notBefore"))
        valid_until = parse_cert_time(decoded.get("notAfter"))
        days_remaining = 0
        if valid_until:
            try:
                expiry = dt.datetime.fromisoformat(valid_until)
                days_remaining = max(0, int((expiry - utc_now()).total_seconds() // 86400))
            except ValueError:
                days_remaining = 0

        status.update(
            {
                "issuer": flatten_name(decoded.get("issuer")),
                "subject": flatten_name(decoded.get("subject")),
                "valid_from": valid_from,
                "valid_until": valid_until,
                "days_remaining": days_remaining,
            }
        )
        return status

    def issue_letsencrypt_cert(self, email: str, force: bool = False) -> dict[str, Any]:
        self._ensure_linux()
        current_status = self.letsencrypt_status()
        domain = str(current_status["domain"])
        already_installed = bool(current_status.get("installed"))
        if already_installed and not force:
            current_status.update(
                {
                    "email": "",
                    "already_installed": True,
                    "reinstalled": False,
                }
            )
            return current_status
        live_dir = pathlib.Path(f"/etc/letsencrypt/live/{domain}")
        cert_target = pathlib.Path("/usr/sbin/iptunnel/cert/cert.crt")
        key_target = pathlib.Path("/usr/sbin/iptunnel/cert/cert.key")
        stunnel_bundle = pathlib.Path("/usr/sbin/iptunnel/cert/stunnel.pem")
        stunnel_config = pathlib.Path("/etc/stunnel/iptunnel-ssh.conf")
        if not self.dry_run:
            for command in (
                ["apt-get", "update", "-y"],
                ["apt-get", "install", "-y", "certbot"],
                [
                    "certbot",
                    "certonly",
                    "--webroot",
                    "-w",
                    "/var/www/html",
                    "-d",
                    domain,
                    "--non-interactive",
                    "--agree-tos",
                    "-m",
                    email,
                ],
            ):
                if command[0] == "certbot" and force:
                    command.append("--force-renewal")
                result = subprocess.run(
                    command,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                    check=False,
                )
                if result.returncode != 0:
                    raise ApiError(400, (result.stderr or result.stdout or "letsencrypt command failed").strip())
            if not live_dir.is_dir():
                raise ApiError(500, "certificate directory not found after certbot run")
            cert_target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(str(live_dir / "fullchain.pem"), str(cert_target))
            shutil.copyfile(str(live_dir / "privkey.pem"), str(key_target))
            os.chmod(cert_target, 0o644)
            os.chmod(key_target, 0o600)
            if stunnel_config.exists():
                stunnel_bundle.write_bytes(cert_target.read_bytes() + key_target.read_bytes())
                os.chmod(stunnel_bundle, 0o600)
            subprocess.run(
                ["systemctl", "restart", "nginx"],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=False,
            )
            subprocess.run(
                ["systemctl", "restart", "iptunnel-ssh-ssl"],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=False,
            )
        refreshed = self.letsencrypt_status()
        refreshed.update(
            {
                "email": email,
                "already_installed": already_installed,
                "reinstalled": already_installed and force,
            }
        )
        if self.dry_run:
            refreshed["installed"] = False
        return refreshed

    def check_updates(self) -> dict[str, Any]:
        license_url = str(self.config.get("license", {}).get("url") or "https://license.internetshub.com").rstrip("/")
        urls = [
            f"{license_url}/version.json",
            f"{license_url}/api/v2/version",
        ]
        payload: dict[str, Any] | None = None
        last_error = ""
        resolved_url = urls[0]
        headers = {
            "Accept": "application/json",
            "User-Agent": f"IPTunnel-Updater/{APP_VERSION}",
        }
        for candidate in urls:
            request = urllib.request.Request(candidate, headers=headers, method="GET")
            try:
                with urllib.request.urlopen(request, timeout=8) as response:
                    payload = json.loads(response.read().decode("utf-8"))
                resolved_url = candidate
                break
            except Exception as exc:
                last_error = str(exc)
                resolved_url = candidate

        if payload is None:
            return {
                "installed": APP_VERSION,
                "remote": "",
                "status": "unavailable",
                "notes": "",
                "error": last_error,
                "url": resolved_url,
                "installer_url": "",
                "installer_sha256": "",
            }
        remote = str(payload.get("version") or payload.get("tag") or payload.get("latest") or "")
        notes = str(payload.get("notes") or payload.get("message") or "")
        installer_url = str(payload.get("url") or payload.get("installer_url") or "").strip()
        installer_sha256 = str(payload.get("sha256") or payload.get("installer_sha256") or "").strip().lower()
        if not installer_url:
            installer_url = f"{license_url}/iptunnel-install.sh"
        if not remote:
            status = "unknown"
        else:
            comparison = compare_release_versions(remote, APP_VERSION)
            if comparison == 0:
                status = "up_to_date"
            elif comparison > 0:
                status = "update_available"
            else:
                status = "local_ahead"
        return {
            "installed": APP_VERSION,
            "remote": remote,
            "status": status,
            "notes": notes,
            "url": resolved_url,
            "installer_url": installer_url,
            "installer_sha256": installer_sha256,
        }

    @staticmethod
    def verify_update_installer(data: bytes, target_version: str, expected_sha256: str = "") -> str:
        actual_sha256 = hashlib.sha256(data).hexdigest()
        expected_sha256 = str(expected_sha256 or "").strip().lower()
        if expected_sha256:
            if not re.fullmatch(r"[0-9a-f]{64}", expected_sha256):
                raise ApiError(502, "Update manifest contains an invalid installer SHA-256")
            if not hmac.compare_digest(actual_sha256, expected_sha256):
                raise ApiError(502, "Downloaded installer SHA-256 does not match the update manifest")

        target_version = str(target_version or "").strip()
        if target_version:
            installer_text = data.decode("utf-8", errors="replace")
            required_markers = (
                f'APP_VERSION = "{target_version}"',
                f'MENU_VERSION="{target_version}"',
            )
            if not all(marker in installer_text for marker in required_markers):
                raise ApiError(502, f"Downloaded installer does not contain release {target_version}")
        return actual_sha256

    def apply_update(self) -> dict[str, Any]:
        """Download iptunnel-install.sh and re-run it in the background.
        The installer is idempotent — it preserves the existing license.id and
        server registration, reconfigures all services, and restarts the API
        itself when done. We return immediately; the install runs in the background."""
        info = self.check_updates()
        if info["status"] == "unavailable":
            raise ApiError(503, f"Cannot reach update server: {info.get('error', '')}")
        if info["status"] == "up_to_date":
            return {"status": "up_to_date", "version": APP_VERSION}
        if info["status"] == "local_ahead":
            return {
                "status": "local_ahead",
                "version": APP_VERSION,
                "remote": info.get("remote", ""),
            }

        license_url = str(self.config.get("license", {}).get("url") or "https://license.internetshub.com").rstrip("/")
        install_url = str(info.get("installer_url") or "").strip()
        if not install_url:
            install_url = f"{license_url}/iptunnel-install.sh"

        license_root = urllib.parse.urlparse(license_url)
        install_url = urllib.parse.urljoin(f"{license_url}/", install_url)
        parsed_install = urllib.parse.urlparse(install_url)
        if parsed_install.scheme not in {"http", "https"} or not parsed_install.netloc:
            raise ApiError(502, "Update manifest returned an invalid installer URL")
        if parsed_install.hostname != license_root.hostname:
            raise ApiError(502, "Update manifest installer host does not match the configured license server")
        if parsed_install.port != license_root.port:
            raise ApiError(502, "Update manifest installer port does not match the configured license server")
        tmp_script = pathlib.Path("/tmp/iptunnel-update.sh")
        installer_cache = pathlib.Path("/opt/iptunnel/updates/iptunnel-install-latest.sh")

        try:
            request = urllib.request.Request(
                install_url,
                headers={
                    "Accept": "text/plain,application/octet-stream,*/*",
                    "User-Agent": f"IPTunnel-Updater/{APP_VERSION}",
                },
                method="GET",
            )
            with urllib.request.urlopen(request, timeout=30) as r:
                data = r.read()
            if len(data) < 1024:
                raise ApiError(502, "Downloaded installer is suspiciously small — aborting")
            self.verify_update_installer(
                data,
                str(info.get("remote") or ""),
                str(info.get("installer_sha256") or ""),
            )
            tmp_script.write_bytes(data)
            tmp_script.chmod(0o755)
            if not self.dry_run:
                installer_cache.parent.mkdir(parents=True, exist_ok=True)
                installer_cache.write_bytes(data)
                installer_cache.chmod(0o755)
        except ApiError:
            raise
        except Exception as exc:
            raise ApiError(502, f"Failed to download installer: {exc}") from exc

        update_unit = ""
        status_path = pathlib.Path("/var/lib/iptunnel/update-status.json")
        if not self.dry_run:
            log_path = pathlib.Path("/var/log/iptunnel/update.log")
            log_path.parent.mkdir(parents=True, exist_ok=True)
            status_path.parent.mkdir(parents=True, exist_ok=True)
            openvpn_config = dict(self.config.get("openvpn") or {})
            slowdns_config = dict(self.config.get("slowdns") or {})
            udp53_mode = str(slowdns_config.get("udp53_mode") or "slowdns").strip().lower()
            if udp53_mode not in {"slowdns", "openvpn", "shared"}:
                udp53_mode = "slowdns"
            installer_path = installer_cache if installer_cache.exists() else tmp_script
            command = [
                "bash",
                str(installer_path),
                "--domain",
                self.hostname(),
                "--public-ip",
                self.public_ip(),
                "--api-key",
                str(self.config.get("api_key") or self.server_info().key or ""),
                "--bind",
                str(self.config.get("bind") or "127.0.0.1"),
                "--port",
                str(self.config.get("port") or 8080),
                "--name-client",
                self.server_info().name_client or "IPTunnel",
                "--status-label",
                self.server_info().status or "selfhosted",
                "--license-url",
                str((self.config.get("license") or {}).get("url") or "https://license.internetshub.com"),
                "--hmac-secret",
                str((self.config.get("license") or {}).get("hmac_secret") or ""),
                "--udp53-mode",
                udp53_mode,
            ]
            udp_public_ports = self._configured_openvpn_udp_ports(openvpn_config, active_only=False)
            if udp_public_ports:
                command.extend(["--openvpn-udp-ports", ",".join(str(port) for port in udp_public_ports)])
            if self.hysteria_enabled():
                command.extend(["--enable-hysteria"])
                hysteria = self.hysteria_config()
                if str(hysteria.get("obfs") or ""):
                    command.extend(["--hysteria-obfs", str(hysteria.get("obfs") or "")])
                if str(hysteria.get("password") or ""):
                    command.extend(["--hysteria-password", str(hysteria.get("password") or "")])
            else:
                command.extend(["--disable-hysteria"])
            if bool(openvpn_config.get("enabled", False)) or udp53_mode in {"openvpn", "shared"}:
                command.extend(["--enable-openvpn"])
            else:
                command.extend(["--disable-openvpn"])
            launcher_path = pathlib.Path(f"/tmp/iptunnel-update-{int(time.time())}.sh")
            quoted_command = " ".join(shlex.quote(arg) for arg in command)
            launcher_path.write_text(
                "\n".join(
                    [
                        "#!/usr/bin/env bash",
                        "set -euo pipefail",
                        f'exec >>"{log_path}" 2>&1',
                        f'STATUS_FILE="{status_path}"',
                        f'CURRENT_VERSION="{APP_VERSION}"',
                        f'TARGET_VERSION="{info["remote"]}"',
                        "write_status() {",
                        "  local status=\"$1\"",
                        "  local exit_code=\"${2:-}\"",
                        "  python3 - \"$STATUS_FILE\" \"$status\" \"$CURRENT_VERSION\" \"$TARGET_VERSION\" \"$exit_code\" <<'PY'",
                        "import datetime as dt, json, pathlib, sys",
                        "path = pathlib.Path(sys.argv[1])",
                        "payload = {",
                        "    'status': sys.argv[2],",
                        "    'installed': sys.argv[3],",
                        "    'target': sys.argv[4],",
                        "    'exit_code': sys.argv[5],",
                        "    'timestamp': dt.datetime.now(dt.timezone.utc).isoformat(),",
                        "}",
                        "path.write_text(json.dumps(payload), encoding='utf-8')",
                        "PY",
                        "}",
                        "write_status running 0",
                        f'echo "[{dt.datetime.now(dt.timezone.utc).isoformat()}] IPTunnel update started"',
                        f"if {quoted_command}; then",
                        "  rc=0",
                        "else",
                        "  rc=$?",
                        "fi",
                        "if [ \"$rc\" -eq 0 ]; then",
                        "  write_status success \"$rc\"",
                        "else",
                        "  write_status failed \"$rc\"",
                        "fi",
                        "exit \"$rc\"",
                        "",
                    ]
                ),
                encoding="utf-8",
            )
            launcher_path.chmod(0o755)

            systemd_run = shutil.which("systemd-run")
            if systemd_run:
                update_unit = f"iptunnel-update-{int(time.time())}"
                result = subprocess.run(
                    [
                        systemd_run,
                        "--unit",
                        update_unit,
                        "--description",
                        "IPTunnel self-update",
                        "--collect",
                        str(launcher_path),
                    ],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                    check=False,
                )
                if result.returncode != 0:
                    raise ApiError(500, (result.stderr or result.stdout or "failed to start background updater").strip())
            else:
                subprocess.Popen(
                    [str(launcher_path)],
                    stdin=subprocess.DEVNULL,
                    stdout=log_path.open("a"),
                    stderr=subprocess.STDOUT,
                    close_fds=True,
                    start_new_session=True,
                )

        return {
            "status": "updating",
            "from": APP_VERSION,
            "to": info["remote"],
            "notes": info["notes"],
            "installer_url": install_url,
            "installer_cache": str(installer_cache),
            "log": "/var/log/iptunnel/update.log",
            "update_unit": update_unit,
            "status_file": str(status_path),
        }

    def ensure_authorized(self, header_value: str | None) -> None:
        token = (header_value or "").strip()
        if token.lower().startswith("bearer "):
            token = token[7:].strip()
        if not token or not any(secrets.compare_digest(token, key) for key in self.accepted_keys()):
            raise ApiError(401, "Status Unauthorization!, Please check your [key]")

    def fetch_account(self, spec: dict[str, Any], username: str) -> sqlite3.Row | None:
        with self.connect() as conn:
            return conn.execute(
                f"SELECT * FROM {spec['table']} WHERE username = ?",
                (username,),
            ).fetchone()

    def list_accounts(self, spec: dict[str, Any]) -> list[dict[str, Any]]:
        with self.connect() as conn:
            rows = conn.execute(
                f"SELECT * FROM {spec['table']} ORDER BY username ASC"
            ).fetchall()
        return [dict(row) for row in rows]

    def list_recovery_accounts(self, spec: dict[str, Any]) -> list[dict[str, Any]]:
        rows = self.list_accounts(spec)
        return [
            row
            for row in rows
            if row.get("status_lock") == "LOCKED"
            or str(row.get("status", "")).upper() != "AKTIF"
            or int(row.get("at_banned", 0) or 0) != 0
        ]

    def build_meta(self, code: int, status: str, message: str) -> dict[str, Any]:
        return {
            "code": code,
            "status": status,
            "ip_address": self.public_ip(),
            "message": message,
        }

    def build_old_error(self, code: int, message: str) -> dict[str, Any]:
        return {
            "meta": self.build_meta(code, "error", message),
            "data": {},
        }

    def build_list_response(self, rows: list[dict[str, Any]]) -> dict[str, Any]:
        total = len(rows)
        return {
            "meta": self.build_meta(200, "success", f"Total {total}"),
            "total": total,
            "data": rows,
        }

    def _run(self, command: list[str], stdin: str | None = None) -> None:
        if self.dry_run:
            return
        subprocess.run(
            command,
            input=stdin,
            text=True,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

    def _ensure_linux(self) -> None:
        if os.name != "posix":
            raise ApiError(500, "This action requires a Linux host")

    def create_system_user(self, username: str, password: str, expires_on: str) -> None:
        if not self.config["ssh"].get("manage_system_users", True):
            return
        self._ensure_linux()
        shell = self.config["ssh"].get("shell", "/bin/false")
        user_exists = subprocess.run(
            ["id", username],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        ).returncode == 0
        if not user_exists:
            self._run(["useradd", "-M", "-s", shell, "-e", expires_on, username])
        else:
            self._run(["chage", "-E", expires_on, username])
        self._run(["chpasswd"], stdin=f"{username}:{password}\n")

    def delete_system_user(self, username: str) -> None:
        if not self.config["ssh"].get("manage_system_users", True):
            return
        self._ensure_linux()
        if self.dry_run:
            return
        subprocess.run(
            ["userdel", username],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )

    def lock_system_user(self, username: str) -> None:
        if not self.config["ssh"].get("manage_system_users", True):
            return
        self._ensure_linux()
        self._run(["passwd", "-l", username])

    def unlock_system_user(self, username: str, password: str | None = None) -> None:
        if not self.config["ssh"].get("manage_system_users", True):
            return
        self._ensure_linux()
        self._run(["passwd", "-u", username])
        if password:
            self._run(["chpasswd"], stdin=f"{username}:{password}\n")

    def change_system_password(self, username: str, password: str) -> None:
        if not self.config["ssh"].get("manage_system_users", True):
            return
        self._ensure_linux()
        self._run(["chpasswd"], stdin=f"{username}:{password}\n")

    def _xray_paths(self, protocol: str) -> dict[str, str]:
        return dict(self.config["xray"]["paths"][protocol])

    def _xray_ports(self) -> dict[str, str]:
        return dict(self.config["xray"]["ports"])

    def _xray_config_file(self, protocol: str) -> pathlib.Path:
        return pathlib.Path(self.config["xray"]["configs"][protocol])

    def _xray_service(self, protocol: str) -> str:
        return str(self.config["xray"]["services"][protocol])

    def resync_all_xray_accounts(self) -> None:
        """Rebuild every Xray JSON config from the DB.

        Called at API startup so that Xray's client lists always match the
        database — even after a reinstall wipes the JSON files or after the
        first API start on a server whose Xray services were already running.
        One file-write + one service restart per protocol (3 total), never
        more.
        """
        if self.dry_run:
            return
        now_str = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
        for spec in PROTOCOLS.values():
            if spec.get("kind") != "xray":
                continue
            protocol: str = spec["xray_protocol"]
            config_file = self._xray_config_file(protocol)
            if not config_file.exists():
                continue
            lock = self._xray_locks.get(protocol)
            if lock is None:
                continue
            try:
                with lock:
                    payload = json.loads(config_file.read_text(encoding="utf-8"))
                    # Wipe all inbound client lists so we start clean
                    for inbound in payload.get("inbounds", []):
                        s = inbound.get("settings") or {}
                        if isinstance(s.get("clients"), list):
                            s["clients"] = []
                    # Re-populate with active, non-expired accounts
                    with self.connect() as conn:
                        rows = conn.execute(
                            f"SELECT username, {spec['secret_column']} AS secret"
                            f"  FROM {spec['table']}"
                            f"  WHERE (status_lock IS NULL OR upper(status_lock) != 'LOCKED')"
                            f"    AND (date_exp IS NULL OR date_exp > ?)",
                            (now_str,),
                        ).fetchall()
                    for row in rows:
                        client = self._build_xray_client(protocol, row["username"], row["secret"] or "")
                        for inbound in payload.get("inbounds", []):
                            s = inbound.get("settings") or {}
                            if isinstance(s.get("clients"), list):
                                s["clients"].append(client)
                    config_file.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
                self._restart_xray_service(protocol)
                print(f"  Xray {protocol}: synced {len(rows)} account(s)")
            except Exception as exc:
                print(f"[warn] Xray {protocol} resync failed: {exc}", file=sys.stderr)

    def _build_xray_client(self, protocol: str, username: str, secret_value: str) -> dict[str, Any]:
        if protocol == "trojan":
            return {"password": secret_value, "email": username}
        client: dict[str, Any] = {"id": secret_value, "email": username}
        if protocol == "vmess":
            client["alterId"] = 0
        return client

    def _restart_xray_service(self, protocol: str) -> None:
        if not self.config["xray"].get("restart_services", True):
            return
        self._ensure_linux()
        if self.dry_run:
            return
        subprocess.run(
            ["systemctl", "restart", self._xray_service(protocol)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )

    def sync_xray_account(self, protocol: str, username: str, secret_value: str | None, present: bool) -> None:
        config_file = self._xray_config_file(protocol)
        default_payload = {"inbounds": [{"settings": {"clients": []}}]}
        lock = self._xray_locks.get(protocol)
        if lock is None:
            lock = threading.Lock()
            self._xray_locks[protocol] = lock
        with lock:
            if not config_file.exists() and not self.dry_run:
                config_file.parent.mkdir(parents=True, exist_ok=True)
                config_file.write_text(
                    json.dumps(default_payload, indent=2) + "\n",
                    encoding="utf-8",
                )
            payload = (
                json.loads(config_file.read_text(encoding="utf-8"))
                if config_file.exists()
                else copy.deepcopy(default_payload)
            )
            changed = False
            for inbound in payload.get("inbounds", []):
                settings = inbound.get("settings") or {}
                clients = settings.get("clients")
                if not isinstance(clients, list):
                    continue
                before = len(clients)
                clients[:] = [client for client in clients if client.get("email") != username]
                if len(clients) != before:
                    changed = True
                if present:
                    clients.append(self._build_xray_client(protocol, username, secret_value or ""))
                    changed = True
            if not changed and not present:
                return
            if not self.dry_run:
                config_file.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
        self._restart_xray_service(protocol)

    def _vmess_uri(
        self,
        username: str,
        host: str,
        port: str,
        uuid_value: str,
        network: str,
        path: str,
        tls: bool,
        alpn: str = "",
    ) -> str:
        payload = {
            "v": "2",
            "ps": username,
            "add": host,
            "port": str(port),
            "id": uuid_value,
            "aid": "0",
            "scy": "auto",
            "net": network,
            "type": "none" if network != "grpc" else "gun",
            "host": host if network in {"ws", "httpupgrade"} else "",
            "path": path,
            "tls": "tls" if tls else "",
            "sni": host if tls else "",
            "alpn": alpn if tls else "",
            "fp": "",
        }
        raw = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        return "vmess://" + base64.b64encode(raw).decode("ascii")

    def _vless_uri(
        self,
        username: str,
        host: str,
        port: str,
        uuid_value: str,
        network: str,
        path: str,
        tls: bool,
        alpn: str = "",
    ) -> str:
        query: dict[str, str] = {
            "encryption": "none",
            "security": "tls" if tls else "none",
            "type": network,
        }
        if tls and alpn:
            query["alpn"] = alpn
        if network == "grpc":
            query["serviceName"] = path
        else:
            query["host"] = host
            query["path"] = path
        return (
            f"vless://{uuid_value}@{host}:{port}?"
            f"{urllib.parse.urlencode(query, safe='/')}"
            f"#{urllib.parse.quote(username)}"
        )

    def _trojan_uri(
        self,
        username: str,
        host: str,
        port: str,
        password_value: str,
        network: str,
        path: str,
        tls: bool,
        alpn: str = "",
        tls_pin: str = "",
    ) -> str:
        query: dict[str, str] = {
            "security": "tls" if tls else "none",
            "type": network,
        }
        if tls and alpn:
            query["alpn"] = alpn
        if tls and tls_pin:
            query["pcs"] = tls_pin
        if network == "grpc":
            query["serviceName"] = path
        else:
            query["host"] = host
            query["path"] = path
        return (
            f"trojan://{password_value}@{host}:{port}?"
            f"{urllib.parse.urlencode(query, safe='/')}"
            f"#{urllib.parse.quote(username)}"
        )

    def _self_signed_certificate_pin(self) -> str:
        cert_path = pathlib.Path("/usr/sbin/iptunnel/cert/cert.crt")
        if not cert_path.is_file():
            return ""
        try:
            identity = subprocess.run(
                ["openssl", "x509", "-in", str(cert_path), "-noout", "-subject", "-issuer", "-nameopt", "RFC2253"],
                capture_output=True,
                text=True,
                check=False,
            )
            fields = [line.partition("=")[2].strip() for line in identity.stdout.splitlines() if "=" in line]
            if identity.returncode != 0 or len(fields) < 2 or fields[0] != fields[1]:
                return ""
            certificate = subprocess.run(
                ["openssl", "x509", "-in", str(cert_path), "-outform", "DER"],
                capture_output=True,
                check=False,
            )
            if certificate.returncode != 0 or not certificate.stdout:
                return ""
            return hashlib.sha256(certificate.stdout).hexdigest()
        except (OSError, subprocess.SubprocessError):
            return ""

    def build_xray_payload(self, protocol: str, username: str, secret_value: str, expires_on: str) -> dict[str, Any]:
        host = self.hostname()
        ports = self._xray_ports()
        paths = self._xray_paths(protocol)
        if protocol == "vmess":
            links = {
                "grpc": self._vmess_uri(username, host, ports["tls"], secret_value, "grpc", paths["grpc"], True, "h2"),
                "none": self._vmess_uri(username, host, ports["none"], secret_value, "ws", paths["primary"], False),
                "tls": self._vmess_uri(username, host, ports["tls"], secret_value, "ws", paths["primary"], True, "http/1.1"),
                "upntls": self._vmess_uri(username, host, ports["none"], secret_value, "httpupgrade", paths["up"], False),
                "uptls": self._vmess_uri(username, host, ports["tls"], secret_value, "httpupgrade", paths["up"], True, "http/1.1"),
            }
        elif protocol == "vless":
            links = {
                "grpc": self._vless_uri(username, host, ports["tls"], secret_value, "grpc", paths["grpc"], True, "h2"),
                "none": self._vless_uri(username, host, ports["none"], secret_value, "ws", paths["primary"], False),
                "tls": self._vless_uri(username, host, ports["tls"], secret_value, "ws", paths["primary"], True, "http/1.1"),
                "upntls": self._vless_uri(username, host, ports["none"], secret_value, "httpupgrade", paths["up"], False),
                "uptls": self._vless_uri(username, host, ports["tls"], secret_value, "httpupgrade", paths["up"], True, "http/1.1"),
            }
        else:
            trojan_tls_pin = self._self_signed_certificate_pin()
            links = {
                "grpc": self._trojan_uri(username, host, ports["tls"], secret_value, "grpc", paths["grpc"], True, "h2", trojan_tls_pin),
                "none": self._trojan_uri(username, host, ports["none"], secret_value, "ws", paths["primary"], False),
                "tls": self._trojan_uri(username, host, ports["tls"], secret_value, "ws", paths["primary"], True, "http/1.1", trojan_tls_pin),
                "upntls": self._trojan_uri(username, host, ports["none"], secret_value, "httpupgrade", paths["up"], False),
                "uptls": self._trojan_uri(username, host, ports["tls"], secret_value, "httpupgrade", paths["up"], True, "http/1.1", trojan_tls_pin),
            }
        return {
            "meta": self.build_meta(200, "success", "Account ready"),
            "data": {
                "CITY": self.config.get("city", ""),
                "ISP": self.config.get("isp", ""),
                "expired": expires_on,
                "hostname": host,
                "link": links,
                "path": {
                    "grpc": paths["grpc"],
                    "multi": paths["multi"],
                    "stn": paths["stn"],
                    "up": paths["up"],
                },
                "port": {
                    "any": ports["any"],
                    "none": ports["none"],
                    "tls": ports["tls"],
                },
                "time": utc_now().isoformat(),
                "username": username,
                "uuid": secret_value,
            },
        }

    def build_ssh_payload(self, username: str, password: str, expires_on: str) -> dict[str, Any]:
        host = self.hostname()
        ws_paths = self.ssh_ws_paths()
        ws_path = ws_paths[0]
        ws_payloads = {
            path: (
                f"GET {path} HTTP/1.1[crlf]Host: {host}[crlf]Upgrade: websocket"
                "[crlf]Connection: Upgrade[crlf][crlf]"
            )
            for path in ws_paths
        }
        ports = self.config["ssh"]["ports"]
        data = {
            "CITY": self.config.get("city", ""),
            "ISP": self.config.get("isp", ""),
            "exp": expires_on,
            "hostname": host,
            "password": password,
            "payloadws": {
                "payloadcdn": f"GET / HTTP/1.1[crlf]Host: {host}[crlf][crlf]",
                "payloadwithpath": ws_payloads[ws_path],
                "payloadrootcompat": (
                    f"GET / HTTP/1.1[crlf]Host: {host}[crlf]Upgrade: websocket"
                    "[crlf]Connection: Upgrade[crlf][crlf]"
                ),
                "path": ws_path,
                "paths": ws_paths,
                "path_payloads": ws_payloads,
                "root_compat_port": "80,443,2082",
            },
            "payloadsquid": {
                "ssh_22": (
                    f"CONNECT {host}:22 HTTP/1.1[crlf]Host: {host}[crlf]X-Online-Host: {host}"
                    "[crlf]X-Forward-Host: " + host + "[crlf]Connection: Keep-Alive[crlf][crlf]"
                ),
                "template": (
                    "CONNECT [host_port] HTTP/1.1[crlf]Host: [host][crlf]X-Online-Host: [host]"
                    "[crlf]X-Forward-Host: [host][crlf]Connection: Keep-Alive[crlf][crlf]"
                ),
            },
            "port": ports,
            "username": username,
        }
        slowdns = self.slowdns_info()
        if slowdns:
            data["slowdns"] = slowdns
        hysteria = self.hysteria_info()
        if hysteria:
            data["hysteria"] = hysteria
        openvpn = self.openvpn_info()
        if openvpn:
            data["openvpn"] = openvpn
        return {
            "meta": self.build_meta(200, "success", "Account ready"),
            "data": data,
        }

    def insert_ssh_account(
        self,
        username: str,
        password: str,
        expired_days: int,
        limit_ip: int,
        max_bw_gb: int,
        trial: bool = False,
        trial_until: dt.datetime | None = None,
    ) -> dict[str, Any]:
        if self.fetch_account(PROTOCOLS["sshvpn"], username):
            raise ApiError(409, "username already exists")
        if trial_until:
            expires_on = trial_until.date().isoformat()
            date_time = int(trial_until.timestamp())
            days = 0
        else:
            expires_on = (dt.date.today() + dt.timedelta(days=expired_days)).isoformat()
            date_time = expiry_timestamp(expires_on)
            days = expired_days
        max_bw, max_bw_hum = quota_to_storage(max_bw_gb)
        self.create_system_user(username, password, expires_on)
        with self.connect() as conn:
            conn.execute(
                """
                INSERT INTO account_sshs (
                    username, password, date_exp, date_time, days, limit_ip,
                    at_trial, at_banned, max_bw, use_bw, max_bw_hum, use_bw_hum,
                    type, protocol, status_lock, status
                ) VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?, 0, ?, '0 GB', ?, 'ALL', 'UNLOCKED', 'AKTIF')
                """,
                (
                    username,
                    password,
                    expires_on,
                    date_time,
                    days,
                    limit_ip,
                    1 if trial else 0,
                    max_bw,
                    max_bw_hum,
                    "TRIAL" if trial else "NORMAL",
                ),
            )
            conn.commit()
        return self.build_ssh_payload(username, password, expires_on)

    def insert_xray_account(
        self,
        protocol: str,
        username: str,
        secret_value: str,
        expired_days: int,
        limit_ip: int,
        max_bw_gb: int,
        trial: bool = False,
        trial_until: dt.datetime | None = None,
    ) -> dict[str, Any]:
        spec = PROTOCOLS[protocol]
        if self.fetch_account(spec, username):
            raise ApiError(409, "username already exists")
        if trial_until:
            expires_on = trial_until.date().isoformat()
            date_time = int(trial_until.timestamp())
            days = 0
        else:
            expires_on = (dt.date.today() + dt.timedelta(days=expired_days)).isoformat()
            date_time = expiry_timestamp(expires_on)
            days = expired_days
        payload = self.build_xray_payload(protocol, username, secret_value, expires_on)
        links = payload["data"]["link"]
        max_bw, max_bw_hum = quota_to_storage(max_bw_gb)
        self.sync_xray_account(protocol, username, secret_value, present=True)
        with self.connect() as conn:
            conn.execute(
                f"""
                INSERT INTO {spec['table']} (
                    username, uuid, date_exp, date_time, days, tls, ntls, grpc,
                    tcptls, tcpntls, reality, upgradetls, upgradentls, limit_ip,
                    at_trial, at_banned, max_bw, use_bw, max_bw_hum, use_bw_hum,
                    type, protocol, status_lock, status
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, '', ?, ?, ?, ?, 0, ?, 0, ?, '0 GB', ?, 'ALL', 'UNLOCKED', 'AKTIF')
                """,
                (
                    username,
                    secret_value,
                    expires_on,
                    date_time,
                    days,
                    links["tls"],
                    links["none"],
                    links["grpc"],
                    links["tls"],
                    links["none"],
                    links["uptls"],
                    links["upntls"],
                    limit_ip,
                    1 if trial else 0,
                    max_bw,
                    max_bw_hum,
                    "TRIAL" if trial else "NORMAL",
                ),
            )
            conn.commit()
        return payload

    def update_limit_ip(self, spec: dict[str, Any], limit_ip: int, username: str | None = None) -> dict[str, Any]:
        with self.connect() as conn:
            if username:
                cursor = conn.execute(
                    f"UPDATE {spec['table']} SET limit_ip = ? WHERE username = ?",
                    (limit_ip, username),
                )
                changed_user = username
            else:
                cursor = conn.execute(
                    f"UPDATE {spec['table']} SET limit_ip = ?",
                    (limit_ip,),
                )
                changed_user = "ALL"
            conn.commit()
        if cursor.rowcount == 0:
            raise ApiError(404, "account not found")
        return {
            "meta": self.build_meta(200, "success", "Limit IP updated"),
            "data": {
                "message": f"limit ip => {limit_ip}",
                "username": changed_user,
            },
        }

    def update_bandwidth(
        self,
        spec: dict[str, Any],
        kuota_gb: int,
        reset_bw: bool,
        username: str | None = None,
    ) -> dict[str, Any]:
        max_bw, max_bw_hum = quota_to_storage(kuota_gb)
        if username:
            sql = (
                f"UPDATE {spec['table']} SET max_bw = ?, max_bw_hum = ?, "
                "use_bw = CASE WHEN ? THEN 0 ELSE use_bw END, "
                "use_bw_hum = CASE WHEN ? THEN '0 GB' ELSE use_bw_hum END "
                "WHERE username = ?"
            )
            params = (max_bw, max_bw_hum, 1 if reset_bw else 0, 1 if reset_bw else 0, username)
            changed_user = username
        else:
            sql = (
                f"UPDATE {spec['table']} SET max_bw = ?, max_bw_hum = ?, "
                "use_bw = CASE WHEN ? THEN 0 ELSE use_bw END, "
                "use_bw_hum = CASE WHEN ? THEN '0 GB' ELSE use_bw_hum END"
            )
            params = (max_bw, max_bw_hum, 1 if reset_bw else 0, 1 if reset_bw else 0)
            changed_user = "ALL"
        with self.connect() as conn:
            cursor = conn.execute(sql, params)
            conn.commit()
        if cursor.rowcount == 0:
            raise ApiError(404, "account not found")
        return {
            "meta": self.build_meta(200, "success", "Bandwidth updated"),
            "data": {
                "message": f"quota => {max_bw_hum}",
                "username": changed_user,
            },
        }

    def modify_account(self, spec: dict[str, Any], username: str, new_secret: str) -> dict[str, Any]:
        row = self.fetch_account(spec, username)
        if not row:
            raise ApiError(404, "account not found")
        if spec["kind"] == "ssh":
            self.change_system_password(username, new_secret)
            with self.connect() as conn:
                conn.execute(
                    "UPDATE account_sshs SET password = ? WHERE username = ?",
                    (new_secret, username),
                )
                conn.commit()
        else:
            protocol = str(spec["xray_protocol"])
            self.sync_xray_account(protocol, username, new_secret, present=True)
            payload = self.build_xray_payload(protocol, username, new_secret, row["date_exp"])
            links = payload["data"]["link"]
            with self.connect() as conn:
                conn.execute(
                    f"""
                    UPDATE {spec['table']}
                    SET uuid = ?, tls = ?, ntls = ?, grpc = ?, tcptls = ?, tcpntls = ?,
                        upgradetls = ?, upgradentls = ?
                    WHERE username = ?
                    """,
                    (
                        new_secret,
                        links["tls"],
                        links["none"],
                        links["grpc"],
                        links["tls"],
                        links["none"],
                        links["uptls"],
                        links["upntls"],
                        username,
                    ),
                )
                conn.commit()
        return {
            "meta": self.build_meta(200, "success", "Account updated"),
            "data": {
                "pass_uuid": new_secret,
                "username": username,
            },
        }

    def renew_account(self, spec: dict[str, Any], username: str, expired_days: int, kuota_gb: int | None = None) -> dict[str, Any]:
        row = self.fetch_account(spec, username)
        if not row:
            raise ApiError(404, "account not found")
        current_exp = str(row["date_exp"])
        today = dt.date.today()
        try:
            base = dt.date.fromisoformat(current_exp)
        except ValueError:
            base = today
        if base < today:
            base = today
        new_exp = (base + dt.timedelta(days=expired_days)).isoformat()
        max_bw = row["max_bw"]
        max_bw_hum = row["max_bw_hum"]
        if kuota_gb is not None:
            max_bw, max_bw_hum = quota_to_storage(kuota_gb)
        with self.connect() as conn:
            conn.execute(
                f"UPDATE {spec['table']} SET date_exp = ?, days = ?, max_bw = ?, max_bw_hum = ? WHERE username = ?",
                (new_exp, expired_days, max_bw, max_bw_hum, username),
            )
            conn.commit()
        if spec["kind"] == "ssh":
            self.create_system_user(username, row["password"], new_exp)
        return {
            "meta": self.build_meta(200, "success", "Account renewed"),
            "data": {
                "from": current_exp,
                "quota": max_bw_hum,
                "to": new_exp,
                "username": username,
            },
        }

    def delete_account(self, spec: dict[str, Any], username: str) -> dict[str, Any]:
        row = self.fetch_account(spec, username)
        if not row:
            raise ApiError(404, "account not found")
        if spec["kind"] == "ssh":
            self.delete_system_user(username)
        else:
            self.sync_xray_account(str(spec["xray_protocol"]), username, None, present=False)
        with self.connect() as conn:
            conn.execute(
                f"DELETE FROM {spec['table']} WHERE username = ?",
                (username,),
            )
            conn.commit()
        return {
            "meta": self.build_meta(200, "success", "Account deleted"),
            "data": {"username": username},
        }

    def set_lock_state(
        self,
        spec: dict[str, Any],
        username: str,
        locked: bool,
        password_override: str | None = None,
    ) -> dict[str, Any]:
        row = self.fetch_account(spec, username)
        if not row:
            raise ApiError(404, "account not found")
        secret_value = password_override or row[spec["secret_column"]]
        if spec["kind"] == "ssh":
            if locked:
                self.lock_system_user(username)
            else:
                self.unlock_system_user(username, password_override)
        else:
            self.sync_xray_account(str(spec["xray_protocol"]), username, secret_value, present=not locked)
        new_state = "LOCKED" if locked else "UNLOCKED"
        with self.connect() as conn:
            if spec["kind"] == "ssh" and password_override:
                conn.execute(
                    "UPDATE account_sshs SET status_lock = ?, password = ? WHERE username = ?",
                    (new_state, password_override, username),
                )
            else:
                conn.execute(
                    f"UPDATE {spec['table']} SET status_lock = ? WHERE username = ?",
                    (new_state, username),
                )
            conn.commit()
        return {
            "meta": self.build_meta(200, "success", "Account updated"),
            "data": {
                "expired": row["date_exp"],
                "pass_uuid": secret_value,
                "status_lock": new_state,
                "username": username,
            },
        }


class IptunnelHandler(http.server.BaseHTTPRequestHandler):
    server: "IptunnelServer"

    def do_GET(self) -> None:
        self._dispatch("GET")

    def do_POST(self) -> None:
        self._dispatch("POST")

    def do_PATCH(self) -> None:
        self._dispatch("PATCH")

    def do_DELETE(self) -> None:
        self._dispatch("DELETE")

    def log_message(self, fmt: str, *args: Any) -> None:
        sys.stderr.write("%s - - [%s] %s\n" % (self.address_string(), self.log_date_time_string(), fmt % args))

    def _send_v2_success(self, status: int, data: dict[str, Any], meta: dict[str, Any] | None = None) -> None:
        payload = {
            "data": data,
            "meta": {
                "request_id": secrets.token_hex(8),
                "timestamp": utc_now().isoformat(),
            },
            "error": None,
        }
        if meta:
            payload["meta"].update(meta)
        self._send_json(status, payload)

    def _send_v2_error(self, status: int, code: str, message: str, details: dict[str, Any] | None = None) -> None:
        self._send_json(
            status,
            {
                "data": None,
                "meta": {
                    "request_id": secrets.token_hex(8),
                    "timestamp": utc_now().isoformat(),
                },
                "error": {
                    "code": code,
                    "message": message,
                    "details": details or {},
                },
            },
        )

    def _v2_protocol(self, route_protocol: str) -> tuple[str, dict[str, Any]]:
        key = V2_PROTOCOL_ALIASES.get(route_protocol)
        if not key:
            raise ApiError(404, "protocol not found")
        return key, PROTOCOLS[key]

    def _v2_account_row(self, spec: dict[str, Any], row: sqlite3.Row) -> dict[str, Any]:
        data = dict(row)
        secret_column = str(spec["secret_column"])
        data.pop(secret_column, None)
        return {
            "username": data.get("username", ""),
            "expires_on": data.get("date_exp", ""),
            "expires_at": data.get("date_time", 0),
            "days": int(data.get("days", 0) or 0),
            "limit_ip": int(data.get("limit_ip", 0) or 0),
            "trial": int(data.get("at_trial", 0) or 0) != 0,
            "banned": int(data.get("at_banned", 0) or 0) != 0,
            "used_bytes": int(data.get("use_bw", 0) or 0),
            "used_human": data.get("use_bw_hum", "0 GB"),
            "max_bytes": int(data.get("max_bw", 0) or 0),
            "max_human": data.get("max_bw_hum", "0 GB"),
            "type": data.get("type", ""),
            "protocol": data.get("protocol", ""),
            "locked": str(data.get("status_lock", "")).upper() == "LOCKED",
            "status_lock": data.get("status_lock", ""),
            "status": data.get("status", ""),
        }

    def _v2_current_quota_gb(self, row: sqlite3.Row) -> int:
        max_bw = int(row["max_bw"] or 0)
        if max_bw <= 0:
            return 0
        return max_bw // (1024 * 1024 * 1024)

    def _v2_update_ssh_bandwidth(self, username: str | None, kuota_gb: int, reset_bw: bool) -> None:
        max_bw, max_bw_hum = quota_to_storage(kuota_gb)
        if username:
            sql = """
                UPDATE account_sshs
                SET max_bw = ?, max_bw_hum = ?,
                    use_bw = CASE WHEN ? THEN 0 ELSE use_bw END,
                    use_bw_hum = CASE WHEN ? THEN '0 GB' ELSE use_bw_hum END
                WHERE username = ?
            """
            params = (max_bw, max_bw_hum, 1 if reset_bw else 0, 1 if reset_bw else 0, username)
        else:
            sql = """
                UPDATE account_sshs
                SET max_bw = ?, max_bw_hum = ?,
                    use_bw = CASE WHEN ? THEN 0 ELSE use_bw END,
                    use_bw_hum = CASE WHEN ? THEN '0 GB' ELSE use_bw_hum END
            """
            params = (max_bw, max_bw_hum, 1 if reset_bw else 0, 1 if reset_bw else 0)
        with self.server.state.connect() as conn:
            conn.execute(sql, params)
            conn.commit()

    def _v2_account_detail(self, route_protocol: str, spec: dict[str, Any], row: sqlite3.Row) -> dict[str, Any]:
        username = str(row["username"])
        if spec["kind"] == "ssh":
            config = self.server.state.build_ssh_payload(username, str(row["password"]), str(row["date_exp"]))["data"]
        else:
            config = self.server.state.build_xray_payload(
                str(spec["xray_protocol"]),
                username,
                str(row["uuid"]),
                str(row["date_exp"]),
            )["data"]
        return {
            "protocol": route_protocol,
            "account": self._v2_account_row(spec, row),
            "config": config,
        }

    def _handle_v2_account_patch(self, route_protocol: str, spec_key: str, spec: dict[str, Any], username: str, body: dict[str, Any]) -> dict[str, Any]:
        state = self.server.state
        row = state.fetch_account(spec, username)
        if not row:
            raise ApiError(404, "account not found")

        if "secret" in body or ("password" in body and spec["kind"] == "ssh"):
            if spec["kind"] == "ssh":
                new_secret = get_required(body, "password")
            else:
                new_secret = get_required(body, "secret", "uuidv2", "pass_uuid")
            state.modify_account(spec, username, new_secret)
            row = state.fetch_account(spec, username)
            if not row:
                raise ApiError(404, "account not found")

        if "limit_ip" in body:
            state.update_limit_ip(spec, int(body["limit_ip"]), username)
            row = state.fetch_account(spec, username)
            if not row:
                raise ApiError(404, "account not found")

        expires_in_days = get_optional_int(body, "expires_in_days", "days", "expired", default=None)
        quota_gb = get_optional_int(body, "quota_gb", "kuota", "quota", default=None)
        reset_bw = parse_reset_flag(get_optional(body, "reset_bandwidth", "reset_bw", default="false"))

        if expires_in_days is not None:
            quota_for_renew = quota_gb if spec["kind"] == "xray" else None
            state.renew_account(spec, username, expires_in_days, quota_for_renew)
            if spec["kind"] == "ssh" and quota_gb is not None:
                self._v2_update_ssh_bandwidth(username, quota_gb, reset_bw)
            row = state.fetch_account(spec, username)
            if not row:
                raise ApiError(404, "account not found")
        elif quota_gb is not None or reset_bw:
            if spec["kind"] == "xray":
                effective_quota = quota_gb if quota_gb is not None else self._v2_current_quota_gb(row)
                state.update_bandwidth(spec, effective_quota, reset_bw, username)
            else:
                effective_quota = quota_gb if quota_gb is not None else self._v2_current_quota_gb(row)
                self._v2_update_ssh_bandwidth(username, effective_quota, reset_bw)
            row = state.fetch_account(spec, username)
            if not row:
                raise ApiError(404, "account not found")

        if "locked" in body:
            locked = parse_reset_flag(body["locked"])
            password_override = get_optional(body, "unlock_password", "password")
            if spec["kind"] != "ssh":
                password_override = None
            state.set_lock_state(spec, username, locked, password_override)
            row = state.fetch_account(spec, username)
            if not row:
                raise ApiError(404, "account not found")

        return self._v2_account_detail(route_protocol, spec, row)

    def _dispatch(self, method: str) -> None:
        is_v2_route = False
        try:
            self.server.state.refresh_config()
            parsed = urllib.parse.urlparse(self.path)
            route = parsed.path
            is_v2_route = route.startswith("/api/v2")
            if route == "/healthz":
                self._send_json(200, {"status": "ok"})
                return
            if route == "/api/v2/healthz":
                self._send_v2_success(200, {"status": "ok", "version": "2"})
                return
            if route == "/hysteria-uri" and method == "GET":
                info = self.server.state.hysteria_info()
                if info and info.get("uri"):
                    self._send_response(200, "text/plain", info["uri"])
                else:
                    self._send_response(404, "text/plain", "Hysteria not enabled")
                return
            # ── Session-token endpoints (public — app calls before SSH) ──
            if route in {"/session-token", "/api/v2/auth/session-token"} and method == "POST":
                state = self.server.state
                if not state.allow_session_issue(self.client_address[0]):
                    if is_v2_route:
                        self._send_v2_error(429, "rate_limited", "Too many session token requests.")
                    else:
                        self._send_json(429, {"error": "too many session token requests"})
                    return
                lic = state.config.get("license", {})
                if not lic.get("enabled") or not lic.get("hmac_secret"):
                    # HMAC not configured — issue token freely
                    token, ttl = state.issue_session_token()
                    if is_v2_route:
                        self._send_v2_success(200, {"token": token, "ttl": ttl})
                    else:
                        self._send_json(200, {"token": token, "ttl": ttl})
                    return
                # Verify HMAC proof from the app
                body = self._read_body()
                hmac_proof = body.get("proof", "")
                if not state.verify_hmac_password(hmac_proof):
                    if is_v2_route:
                        self._send_v2_error(403, "invalid_proof", "Invalid proof.")
                    else:
                        self._send_json(403, {"error": "invalid proof"})
                    return
                token, ttl = state.issue_session_token()
                if is_v2_route:
                    self._send_v2_success(200, {"token": token, "ttl": ttl})
                else:
                    self._send_json(200, {"token": token, "ttl": ttl})
                return
            if route in {"/verify-session", "/api/v2/auth/session-token/verify"} and method == "POST":
                # Called by PAM script (localhost only)
                if self.client_address[0] not in {"127.0.0.1", "::1"}:
                    if is_v2_route:
                        self._send_v2_error(403, "forbidden", "Localhost access required.")
                    else:
                        self._send_json(403, {"status": "denied"})
                    return
                body = self._read_body()
                token = body.get("token", "")
                if self.server.state.verify_session_token(token):
                    if is_v2_route:
                        self._send_v2_success(200, {"status": "ok"})
                    else:
                        self._send_json(200, {"status": "ok"})
                else:
                    if is_v2_route:
                        self._send_v2_error(403, "denied", "Session token denied.")
                    else:
                        self._send_json(403, {"status": "denied"})
                return
            self.server.state.ensure_authorized(self.headers.get("Authorization"))
            body = self._read_body() if method in {"POST", "PATCH"} else {}
            if is_v2_route:
                status, response, meta = self._handle_v2_route(method, route, body)
                self._send_v2_success(status, response, meta)
            else:
                response = self._handle_route(method, route, body)
                self._send_json(200, response)
        except ApiError as exc:
            if is_v2_route:
                code = "validation_error" if exc.status in {400, 409, 422} else "api_error"
                if exc.status == 401:
                    code = "unauthorized"
                elif exc.status == 403:
                    code = "forbidden"
                elif exc.status == 404:
                    code = "not_found"
                elif exc.status == 429:
                    code = "rate_limited"
                self._send_v2_error(exc.status, code, exc.message)
            else:
                self._send_json(exc.status, self.server.state.build_old_error(exc.status, exc.message))
        except Exception:
            traceback.print_exc()
            if is_v2_route:
                self._send_v2_error(500, "internal_error", "Internal server error")
            else:
                self._send_json(500, self.server.state.build_old_error(500, "Internal server error"))

    def _handle_patch_route(self, route: str, body: dict[str, Any]) -> dict[str, Any]:
        state = self.server.state
        for spec in PROTOCOLS.values():
            match = spec["renew_pattern"].fullmatch(route)
            if match:
                username = safe_username(match.group("username"))
                expired = int(match.group("expired"))
                kuota = None
                if spec["kind"] == "xray" and body:
                    kuota = get_optional_int(body, "kuota", "quota", default=None)
                return state.renew_account(spec, username, expired, kuota)
            match = spec["lock_pattern"].fullmatch(route)
            if match:
                return state.set_lock_state(spec, safe_username(match.group("username")), True)
            match = spec["unlock_pattern"].fullmatch(route)
            if match:
                password = match.groupdict().get("password")
                return state.set_lock_state(spec, safe_username(match.group("username")), False, password)
        raise ApiError(404, "route not found")

    def _handle_v2_route(self, method: str, route: str, body: dict[str, Any]) -> tuple[int, dict[str, Any], dict[str, Any] | None]:
        state = self.server.state

        if route.startswith("/api/v2/vps/device-credentials"):
            # This boundary accepts only the private control-plane key, never a
            # legacy database credential or a public session token.
            key = str(state.config.get("api_key") or "")
            supplied = self.headers.get("Authorization", "")
            if supplied.startswith("Bearer "):
                supplied = supplied[7:]
            if len(key) < 32 or not secrets.compare_digest(key.encode(), supplied.encode()):
                raise ApiError(401, "provisioning_control_plane_key_required")
            if state.dry_run:
                raise ApiError(503, "provisioning_unavailable_in_dry_run")
            from device_credentials import CredentialStore, ProvisioningError
            try:
                if route == "/api/v2/vps/device-credentials" and method == "POST" and body.get("protocol") == "ssh":
                    from device_ssh import SshCredentialStore
                    return 200, SshCredentialStore(state.config).provision(body), None
                if route == "/api/v2/vps/device-credentials" and method == "POST" and body.get('protocol') in ('vmess','vless','trojan'):
                    from device_xray import XrayDeviceStore
                    return 200, XrayDeviceStore(state.config).provision(body), None
                store = CredentialStore(state.config)
                if route == "/api/v2/vps/device-credentials" and method == "POST":
                    if state.config.get('provisioning', {}).get('openvpn_device_certificates') is True:
                        from device_certificates import CertificateStore
                        return 200, CertificateStore(state.config).provision(body), None
                    return 200, store.provision(body), None
                if route == "/api/v2/vps/device-credentials" and method == "GET":
                    return 200, store.status(), None
                match = re.fullmatch(r"/api/v2/vps/device-credentials/([0-9a-f]{32})/suspend", route)
                if match and method == "POST":
                    if body:
                        raise ApiError(422, "suspend_body_must_be_empty")
                    return 202, store.suspend(match.group(1)), None
            except ProvisioningError as exc:
                raise ApiError(exc.status, exc.message) from None
            raise ApiError(404, "route not found")

        if route == "/api/v2/vps/runtime" and method == "GET":
            return 200, state.runtime_summary(), None

        if route == "/api/v2/vps/domains" and method == "PATCH":
            result = state.update_domains(body)
            return 200, result, {"message": "Domain settings updated"}

        if route == "/api/v2/vps/services" and method == "GET":
            return 200, {"services": state.service_summary()}, None

        if route == "/api/v2/vps/bandwidth" and method == "GET":
            return 200, state.bandwidth_summary(), None

        if route == "/api/v2/vps/updates" and method == "GET":
            return 200, state.check_updates(), None

        if route == "/api/v2/vps/updates" and method == "POST":
            return 200, state.apply_update(), None

        if route == "/api/v2/vps/backup" and method == "POST":
            return 201, state.backup_configs(), {"message": "Backup created"}

        if route == "/api/v2/vps/restore" and method == "POST":
            backup_path = get_required(body, "path")
            return 200, state.restore_configs(backup_path), {"message": "Backup restored"}

        if route == "/api/v2/vps/certificates/letsencrypt" and method == "GET":
            return 200, state.letsencrypt_status(), None

        if route == "/api/v2/vps/certificates/letsencrypt" and method == "POST":
            email = get_required(body, "email")
            force = parse_reset_flag(get_optional(body, "force", "reinstall", "renew", default="false"))
            result = state.issue_letsencrypt_cert(email, force=force)
            if result.get("already_installed") and not result.get("reinstalled"):
                message = "Let's Encrypt certificate is already installed"
            elif result.get("reinstalled"):
                message = "Let's Encrypt certificate reinstalled"
            else:
                message = "Let's Encrypt certificate installed"
            return 200, result, {"message": message}

        udp53_mode_match = re.fullmatch(r"^/api/v2/vps/transports/udp53-mode/(?P<mode>[a-z0-9_-]+)$", route)
        if udp53_mode_match and method == "POST":
            mode = udp53_mode_match.group("mode")
            result = state.set_udp53_mode(mode)
            return 200, result, {"message": "UDP53 mode updated"}

        if route == "/api/v2/vps/transports/openvpn/udp-port" and method == "PATCH":
            result = state.set_openvpn_udp_ports(body.get("ports", body.get("port")))
            return 200, result, {"message": "OpenVPN UDP ports updated"}

        if route == "/api/v2/vps/transports/slowdns/mtu" and method == "PATCH":
            result = state.set_slowdns_mtu(body.get("mtu"))
            return 200, result, {"message": "SlowDNS MTU updated"}

        transport_match = re.fullmatch(r"^/api/v2/vps/transports/(?P<transport>[a-z0-9_-]+)/(?P<action>enable|disable)$", route)
        if transport_match and method == "POST":
            transport = transport_match.group("transport")
            enable = transport_match.group("action") == "enable"
            result = state.transport_action(transport, enable)
            return 200, result, None

        recovery_match = re.fullmatch(r"^/api/v2/vps/accounts/(?P<protocol>ssh|vmess|vless|trojan)/recovery$", route)
        if recovery_match:
            route_protocol = recovery_match.group("protocol")
            key, spec = self._v2_protocol(route_protocol)
            if method == "GET":
                rows = state.list_recovery_accounts(spec)
                return 200, {"protocol": route_protocol, "accounts": [self._v2_account_row(spec, row) for row in rows]}, None
            if method == "POST":
                payload = self._create_account(key, body, trial=False, recovery=True)
                return 201, {"protocol": route_protocol, "config": payload["data"]}, {"message": payload["meta"]["message"]}

        trial_match = re.fullmatch(r"^/api/v2/vps/accounts/(?P<protocol>ssh|vmess|vless|trojan)/trials$", route)
        if trial_match and method == "POST":
            route_protocol = trial_match.group("protocol")
            key, _spec = self._v2_protocol(route_protocol)
            payload = self._create_account(key, body, trial=True, recovery=False)
            return 201, {"protocol": route_protocol, "config": payload["data"]}, {"message": payload["meta"]["message"]}

        collection_match = re.fullmatch(r"^/api/v2/vps/accounts/(?P<protocol>ssh|vmess|vless|trojan)$", route)
        if collection_match:
            route_protocol = collection_match.group("protocol")
            key, spec = self._v2_protocol(route_protocol)
            if method == "GET":
                rows = state.list_accounts(spec)
                return 200, {"protocol": route_protocol, "accounts": [self._v2_account_row(spec, row) for row in rows]}, None
            if method == "POST":
                payload = self._create_account(key, body, trial=False, recovery=False)
                return 201, {"protocol": route_protocol, "config": payload["data"]}, {"message": payload["meta"]["message"]}
            if method == "PATCH":
                if "limit_ip" in body:
                    result = state.update_limit_ip(spec, int(body["limit_ip"]), None)
                    return 200, {"protocol": route_protocol, "scope": "all", "result": result["data"]}, {"message": result["meta"]["message"]}
                quota_gb = get_optional_int(body, "quota_gb", "kuota", "quota", default=None)
                reset_bw = parse_reset_flag(get_optional(body, "reset_bandwidth", "reset_bw", default="false"))
                if quota_gb is not None or reset_bw:
                    if spec["kind"] == "xray":
                        if quota_gb is None:
                            raise ApiError(400, "quota_gb is required for collection bandwidth updates")
                        result = state.update_bandwidth(spec, quota_gb, reset_bw, None)
                        return 200, {"protocol": route_protocol, "scope": "all", "result": result["data"]}, {"message": result["meta"]["message"]}
                    if quota_gb is None:
                        raise ApiError(400, "quota_gb is required for collection bandwidth updates")
                    self._v2_update_ssh_bandwidth(None, quota_gb, reset_bw)
                    return 200, {
                        "protocol": route_protocol,
                        "scope": "all",
                        "result": {
                            "message": f"quota => {quota_to_storage(quota_gb)[1]}",
                            "username": "ALL",
                        },
                    }, {"message": "Bandwidth updated"}
                raise ApiError(400, "no supported collection update fields provided")

        item_match = re.fullmatch(r"^/api/v2/vps/accounts/(?P<protocol>ssh|vmess|vless|trojan)/(?P<username>[^/]+)$", route)
        if item_match:
            route_protocol = item_match.group("protocol")
            username = safe_username(item_match.group("username"))
            key, spec = self._v2_protocol(route_protocol)
            row = state.fetch_account(spec, username)
            if not row:
                raise ApiError(404, "account not found")
            if method == "GET":
                return 200, self._v2_account_detail(route_protocol, spec, row), None
            if method == "PATCH":
                detail = self._handle_v2_account_patch(route_protocol, key, spec, username, body)
                return 200, detail, None
            if method == "DELETE":
                state.delete_account(spec, username)
                return 200, {"protocol": route_protocol, "deleted": True, "username": username}, None

        raise ApiError(404, "route not found")

    def _handle_route(self, method: str, route: str, body: dict[str, Any]) -> dict[str, Any]:
        state = self.server.state
        if method == "GET":
            for spec in PROTOCOLS.values():
                if route == spec["list_route"]:
                    return state.build_list_response(state.list_accounts(spec))
                if route == spec["list_recovery_route"]:
                    return state.build_list_response(state.list_recovery_accounts(spec))
                match = spec["check_pattern"].fullmatch(route)
                if match:
                    username = safe_username(match.group("username"))
                    row = state.fetch_account(spec, username)
                    if not row:
                        raise ApiError(404, "account not found")
                    if spec["kind"] == "ssh":
                        return state.build_ssh_payload(username, row["password"], row["date_exp"])
                    return state.build_xray_payload(str(spec["xray_protocol"]), username, row["uuid"], row["date_exp"])

        if method == "POST":
            for key, spec in PROTOCOLS.items():
                if route == spec["create_route"]:
                    return self._create_account(key, body, trial=False, recovery=False)
                if route == spec["trial_route"]:
                    return self._create_account(key, body, trial=True, recovery=False)
                if route == spec["recovery_route"]:
                    return self._create_account(key, body, trial=False, recovery=True)
                if route == spec["modify_route"]:
                    username = safe_username(get_required(body, "username"))
                    new_secret = get_required(body, "pass_uuid", "password", "uuidv2")
                    return state.modify_account(spec, username, new_secret)
                if route == spec["limit_ip_route"]:
                    username = safe_username(get_required(body, "username"))
                    limit_ip = get_int(body, "limitip", "limit_ip")
                    return state.update_limit_ip(spec, limit_ip, username)
                if route == spec["limit_ip_all_route"]:
                    limit_ip = get_int(body, "limitip", "limit_ip")
                    return state.update_limit_ip(spec, limit_ip, None)
                if spec["kind"] == "xray" and route == spec["limit_bw_route"]:
                    username = safe_username(get_required(body, "username"))
                    kuota = get_int(body, "kuota", "quota")
                    return state.update_bandwidth(spec, kuota, parse_reset_flag(get_optional(body, "reset_bw", default="false")), username)
                if spec["kind"] == "xray" and route == spec["limit_bw_all_route"]:
                    kuota = get_int(body, "kuota", "quota")
                    return state.update_bandwidth(spec, kuota, parse_reset_flag(get_optional(body, "reset_bw", default="false")), None)
            return self._handle_patch_route(route, body)

        if method == "PATCH":
            return self._handle_patch_route(route, body)

        if method == "DELETE":
            for spec in PROTOCOLS.values():
                match = spec["delete_pattern"].fullmatch(route)
                if match:
                    return state.delete_account(spec, safe_username(match.group("username")))

        raise ApiError(404, "route not found")

    def _create_account(self, key: str, body: dict[str, Any], trial: bool, recovery: bool) -> dict[str, Any]:
        state = self.server.state
        spec = PROTOCOLS[key]
        if trial:
            duration = parse_duration(get_required(body, "timelimit", "duration"))
            trial_until = utc_now() + duration
            username = random_username("trial")
            limit_ip = 1
            kuota = 0
            expired_days = 0
        else:
            trial_until = None
            username = safe_username(get_required(body, "username"))
            limit_ip = get_int(body, "limitip", "limit_ip")
            expired_days = get_int(body, "expired", "days", "expires_in_days")
            kuota = get_optional_int(body, "kuota", "quota", "quota_gb", default=0) or 0
        if spec["kind"] == "ssh":
            password = get_optional(body, "password", "pass_uuid")
            if trial and not password:
                password = random_password()
            if recovery and not password:
                raise ApiError(400, "password is required for recovery")
            if not password:
                raise ApiError(400, "password is required")
            return state.insert_ssh_account(username, password, expired_days, limit_ip, kuota, trial=trial, trial_until=trial_until)
        secret_value = get_optional(body, "uuidv2", "pass_uuid", "secret")
        if trial and not secret_value:
            secret_value = str(uuid.uuid4())
        if recovery and not secret_value:
            raise ApiError(400, "uuidv2, pass_uuid, or secret is required for recovery")
        if not secret_value:
            secret_value = str(uuid.uuid4())
        return state.insert_xray_account(key, username, secret_value, expired_days, limit_ip, kuota, trial=trial, trial_until=trial_until)

    def _read_body(self) -> dict[str, Any]:
        raw_length = self.headers.get("Content-Length")
        try:
            length = int(raw_length or 0)
        except ValueError as exc:
            raise ApiError(400, "invalid Content-Length header") from exc
        if length < 0:
            raise ApiError(400, "invalid Content-Length header")
        if length > MAX_BODY_BYTES:
            raise ApiError(413, "request body too large")
        if length <= 0:
            return {}
        raw = self.rfile.read(length).decode("utf-8", "replace")
        content_type = (self.headers.get("Content-Type") or "").lower()
        if "application/json" in content_type or raw.lstrip().startswith("{"):
            try:
                return json.loads(raw)
            except json.JSONDecodeError as exc:
                raise ApiError(400, f"invalid json body: {exc.msg}") from exc
        parsed = urllib.parse.parse_qs(raw, keep_blank_values=True)
        return {key: values[-1] if values else "" for key, values in parsed.items()}

    def _send_json(self, status: int, payload: dict[str, Any]) -> None:
        data = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        if self.path.startswith("/api/v2/vps/device-credentials"):
            self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def _send_response(self, status: int, content_type: str, body: str) -> None:
        data = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


class IptunnelServer(http.server.ThreadingHTTPServer):
    def __init__(self, server_address: tuple[str, int], handler_cls: type[IptunnelHandler], state: IptunnelState) -> None:
        super().__init__(server_address, handler_cls)
        self.state = state


# ── License check-in background thread ───────────────────────
def _license_checkin_loop(config: dict[str, Any]) -> None:
    """Periodically check in with license.internetshub.com."""
    lic = config.get("license", {})
    url = str(lic.get("url", "")).rstrip("/")
    interval = int(lic.get("checkin_interval", 86400) or 86400)
    id_path = pathlib.Path(lic.get("server_id_path", "/etc/iptunnel/license.id"))
    bearer_token = str(lic.get("master_token", "") or "").strip()

    if not url:
        return  # License not configured — run freely

    # Load server_id from disk (written during install)
    server_id = ""
    if id_path.is_file():
        server_id = id_path.read_text(encoding="utf-8").strip()

    if not server_id:
        # License URL is set but no server_id — installer was run without
        # a valid token, or someone copied the script. Give a 24-hour grace
        # period, then shut down.
        print("[license] No server_id — unregistered server. 24-hour grace period starts now.")
        time.sleep(86400)
        print("[license] Grace period expired — unregistered server shutting down.")
        os._exit(1)

    consecutive_failures = 0
    while True:
        time.sleep(interval)
        try:
            headers = {"Content-Type": "application/json"}
            if bearer_token:
                headers["Authorization"] = f"Bearer {bearer_token}"
            v2_req = urllib.request.Request(
                f"{url}/api/v2/servers/{urllib.parse.quote(server_id)}/check-in",
                data=b"{}",
                headers=headers,
                method="POST",
            )
            try:
                resp = urllib.request.urlopen(v2_req, timeout=15)
                body = json.loads(resp.read())
                data = body.get("data", {}) if isinstance(body, dict) else {}
            except urllib.error.HTTPError as exc:
                if exc.code != 404:
                    raise
                payload = json.dumps({"server_id": server_id}).encode("utf-8")
                legacy_req = urllib.request.Request(
                    f"{url}/checkin",
                    data=payload,
                    headers=headers,
                    method="POST",
                )
                resp = urllib.request.urlopen(legacy_req, timeout=15)
                body = json.loads(resp.read())
                data = body if isinstance(body, dict) else {}

            if data.get("status") == "revoked":
                print("[license] Server has been REVOKED — shutting down API")
                os._exit(1)
            consecutive_failures = 0
            print(f"[license] Check-in OK ({dt.datetime.now().isoformat()})")
        except Exception as exc:
            consecutive_failures += 1
            print(f"[license] Check-in failed ({consecutive_failures}): {exc}")
            if consecutive_failures >= 7:
                print("[license] 7 consecutive failures — shutting down API")
                os._exit(1)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Vendor-free replacement for the old IPTunnel account API.")
    parser.add_argument(
        "--config",
        default=os.getenv("IPTUNNEL_API_CONFIG", ""),
        help="Path to a JSON config file.",
    )
    parser.add_argument("--bind", default="", help="Override bind host.")
    parser.add_argument("--port", type=int, default=0, help="Override listen port.")
    parser.add_argument("--dry-run", action="store_true", help="Skip touching Linux users and Xray files.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    config_path = pathlib.Path(args.config) if args.config else None
    config = load_config(config_path)
    if config_path:
        config["config_path"] = str(config_path)
    if args.bind:
        config["bind"] = args.bind
    if args.port:
        config["port"] = args.port
    state = IptunnelState(config=config, dry_run=args.dry_run)
    state.resync_all_xray_accounts()
    server = IptunnelServer((config["bind"], int(config["port"])), IptunnelHandler, state)

    # Start license check-in if configured
    lic = config.get("license", {})
    if lic.get("enabled") and lic.get("url"):
        t = threading.Thread(target=_license_checkin_loop, args=(config,), daemon=True)
        t.start()
        print(f"  License check-in enabled → {lic['url']}")

    print(f"IPTunnel API listening on http://{config['bind']}:{config['port']}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
PYCODE
chmod 755 /opt/iptunnel/iptunnel_api.py

cat >/opt/iptunnel/device_credentials.py <<'DEVICE_CREDENTIALS'
"""Managed OpenVPN credentials and durable authenticated-session admission.

No OS accounts, shared-password fallback, IP-based device guesses, or Xray reloads.
The local management monitor is the only writer of session lifecycle evidence.
"""
from __future__ import annotations

import contextlib
import hashlib
import json
import os
import pathlib
import re
import secrets
import sqlite3
import time


class ProvisioningError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status
        self.message = message


SCHEMA = """
CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS credentials (
 credential_id TEXT PRIMARY KEY, owner_id TEXT NOT NULL, protocol TEXT NOT NULL,
 version INTEGER NOT NULL, username TEXT NOT NULL UNIQUE, password TEXT NOT NULL,
 expires_at INTEGER NOT NULL, state TEXT NOT NULL, reason TEXT,
 excess_since REAL, UNIQUE(owner_id, protocol)
);
CREATE TABLE IF NOT EXISTS requests (
 request_id TEXT PRIMARY KEY, fingerprint TEXT NOT NULL,
 credential_id TEXT NOT NULL, version INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS monitors (
 instance TEXT PRIMARY KEY, heartbeat REAL NOT NULL, ready INTEGER NOT NULL,
 config_hash TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS sessions (
 instance TEXT NOT NULL, cid TEXT NOT NULL, credential_id TEXT NOT NULL,
 version INTEGER NOT NULL, state TEXT NOT NULL, created_at REAL NOT NULL,
 PRIMARY KEY(instance, cid)
);
CREATE INDEX IF NOT EXISTS sessions_credential ON sessions(credential_id);
"""


def configuration(config):
    p = config.get("provisioning", {})
    if p.get("enabled") is not True:
        raise ProvisioningError(503, "provisioning_disabled")
    server_id = p.get("server_id", "")
    if not isinstance(server_id, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,127}", server_id):
        raise ProvisioningError(503, "provisioning_server_id_required")
    sockets = p.get("openvpn_management", {})
    if (not isinstance(sockets, dict) or not sockets or len(sockets) > 8
            or any(k not in {"tcp", "udp"}
                   or not isinstance(v, str) or not v.startswith("/run/iptunnel-provisioning/")
                   or ".." in v.split("/") for k, v in sockets.items())
            or len(set(sockets.values())) != len(sockets)):
        raise ProvisioningError(503, "invalid_openvpn_management_configuration")
    if config.get("openvpn", {}).get("enabled") is not True:
        raise ProvisioningError(503, "openvpn_disabled")
    grace = p.get("reconnect_grace_seconds", 30)
    days = p.get("credential_ttl_days", 30)
    if (type(grace) is not int or not 5 <= grace <= 120
            or type(days) is not int or not 1 <= days <= 365):
        raise ProvisioningError(503, "invalid_provisioning_limits")
    return {"server_id": server_id, "openvpn_management": sockets,
            "openvpn_device_certificates": p.get("openvpn_device_certificates") is True,
            "client_ca_certificate": p.get("client_ca_certificate", ""),
            "reconnect_grace_seconds": grace, "credential_ttl_days": days}


class CredentialStore:
    def __init__(self, config, clock=time.time):
        self.settings = configuration(config)
        self.require_certificate = config.get('provisioning', {}).get('openvpn_device_certificates') is True
        self.clock = clock
        self.config_hash = hashlib.sha256(json.dumps(self.settings, sort_keys=True).encode()).hexdigest()
        self.path = pathlib.Path(config.get("provisioning", {}).get(
            "db_path", "/var/lib/iptunnel-provisioning/credentials.sqlite3"))
        self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        if self.path.is_symlink() or self.path.parent.is_symlink():
            raise ProvisioningError(503, "unsafe_provisioning_database_path")
        if os.name == "posix":
            st = self.path.parent.stat()
            if st.st_uid != os.geteuid() or st.st_mode & 0o077:
                raise ProvisioningError(503, "provisioning_directory_must_be_private")
        fd = os.open(self.path, os.O_CREAT | os.O_RDWR | getattr(os, "O_NOFOLLOW", 0), 0o600)
        os.close(fd)
        if os.name == "posix":
            st = self.path.stat()
            if st.st_uid != os.geteuid() or st.st_mode & 0o077:
                raise ProvisioningError(503, "provisioning_database_must_be_private")
        with self.transaction() as db:
            # execute separately: executescript implicitly commits an open transaction.
            for statement in SCHEMA.split(";"):
                if statement.strip():
                    db.execute(statement)
            row = db.execute("SELECT value FROM metadata WHERE key='server_id'").fetchone()
            if row and row[0] != self.settings["server_id"]:
                raise ProvisioningError(503, "provisioning_server_id_mismatch")
            db.execute("INSERT OR IGNORE INTO metadata VALUES ('server_id', ?)",
                       (self.settings["server_id"],))

    @contextlib.contextmanager
    def transaction(self):
        db = sqlite3.connect(str(self.path), timeout=10, isolation_level=None)
        db.row_factory = sqlite3.Row
        try:
            db.execute("PRAGMA synchronous=FULL")
            db.execute("BEGIN IMMEDIATE")
            yield db
            db.commit()
        except BaseException:
            db.rollback()
            raise
        finally:
            db.close()

    def ready(self, db):
        rows = {r["instance"]: r for r in db.execute("SELECT * FROM monitors")}
        now = self.clock()
        return all(k in rows and rows[k]["ready"] and
                   0 <= now - rows[k]["heartbeat"] <= 10 and
                   rows[k]["config_hash"] == self.config_hash
                   for k in self.settings["openvpn_management"])

    def require_ready(self, db):
        if not self.ready(db):
            raise ProvisioningError(503, "provisioning_monitor_not_ready")

    @staticmethod
    def public(row):
        return {k: row[k] for k in ("credential_id", "version", "username", "expires_at", "state")}

    def provision(self, body):
        if not isinstance(body, dict) or set(body) != {"owner_id", "protocol", "request_id", "recover"}:
            raise ProvisioningError(422, "invalid_provisioning_body")
        owner, protocol, request, recover = (body[k] for k in ("owner_id", "protocol", "request_id", "recover"))
        if (not isinstance(owner, str) or not re.fullmatch(r"[0-9a-f]{64}", owner)
                or not isinstance(request, str) or not re.fullmatch(r"[0-9a-f]{32}", request)
                or type(recover) is not bool or not isinstance(protocol, str)):
            raise ProvisioningError(422, "invalid_provisioning_body")
        if protocol not in {"ssh", "vmess", "vless", "trojan", "openvpn"}:
            raise ProvisioningError(422, "invalid_protocol")
        if protocol != "openvpn":
            raise ProvisioningError(422, "unsupported_protocol_session_enforcement")
        fingerprint = hashlib.sha256(json.dumps(body, sort_keys=True).encode()).hexdigest()
        with self.transaction() as db:
            self.require_ready(db)
            previous = db.execute("SELECT * FROM requests WHERE request_id=?", (request,)).fetchone()
            if previous and previous["fingerprint"] != fingerprint:
                raise ProvisioningError(409, "idempotency_key_conflict")
            row = db.execute("SELECT * FROM credentials WHERE owner_id=? AND protocol=?", (owner, protocol)).fetchone()
            if previous:
                if not row or row["version"] != previous["version"]:
                    raise ProvisioningError(409, "idempotency_version_superseded")
            elif not row:
                if recover:
                    raise ProvisioningError(404, "credential_not_found")
                cid = secrets.token_hex(16)
                db.execute("INSERT INTO credentials VALUES (?,?,?,?,?,?,?,?,NULL,NULL)",
                           (cid, owner, protocol, 1, "dp_" + secrets.token_hex(12),
                            secrets.token_urlsafe(32), int(self.clock()) + self.settings["credential_ttl_days"] * 86400,
                            "active"))
                row = db.execute("SELECT * FROM credentials WHERE credential_id=?", (cid,)).fetchone()
            expired = row["expires_at"] <= self.clock()
            if expired and not (recover and not previous):
                raise ProvisioningError(410, "credential_expired")
            if (expired or row["state"] == "suspended") and recover and not previous:
                # Disconnect evidence is committed by the monitor before this atomic rotation.
                if db.execute("SELECT 1 FROM sessions WHERE credential_id=?", (row["credential_id"],)).fetchone():
                    raise ProvisioningError(409, "credential_disconnect_pending")
                db.execute("UPDATE credentials SET version=version+1,password=?,expires_at=?,state='active',reason=NULL,excess_since=NULL WHERE credential_id=?",
                           (secrets.token_urlsafe(32), int(self.clock()) + self.settings["credential_ttl_days"] * 86400, row["credential_id"]))
                row = db.execute("SELECT * FROM credentials WHERE credential_id=?", (row["credential_id"],)).fetchone()
            if row["state"] != "active":
                raise ProvisioningError(409, "credential_" + row["state"])
            db.execute("INSERT OR IGNORE INTO requests VALUES (?,?,?,?)",
                       (request, fingerprint, row["credential_id"], row["version"]))
            return {**self.public(row), "password": row["password"]}

    def suspend(self, credential_id):
        if not re.fullmatch(r"[0-9a-f]{32}", credential_id):
            raise ProvisioningError(404, "credential_not_found")
        with self.transaction() as db:
            row = db.execute("SELECT * FROM credentials WHERE credential_id=?", (credential_id,)).fetchone()
            if not row:
                raise ProvisioningError(404, "credential_not_found")
            if row["state"] == "active":
                db.execute("UPDATE credentials SET state='suspending',reason='admin' WHERE credential_id=?", (credential_id,))
            return self.public(db.execute("SELECT * FROM credentials WHERE credential_id=?", (credential_id,)).fetchone())

    def status(self):
        with self.transaction() as db:
            ready = self.ready(db)
            rows = []
            for row in db.execute("SELECT * FROM credentials ORDER BY credential_id LIMIT 1000"):
                counts = db.execute("SELECT state,count(*) FROM sessions WHERE credential_id=? GROUP BY state",
                                    (row["credential_id"],)).fetchall()
                rows.append({**self.public(row), "reason": row["reason"],
                             "expired": row["expires_at"] <= self.clock(),
                             "sessions": {r[0]: r[1] for r in counts}})
            return {"server_id": self.settings["server_id"], "monitor_ready": ready,
                    "supported_protocols": ["openvpn"] if ready else [],
                    "implemented_protocols": ["openvpn"],
                    "unsupported_protocols": ["ssh", "vmess", "vless", "trojan"],
                    "session_unit": "authenticated_openvpn_client_instance",
                    "max_protocol_sessions": 2, "verified_device_count": None,
                    "reconnect_grace_seconds": self.settings["reconnect_grace_seconds"],
                    "credentials": rows, "credential_list_limit": 1000}

    def heartbeat(self, instance, ready):
        if instance not in self.settings["openvpn_management"]:
            raise ValueError("unknown management instance")
        with self.transaction() as db:
            db.execute("INSERT OR REPLACE INTO monitors VALUES (?,?,?,?)",
                       (instance, self.clock(), int(ready), self.config_hash))

    def authorize(self, instance, cid, username, password, certificate_cn=None):
        if self.require_certificate and (not certificate_cn or certificate_cn != username):
            return False
        if instance not in self.settings["openvpn_management"] or not re.fullmatch(r"[0-9]{1,10}", cid):
            return False
        with self.transaction() as db:
            if not self.ready(db):
                return False
            row = db.execute("SELECT * FROM credentials WHERE username=?", (username,)).fetchone()
            if (not row or row["state"] != "active" or row["expires_at"] <= self.clock()
                    or not isinstance(password, str)
                    or not secrets.compare_digest(row["password"].encode(), password.encode())):
                return False
            existing = db.execute("SELECT * FROM sessions WHERE instance=? AND cid=?", (instance, cid)).fetchone()
            if existing:
                return existing["credential_id"] == row["credential_id"] and existing["version"] == row["version"]
            count = db.execute("SELECT count(*) FROM sessions WHERE credential_id=?", (row["credential_id"],)).fetchone()[0]
            if count >= 2:
                # Repeated authenticated overuse, not a count of physical devices.
                if row["excess_since"] is None:
                    db.execute("UPDATE credentials SET excess_since=? WHERE credential_id=?",
                               (self.clock(), row["credential_id"]))
                elif self.clock() - row["excess_since"] >= self.settings["reconnect_grace_seconds"]:
                    db.execute("UPDATE credentials SET state='suspending',reason='session_limit' WHERE credential_id=?",
                               (row["credential_id"],))
                return False
            db.execute("INSERT INTO sessions VALUES (?,?,?,?,?,?)",
                       (instance, cid, row["credential_id"], row["version"], "reserved", self.clock()))
            db.execute("UPDATE credentials SET excess_since=NULL WHERE credential_id=?", (row["credential_id"],))
            return True

    def established(self, instance, cid):
        with self.transaction() as db:
            db.execute("UPDATE sessions SET state='active' WHERE instance=? AND cid=?", (instance, cid))

    def disconnected(self, instance, cid):
        with self.transaction() as db:
            row = db.execute("SELECT credential_id FROM sessions WHERE instance=? AND cid=?", (instance, cid)).fetchone()
            db.execute("DELETE FROM sessions WHERE instance=? AND cid=?", (instance, cid))
            if row:
                db.execute("UPDATE credentials SET excess_since=NULL WHERE credential_id=?", (row[0],))

    def reconcile(self, instance, live_cids, bootstrapping=False):
        """Snapshot absence confirms disconnection, never authenticates a new session."""
        kill = set(live_cids) if bootstrapping else set()
        with self.transaction() as db:
            db.execute("UPDATE credentials SET state='suspending',reason='expired' WHERE state='active' AND expires_at<=?", (self.clock(),))
            # Defensive enforcement for a pre-existing excess of authenticated
            # sessions. Reservations and rejected logins cannot trigger this.
            for credential in db.execute("SELECT credential_id,excess_since FROM credentials WHERE state='active'").fetchall():
                count = db.execute("SELECT count(*) FROM sessions WHERE credential_id=? AND state='active'", (credential[0],)).fetchone()[0]
                if count < 2:
                    db.execute("UPDATE credentials SET excess_since=NULL WHERE credential_id=?", (credential[0],))
                elif count > 2 and credential[1] is None:
                    db.execute("UPDATE credentials SET excess_since=? WHERE credential_id=?", (self.clock(), credential[0]))
                elif count > 2 and credential[1] is not None and self.clock() - credential[1] >= self.settings["reconnect_grace_seconds"]:
                    db.execute("UPDATE credentials SET state='suspending',reason='session_limit' WHERE credential_id=?", (credential[0],))
            rows = db.execute("SELECT s.*,c.state AS credential_state,c.version AS current_version FROM sessions s JOIN credentials c USING(credential_id) WHERE instance=?", (instance,)).fetchall()
            known = {r["cid"] for r in rows}
            kill.update(set(live_cids) - known)
            for row in rows:
                cid = row["cid"]
                if cid not in live_cids and bootstrapping:
                    db.execute("DELETE FROM sessions WHERE instance=? AND cid=?", (instance, cid))
                elif (row["credential_state"] != "active" or row["version"] != row["current_version"]
                      or (row["state"] == "reserved" and self.clock() - row["created_at"] > 30)):
                    kill.add(cid)
            if self.ready(db):
                db.execute("UPDATE credentials SET state='suspended' WHERE state='suspending' AND NOT EXISTS (SELECT 1 FROM sessions s WHERE s.credential_id=credentials.credential_id)")
        return sorted(kill, key=int)

    def reset_instance(self, instance):
        """Only after a bootstrap drain: all new auth was denied during drain."""
        with self.transaction() as db:
            db.execute("DELETE FROM sessions WHERE instance=?", (instance,))
DEVICE_CREDENTIALS
cat >/opt/iptunnel/device_certificates.py <<'DEVICE_CERTIFICATES'
"""Dedicated client CA issuance. Private device keys never leave Android."""
import base64
import os
import pathlib
import secrets
import subprocess
import tempfile
import time

from device_credentials import CredentialStore, ProvisioningError
from device_ssh import ssh_key


class CertificateStore:
    def __init__(self, config):
        settings = config.get('provisioning', {})
        if settings.get('openvpn_device_certificates') is not True:
            raise ProvisioningError(503, 'device_certificates_disabled')
        self.store = CredentialStore(config)
        self.ca = pathlib.Path(settings.get('client_ca_certificate', ''))
        self.key = pathlib.Path(settings.get('client_ca_key', ''))
        for path in (self.ca, self.key):
            if not path.is_absolute() or path.is_symlink() or not path.is_file():
                raise ProvisioningError(503, 'client_ca_unavailable')
            if os.name == 'posix' and (path.stat().st_uid != os.geteuid() or path.stat().st_mode & 0o077):
                raise ProvisioningError(503, 'client_ca_not_private')
        with self.store.transaction() as db:
            db.execute('CREATE TABLE IF NOT EXISTS device_certificates (owner TEXT PRIMARY KEY, key_hash TEXT NOT NULL, certificate TEXT NOT NULL, expires INTEGER NOT NULL)')

    @staticmethod
    def run(args):
        result = subprocess.run(['openssl'] + args, capture_output=True, timeout=15)
        if result.returncode:
            raise ProvisioningError(503, 'certificate_operation_failed')
        return result.stdout

    def provision(self, body):
        if not isinstance(body, dict) or set(body) != {'owner_id','protocol','request_id','recover','tls_public_key'}:
            raise ProvisioningError(422, 'invalid_certificate_request')
        _, key_hash = ssh_key(body['tls_public_key'])
        # Bind issuance before creating credentials, including on replay.
        core = {k:v for k,v in body.items() if k != 'tls_public_key'}
        with self.store.transaction() as db:
            old = db.execute('SELECT * FROM device_certificates WHERE owner=?', (body['owner_id'],)).fetchone()
            if old and old['key_hash'] != key_hash:
                raise ProvisioningError(409, 'tls_key_mismatch')
        credential = self.store.provision(core)
        with self.store.transaction() as db:
            old = db.execute('SELECT * FROM device_certificates WHERE owner=?', (body['owner_id'],)).fetchone()
            if old and old['key_hash'] != key_hash:
                raise ProvisioningError(409, 'tls_key_mismatch')
            if old and old['expires'] > time.time() + 300:
                pem, expires = old['certificate'], old['expires']
            else:
                # One-day certificates; renewal still requires a fresh app proof.
                self.run(['x509','-in',str(self.ca),'-checkend','86460','-noout'])
                with tempfile.TemporaryDirectory(dir=self.store.path.parent) as directory:
                    public = pathlib.Path(directory) / 'public.pem'
                    extensions = pathlib.Path(directory) / 'extensions.cnf'
                    public.write_text('-----BEGIN PUBLIC KEY-----\n' + body['tls_public_key'] + '\n-----END PUBLIC KEY-----\n')
                    extensions.write_text('basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=clientAuth\n')
                    pem = self.run(['x509','-new','-force_pubkey',str(public),'-subj','/CN=' + credential['username'],
                                    '-CA',str(self.ca),'-CAkey',str(self.key),'-set_serial','0x'+secrets.token_hex(16),
                                    '-days','1','-sha256','-extfile',str(extensions)]).decode('ascii')
                expires = int(time.time()) + 86340
                db.execute('INSERT OR REPLACE INTO device_certificates VALUES (?,?,?,?)',
                           (body['owner_id'],key_hash,pem,expires))
        return {**credential, 'expires_at': min(credential['expires_at'], expires),
                'auth_type':'openvpn_certificate', 'key_hash':key_hash,
                'certificate_pem':pem, 'ca_certificate_pem':self.ca.read_text()}
DEVICE_CERTIFICATES
chmod 644 /opt/iptunnel/device_certificates.py
cat >/opt/iptunnel/device_xray.py <<'DEVICE_XRAY'
"""Isolated managed WS listeners. No users are added to legacy Xray inbounds."""
import argparse
import contextlib
import hashlib
import json
import os
import pathlib
import re
import secrets
import sqlite3
import subprocess
import tempfile
import time
import uuid

from device_credentials import ProvisioningError
from device_ssh import ssh_key
from device_certificates import CertificateStore

PROTOCOLS = ('vmess', 'vless', 'trojan')


def atomic(path, text, mode=0o600):
    path = pathlib.Path(path)
    temporary = path.with_name(path.name + '.' + secrets.token_hex(8))
    fd = os.open(temporary, os.O_CREAT | os.O_EXCL | os.O_WRONLY, mode)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8', newline='\n') as stream:
            stream.write(text)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


class XrayDeviceStore:
    def __init__(self, config, runner=None):
        p = config.get('provisioning', {})
        if p.get('enabled') is not True or p.get('xray_device_certificates') is not True:
            raise ProvisioningError(503, 'managed_xray_disabled')
        self.p = p
        self.root = pathlib.Path(p.get('xray_state_dir', '/var/lib/iptunnel-device-xray'))
        self.port = p.get('managed_port', 9443)
        self.name = p.get('managed_server_name', '')
        self.binary = p.get('xray_binary', '/usr/local/bin/xray')
        if (type(self.port) is not int or not 1024 <= self.port <= 65535
                or self.port in (19440, 19441, 19442, 19449)
                or not re.fullmatch(r'[A-Za-z0-9.-]+', self.name)
                or not self.root.is_absolute() or self.root.is_symlink()):
            raise ProvisioningError(503, 'invalid_managed_xray_configuration')
        if os.name == 'posix' and any(not re.fullmatch(r'/[A-Za-z0-9_./-]+', value)
                                     for value in (str(self.root), self.binary)):
            raise ProvisioningError(503, 'invalid_managed_xray_configuration')
        self.root.mkdir(mode=0o700, parents=True, exist_ok=True)
        if os.name == 'posix' and (self.root.stat().st_uid != os.geteuid() or self.root.stat().st_mode & 0o077):
            raise ProvisioningError(503, 'managed_xray_directory_not_private')
        self.ca = pathlib.Path(p.get('client_ca_certificate', ''))
        self.ca_key = pathlib.Path(p.get('client_ca_key', ''))
        self.server_cert = pathlib.Path(p.get('managed_server_certificate', ''))
        self.server_key = pathlib.Path(p.get('managed_server_key', ''))
        for path in (self.ca,self.ca_key,self.server_cert,self.server_key):
            if not path.is_absolute() or not re.fullmatch(r'[A-Za-z0-9_./:\\ -]+', str(path)) or not path.is_file():
                raise ProvisioningError(503, 'managed_xray_certificate_unavailable')
            # Let's Encrypt live paths are symlinks; validate their resolved owner.
            if os.name == 'posix' and path.resolve().stat().st_uid != os.geteuid():
                raise ProvisioningError(503, 'managed_xray_certificate_owner_invalid')
        for path in (self.ca_key,self.server_key):
            if os.name == 'posix' and (path.stat().st_uid != os.geteuid() or path.stat().st_mode & 0o077):
                raise ProvisioningError(503, 'managed_xray_key_not_private')
        self.db_path = self.root/'devices.sqlite3'
        if self.db_path.is_symlink():
            raise ProvisioningError(503, 'unsafe_managed_xray_database')
        self.run = runner or self.command
        with self.transaction() as db:
            db.execute('CREATE TABLE IF NOT EXISTS identities(owner TEXT NOT NULL, protocol TEXT NOT NULL, id TEXT NOT NULL UNIQUE, secret TEXT NOT NULL, key_hash TEXT NOT NULL, cert TEXT NOT NULL, expires INTEGER NOT NULL, PRIMARY KEY(owner,protocol))')
            db.execute('CREATE TABLE IF NOT EXISTS requests(id TEXT PRIMARY KEY, fingerprint TEXT NOT NULL)')

    @contextlib.contextmanager
    def transaction(self):
        db = sqlite3.connect(self.db_path, isolation_level=None, timeout=15)
        db.row_factory = sqlite3.Row
        try:
            db.execute('PRAGMA synchronous=FULL')
            db.execute('BEGIN IMMEDIATE')
            yield db
            db.commit()
        except BaseException:
            db.rollback()
            raise
        finally:
            db.close()

    @staticmethod
    def command(args):
        result = subprocess.run(args, capture_output=True, timeout=15, text=True)
        if result.returncode:
            raise ProvisioningError(503, 'managed_xray_runtime_unavailable')
        return result.stdout

    @staticmethod
    def client(row):
        result = {'email':row['id']}
        result['password' if row['protocol']=='trojan' else 'id'] = row['secret']
        return result

    def core_config(self, rows):
        inbounds = []
        for i, protocol in enumerate(PROTOCOLS):
            settings = {'clients':[self.client(r) for r in rows if r['protocol']==protocol]}
            if protocol == 'vless': settings['decryption']='none'
            inbounds.append({'tag':'device-'+protocol,'listen':'127.0.0.1','port':19440+i,
                             'protocol':protocol,'settings':settings,
                             'streamSettings':{'network':'ws','wsSettings':{'path':'/'+protocol}}})
        inbounds.append({'tag':'device-api','listen':'127.0.0.1','port':19449,'protocol':'dokodemo-door','settings':{'address':'127.0.0.1'}})
        return {'log':{'loglevel':'warning'},'api':{'tag':'device-api','services':['HandlerService']},
                'inbounds':inbounds,'outbounds':[{'protocol':'freedom','tag':'direct'}],
                'routing':{'rules':[{'type':'field','inboundTag':['device-api'],'outboundTag':'device-api'}]}}

    def nginx_config(self):
        text = f'''# Generated managed-only listener; do not proxy here from a cleartext listener.
server {{
    listen {self.port} ssl;
    server_name {self.name};
    ssl_certificate "{self.server_cert.as_posix()}";
    ssl_certificate_key "{self.server_key.as_posix()}";
    ssl_client_certificate "{self.ca.as_posix()}";
    ssl_verify_client on;
    ssl_verify_depth 1;
    ssl_session_cache off;
    ssl_session_tickets off;
    ssl_protocols TLSv1.2 TLSv1.3;
    access_log off;
    location / {{ return 403; }}
'''
        for i, protocol in enumerate(PROTOCOLS):
            text += f'''    location ~ "^/device/(?<device_id>[a-f0-9]{{32}})/{protocol}$" {{
        if ($ssl_client_verify != SUCCESS) {{ return 403; }}
        if ($ssl_client_s_dn != "CN=$device_id") {{ return 403; }}
        rewrite ^ /{protocol} break;
        proxy_pass http://127.0.0.1:{19440+i};
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }}
'''
        return text + '}\n'

    def check_runtime(self, rows):
        expected = json.dumps(self.core_config(rows), indent=2)
        self.reconcile_config(expected)
        nginx = pathlib.Path('/etc/nginx/conf.d/iptunnel-device-xray.conf')
        if nginx.read_text() != self.nginx_config():
            raise ProvisioningError(503,'managed_xray_ingress_mismatch')
        self.run(['nginx','-t'])
        self.run(['systemctl','is-active','--quiet','iptunnel-device-xray','nginx'])

    def reconcile_config(self, expected):
        path = self.root/'config.json'
        actual = path.read_text()
        journal = self.root/'config-pending.json'
        if actual != expected:
            hashes = json.loads(journal.read_text()) if journal.exists() else []
            digest = lambda text: hashlib.sha256(text.encode()).hexdigest()
            if digest(actual) not in hashes or digest(expected) not in hashes:
                raise ProvisioningError(503, 'managed_xray_config_mismatch')
            # Only recover our own interrupted write, never arbitrary operator edits.
            atomic(path, expected)
        journal.unlink(missing_ok=True)

    def provision(self, body):
        if not isinstance(body,dict) or set(body) != {'owner_id','protocol','request_id','recover','tls_public_key'}:
            raise ProvisioningError(422,'invalid_provisioning_body')
        owner,protocol,request = body['owner_id'],body['protocol'],body['request_id']
        if (not isinstance(owner,str) or not re.fullmatch('[a-f0-9]{64}',owner) or protocol not in PROTOCOLS
                or not isinstance(request,str) or not re.fullmatch('[a-f0-9]{32}',request) or type(body['recover']) is not bool):
            raise ProvisioningError(422,'invalid_provisioning_body')
        _,key_hash = ssh_key(body['tls_public_key'])
        fingerprint = hashlib.sha256(json.dumps(body,sort_keys=True).encode()).hexdigest()
        with self.transaction() as db:
            previous=db.execute('SELECT fingerprint FROM requests WHERE id=?',(request,)).fetchone()
            if previous and previous[0]!=fingerprint: raise ProvisioningError(409,'idempotency_key_conflict')
            rows=db.execute('SELECT * FROM identities').fetchall()
            self.check_runtime(rows)
            row=db.execute('SELECT * FROM identities WHERE owner=? AND protocol=?',(owner,protocol)).fetchone()
            if row and row['key_hash']!=key_hash: raise ProvisioningError(409,'tls_key_mismatch')
            if not row:
                row={'owner':owner,'protocol':protocol,'id':secrets.token_hex(16),'secret':str(uuid.uuid4()),'key_hash':key_hash,'cert':'','expires':0}
            else: row=dict(row)
            if row['expires'] <= time.time()+300:
                CertificateStore.run(['x509','-in',str(self.ca),'-checkend','86460','-noout'])
                with tempfile.TemporaryDirectory(dir=self.root) as directory:
                    public=pathlib.Path(directory)/'public.pem'; ext=pathlib.Path(directory)/'ext.cnf'
                    public.write_text('-----BEGIN PUBLIC KEY-----\n'+body['tls_public_key']+'\n-----END PUBLIC KEY-----\n')
                    ext.write_text('basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=clientAuth\n')
                    row['cert']=CertificateStore.run(['x509','-new','-force_pubkey',str(public),'-subj','/CN='+row['id'],'-CA',str(self.ca),'-CAkey',str(self.ca_key),'-set_serial','0x'+secrets.token_hex(16),'-days','1','-sha256','-extfile',str(ext)]).decode()
                row['expires']=int(time.time())+86340
            # Persist before runtime side effects. Replay reconciles a lost response.
            db.execute('INSERT OR REPLACE INTO identities VALUES (?,?,?,?,?,?,?)',tuple(row[k] for k in ('owner','protocol','id','secret','key_hash','cert','expires')))
            db.execute('INSERT OR IGNORE INTO requests VALUES (?,?)',(request,fingerprint))
            rows=db.execute('SELECT * FROM identities').fetchall()
            path = self.root/'config.json'
            updated = json.dumps(self.core_config(rows),indent=2)
            atomic(self.root/'config-pending.json', json.dumps([
                hashlib.sha256(path.read_text().encode()).hexdigest(),
                hashlib.sha256(updated.encode()).hexdigest()]))
            atomic(path, updated)
        # Existing runtime users are queried by identity; adu's exit status alone is insufficient.
        self.ensure_user(row)
        return {'credential_id':row['id'],'version':1,'state':'active','expires_at':row['expires'],
                'auth_type':'xray_certificate','key_hash':key_hash,'certificate_pem':row['cert'],
                'ca_certificate_pem':self.ca.read_text(),'managed_port':self.port,
                'managed_path':'/device/'+row['id']+'/'+protocol,
                ('password' if protocol=='trojan' else 'uuid'):row['secret']}

    def ensure_user(self,row):
        tag='device-'+row['protocol']
        def present():
            data=json.loads(self.run([self.binary,'api','inbounduser','--server=127.0.0.1:19449','-tag='+tag,'-email='+row['id']]))
            return any(user.get('email')==row['id'] for user in data.get('users',[]))
        if present(): return
        with tempfile.TemporaryDirectory(dir=self.root) as directory:
            path=pathlib.Path(directory)/'add.json'
            config=self.core_config([row]); config['inbounds']=[i for i in config['inbounds'] if i['tag']==tag]
            path.write_text(json.dumps(config))
            self.run([self.binary,'api','adu','--server=127.0.0.1:19449',str(path)])
        if not present(): raise ProvisioningError(503,'managed_xray_user_unavailable')

    def initialize(self):
        with self.transaction() as db:
            atomic(self.root/'config.json',json.dumps(self.core_config(db.execute('SELECT * FROM identities').fetchall()),indent=2))
        self.run([self.binary,'run','-test','-config',str(self.root/'config.json')])
        atomic('/etc/nginx/conf.d/iptunnel-device-xray.conf',self.nginx_config(),0o644)
        unit=f'''[Unit]
Description=IPTunnel device-only Xray
After=network.target
[Service]
ExecStart={self.binary} run -config {self.root}/config.json
Restart=on-failure
NoNewPrivileges=true
PrivateTmp=true
[Install]
WantedBy=multi-user.target
'''
        atomic('/etc/systemd/system/iptunnel-device-xray.service',unit,0o644)
        self.run(['nginx','-t'])


if __name__=='__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('--config',required=True)
    parser.add_argument('--initialize',action='store_true',required=True)
    args=parser.parse_args()
    XrayDeviceStore(json.loads(pathlib.Path(args.config).read_text())).initialize()
DEVICE_XRAY
chmod 644 /opt/iptunnel/device_xray.py
cat >/opt/iptunnel/provisioning_setup.py <<'PROVISIONING_SETUP'
#!/usr/bin/env python3
"""Transactional, explicit activation for IPTunnel device provisioning."""
from __future__ import annotations

import argparse
import json
import os
import pathlib
import re
import shutil
import subprocess
import tempfile


class SetupError(RuntimeError):
    pass


def run(args):
    result = subprocess.run(args, capture_output=True, text=True, timeout=30)
    if result.returncode:
        raise SetupError((result.stderr or result.stdout or 'command failed').strip())
    return result.stdout


def atomic_json(path, value):
    path = pathlib.Path(path)
    fd, temporary = tempfile.mkstemp(prefix=path.name + '.', dir=path.parent)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8', newline='\n') as stream:
            json.dump(value, stream, indent=2)
            stream.write('\n')
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    finally:
        pathlib.Path(temporary).unlink(missing_ok=True)


def load_config(path):
    try:
        value = json.loads(pathlib.Path(path).read_text())
    except (OSError, ValueError) as exc:
        raise SetupError('invalid IPTunnel config') from exc
    if not isinstance(value, dict):
        raise SetupError('invalid IPTunnel config')
    return value


def provisioning(config, server_id):
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,63}', server_id or ''):
        raise SetupError('server id must use 1-64 letters, numbers, dot, underscore or hyphen')
    current = config.setdefault('provisioning', {})
    existing = current.get('server_id')
    if existing and existing != server_id:
        raise SetupError('server id is immutable after configuration')
    defaults = {
        'enabled': True, 'ssh_device_keys': False,
        'openvpn_device_certificates': False, 'xray_device_certificates': False,
        'server_id': server_id,
        'db_path': '/var/lib/iptunnel-provisioning/credentials.sqlite3',
        'ssh_db_path': '/var/lib/iptunnel-provisioning/ssh.sqlite3',
        'credential_ttl_days': 30, 'reconnect_grace_seconds': 30,
        'client_ca_certificate': '/var/lib/iptunnel-provisioning/client-ca.pem',
        'client_ca_key': '/var/lib/iptunnel-provisioning/client-ca.key',
        'openvpn_management': {'udp': '/run/iptunnel-provisioning/udp.sock'},
        'xray_state_dir': '/var/lib/iptunnel-device-xray',
        'xray_binary': '/usr/local/bin/xray', 'managed_port': 9443,
    }
    for key, value in defaults.items():
        current.setdefault(key, value)
    return current


def require_root():
    if os.name != 'posix' or os.geteuid() != 0:
        raise SetupError('device provisioning setup requires Linux root')


def generate_ca(settings):
    certificate = pathlib.Path(settings['client_ca_certificate'])
    key = pathlib.Path(settings['client_ca_key'])
    if certificate.exists() != key.exists():
        raise SetupError('client CA is incomplete; restore both files or remove both deliberately')
    if certificate.exists():
        run(['openssl', 'x509', '-in', str(certificate), '-checkend', '172800', '-noout'])
        return
    certificate.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if certificate.parent.is_symlink():
        raise SetupError('client CA directory cannot be a symlink')
    run(['openssl', 'req', '-x509', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:P-256',
         '-nodes', '-keyout', str(key), '-out', str(certificate), '-days', '3650',
         '-subj', '/CN=IPTunnel Device Client CA',
         '-addext', 'basicConstraints=critical,CA:TRUE',
         '-addext', 'keyUsage=critical,keyCertSign,cRLSign'])
    os.chmod(key, 0o600)
    os.chmod(certificate, 0o600)


def prepare_ssh(config_path, server_id):
    require_root()
    config = load_config(config_path)
    settings = provisioning(config, server_id)
    source = pathlib.Path('/opt/iptunnel/managed-ssh.conf')
    target = pathlib.Path('/etc/ssh/sshd_config.d/10-iptunnel-device-keys.conf')
    if not source.is_file() or not pathlib.Path('/usr/sbin/sshd').is_file():
        raise SetupError('OpenSSH or managed SSH policy is unavailable')
    pathlib.Path('/etc/iptunnel/device-ssh/keys').mkdir(mode=0o755, parents=True, exist_ok=True)
    os.chmod('/etc/iptunnel/device-ssh', 0o755)
    os.chmod('/etc/iptunnel/device-ssh/keys', 0o755)
    previous = target.read_bytes() if target.exists() else None
    try:
        shutil.copyfile(source, target)
        os.chmod(target, 0o644)
        run(['/usr/sbin/sshd', '-t'])
        effective = run(['/usr/sbin/sshd', '-T', '-C',
                         'user=dpk_000000000000000000000000,host=localhost,addr=127.0.0.1'])
        required = {'authenticationmethods publickey', 'passwordauthentication no',
                    'kbdinteractiveauthentication no', 'forcecommand /usr/sbin/nologin',
                    'authorizedkeysfile /etc/iptunnel/device-ssh/keys/%u',
                    'allowtcpforwarding local'}
        if not required.issubset(set(effective.splitlines())):
            raise SetupError('OpenSSH did not apply the managed device policy')
        run(['systemctl', 'reload', 'ssh'])
        settings['ssh_device_keys'] = True
        atomic_json(config_path, config)
    except BaseException:
        if previous is None: target.unlink(missing_ok=True)
        else: target.write_bytes(previous)
        subprocess.run(['/usr/sbin/sshd', '-t'], capture_output=True)
        subprocess.run(['systemctl', 'reload', 'ssh'], capture_output=True)
        raise


def prepare_openvpn(config_path, server_id):
    require_root()
    from provisioning_monitor import configure, verify_runtime_config
    config = load_config(config_path)
    settings = provisioning(config, server_id)
    generate_ca(settings)
    directory = pathlib.Path('/etc/openvpn/server')
    profiles = sorted(directory.glob('iptunnel-*.conf'))
    if not profiles:
        raise SetupError('no IPTunnel OpenVPN server profiles found')
    instances = [path.stem.removeprefix('iptunnel-') for path in profiles]
    settings['openvpn_management'] = {
        name: f'/run/iptunnel-provisioning/{name}.sock' for name in instances
    }
    settings['openvpn_device_certificates'] = True
    backup = {path: path.read_bytes() for path in profiles}
    old_config = pathlib.Path(config_path).read_bytes()
    monitor_was_active = subprocess.run(
        ['systemctl', 'is-active', '--quiet', 'iptunnel-provisioning'],
        capture_output=True).returncode == 0
    try:
        configure(config, directory)
        atomic_json(config_path, config)
        for name in instances:
            verify_runtime_config(name, settings['openvpn_management'][name], settings)
            run(['systemctl', 'restart', f'openvpn-server@iptunnel-{name}'])
        run(['systemctl', 'enable', '--now', 'iptunnel-provisioning'])
    except BaseException:
        for path, value in backup.items(): path.write_bytes(value)
        pathlib.Path(config_path).write_bytes(old_config)
        if not monitor_was_active:
            subprocess.run(['systemctl', 'disable', '--now', 'iptunnel-provisioning'],
                           capture_output=True)
        for name in instances:
            subprocess.run(['systemctl', 'restart', f'openvpn-server@iptunnel-{name}'],
                           capture_output=True)
        raise


def prepare_xray(config_path, server_id, port, server_name, certificate, key):
    require_root()
    config = load_config(config_path)
    settings = provisioning(config, server_id)
    generate_ca(settings)
    if not 1024 <= port <= 65535 or port in (19440, 19441, 19442, 19449):
        raise SetupError('managed Xray port is invalid or reserved')
    if not re.fullmatch(r'[A-Za-z0-9.-]+', server_name or ''):
        raise SetupError('managed Xray server name is invalid')
    for path in (certificate, key):
        if not pathlib.Path(path).is_file(): raise SetupError('managed Xray TLS file missing')
    settings.update({'xray_device_certificates': True, 'managed_port': port,
                     'managed_server_name': server_name,
                     'managed_server_certificate': certificate,
                     'managed_server_key': key})
    old_config = pathlib.Path(config_path).read_bytes()
    managed = [pathlib.Path('/etc/nginx/conf.d/iptunnel-device-xray.conf'),
               pathlib.Path('/etc/systemd/system/iptunnel-device-xray.service'),
               pathlib.Path(settings['xray_state_dir'])/'config.json']
    backup = {path: path.read_bytes() if path.exists() else None for path in managed}
    was_active = subprocess.run(['systemctl','is-active','--quiet','iptunnel-device-xray'],
                                capture_output=True).returncode == 0
    try:
        atomic_json(config_path, config)
        from device_xray import XrayDeviceStore
        store = XrayDeviceStore(config)
        store.initialize()
        run(['systemctl', 'daemon-reload'])
        run(['systemctl', 'enable', '--now', 'iptunnel-device-xray'])
        run(['nginx', '-t'])
        run(['systemctl', 'reload', 'nginx'])
        with store.transaction() as db:
            store.check_runtime(db.execute('SELECT * FROM identities').fetchall())
    except BaseException:
        pathlib.Path(config_path).write_bytes(old_config)
        for path, value in backup.items():
            if value is None: path.unlink(missing_ok=True)
            else: path.write_bytes(value)
        if not was_active:
            subprocess.run(['systemctl','disable','--now','iptunnel-device-xray'], capture_output=True)
        subprocess.run(['systemctl','daemon-reload'], capture_output=True)
        subprocess.run(['nginx','-t'], capture_output=True)
        subprocess.run(['systemctl','reload','nginx'], capture_output=True)
        raise


def status(config_path):
    config = load_config(config_path)
    settings = config.get('provisioning') or {}
    result = {key: settings.get(key, False) for key in
          ('enabled','server_id','ssh_device_keys','openvpn_device_certificates',
           'xray_device_certificates','managed_port','managed_server_name')}
    if os.name == 'posix':
        result['services'] = {name: subprocess.run(
            ['systemctl','is-active','--quiet',name], capture_output=True).returncode == 0
            for name in ('ssh','iptunnel-provisioning','iptunnel-device-xray','nginx')}
    print(json.dumps(result, indent=2))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--config', default='/etc/iptunnel/config.json')
    sub = parser.add_subparsers(dest='action', required=True)
    sub.add_parser('status')
    for name in ('prepare-ssh','prepare-openvpn'):
        item = sub.add_parser(name); item.add_argument('--server-id', required=True)
    item = sub.add_parser('prepare-xray'); item.add_argument('--server-id', required=True)
    item.add_argument('--port', required=True, type=int); item.add_argument('--server-name', required=True)
    item.add_argument('--certificate', required=True); item.add_argument('--key', required=True)
    args = parser.parse_args()
    try:
        if args.action == 'status': status(args.config)
        elif args.action == 'prepare-ssh': prepare_ssh(args.config, args.server_id)
        elif args.action == 'prepare-openvpn': prepare_openvpn(args.config, args.server_id)
        else: prepare_xray(args.config, args.server_id, args.port, args.server_name, args.certificate, args.key)
    except SetupError as exc:
        raise SystemExit('ERROR: ' + str(exc)) from None


if __name__ == '__main__':
    main()
PROVISIONING_SETUP
chmod 700 /opt/iptunnel/provisioning_setup.py
cat >/opt/iptunnel/device_ssh.py <<'DEVICE_SSH'
"""Opt-in OpenSSH enrollment bound to the verified installation P-256 key."""
import base64
import contextlib
import datetime
import hashlib
import json
import os
import pathlib
import re
import secrets
import sqlite3
import struct
import subprocess
import time

from device_credentials import ProvisioningError


def ssh_key(encoded):
    try:
        raw = base64.b64decode(encoded, validate=True)
        prefix = bytes.fromhex('3059301306072a8648ce3d020106082a8648ce3d03010703420004')
        if len(raw) != 91 or not raw.startswith(prefix) or base64.b64encode(raw).decode() != encoded:
            raise ValueError()
        point = raw[-65:]
        x, y = int.from_bytes(point[1:33], 'big'), int.from_bytes(point[33:], 'big')
        prime = 0xffffffff00000001000000000000000000000000ffffffffffffffffffffffff
        b = 0x5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604b
        if x >= prime or y >= prime or (y*y - (x*x*x - 3*x + b)) % prime:
            raise ValueError()
        fields = (b'ecdsa-sha2-nistp256', b'nistp256', point)
        blob = b''.join(struct.pack('>I', len(field)) + field for field in fields)
        return 'ecdsa-sha2-nistp256 ' + base64.b64encode(blob).decode(), hashlib.sha256(raw).hexdigest()
    except (ValueError, TypeError):
        raise ProvisioningError(422, 'invalid_public_key') from None


class OpenSshAccounts:
    key_dir = pathlib.Path('/etc/iptunnel/device-ssh/keys')

    def check(self, username):
        if os.name != 'posix' or os.geteuid() != 0:
            raise ProvisioningError(503, 'managed_ssh_requires_linux_root')
        result = subprocess.run(['/usr/sbin/sshd', '-T', '-C',
                                 f'user={username},host=localhost,addr=127.0.0.1'],
                                capture_output=True, text=True, timeout=10)
        expected = ['authenticationmethods publickey', 'passwordauthentication no',
                    'kbdinteractiveauthentication no', 'forcecommand /usr/sbin/nologin',
                    'authorizedkeysfile /etc/iptunnel/device-ssh/keys/%u',
                    'authorizedkeyscommand none', 'trustedusercakeys none',
                    'pubkeyauthentication yes', 'allowtcpforwarding local']
        if result.returncode or any(line not in result.stdout.splitlines() for line in expected):
            raise ProvisioningError(503, 'managed_ssh_policy_not_ready')
        for path in (self.key_dir, self.key_dir.parent):
            node = path.lstat()
            if path.is_symlink() or node.st_uid != 0 or node.st_mode & 0o022:
                raise ProvisioningError(503, 'unsafe_managed_ssh_key_directory')

    def install(self, username, public_key, expires, owner):
        import pwd
        self.check(username)
        marker = 'iptunnel-device:' + owner
        try:
            account = pwd.getpwnam(username)
        except KeyError:
            # An unknown random password hash keeps the Unix account unlocked for
            # public-key auth; sshd explicitly forbids password authentication.
            hashed = subprocess.run(['/usr/bin/openssl', 'passwd', '-6', '-stdin'],
                                    input=secrets.token_urlsafe(48) + '\n', text=True,
                                    capture_output=True, timeout=10, check=True).stdout.strip()
            subprocess.run(['/usr/sbin/useradd', '-M', '-s', '/usr/sbin/nologin',
                            '-c', marker, '-p', hashed, username], check=True,
                           capture_output=True, timeout=10)
            account = pwd.getpwnam(username)
        if account.pw_gecos != marker or account.pw_shell != '/usr/sbin/nologin':
            raise ProvisioningError(409, 'managed_ssh_account_collision')
        expiry = datetime.datetime.fromtimestamp(expires, datetime.timezone.utc).strftime('%Y%m%d%H%M%SZ')
        line = f'restrict,port-forwarding,expiry-time="{expiry}" {public_key}\n'
        path = self.key_dir / username
        temporary = self.key_dir / (username + '.' + secrets.token_hex(8))
        try:
            fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
            os.fchmod(fd, 0o644)
            with os.fdopen(fd, 'w') as stream:
                stream.write(line)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, path)
        finally:
            temporary.unlink(missing_ok=True)


class SshCredentialStore:
    def __init__(self, config, accounts=None, clock=time.time):
        settings = config.get('provisioning', {})
        if settings.get('enabled') is not True or settings.get('ssh_device_keys') is not True:
            raise ProvisioningError(503, 'managed_ssh_disabled')
        self.accounts = accounts or OpenSshAccounts()
        self.clock = clock
        self.path = pathlib.Path(settings.get('ssh_db_path', '/var/lib/iptunnel-provisioning/ssh.sqlite3'))
        self.path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        if self.path.is_symlink() or self.path.parent.is_symlink():
            raise ProvisioningError(503, 'unsafe_managed_ssh_database')
        if os.name == 'posix' and (self.path.parent.stat().st_uid != os.geteuid() or self.path.parent.stat().st_mode & 0o077):
            raise ProvisioningError(503, 'unsafe_managed_ssh_database')
        fd = os.open(self.path, os.O_CREAT | os.O_RDWR | getattr(os, 'O_NOFOLLOW', 0), 0o600)
        os.close(fd)
        if os.name == 'posix' and (self.path.stat().st_uid != os.geteuid() or self.path.stat().st_mode & 0o077):
            raise ProvisioningError(503, 'unsafe_managed_ssh_database')

    def provision(self, body):
        if not isinstance(body, dict) or set(body) != {'owner_id', 'protocol', 'request_id', 'recover', 'public_key'}:
            raise ProvisioningError(422, 'invalid_ssh_enrollment')
        owner, request = body['owner_id'], body['request_id']
        if (not isinstance(owner, str) or not re.fullmatch('[a-f0-9]{64}', owner)
                or not isinstance(request, str) or not re.fullmatch('[a-f0-9]{32}', request)
                or type(body['recover']) is not bool or body['protocol'] != 'ssh'):
            raise ProvisioningError(422, 'invalid_ssh_enrollment')
        public_key, key_hash = ssh_key(body['public_key'])
        username = 'dpk_' + owner[:24]
        self.accounts.check(username)
        fingerprint = hashlib.sha256(json.dumps(body, sort_keys=True).encode()).hexdigest()
        with contextlib.closing(sqlite3.connect(self.path, timeout=15)) as db, db:
            db.execute('CREATE TABLE IF NOT EXISTS owners (owner TEXT PRIMARY KEY, key_hash TEXT NOT NULL, expires INTEGER NOT NULL)')
            db.execute('CREATE TABLE IF NOT EXISTS requests (id TEXT PRIMARY KEY, fingerprint TEXT NOT NULL)')
            db.execute('BEGIN IMMEDIATE')
            prior = db.execute('SELECT fingerprint FROM requests WHERE id=?', (request,)).fetchone()
            if prior and prior[0] != fingerprint:
                raise ProvisioningError(409, 'idempotency_key_conflict')
            row = db.execute('SELECT key_hash,expires FROM owners WHERE owner=?', (owner,)).fetchone()
            if row and row[0] != key_hash:
                raise ProvisioningError(409, 'device_key_mismatch')
            expires = row[1] if row else int(self.clock()) + 30 * 86400
            if expires <= self.clock() and body['recover'] and not prior:
                expires = int(self.clock()) + 30 * 86400
            if expires <= self.clock():
                raise ProvisioningError(410, 'ssh_enrollment_expired')
            self.accounts.install(username, public_key, expires, owner)
            db.execute('INSERT INTO owners VALUES (?,?,?) ON CONFLICT(owner) DO UPDATE SET expires=excluded.expires', (owner, key_hash, expires))
            db.execute('INSERT OR IGNORE INTO requests VALUES (?,?)', (request, fingerprint))
        return dict(credential_id=owner[:32], username=username, key_hash=key_hash,
                    auth_type='ssh_publickey', version=1, expires_at=expires, state='active')
DEVICE_SSH
cat >/opt/iptunnel/managed-ssh.conf <<'MANAGED_SSH_CONFIG'
# Install as /etc/ssh/sshd_config.d/10-iptunnel-device-keys.conf on opt-in hosts.
# Public keys are root managed. Forwarding works without opening a shell.
Match User dpk_*
    AuthenticationMethods publickey
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    PubkeyAuthentication yes
    AuthorizedKeysFile /etc/iptunnel/device-ssh/keys/%u
    AuthorizedKeysCommand none
    TrustedUserCAKeys none
    ForceCommand /usr/sbin/nologin
    PermitTTY no
    AllowAgentForwarding no
    X11Forwarding no
    PermitUserRC no
    AllowTcpForwarding local
Match all
MANAGED_SSH_CONFIG
chmod 644 /opt/iptunnel/device_ssh.py /opt/iptunnel/managed-ssh.conf
cat >/opt/iptunnel/provisioning_monitor.py <<'PROVISIONING_MONITOR'
#!/usr/bin/env python3
"""OpenVPN management-client-auth monitor. Never expose this socket over TCP."""
from __future__ import annotations

import argparse
import json
import os
import pathlib
import re
import select
import shlex
import socket
import stat
import threading
import time

from device_credentials import CredentialStore, configuration


def required_directives(socket_path):
    return [f"management {socket_path} unix", "management-client-user root",
            "management-client-group root", "management-client-auth",
            "management-hold", "management-signal", "username-as-common-name"]


def configure(config, directory, profile=None):
    if config.get("provisioning", {}).get("enabled") is not True:
        return
    settings = configuration(config)
    if profile:
        path = pathlib.Path(profile)
        text = path.read_text()
        if "auth-user-pass" not in text.splitlines():
            path.write_text(text + "\nauth-user-pass\nauth-nocache\n")
        return
    profiles = {path.stem.removeprefix('iptunnel-'): path
                for path in pathlib.Path(directory).glob('iptunnel-*.conf')}
    if not profiles or set(profiles) != set(settings['openvpn_management']):
        raise RuntimeError('OpenVPN profiles and managed sockets do not match')
    for name, path in profiles.items():
        socket_path = settings["openvpn_management"][name]
        lines = path.read_text().splitlines()
        remove = {"management", "management-client-user", "management-client-group",
                  "management-client-auth", "management-hold", "management-signal",
                  "username-as-common-name", "auth-user-pass-optional", "auth-gen-token"}
        lines = [line for line in lines if not line.split() or line.split()[0] not in remove]
        lines.extend(required_directives(socket_path))
        if settings.get('openvpn_device_certificates'):
            ca = settings['client_ca_certificate']
            if not isinstance(ca, str) or not re.fullmatch(r'/[A-Za-z0-9_./-]+', ca):
                raise RuntimeError('invalid dedicated client CA path')
            if any(line.strip() == '<ca>' for line in lines):
                raise RuntimeError('remove inline client CA before managed certificate activation')
            lines = [line for line in lines if not line.split() or line.split()[0] not in
                     {'ca','capath','verify-client-cert','client-cert-not-required'}]
            lines.extend(['verify-client-cert require', f'ca {ca}'])
        path.write_text("\n".join(lines) + "\n")


def verify_runtime_config(instance, socket_path, settings=None):
    path = pathlib.Path(f"/etc/openvpn/server/iptunnel-{instance}.conf")
    lines = [shlex.split(line, comments=True) for line in path.read_text().splitlines()]
    for directive in required_directives(socket_path):
        wanted = shlex.split(directive)
        if [line for line in lines if line and line[0] == wanted[0]] != [wanted]:
            raise RuntimeError("managed OpenVPN configuration mismatch")
    forbidden = {"config", "auth-user-pass-optional", "auth-gen-token", "management-client",
                 "client-connect", "client-disconnect", "plugin", "auth-user-pass-verify"}
    if any(line and line[0] in forbidden for line in lines):
        raise RuntimeError("conflicting OpenVPN authentication configuration")
    if settings and settings.get('openvpn_device_certificates'):
        for wanted in (['verify-client-cert', 'require'], ['ca', settings['client_ca_certificate']]):
            if [line for line in lines if line and line[0] == wanted[0]] != [wanted]:
                raise RuntimeError('managed client certificate policy mismatch')
        if any(line and line[0] in {'client-cert-not-required', '<ca>', 'capath'} for line in lines):
            raise RuntimeError('alternate client certificate policy')


class Management:
    def __init__(self, store, instance, sock):
        self.store, self.instance, self.sock = store, instance, sock
        self.buffer = b""
        self.event = None
        self.env = {}
        self.bootstrap = True
        self.auth_replies = 0

    def send(self, command):
        self.sock.sendall((command + "\n").encode())

    def line(self, deadline):
        while b"\n" not in self.buffer:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([self.sock], [], [], remaining)[0]:
                raise TimeoutError("management response timeout")
            data = self.sock.recv(65536)
            if not data:
                raise ConnectionError("management disconnected")
            self.buffer += data
            if len(self.buffer) > 262144:
                raise RuntimeError("oversized management line")
        raw, self.buffer = self.buffer.split(b"\n", 1)
        return raw.decode("utf-8", "strict").rstrip("\r")

    def event_line(self, line):
        if not line.startswith(">"):
            return False
        if line.startswith(">CLIENT:ENV,"):
            item = line[len(">CLIENT:ENV,"):]
            if item == "END":
                self.finish_event()
            elif self.event and "=" in item:
                key, value = item.split("=", 1)
                if key in {"username", "password", "X509_0_CN"}:
                    self.env[key] = value
        elif line.startswith(">CLIENT:"):
            fields = line[len(">CLIENT:"):].split(",")
            if fields[0] in {"CONNECT", "REAUTH", "ESTABLISHED", "DISCONNECT"}:
                if len(fields) < 2 or not re.fullmatch(r"[0-9]{1,10}", fields[1]):
                    raise RuntimeError("invalid client id")
                if fields[0] in {"CONNECT", "REAUTH"} and (len(fields) != 3 or not re.fullmatch(r"[0-9]{1,10}", fields[2])):
                    raise RuntimeError("invalid key id")
                self.event, self.env = fields, {}
        return True

    def finish_event(self):
        event, env = self.event, self.env
        self.event, self.env = None, {}
        if not event:
            return
        kind, cid = event[:2]
        if kind in {"CONNECT", "REAUTH"}:
            allow = not self.bootstrap and self.store.authorize(
                self.instance, cid, env.get("username", ""), env.get("password", ""), env.get("X509_0_CN"))
            env.clear()
            command = (f"client-auth-nt {cid} {event[2]}" if allow else
                       f'client-deny {cid} {event[2]} "managed_auth_denied"')
            # Commands sent from async notifications can precede a polling reply.
            self.send(command)
            self.auth_replies += 1
        elif kind == "ESTABLISHED":
            self.store.established(self.instance, cid)
        elif kind == "DISCONNECT":
            self.store.disconnected(self.instance, cid)

    def reply(self, deadline):
        while True:
            line = self.line(deadline)
            if not self.event_line(line):
                # Authentication replies are identifiable, not interchangeable
                # with client-kill replies that prove revocation.
                if line.startswith(("SUCCESS: client-auth", "SUCCESS: client-deny")):
                    self.auth_replies = max(0, self.auth_replies - 1)
                    continue
                if line.startswith("ERROR:"):
                    raise RuntimeError("management command rejected")
                return line

    def status(self):
        self.send("status 3")
        deadline = time.monotonic() + 5
        cids = set()
        header = None
        while True:
            line = self.reply(deadline)
            if line == "END":
                if header is None:
                    raise RuntimeError("missing management status header")
                return cids
            parts = line.split("\t")
            if parts[:2] == ["HEADER", "CLIENT_LIST"]:
                header = parts[2:]
                if "Client ID" not in header:
                    raise RuntimeError("OpenVPN client IDs unavailable")
            elif parts[0] == "CLIENT_LIST":
                if header is None or len(parts) != len(header) + 1:
                    raise RuntimeError("invalid management client row")
                cid = parts[1 + header.index("Client ID")]
                if not re.fullmatch(r"[0-9]{1,10}", cid):
                    raise RuntimeError("invalid management client id")
                cids.add(cid)

    def kill(self, cid):
        self.send(f"client-kill {cid}")
        deadline = time.monotonic() + 5
        while True:
            reply = self.reply(deadline)
            if reply.startswith("SUCCESS: client-kill"):
                self.store.disconnected(self.instance, cid)
                return
            if reply.startswith("SUCCESS:"):
                continue
            raise RuntimeError("unconfirmed client disconnect")

    def run(self, check_config):
        self.store.heartbeat(self.instance, False)
        # management-signal resets tunnels when this connection is lost; hold
        # prevents new tunnels during startup. Also drain on first attachment.
        self.send("hold release")
        startup_deadline = time.monotonic() + 20
        while True:
            try:
                cids = self.status()
            except RuntimeError as exc:
                if str(exc) != "missing management status header" or time.monotonic() >= startup_deadline:
                    raise
                time.sleep(0.25)
                continue
            if not cids:
                break
            for cid in sorted(cids, key=int):
                self.kill(cid)
        self.store.reset_instance(self.instance)
        self.bootstrap = False
        while True:
            check_config()
            cids = self.status()
            for cid in self.store.reconcile(self.instance, cids):
                self.kill(cid)
            self.store.heartbeat(self.instance, True)
            # Consume authentication events promptly, not only every poll.
            until = time.monotonic() + 1
            while time.monotonic() < until:
                if b"\n" not in self.buffer and not select.select([self.sock], [], [], max(0, until - time.monotonic()))[0]:
                    break
                line = self.line(time.monotonic() + 5)
                if not self.event_line(line) and line.startswith("ERROR:"):
                    raise RuntimeError("management authentication command rejected")


def worker(config_path, settings, instance, socket_path):
    while True:
        store = None
        try:
            config = json.loads(pathlib.Path(config_path).read_text())
            if configuration(config) != settings:
                raise RuntimeError("configuration changed; restart monitor")
            store = CredentialStore(config)
            store.heartbeat(instance, False)
            verify_runtime_config(instance, socket_path, settings)
            parent = pathlib.Path(socket_path).parent.stat()
            node = pathlib.Path(socket_path).stat()
            if parent.st_uid != 0 or parent.st_mode & 0o077 or node.st_uid != 0 or not stat.S_ISSOCK(node.st_mode):
                raise RuntimeError("management socket must be root-owned in private directory")
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
                sock.settimeout(5)
                sock.connect(socket_path)

                def check_config():
                    current = json.loads(pathlib.Path(config_path).read_text())
                    if configuration(current) != settings or current.get("provisioning", {}).get("db_path") != config.get("provisioning", {}).get("db_path"):
                        raise RuntimeError("configuration changed; restart monitor")
                    verify_runtime_config(instance, socket_path, settings)

                Management(store, instance, sock).run(check_config)
        except Exception:
            # Never log management lines, auth environment or exception payloads.
            if store:
                try:
                    store.heartbeat(instance, False)
                except Exception:
                    pass
            print(f"provisioning monitor {instance}: unavailable; retrying", flush=True)
            time.sleep(3)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", default="/etc/iptunnel/config.json")
    parser.add_argument("--configure-directory")
    parser.add_argument("--profile")
    args = parser.parse_args()
    config = json.loads(pathlib.Path(args.config).read_text())
    if args.configure_directory or args.profile:
        configure(config, args.configure_directory, args.profile)
        return
    if os.name != "posix" or os.geteuid() != 0:
        raise SystemExit("monitor requires root on Linux")
    settings = configuration(config)
    import fcntl
    with open("/run/iptunnel-provisioning/monitor.lock", "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        threads = []
        for instance, socket_path in settings["openvpn_management"].items():
            thread = threading.Thread(target=worker, args=(args.config, settings, instance, socket_path))
            thread.start()
            threads.append(thread)
        for thread in threads:
            thread.join()


if __name__ == "__main__":
    main()
PROVISIONING_MONITOR
chmod 644 /opt/iptunnel/device_credentials.py /opt/iptunnel/provisioning_monitor.py
cat >/etc/systemd/system/iptunnel-provisioning.service <<'PROVISIONING_SERVICE'
[Unit]
Description=IPTunnel managed OpenVPN session monitor
After=network.target

[Service]
Type=simple
User=root
Group=root
UMask=0077
ExecStart=/usr/bin/python3 /opt/iptunnel/provisioning_monitor.py
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=/var/lib/iptunnel-provisioning /run/iptunnel-provisioning

[Install]
WantedBy=multi-user.target
PROVISIONING_SERVICE
install -d -m 700 /var/lib/iptunnel-provisioning /run/iptunnel-provisioning
cat >/etc/tmpfiles.d/iptunnel-provisioning.conf <<'PROVISIONING_TMPFILES'
d /run/iptunnel-provisioning 0700 root root -
d /var/lib/iptunnel-provisioning 0700 root root -
PROVISIONING_TMPFILES
# Deliberately do not enable/start provisioning: explicit managed activation only.

cat >/usr/local/bin/iptunnel-menu <<'MENU'
#!/usr/bin/env bash
set -euo pipefail

CONFIG_PATH="${IPTUNNEL_CONFIG:-/etc/iptunnel/config.json}"
API_SCHEME="${IPTUNNEL_API_SCHEME:-http}"
API_HOST="${IPTUNNEL_API_HOST:-127.0.0.1}"
API_BASE="${IPTUNNEL_API_BASE:-}"
API_KEY="${IPTUNNEL_API_KEY:-}"
API_PORT=""
DOMAIN=""
PUBLIC_IP=""
API_RESPONSE=""
API_STATUS=""
PROTOCOL_KEY=""
PROTOCOL_LABEL=""
POST_ACTION_PAUSE="1"

# ══════════════════════════════════════════════════════════════════════
#  THEME — Dark, clean, minimal. Matches the web admin panel.
# ══════════════════════════════════════════════════════════════════════

# Colors
C_BG=$'\033[0m'
C_BOLD=$'\033[1m'
C_DIM=$'\033[2m'
C_RESET=$'\033[0m'
C_RED=$'\033[38;5;210m'
C_GREEN=$'\033[38;5;114m'
C_YELLOW=$'\033[38;5;222m'
C_BLUE=$'\033[38;5;110m'
C_CYAN=$'\033[38;5;116m'
C_PURPLE=$'\033[38;5;183m'
C_MUTED=$'\033[38;5;243m'
C_WHITE=$'\033[38;5;255m'
C_SURFACE=$'\033[38;5;238m'
MENU_VERSION="2026.09.06.1"

# Box width (inner content)
W=68

# ── Drawing primitives ───────────────────────────────────────────────

_rep() { local i s=""; for ((i=0;i<$1;i++)); do s="${s}${2}"; done; printf '%s' "$s"; }

# Horizontal rule
hr() { printf '  %s%s%s\n' "$C_SURFACE" "$(_rep $W '─')" "$C_RESET"; }

# Section header — styled block
section() {
  local title="$1"
  echo
  printf '  %s%s %s %s\n' "$C_BOLD" "$C_BLUE" "$title" "$C_RESET"
  printf '  %s%s%s\n' "$C_SURFACE" "$(_rep ${#title} '━')" "$C_RESET"
}

# Subsection label
label() {
  printf '  %s%s%s\n' "$C_MUTED" "$1" "$C_RESET"
}

# Menu item — number + title + optional description
mi() {
  local num="$1" title="$2" desc="${3:-}"
  if [[ -n "$desc" ]]; then
    printf '  %s[%s%s%s]%s  %-24s %s%s%s\n' "$C_SURFACE" "$C_BLUE" "$num" "$C_SURFACE" "$C_RESET" "$title" "$C_MUTED" "$desc" "$C_RESET"
  else
    printf '  %s[%s%s%s]%s  %s\n' "$C_SURFACE" "$C_BLUE" "$num" "$C_SURFACE" "$C_RESET" "$title"
  fi
}

# Status indicator
_dot() {
  if [[ "$1" == "1" ]]; then
    printf '%s●%s' "$C_GREEN" "$C_RESET"
  else
    printf '%s○%s' "$C_RED" "$C_RESET"
  fi
}

_status_label() {
  if [[ "$1" == "1" ]]; then
    printf '%senabled%s' "$C_GREEN" "$C_RESET"
  else
    printf '%sdisabled%s' "$C_MUTED" "$C_RESET"
  fi
}

_blocked_label() {
  if [[ "$1" == "1" ]]; then
    printf '%sblocked%s' "$C_RED" "$C_RESET"
  else
    printf '%sallowed%s' "$C_GREEN" "$C_RESET"
  fi
}

dot_ok()  { printf '%s✔%s' "$C_GREEN" "$C_RESET"; }
dot_err() { printf '%s✘%s' "$C_RED" "$C_RESET"; }

# Prompt — writes to /dev/tty so command substitutions only capture the answer
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
  local prompt="$1" reply=""
  if [[ -e /dev/tty ]]; then
    printf '  %s%s%s: ' "$C_MUTED" "$prompt" "$C_RESET" > /dev/tty
    IFS= read -r reply < /dev/tty
  else
    printf '  %s%s%s: ' "$C_MUTED" "$prompt" "$C_RESET"
    IFS= read -r reply
  fi
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

# ══════════════════════════════════════════════════════════════════════
#  BANNER
# ══════════════════════════════════════════════════════════════════════

print_banner() {
  clear
  echo
  printf '  %s%s╔══════════════════════════════════════════════════════════════════════╗%s\n' "$C_BOLD" "$C_BLUE" "$C_RESET"
  printf '  %s%s║%s                                                                    %s%s║%s\n' "$C_BOLD" "$C_BLUE" "$C_RESET" "" "$C_BLUE" "$C_RESET"
  printf '  %s%s║%s     %s██╗%s%s██████╗%s %s████████╗%s%s██╗   ██╗%s%s███╗   ██╗%s%s███╗   ██╗%s%s███████╗%s%s██╗%s     %s%s║%s\n' \
    "$C_BOLD" "$C_BLUE" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_BLUE" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_BLUE" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_BLUE" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_BLUE" "$C_RESET" "$C_BLUE" "$C_RESET"
  printf '  %s%s║%s     %s██║%s%s██╔══██╗%s%s╚══██╔══╝%s%s██║   ██║%s%s████╗  ██║%s%s████╗  ██║%s%s██╔════╝%s%s██║%s     %s%s║%s\n' \
    "$C_BOLD" "$C_BLUE" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_BLUE" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_BLUE" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_BLUE" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_BLUE" "$C_RESET" "$C_BLUE" "$C_RESET"
  printf '  %s%s║%s     %s██║%s%s██████╔╝%s%s   ██║   %s%s██║   ██║%s%s██╔██╗ ██║%s%s██╔██╗ ██║%s%s█████╗  %s%s██║%s     %s%s║%s\n' \
    "$C_BOLD" "$C_BLUE" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_BLUE" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_BLUE" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_BLUE" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_BLUE" "$C_RESET" "$C_BLUE" "$C_RESET"
  printf '  %s%s║%s     %s██║%s%s██╔═══╝ %s%s   ██║   %s%s██║   ██║%s%s██║╚██╗██║%s%s██║╚██╗██║%s%s██╔══╝  %s%s██║%s     %s%s║%s\n' \
    "$C_BOLD" "$C_BLUE" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_BLUE" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_BLUE" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_BLUE" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_BLUE" "$C_RESET" "$C_BLUE" "$C_RESET"
  printf '  %s%s║%s     %s██║%s%s██║     %s%s   ██║   %s%s╚██████╔╝%s%s██║ ╚████║%s%s██║ ╚████║%s%s███████╗%s%s███████╗%s %s%s║%s\n' \
    "$C_BOLD" "$C_BLUE" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_BLUE" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_BLUE" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_BLUE" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_BLUE" "$C_RESET" "$C_BLUE" "$C_RESET"
  printf '  %s%s║%s     %s╚═╝%s%s╚═╝     %s%s   ╚═╝   %s%s ╚═════╝ %s%s╚═╝  ╚═══╝%s%s╚═╝  ╚═══╝%s%s╚══════╝%s%s╚══════╝%s %s%s║%s\n' \
    "$C_BOLD" "$C_BLUE" "$C_RESET" "$C_MUTED" "$C_RESET" "$C_MUTED" "$C_RESET" "$C_MUTED" "$C_RESET" "$C_MUTED" "$C_RESET" "$C_MUTED" "$C_RESET" "$C_MUTED" "$C_RESET" "$C_MUTED" "$C_RESET" "$C_MUTED" "$C_RESET" "$C_BLUE" "$C_RESET"
  printf '  %s%s║%s                                                                    %s%s║%s\n' "$C_BOLD" "$C_BLUE" "$C_RESET" "$C_BLUE" "" "$C_RESET"
  printf '  %s%s╚══════════════════════════════════════════════════════════════════════╝%s\n' "$C_BOLD" "$C_BLUE" "$C_RESET"
  echo
}

print_header() {
  print_banner

  # Server info bar
  printf '  %s┌─────────────────────────────────────────────────────────────────────┐%s\n' "$C_SURFACE" "$C_RESET"
  printf '  %s│%s  %-10s %s%-28s%s  %-8s %s%-17s%s  %s│%s\n' \
    "$C_SURFACE" "$C_RESET" \
    "Domain" "$C_WHITE" "${DOMAIN:-unknown}" "$C_RESET" \
    "IP" "$C_CYAN" "${PUBLIC_IP:-unknown}" "$C_RESET" \
    "$C_SURFACE" "$C_RESET"
  printf '  %s│%s  %-10s %s%-56s%s%s│%s\n' \
    "$C_SURFACE" "$C_RESET" \
    "API" "$C_MUTED" "${API_BASE}" "$C_RESET" \
    "$C_SURFACE" "$C_RESET"
  printf '  %s└─────────────────────────────────────────────────────────────────────┘%s\n' "$C_SURFACE" "$C_RESET"
}

# ══════════════════════════════════════════════════════════════════════
#  UTILITIES
# ══════════════════════════════════════════════════════════════════════

need_commands() {
  command -v curl    >/dev/null 2>&1 || { echo "curl is required";    exit 1; }
  command -v python3 >/dev/null 2>&1 || { echo "python3 is required"; exit 1; }
}

load_config() {
  [[ -f "$CONFIG_PATH" ]] || { echo "IPTunnel config not found at $CONFIG_PATH"; exit 1; }

  local cfg=()
  mapfile -t cfg < <(python3 - "$CONFIG_PATH" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
print(c.get("port", 8080))
print(c.get("api_key", ""))
print(c.get("hostname", "localhost"))
print(c.get("public_ip", ""))
PY
  )

  API_PORT="${cfg[0]:-8080}"
  [[ -z "$API_KEY" ]] && API_KEY="${cfg[1]:-}"
  DOMAIN="${cfg[2]:-localhost}"
  PUBLIC_IP="${cfg[3]:-}"
  [[ -n "$API_BASE" ]] || API_BASE="${API_SCHEME}://${API_HOST}:${API_PORT}"
  [[ -n "$API_KEY" ]] || { echo "API key missing. Set IPTUNNEL_API_KEY or fix $CONFIG_PATH"; exit 1; }
}

ensure_api_base() {
  [[ -n "$API_PORT" && -n "$API_KEY" ]] || load_config

  if [[ -z "${API_BASE:-}" ]]; then
    API_BASE="${API_SCHEME}://${API_HOST}:${API_PORT}"
  elif [[ "$API_BASE" != http://* && "$API_BASE" != https://* ]]; then
    if [[ "$API_BASE" == /* ]]; then
      API_BASE=""
    else
      API_BASE="${API_SCHEME}://${API_BASE}"
    fi
  fi

  API_BASE="${API_BASE%/}"
  if [[ ! "$API_BASE" =~ ^https?://[^/]+$ ]]; then
    API_BASE=""
    return 1
  fi

  return 0
}

build_api_url() {
  local path="$1" base host_part
  ensure_api_base || return 1
  base="${API_BASE//$'\r'/}"
  base="${base//$'\n'/}"
  base="${base%/}"
  [[ "$path" == /* ]] || path="/${path}"
  if [[ ! "$base" =~ ^https?://[^/]+$ ]]; then
    return 1
  fi
  printf '%s%s\n' "$base" "$path"
}

api_curl_noproxy_args() {
  # The menu only ever talks to this machine's own iptunnel API, so it must
  # never be routed through an http_proxy/https_proxy set in the environment.
  # A configured public IP/domain base (or a leaked proxy env var) would
  # otherwise send the request to an intercepting proxy (e.g. Squid), which
  # rejects it with ERR_INVALID_URL / HTTP 400. Disable proxying for all hosts.
  printf '%s\n' "--noproxy" "*"
}

api_response_is_squid_invalid_url() {
  local body="$1"
  [[ "$body" == *"ERR_INVALID_URL"* && "$body" == *"Squid"* ]]
}

force_local_api_base() {
  API_BASE="http://127.0.0.1:${API_PORT:-8080}"
}

configured_services() {
  python3 - "$CONFIG_PATH" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
svcs = ["iptunnel-api","iptunnel-ssh-ws","iptunnel-ssh-ssl","iptunnel-vmess",
        "iptunnel-vless","iptunnel-trojan","iptunnel-slowdns","iptunnel-slowdns-target",
        "iptunnel-edge-proxy",
        "nginx","dropbear","ssh"]
h = c.get("hysteria") or {}
if h.get("enabled"):
    svcs += ["iptunnel-hysteria","hysteria-server"]
p = (c.get("ssh") or {}).get("ports") or {}
if str(p.get("ovpntcp","-")) != "-" or str(p.get("ovpnudp","-")) != "-":
    svcs += ["openvpn-server@iptunnel-tcp","openvpn-server@iptunnel-udp"]
[print(s) for s in svcs]
PY
}

transport_module_state() {
  python3 - "$CONFIG_PATH" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
h = c.get("hysteria") or {}
p = (c.get("ssh") or {}).get("ports") or {}
slowdns = c.get("slowdns") or {}
openvpn = c.get("openvpn") or {}
udp53_mode = str(slowdns.get("udp53_mode", "slowdns") or "slowdns")
ovpn_enabled = bool(openvpn.get("enabled", False))
raw_ports = openvpn.get("udp_public_ports")
if isinstance(raw_ports, str):
    candidates = raw_ports.split(",")
elif isinstance(raw_ports, list):
    candidates = raw_ports
else:
    candidates = []
if not candidates and openvpn.get("udp_public_port") not in {None, "", "-"}:
    candidates = [openvpn.get("udp_public_port")]
ports = []
for candidate in candidates:
    try:
        port = int(str(candidate).strip())
    except (TypeError, ValueError):
        continue
    if 1 <= port <= 65535 and port not in ports:
        ports.append(port)
if udp53_mode in {"openvpn", "shared"}:
    ports = [53, *[port for port in ports if port != 53]]
else:
    ports = [port for port in ports if port != 53]
ovpn_udp_port = ",".join(str(port) for port in ports) if ovpn_enabled and ports else "-"
print("1" if h.get("enabled") else "0")
print(str(p.get("ovpntcp","-")))
print(ovpn_udp_port)
print(udp53_mode)
print(ovpn_udp_port)
print("1" if slowdns.get("enabled", True) else "0")
try:
    mtu = int(slowdns.get("mtu") or 1232)
except (TypeError, ValueError):
    mtu = 1232
print(mtu)
PY
}

domain_state() {
  python3 - "$CONFIG_PATH" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
s = c.get("slowdns") or {}
host = c.get("hostname", "")
print(host)
print(s.get("tunnel_domain", "") or ("dns." + host if host else ""))
PY
}

run_transport_action() {
  IPTUNNEL_CONFIG_PATH="$CONFIG_PATH" /opt/iptunnel/transport_stack.sh "$1"
}

# ══════════════════════════════════════════════════════════════════════
#  API HELPERS
# ══════════════════════════════════════════════════════════════════════

json_message() {
  PAYLOAD="$1" python3 - <<'PY'
import json, os
raw = os.environ.get("PAYLOAD", "")
if not raw: raise SystemExit(0)
try: payload = json.loads(raw)
except Exception: raise SystemExit(0)
if isinstance(payload, dict):
    error = payload.get("error")
    if isinstance(error, dict) and error.get("message"):
        print(str(error.get("message", "")))
        raise SystemExit(0)
    meta = payload.get("meta")
    if isinstance(meta, dict) and meta.get("message"):
        print(str(meta.get("message", "")))
        raise SystemExit(0)
    if "status" in payload and len(payload) == 1:
        print(str(payload.get("status", "")))
PY
}

json_data_field() {
  PAYLOAD="$1" FIELD="$2" python3 - <<'PY'
import json, os
raw = os.environ.get("PAYLOAD", "")
field = os.environ.get("FIELD", "")
if not raw or not field:
    raise SystemExit(0)
try:
    payload = json.loads(raw)
except Exception:
    raise SystemExit(0)
if isinstance(payload, dict) and {"data", "meta", "error"}.issubset(payload.keys()):
    payload = payload.get("data")
if not isinstance(payload, dict):
    raise SystemExit(0)
value = payload.get(field)
if isinstance(value, bool):
    print("true" if value else "false")
elif value is None:
    print("")
else:
    print(str(value))
PY
}

render_api_body() {
  PAYLOAD="$1" python3 - <<'PY'
import json, os
raw = os.environ.get("PAYLOAD", "")
if not raw: raise SystemExit(0)
try: payload = json.loads(raw)
except Exception: print(raw); raise SystemExit(0)

def titleize(value):
    text = str(value).replace("_", " ").strip()
    if not text:
        return ""
    return text[:1].upper() + text[1:]

def scalar(value):
    if isinstance(value, bool):
        return "yes" if value else "no"
    if isinstance(value, list):
        return ",".join(str(item) for item in value)
    if value is None:
        return "-"
    return str(value)

def print_rows(rows, indent=2):
    rows = [(label, value) for label, value in rows if value not in ("", None)]
    if not rows:
        return False
    pad = " " * indent
    width = max(len(label) for label, _ in rows)
    for label, value in rows:
        print(f"{pad}{label:<{width}} : {scalar(value)}")
    return True

def print_subsection(title, indent=2):
    pad = " " * indent
    line = "-" * max(8, len(title))
    print(f"{pad}{title}")
    print(f"{pad}{line}")

def print_dict_rows(mapping, indent=4, preferred=None, rename=None, skip_values=None):
    if not isinstance(mapping, dict):
        return False
    rename = rename or {}
    skip = {"", None}
    if skip_values:
        skip.update(skip_values)
    rows = []
    seen = set()
    for key in preferred or []:
        if key in mapping:
            value = mapping.get(key)
            if value not in skip:
                rows.append((rename.get(key, titleize(key)), value))
            seen.add(key)
    for key, value in mapping.items():
        if key in seen or value in skip:
            continue
        rows.append((rename.get(key, titleize(key)), value))
    return print_rows(rows, indent=indent)

def print_list_rows(label, value, indent=4):
    if value in ("", None, []):
        return False
    items = value if isinstance(value, list) else [part.strip() for part in str(value).split(",") if part.strip()]
    if not items:
        return False
    print(" " * indent + f"{label}:")
    for item in items:
        print(" " * (indent + 2) + f"- {item}")
    return True

def print_protocol_paths(title, path_info, indent=2):
    if not isinstance(path_info, dict) or not path_info:
        return False
    print_subsection(title, indent=indent)
    rename = {
        "primary": "Primary path",
        "grpc": "gRPC service",
        "multi": "Multi path",
        "stn": "STN path",
        "up": "Upgrade path",
    }
    rendered = False
    for key in ("vmess", "vless", "trojan"):
        block = path_info.get(key)
        if not isinstance(block, dict):
            continue
        print(" " * (indent + 2) + titleize(key))
        print(" " * (indent + 2) + "~" * max(5, len(titleize(key))))
        print_dict_rows(block, indent=indent + 4, preferred=["primary", "grpc", "multi", "stn", "up"], rename=rename)
        print()
        rendered = True
    return rendered

def update_status_label(value):
    mapping = {
        "up_to_date": "Up to date",
        "update_available": "Update available",
        "local_ahead": "Installed build is newer",
        "unavailable": "Update server unavailable",
        "unknown": "Unable to compare versions",
    }
    return mapping.get(str(value), titleize(value))

def render_update(obj):
    rows = [
        ("Installed version", obj.get("installed")),
        ("Latest version", obj.get("remote") or "-"),
        ("Status", update_status_label(obj.get("status"))),
        ("Manifest URL", obj.get("url")),
        ("Installer URL", obj.get("installer_url")),
    ]
    printed = print_rows(rows)
    notes = str(obj.get("notes") or "").strip()
    error = str(obj.get("error") or "").strip()
    if notes:
        if printed:
            print()
        print("  Release notes")
        print("  -------------")
        print(f"  {notes}")
    if error:
        if printed or notes:
            print()
        print("  Error")
        print("  -----")
        print(f"  {error}")

def render_certificate(obj):
    state = "Ready"
    if not obj.get("installed"):
        state = "Not installed"
    elif obj.get("reinstalled"):
        state = "Reinstalled"
    elif obj.get("already_installed"):
        state = "Already installed"
    rows = [
        ("Domain", obj.get("domain")),
        ("State", state),
        ("Installed", obj.get("installed")),
        ("Active", obj.get("active")),
        ("Issuer", obj.get("issuer")),
        ("Valid from", obj.get("valid_from")),
        ("Valid until", obj.get("valid_until")),
        ("Days remaining", obj.get("days_remaining")),
        ("Certificate", obj.get("certificate_path")),
        ("Private key", obj.get("private_key_path")),
        ("Stunnel bundle", obj.get("stunnel_bundle_path")),
        ("Live directory", obj.get("live_directory")),
    ]
    print_rows(rows)

def render_action_result(obj):
    print_subsection("Result")
    rows = []
    if "status" in obj:
        rows.append(("Status", obj.get("status")))
    if "username" in obj:
        rows.append(("Username", obj.get("username")))
    if "from" in obj:
        rows.append(("Previous expiry", obj.get("from")))
    if "to" in obj:
        rows.append(("New expiry", obj.get("to")))
    if "version" in obj:
        rows.append(("Version", obj.get("version")))
    if "remote" in obj:
        rows.append(("Latest version", obj.get("remote")))
    if "quota" in obj:
        rows.append(("Quota", obj.get("quota")))
    if "status_lock" in obj:
        rows.append(("Lock state", obj.get("status_lock")))
    if "expired" in obj:
        rows.append(("Expires on", obj.get("expired")))
    if "pass_uuid" in obj:
        rows.append(("Secret", obj.get("pass_uuid")))
    if "installer_url" in obj:
        rows.append(("Installer URL", obj.get("installer_url")))
    if "installer_cache" in obj:
        rows.append(("Installer cache", obj.get("installer_cache")))
    if "log" in obj:
        rows.append(("Log file", obj.get("log")))
    if "update_unit" in obj:
        rows.append(("Update unit", obj.get("update_unit")))
    if "notes" in obj:
        rows.append(("Notes", obj.get("notes")))
    if "message" in obj:
        rows.append(("Result", obj.get("message")))
    print_rows(rows)

def render_transport_result(obj):
    name = titleize(obj.get("transport") or "transport")
    print_subsection(name)
    openvpn = obj.get("openvpn") or {}
    rows = [
        ("State", "enabled" if obj.get("enabled") is True else "disabled" if obj.get("enabled") is False else obj.get("status")),
        ("UDP53 mode", obj.get("udp53_mode")),
        ("OpenVPN UDP ports", obj.get("udp_public_ports") or openvpn.get("udp_public_ports") or obj.get("udp_public_port") or openvpn.get("udp_public_port")),
    ]
    if isinstance(obj.get("ports"), dict):
        ports = obj.get("ports") or {}
        rows.extend([
            ("TCP port", ports.get("tcp")),
            ("UDP ports", ports.get("udp")),
        ])
    profiles = (openvpn.get("profiles") or {}) if isinstance(openvpn, dict) else {}
    if isinstance(profiles, dict):
        def profile_url(profile):
            if not isinstance(profile, dict) or not profile:
                return None
            url = profile.get("url_https") or profile.get("url_http")
            if profile.get("exists") is False:
                return f"missing file: {profile.get('path') or profile.get('file')}"
            return url

        active_udp_profile = profiles.get("active_udp") or {}
        tcp_profile = profiles.get("tcp") or {}
        udp_profile = profiles.get("udp") or {}
        rows.extend([
            ("Active UDP profile", profile_url(active_udp_profile)),
            ("UDP config port", active_udp_profile.get("port") or udp_profile.get("port")),
            ("TCP profile", profile_url(tcp_profile)),
        ])
        udp_profiles = openvpn.get("udp_profiles") or []
        if isinstance(udp_profiles, list) and udp_profiles:
            for profile in udp_profiles:
                if isinstance(profile, dict):
                    label = profile.get("label") or f"UDP {profile.get('port')}"
                    rows.append((f"{label} profile", profile_url(profile)))
        elif udp_profile:
            rows.append(("UDP profile", profile_url(udp_profile)))
    print_rows(rows)

def render_domain_result(obj):
    print_subsection("Domain Settings")
    rows = [
        ("A record domain", obj.get("hostname") or obj.get("public_hostname")),
        ("NS record", obj.get("tunnel_domain")),
        ("Public IP", obj.get("public_ip")),
    ]
    print_rows(rows)
    records = obj.get("records") or []
    if records:
        print()
        print_subsection("DNS Records")
        for item in records:
            if not isinstance(item, dict):
                continue
            print(f"    {item.get('type', '-'):<4} {item.get('name', '-')} -> {item.get('value', '-')}")

def render_account_rows(account):
    print_subsection("Account")
    rows = [
        ("Username", account.get("username")),
        ("Expires on", account.get("expires_on")),
        ("Days", account.get("days")),
        ("IP limit", account.get("limit_ip")),
        ("Trial", account.get("trial")),
        ("Locked", account.get("locked")),
        ("Status", account.get("status")),
        ("Lock state", account.get("status_lock")),
        ("Used bandwidth", account.get("used_human")),
        ("Quota", account.get("max_human")),
        ("Type", account.get("type")),
        ("Protocol", account.get("protocol")),
    ]
    print_rows(rows)

def render_account_config(protocol, config):
    protocol_name = str(protocol or "").lower()
    port_names = {
        "ssh": "SSH",
        "dropbear": "Dropbear",
        "ssl": "SSL",
        "ws": "WebSocket",
        "slowdns": "SlowDNS",
        "squid": "Squid",
        "hysteria": "Hysteria",
        "ovpntcp": "OpenVPN TCP",
        "ovpnudp": "OpenVPN UDP",
        "ovpnohp": "OpenVPN OHP",
        "any": "All open ports",
    }
    rows = [
        ("Protocol", str(protocol or "").upper()),
        ("Hostname", config.get("hostname")),
        ("Username", config.get("username")),
        ("Password", config.get("password")),
        ("UUID", config.get("uuid")),
        ("Expires on", config.get("exp") or config.get("expired")),
    ]
    print_subsection("Connection")
    printed = print_rows(rows)

    payloadws = config.get("payloadws") or {}
    ssh_ports = config.get("port") or {}
    if protocol_name in {"ssh", "sshvpn"} and (payloadws or ssh_ports):
        if printed:
            print()
        print_subsection("SSH Access")
        if ssh_ports:
            print("    Ports")
            print("    -----")
            print_dict_rows(
                ssh_ports,
                indent=6,
                preferred=["ssh", "dropbear", "ssl", "ws", "slowdns", "squid", "hysteria", "ovpntcp", "ovpnudp", "ovpnohp", "any"],
                rename=port_names,
                skip_values={"", None, "-"},
            )
            print()
        ws_rows = [
            ("Primary WS path", payloadws.get("path")),
            ("CDN payload", payloadws.get("payloadcdn")),
            ("Upgrade payload", payloadws.get("payloadwithpath")),
            ("Root WS ports", payloadws.get("root_compat_port")),
            ("Root WS payload", payloadws.get("payloadrootcompat")),
        ]
        if any(value not in ("", None) for _, value in ws_rows) or payloadws.get("paths"):
            print("    WebSocket")
            print("    ---------")
            print_rows(ws_rows, indent=6)
            print_list_rows("Aliases", payloadws.get("paths"), indent=6)

    slowdns = config.get("slowdns") or {}
    if slowdns:
        print()
        print_subsection("SlowDNS")
        print_rows(
            [
                ("Public host", slowdns.get("public_hostname") or slowdns.get("ns_host")),
                ("Nameserver host", slowdns.get("ns_host")),
                ("Tunnel domain", slowdns.get("tunnel_domain")),
                ("Public port", slowdns.get("public_port") or slowdns.get("listen_port")),
                ("Listen port", slowdns.get("listen_port")),
                ("Target", slowdns.get("target")),
                ("Public key", slowdns.get("public_key")),
            ],
            indent=4,
        )

    path_info = config.get("path") or {}
    xray_ports = config.get("port") or {}
    links = config.get("link") or {}
    if protocol_name not in {"ssh", "sshvpn"} and (path_info or links or xray_ports):
        if printed:
            print()
        print_subsection("Transport")
        if xray_ports:
            print("    Ports")
            print("    -----")
            print_dict_rows(
                xray_ports,
                indent=6,
                preferred=["tls", "none", "ws", "grpc", "slowdns", "ssh", "dropbear", "ssl", "any"],
                rename={
                    "tls": "TLS",
                    "none": "Non-TLS",
                    "ws": "WebSocket",
                    "grpc": "gRPC",
                    "slowdns": "SlowDNS",
                    "ssh": "SSH",
                    "dropbear": "Dropbear",
                    "ssl": "SSL",
                    "any": "All open ports",
                },
                skip_values={"", None, "-"},
            )
            print()
        if path_info:
            print_protocol_paths("Paths", path_info, indent=4)
        if links:
            print()
            print_subsection("Links")
            print_rows(
                [
                    ("TLS WS", links.get("tls")),
                    ("NTLS WS", links.get("none")),
                    ("gRPC", links.get("grpc")),
                    ("Upgrade TLS", links.get("uptls")),
                    ("Upgrade NTLS", links.get("upntls")),
                ],
                indent=4,
            )

def unwrap(value):
    if isinstance(value, dict) and {"data", "meta", "error"}.issubset(value.keys()):
        error = value.get("error")
        if isinstance(error, dict) and error:
            width = max(len(str(k)) for k in error)
            for key, item in error.items():
                print(f"  {str(key):<{width}} : {item}")
            raise SystemExit(0)
        value = value.get("data")
    if isinstance(value, dict) and set(value.keys()) == {"status"}:
        print(f"  Status : {scalar(value['status'])}")
        raise SystemExit(0)
    return value

def print_block(obj, indent=2, heading=None):
    pad = " " * indent
    if heading:
        print(f"{pad}{titleize(heading)}")
        print(f"{pad}{'─' * min(max(len(titleize(heading)), 8), 28)}")
    if isinstance(obj, dict):
        simple = [(k, v) for k, v in obj.items() if not isinstance(v, (dict, list))]
        nested = [(k, v) for k, v in obj.items() if isinstance(v, (dict, list))]
        if simple:
            width = max(len(titleize(k)) for k, _ in simple)
            for key, value in simple:
                print(f"{pad}{titleize(key):<{width}} : {scalar(value)}")
        for idx, (key, value) in enumerate(nested):
            if simple or idx > 0:
                print()
            print_block(value, indent=indent, heading=key)
        return
    if isinstance(obj, list):
        if not obj:
            print(f"{pad}-")
            return
        for item in obj:
            if isinstance(item, (dict, list)):
                print(f"{pad}-")
                print_block(item, indent=indent + 2)
            else:
                print(f"{pad}- {scalar(item)}")
        return
    print(f"{pad}{scalar(obj)}")

payload = unwrap(payload)
if payload in ({}, [], None):
    raise SystemExit(0)
if isinstance(payload, dict) and {"installed", "remote", "status"}.issubset(payload.keys()):
    render_update(payload)
    raise SystemExit(0)
if isinstance(payload, dict) and "certificate_path" in payload and "private_key_path" in payload:
    render_certificate(payload)
    raise SystemExit(0)
if isinstance(payload, dict) and ("transport" in payload or "udp53_mode" in payload):
    render_transport_result(payload)
    raise SystemExit(0)
if isinstance(payload, dict) and {"hostname", "public_hostname", "tunnel_domain"}.issubset(payload.keys()):
    render_domain_result(payload)
    raise SystemExit(0)
if isinstance(payload, dict) and "account" in payload and "config" in payload:
    render_account_rows(payload.get("account") or {})
    print()
    render_account_config(payload.get("protocol"), payload.get("config") or {})
    raise SystemExit(0)
if isinstance(payload, dict) and "config" in payload and isinstance(payload.get("config"), dict):
    render_account_config(payload.get("protocol"), payload.get("config") or {})
    raise SystemExit(0)
if isinstance(payload, dict) and ("username" in payload or "message" in payload) and not any(k in payload for k in ("config", "account")):
    render_action_result(payload)
    raise SystemExit(0)
print_block(payload)
PY
}

json_kv() {
  python3 - "$@" <<'PY'
import json, sys
d = {}
for item in sys.argv[1:]:
    k, v = item.split("=", 1)
    d[k] = v
print(json.dumps(d))
PY
}

urlencode() { python3 -c "import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1],safe=''))" "$1"; }

api_request() {
  local method="$1" path="$2" body="${3:-}" tmp url
  local curl_extra=()
  if ! url="$(build_api_url "$path")"; then
    API_STATUS="000"
    API_RESPONSE="{\"error\":{\"message\":\"Menu API base is invalid. Re-run the installer or repair ${CONFIG_PATH}.\"}}"
    return 0
  fi
  mapfile -t curl_extra < <(api_curl_noproxy_args "$url")
  tmp="$(mktemp)"
  if [[ -n "$body" ]]; then
    API_STATUS="$(curl -ksS -o "$tmp" -w "%{http_code}" -X "$method" \
      "${curl_extra[@]}" \
      -H "Authorization: $API_KEY" -H "Content-Type: application/json" \
      --data "$body" "$url" || true)"
  else
    API_STATUS="$(curl -ksS -o "$tmp" -w "%{http_code}" -X "$method" \
      "${curl_extra[@]}" \
      -H "Authorization: $API_KEY" "$url" || true)"
  fi
  API_RESPONSE="$(cat "$tmp")"
  if [[ "${API_STATUS:-000}" == "400" ]] && api_response_is_squid_invalid_url "$API_RESPONSE"; then
    force_local_api_base
    url="$(build_api_url "$path")" || true
    curl_extra=(--noproxy "*")
    if [[ -n "${url:-}" ]]; then
      if [[ -n "$body" ]]; then
        API_STATUS="$(curl -ksS -o "$tmp" -w "%{http_code}" -X "$method" \
          "${curl_extra[@]}" \
          -H "Authorization: $API_KEY" -H "Content-Type: application/json" \
          --data "$body" "$url" || true)"
      else
        API_STATUS="$(curl -ksS -o "$tmp" -w "%{http_code}" -X "$method" \
          "${curl_extra[@]}" \
          -H "Authorization: $API_KEY" "$url" || true)"
      fi
      API_RESPONSE="$(cat "$tmp")"
    fi
  fi
  rm -f "$tmp"
}

api_request_with_spinner() {
  local method="$1" path="$2" body="${3:-}" label="${4:-Working}"
  local tmp status_tmp url pid waited=0 frame spinner='-\|/' idx=0
  local curl_extra=()
  if ! url="$(build_api_url "$path")"; then
    API_STATUS="000"
    API_RESPONSE="{\"error\":{\"message\":\"Menu API base is invalid. Re-run the installer or repair ${CONFIG_PATH}.\"}}"
    return 0
  fi
  mapfile -t curl_extra < <(api_curl_noproxy_args "$url")
  tmp="$(mktemp)"
  status_tmp="$(mktemp)"
  if [[ -n "$body" ]]; then
    (
      curl -ksS -o "$tmp" -w "%{http_code}" -X "$method" \
        "${curl_extra[@]}" \
        -H "Authorization: $API_KEY" -H "Content-Type: application/json" \
        --data "$body" "$url" >"$status_tmp" || printf '000' >"$status_tmp"
    ) &
  else
    (
      curl -ksS -o "$tmp" -w "%{http_code}" -X "$method" \
        "${curl_extra[@]}" \
        -H "Authorization: $API_KEY" "$url" >"$status_tmp" || printf '000' >"$status_tmp"
    ) &
  fi
  pid=$!
  while kill -0 "$pid" >/dev/null 2>&1; do
    frame="${spinner:idx%4:1}"
    printf '\r  %s %s %ss' "$frame" "$label" "$waited" > /dev/tty 2>/dev/null || true
    sleep 1
    waited=$((waited + 1))
    idx=$((idx + 1))
  done
  wait "$pid" >/dev/null 2>&1 || true
  printf '\r  %s%s%s\n' "$C_GREEN" "Finished." "$C_RESET" > /dev/tty 2>/dev/null || true
  API_STATUS="$(cat "$status_tmp" 2>/dev/null || printf '000')"
  API_RESPONSE="$(cat "$tmp" 2>/dev/null || true)"
  if [[ "${API_STATUS:-000}" == "400" ]] && api_response_is_squid_invalid_url "$API_RESPONSE"; then
    force_local_api_base
    url="$(build_api_url "$path")" || true
    curl_extra=(--noproxy "*")
    if [[ -n "${url:-}" ]]; then
      if [[ -n "$body" ]]; then
        API_STATUS="$(curl -ksS -o "$tmp" -w "%{http_code}" -X "$method" \
          "${curl_extra[@]}" \
          -H "Authorization: $API_KEY" -H "Content-Type: application/json" \
          --data "$body" "$url" || true)"
      else
        API_STATUS="$(curl -ksS -o "$tmp" -w "%{http_code}" -X "$method" \
          "${curl_extra[@]}" \
          -H "Authorization: $API_KEY" "$url" || true)"
      fi
      API_RESPONSE="$(cat "$tmp" 2>/dev/null || true)"
    fi
  fi
  rm -f "$tmp" "$status_tmp"
}

show_api_result() {
  local msg rendered
  msg="$(json_message "$API_RESPONSE")"
  rendered="$(render_api_body "$API_RESPONSE")"
  echo
  if [[ "$API_STATUS" =~ ^2[0-9][0-9]$ ]]; then
    if [[ -n "$rendered" ]]; then
      printf '%s\n' "$rendered"
    elif [[ -n "$msg" ]]; then
      printf '  %s%s%s\n' "$C_GREEN" "$msg" "$C_RESET"
    else
      printf '  %s%sCompleted successfully.%s\n' "$(dot_ok)" "$C_GREEN" "$C_RESET"
    fi
  else
    printf '  %s %s%s  Request failed%s\n' "$(dot_err)" "$C_BOLD" "$C_RED" "$C_RESET"
    [[ -n "$msg" ]] && printf '  %sMessage :%s %s\n' "$C_MUTED" "$C_RESET" "$msg"
    printf '  %sHTTP    :%s %s\n' "$C_MUTED" "$C_RESET" "${API_STATUS:-000}"
    hr
    if [[ -n "$rendered" ]]; then
      printf '%s\n' "$rendered"
    fi
  fi
}

show_update_progress() {
  local log_path="$1" update_unit="$2" installer_cache="${3:-}" from_version="${4:-}" to_version="${5:-}" status_file="${6:-}"
  local waited=0 max_wait=180 state="" substate="" result="" spinner='-\|/' frame="" status_state="" exit_code=""

  echo
  section "Updating IPTunnel"
  echo
  [[ -n "$from_version" ]] && printf '  %sCurrent build :%s %s\n' "$C_MUTED" "$C_RESET" "$from_version"
  [[ -n "$to_version" ]] && printf '  %sTarget build  :%s %s\n' "$C_MUTED" "$C_RESET" "$to_version"
  [[ -n "$installer_cache" ]] && printf '  %sInstaller     :%s %s\n' "$C_MUTED" "$C_RESET" "$installer_cache"
  [[ -n "$update_unit" ]] && printf '  %sBackground job:%s %s\n' "$C_MUTED" "$C_RESET" "$update_unit"
  [[ -n "$status_file" ]] && printf '  %sStatus file   :%s %s\n' "$C_MUTED" "$C_RESET" "$status_file"
  echo

  while (( waited < max_wait )); do
    if [[ -n "$status_file" && -f "$status_file" ]]; then
      mapfile -t __upd_status < <(python3 - "$status_file" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
try:
    data = json.loads(path.read_text(encoding="utf-8"))
except Exception:
    data = {}
for key in ("status", "exit_code"):
    value = data.get(key, "")
    print("" if value is None else value)
PY
)
      status_state="${__upd_status[0]:-}"
      exit_code="${__upd_status[1]:-}"
      if [[ "$status_state" == "success" || "$status_state" == "failed" ]]; then
        break
      fi
    fi
    if [[ -n "$update_unit" ]]; then
      state="$(systemctl is-active "$update_unit" 2>/dev/null || true)"
      substate="$(systemctl show -p SubState --value "$update_unit" 2>/dev/null || true)"
      result="$(systemctl show -p Result --value "$update_unit" 2>/dev/null || true)"
      if [[ "$state" != "active" && "$state" != "activating" && -n "$state" ]]; then
        break
      fi
    fi
    frame="${spinner:$(( waited % ${#spinner} )):1}"
    printf '\r  %s Updating services... %3ss' "$frame" "$waited"
    sleep 1
    waited=$((waited + 1))
  done
  printf '\r'

  if [[ -n "$update_unit" ]]; then
    state="$(systemctl is-active "$update_unit" 2>/dev/null || true)"
    substate="$(systemctl show -p SubState --value "$update_unit" 2>/dev/null || true)"
    result="$(systemctl show -p Result --value "$update_unit" 2>/dev/null || true)"
  fi

  echo
  if [[ "$status_state" == "success" ]]; then
    printf '  %s Update completed successfully.%s\n' "$(dot_ok)" "$C_RESET"
    [[ -n "$to_version" ]] && printf '  %sInstalled build:%s %s\n' "$C_MUTED" "$C_RESET" "$to_version"
    [[ -n "$log_path" ]] && printf '  %sLog file       :%s %s\n' "$C_MUTED" "$C_RESET" "$log_path"
    return
  fi

  if [[ "$status_state" == "failed" ]]; then
    printf '  %s Update failed.%s\n' "$(dot_err)" "$C_RESET"
    [[ -n "$exit_code" ]] && printf '  %sExit code :%s %s\n' "$C_MUTED" "$C_RESET" "$exit_code"
    [[ -n "$log_path" ]] && printf '  %sLog file  :%s %s\n' "$C_MUTED" "$C_RESET" "$log_path"
    if [[ -f "$log_path" ]]; then
      echo
      hr
      tail -n 30 "$log_path" 2>/dev/null || true
      hr
    fi
    return
  fi

  if [[ "$result" == "success" || ( "$state" == "inactive" && "$result" == "success" ) ]]; then
    printf '  %s Update completed successfully.%s\n' "$(dot_ok)" "$C_RESET"
    [[ -n "$to_version" ]] && printf '  %sInstalled build:%s %s\n' "$C_MUTED" "$C_RESET" "$to_version"
    [[ -n "$log_path" ]] && printf '  %sLog file       :%s %s\n' "$C_MUTED" "$C_RESET" "$log_path"
    return
  fi

  if [[ "$result" == "failed" || "$state" == "failed" ]]; then
    printf '  %s Update failed.%s\n' "$(dot_err)" "$C_RESET"
    [[ -n "$log_path" ]] && printf '  %sLog file :%s %s\n' "$C_MUTED" "$C_RESET" "$log_path"
    if [[ -f "$log_path" ]]; then
      echo
      hr
      tail -n 20 "$log_path" 2>/dev/null || true
      hr
    fi
    return
  fi

  printf '  %s Update is still running in the background.%s\n' "$(dot_ok)" "$C_RESET"
  [[ -n "$substate" ]] && printf '  %sState    :%s %s / %s\n' "$C_MUTED" "$C_RESET" "${state:-unknown}" "$substate"
  [[ -n "$log_path" ]] && printf '  %sLog file :%s %s\n' "$C_MUTED" "$C_RESET" "$log_path"
}

# ══════════════════════════════════════════════════════════════════════
#  PROTOCOL SELECTION
# ══════════════════════════════════════════════════════════════════════

choose_protocol() {
  section "Select Protocol"
  echo
  printf '  %s┌──────────┬──────────┬──────────┬──────────┐%s\n' "$C_SURFACE" "$C_RESET"
  printf '  %s│%s %s[1]%s SSH  %s│%s %s[2]%s VMess%s│%s %s[3]%s VLESS%s│%s %s[4]%s Trojan%s│%s\n' \
    "$C_SURFACE" "$C_RESET" "$C_BLUE" "$C_RESET" "$C_SURFACE" "$C_RESET" \
    "$C_BLUE" "$C_RESET" "$C_SURFACE" "$C_RESET" \
    "$C_BLUE" "$C_RESET" "$C_SURFACE" "$C_RESET" \
    "$C_BLUE" "$C_RESET" "$C_SURFACE" "$C_RESET"
  printf '  %s└──────────┴──────────┴──────────┴──────────┘%s\n' "$C_SURFACE" "$C_RESET"
  local ch
  ch="$(ask)"
  case "$ch" in
    1) PROTOCOL_KEY="sshvpn"; PROTOCOL_LABEL="SSH" ;;
    2) PROTOCOL_KEY="vmess";  PROTOCOL_LABEL="VMess" ;;
    3) PROTOCOL_KEY="vless";  PROTOCOL_LABEL="VLESS" ;;
    4) PROTOCOL_KEY="trojan"; PROTOCOL_LABEL="Trojan" ;;
    *) printf '  %s Invalid protocol\n' "$(dot_err)"; return 1 ;;
  esac
}

protocol_slug() {
  case "$PROTOCOL_KEY" in
    sshvpn) echo "ssh" ;;
    vmess|vless|trojan) echo "$PROTOCOL_KEY" ;;
    *) return 1 ;;
  esac
}

route_for() {
  local action="$1"
  local protocol base
  protocol="$(protocol_slug)" || return 1
  base="/api/v2/vps/accounts/${protocol}"
  case "$action" in
    list|create|check|renew|delete|lock|unlock) echo "$base" ;;
    trial) echo "${base}/trials" ;;
    *) return 1 ;;
  esac
}

# ══════════════════════════════════════════════════════════════════════
#  ACCOUNT OPERATIONS
# ══════════════════════════════════════════════════════════════════════

list_accounts() {
  choose_protocol || return
  api_request GET "$(route_for list)"
  echo
  if [[ ! "$API_STATUS" =~ ^2[0-9][0-9]$ ]]; then show_api_result; return; fi
  section "$PROTOCOL_LABEL Accounts"
  echo
  PAYLOAD="$API_RESPONSE" python3 - <<'PY'
import json, os
payload = json.loads(os.environ["PAYLOAD"])
rows = ((payload.get("data") or {}).get("accounts") or [])
if not rows:
    print("  No accounts found.")
    raise SystemExit(0)
# Header
h = f"\033[38;5;243m  {'USERNAME':<20} {'EXPIRES':<12} {'IP':>3}  {'LOCK':<10} {'STATUS':<10} {'QUOTA':<10}\033[0m"
print(h)
print(f"\033[38;5;238m  {'─'*68}\033[0m")
for row in rows:
    u = str(row.get('username','-'))[:20]
    e = str(row.get('expires_on','-'))[:12]
    i = int(row.get('limit_ip',0) or 0)
    l = 'LOCKED' if row.get('locked') else 'UNLOCKED'
    s = str(row.get('status','-'))[:10]
    q = str(row.get('max_human','-'))[:10]
    # Color active/expired
    sc = "\033[38;5;114m" if s.upper() in {"ACTIVE", "AKTIF"} else "\033[38;5;210m"
    print(f"  {u:<20} {e:<12} {i:>3}  {l:<10} {sc}{s:<10}\033[0m {q:<10}")
PY
}

create_account() {
  choose_protocol || return
  section "$PROTOCOL_LABEL — Create Account"
  echo
  local username="" password="" secret_value="" expired_days="" limit_ip="" kuota="" payload=()

  username="$(ask_prompt "Username")"
  expired_days="$(ask_prompt "Days until expiry")"
  limit_ip="$(ask_prompt "IP limit    [0]")"
  kuota="$(ask_prompt "Quota GB    [0]")"

  limit_ip="${limit_ip:-0}"; kuota="${kuota:-0}"
  payload+=("username=$username" "expires_in_days=$expired_days" "limit_ip=$limit_ip" "quota_gb=$kuota")

  if [[ "$PROTOCOL_KEY" == "sshvpn" ]]; then
    password="$(ask_prompt "Password")"
    payload+=("password=$password")
  else
    secret_value="$(ask_prompt "Custom UUID [auto]")"
    [[ -n "$secret_value" ]] && payload+=("secret=$secret_value")
  fi

  api_request POST "$(route_for create)" "$(json_kv "${payload[@]}")"
  show_api_result
}

create_trial() {
  choose_protocol || return
  section "$PROTOCOL_LABEL — Trial Account"
  echo
  local timelimit="" password="" secret_value="" payload=()

  timelimit="$(ask_prompt "Duration (30m / 1h / 1d)")"
  payload+=("duration=$timelimit")

  if [[ "$PROTOCOL_KEY" == "sshvpn" ]]; then
    password="$(ask_prompt "Password [auto]")"
    [[ -n "$password" ]] && payload+=("password=$password")
  else
    secret_value="$(ask_prompt "Custom UUID [auto]")"
    [[ -n "$secret_value" ]] && payload+=("secret=$secret_value")
  fi

  api_request POST "$(route_for trial)" "$(json_kv "${payload[@]}")"
  show_api_result
}

show_account() {
  choose_protocol || return
  section "$PROTOCOL_LABEL — Account Details"
  echo
  local username=""
  username="$(ask_prompt "Username")"
  api_request GET "$(route_for check)/$(urlencode "$username")"
  show_api_result
}

renew_account() {
  choose_protocol || return
  section "$PROTOCOL_LABEL — Renew Account"
  echo
  local username="" days="" kuota="" body_items=()

  username="$(ask_prompt "Username")"
  days="$(ask_prompt "Add days")"

  body_items+=("expires_in_days=$days")
  kuota="$(ask_prompt "New quota GB [keep]")"
  [[ -n "$kuota" ]] && body_items+=("quota_gb=$kuota")

  api_request PATCH "$(route_for renew)/$(urlencode "$username")" "$(json_kv "${body_items[@]}")"
  show_api_result
}

delete_account() {
  choose_protocol || return
  section "$PROTOCOL_LABEL — Delete Account"
  echo
  local username="" confirm=""

  username="$(ask_prompt "Username")"
  printf '  %s%s⚠  Delete "%s"? This cannot be undone.%s\n' "$C_BOLD" "$C_RED" "$username" "$C_RESET"
  confirm="$(ask_prompt "Type 'yes' to confirm")"
  if [[ "$confirm" != "yes" ]]; then printf '  %sCancelled.%s\n' "$C_MUTED" "$C_RESET"; return; fi

  api_request DELETE "$(route_for delete)/$(urlencode "$username")"
  show_api_result
}

lock_or_unlock() {
  choose_protocol || return
  section "$PROTOCOL_LABEL — Lock / Unlock"
  echo
  local username="" action="" password=""

  username="$(ask_prompt "Username")"
  echo
  mi 1 "Lock account"
  mi 2 "Unlock account"
  action="$(ask)"

  case "$action" in
    1)
      api_request PATCH "$(route_for lock)/$(urlencode "$username")" "$(json_kv "locked=true")"
      ;;
    2)
      if [[ "$PROTOCOL_KEY" == "sshvpn" ]]; then
        password="$(ask_prompt "New password for unlock")"
        api_request PATCH "$(route_for unlock)/$(urlencode "$username")" "$(json_kv "locked=false" "unlock_password=$password")"
      else
        api_request PATCH "$(route_for unlock)/$(urlencode "$username")" "$(json_kv "locked=false")"
      fi
      ;;
    *)
      printf '  %s Invalid choice\n' "$(dot_err)"
      return
      ;;
  esac

  show_api_result
}

# ══════════════════════════════════════════════════════════════════════
#  SERVICE STATUS
# ══════════════════════════════════════════════════════════════════════

show_status() {
  section "Service Status"
  echo
  local services=()
  mapfile -t services < <(configured_services)
  local svc
  for svc in "${services[@]}"; do
    local state
    state="$(systemctl is-active "$svc" 2>/dev/null || true)"
    if [[ "$state" == "active" ]]; then
      printf '  %s  %-38s %s%s%s\n' "$(_dot 1)" "$svc" "$C_GREEN" "active" "$C_RESET"
    else
      printf '  %s  %-38s %s%s%s\n' "$(_dot 0)" "$svc" "$C_RED" "${state}" "$C_RESET"
    fi
  done
}

# ══════════════════════════════════════════════════════════════════════
#  RUNTIME INFO
# ══════════════════════════════════════════════════════════════════════

show_runtime_info() {
  section "Runtime Info"
  echo
  printf '  %s%-14s%s %s\n' "$C_MUTED" "Config" "$C_RESET" "$CONFIG_PATH"
  printf '  %s%-14s%s %s%s%s\n' "$C_MUTED" "Domain" "$C_RESET" "$C_WHITE" "$DOMAIN" "$C_RESET"
  printf '  %s%-14s%s %s%s%s\n' "$C_MUTED" "Public IP" "$C_RESET" "$C_CYAN" "${PUBLIC_IP:-unknown}" "$C_RESET"
  printf '  %s%-14s%s %s\n' "$C_MUTED" "API base" "$C_RESET" "$API_BASE"
  printf '  %s%-14s%s %s\n' "$C_MUTED" "API key" "$C_RESET" "$API_KEY"

  # License info
  local lic_enabled lic_url lic_sid
  lic_enabled="$(python3 -c "import json; c=json.load(open('$CONFIG_PATH')); print('1' if c.get('license',{}).get('enabled') else '0')" 2>/dev/null || echo "0")"
  if [[ "$lic_enabled" == "1" ]]; then
    lic_url="$(python3 -c "import json; print(json.load(open('$CONFIG_PATH')).get('license',{}).get('url',''))" 2>/dev/null || echo "")"
    lic_sid="$(cat /etc/iptunnel/license.id 2>/dev/null | tr -d '[:space:]')"
    if [[ -n "$lic_sid" ]]; then
      printf '  %s%-14s%s %s %s%sregistered%s\n' "$C_MUTED" "License" "$C_RESET" "$(_dot 1)" "$C_GREEN" "" "$C_RESET"
    else
      lic_sid="none"
      printf '  %s%-14s%s %s %s%sunregistered%s %s(24h grace)%s\n' "$C_MUTED" "License" "$C_RESET" "$(_dot 0)" "$C_YELLOW" "" "$C_RESET" "$C_MUTED" "$C_RESET"
    fi
    printf '  %s%-14s%s %s\n' "$C_MUTED" "License URL" "$C_RESET" "$lic_url"
    printf '  %s%-14s%s %s\n' "$C_MUTED" "Server ID" "$C_RESET" "$lic_sid"
  else
    printf '  %s%-14s%s %s %snot configured%s\n' "$C_MUTED" "License" "$C_RESET" "$(_dot 0)" "$C_MUTED" "$C_RESET"
  fi

  # PAM auth status
  if grep -qF "iptunnel-pam-check" /etc/pam.d/sshd 2>/dev/null; then
    printf '  %s%-14s%s %s %s%sactive%s %s(foreign app blocking)%s\n' "$C_MUTED" "PAM auth" "$C_RESET" "$(_dot 1)" "$C_GREEN" "" "$C_RESET" "$C_MUTED" "$C_RESET"
  else
    printf '  %s%-14s%s %s %snot installed%s\n' "$C_MUTED" "PAM auth" "$C_RESET" "$(_dot 0)" "$C_MUTED" "$C_RESET"
  fi

  hr
  api_request GET "/api/v2/vps/runtime"
  if [[ ! "$API_STATUS" =~ ^2[0-9][0-9]$ ]]; then
    show_api_result
    return
  fi
  echo
  PAYLOAD="$API_RESPONSE" python3 - <<'PY'
import json, os
payload = json.loads(os.environ["PAYLOAD"])
data = payload.get("data") or {}
ssh = data.get("ssh") or {}
xray = data.get("xray") or {}
slowdns = data.get("slowdns") or {}
hysteria = data.get("hysteria") or {}
openvpn = data.get("openvpn") or {}

def yes_no(value):
    return "yes" if value else "no"

def show_rows(title, rows):
    rows = [(label, value) for label, value in rows if value not in ("", None, [], {})]
    if not rows:
        return
    print(f"  {title}")
    print(f"  {'-' * len(title)}")
    width = max(len(label) for label, _ in rows)
    for label, value in rows:
        if isinstance(value, list):
            value = ", ".join(str(item) for item in value if str(item).strip()) or "-"
        elif isinstance(value, dict):
            value = ", ".join(f"{k}={v}" for k, v in value.items() if str(v).strip()) or "-"
        elif isinstance(value, bool):
            value = yes_no(value)
        print(f"  {label:<{width}} : {value}")
    print()

show_rows("SSH", [
    ("Manage users", ssh.get("manage_system_users")),
    ("WS path", ssh.get("ws_path")),
    ("WS aliases", ssh.get("ws_paths")),
    ("Ports", ssh.get("ports")),
])
show_rows("Xray", [
    ("Ports", xray.get("ports")),
    ("Paths", xray.get("paths")),
    ("Services", xray.get("services")),
])
show_rows("SlowDNS", [
    ("Enabled", slowdns.get("enabled")),
    ("Public host", slowdns.get("public_hostname") or slowdns.get("ns_host")),
    ("Tunnel domain", slowdns.get("tunnel_domain")),
    ("Public port", slowdns.get("public_port") or slowdns.get("listen_port")),
    ("Local port", slowdns.get("local_port")),
    ("Target", slowdns.get("target")),
    ("Service", slowdns.get("service")),
])
show_rows("Hysteria", [
    ("Enabled", hysteria.get("enabled")),
    ("Protocol", hysteria.get("protocol")),
    ("Port", hysteria.get("port")),
    ("Obfs", hysteria.get("obfs")),
    ("Password", hysteria.get("password")),
])
show_rows("OpenVPN", [
    ("Enabled", openvpn.get("enabled")),
    ("TCP", openvpn.get("tcp")),
    ("UDP", openvpn.get("udp")),
])
PY
}

# ══════════════════════════════════════════════════════════════════════
#  HYSTERIA CONFIG
# ══════════════════════════════════════════════════════════════════════

configure_hysteria_auth() {
  local values=() enabled="" obfs="" password="" host="" port="" protocol=""
  local service="" hop_ports="" ca_cert_path="" info_path="" reply=""

  mapfile -t values < <(python3 - "$CONFIG_PATH" <<'PY'
import json, pathlib, sys
c = json.load(open(sys.argv[1]))
h = c.get("hysteria") or {}
obfs     = str(h.get("obfs","") or "")
password = str(h.get("password","") or "")
if not obfs or not password:
    p = pathlib.Path("/etc/hysteria/config.json")
    if p.exists():
        try:    hc = json.loads(p.read_text())
        except: hc = {}
        obfs = obfs or str(hc.get("obfs","") or "")
        cfg  = (hc.get("auth") or {}).get("config") or []
        password = password or (str(cfg[0]) if cfg else "")
print(h.get("enabled",""))
print(obfs)
print(password)
print(c.get("hostname",""))
print(h.get("port",5666))
print(h.get("protocol","udp"))
print(h.get("service","hysteria-server"))
print(h.get("hop_ports","-"))
print(h.get("ca_cert_path",""))
print(h.get("info_path","/var/www/html/hysteria-info.txt"))
PY
  )

  enabled="${values[0]:-}"; obfs="${values[1]:-}"; password="${values[2]:-}"
  host="${values[3]:-}"; port="${values[4]:-5666}"; protocol="${values[5]:-udp}"
  service="${values[6]:-hysteria-server}"; hop_ports="${values[7]:--}"
  ca_cert_path="${values[8]:-}"; info_path="${values[9]:-/var/www/html/hysteria-info.txt}"

  section "Hysteria Auth / URI"
  echo
  printf '  %s%-12s%s %s\n' "$C_MUTED" "Current obfs" "$C_RESET" "${obfs:-(not set)}"
  printf '  %s%-12s%s %s\n' "$C_MUTED" "Current pass" "$C_RESET" "${password:-(not set)}"
  hr

  read -r -p "  New obfs [$obfs]: " reply
  [[ -n "$reply" ]] && obfs="$reply"
  read -r -p "  New password [$password]: " reply
  [[ -n "$reply" ]] && password="$reply"

  if [[ -z "$obfs" || -z "$password" ]]; then
    printf '  %s Both obfs and password are required.\n' "$(dot_err)"; return
  fi

  python3 - "$CONFIG_PATH" "$obfs" "$password" <<'PY'
import json, sys
p, o, pw = sys.argv[1], sys.argv[2], sys.argv[3]
c = json.load(open(p))
c.setdefault("hysteria",{})["obfs"] = o
c["hysteria"]["password"] = pw
with open(p,"w") as f: json.dump(c, f, indent=2)
PY

  if [[ -f /etc/hysteria/config.json ]]; then
    python3 - "$obfs" "$password" <<'PY'
import json, sys
path = "/etc/hysteria/config.json"
obfs, password = sys.argv[1], sys.argv[2]
cfg = json.load(open(path, encoding="utf-8"))
cfg["obfs"] = obfs
cfg.setdefault("auth", {})["mode"] = "passwords"
cfg["auth"]["config"] = [password]
with open(path, "w", encoding="utf-8") as handle:
    json.dump(cfg, handle, indent=2)
    handle.write("\n")
PY
  fi

  printf '  %s Config updated.\n' "$(dot_ok)"

  local hysteria_uri="hysteria://${host}:${port}?obfs=${obfs}&auth=${password}&insecure=1"
  local uri_path; uri_path="$(dirname "$info_path")/hysteria.uri"
  printf '%s\n' "$hysteria_uri" >"$uri_path"
  cat >"$info_path" <<EOF
IPTunnel Hysteria
=================
Host         : ${host}
Port         : ${port}
Protocol     : ${protocol}
Obfs         : ${obfs}
Password     : ${password}
CA cert      : ${ca_cert_path}
Service      : ${service}
Hop range    : ${hop_ports}

Notes:
- Import ${ca_cert_path} into the client if it verifies certificates strictly.
- If the client supports insecure/self-signed mode, you can use that instead of importing the CA.
EOF

  echo
  printf '  %s%s╔══════════════════════════════════════════════════╗%s\n' "$C_BOLD" "$C_GREEN" "$C_RESET"
  printf '  %s%s║  Hysteria URI                                    ║%s\n' "$C_BOLD" "$C_GREEN" "$C_RESET"
  printf '  %s%s╚══════════════════════════════════════════════════╝%s\n' "$C_BOLD" "$C_GREEN" "$C_RESET"
  echo
  printf '  %s\n' "$hysteria_uri"
  echo
  printf '  %sSaved to: %s%s\n' "$C_MUTED" "$uri_path" "$C_RESET"

  if systemctl is-active --quiet "$service" 2>/dev/null; then
    systemctl restart "$service"
    printf '  %s Hysteria service restarted.\n' "$(dot_ok)"
  fi
}

# ══════════════════════════════════════════════════════════════════════
#  TRANSPORT TOGGLES
# ══════════════════════════════════════════════════════════════════════

toggle_hysteria() {
  local states=() hys_on=""
  mapfile -t states < <(transport_module_state)
  hys_on="${states[0]:-0}"
  if [[ "$hys_on" == "1" ]]; then
    api_request_with_spinner POST "/api/v2/vps/transports/hysteria/disable" "" "Disabling Hysteria..."
  else
    api_request_with_spinner POST "/api/v2/vps/transports/hysteria/enable" "" "Enabling Hysteria..."
  fi
  show_api_result
}

toggle_openvpn() {
  local states=() ovpn_tcp="" ovpn_udp="" openvpn_on="0"
  mapfile -t states < <(transport_module_state)
  ovpn_tcp="${states[1]:--}"; ovpn_udp="${states[2]:--}"
  [[ "$ovpn_tcp" != "-" || "$ovpn_udp" != "-" ]] && openvpn_on="1"
  if [[ "$openvpn_on" == "1" ]]; then
    api_request_with_spinner POST "/api/v2/vps/transports/openvpn/disable" "" "Disabling OpenVPN..."
  else
    api_request_with_spinner POST "/api/v2/vps/transports/openvpn/enable" "" "Enabling OpenVPN..."
  fi
  show_api_result
}

udp53_mode_label() {
  case "${1:-slowdns}" in
    openvpn) printf 'OpenVPN only' ;;
    shared) printf 'Shared (experimental)' ;;
    *) printf 'SlowDNS only' ;;
  esac
}

set_udp53_mode() {
  local label
  label="$(udp53_mode_label "$1")"
  api_request_with_spinner POST "/api/v2/vps/transports/udp53-mode/$1" "" "Switching UDP53 to ${label}..."
  show_api_result
}

set_openvpn_udp_ports() {
  local states=() current_ports="" ports="" udp53_mode=""
  mapfile -t states < <(transport_module_state)
  current_ports="${states[4]:--}"
  udp53_mode="${states[3]:-slowdns}"
  [[ "${current_ports}" != "-" ]] || current_ports="1194"
  section "OpenVPN UDP Multiport"
  echo
  printf '  %sCurrent public UDP ports:%s %s\n' "$C_MUTED" "$C_RESET" "$current_ports"
  printf '  %sUDP53 mode:%s %s\n' "$C_MUTED" "$C_RESET" "$(udp53_mode_label "$udp53_mode")"
  printf '  %sEnter comma-separated ports, for example 53,1194. Port 53 follows the UDP53 mode above.%s\n' "$C_MUTED" "$C_RESET"
  echo
  ports="$(ask_prompt "OpenVPN UDP public ports [${current_ports}]")"
  ports="${ports:-$current_ports}"
  api_request_with_spinner PATCH "/api/v2/vps/transports/openvpn/udp-port" "$(json_kv "ports=$ports")" "Updating OpenVPN UDP ports..."
  show_api_result
}

enable_openvpn_alt_port() {
  set_openvpn_udp_ports
}

change_slowdns_mtu() {
  local states=() current_mtu="1232" choice="" mtu=""
  mapfile -t states < <(transport_module_state)
  current_mtu="${states[6]:-1232}"

  section "SlowDNS MTU"
  echo
  printf '  %sCurrent server MTU:%s %s\n' "$C_MUTED" "$C_RESET" "$current_mtu"
  printf '  %sThis setting applies to all SlowDNS users. Active SlowDNS restarts after a change.%s\n' "$C_MUTED" "$C_RESET"
  echo
  mi 1 "512"  "Recommended"
  mi 2 "1232" "Default / higher throughput"
  mi 3 "800"  "Balanced compatibility"
  mi 4 "296"  "Very restricted resolvers"
  mi 5 "Custom" "Choose 128 to 1500"
  echo
  mi 0 "Back"

  choice="$(ask)"
  case "$choice" in
    1) mtu="512" ;;
    2) mtu="1232" ;;
    3) mtu="800" ;;
    4) mtu="296" ;;
    5) mtu="$(ask_prompt "Custom MTU [128-1500]")" ;;
    0) return ;;
    *) printf '  %s Invalid choice\n' "$(dot_err)"; return ;;
  esac
  if ! [[ "$mtu" =~ ^[0-9]+$ ]] || (( mtu < 128 || mtu > 1500 )); then
    printf '  %s MTU must be between 128 and 1500.\n' "$(dot_err)"
    return
  fi
  api_request_with_spinner PATCH "/api/v2/vps/transports/slowdns/mtu" \
    "$(json_kv "mtu=$mtu")" "Updating SlowDNS MTU..."
  show_api_result
}

# ══════════════════════════════════════════════════════════════════════
#  TORRENT CONTROL
# ══════════════════════════════════════════════════════════════════════

_TORRENT_CHAIN="IPTUNNEL_TORRENT_BLK"

torrent_is_blocked() {
  iptables -L FORWARD 2>/dev/null | grep -qF "$_TORRENT_CHAIN" && echo "1" || echo "0"
}

torrent_block() {
  # Create or flush custom chain
  iptables -N "$_TORRENT_CHAIN" 2>/dev/null || iptables -F "$_TORRENT_CHAIN"

  # String-match rules (DPI-lite)
  iptables -A "$_TORRENT_CHAIN" -m string --string "BitTorrent protocol" --algo bm -j DROP
  iptables -A "$_TORRENT_CHAIN" -m string --string "info_hash="          --algo bm -j DROP
  iptables -A "$_TORRENT_CHAIN" -m string --string "peer_id="            --algo bm -j DROP
  iptables -A "$_TORRENT_CHAIN" -m string --string "get_peers"           --algo bm -j DROP
  iptables -A "$_TORRENT_CHAIN" -m string --string "announce_peer"       --algo bm -j DROP

  # Port-based rules
  iptables -A "$_TORRENT_CHAIN" -p tcp --dport 6881:6889 -j DROP
  iptables -A "$_TORRENT_CHAIN" -p udp --dport 6881:6889 -j DROP

  # Jump from FORWARD
  if ! iptables -L FORWARD 2>/dev/null | grep -qF "$_TORRENT_CHAIN"; then
    iptables -I FORWARD -j "$_TORRENT_CHAIN"
  fi

  _iptables_save
  printf '  %s Torrent traffic blocked.\n' "$(dot_ok)"
}

torrent_unblock() {
  iptables -D FORWARD -j "$_TORRENT_CHAIN" 2>/dev/null || true
  iptables -F "$_TORRENT_CHAIN" 2>/dev/null || true
  iptables -X "$_TORRENT_CHAIN" 2>/dev/null || true
  _iptables_save
  printf '  %s Torrent traffic allowed.\n' "$(dot_ok)"
}

toggle_torrent() {
  if [[ "$(torrent_is_blocked)" == "1" ]]; then
    torrent_unblock
  else
    torrent_block
  fi
}

_iptables_save() {
  if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save 2>/dev/null || true
  elif command -v iptables-save >/dev/null 2>&1; then
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
  fi
}

# ══════════════════════════════════════════════════════════════════════
#  AUTO REBOOT
# ══════════════════════════════════════════════════════════════════════

_REBOOT_CRON=/etc/cron.d/iptunnel-autoreboot

autoreboot_status() {
  [[ -f "$_REBOOT_CRON" ]] && echo "1" || echo "0"
}

autoreboot_time() {
  [[ -f "$_REBOOT_CRON" ]] || { echo "—"; return; }
  awk '!/^#/ && NF { printf "%02d:%02d", $2, $1 }' "$_REBOOT_CRON"
}

autoreboot_enable() {
  local hour="" minute="" confirm=""
  section "Schedule Auto-Reboot"
  echo
  printf '  %sThe server will reboot daily at the time you set.%s\n' "$C_MUTED" "$C_RESET"
  echo
  hour="$(ask_prompt "Hour   [4]")"
  minute="$(ask_prompt "Minute [0]")"
  hour="${hour:-4}"; minute="${minute:-0}"

  if ! [[ "$hour"   =~ ^([0-9]|1[0-9]|2[0-3])$ ]]; then
    printf '  %s Invalid hour.\n' "$(dot_err)"; return
  fi
  if ! [[ "$minute" =~ ^([0-9]|[1-5][0-9])$ ]]; then
    printf '  %s Invalid minute.\n' "$(dot_err)"; return
  fi

  printf '\n  Schedule: every day at %s%02d:%02d%s\n' "$C_CYAN" "$hour" "$minute" "$C_RESET"
  confirm="$(ask_prompt "Continue? [y/N]")"
  [[ "$confirm" =~ ^[Yy]$ ]] || { printf '  %sCancelled.%s\n' "$C_MUTED" "$C_RESET"; return; }

  cat >"$_REBOOT_CRON" <<EOF
# IPTunnel auto-reboot — managed by iptunnel_menu.sh
${minute} ${hour} * * * root /sbin/reboot
EOF
  chmod 644 "$_REBOOT_CRON"
  printf '  %s Auto-reboot set for %02d:%02d daily.\n' "$(dot_ok)" "$hour" "$minute"
}

autoreboot_disable() {
  if [[ ! -f "$_REBOOT_CRON" ]]; then
    printf '  %sAuto-reboot is not enabled.%s\n' "$C_MUTED" "$C_RESET"; return
  fi
  rm -f "$_REBOOT_CRON"
  printf '  %s Auto-reboot disabled.\n' "$(dot_ok)"
}

show_bandwidth_stats() {
  section "Bandwidth Stats"
  echo
  api_request GET "/api/v2/vps/bandwidth"
  if [[ ! "$API_STATUS" =~ ^2[0-9][0-9]$ ]]; then
    show_api_result
    return
  fi
  PAYLOAD="$API_RESPONSE" python3 - <<'PY'
import json, os
payload = json.loads(os.environ["PAYLOAD"])
data = payload.get("data") or {}
totals = data.get("totals") or {}
protocols = data.get("protocols") or {}
print(f"  Total accounts : {totals.get('accounts', 0)}")
print(f"  Used bandwidth : {totals.get('used_human', '0 B')}")
print(f"  Quota ceiling  : {totals.get('max_human', '0 B')}")
if protocols:
    print()
for name, info in protocols.items():
    print(f"  {name:<8} used={info.get('used_human', '0 B'):<12} quota={info.get('max_human', '0 B')}")
    for row in (info.get('accounts') or [])[:5]:
        print(f"    - {str(row.get('username', '-')):<20} {row.get('used_human', '0 B')}")
PY
}

backup_configs() {
  section "Backup Configs"
  echo
  api_request POST "/api/v2/vps/backup"
  show_api_result
}

restore_configs() {
  local path confirm
  section "Restore Backup"
  echo
  path="$(ask_prompt "Backup path (/root/iptunnel-backup-*.tar.gz)")"
  [[ -n "$path" && -f "$path" ]] || { printf '  %s Backup file not found.\n' "$(dot_err)"; return; }
  confirm="$(ask_prompt "Type RESTORE to continue")"
  [[ "$confirm" == "RESTORE" ]] || { printf '  %sCancelled.%s\n' "$C_MUTED" "$C_RESET"; return; }
  api_request POST "/api/v2/vps/restore" "$(json_kv "path=$path")"
  show_api_result
}

change_domains() {
  local values=() current_host="" current_tunnel=""
  local hostname="" tunnel_domain="" confirm="" choice=""
  POST_ACTION_PAUSE="1"
  while true; do
    section "Domain Settings"
    echo
    mapfile -t values < <(domain_state)
    current_host="${values[0]:-}"
    current_tunnel="${values[1]:-}"
    printf '  %sA record domain:%s %s\n' "$C_MUTED" "$C_RESET" "${current_host:-unknown}"
    printf '  %sNS record      :%s %s\n' "$C_MUTED" "$C_RESET" "${current_tunnel:-unknown}"
    printf '  %sNS target      :%s %s\n' "$C_MUTED" "$C_RESET" "${current_host:-unknown}"
    echo
    mi 1 "Edit A record domain" "Change the main server domain"
    mi 2 "Edit NS record" "Change the SlowDNS nameserver domain"
    mi 3 "Edit both records" "Change server domain and SlowDNS NS"
    mi 0 "Back"
    choice="$(ask)"
    case "$choice" in
      1)
        hostname="$(ask_prompt "New A record domain [${current_host:-same}]")"
        hostname="${hostname:-$current_host}"
        tunnel_domain="$current_tunnel"
        ;;
      2)
        hostname="$current_host"
        tunnel_domain="$(ask_prompt "New NS record [${current_tunnel:-dns.<A record domain>}]")"
        tunnel_domain="${tunnel_domain:-$current_tunnel}"
        ;;
      3)
        hostname="$(ask_prompt "New A record domain [${current_host:-same}]")"
        hostname="${hostname:-$current_host}"
        tunnel_domain="$(ask_prompt "New NS record [${current_tunnel:-dns.<A record domain>}]")"
        tunnel_domain="${tunnel_domain:-$current_tunnel}"
        ;;
      0)
        POST_ACTION_PAUSE="0"
        return
        ;;
      *)
        printf '  %s Invalid choice\n' "$(dot_err)"
        continue
        ;;
    esac
    echo
    printf '  %sA record domain:%s %s\n' "$C_MUTED" "$C_RESET" "$hostname"
    printf '  %sNS record      :%s %s\n' "$C_MUTED" "$C_RESET" "$tunnel_domain"
    printf '  %sNS target      :%s %s\n' "$C_MUTED" "$C_RESET" "$hostname"
    echo
    confirm="$(ask_prompt "Type CHANGE to apply")"
    [[ "$confirm" == "CHANGE" ]] || { printf '  %sCancelled.%s\n' "$C_MUTED" "$C_RESET"; return; }
    api_request_with_spinner PATCH "/api/v2/vps/domains" \
      "$(json_kv "hostname=$hostname" "tunnel_domain=$tunnel_domain")" \
      "Applying domain settings..."
    show_api_result
    if [[ "$API_STATUS" =~ ^2[0-9][0-9]$ ]]; then
      load_config
    fi
    return
  done
}

device_provisioning() {
  local status="" server_id="" choice="" confirm="" port="9443" server_name=""
  local certificate="" key="" prepared="0"
  while true; do
    print_header
    section "Device Provisioning"
    echo
    status="$(python3 /opt/iptunnel/provisioning_setup.py --config "$CONFIG_PATH" status 2>&1 || true)"
    printf '  %sCurrent configuration%s\n' "$C_MUTED" "$C_RESET"
    printf '%s\n' "$status" | sed 's/^/  /'
    echo
    hr
    echo
    mi 1 "Prepare managed SSH"      "OpenSSH device-key authentication"
    mi 2 "Prepare managed OpenVPN"  "Client certificates and session monitor"
    mi 3 "Prepare managed Xray"     "Isolated mTLS VMess/VLESS/Trojan"
    mi 4 "Refresh status"
    echo
    mi 0 "Back"
    choice="$(ask)"
    [[ "$choice" == "0" ]] && return
    [[ "$choice" == "4" ]] && continue
    if [[ ! "$choice" =~ ^[123]$ ]]; then
      printf '  %s Invalid choice\n' "$(dot_err)"; pause; continue
    fi

    server_id="$(python3 - "$CONFIG_PATH" <<'PY'
import json, sys
try: print((json.load(open(sys.argv[1])).get('provisioning') or {}).get('server_id',''))
except Exception: print('')
PY
)"
    if [[ -z "$server_id" ]]; then
      server_id="$(ask_prompt "Immutable registry server ID")"
    else
      printf '  %sServer ID:%s %s\n' "$C_MUTED" "$C_RESET" "$server_id"
    fi
    [[ "$server_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || {
      printf '  %s Invalid server ID.\n' "$(dot_err)"; pause; continue;
    }
    echo
    confirm="$(ask_prompt "Type PREPARE to validate and activate")"
    [[ "$confirm" == "PREPARE" ]] || { printf '  %sCancelled.%s\n' "$C_MUTED" "$C_RESET"; pause; continue; }

    prepared="0"
    case "$choice" in
      1)
        if python3 /opt/iptunnel/provisioning_setup.py --config "$CONFIG_PATH" prepare-ssh --server-id "$server_id"; then
          prepared="1"
        fi
        ;;
      2)
        if python3 /opt/iptunnel/provisioning_setup.py --config "$CONFIG_PATH" prepare-openvpn --server-id "$server_id"; then
          prepared="1"
        fi
        ;;
      3)
        server_name="$(ask_prompt "TLS server name [$DOMAIN]")"; server_name="${server_name:-$DOMAIN}"
        port="$(ask_prompt "Dedicated public TLS port [9443]")"; port="${port:-9443}"
        certificate="$(ask_prompt "Server certificate [/etc/letsencrypt/live/$server_name/fullchain.pem]")"
        certificate="${certificate:-/etc/letsencrypt/live/$server_name/fullchain.pem}"
        key="$(ask_prompt "Server key [/etc/letsencrypt/live/$server_name/privkey.pem]")"
        key="${key:-/etc/letsencrypt/live/$server_name/privkey.pem}"
        if python3 /opt/iptunnel/provisioning_setup.py --config "$CONFIG_PATH" prepare-xray \
          --server-id "$server_id" --port "$port" --server-name "$server_name" \
          --certificate "$certificate" --key "$key"; then
          prepared="1"
        fi
        ;;
    esac
    if [[ "$prepared" == "1" ]]; then
      printf '  %s Device provisioning preparation completed.\n' "$(dot_ok)"
    else
      printf '  %s Device provisioning was not activated; previous configuration was restored.\n' "$(dot_err)"
    fi
    pause
  done
}

issue_letsencrypt_cert() {
  local email="" installed="" choice=""
  POST_ACTION_PAUSE="1"
  section "Let's Encrypt"
  echo
  [[ -n "$DOMAIN" ]] || { printf '  %s Domain is not set in config.\n' "$(dot_err)"; return; }
  api_request GET "/api/v2/vps/certificates/letsencrypt"
  show_api_result
  [[ "$API_STATUS" =~ ^2[0-9][0-9]$ ]] || return

  installed="$(json_data_field "$API_RESPONSE" "installed")"
  if [[ "$installed" == "true" ]]; then
    echo
    mi 1 "Reinstall certificate" "Force a fresh certbot renewal"
    mi 0 "Back"
    choice="$(ask)"
    if [[ "$choice" != "1" ]]; then
      POST_ACTION_PAUSE="0"
      return
    fi
    email="$(ask_prompt "Email for Let's Encrypt notices")"
    [[ -n "$email" ]] || { printf '  %s Email is required.\n' "$(dot_err)"; return; }
    api_request POST "/api/v2/vps/certificates/letsencrypt" "$(json_kv "email=$email" "force=true")"
    show_api_result
    return
  fi

  echo
  printf '  %sNo certificate is installed yet. Continue with a new issuance.%s\n' "$C_MUTED" "$C_RESET"
  echo
  email="$(ask_prompt "Email for Let's Encrypt notices")"
  [[ -n "$email" ]] || { printf '  %s Email is required.\n' "$(dot_err)"; return; }
  api_request POST "/api/v2/vps/certificates/letsencrypt" "$(json_kv "email=$email")"
  show_api_result
}

check_updates() {
  section "Update Checker"
  echo
  api_request GET "/api/v2/vps/updates"
  show_api_result
}

apply_update() {
  local confirm="" update_status="" update_log="" update_unit="" installer_cache="" status_file=""
  local current_version="" target_version="" notes="" installer_url=""
  section "Install Update"
  echo
  printf '  %sThis downloads the installer URL from the remote release manifest and reapplies the stack in the background.%s\n' "$C_MUTED" "$C_RESET"
  printf '  %sYour SSH session should stay up, but services may restart during the update.%s\n' "$C_MUTED" "$C_RESET"
  echo
  confirm="$(ask_prompt "Type UPDATE to continue")"
  [[ "$confirm" == "UPDATE" ]] || { printf '  %sCancelled.%s\n' "$C_MUTED" "$C_RESET"; return; }
  api_request POST "/api/v2/vps/updates"
  if [[ ! "$API_STATUS" =~ ^2[0-9][0-9]$ ]]; then
    show_api_result
    return
  fi

  update_status="$(json_data_field "$API_RESPONSE" "status")"
  current_version="$(json_data_field "$API_RESPONSE" "installed")"
  target_version="$(json_data_field "$API_RESPONSE" "remote")"
  notes="$(json_data_field "$API_RESPONSE" "notes")"
  installer_url="$(json_data_field "$API_RESPONSE" "installer_url")"
  update_log="$(json_data_field "$API_RESPONSE" "log")"
  update_unit="$(json_data_field "$API_RESPONSE" "update_unit")"
  installer_cache="$(json_data_field "$API_RESPONSE" "installer_cache")"
  status_file="$(json_data_field "$API_RESPONSE" "status_file")"

  if [[ "$update_status" == "updating" ]]; then
    echo
    printf '  %s Update started.%s\n' "$(dot_ok)" "$C_RESET"
    [[ -n "$current_version" ]] && printf '  %sCurrent build :%s %s\n' "$C_MUTED" "$C_RESET" "$current_version"
    [[ -n "$target_version" ]] && printf '  %sTarget build  :%s %s\n' "$C_MUTED" "$C_RESET" "$target_version"
    [[ -n "$installer_url" ]] && printf '  %sSource        :%s %s\n' "$C_MUTED" "$C_RESET" "$installer_url"
    if [[ -n "$notes" ]]; then
      printf '  %sRelease notes :%s %s\n' "$C_MUTED" "$C_RESET" "$notes"
    fi
    show_update_progress "$update_log" "$update_unit" "$installer_cache" "$current_version" "$target_version" "$status_file"
    return
  fi

  show_api_result
}

# ══════════════════════════════════════════════════════════════════════
#  SUBMENUS
# ══════════════════════════════════════════════════════════════════════

udp_management() {
  while true; do
    local states=() hys_on="" ovpn_tcp="" ovpn_udp="" udp53_mode="" ovpn_public_udp="" slowdns_on=""
    local openvpn_udp_on="0"
    mapfile -t states < <(transport_module_state)
    hys_on="${states[0]:-0}"; ovpn_tcp="${states[1]:--}"; ovpn_udp="${states[2]:--}"; udp53_mode="${states[3]:-slowdns}"; ovpn_public_udp="${states[4]:-53}"; slowdns_on="${states[5]:-1}"
    [[ "$ovpn_udp" != "-" ]] && openvpn_udp_on="1"

    print_header
    section "Mux53 / UDP Management"
    echo

    printf '  %s  %-22s %s\n' "$(_dot "$slowdns_on")" "SlowDNS" "$(_status_label "$slowdns_on")"
    printf '  %s  %-22s %s\n' "$(_dot "$openvpn_udp_on")" "OpenVPN UDP" "$(_status_label "$openvpn_udp_on")"
    printf '  %s  %-22s %s\n' "$(_dot 1)" "UDP53 mode" "$(udp53_mode_label "$udp53_mode")"
    printf '  %s  %-22s %s\n' "$(_dot "$([[ "$ovpn_public_udp" != "-" ]] && echo 1 || echo 0)")" "OpenVPN UDP ports" "$ovpn_public_udp"
    echo
    hr
    echo

    mi 1 "SlowDNS owns port 53"           "OpenVPN extra ports stay active"
    mi 2 "OpenVPN owns port 53"           "Supports extra ports such as 1194"
    mi 3 "Share port 53"                  "Experimental SlowDNS and OpenVPN mux"
    mi 4 "Configure OpenVPN UDP ports"    "Multiport, for example 53,1194"
    echo
    mi 0 "Back"

    local ch
    ch="$(ask)"
    case "$ch" in
      1) set_udp53_mode slowdns ;;
      2) set_udp53_mode openvpn ;;
      3) set_udp53_mode shared ;;
      4) enable_openvpn_alt_port ;;
      0) return ;;
      *) printf '  %s Invalid choice\n' "$(dot_err)" ;;
    esac
    pause
  done
}

transport_settings() {
  while true; do
    local states=() hys_on="" ovpn_tcp="" ovpn_udp="" udp53_mode="" slowdns_mtu="1232" torrent_on="" openvpn_on="0"
    mapfile -t states < <(transport_module_state)
    hys_on="${states[0]:-0}"; ovpn_tcp="${states[1]:--}"; ovpn_udp="${states[2]:--}"; udp53_mode="${states[3]:-slowdns}"
    slowdns_mtu="${states[6]:-1232}"
    torrent_on="$(torrent_is_blocked)"
    [[ "$ovpn_tcp" != "-" || "$ovpn_udp" != "-" ]] && openvpn_on="1"

    print_header
    section "Transport & Protocols"
    echo

    printf '  %s  %-20s %s\n' "$(_dot "$hys_on")"     "Hysteria UDP"    "$(_status_label "$hys_on")"
    printf '  %s  %-20s %s\n' "$(_dot "$openvpn_on")"  "OpenVPN"         "$(_status_label "$openvpn_on")"
    printf '  %s  %-20s %s\n' "$(_dot 1)"             "UDP53 mode"       "$(udp53_mode_label "$udp53_mode")"
    printf '  %s  %-20s %s\n' "$(_dot 1)"             "SlowDNS MTU"      "$slowdns_mtu"
    printf '  %s  %-20s %s\n' \
      "$(_dot "$([[ "$torrent_on" == "1" ]] && echo 0 || echo 1)")" \
      "Torrent traffic" \
      "$(_blocked_label "$torrent_on")"
    echo
    hr
    echo

    mi 1 "$([[ "$hys_on" == "1" ]] && echo "Disable Hysteria" || echo "Enable Hysteria")"
    mi 2 "Hysteria auth / URI"          "Configure obfs & password"
    mi 3 "Mux53 / UDP management"       "SlowDNS, OpenVPN UDP, shared 53"
    mi 4 "SlowDNS MTU"                   "Tune resolver compatibility"
    mi 5 "$([[ "$torrent_on" == "1" ]] && echo "Allow torrent traffic" || echo "Block torrent traffic")"
    echo
    mi 0 "Back"

    local ch
    ch="$(ask)"
    case "$ch" in
      1) toggle_hysteria ;;
      2) configure_hysteria_auth ;;
      3) udp_management ;;
      4) change_slowdns_mtu ;;
      5) toggle_torrent ;;
      0) return ;;
      *) printf '  %s Invalid choice\n' "$(dot_err)" ;;
    esac
    pause
  done
}

system_settings() {
  while true; do
    local rb_on rb_time
    rb_on="$(autoreboot_status)"
    rb_time="$(autoreboot_time)"
    POST_ACTION_PAUSE="1"

    print_header
    section "System Settings"
    echo

    printf '  %s  %-20s %s' "$(_dot "$rb_on")" "Auto-reboot" "$(_status_label "$rb_on")"
    [[ "$rb_on" == "1" ]] && printf '  %s(daily at %s)%s' "$C_MUTED" "$rb_time" "$C_RESET"
    echo
    echo
    hr
    echo

    mi 1 "Enable auto-reboot"          "Schedule daily server restart"
    mi 2 "Disable auto-reboot"
    mi 3 "Bandwidth stats"             "Usage totals by protocol"
    mi 4 "Backup configs"              "Create /root tar.gz snapshot"
    mi 5 "Restore backup"              "Extract saved tarball"
    mi 6 "Let's Encrypt cert"          "Inspect or install trusted TLS"
    mi 7 "Check for updates"           "Compare installed vs latest release"
    mi 8 "Install latest update"       "Use the release manifest installer"
    mi 9 "Change domains"              "Edit A record domain or SlowDNS NS"
    echo
    mi 0 "Back"

    local ch
    ch="$(ask)"
    case "$ch" in
      1) autoreboot_enable ;;
      2) autoreboot_disable ;;
      3) show_bandwidth_stats ;;
      4) backup_configs ;;
      5) restore_configs ;;
      6) issue_letsencrypt_cert ;;
      7) check_updates ;;
      8) apply_update ;;
      9) change_domains ;;
      0) return ;;
      *) printf '  %s Invalid choice\n' "$(dot_err)" ;;
    esac
    [[ "${POST_ACTION_PAUSE:-1}" == "1" ]] && pause
  done
}

# ══════════════════════════════════════════════════════════════════════
#  MAIN MENU
# ══════════════════════════════════════════════════════════════════════


main_menu() {
  while true; do
    print_header

    section "Account Management"
    echo
    mi 1  "List accounts"               "View all users by protocol"
    mi 2  "Create account"              "New user with expiry & limits"
    mi 3  "Create trial"                "Time-limited trial account"
    mi 4  "Account details"             "Check a specific user"
    mi 5  "Renew account"               "Extend expiry date"
    mi 6  "Delete account"              "Permanently remove a user"
    mi 7  "Lock / Unlock"               "Suspend or reactivate access"

    section "Server"
    echo
    mi 8  "Service status"              "Check all running services"
    mi 9  "Runtime info"                "Domain, IP, API, license"
    mi 10 "Transport & Protocols"       "Hysteria, Mux53, OpenVPN, torrent"
    mi 11 "System settings"             "Auto-reboot schedule"
    mi 12 "Device provisioning"         "Keys, certificates, readiness"
    echo
    mi 0  "Exit"

    local ch
    ch="$(ask)"
    print_header

    case "$ch" in
      1)  list_accounts ;;
      2)  create_account ;;
      3)  create_trial ;;
      4)  show_account ;;
      5)  renew_account ;;
      6)  delete_account ;;
      7)  lock_or_unlock ;;
      8)  show_status ;;
      9)  show_runtime_info ;;
      10) transport_settings ;;
      11) system_settings ;;
      12) device_provisioning ;;
      0)  echo; printf '  %sGoodbye.%s\n\n' "$C_MUTED" "$C_RESET"; exit 0 ;;
      *)  printf '  %s Invalid choice\n' "$(dot_err)" ;;
    esac

    pause
  done
}

need_commands
load_config
main_menu
MENU
chmod 755 /usr/local/bin/iptunnel-menu
ln -sf /usr/local/bin/iptunnel-menu /usr/local/bin/menu

cat >/opt/iptunnel/hysteria_vendor.sh <<'HYSTERIA'
#!/usr/bin/env bash
#
#

set -e


###
# SCRIPT CONFIGURATION
###

# Domain Name
DOMAIN="${DOMAIN:-}"

# PROTOCOL
PROTOCOL="udp"

# UDP PORT
UDP_PORT=":5666"

# OBFS
OBFS="${OBFS:-}"

# Password. Leave empty to auto-generate a secure value on first install.
PASSWORD="${PASSWORD:-}"
# Basename of this script
SCRIPT_NAME="$(basename "$0")"

# Command line arguments of this script
SCRIPT_ARGS=("$@")

# Path for installing executable
EXECUTABLE_INSTALL_PATH="/usr/local/bin/hysteria"

# Paths to install systemd files
SYSTEMD_SERVICES_DIR="/etc/systemd/system"

# Directory to store hysteria config file
CONFIG_DIR="/etc/hysteria"

# Sysctl drop-in managed by this script
SYSCTL_CONFIG_PATH="/etc/sysctl.d/99-hysteria.conf"

# URLs of GitHub
REPO_URL="https://github.com/apernet/hysteria"
API_BASE_URL="https://api.github.com/repos/apernet/hysteria"

# curl command line flags.
# To use a proxy, please specify ALL_PROXY in the environment variable, such as:
# export ALL_PROXY=socks5h://192.0.2.1:1080
CURL_FLAGS=(-L -f -q --retry 5 --retry-delay 10 --retry-max-time 60)


###
# AUTO DETECTED GLOBAL VARIABLE
###

# Package manager
PACKAGE_MANAGEMENT_INSTALL="${PACKAGE_MANAGEMENT_INSTALL:-}"

# Operating System of current machine, supported: Linux
OPERATING_SYSTEM="${OPERATING_SYSTEM:-}"

# Architecture of current machine, supported: 386, amd64, arm, arm64, mipsle, s390x
ARCHITECTURE="${ARCHITECTURE:-}"

# User for running hysteria
HYSTERIA_USER="${HYSTERIA_USER:-}"

# Directory for ACME certificates storage
HYSTERIA_HOME_DIR="${HYSTERIA_HOME_DIR:-}"


###
# ARGUMENTS
###

# Supported operation: install, remove, check_update
OPERATION=

# User-specified version to install
VERSION=

# Force install even if installed
FORCE=

# User specified binary to install
LOCAL_FILE=


###
# COMMAND REPLACEMENT & UTILITIES
###

has_command() {
	local _command=$1
	
	type -P "$_command" > /dev/null 2>&1
}

curl() {
	command curl "${CURL_FLAGS[@]}" "$@"
}

mktemp() {
	command mktemp "$@" "hyservinst.XXXXXXXXXX"
}

tput() {
	if has_command tput; then
		command tput "$@"
		fi
}

tred() {
	tput setaf 1
}

tgreen() {
	tput setaf 2
}

tyellow() {
	tput setaf 3
}

tblue() {
	tput setaf 4
}

taoi() {
	tput setaf 6
}

tbold() {
	tput bold
}

treset() {
	tput sgr0
}

note() {
	local _msg="$1"
	
	echo -e "$SCRIPT_NAME: $(tbold)note: $_msg$(treset)"
}

warning() {
	local _msg="$1"
	
	echo -e "$SCRIPT_NAME: $(tyellow)warning: $_msg$(treset)"
}

error() {
	local _msg="$1"
	
	echo -e "$SCRIPT_NAME: $(tred)error: $_msg$(treset)"
}

has_prefix() {
	local _s="$1"
	local _prefix="$2"
	
	if [[ -z "$_prefix" ]]; then
		return 0
		fi
		
		if [[ -z "$_s" ]]; then
			return 1
			fi
			
			[[ "x$_s" != "x${_s#"$_prefix"}" ]]
}

systemctl() {
	if [[ "x$FORCE_NO_SYSTEMD" == "x2" ]] || ! has_command systemctl; then
		return
		fi
		
		command systemctl "$@"
}

show_argument_error_and_exit() {
	local _error_msg="$1"
	
	error "$_error_msg"
	echo "Try \"$0 --help\" for the usage." >&2
	exit 22
}

install_content() {
	local _install_flags="$1"
	local _content="$2"
	local _destination="$3"

	local _tmpfile="$(mktemp)"

	echo -ne "Install $_destination ... "
	printf '%s' "$_content" > "$_tmpfile"
	if install "$_install_flags" "$_tmpfile" "$_destination"; then
		echo -e "ok"
	else
		rm -f "$_tmpfile"
		error "Failed to install $_destination"
		return 1
	fi

	rm -f "$_tmpfile"
}

remove_file() {
	local _target="$1"
	
	echo -ne "Remove $_target ... "
	if rm -f "$_target"; then
		echo -e "ok"
		fi
}

generate_random_password() {
	local _password

	if has_command openssl; then
		_password="$(openssl rand -hex 16 2> /dev/null || true)"
		if [[ -n "$_password" ]]; then
			echo "$_password"
			return 0
			fi
		fi

		LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32
}

is_interactive() {
	[[ -t 0 && -t 1 ]]
}

prompt_value() {
	local _label="$1"
	local _current_value="$2"
	local _entered_value

	if ! is_interactive; then
		echo "$_current_value"
		return 0
		fi

		if [[ -n "$_current_value" ]]; then
			read -r -p "$_label [$_current_value]: " _entered_value || true
			else
				read -r -p "$_label: " _entered_value || true
				fi

				if [[ -n "$_entered_value" ]]; then
					echo "$_entered_value"
					else
						echo "$_current_value"
						fi
}

prompt_password_value() {
	local _current_value="$1"
	local _entered_value

	if ! is_interactive; then
		echo "$_current_value"
		return 0
		fi

		if [[ -n "$_current_value" ]]; then
			echo "Press Enter to keep the current password or type a new one."
			else
				echo "Press Enter to auto-generate a secure password."
				fi

				read -r -s -p "Password: " _entered_value || true
				echo

				if [[ -n "$_entered_value" ]]; then
					echo "$_entered_value"
					else
						echo "$_current_value"
						fi
}

read_existing_config_string() {
	local _key="$1"
	local _config_path="$CONFIG_DIR/config.json"

	if [[ ! -f "$_config_path" ]]; then
		return 0
		fi

		sed -n "s/.*\"$_key\":[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$_config_path" | head -1
}

read_existing_password() {
	local _config_path="$CONFIG_DIR/config.json"

	if [[ ! -f "$_config_path" ]]; then
		return 0
		fi

		sed -n 's/.*"config":[[:space:]]*\["\([^"]*\)"\].*/\1/p' "$_config_path" | head -1
}

ensure_hysteria_domain() {
	local _existing_domain

	if [[ -z "$DOMAIN" ]]; then
		_existing_domain="$(read_existing_config_string "server" || true)"
		if [[ -n "$_existing_domain" ]]; then
			DOMAIN="$_existing_domain"
			fi
		fi

		DOMAIN="$(prompt_value "Domain" "$DOMAIN")"
		if [[ -z "$DOMAIN" ]]; then
			error "DOMAIN is required."
			exit 22
			fi
}

ensure_hysteria_obfs() {
	local _existing_obfs

	if [[ -z "$OBFS" ]]; then
		_existing_obfs="$(read_existing_config_string "obfs" || true)"
		if [[ -n "$_existing_obfs" ]]; then
			OBFS="$_existing_obfs"
			fi
		fi

		OBFS="$(prompt_value "Obfs" "$OBFS")"
		if [[ -z "$OBFS" ]]; then
			error "OBFS is required."
			exit 22
			fi
}

ensure_hysteria_password() {
	local _existing_password

	if [[ -z "$PASSWORD" ]]; then
		_existing_password="$(read_existing_password || true)"
		if [[ -n "$_existing_password" ]]; then
			PASSWORD="$_existing_password"
			fi
		fi

	PASSWORD="$(prompt_password_value "$PASSWORD")"

	if [[ -z "$PASSWORD" ]]; then
		PASSWORD="$(generate_random_password)"
		if [[ -z "$PASSWORD" ]]; then
			error "Unable to generate a secure Hysteria password."
			exit 70
			fi
		fi
}

collect_install_configuration() {
	ensure_hysteria_domain
	ensure_hysteria_obfs
	ensure_hysteria_password
}

exec_sudo() {
	# exec sudo with configurable environ preserved.
	local _saved_ifs="$IFS"
	IFS=$'\n'
	local _preserved_env=(
		$(env | grep "^PACKAGE_MANAGEMENT_INSTALL=" || true)
		$(env | grep "^OPERATING_SYSTEM=" || true)
		$(env | grep "^ARCHITECTURE=" || true)
		$(env | grep "^HYSTERIA_USER=" || true)
		$(env | grep "^HYSTERIA_HOME_DIR=" || true)
		$(env | grep "^FORCE_\w*=" || true)
	)
	IFS="$_saved_ifs"
	
	exec sudo env \
	"${_preserved_env[@]}" \
	"$@"
}

detect_package_manager() {
	if [[ -n "$PACKAGE_MANAGEMENT_INSTALL" ]]; then
		return 0
		fi
		
		if has_command apt; then
			PACKAGE_MANAGEMENT_INSTALL='apt update; apt -y install'
			return 0
			fi
			
			if has_command dnf; then
				PACKAGE_MANAGEMENT_INSTALL='dnf check-update; dnf -y install'
				return 0
				fi
				
				if has_command yum; then
					PACKAGE_MANAGEMENT_INSTALL='yum update; yum -y install'
					return 0
					fi
					
					if has_command zypper; then
						PACKAGE_MANAGEMENT_INSTALL='zypper update; zypper install -y --no-recommends'
						return 0
						fi
						
						if has_command pacman; then
							PACKAGE_MANAGEMENT_INSTALL='pacman -Syu; pacman -Syu --noconfirm'
							return 0
							fi
							
							return 1
}

install_software() {
	local _package_name="$1"
	
	if ! detect_package_manager; then
		error "Supported package manager is not detected, please install the following package manually:"
		echo
		echo -e "\t* $_package_name"
		echo
		exit 65
		fi
		
		echo "Installing missing dependence '$_package_name' with '$PACKAGE_MANAGEMENT_INSTALL' ... "
		if $PACKAGE_MANAGEMENT_INSTALL "$_package_name"; then
			echo "ok"
			else
				error "Cannot install '$_package_name' with detected package manager, please install it manually."
				exit 65
				fi
}

is_user_exists() {
	local _user="$1"
	
	id "$_user" > /dev/null 2>&1
}

check_permission() {
	if [[ "$UID" -eq '0' ]]; then
		return
		fi
		
		note "The user currently executing this script is not root."
		
		case "$FORCE_NO_ROOT" in
		'1')
		warning "FORCE_NO_ROOT=1 is specified, we will process without root, and you may encounter the insufficient privilege error."
		;;
	*)
	if has_command sudo; then
		note "Re-running this script with sudo, you can also specify FORCE_NO_ROOT=1 to force this script to run with the current user."
		exec_sudo "$0" "${SCRIPT_ARGS[@]}"
		else
			error "Please run this script with root or specify FORCE_NO_ROOT=1 to force this script to run with the current user."
			exit 13
			fi
			;;
		esac
}

check_environment_operating_system() {
	if [[ -n "$OPERATING_SYSTEM" ]]; then
		warning "OPERATING_SYSTEM=$OPERATING_SYSTEM is specified, operating system detection will not be performed."
		return
		fi
		
		if [[ "x$(uname)" == "xLinux" ]]; then
			OPERATING_SYSTEM=linux
			return
			fi
			
			error "This script only supports Linux."
			note "Specify OPERATING_SYSTEM=[linux|darwin|freebsd|windows] to bypass this check and force this script to run on this $(uname)."
			exit 95
}

check_environment_architecture() {
	if [[ -n "$ARCHITECTURE" ]]; then
		warning "ARCHITECTURE=$ARCHITECTURE is specified, architecture detection will not be performed."
		return
		fi
		
		case "$(uname -m)" in
		'i386' | 'i686')
		ARCHITECTURE='386'
		;;
	'amd64' | 'x86_64')
	ARCHITECTURE='amd64'
	;;
	'armv5tel' | 'armv6l' | 'armv7' | 'armv7l')
	ARCHITECTURE='arm'
	;;
	'armv8' | 'aarch64')
	ARCHITECTURE='arm64'
	;;
	'mips' | 'mipsle' | 'mips64' | 'mips64le')
	ARCHITECTURE='mipsle'
	;;
	's390x')
	ARCHITECTURE='s390x'
	;;
	*)
	error "The architecture '$(uname -a)' is not supported."
	note "Specify ARCHITECTURE=<architecture> to bypass this check and force this script to run on this $(uname -m)."
	exit 8
	;;
	esac
}

check_environment_systemd() {
	if [[ -d "/run/systemd/system" ]] || grep -q systemd <(ls -l /sbin/init); then
		return
		fi
		
		case "$FORCE_NO_SYSTEMD" in
		'1')
		warning "FORCE_NO_SYSTEMD=1 is specified, we will process as normal even if systemd is not detected by us."
		;;
	'2')
	warning "FORCE_NO_SYSTEMD=2 is specified, we will process, but all systemd related command will not be executed."
	;;
	*)
	error "This script only supports Linux distributions with systemd."
	note "Specify FORCE_NO_SYSTEMD=1 to disable this check and force this script to run as systemd is detected."
	note "Specify FORCE_NO_SYSTEMD=2 to disable this check along with all systemd-related commands."
	;;
	esac
}

check_environment_curl() {
	if has_command curl; then
		return
		fi
		apt update; apt -y install curl
}

check_environment_grep() {
	if has_command grep; then
		return
		fi
		apt update; apt -y install grep
}

check_environment_openssl() {
	if has_command openssl; then
		return
		fi
		apt update; apt -y install openssl
}

check_environment() {
	check_environment_operating_system
	check_environment_architecture
	check_environment_systemd
	check_environment_curl
	check_environment_grep
	check_environment_openssl
}

vercmp_segment() {
	local _lhs="$1"
	local _rhs="$2"
	
	if [[ "x$_lhs" == "x$_rhs" ]]; then
		echo 0
		return
		fi
		if [[ -z "$_lhs" ]]; then
			echo -1
			return
			fi
			if [[ -z "$_rhs" ]]; then
				echo 1
				return
				fi
				
				local _lhs_num="${_lhs//[A-Za-z]*/}"
				local _rhs_num="${_rhs//[A-Za-z]*/}"
				
				if [[ "x$_lhs_num" == "x$_rhs_num" ]]; then
					echo 0
					return
					fi
					if [[ -z "$_lhs_num" ]]; then
						echo -1
						return
						fi
						if [[ -z "$_rhs_num" ]]; then
							echo 1
							return
							fi
							local _numcmp=$(($_lhs_num - $_rhs_num))
							if [[ "$_numcmp" -ne 0 ]]; then
								echo "$_numcmp"
								return
								fi
								
								local _lhs_suffix="${_lhs#"$_lhs_num"}"
								local _rhs_suffix="${_rhs#"$_rhs_num"}"
								
								if [[ "x$_lhs_suffix" == "x$_rhs_suffix" ]]; then
									echo 0
									return
									fi
									if [[ -z "$_lhs_suffix" ]]; then
										echo 1
										return
										fi
										if [[ -z "$_rhs_suffix" ]]; then
											echo -1
											return
											fi
											if [[ "$_lhs_suffix" < "$_rhs_suffix" ]]; then
												echo -1
												return
												fi
												echo 1
}

vercmp() {
	local _lhs=${1#v}
	local _rhs=${2#v}
	
	while [[ -n "$_lhs" && -n "$_rhs" ]]; do
		local _clhs="${_lhs/.*/}"
		local _crhs="${_rhs/.*/}"
		
		local _segcmp="$(vercmp_segment "$_clhs" "$_crhs")"
		if [[ "$_segcmp" -ne 0 ]]; then
			echo "$_segcmp"
			return
			fi
			
			_lhs="${_lhs#"$_clhs"}"
			_lhs="${_lhs#.}"
			_rhs="${_rhs#"$_crhs"}"
			_rhs="${_rhs#.}"
			done
			
			if [[ "x$_lhs" == "x$_rhs" ]]; then
				echo 0
				return
				fi
				
				if [[ -z "$_lhs" ]]; then
					echo -1
					return
					fi
					
					if [[ -z "$_rhs" ]]; then
						echo 1
						return
						fi
						
						return
}

check_hysteria_user() {
	local _default_hysteria_user="$1"
	
	if [[ -n "$HYSTERIA_USER" ]]; then
		return
		fi
		
		if [[ ! -e "$SYSTEMD_SERVICES_DIR/hysteria-server.service" ]]; then
			HYSTERIA_USER="$_default_hysteria_user"
			return
			fi
			
			HYSTERIA_USER="$(sed -n 's/^User=//p' "$SYSTEMD_SERVICES_DIR/hysteria-server.service" | head -1 || true)"
			
			if [[ -z "$HYSTERIA_USER" ]]; then
				HYSTERIA_USER="$_default_hysteria_user"
				fi
}

validate_hysteria_user() {
	if [[ ! "$HYSTERIA_USER" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]]; then
		error "Invalid HYSTERIA_USER '$HYSTERIA_USER'."
		exit 22
		fi
}

check_hysteria_homedir() {
	local _default_hysteria_homedir="$1"
	local _existing_homedir
	
	if [[ -n "$HYSTERIA_HOME_DIR" ]]; then
		return
		fi
		
		if ! is_user_exists "$HYSTERIA_USER"; then
			HYSTERIA_HOME_DIR="$_default_hysteria_homedir"
			return
			fi

			_existing_homedir="$(getent passwd "$HYSTERIA_USER" | cut -d ':' -f 6 || true)"
			if [[ -n "$_existing_homedir" ]]; then
				HYSTERIA_HOME_DIR="$_existing_homedir"
				else
					HYSTERIA_HOME_DIR="$_default_hysteria_homedir"
					fi
}

validate_hysteria_homedir() {
	if [[ -z "$HYSTERIA_HOME_DIR" || "${HYSTERIA_HOME_DIR#/}" == "$HYSTERIA_HOME_DIR" ]]; then
		error "HYSTERIA_HOME_DIR must be an absolute path."
		exit 22
		fi
}


###
# ARGUMENTS PARSER
###

show_usage_and_exit() {
	echo
	echo -e "\t$(tbold)$SCRIPT_NAME$(treset) - IP Tunnel VPN Hysteria Server Install Script"
	echo
	echo -e "Usage:"
	echo
	echo -e "$(tbold)Install IP Tunnel VPN$(treset)"
	echo -e "\t$0 [ -l <file> | --version <version> ]"
	echo -e "Flags:"
	echo -e "\t-l, --local <file>\tInstall specified IP Tunnel VPN binary instead of downloading it."
	echo -e "\t--version <version>\tInstall specified version instead of the latest."
	echo
	echo -e "$(tbold)Remove IP Tunnel VPN$(treset)"
	echo -e "\t$0 --remove"
	echo
	echo -e "$(tbold)Show this help$(treset)"
	echo -e "\t$0 -h"
	echo -e "\t$0 --help"
	exit 0
}

parse_arguments() {
	while [[ "$#" -gt '0' ]]; do
		case "$1" in
		'--remove')
		if [[ -n "$OPERATION" && "$OPERATION" != 'remove' ]]; then
			show_argument_error_and_exit "Option '--remove' is conflicted with other options."
			fi
			OPERATION='remove'
			;;
		'--version')
		VERSION="$2"
		if [[ -z "$VERSION" ]]; then
			show_argument_error_and_exit "Please specify the version for option '--version'."
			fi
			shift
			if ! has_prefix "$VERSION" 'v'; then
				show_argument_error_and_exit "Version numbers should begin with 'v' (such as 'v1.3.1'), got '$VERSION'"
				fi
				;;
			 
			'-h' | '--help')
			show_usage_and_exit
			;;
			'-l' | '--local')
			LOCAL_FILE="$2"
			if [[ -z "$LOCAL_FILE" ]]; then
				show_argument_error_and_exit "Please specify the local binary to install for option '-l' or '--local'."
				fi
				break
				;;
			*)
			show_argument_error_and_exit "Unknown option '$1'"
			;;
			esac
			shift
			done
			
			if [[ -z "$OPERATION" ]]; then
				OPERATION='install'
				fi
				
				# validate arguments
				case "$OPERATION" in
				'install')
				if [[ -n "$VERSION" && -n "$LOCAL_FILE" ]]; then
					show_argument_error_and_exit '--version and --local cannot be specified together.'
					fi
					;;
				*)
				if [[ -n "$VERSION" ]]; then
					show_argument_error_and_exit "--version is only available when installing."
					fi
					if [[ -n "$LOCAL_FILE" ]]; then
						show_argument_error_and_exit "--local is only available when installing."
						fi
						;;
					esac
}


###
# FILE TEMPLATES
###

# /etc/systemd/system/hysteria-server.service
tpl_hysteria_server_service_base() {
  local _config_name="$1"

  cat << EOF
[Unit]
Description=IP Tunnel VPN Service
After=network.target

[Service]
User=$HYSTERIA_USER
Group=$(get_hysteria_group)
WorkingDirectory=$CONFIG_DIR
Environment="PATH=/usr/local/bin/hysteria"
ExecStart=/usr/local/bin/hysteria -config /etc/hysteria/config.json server
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
}

# /etc/systemd/system/hysteria-server.service
tpl_hysteria_server_service() {
  tpl_hysteria_server_service_base 'config'
}

# /etc/systemd/system/hysteria-server@.service
tpl_hysteria_server_x_service() {
  tpl_hysteria_server_service_base '%i'
}

# /etc/hysteria/config.json
tpl_etc_hysteria_config_json() {
  cat << EOF
{
  "server": "$DOMAIN",
   "listen": "$UDP_PORT",
  "protocol": "$PROTOCOL",
  "cert": "/etc/hysteria/hysteria.server.crt",
  "key": "/etc/hysteria/hysteria.server.key",
  "up": "100 Mbps",
  "up_mbps": 100,
  "down": "100 Mbps",
  "down_mbps": 100,
  "disable_udp": false,
  "obfs": "$OBFS",
  "auth": {
	"mode": "passwords",
	"config": ["$PASSWORD"]
         }
}
EOF
}


###
# SYSTEMD
###

get_running_services() {
	if [[ "x$FORCE_NO_SYSTEMD" == "x2" ]]; then
		return
		fi
		
		systemctl list-units --state=active --plain --no-legend \
		| grep -o "hysteria-server@*[^\s]*.service" || true
}

restart_running_services() {
	if [[ "x$FORCE_NO_SYSTEMD" == "x2" ]]; then
		return
		fi
		
		echo "Restarting running service ... "
		
		for service in $(get_running_services); do
			echo -ne "Restarting $service ... "
			systemctl restart "$service"
			echo "done"
			done
}

stop_running_services() {
	if [[ "x$FORCE_NO_SYSTEMD" == "x2" ]]; then
		return
		fi
		
		echo "Stopping running service ... "
		
		for service in $(get_running_services); do
			echo -ne "Stopping $service ... "
			systemctl stop "$service"
			echo "done"
			done
}


###
# HYSTERIA & GITHUB API
###

is_hysteria_installed() {
	# RETURN VALUE
	# 0: hysteria is installed
	# 1: hysteria is not installed
	
	if [[ -f "$EXECUTABLE_INSTALL_PATH" || -h "$EXECUTABLE_INSTALL_PATH" ]]; then
		return 0
		fi
		return 1
}

get_installed_version() {
	if is_hysteria_installed; then
		"$EXECUTABLE_INSTALL_PATH" -v | cut -d ' ' -f 3
		fi
}

get_latest_version() {
	if [[ -n "$VERSION" ]]; then
		echo "$VERSION"
		return
		fi
		
		local _tmpfile=$(mktemp)
		if ! curl -sS -H 'Accept: application/vnd.github.v3+json' "$API_BASE_URL/releases/latest" -o "$_tmpfile"; then
			error "Failed to get latest release, please check your network."
			exit 11
			fi
			
			local _latest_version=$(grep 'tag_name' "$_tmpfile" | head -1 | grep -o '"v.*"')
			_latest_version=${_latest_version#'"'}
			_latest_version=${_latest_version%'"'}
			
			if [[ -n "$_latest_version" ]]; then
				echo "$_latest_version"
				fi
				
				rm -f "$_tmpfile"
}

download_hysteria() {
	local _version="$1"
	local _destination="$2"
	
	local _download_url="$REPO_URL/releases/download/v1.3.5/hysteria-$OPERATING_SYSTEM-$ARCHITECTURE"
	echo "Downloading hysteria archive: $_download_url ..."
	if ! curl -fL -R -H 'Cache-Control: no-cache' --retry 5 --retry-delay 10 --retry-max-time 60 "$_download_url" -o "$_destination"; then
		error "Download failed! Please check your network and try again."
		return 11
		fi
		return 0
}

get_default_network_interface() {
	ip -4 route show default 2> /dev/null | awk 'NR == 1 { print $5 }'
}

get_hysteria_group() {
	id -gn "$HYSTERIA_USER"
}

secure_hysteria_assets() {
	local _group

	_group="$(get_hysteria_group)"
	install -d -m 750 -o "$HYSTERIA_USER" -g "$_group" "$CONFIG_DIR"

	if [[ -e "$CONFIG_DIR/config.json" ]]; then
		chown "$HYSTERIA_USER:$_group" "$CONFIG_DIR/config.json"
		chmod 640 "$CONFIG_DIR/config.json"
		fi

	if [[ -e "$CONFIG_DIR/hysteria.server.key" ]]; then
		chown "$HYSTERIA_USER:$_group" "$CONFIG_DIR/hysteria.server.key"
		chmod 640 "$CONFIG_DIR/hysteria.server.key"
		fi

	if [[ -e "$CONFIG_DIR/hysteria.server.crt" ]]; then
		chown "$HYSTERIA_USER:$_group" "$CONFIG_DIR/hysteria.server.crt"
		chmod 640 "$CONFIG_DIR/hysteria.server.crt"
		fi

	if [[ -e "$CONFIG_DIR/hysteria.ca.key" ]]; then
		chown root:root "$CONFIG_DIR/hysteria.ca.key"
		chmod 600 "$CONFIG_DIR/hysteria.ca.key"
		fi

	if [[ -e "$CONFIG_DIR/hysteria.ca.crt" ]]; then
		chown root:root "$CONFIG_DIR/hysteria.ca.crt"
		chmod 644 "$CONFIG_DIR/hysteria.ca.crt"
		fi
}

tpl_etc_hysteria_sysctl_conf() {
	local _interface="$1"

	cat << EOF
net.ipv4.ip_forward = 1
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.$_interface.rp_filter = 0
EOF
}

configure_hysteria_sysctl() {
	local _interface="$1"

	install_content -Dm644 "$(tpl_etc_hysteria_sysctl_conf "$_interface")" "$SYSCTL_CONFIG_PATH" ""
	if ! sysctl --system > /dev/null 2>&1; then
		sysctl -p "$SYSCTL_CONFIG_PATH" > /dev/null
		fi
}

add_nat_prerouting_rule_if_missing() {
	local _tool="$1"
	local _interface="$2"
	shift 2

	if "$_tool" -t nat -C PREROUTING -i "$_interface" "$@" > /dev/null 2>&1; then
		return 0
		fi

		"$_tool" -t nat -A PREROUTING -i "$_interface" "$@"
}

show_install_summary() {
	echo
	echo -e "$(tbold)Connection details$(treset)"
	echo -e "Domain: $DOMAIN"
	echo -e "Port: ${UDP_PORT#:}"
	echo -e "Protocol: $PROTOCOL"
	echo -e "Obfs: $OBFS"
	echo -e "Password: $PASSWORD"
	echo -e "Config: $CONFIG_DIR/config.json"
	echo
}


###
# ENTRY
###

perform_install_hysteria_binary() {
	if [[ -n "$LOCAL_FILE" ]]; then
		note "Performing local install: $LOCAL_FILE"
		
		echo -ne "Installing hysteria executable ... "
		
		if install -Dm755 "$LOCAL_FILE" "$EXECUTABLE_INSTALL_PATH"; then
			echo "ok"
			else
				exit 2
				fi
				
				return
				fi
				
				local _tmpfile=$(mktemp)
				
				if ! download_hysteria "$VERSION" "$_tmpfile"; then
					rm -f "$_tmpfile"
					exit 11
					fi
					
					echo -ne "Installing hysteria executable ... "
					
					if install -Dm755 "$_tmpfile" "$EXECUTABLE_INSTALL_PATH"; then
						echo "ok"
						else
							exit 13
							fi
							
							rm -f "$_tmpfile"
}

perform_remove_hysteria_binary() {
	remove_file "$EXECUTABLE_INSTALL_PATH"
}

perform_install_hysteria_example_config() {
	install_content -Dm600 "$(tpl_etc_hysteria_config_json)" "$CONFIG_DIR/config.json" ""
}

perform_install_hysteria_systemd() {
	if [[ "x$FORCE_NO_SYSTEMD" == "x2" ]]; then
		return
		fi
		
		install_content -Dm644 "$(tpl_hysteria_server_service)" "$SYSTEMD_SERVICES_DIR/hysteria-server.service"
		install_content -Dm644 "$(tpl_hysteria_server_x_service)" "$SYSTEMD_SERVICES_DIR/hysteria-server@.service"
		
		systemctl daemon-reload
}

perform_remove_hysteria_systemd() {
	remove_file "$SYSTEMD_SERVICES_DIR/hysteria-server.service"
	remove_file "$SYSTEMD_SERVICES_DIR/hysteria-server@.service"
	
	systemctl daemon-reload
}

perform_install_hysteria_home_legacy() {
	if ! is_user_exists "$HYSTERIA_USER"; then
		echo -ne "Creating user $HYSTERIA_USER ... "
		useradd -r -d "$HYSTERIA_HOME_DIR" -m "$HYSTERIA_USER"
		echo "ok"
		fi
}

perform_install() {
	local _is_frash_install
	if ! is_hysteria_installed; then
		_is_frash_install=1
		fi
		
		collect_install_configuration
		perform_install_hysteria_binary
		perform_install_hysteria_home_legacy
		perform_install_hysteria_example_config
		perform_install_hysteria_systemd
		setup_ssl
		secure_hysteria_assets
		start_services
		if [[ -n "$_is_frash_install" ]]; then
			echo
			echo -e "$(tbold)Congratulation! IP Tunnel VPN Hysteria Script has been successfully installed on your server.$(treset)"
			echo
			echo -e "$(tbold)Client app IP Tunnel VPN:$(treset)"
			echo -e "$(tblue)https://play.google.com/store/apps/details?id=com.iptunnel.tunnel$(treset)"
			echo
			show_install_summary
			else
				restart_running_services
				start_services
				echo
				echo -e "$(tbold)IP Tunnel Script has been successfully update to $VERSION.$(treset)"
				echo
				show_install_summary
				fi
}

perform_remove() {
	perform_remove_hysteria_binary
	stop_running_services
	perform_remove_hysteria_systemd
	
	echo
	echo -e "$(tbold)Congratulation! IP Tunnel Hysteria Script has been successfully removed from your server.$(treset)"
	echo
	echo -e "You still need to remove configuration files and ACME certificates manually with the following commands:"
	echo
	echo -e "\t$(tred)rm -rf "$CONFIG_DIR"$(treset)"
	if [[ "x$HYSTERIA_USER" != "xroot" ]]; then
		echo -e "\t$(tred)userdel -r "$HYSTERIA_USER"$(treset)"
		fi
		if [[ "x$FORCE_NO_SYSTEMD" != "x2" ]]; then
			echo
			echo -e "You still might need to disable all related systemd services with the following commands:"
			echo
			echo -e "\t$(tred)rm -f /etc/systemd/system/multi-user.target.wants/hysteria-server.service$(treset)"
			echo -e "\t$(tred)rm -f /etc/systemd/system/multi-user.target.wants/hysteria-server@*.service$(treset)"
			echo -e "\t$(tred)systemctl daemon-reload$(treset)"
			fi
			echo
}

add_netfilter_rule_if_missing() {
	local _tool="$1"
	local _action="$2"
	shift 2

	if "$_tool" -C "$@" > /dev/null 2>&1; then
		return 0
		fi

		"$_tool" "$_action" "$@"
}

setup_bittorrent_firewall_for_tool() {
	local _tool="$1"
	local _chain="HY_BT_BLOCK"
	local _signature
	local _protocol
	local _signatures=(
		"BitTorrent protocol"
		"peer_id="
		".torrent"
		"announce.php?passkey="
	)

	if ! has_command "$_tool"; then
		return 0
		fi

		if "$_tool" -nL "$_chain" > /dev/null 2>&1; then
			"$_tool" -F "$_chain"
			else
				"$_tool" -N "$_chain"
				fi

				add_netfilter_rule_if_missing "$_tool" -I INPUT -j "$_chain"
				add_netfilter_rule_if_missing "$_tool" -I OUTPUT -j "$_chain"
				add_netfilter_rule_if_missing "$_tool" -I FORWARD -j "$_chain"

				for _signature in "${_signatures[@]}"; do
					for _protocol in tcp udp; do
						add_netfilter_rule_if_missing "$_tool" -A "$_chain" -p "$_protocol" -m string --algo bm --string "$_signature" -j DROP
						done
						done
}

setup_bittorrent_firewall() {
	if has_command modprobe; then
		modprobe xt_string > /dev/null 2>&1 || true
		fi

	setup_bittorrent_firewall_for_tool iptables
	setup_bittorrent_firewall_for_tool ip6tables
}



setup_ssl() {
	local _old_umask

	echo "Installing ssl"
	_old_umask="$(umask)"
	umask 077

	openssl genrsa -out /etc/hysteria/hysteria.ca.key 2048

	openssl req -new -x509 -days 3650 -key /etc/hysteria/hysteria.ca.key -subj "/C=CN/ST=GD/L=SZ/O=Hysteria, Inc./CN=Hysteria Root CA" -out /etc/hysteria/hysteria.ca.crt

	openssl req -newkey rsa:2048 -nodes -keyout /etc/hysteria/hysteria.server.key -subj "/C=CN/ST=GD/L=SZ/O=Hysteria, Inc./CN=$DOMAIN" -out /etc/hysteria/hysteria.server.csr

	openssl x509 -req -extfile <(printf "subjectAltName=DNS:$DOMAIN,DNS:$DOMAIN") -days 3650 -in /etc/hysteria/hysteria.server.csr -CA /etc/hysteria/hysteria.ca.crt -CAkey /etc/hysteria/hysteria.ca.key -CAcreateserial -out /etc/hysteria/hysteria.server.crt	
	rm -f /etc/hysteria/hysteria.server.csr /etc/hysteria/hysteria.ca.srl
	umask "$_old_umask"
}
start_services() {
	local _default_interface

	echo "Starting IPTunnel VPN Hysteria"
	apt update
	debconf-set-selections <<< "iptables-persistent iptables-persistent/autosave_v4 boolean true"
	debconf-set-selections <<< "iptables-persistent iptables-persistent/autosave_v6 boolean true"
	apt -y install iptables-persistent
	_default_interface="$(get_default_network_interface)"
	if [[ -z "$_default_interface" ]]; then
		error "Unable to detect the default IPv4 network interface."
		exit 65
		fi

	add_nat_prerouting_rule_if_missing iptables "$_default_interface" -p udp --dport 10000:65000 -j DNAT --to-destination "$UDP_PORT"
	if has_command modprobe; then
		modprobe ip6table_nat > /dev/null 2>&1 || true
		fi
	if has_command ip6tables && ip6tables -t nat -S > /dev/null 2>&1; then
		add_nat_prerouting_rule_if_missing ip6tables "$_default_interface" -p udp --dport 10000:65000 -j DNAT --to-destination "$UDP_PORT"
		fi

	configure_hysteria_sysctl "$_default_interface"
	setup_bittorrent_firewall
	systemctl enable netfilter-persistent > /dev/null 2>&1 || true
	iptables-save > /etc/iptables/rules.v4
	if has_command ip6tables-save; then
		ip6tables-save > /etc/iptables/rules.v6
		fi
	systemctl enable hysteria-server.service
	systemctl start hysteria-server.service	
}



main() {
parse_arguments "$@"
	check_permission
	check_environment
	check_hysteria_user "hysteria"
	validate_hysteria_user
	check_hysteria_homedir "/var/lib/$HYSTERIA_USER"
	validate_hysteria_homedir
	case "$OPERATION" in
	"install")
	perform_install
	;;
	"remove")
	perform_remove
	;;
	 
	*)
	error "Unknown operation '$OPERATION'."
	;;
	esac
}

main "$@"

# vim:set ft=bash ts=2 sw=2 sts=2 et:
HYSTERIA
chmod 755 /opt/iptunnel/hysteria_vendor.sh

cat >/etc/iptunnel/config.json <<EOF
{
  "bind": "${BIND}",
  "port": ${PORT},
  "api_key": "${API_KEY}",
  "db_path": "/usr/sbin/iptunnel/iptunnel.db",
  "hostname": "${DOMAIN}",
  "public_ip": "${PUBLIC_IP}",
  "city": "",
  "isp": "",
  "allow_legacy_db_key": true,
    "ssh": {
      "manage_system_users": true,
      "shell": "/bin/false",
      "ws_path": "/sshws",
      "ws_path_aliases": ["/ssh"],
      "ports": {
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
    }
  },
  "slowdns": {
    "enabled": true,
    "service": "iptunnel-slowdns",
    "mux_service": "iptunnel-udp53-mux",
    "listen_port": 5300,
    "public_port": 53,
    "local_port": 8000,
    "target": "127.0.0.1:111",
    "public_hostname": "${DOMAIN}",
    "ns_host": "${DOMAIN}",
    "tunnel_domain": "dns.${DOMAIN}",
    "zone_prefix": "dns",
    "ns_prefix": "",
    "public_key_path": "/etc/iptunnel/slowdns/server.pub",
    "private_key_path": "/etc/iptunnel/slowdns/server.key",
    "info_path": "/var/www/html/slowdns-info.txt",
    "mtu": 1232
  },
  "hysteria": {
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
  },
  "license": {
    "enabled": $(if [[ -n "$LICENSE_URL" ]]; then echo "true"; else echo "false"; fi),
    "url": "${LICENSE_URL}",
    "master_token": "${LICENSE_TOKEN}",
    "server_id": "",
    "server_id_path": "/etc/iptunnel/license.id",
    "checkin_interval": 86400,
    "hmac_secret": "${HMAC_SECRET}",
    "session_ttl": 60
  },
  "xray": {
    "restart_services": true,
    "ports": {
      "any": "80,443",
      "none": "80",
      "tls": "443"
    },
    "paths": {
      "vmess": {
        "primary": "/vmess",
        "grpc": "vmess",
        "multi": "/vmess",
        "stn": "/vmess",
        "up": "/upvmess"
      },
      "vless": {
        "primary": "/vless",
        "grpc": "vless",
        "multi": "/vless",
        "stn": "/vless",
        "up": "/upvless"
      },
      "trojan": {
        "primary": "/trojan",
        "grpc": "trojan",
        "multi": "/trojan",
        "stn": "/trojan",
        "up": "/uptrojan"
      }
    },
    "configs": {
      "vmess": "/etc/iptunnel/xray/vmess.json",
      "vless": "/etc/iptunnel/xray/vless.json",
      "trojan": "/etc/iptunnel/xray/trojan.json"
    },
    "services": {
      "vmess": "iptunnel-vmess",
      "vless": "iptunnel-vless",
      "trojan": "iptunnel-trojan"
    }
  }
}
EOF
chmod 600 /etc/iptunnel/config.json

for f in /etc/iptunnel/xray/vmess.json /etc/iptunnel/xray/vless.json /etc/iptunnel/xray/trojan.json; do
  if [[ ! -f "$f" ]]; then
    cat >"$f" <<'EOF'
{
  "inbounds": [
    {
      "settings": {
        "clients": []
      }
    }
  ]
}
EOF
  fi
done

cat >/etc/systemd/system/iptunnel-api.service <<'UNIT'
[Unit]
Description=IPTunnel API
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
Environment=IPTUNNEL_API_CONFIG=/etc/iptunnel/config.json
ExecStart=/usr/bin/python3 /opt/iptunnel/iptunnel_api.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

if [[ ! -f /usr/sbin/iptunnel/cert/cert.crt || ! -f /usr/sbin/iptunnel/cert/cert.key ]]; then
  if [[ "$GENERATE_SELF_SIGNED" == "1" ]]; then
    openssl req -x509 -nodes -newkey rsa:2048 -days 825       -keyout /usr/sbin/iptunnel/cert/cert.key       -out /usr/sbin/iptunnel/cert/cert.crt       -subj "/CN=${DOMAIN}"       -addext "subjectAltName=DNS:${DOMAIN}"
  fi
fi

cat >/opt/iptunnel/transport_stack.sh <<'STACK'
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
STACK
chmod 755 /opt/iptunnel/transport_stack.sh

IPTUNNEL_DOMAIN="${DOMAIN}" IPTUNNEL_PUBLIC_IP="${PUBLIC_IP}" IPTUNNEL_CERT_DIR="/usr/sbin/iptunnel/cert" IPTUNNEL_API_PORT="${PORT}" IPTUNNEL_INSTALL_NGINX="${INSTALL_NGINX}" IPTUNNEL_ENABLE_HYSTERIA="${ENABLE_HYSTERIA}" IPTUNNEL_ENABLE_OPENVPN="${ENABLE_OPENVPN}" IPTUNNEL_SLOWDNS_UDP53_MODE="${SLOWDNS_UDP53_MODE}" IPTUNNEL_OPENVPN_UDP_PUBLIC_PORTS="${OPENVPN_UDP_PORTS}" IPTUNNEL_HYSTERIA_OBFS="${HYSTERIA_OBFS}" IPTUNNEL_HYSTERIA_PASSWORD="${HYSTERIA_PASSWORD}"   /opt/iptunnel/transport_stack.sh

# --- PAM auth script (disabled by default for rollout) ---
if [[ "${IPTUNNEL_ENABLE_PAM_AUTH:-0}" == "1" ]]; then
cat >/usr/local/bin/iptunnel-pam-check <<'PAMSCRIPT'
#!/usr/bin/env bash
# ---------------------------------------------------------------
# IPTunnel PAM Authentication Script
# Called by pam_exec.so during SSH password authentication.
#
# Flow:
#   1. Check if the password is a valid session token (via API)
#   2. If yes → allow (exit 0)
#   3. If no  → reject with user-facing message (exit 1)
#
# The IPTunnel Android app calls /session-token first to get a
# one-time token, then uses it as the SSH password.
# Foreign apps use the raw static password → rejected here.
#
# Install:
#   In /etc/pam.d/sshd, add BEFORE @include common-auth:
#     auth requisite pam_exec.so expose_authtok quiet /usr/local/bin/iptunnel-pam-check
# ---------------------------------------------------------------

API_URL="http://127.0.0.1:8080"
SKIP_USERS="root"

# PAM provides the username
USER="${PAM_USER:-}"

# Skip PAM check for admin users (root, etc.)
for skip in $SKIP_USERS; do
    if [ "$USER" = "$skip" ]; then
        exit 0
    fi
done

# Read the password from stdin (pam_exec expose_authtok)
read -r PASSWORD

if [ -z "$PASSWORD" ]; then
    echo "⚠ Authentication rejected: This server only accepts connections from the IPTunnel app." >&2
    echo "  Download IPTunnel VPN on the Google Play Store to connect." >&2
    exit 1
fi

# Ask the API if this is a valid session token
RESPONSE=$(curl -sf -X POST "$API_URL/verify-session" \
    -H "Content-Type: application/json" \
    -d "{\"token\": \"${PASSWORD}\"}" \
    --max-time 3 2>/dev/null) || RESPONSE=""

# Check for "status":"ok" without python3 (avoids ~100ms startup penalty per SSH)
if echo "$RESPONSE" | grep -qF '"status":"ok"' 2>/dev/null; then
    exit 0
fi
if echo "$RESPONSE" | grep -qF '"status": "ok"' 2>/dev/null; then
    exit 0
fi

# Not a valid session token → reject with message
echo "⚠ Authentication rejected: This server only accepts connections from the IPTunnel app." >&2
echo "  Download IPTunnel VPN on the Google Play Store to connect." >&2
exit 1
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
cfg.setdefault("license", {})["server_id"] = sid
p.write_text(json.dumps(cfg, indent=2))
PY
  echo "[+] server_id $EXISTING_SID written to config"
else
  # --- License: auto-authorize via IP if no token provided ---
  if [[ -n "$LICENSE_URL" && -z "$LICENSE_TOKEN" ]]; then
    echo "[*] No --license-token provided — checking IP authorization via API v2..."
    AUTH_RESP=$(curl -4 -sf -X POST "$LICENSE_URL/api/v2/install-tickets/issue"       -H "Content-Type: application/json"       -d "{}"       --max-time 15 2>/dev/null) || AUTH_RESP=""
    AUTO_TOKEN=$(echo "$AUTH_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('data',{}).get('ticket',''))" 2>/dev/null || echo "")
    AUTO_CLIENT=$(echo "$AUTH_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin).get('data',{}).get('client',{}); print(d.get('name',''))" 2>/dev/null || echo "")

    if [[ -z "$AUTO_TOKEN" ]]; then
      AUTH_RESP=$(curl -4 -sf -X GET "$LICENSE_URL/authorize"         --max-time 15 2>/dev/null) || AUTH_RESP=""
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
    LICENSE_RESP=$(curl -4 -sf -X POST "$LICENSE_URL/api/v2/servers/register"       -H "Content-Type: application/json"       -d "{\"token\": \"$LICENSE_TOKEN\", \"ip\": \"$PUBLIC_IP\", \"hostname\": \"$DOMAIN\"}"       --max-time 15 2>/dev/null) || LICENSE_RESP=""

    SERVER_ID=$(echo "$LICENSE_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('data',{}).get('server_id',''))" 2>/dev/null || echo "")

    if [[ -z "$SERVER_ID" ]]; then
      LICENSE_RESP=$(curl -4 -sf -X POST "$LICENSE_URL/register"         -H "Content-Type: application/json"         -d "{\"token\": \"$LICENSE_TOKEN\", \"ip\": \"$PUBLIC_IP\", \"hostname\": \"$DOMAIN\"}"         --max-time 15 2>/dev/null) || LICENSE_RESP=""
      SERVER_ID=$(echo "$LICENSE_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('server_id',''))" 2>/dev/null || echo "")
    fi

    if [[ -n "$SERVER_ID" ]]; then
      echo "$SERVER_ID" > /etc/iptunnel/license.id
      python3 - "$SERVER_ID" <<'PY'
import json, sys, pathlib
sid = sys.argv[1]
p = pathlib.Path("/etc/iptunnel/config.json")
cfg = json.loads(p.read_text())
cfg.setdefault("license", {})["server_id"] = sid
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
