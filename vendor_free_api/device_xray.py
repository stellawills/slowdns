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
