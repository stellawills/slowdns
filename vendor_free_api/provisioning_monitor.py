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
