#!/usr/bin/env python3
from __future__ import annotations

import base64
import datetime as dt
import hashlib
import hmac
import http.server
import json
import os
import pathlib
import re
import secrets
import sqlite3
import traceback
import urllib.parse
from typing import Any, Dict, List, Optional, Tuple


APP_VERSION = "2026.03.30"
MAX_BODY_BYTES = 1_048_576
LICENSE_RE = re.compile(r"^IPT-[A-Z]{2}-[A-Z0-9]{6}-[A-Z0-9]{6}-[A-Z0-9]{6}$")
PRODUCT_RE = re.compile(r"^[a-z0-9_-]{2,32}$")


def utc_now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


def now_iso() -> str:
    return utc_now().isoformat()


def parse_int(value: Any, default: int = 0) -> int:
    try:
        return int(value)
    except Exception:
        return default


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode("ascii").rstrip("=")


def b64url_json(obj: Dict[str, Any]) -> str:
    return b64url(json.dumps(obj, separators=(",", ":"), sort_keys=True).encode("utf-8"))


def token_sign(secret: str, header: Dict[str, Any], payload: Dict[str, Any]) -> str:
    head = b64url_json(header)
    body = b64url_json(payload)
    message = f"{head}.{body}".encode("utf-8")
    signature = hmac.new(secret.encode("utf-8"), message, hashlib.sha256).digest()
    return f"{head}.{body}.{b64url(signature)}"


def token_verify(secret: str, token: str) -> Dict[str, Any]:
    parts = token.split(".")
    if len(parts) != 3:
        raise ValueError("invalid token")
    head, body, signature = parts
    message = f"{head}.{body}".encode("utf-8")
    expected = b64url(hmac.new(secret.encode("utf-8"), message, hashlib.sha256).digest())
    if not hmac.compare_digest(expected, signature):
        raise ValueError("signature mismatch")
    payload_raw = base64.urlsafe_b64decode(body + "=" * ((4 - len(body) % 4) % 4))
    payload = json.loads(payload_raw.decode("utf-8"))
    if int(payload.get("exp", 0)) < int(utc_now().timestamp()):
        raise ValueError("token expired")
    return payload


class ApiError(Exception):
    def __init__(self, status: int, code: str, message: str) -> None:
        super().__init__(message)
        self.status = status
        self.code = code
        self.message = message


