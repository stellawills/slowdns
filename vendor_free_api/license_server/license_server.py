#!/usr/bin/env python3
"""
IPTunnel License Server — deployed at license.internetshub.com

Endpoints
---------
POST /register   — installer self-registers a server (requires master token)
POST /checkin    — daily heartbeat from a running iptunnel_api service
POST /revoke     — admin revokes a server_id (requires master token)
GET  /status     — admin lists all registered servers (requires master token)
GET  /healthz    — simple liveness probe (public)
"""
from __future__ import annotations

import argparse
import datetime as dt
import http.server
import json
import os
import secrets
import sqlite3
import sys
import threading
import traceback
import uuid
from typing import Any


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
DEFAULT_CONFIG: dict[str, Any] = {
    "bind": "0.0.0.0",
    "port": 9090,
    "master_token": "CHANGE_ME",
    "db_path": "/opt/license-server/license.db",
    "schema_path": "/opt/license-server/license_schema.sql",
}


def load_config(path: str | None) -> dict[str, Any]:
    config = dict(DEFAULT_CONFIG)
    if path and os.path.isfile(path):
        with open(path, encoding="utf-8") as fh:
            config.update(json.load(fh))
    # Environment overrides
    for key in ("bind", "port", "master_token", "db_path", "schema_path"):
        env = f"LICENSE_{key.upper()}"
        val = os.getenv(env)
        if val is not None:
            config[key] = int(val) if key == "port" else val
    return config


# ---------------------------------------------------------------------------
# State (database)
# ---------------------------------------------------------------------------
class LicenseState:
    def __init__(self, config: dict[str, Any]) -> None:
        self.config = config
        self._local = threading.local()
        self._init_db()

    def _get_conn(self) -> sqlite3.Connection:
        conn = getattr(self._local, "conn", None)
        if conn is None:
            conn = sqlite3.connect(self.config["db_path"])
            conn.row_factory = sqlite3.Row
            conn.execute("PRAGMA journal_mode=WAL")
            conn.execute("PRAGMA foreign_keys=ON")
            self._local.conn = conn
        return conn

    def _init_db(self) -> None:
        conn = self._get_conn()
        schema_path = self.config["schema_path"]
        if os.path.isfile(schema_path):
            with open(schema_path, encoding="utf-8") as fh:
                conn.executescript(fh.read())
        else:
            # Inline fallback
            conn.executescript(
                """
                CREATE TABLE IF NOT EXISTS servers (
                    server_id     TEXT PRIMARY KEY,
                    ip            TEXT NOT NULL,
                    hostname      TEXT NOT NULL DEFAULT '',
                    token         TEXT NOT NULL,
                    registered_at TEXT NOT NULL DEFAULT (datetime('now')),
                    last_checkin  TEXT,
                    revoked       INTEGER NOT NULL DEFAULT 0,
                    note          TEXT NOT NULL DEFAULT ''
                );
                CREATE INDEX IF NOT EXISTS idx_servers_ip    ON servers(ip);
                CREATE INDEX IF NOT EXISTS idx_servers_token ON servers(token);
                """
            )
        conn.commit()

    # -- Master token validation ------------------------------------------------
    def verify_master(self, token: str) -> bool:
        return secrets.compare_digest(token, self.config["master_token"])

    # -- Registration -----------------------------------------------------------
    def register(self, ip: str, hostname: str, token: str) -> dict[str, Any]:
        """Register a new server. Returns the server record."""
        # Check if this IP is already registered under this token
        conn = self._get_conn()
        row = conn.execute(
            "SELECT server_id, revoked FROM servers WHERE ip = ? AND token = ?",
            (ip, token),
        ).fetchone()
        if row:
            # Re-registration: reactivate if revoked, update checkin
            server_id = row["server_id"]
            conn.execute(
                "UPDATE servers SET revoked = 0, last_checkin = datetime('now'), hostname = ? WHERE server_id = ?",
                (hostname, server_id),
            )
            conn.commit()
            return self._server_dict(server_id)

        server_id = uuid.uuid4().hex[:16]
        conn.execute(
            "INSERT INTO servers (server_id, ip, hostname, token) VALUES (?, ?, ?, ?)",
            (server_id, ip, hostname, token),
        )
        conn.commit()
        return self._server_dict(server_id)

    # -- Check-in ---------------------------------------------------------------
    def checkin(self, server_id: str) -> dict[str, Any] | None:
        conn = self._get_conn()
        row = conn.execute(
            "SELECT server_id, revoked FROM servers WHERE server_id = ?",
            (server_id,),
        ).fetchone()
        if not row:
            return None
        if row["revoked"]:
            return {"status": "revoked", "server_id": server_id}
        conn.execute(
            "UPDATE servers SET last_checkin = datetime('now') WHERE server_id = ?",
            (server_id,),
        )
        conn.commit()
        return {"status": "ok", "server_id": server_id}

    # -- Revoke -----------------------------------------------------------------
    def revoke(self, server_id: str) -> bool:
        conn = self._get_conn()
        cur = conn.execute(
            "UPDATE servers SET revoked = 1 WHERE server_id = ?", (server_id,)
        )
        conn.commit()
        return cur.rowcount > 0

    # -- List -------------------------------------------------------------------
    def list_servers(self) -> list[dict[str, Any]]:
        conn = self._get_conn()
        rows = conn.execute(
            "SELECT server_id, ip, hostname, token, registered_at, last_checkin, revoked, note "
            "FROM servers ORDER BY registered_at DESC"
        ).fetchall()
        return [dict(r) for r in rows]

    # -- Helpers ----------------------------------------------------------------
    def _server_dict(self, server_id: str) -> dict[str, Any]:
        conn = self._get_conn()
        row = conn.execute("SELECT * FROM servers WHERE server_id = ?", (server_id,)).fetchone()
        return dict(row) if row else {}


