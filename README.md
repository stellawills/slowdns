# SlowDNS

Standalone SlowDNS (SSH over DNS) service that stays API-compatible with the existing IPTunnel SSH account flow, while using a machine-bound install-code activation step and keeping the runtime account API token-free.

Install target on Linux:

```text
/opt/slowdns/
|-- api/
|-- bin/
|-- config/
|-- logs/
`-- scripts/
```

What it provides:

- `dnstt`-based SlowDNS server that forwards tunnel traffic to `127.0.0.1:22`
- standalone SSH account API with legacy and v2-compatible routes
- terminal menu via `slowdns-menu`
- optional `menu` command on standalone boxes where `menu` is not already installed
- system SSH user creation, password rotation, lock/unlock, delete, and expiry sync
- isolated systemd services and logs
- private machine-bound install-code activation during install

Main compatibility routes:

- `POST /vps/sshvpn`
- `POST /vps/trialsshvpn`
- `POST /vps/recoverysshvpn`
- `GET /vps/listuserssshvpn`
- `GET /vps/listrecoverysshvpn`
- `GET /vps/checkconfigsshvpn/{username}`
- `POST /vps/modifysshvpn`
- `POST /vps/changelimipsshvpn`
- `POST /vps/changelimipallsshvpn`
- `PATCH /vps/renewsshvpn/{username}/{expired}`
- `PATCH /vps/locksshvpn/{username}`
- `PATCH /vps/unlocksshvpn/{username}/{password}`
- `DELETE /vps/deletesshvpn/{username}`

V2-compatible routes:

- `GET /api/v2/healthz`
- `GET /api/v2/vps/runtime`
- `GET /api/v2/vps/services`
- `GET|POST|PATCH /api/v2/vps/accounts/ssh`
- `GET|PATCH|DELETE /api/v2/vps/accounts/ssh/{username}`
- `POST /api/v2/vps/accounts/ssh/trials`
- `GET|POST /api/v2/vps/accounts/ssh/recovery`

Notes:

- Installation requires a short-lived public `IPT-SD-...` install code from `https://license.internetshub.com/slowdns`.
- API access is also token-free by design.
- Install-code activation is locked to `https://license.internetshub.com`.
- Installer validates the install code first, then prompts for the public hostname, delegated SlowDNS tunnel domain, and public IPv4.
- Installer automatically uses the public hostname as the NS target host unless `SLOWDNS_NS_HOST` is explicitly set.
- On SSH sessions with `screen` available, the installer re-launches itself in `screen -S slowdns-install` so it can survive a dropped connection.
- Installer now fails fast if the API or dnstt service does not come up cleanly.
- Installer bootstraps an isolated modern Go toolchain under `/opt/slowdns/toolchain/` when the VPS has an outdated system Go.
- When the daemon must bind an internal high port like `5300`, the installer can still expose standard UDP `53` externally via an automatic redirect service.
- Default API bind is `127.0.0.1`; change it in config if you intentionally want remote access.
- Default dnstt source is the pinned official upstream snapshot, not a third-party mirror.

Installation on Linux:

```bash
bash <(curl -4fsSL https://raw.githubusercontent.com/stellawills/slowdns/main/install.sh)
```

Open `https://license.internetshub.com/slowdns`, generate a one-time `IPT-SD-...` install code, then paste that code into the installer when prompted.

Clone-based install also works:

```bash
cd /root
git clone https://github.com/stellawills/slowdns.git slowdns-src
bash slowdns-src/install.sh
```

Operator entrypoint:

- `install.sh` at the repo root is the only public installer entrypoint.
- The root installer works both as a cloned file and as a raw `curl | bash` bootstrap.
- `scripts/` contains internal implementation details that back the root installer.

Useful environment overrides:

```bash
SLOWDNS_HOSTNAME=dns.example.com \
SLOWDNS_TUNNEL_DOMAIN=slowdns.example.com \
SLOWDNS_PUBLIC_IP=203.0.113.10 \
SLOWDNS_LISTEN_PORT=5300 \
SLOWDNS_PUBLIC_PORT=53 \
SLOWDNS_API_BIND=127.0.0.1 \
SLOWDNS_API_PORT=8091 \
SLOWDNS_MTU=512 \
bash install.sh
```

Non-interactive install example:

```bash
SLOWDNS_INSTALL_CODE=IPT-SD-XXXXXX-XXXXXX-XXXXXX \
bash install.sh
```

Advanced override:

- `SLOWDNS_NS_HOST` is still supported if you intentionally want the NS target host to differ from the public hostname.

Service control after install:

```bash
/opt/slowdns/scripts/control.sh start
/opt/slowdns/scripts/control.sh restart
/opt/slowdns/scripts/control.sh status
slowdns-menu
menu
```

Official dnstt reference:

- [dnstt](https://www.bamsoftware.com/software/dnstt/)

Preferred DNS layout for this standalone service:

```dns
A   dns.example.com        203.0.113.10
NS  slowdns.example.com   dns.example.com
```
