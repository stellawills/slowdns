#!/usr/bin/env python3
from __future__ import annotations

import argparse
import copy
import datetime as dt
import http.server
import json
import os
import pathlib
import re
import secrets
import sqlite3
import subprocess
import sys
import traceback
import urllib.parse
from typing import Any, Dict, List, Optional, Tuple, Type, Union


APP_VERSION = "2026.03.29"
USERNAME_RE = re.compile(r"^[A-Za-z0-9._-]{1,20}$")
MAX_BODY_BYTES = 1_048_576

DEFAULT_CONFIG: Dict[str, Any] = {
    "bind": "127.0.0.1",
    "port": 8091,
    "db_path": "/opt/slowdns-only/config/slowdns-only.db",
    "hostname": "",
    "public_ip": "",
    "city": "",
    "isp": "",
    "ssh": {
        "manage_system_users": True,
        "shell": "/bin/false",
        "ws_path": "/sshws",
        "ports": {
            "any": "22,53",
            "none": "-",
            "ssh": "22",
            "dropbear": "-",
            "ssl": "-",
            "ws": "-",
            "slowdns": "53",
            "squid": "-",
            "hysteria": "-",
            "ovpnohp": "-",
            "ovpntcp": "-",
            "ovpnudp": "-",
        },
    },
    "slowdns": {
        "enabled": True,
        "service": "slowdns-only-dnstt",
        "listen_port": 5300,
        "public_port": 53,
        "redirect_53": True,
        "local_port": 8000,
        "target": "127.0.0.1:22",
        "tunnel_domain": "",
        "ns_host": "",
        "zone_prefix": "",
        "ns_prefix": "",
        "mtu": 512,
        "public_key_path": "/opt/slowdns-only/config/server.pub",
        "private_key_path": "/opt/slowdns-only/config/server.key",
    },
}


class ApiError(Exception):
    def __init__(self, status: int, message: str) -> None:
        super().__init__(message)
        self.status = status
        self.message = message


def utc_now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


def merge_dicts(base: Dict[str, Any], overlay: Dict[str, Any]) -> Dict[str, Any]:
    result = copy.deepcopy(base)
    for key, value in overlay.items():
        if isinstance(value, dict) and isinstance(result.get(key), dict):
            result[key] = merge_dicts(result[key], value)
        else:
            result[key] = value
    return result


def load_config(path: pathlib.Path) -> Dict[str, Any]:
    config = copy.deepcopy(DEFAULT_CONFIG)
    if path.exists():
        loaded = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(loaded, dict):
            raise ApiError(500, "config file must contain a JSON object")
        config = merge_dicts(config, loaded)
    env_bind = os.getenv("SLOWDNS_ONLY_API_BIND")
    env_port = os.getenv("SLOWDNS_ONLY_API_PORT")
    if env_bind:
        config["bind"] = env_bind
    if env_port:
        config["port"] = int(env_port)
    return config


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


def quota_to_storage(kuota: int) -> Tuple[int, str]:
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


def get_optional(payload: Dict[str, Any], *names: str, default: Any = None) -> Any:
    for name in names:
        if name in payload:
            return payload[name]
    return default


def get_required(payload: Dict[str, Any], *names: str) -> str:
    value = get_optional(payload, *names, default=None)
    if value is None or str(value).strip() == "":
        raise ApiError(400, f"missing required field: {names[0]}")
    return str(value).strip()


def get_int(payload: Dict[str, Any], *names: str) -> int:
    value = get_required(payload, *names)
    try:
        return int(value)
    except ValueError as exc:
        raise ApiError(400, f"{names[0]} must be an integer") from exc


def get_optional_int(payload: Dict[str, Any], *names: str, default: Optional[int] = None) -> Optional[int]:
    value = get_optional(payload, *names, default=None)
    if value is None or str(value).strip() == "":
        return default
    try:
        return int(str(value).strip())
    except ValueError as exc:
        raise ApiError(400, f"{names[0]} must be an integer") from exc


def expiry_timestamp(expires_on: str) -> int:
    return int(dt.datetime.fromisoformat(f"{expires_on}T00:00:00+00:00").timestamp())


def row_value(row: Union[sqlite3.Row, Dict[str, Any]], key: str, default: Any = None) -> Any:
    if isinstance(row, sqlite3.Row):
        return row[key] if key in row.keys() else default
    return row.get(key, default)