class LicenseState:
    def __init__(self, db_path: pathlib.Path, signing_secret: str, issuer: str) -> None:
        self.db_path = db_path
        self.db_path.parent.mkdir(parents=True, exist_ok=True)
        self.signing_secret = signing_secret
        self.issuer = issuer
        self._init_db()

    def connect(self) -> sqlite3.Connection:
        conn = sqlite3.connect(str(self.db_path))
        conn.row_factory = sqlite3.Row
        return conn

    def _init_db(self) -> None:
        with self.connect() as conn:
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS licenses (
                    license_key TEXT PRIMARY KEY,
                    product TEXT NOT NULL,
                    status TEXT NOT NULL DEFAULT 'active',
                    max_activations INTEGER NOT NULL DEFAULT 1,
                    expires_at TEXT,
                    note TEXT NOT NULL DEFAULT '',
                    created_at TEXT NOT NULL,
                    revoked_at TEXT
                )
                """
            )
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS activations (
                    activation_id TEXT PRIMARY KEY,
                    license_key TEXT NOT NULL,
                    product TEXT NOT NULL,
                    machine_id TEXT NOT NULL,
                    ssh_fingerprint TEXT NOT NULL,
                    public_ip TEXT NOT NULL,
                    hostname TEXT NOT NULL,
                    install_token TEXT,
                    install_token_expires_at TEXT,
                    install_token_used_at TEXT,
                    created_at TEXT NOT NULL,
                    last_seen_at TEXT NOT NULL,
                    released_at TEXT,
                    FOREIGN KEY(license_key) REFERENCES licenses(license_key)
                )
                """
            )
            conn.execute(
                "CREATE INDEX IF NOT EXISTS idx_activations_license_key ON activations(license_key)"
            )
            conn.execute(
                """
                CREATE UNIQUE INDEX IF NOT EXISTS idx_activations_binding
                ON activations(license_key, machine_id, ssh_fingerprint)
                WHERE released_at IS NULL
                """
            )
            conn.commit()

    def key_hint(self, license_key: str) -> str:
        return f"{license_key[:6]}...{license_key[-4:]}"

    def generate_license_key(self, product: str) -> str:
        prefix = "SD" if product == "slowdns" else product[:2].upper()
        alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

        def part() -> str:
            return "".join(secrets.choice(alphabet) for _ in range(6))

        while True:
            candidate = f"IPT-{prefix}-{part()}-{part()}-{part()}"
            with self.connect() as conn:
                exists = conn.execute(
                    "SELECT 1 FROM licenses WHERE license_key = ?",
                    (candidate,),
                ).fetchone()
            if not exists:
                return candidate

    def create_license(
        self,
        product: str,
        max_activations: int,
        expires_in_days: int,
        note: str,
    ) -> Dict[str, Any]:
        if not PRODUCT_RE.fullmatch(product):
            raise ApiError(400, "invalid_product", "product must be lowercase letters, numbers, dash, or underscore")
        if max_activations < 1:
            raise ApiError(400, "invalid_limit", "max_activations must be at least 1")
        expires_at = None
        if expires_in_days > 0:
            expires_at = (utc_now() + dt.timedelta(days=expires_in_days)).replace(microsecond=0).isoformat()
        license_key = self.generate_license_key(product)
        created_at = now_iso()
        with self.connect() as conn:
            conn.execute(
                """
                INSERT INTO licenses (license_key, product, status, max_activations, expires_at, note, created_at, revoked_at)
                VALUES (?, ?, 'active', ?, ?, ?, ?, NULL)
                """,
                (license_key, product, max_activations, expires_at, note, created_at),
            )
            conn.commit()
        return self.get_license(license_key)

    def get_license_row(self, license_key: str) -> sqlite3.Row:
        if not LICENSE_RE.fullmatch(license_key):
            raise ApiError(400, "invalid_key", "license key format is invalid")
        with self.connect() as conn:
            row = conn.execute("SELECT * FROM licenses WHERE license_key = ?", (license_key,)).fetchone()
        if not row:
            raise ApiError(404, "license_not_found", "license key was not found")
        return row

    def get_license(self, license_key: str) -> Dict[str, Any]:
        row = self.get_license_row(license_key)
        return {
            "license_key": row["license_key"],
            "license_key_hint": self.key_hint(row["license_key"]),
            "product": row["product"],
            "status": row["status"],
            "max_activations": int(row["max_activations"] or 0),
            "expires_at": row["expires_at"],
            "note": row["note"],
            "created_at": row["created_at"],
            "revoked_at": row["revoked_at"],
        }

    def list_activations(self, license_key: str) -> List[Dict[str, Any]]:
        with self.connect() as conn:
            rows = conn.execute(
                """
                SELECT * FROM activations
                WHERE license_key = ?
                ORDER BY created_at ASC
                """,
                (license_key,),
            ).fetchall()
        return [dict(row) for row in rows]

    def revoke_license(self, license_key: str) -> Dict[str, Any]:
        self.get_license_row(license_key)
        revoked_at = now_iso()
        with self.connect() as conn:
            conn.execute(
                "UPDATE licenses SET status = 'revoked', revoked_at = ? WHERE license_key = ?",
                (revoked_at, license_key),
            )
            conn.commit()
        return self.get_license(license_key)

    def _active_activation_count(self, conn: sqlite3.Connection, license_key: str) -> int:
        row = conn.execute(
            """
            SELECT COUNT(*) AS total
            FROM activations
            WHERE license_key = ? AND released_at IS NULL
            """,
            (license_key,),
        ).fetchone()
        return int(row["total"] or 0)

    def activate_install(self, body: Dict[str, Any]) -> Dict[str, Any]:
        license_key = str(body.get("license_key") or "").strip().upper()
        product = str(body.get("product") or "slowdns").strip().lower()
        hostname = str(body.get("hostname") or "").strip().lower()
        public_ip = str(body.get("public_ip") or "").strip()
        machine_id = str(body.get("machine_id") or "").strip()
        ssh_fingerprint = str(body.get("ssh_fingerprint") or "").strip()
        requested_ref = str(body.get("requested_ref") or "main").strip()
        installer_version = str(body.get("installer_version") or "").strip()

        if not all([license_key, hostname, public_ip, machine_id, ssh_fingerprint]):
            raise ApiError(400, "missing_fields", "license_key, hostname, public_ip, machine_id, and ssh_fingerprint are required")

        with self.connect() as conn:
            row = conn.execute("SELECT * FROM licenses WHERE license_key = ?", (license_key,)).fetchone()
            if not row:
                raise ApiError(404, "license_not_found", "license key was not found")
            if row["product"] != product:
                raise ApiError(403, "product_mismatch", "license key is not valid for this product")
            if str(row["status"]).lower() != "active":
                raise ApiError(403, "license_revoked", "license key is not active")
            if row["expires_at"]:
                expires_at = dt.datetime.fromisoformat(str(row["expires_at"]))
                if expires_at < utc_now():
                    raise ApiError(403, "license_expired", "license key has expired")

            existing = conn.execute(
                """
                SELECT * FROM activations
                WHERE license_key = ? AND machine_id = ? AND ssh_fingerprint = ? AND released_at IS NULL
                """,
                (license_key, machine_id, ssh_fingerprint),
            ).fetchone()

            if not existing and self._active_activation_count(conn, license_key) >= int(row["max_activations"] or 0):
                raise ApiError(403, "activation_limit", "maximum activations reached for this key")

            activation_id = str(existing["activation_id"]) if existing else f"act_{secrets.token_hex(8)}"
            issued_at = utc_now()
            expires_at = issued_at + dt.timedelta(minutes=5)
            payload = {
                "iss": self.issuer,
                "typ": "slowdns_install",
                "sub": activation_id,
                "prd": product,
                "key": license_key,
                "mid": hashlib.sha256(machine_id.encode("utf-8")).hexdigest(),
                "ssh": hashlib.sha256(ssh_fingerprint.encode("utf-8")).hexdigest(),
                "ip": public_ip,
                "hst": hostname,
                "ref": requested_ref,
                "ver": installer_version,
                "iat": int(issued_at.timestamp()),
                "exp": int(expires_at.timestamp()),
                "jti": secrets.token_hex(8),
            }
            token = token_sign(self.signing_secret, {"alg": "HS256", "typ": "LIT", "kid": "v1"}, payload)
            if existing:
                conn.execute(
                    """
                    UPDATE activations
                    SET public_ip = ?, hostname = ?, install_token = ?, install_token_expires_at = ?,
                        install_token_used_at = NULL, last_seen_at = ?
                    WHERE activation_id = ?
                    """,
                    (public_ip, hostname, token, expires_at.isoformat(), now_iso(), activation_id),
                )
            else:
                conn.execute(
                    """
                    INSERT INTO activations (
                        activation_id, license_key, product, machine_id, ssh_fingerprint, public_ip,
                        hostname, install_token, install_token_expires_at, install_token_used_at,
                        created_at, last_seen_at, released_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, ?, NULL)
                    """,
                    (
                        activation_id,
                        license_key,
                        product,
                        machine_id,
                        ssh_fingerprint,
                        public_ip,
                        hostname,
                        token,
                        expires_at.isoformat(),
                        now_iso(),
                        now_iso(),
                    ),
                )
            conn.commit()

        return {
            "activation_id": activation_id,
            "install_token": token,
            "install_token_expires_at": expires_at.isoformat(),
            "license": {
                "license_key_hint": self.key_hint(license_key),
                "product": product,
                "max_activations": int(row["max_activations"] or 0),
                "expires_at": row["expires_at"],
                "status": row["status"],
            },
            "machine_binding": {
                "hostname": hostname,
                "public_ip": public_ip,
                "machine_id": machine_id,
                "ssh_fingerprint": ssh_fingerprint,
            },
        }

    def confirm_install(self, body: Dict[str, Any]) -> Dict[str, Any]:
        activation_id = str(body.get("activation_id") or "").strip()
        install_token = str(body.get("install_token") or "").strip()
        if not activation_id or not install_token:
            raise ApiError(400, "missing_fields", "activation_id and install_token are required")

        payload = token_verify(self.signing_secret, install_token)
        if payload.get("sub") != activation_id:
            raise ApiError(403, "token_mismatch", "install token does not match activation")

        with self.connect() as conn:
            row = conn.execute(
                """
                SELECT * FROM activations
                WHERE activation_id = ? AND released_at IS NULL
                """,
                (activation_id,),
            ).fetchone()
            if not row:
                raise ApiError(404, "activation_not_found", "activation was not found")
            if str(row["install_token"] or "") != install_token:
                raise ApiError(403, "token_mismatch", "install token is not valid for this activation")
            if row["install_token_used_at"]:
                raise ApiError(409, "token_used", "install token has already been used")
            conn.execute(
                """
                UPDATE activations
                SET install_token_used_at = ?, last_seen_at = ?
                WHERE activation_id = ?
                """,
                (now_iso(), now_iso(), activation_id),
            )
            conn.commit()
        return {"activation_id": activation_id, "status": "confirmed"}

    def release_install(self, body: Dict[str, Any]) -> Dict[str, Any]:
        activation_id = str(body.get("activation_id") or "").strip()
        license_key = str(body.get("license_key") or "").strip().upper()
        if not activation_id or not license_key:
            raise ApiError(400, "missing_fields", "activation_id and license_key are required")
        with self.connect() as conn:
            row = conn.execute(
                """
                SELECT * FROM activations
                WHERE activation_id = ? AND license_key = ? AND released_at IS NULL
                """,
                (activation_id, license_key),
            ).fetchone()
            if not row:
                raise ApiError(404, "activation_not_found", "activation was not found")
            conn.execute(
                """
                UPDATE activations
                SET released_at = ?, last_seen_at = ?
                WHERE activation_id = ?
                """,
                (now_iso(), now_iso(), activation_id),
            )
            conn.commit()
        return {"activation_id": activation_id, "status": "released"}


