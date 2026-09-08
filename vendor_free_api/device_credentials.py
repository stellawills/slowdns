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
