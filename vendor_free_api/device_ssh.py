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
