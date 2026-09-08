# IPTunnel

This is the IPTunnel full installer and API.

This is a clean replacement for the old `aus-cloud` backend. Fresh installs now use `/api/v2/...` as the primary API surface, keep the same SQLite tables in `iptunnel.db`, and can install and manage the main VPS stack in one shot.

It does **not** talk to the dead vendor cloud endpoint, and it does **not** depend on the old vendor auth flow.

## One-Shot Install

Run the generated installer on each VPS. If you do not pass `--domain` or `--public-ip`, it will ask for them during the install so each VPS can have its own values.

The installer lays down the full stack in one shot. Core services start enabled by default, while the conflicting optional modules stay installed but disabled until you turn them on from the terminal menu:

- enabled by default: SSH, SlowDNS, Squid, Xray
- installed but disabled by default: Hysteria, OpenVPN

```bash
bash iptunnel-install.sh
```

Optional overrides still work for automation:

```bash
bash iptunnel-install.sh --domain api-vps1.example.com --public-ip 203.0.113.10
```

## What It Installs

- IPTunnel API + SQLite database
- Terminal management menu available as `menu` or `iptunnel-menu`
- Nginx reverse proxy for `/api/v2`, legacy `/vps`, `/healthz`, Xray websocket paths, and OpenVPN profile hosting
- Xray with VMess, VLESS, and Trojan services
- SlowDNS server for SSH tunneling
- UDP 53 demultiplexer that routes DNS-looking packets to SlowDNS and non-DNS packets to OpenVPN UDP when OpenVPN is enabled
- Hysteria on UDP `5666` using the exact standalone installer flow, including hop range `10000:65000` when enabled from the menu
- OpenSSH, Dropbear 2019.78, SSH-over-WebSocket, and SSH-over-SSL
- Squid
- OpenVPN TCP `1194` and UDP `53` when enabled from the menu, with the UDP server bound internally on `127.0.0.1:25000`
- vnStat

## License Control Plane

Fresh installs now prefer the versioned license API under `/api/v2` for:

- `POST /api/v2/install-tickets/issue`
- `POST /api/v2/servers/register`
- `POST /api/v2/servers/{server_id}/check-in`

The old `/authorize`, `/register`, and `/checkin` routes are still kept as compatibility aliases during migration.

## API Coverage

Primary VPS routes now live under `/api/v2/vps`:

- `GET /api/v2/vps/runtime`
- `GET /api/v2/vps/services`
- `GET /api/v2/vps/bandwidth`
- `GET /api/v2/vps/updates`
- `POST /api/v2/vps/backup`
- `POST /api/v2/vps/restore`
- `POST /api/v2/vps/certificates/letsencrypt`
- `POST /api/v2/vps/transports/{transport}/enable`
- `POST /api/v2/vps/transports/{transport}/disable`
- `GET /api/v2/vps/accounts/{protocol}`
- `POST /api/v2/vps/accounts/{protocol}`
- `PATCH /api/v2/vps/accounts/{protocol}` for bulk limit/quota operations
- `GET /api/v2/vps/accounts/{protocol}/recovery`
- `POST /api/v2/vps/accounts/{protocol}/recovery`
- `POST /api/v2/vps/accounts/{protocol}/trials`
- `GET /api/v2/vps/accounts/{protocol}/{username}`
- `PATCH /api/v2/vps/accounts/{protocol}/{username}`
- `DELETE /api/v2/vps/accounts/{protocol}/{username}`

Legacy `/vps/...` routes are still shipped as compatibility aliases during migration.

## Terminal Menu

Each VPS install also drops a terminal manager at:

```bash
menu
```

It uses the local API and `/etc/iptunnel/config.json` to:

- list SSH, VMess, VLESS, and Trojan users
- create normal or trial accounts
- show account config output
- renew, delete, lock, and unlock accounts
- show main IPTunnel service status
- run backup, restore, Let's Encrypt, and update checks through the same v2 API
- enable or disable Hysteria and OpenVPN after install
- update Hysteria `obfs` and `password` after install

Current SSH transport coverage includes direct SSH on `22`, Dropbear on `109` and `143`, SSH-over-WebSocket on `80`, `443`, and `2082` using path `/sshws`, SSH-over-SSL on `443`, `2083`, and `8443`, SlowDNS on `53`, Squid on `3128`, Hysteria on `5666/udp` when enabled, and the OpenVPN helper outputs when enabled. OHP is still not implemented yet.
The SSH WebSocket bridge is implemented as an HTTP Upgrade tunnel on `/sshws`, so the usual SSH VPN payload format works without requiring strict RFC6455 websocket framing.
On `443`, HAProxy multiplexes HTTP/TLS traffic to nginx while routing non-HTTP raw TLS traffic to the Dropbear-backed SSH-SSL tunnel.

