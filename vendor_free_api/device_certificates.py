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
