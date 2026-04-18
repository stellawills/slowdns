# SlowDNS Only

Standalone SlowDNS (SSH over DNS) service that stays API-compatible with the existing IPTunnel SSH account flow, but does not use token-based installation or token-gated API access.

Install target on Linux:

```text
/opt/slowdns-only/
├── api/
├── bin/
├── config/
├── logs/
└── scripts/
```

What it provides:

- `dnstt`-based SlowDNS server that forwards tunnel traffic to `127.0.0.1:22`
- internal `5300` listener with optional public `53` redirect, matching the more reliable legacy SlowDNS layout
- standalone SSH account API with legacy and v2-compatible routes
- system SSH user creation, password rotation, lock/unlock, delete, and expiry sync
- isolated systemd services and logs
- plain-text `slowdns` menu for user management without raw JSON responses

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

- Installation is token-free.
- API access is also token-free by design.
- Default API bind is `127.0.0.1`; change it in config if you intentionally want remote access.
- Default dnstt source is the pinned official upstream snapshot, not a third-party mirror.
- Installer asks for the two DNS values that matter operationally:
  - `SlowDNS public hostname (A record host)` like `dns.example.com`
  - `SlowDNS delegated tunnel domain` like `slowdns.example.com`

Installation on Linux:

```bash
cd /root
git clone <your-repo> slowdns-src
bash slowdns-src/install.sh
```

Useful environment overrides:

```bash
SLOWDNS_HOSTNAME=example.com \
SLOWDNS_PUBLIC_HOSTNAME=dns.example.com \
SLOWDNS_TUNNEL_DOMAIN=slowdns.example.com \
SLOWDNS_PUBLIC_IP=203.0.113.10 \
SLOWDNS_LISTEN_PORT=5300 \
SLOWDNS_PUBLIC_PORT=53 \
SLOWDNS_API_BIND=127.0.0.1 \
SLOWDNS_API_PORT=8091 \
SLOWDNS_MTU=512 \
bash install.sh
```

Service control after install:

```bash
/usr/local/bin/slowdns
/usr/local/bin/slowdns-ctl status
/opt/slowdns-only/scripts/control.sh start
/opt/slowdns-only/scripts/control.sh restart
/opt/slowdns-only/scripts/control.sh status
```

Official dnstt reference:

- [dnstt](https://www.bamsoftware.com/software/dnstt/)