class SlowDnsOnlyState:
    def __init__(self, config_path: pathlib.Path, dry_run: bool = False) -> None:
        self.config_path = config_path
        self.dry_run = dry_run
        self.config = load_config(config_path)
        self.db_path = pathlib.Path(str(self.config.get("db_path") or "/opt/slowdns-only/config/slowdns-only.db"))
        self.db_path.parent.mkdir(parents=True, exist_ok=True)
        self._init_db()

    def refresh_config(self) -> None:
        self.config = load_config(self.config_path)

    def connect(self) -> sqlite3.Connection:
        conn = sqlite3.connect(str(self.db_path))
        conn.row_factory = sqlite3.Row
        return conn

    def _init_db(self) -> None:
        with self.connect() as conn:
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS account_sshs (
                    username TEXT PRIMARY KEY,
                    password TEXT NOT NULL,
                    date_exp TEXT NOT NULL,
                    date_time INTEGER NOT NULL,
                    days INTEGER NOT NULL DEFAULT 0,
                    limit_ip INTEGER NOT NULL DEFAULT 1,
                    at_trial INTEGER NOT NULL DEFAULT 0,
                    at_banned INTEGER NOT NULL DEFAULT 0,
                    max_bw INTEGER NOT NULL DEFAULT 0,
                    use_bw INTEGER NOT NULL DEFAULT 0,
                    max_bw_hum TEXT NOT NULL DEFAULT '0 GB',
                    use_bw_hum TEXT NOT NULL DEFAULT '0 GB',
                    type TEXT NOT NULL DEFAULT 'NORMAL',
                    protocol TEXT NOT NULL DEFAULT 'ALL',
                    status_lock TEXT NOT NULL DEFAULT 'UNLOCKED',
                    status TEXT NOT NULL DEFAULT 'AKTIF',
                    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
                    updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
                )
                """
            )
            conn.commit()

    def build_meta(self, code: int, status: str, message: str) -> Dict[str, Any]:
        return {
            "code": code,
            "status": status,
            "ip_address": self.public_ip(),
            "message": message,
        }

    def build_old_error(self, code: int, message: str) -> Dict[str, Any]:
        return {"meta": self.build_meta(code, "error", message), "data": {}}

    def build_list_response(self, rows: List[Dict[str, Any]]) -> Dict[str, Any]:
        total = len(rows)
        return {
            "meta": self.build_meta(200, "success", f"Total {total}"),
            "total": total,
            "data": rows,
        }

    def hostname(self) -> str:
        return str(self.config.get("hostname") or "")

    def public_ip(self) -> str:
        return str(self.config.get("public_ip") or "")

    def ssh_config(self) -> Dict[str, Any]:
        return dict(self.config.get("ssh") or {})

    def slowdns_config(self) -> Dict[str, Any]:
        return dict(self.config.get("slowdns") or {})

    def slowdns_enabled(self) -> bool:
        return bool(self.slowdns_config().get("enabled", False))

    @staticmethod
    def _compose_dns_name(prefix: str, host: str) -> str:
        prefix = str(prefix or "").strip(".")
        host = str(host or "").strip(".")
        if not prefix:
            return host
        if not host:
            return prefix
        if host == prefix or host.startswith(prefix + "."):
            return host
        return f"{prefix}.{host}"

    def slowdns_zone(self) -> str:
        config = self.slowdns_config()
        explicit = str(config.get("tunnel_domain") or "").strip(".")
        if explicit:
            return explicit
        prefix = str(config.get("zone_prefix") or "").strip(".")
        host = self.hostname().strip(".")
        return self._compose_dns_name(prefix, host)

    def slowdns_ns_host(self) -> str:
        config = self.slowdns_config()
        explicit = str(config.get("ns_host") or "").strip(".")
        if explicit:
            return explicit
        prefix = str(config.get("ns_prefix") or "").strip(".")
        host = self.hostname().strip(".")
        return self._compose_dns_name(prefix, host)

    def slowdns_public_key(self) -> str:
        path = pathlib.Path(str(self.slowdns_config().get("public_key_path") or ""))
        if not path.exists():
            return ""
        return path.read_text(encoding="utf-8").strip()

    def slowdns_info(self) -> Optional[Dict[str, Any]]:
        if not self.slowdns_enabled():
            return None
        config = self.slowdns_config()
        public_port = int(config.get("public_port", config.get("listen_port", 53)))
        return {
            "enabled": True,
            "listen_port": int(config.get("listen_port", 53)),
            "public_port": public_port,
            "local_port": int(config.get("local_port", 8000)),
            "ns_host": self.slowdns_ns_host(),
            "public_key": self.slowdns_public_key(),
            "records": {
                "a": {"type": "A", "name": self.slowdns_ns_host(), "value": self.public_ip()},
                "ns": {"type": "NS", "name": self.slowdns_zone(), "value": self.slowdns_ns_host()},
            },
            "service": str(config.get("service") or ""),
            "target": str(config.get("target") or "127.0.0.1:22"),
            "tunnel_domain": self.slowdns_zone(),
            "usage": {
                "summary": (
                    f"Create A {self.slowdns_ns_host()} -> {self.public_ip()} and "
                    f"NS {self.slowdns_zone()} -> {self.slowdns_ns_host()} on the parent zone."
                ),
                "connect_host": self.slowdns_zone(),
                "connect_port": public_port,
                "client_local_host": "127.0.0.1",
                "client_local_port": int(config.get("local_port", 8000)),
            },
        }

    def _run(self, command: List[str], stdin: Optional[str] = None) -> None:
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
        if not self.ssh_config().get("manage_system_users", True):
            return
        self._ensure_linux()
        shell = str(self.ssh_config().get("shell", "/bin/false"))
        user_exists = subprocess.run(
            ["id", username],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        ).returncode == 0
        if not user_exists:
            self._run(["useradd", "-M", "-s", shell, "-e", expires_on, username])
        else:
            self._run(["chage", "-E", expires_on, username])
        self._run(["chpasswd"], stdin=f"{username}:{password}\n")

    def delete_system_user(self, username: str) -> None:
        if not self.ssh_config().get("manage_system_users", True):
            return
        self._ensure_linux()
        if self.dry_run:
            return
        subprocess.run(["userdel", username], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=False)

    def lock_system_user(self, username: str) -> None:
        if not self.ssh_config().get("manage_system_users", True):
            return
        self._ensure_linux()
        self._run(["passwd", "-l", username])

    def unlock_system_user(self, username: str, password: Optional[str] = None) -> None:
        if not self.ssh_config().get("manage_system_users", True):
            return
        self._ensure_linux()
        self._run(["passwd", "-u", username])
        if password:
            self._run(["chpasswd"], stdin=f"{username}:{password}\n")

    def change_system_password(self, username: str, password: str) -> None:
        if not self.ssh_config().get("manage_system_users", True):
            return
        self._ensure_linux()
        self._run(["chpasswd"], stdin=f"{username}:{password}\n")

    def fetch_account(self, username: str) -> Optional[sqlite3.Row]:
        with self.connect() as conn:
            return conn.execute("SELECT * FROM account_sshs WHERE username = ?", (username,)).fetchone()

    def list_accounts(self) -> List[Dict[str, Any]]:
        self.reconcile_expired_accounts()
        with self.connect() as conn:
            rows = conn.execute("SELECT * FROM account_sshs ORDER BY username ASC").fetchall()
        return [dict(row) for row in rows]

    def list_recovery_accounts(self) -> List[Dict[str, Any]]:
        rows = self.list_accounts()
        return [
            row
            for row in rows
            if row.get("status_lock") == "LOCKED"
            or str(row.get("status", "")).upper() != "AKTIF"
            or int(row.get("at_banned", 0) or 0) != 0
        ]

    def reconcile_expired_accounts(self) -> int:
        today = dt.date.today().isoformat()
        updated = 0
        with self.connect() as conn:
            rows = conn.execute("SELECT username, status_lock FROM account_sshs WHERE date_exp < ?", (today,)).fetchall()
            for row in rows:
                if str(row["status_lock"]).upper() != "LOCKED":
                    try:
                        self.lock_system_user(str(row["username"]))
                    except Exception:
                        pass
                conn.execute(
                    """
                    UPDATE account_sshs
                    SET status = 'EXPIRED', status_lock = 'LOCKED', updated_at = CURRENT_TIMESTAMP
                    WHERE username = ?
                    """,
                    (row["username"],),
                )
                updated += 1
            conn.commit()
        return updated

    def build_ssh_payload(self, username: str, password: str, expires_on: str) -> Dict[str, Any]:
        host = self.hostname()
        ssh_cfg = self.ssh_config()
        ws_path = str(ssh_cfg.get("ws_path", "/sshws") or "/sshws")
        ports = dict(ssh_cfg.get("ports") or {})
        data = {
            "CITY": self.config.get("city", ""),
            "ISP": self.config.get("isp", ""),
            "exp": expires_on,
            "hostname": host,
            "password": password,
            "payloadws": {
                "payloadcdn": f"GET / HTTP/1.1[crlf]Host: {host}[crlf][crlf]",
                "payloadwithpath": (
                    f"GET {ws_path} HTTP/1.1[crlf]Host: {host}[crlf]Upgrade: websocket"
                    "[crlf]Connection: Upgrade[crlf][crlf]"
                ),
                "path": ws_path,
            },
            "payloadsquid": {
                "ssh_22": (
                    f"CONNECT {host}:22 HTTP/1.1[crlf]Host: {host}[crlf]X-Online-Host: {host}"
                    "[crlf]X-Forward-Host: " + host + "[crlf][crlf]"
                ),
            },
            "port": ports,
            "username": username,
        }
        slowdns = self.slowdns_info()
        if slowdns:
            data["slowdns"] = slowdns
        return {"meta": self.build_meta(200, "success", "Account ready"), "data": data}

    def insert_ssh_account(
        self,
        username: str,
        password: str,
        expired_days: int,
        limit_ip: int,
        max_bw_gb: int,
        trial: bool = False,
        trial_until: Optional[dt.datetime] = None,
    ) -> Dict[str, Any]:
        if self.fetch_account(username):
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

    def update_limit_ip(self, limit_ip: int, username: Optional[str] = None) -> Dict[str, Any]:
        with self.connect() as conn:
            if username:
                cursor = conn.execute(
                    "UPDATE account_sshs SET limit_ip = ?, updated_at = CURRENT_TIMESTAMP WHERE username = ?",
                    (limit_ip, username),
                )
                changed_user = username
            else:
                cursor = conn.execute(
                    "UPDATE account_sshs SET limit_ip = ?, updated_at = CURRENT_TIMESTAMP",
                    (limit_ip,),
                )
                changed_user = "ALL"
            conn.commit()
        if cursor.rowcount == 0:
            raise ApiError(404, "account not found")
        return {"meta": self.build_meta(200, "success", "Limit IP updated"), "data": {"message": f"limit ip => {limit_ip}", "username": changed_user}}

    def update_bandwidth(self, kuota_gb: int, reset_bw: bool, username: Optional[str] = None) -> Dict[str, Any]:
        max_bw, max_bw_hum = quota_to_storage(kuota_gb)
        if username:
            sql = """
                UPDATE account_sshs
                SET max_bw = ?, max_bw_hum = ?,
                    use_bw = CASE WHEN ? THEN 0 ELSE use_bw END,
                    use_bw_hum = CASE WHEN ? THEN '0 GB' ELSE use_bw_hum END,
                    updated_at = CURRENT_TIMESTAMP
                WHERE username = ?
            """
            params = (max_bw, max_bw_hum, 1 if reset_bw else 0, 1 if reset_bw else 0, username)
            changed_user = username
        else:
            sql = """
                UPDATE account_sshs
                SET max_bw = ?, max_bw_hum = ?,
                    use_bw = CASE WHEN ? THEN 0 ELSE use_bw END,
                    use_bw_hum = CASE WHEN ? THEN '0 GB' ELSE use_bw_hum END,
                    updated_at = CURRENT_TIMESTAMP
            """
            params = (max_bw, max_bw_hum, 1 if reset_bw else 0, 1 if reset_bw else 0)
            changed_user = "ALL"
        with self.connect() as conn:
            cursor = conn.execute(sql, params)
            conn.commit()
        if cursor.rowcount == 0:
            raise ApiError(404, "account not found")
        return {"meta": self.build_meta(200, "success", "Bandwidth updated"), "data": {"message": f"quota => {max_bw_hum}", "username": changed_user}}

    def modify_account(self, username: str, new_password: str) -> Dict[str, Any]:
        row = self.fetch_account(username)
        if not row:
            raise ApiError(404, "account not found")
        self.change_system_password(username, new_password)
        with self.connect() as conn:
            conn.execute(
                "UPDATE account_sshs SET password = ?, updated_at = CURRENT_TIMESTAMP WHERE username = ?",
                (new_password, username),
            )
            conn.commit()
        return {"meta": self.build_meta(200, "success", "Account updated"), "data": {"pass_uuid": new_password, "username": username}}

    def renew_account(self, username: str, expired_days: int, kuota_gb: Optional[int] = None) -> Dict[str, Any]:
        row = self.fetch_account(username)
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
        max_bw = int(row["max_bw"] or 0)
        max_bw_hum = str(row["max_bw_hum"] or "0 GB")
        if kuota_gb is not None:
            max_bw, max_bw_hum = quota_to_storage(kuota_gb)
        with self.connect() as conn:
            conn.execute(
                """
                UPDATE account_sshs
                SET date_exp = ?, date_time = ?, days = ?, max_bw = ?, max_bw_hum = ?,
                    status = 'AKTIF', status_lock = 'UNLOCKED', updated_at = CURRENT_TIMESTAMP
                WHERE username = ?
                """,
                (new_exp, expiry_timestamp(new_exp), expired_days, max_bw, max_bw_hum, username),
            )
            conn.commit()
        self.create_system_user(username, str(row["password"]), new_exp)
        return {"meta": self.build_meta(200, "success", "Account renewed"), "data": {"from": current_exp, "quota": max_bw_hum, "to": new_exp, "username": username}}

    def delete_account(self, username: str) -> Dict[str, Any]:
        row = self.fetch_account(username)
        if not row:
            raise ApiError(404, "account not found")
        self.delete_system_user(username)
        with self.connect() as conn:
            conn.execute("DELETE FROM account_sshs WHERE username = ?", (username,))
            conn.commit()
        return {"meta": self.build_meta(200, "success", "Account deleted"), "data": {"username": username}}

    def set_lock_state(self, username: str, locked: bool, password_override: Optional[str] = None) -> Dict[str, Any]:
        row = self.fetch_account(username)
        if not row:
            raise ApiError(404, "account not found")
        secret_value = password_override or str(row["password"])
        if locked:
            self.lock_system_user(username)
        else:
            self.unlock_system_user(username, password_override)
        new_state = "LOCKED" if locked else "UNLOCKED"
        with self.connect() as conn:
            if password_override:
                conn.execute(
                    """
                    UPDATE account_sshs
                    SET status_lock = ?, password = ?, status = ?, updated_at = CURRENT_TIMESTAMP
                    WHERE username = ?
                    """,
                    (new_state, password_override, "AKTIF", username),
                )
            else:
                conn.execute(
                    """
                    UPDATE account_sshs
                    SET status_lock = ?, status = ?, updated_at = CURRENT_TIMESTAMP
                    WHERE username = ?
                    """,
                    (new_state, "BANNED" if locked else "AKTIF", username),
                )
            conn.commit()
        return {"meta": self.build_meta(200, "success", "Account updated"), "data": {"expired": str(row["date_exp"]), "pass_uuid": secret_value, "status_lock": new_state, "username": username}}

    def service_summary(self) -> List[Dict[str, Any]]:
        services = [
            "slowdns-only-api",
            "slowdns-only-dnstt",
            "slowdns-only-udp53-redirect",
            "slowdns-only-expire-sync.timer",
        ]
        summary: List[Dict[str, Any]] = []
        for service in services:
            if os.name != "posix":
                summary.append({"name": service, "active": "unsupported", "enabled": "unsupported"})
                continue
            try:
                active = subprocess.run(["systemctl", "is-active", service], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=False).stdout.strip() or "unknown"
                enabled = subprocess.run(["systemctl", "is-enabled", service], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=False).stdout.strip() or "unknown"
            except OSError:
                active = "unsupported"
                enabled = "unsupported"
            summary.append({"name": service, "active": active, "enabled": enabled})
        return summary

    def runtime_summary(self) -> Dict[str, Any]:
        return {
            "version": APP_VERSION,
            "hostname": self.hostname(),
            "public_ip": self.public_ip(),
            "slowdns": self.slowdns_info(),
            "services": self.service_summary(),
        }


class SlowDnsOnlyHandler(http.server.BaseHTTPRequestHandler):
    server: "SlowDnsOnlyServer"

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

    def _send_json(self, status: int, payload: Dict[str, Any]) -> None:
        raw = json.dumps(payload, separators=(",", ":"), ensure_ascii=True).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def _send_v2_success(self, status: int, data: Dict[str, Any], meta: Optional[Dict[str, Any]] = None) -> None:
        payload = {"data": data, "meta": {"request_id": secrets.token_hex(8), "timestamp": utc_now().isoformat()}, "error": None}
        if meta:
            payload["meta"].update(meta)
        self._send_json(status, payload)

    def _send_v2_error(self, status: int, code: str, message: str, details: Optional[Dict[str, Any]] = None) -> None:
        self._send_json(status, {"data": None, "meta": {"request_id": secrets.token_hex(8), "timestamp": utc_now().isoformat()}, "error": {"code": code, "message": message, "details": details or {}}})

    def _read_body(self) -> Dict[str, Any]:
        raw_length = self.headers.get("Content-Length")
        try:
            length = int(raw_length or 0)
        except ValueError as exc:
            raise ApiError(400, "invalid Content-Length header") from exc
        if length < 0:
            raise ApiError(400, "invalid Content-Length header")
        if length == 0:
            return {}
        if length > MAX_BODY_BYTES:
            raise ApiError(413, "request body too large")
        raw = self.rfile.read(length)
        try:
            parsed = json.loads(raw.decode("utf-8"))
        except json.JSONDecodeError as exc:
            raise ApiError(400, "request body must be valid JSON") from exc
        if not isinstance(parsed, dict):
            raise ApiError(400, "request body must be a JSON object")
        return parsed

    def _v2_account_row(self, row: Union[sqlite3.Row, Dict[str, Any]]) -> Dict[str, Any]:
        return {
            "username": row_value(row, "username", ""),
            "expires_on": row_value(row, "date_exp", ""),
            "expires_at": int(row_value(row, "date_time", 0) or 0),
            "days": int(row_value(row, "days", 0) or 0),
            "limit_ip": int(row_value(row, "limit_ip", 0) or 0),
            "trial": int(row_value(row, "at_trial", 0) or 0) != 0,
            "banned": int(row_value(row, "at_banned", 0) or 0) != 0,
            "used_bytes": int(row_value(row, "use_bw", 0) or 0),
            "used_human": row_value(row, "use_bw_hum", "0 GB"),
            "max_bytes": int(row_value(row, "max_bw", 0) or 0),
            "max_human": row_value(row, "max_bw_hum", "0 GB"),
            "type": row_value(row, "type", ""),
            "protocol": row_value(row, "protocol", ""),
            "locked": str(row_value(row, "status_lock", "")).upper() == "LOCKED",
            "status_lock": row_value(row, "status_lock", ""),
            "status": row_value(row, "status", ""),
        }

    def _v2_current_quota_gb(self, row: sqlite3.Row) -> int:
        max_bw = int(row["max_bw"] or 0)
        if max_bw <= 0:
            return 0
        return max_bw // (1024 * 1024 * 1024)

    def _v2_account_detail(self, row: sqlite3.Row) -> Dict[str, Any]:
        username = str(row["username"])
        config = self.server.state.build_ssh_payload(username, str(row["password"]), str(row["date_exp"]))["data"]
        return {"protocol": "ssh", "account": self._v2_account_row(row), "config": config}

    def _create_account(self, body: Dict[str, Any], trial: bool, recovery: bool) -> Dict[str, Any]:
        state = self.server.state
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
        password = get_optional(body, "password", "pass_uuid")
        if trial and not password:
            password = random_password()
        if recovery and not password:
            raise ApiError(400, "password is required for recovery")
        if not password:
            raise ApiError(400, "password is required")
        return state.insert_ssh_account(username, str(password), expired_days, limit_ip, kuota, trial=trial, trial_until=trial_until)

    def _handle_patch_route(self, route: str) -> Dict[str, Any]:
        state = self.server.state
        renew = re.fullmatch(r"^/vps/renewsshvpn/(?P<username>[^/]+)/(?P<expired>\d+)$", route)
        if renew:
            return state.renew_account(safe_username(renew.group("username")), int(renew.group("expired")))
        lock = re.fullmatch(r"^/vps/locksshvpn/(?P<username>[^/]+)$", route)
        if lock:
            return state.set_lock_state(safe_username(lock.group("username")), True)
        unlock = re.fullmatch(r"^/vps/unlocksshvpn/(?P<username>[^/]+)/(?P<password>[^/]+)$", route)
        if unlock:
            return state.set_lock_state(safe_username(unlock.group("username")), False, unlock.group("password"))
        raise ApiError(404, "route not found")

    def _handle_v2_account_patch(self, username: str, body: Dict[str, Any]) -> Dict[str, Any]:
        state = self.server.state
        row = state.fetch_account(username)
        if not row:
            raise ApiError(404, "account not found")
        if "secret" in body or "password" in body:
            state.modify_account(username, get_required(body, "password", "secret", "pass_uuid"))
            row = state.fetch_account(username)
        if "limit_ip" in body:
            state.update_limit_ip(int(body["limit_ip"]), username)
            row = state.fetch_account(username)
        expires_in_days = get_optional_int(body, "expires_in_days", "days", "expired", default=None)
        quota_gb = get_optional_int(body, "quota_gb", "kuota", "quota", default=None)
        reset_bw = parse_reset_flag(get_optional(body, "reset_bandwidth", "reset_bw", default="false"))
        if expires_in_days is not None:
            state.renew_account(username, expires_in_days, quota_gb)
            row = state.fetch_account(username)
        elif quota_gb is not None or reset_bw:
            effective_quota = quota_gb if quota_gb is not None else self._v2_current_quota_gb(row)
            state.update_bandwidth(effective_quota, reset_bw, username)
            row = state.fetch_account(username)
        if "locked" in body:
            state.set_lock_state(username, parse_reset_flag(body["locked"]), get_optional(body, "unlock_password", "password"))
            row = state.fetch_account(username)
        if not row:
            raise ApiError(404, "account not found")
        return self._v2_account_detail(row)

    def _handle_v2_route(self, method: str, route: str, body: Dict[str, Any]) -> Tuple[int, Dict[str, Any], Optional[Dict[str, Any]]]:
        state = self.server.state
        if route == "/api/v2/healthz" and method == "GET":
            return 200, {"status": "ok", "version": "2"}, None
        if route == "/api/v2/vps/runtime" and method == "GET":
            return 200, state.runtime_summary(), None
        if route == "/api/v2/vps/services" and method == "GET":
            return 200, {"services": state.service_summary()}, None
        if route == "/api/v2/vps/accounts/ssh/recovery":
            if method == "GET":
                return 200, {"protocol": "ssh", "accounts": [self._v2_account_row(row) for row in state.list_recovery_accounts()]}, None
            if method == "POST":
                payload = self._create_account(body, trial=False, recovery=True)
                return 201, {"protocol": "ssh", "config": payload["data"]}, {"message": payload["meta"]["message"]}
        if route == "/api/v2/vps/accounts/ssh/trials" and method == "POST":
            payload = self._create_account(body, trial=True, recovery=False)
            return 201, {"protocol": "ssh", "config": payload["data"]}, {"message": payload["meta"]["message"]}
        if route == "/api/v2/vps/accounts/ssh":
            if method == "GET":
                return 200, {"protocol": "ssh", "accounts": [self._v2_account_row(row) for row in state.list_accounts()]}, None
            if method == "POST":
                payload = self._create_account(body, trial=False, recovery=False)
                return 201, {"protocol": "ssh", "config": payload["data"]}, {"message": payload["meta"]["message"]}
            if method == "PATCH":
                if "limit_ip" in body:
                    result = state.update_limit_ip(int(body["limit_ip"]), None)
                    return 200, {"protocol": "ssh", "scope": "all", "result": result["data"]}, {"message": result["meta"]["message"]}
                quota_gb = get_optional_int(body, "quota_gb", "kuota", "quota", default=None)
                reset_bw = parse_reset_flag(get_optional(body, "reset_bandwidth", "reset_bw", default="false"))
                if quota_gb is not None or reset_bw:
                    if quota_gb is None:
                        raise ApiError(400, "quota_gb is required for collection bandwidth updates")
                    result = state.update_bandwidth(quota_gb, reset_bw, None)
                    return 200, {"protocol": "ssh", "scope": "all", "result": result["data"]}, {"message": result["meta"]["message"]}
                raise ApiError(400, "no supported collection update fields provided")
        item_match = re.fullmatch(r"^/api/v2/vps/accounts/ssh/(?P<username>[^/]+)$", route)
        if item_match:
            username = safe_username(item_match.group("username"))
            row = state.fetch_account(username)
            if not row:
                raise ApiError(404, "account not found")
            if method == "GET":
                return 200, self._v2_account_detail(row), None
            if method == "PATCH":
                return 200, self._handle_v2_account_patch(username, body), None
            if method == "DELETE":
                state.delete_account(username)
                return 200, {"protocol": "ssh", "deleted": True, "username": username}, None
        raise ApiError(404, "route not found")

    def _handle_route(self, method: str, route: str, body: Dict[str, Any]) -> Dict[str, Any]:
        state = self.server.state
        if method == "GET":
            if route == "/vps/listuserssshvpn":
                return state.build_list_response(state.list_accounts())
            if route == "/vps/listrecoverysshvpn":
                return state.build_list_response(state.list_recovery_accounts())
            match = re.fullmatch(r"^/vps/checkconfigsshvpn/(?P<username>[^/]+)$", route)
            if match:
                username = safe_username(match.group("username"))
                row = state.fetch_account(username)
                if not row:
                    raise ApiError(404, "account not found")
                return state.build_ssh_payload(username, str(row["password"]), str(row["date_exp"]))
        if method == "POST":
            if route == "/vps/sshvpn":
                return self._create_account(body, trial=False, recovery=False)
            if route == "/vps/trialsshvpn":
                return self._create_account(body, trial=True, recovery=False)
            if route == "/vps/recoverysshvpn":
                return self._create_account(body, trial=False, recovery=True)
            if route == "/vps/modifysshvpn":
                return state.modify_account(safe_username(get_required(body, "username")), get_required(body, "pass_uuid", "password"))
            if route == "/vps/changelimipsshvpn":
                return state.update_limit_ip(get_int(body, "limitip", "limit_ip"), safe_username(get_required(body, "username")))
            if route == "/vps/changelimipallsshvpn":
                return state.update_limit_ip(get_int(body, "limitip", "limit_ip"), None)
            return self._handle_patch_route(route)
        if method == "PATCH":
            return self._handle_patch_route(route)
        if method == "DELETE":
            match = re.fullmatch(r"^/vps/deletesshvpn/(?P<username>[^/]+)$", route)
            if match:
                return state.delete_account(safe_username(match.group("username")))
        raise ApiError(404, "route not found")

    def _dispatch(self, method: str) -> None:
        is_v2_route = False
        try:
            self.server.state.refresh_config()
            self.server.state.reconcile_expired_accounts()
            route = urllib.parse.urlparse(self.path).path
            is_v2_route = route.startswith("/api/v2")
            body = self._read_body() if method in {"POST", "PATCH"} else {}
            if route == "/healthz" and method == "GET":
                self._send_json(200, {"status": "ok"})
                return
            if is_v2_route:
                status, data, meta = self._handle_v2_route(method, route, body)
                self._send_v2_success(status, data, meta)
                return
            payload = self._handle_route(method, route, body)
            status = 201 if payload.get("meta", {}).get("code") == 201 else 200
            self._send_json(status, payload)
        except ApiError as exc:
            if is_v2_route:
                self._send_v2_error(exc.status, "request_error", exc.message)
            else:
                self._send_json(exc.status, self.server.state.build_old_error(exc.status, exc.message))
        except Exception as exc:
            traceback.print_exc()
            if is_v2_route:
                self._send_v2_error(500, "internal_error", str(exc) or "internal server error")
            else:
                self._send_json(500, self.server.state.build_old_error(500, str(exc) or "internal server error"))


class SlowDnsOnlyServer(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address: Tuple[str, int], handler: Type[SlowDnsOnlyHandler], state: SlowDnsOnlyState) -> None:
        super().__init__(address, handler)
        self.state = state


def serve(config_path: pathlib.Path, dry_run: bool) -> None:
    state = SlowDnsOnlyState(config_path, dry_run=dry_run)
    bind = str(state.config.get("bind") or "127.0.0.1")
    port = int(state.config.get("port") or 8091)
    server = SlowDnsOnlyServer((bind, port), SlowDnsOnlyHandler, state)
    print(f"slowdns-only api listening on {bind}:{port}", flush=True)
    server.serve_forever()


def run_expire_sync(config_path: pathlib.Path, dry_run: bool) -> None:
    state = SlowDnsOnlyState(config_path, dry_run=dry_run)
    print(json.dumps({"updated": state.reconcile_expired_accounts()}))


def main() -> int:
    parser = argparse.ArgumentParser(description="Standalone SlowDNS-only API")
    parser.add_argument("--config", default="/opt/slowdns-only/config/config.json")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--expire-sync", action="store_true")
    args = parser.parse_args()
    config_path = pathlib.Path(args.config)
    if args.expire_sync:
        run_expire_sync(config_path, dry_run=args.dry_run)
        return 0
    serve(config_path, dry_run=args.dry_run)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