## Auth

The old backend expected the API key in the `Authorization` header. This replacement keeps that behavior for both legacy and v2 routes.

Examples:

```bash
curl -H "Authorization: your-own-api-key" http://127.0.0.1:8080/api/v2/vps/accounts/ssh
curl -H "Authorization: Bearer your-own-api-key" http://127.0.0.1:8080/api/v2/vps/accounts/vmess
```

If `allow_legacy_db_key` is left enabled, it will also accept the current `servers.key` value from an old migrated DB. That makes migration easier while you switch your callers over.

## Deploy On The VPS

1. Copy `iptunnel_api.py` to `/opt/iptunnel/iptunnel_api.py`.
2. Copy `config.example.json` to `/etc/iptunnel/config.json`.
3. Edit `/etc/iptunnel/config.json` with the domain and IP for that specific VPS, plus your own API key and paths.
4. Copy `iptunnel-api.service` to `/etc/systemd/system/iptunnel-api.service`.
5. Reload systemd and start it:

```bash
systemctl daemon-reload
systemctl enable --now iptunnel-api
systemctl status iptunnel-api --no-pager
```

## Proxy Through Nginx

Drop the contents of `nginx-proxy.conf` inside the correct `server { ... }` block, then reload nginx.

```bash
nginx -t && systemctl reload nginx
```

## Paths

- Database: `/usr/sbin/iptunnel/iptunnel.db`
- API config: `/etc/iptunnel/config.json`
- Xray configs:
  - `/etc/iptunnel/xray/vmess.json`
  - `/etc/iptunnel/xray/vless.json`
  - `/etc/iptunnel/xray/trojan.json`
- Xray services:
  - `iptunnel-vmess`
  - `iptunnel-vless`
  - `iptunnel-trojan`
- SlowDNS:
  - service: `iptunnel-slowdns`
  - env: `/etc/iptunnel/slowdns/slowdns.env`
  - public key: `/etc/iptunnel/slowdns/server.pub`
  - info file: `/var/www/html/slowdns-info.txt`
- Hysteria:
  - service: `hysteria-server` with compatibility alias `iptunnel-hysteria`
  - config: `/etc/hysteria/config.json`
  - CA cert: `/var/www/html/hysteria.ca.crt`
  - info file: `/var/www/html/hysteria-info.txt`
- SSH-over-WebSocket:
  - service: `iptunnel-ssh-ws`
  - local bridge: `/opt/iptunnel/ssh_ws_bridge.py`
  - public paths: `/sshws` and compatibility alias `/ssh`
  - public ports: `80`, `443`, and `2082`
- SSH-over-SSL:
  - service: `iptunnel-ssh-ssl`
  - config: `/etc/stunnel/iptunnel-ssh.conf`
  - cert bundle: `/usr/sbin/iptunnel/cert/stunnel.pem`
## Notes

- The API edits the same account tables the old backend used.
- SSH actions use Linux account commands like `useradd`, `passwd`, `chage`, and `userdel`.
- Xray actions update the per-protocol client JSON and restart `iptunnel-vmess`, `iptunnel-vless`, or `iptunnel-trojan`.
- gRPC service names follow the old compatible values: `vmess`, `vless`, and `trojan`.
- SlowDNS is installed from a pinned official `dnstt` snapshot by default, with local legacy-binary reuse and direct override URLs as the only fallbacks.
- SlowDNS no longer forces a fixed MTU by default. If you need to pin it for a specific resolver path, set `IPTUNNEL_SLOWDNS_MTU`.
- For SlowDNS, the runtime model is `A <public hostname> -> VPS_IP` and `NS <tunnel domain> -> <public hostname>`. By default in IPTunnel that becomes `A <domain> -> VPS_IP` and `NS dns.<domain> -> <domain>`, while `dnstt` listens on `:5300` and public UDP `53` is either redirected directly there or shared through the UDP53 mux when OpenVPN UDP53 is enabled.
- Hysteria uses the exact standalone `hysteria.sh` installer flow that already worked on your other server, including UDP hopping across `10000:65000`.
- Hysteria and OpenVPN stay disabled by default until you explicitly enable them from the menu. They can now coexist because OpenVPN UDP is exposed only through the public `53/udp` demultiplexer while Hysteria keeps its standalone hop range on `10000:65000`.
- Squid is an HTTP proxy, not a website. A direct browser-style request to port `3128` can return `400`; use it from a tunneling client or with an HTTP `CONNECT` payload.
- For classic Squid/injector SSH tunneling, point the app at Squid on `3128` or `8080` and use a `CONNECT <host>:22` payload. Shared `443` is for HTTPS/WSS multiplexing, not the preferred Squid target.
- Shadowsocks is not included yet because it did not show up in the extracted backend routes.
