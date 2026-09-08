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
