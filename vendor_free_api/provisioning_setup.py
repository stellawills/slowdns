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