class LicenseHandler(http.server.BaseHTTPRequestHandler):
    server: "LicenseServer"

    def log_message(self, fmt: str, *args: Any) -> None:
        return

    def do_GET(self) -> None:
        self._dispatch("GET")

    def do_POST(self) -> None:
        self._dispatch("POST")

    def _json_success(self, status: int, data: Dict[str, Any], message: str = "") -> None:
        self._send_json(
            status,
            {
                "data": data,
                "meta": {
                    "request_id": secrets.token_hex(8),
                    "timestamp": now_iso(),
                    "version": APP_VERSION,
                    "message": message,
                },
                "error": None,
            },
        )

    def _json_error(self, status: int, code: str, message: str) -> None:
        self._send_json(
            status,
            {
                "data": None,
                "meta": {
                    "request_id": secrets.token_hex(8),
                    "timestamp": now_iso(),
                    "version": APP_VERSION,
                },
                "error": {
                    "code": code,
                    "message": message,
                },
            },
        )

    def _send_json(self, status: int, payload: Dict[str, Any]) -> None:
        raw = json.dumps(payload, separators=(",", ":"), ensure_ascii=True).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def _require_admin(self) -> None:
        expected = self.server.admin_token
        if not expected:
            raise ApiError(500, "admin_disabled", "admin token is not configured")
        auth = str(self.headers.get("Authorization") or "")
        if auth != f"Bearer {expected}":
            raise ApiError(401, "unauthorized", "missing or invalid admin token")

    def _read_body(self) -> Dict[str, Any]:
        length = parse_int(self.headers.get("Content-Length"), 0)
        if length <= 0:
            return {}
        if length > MAX_BODY_BYTES:
            raise ApiError(413, "body_too_large", "request body too large")
        raw = self.rfile.read(length)
        try:
            payload = json.loads(raw.decode("utf-8"))
        except json.JSONDecodeError as exc:
            raise ApiError(400, "invalid_json", "request body must be valid JSON") from exc
        if not isinstance(payload, dict):
            raise ApiError(400, "invalid_json", "request body must be a JSON object")
        return payload

    def _dispatch(self, method: str) -> None:
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path.rstrip("/") or "/"
        try:
            if method == "GET" and path == "/api/v1/healthz":
                self._json_success(
                    200,
                    {
                        "status": "ok",
                        "issuer": self.server.state.issuer,
                        "version": APP_VERSION,
                    },
                )
                return

            if path == "/api/v1/admin/licenses" and method == "POST":
                self._require_admin()
                body = self._read_body()
                license_data = self.server.state.create_license(
                    product=str(body.get("product") or "slowdns").strip().lower(),
                    max_activations=parse_int(body.get("max_activations"), 1),
                    expires_in_days=parse_int(body.get("expires_in_days"), 0),
                    note=str(body.get("note") or "").strip(),
                )
                self._json_success(201, license_data, "License created")
                return

            admin_key_match = re.fullmatch(r"/api/v1/admin/licenses/(?P<key>[^/]+)", path)
            if admin_key_match and method == "GET":
                self._require_admin()
                self._json_success(200, self.server.state.get_license(admin_key_match.group("key").upper()))
                return

            admin_activation_match = re.fullmatch(r"/api/v1/admin/licenses/(?P<key>[^/]+)/activations", path)
            if admin_activation_match and method == "GET":
                self._require_admin()
                key = admin_activation_match.group("key").upper()
                self.server.state.get_license_row(key)
                self._json_success(200, {"activations": self.server.state.list_activations(key)})
                return

            admin_revoke_match = re.fullmatch(r"/api/v1/admin/licenses/(?P<key>[^/]+)/revoke", path)
            if admin_revoke_match and method == "POST":
                self._require_admin()
                self._json_success(200, self.server.state.revoke_license(admin_revoke_match.group("key").upper()), "License revoked")
                return

            if path == "/api/v1/install/activate" and method == "POST":
                body = self._read_body()
                self._json_success(200, self.server.state.activate_install(body), "Install token issued")
                return

            if path == "/api/v1/install/confirm" and method == "POST":
                body = self._read_body()
                self._json_success(200, self.server.state.confirm_install(body), "Install confirmed")
                return

            if path == "/api/v1/install/release" and method == "POST":
                body = self._read_body()
                self._json_success(200, self.server.state.release_install(body), "Activation released")
                return

            raise ApiError(404, "not_found", "route not found")
        except ApiError as exc:
            self._json_error(exc.status, exc.code, exc.message)
        except Exception as exc:
            traceback.print_exc()
            self._json_error(500, "internal_error", str(exc) or "internal server error")


class LicenseServer(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address: Tuple[str, int], state: LicenseState, admin_token: str) -> None:
        super().__init__(address, LicenseHandler)
        self.state = state
        self.admin_token = admin_token


def serve() -> None:
    bind = os.getenv("SLOWDNS_LICENSE_BIND", "127.0.0.1")
    port = parse_int(os.getenv("SLOWDNS_LICENSE_PORT"), 8787)
    db_path = pathlib.Path(os.getenv("SLOWDNS_LICENSE_DB", "/opt/slowdns-license/license.db"))
    signing_secret = os.getenv("SLOWDNS_LICENSE_SIGNING_SECRET", "")
    admin_token = os.getenv("SLOWDNS_LICENSE_ADMIN_TOKEN", "")
    issuer = os.getenv("SLOWDNS_LICENSE_ISSUER", "https://license.internetshub.com/slowdns")

    if not signing_secret:
        raise SystemExit("SLOWDNS_LICENSE_SIGNING_SECRET is required")

    state = LicenseState(db_path, signing_secret=signing_secret, issuer=issuer)
    server = LicenseServer((bind, port), state, admin_token=admin_token)
    print(f"slowdns license api listening on {bind}:{port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    serve()