# ---------------------------------------------------------------------------
# HTTP Handler
# ---------------------------------------------------------------------------
class LicenseHandler(http.server.BaseHTTPRequestHandler):
    server: LicenseServer  # type hint for IDE

    # Silence per-request log lines
    def log_message(self, fmt: str, *args: Any) -> None:
        pass

    # -- Routing ----------------------------------------------------------------
    def do_GET(self) -> None:
        self._dispatch("GET")

    def do_POST(self) -> None:
        self._dispatch("POST")

    def _dispatch(self, method: str) -> None:
        parsed = urllib.parse.urlparse(self.path) if hasattr(self, "path") else None
        # We only need the path portion
        path = self.path.split("?")[0].rstrip("/") or "/"

        try:
            if path == "/healthz" and method == "GET":
                self._json(200, {"status": "ok"})
                return

            if path == "/register" and method == "POST":
                self._handle_register()
                return

            if path == "/checkin" and method == "POST":
                self._handle_checkin()
                return

            if path == "/revoke" and method == "POST":
                self._handle_revoke()
                return

            if path == "/status" and method == "GET":
                self._handle_status()
                return

            self._json(404, {"error": "not found"})

        except Exception:
            traceback.print_exc()
            self._json(500, {"error": "internal server error"})

    # -- Handlers ---------------------------------------------------------------
    def _handle_register(self) -> None:
        body = self._read_json()
        if body is None:
            return
        token = body.get("token", "")
        ip = body.get("ip", "")
        hostname = body.get("hostname", "")

        if not token or not ip:
            self._json(400, {"error": "missing 'token' and/or 'ip'"})
            return

        state: LicenseState = self.server.state
        if not state.verify_master(token):
            self._json(403, {"error": "invalid token"})
            return

        result = state.register(ip, hostname, token)
        self._json(200, {"status": "authorized", **result})

    def _handle_checkin(self) -> None:
        body = self._read_json()
        if body is None:
            return
        server_id = body.get("server_id", "")
        if not server_id:
            self._json(400, {"error": "missing 'server_id'"})
            return

        state: LicenseState = self.server.state
        result = state.checkin(server_id)
        if result is None:
            self._json(404, {"error": "unknown server_id"})
            return
        if result.get("status") == "revoked":
            self._json(403, result)
            return
        self._json(200, result)

    def _handle_revoke(self) -> None:
        if not self._require_master():
            return
        body = self._read_json()
        if body is None:
            return
        server_id = body.get("server_id", "")
        if not server_id:
            self._json(400, {"error": "missing 'server_id'"})
            return

        state: LicenseState = self.server.state
        if state.revoke(server_id):
            self._json(200, {"status": "revoked", "server_id": server_id})
        else:
            self._json(404, {"error": "unknown server_id"})

    def _handle_status(self) -> None:
        if not self._require_master():
            return
        state: LicenseState = self.server.state
        servers = state.list_servers()
        self._json(200, {"count": len(servers), "servers": servers})

    # -- Auth helpers -----------------------------------------------------------
    def _get_token(self) -> str:
        auth = self.headers.get("Authorization", "")
        if auth.lower().startswith("bearer "):
            return auth[7:].strip()
        return auth.strip()

    def _require_master(self) -> bool:
        token = self._get_token()
        state: LicenseState = self.server.state
        if not state.verify_master(token):
            self._json(403, {"error": "master token required"})
            return False
        return True

    # -- I/O helpers ------------------------------------------------------------
    def _read_json(self) -> dict[str, Any] | None:
        length = int(self.headers.get("Content-Length", 0))
        if length == 0:
            self._json(400, {"error": "empty body"})
            return None
        try:
            return json.loads(self.rfile.read(length))
        except (json.JSONDecodeError, UnicodeDecodeError):
            self._json(400, {"error": "invalid JSON"})
            return None

    def _json(self, status: int, data: Any) -> None:
        body = json.dumps(data, indent=2).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


# ---------------------------------------------------------------------------
# Server
# ---------------------------------------------------------------------------
import urllib.parse  # noqa: E402 (used in _dispatch)


class LicenseServer(http.server.ThreadingHTTPServer):
    def __init__(
        self,
        server_address: tuple[str, int],
        handler_cls: type[LicenseHandler],
        state: LicenseState,
    ) -> None:
        super().__init__(server_address, handler_cls)
        self.state = state


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="IPTunnel License Server")
    parser.add_argument(
        "--config",
        default=os.getenv("LICENSE_CONFIG", ""),
        help="Path to JSON config file.",
    )
    parser.add_argument("--bind", default="", help="Override bind address.")
    parser.add_argument("--port", type=int, default=0, help="Override listen port.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    config = load_config(args.config or None)
    if args.bind:
        config["bind"] = args.bind
    if args.port:
        config["port"] = args.port

    if config["master_token"] == "CHANGE_ME":
        print("WARNING: master_token is still 'CHANGE_ME' — generating a random one.")
        config["master_token"] = secrets.token_hex(24)
        print(f"  Generated master_token: {config['master_token']}")
        print("  Save this in your config file!")

    state = LicenseState(config)
    server = LicenseServer(
        (config["bind"], int(config["port"])), LicenseHandler, state
    )
    print(f"IPTunnel License Server listening on http://{config['bind']}:{config['port']}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
