# IPTunnel Security And Architecture Audit

## Executive Summary

The codebase is in a workable state, but there are two release-blocking issues in the license flow and several high-value hardening gaps across the VPS installer, runtime API, and license panel.

The most severe problems are:

1. Revoked servers can self-reactivate by registering again with the same IP and token.
2. The PHP license panel trusts spoofable forwarding headers for IP-based authorization and returns reusable client tokens based on that IP check.

Beyond those, the next most important risks are plaintext registration tokens at rest, unpinned installer supply-chain downloads, and the default open Squid proxy configuration.

---

## Critical Findings

### C1. Revoked servers can self-reactivate by re-registering

Impact: a server that was intentionally revoked can recover its authorization without admin approval as long as it still has a valid token and the same IP.

- Python license server:
  - `register()` reactivates an existing `(ip, token)` row by forcing `revoked = 0` at [vendor_free_api/license_server/license_server.py](vendor_free_api/license_server/license_server.py):110 and [vendor_free_api/license_server/license_server.py](vendor_free_api/license_server/license_server.py):117
  - Revocation itself is written at [vendor_free_api/license_server/license_server.py](vendor_free_api/license_server/license_server.py):153
- PHP license server:
  - `handle_register()` reactivates an existing `(ip, token)` row at [vendor_free_api/license_server_php/index.php](vendor_free_api/license_server_php/index.php):255 and [vendor_free_api/license_server_php/index.php](vendor_free_api/license_server_php/index.php):262
  - Revocation is written at [vendor_free_api/license_server_php/index.php](vendor_free_api/license_server_php/index.php):296 and [vendor_free_api/license_server_php/index.php](vendor_free_api/license_server_php/index.php):302

Recommended fix:

- Treat revocation as sticky until an explicit admin restore action.
- Change re-registration to reject revoked rows instead of resetting them.
- Add automated tests for:
  - revoke -> checkin denied
  - revoke -> register denied
  - restore -> register/checkin allowed

### C2. IP-based zero-touch authorization trusts spoofable proxy headers and returns a reusable client token

Impact: if the panel is served directly by Apache/PHP or behind a proxy that does not sanitize inbound forwarding headers, an attacker can spoof `X-Forwarded-For` / `X-Real-IP`, pass the IP whitelist check, and receive a valid client token.

- Client IP is derived by blindly trusting forwarded headers at [vendor_free_api/license_server_php/db.php](vendor_free_api/license_server_php/db.php):238
- The authorization endpoint uses that IP and returns the client's token at [vendor_free_api/license_server_php/index.php](vendor_free_api/license_server_php/index.php):184 and [vendor_free_api/license_server_php/index.php](vendor_free_api/license_server_php/index.php):207

Recommended fix:

- Introduce a trusted-proxy allowlist and only honor forwarded headers when the immediate peer is a trusted reverse proxy.
- Prefer a canonical “real client IP” helper instead of reading raw headers everywhere.
- Replace token return with either:
  - a short-lived install ticket, or
  - a one-time registration token scoped to that IP and a short expiry.

---

## High Findings

### H3. Registration tokens are stored in plaintext and reused as long-lived credentials

Impact: a database leak or log exposure immediately yields working client/master registration credentials.

- Client token creation and lookup in PHP:
  - created at [vendor_free_api/license_server_php/db.php](vendor_free_api/license_server_php/db.php):77 and [vendor_free_api/license_server_php/db.php](vendor_free_api/license_server_php/db.php):79
  - looked up directly at [vendor_free_api/license_server_php/db.php](vendor_free_api/license_server_php/db.php):99
  - rotated at [vendor_free_api/license_server_php/db.php](vendor_free_api/license_server_php/db.php):178
- Tokens are stored in schema columns as plaintext:
  - PHP schema at [vendor_free_api/license_server_php/schema.sql](vendor_free_api/license_server_php/schema.sql):20 and [vendor_free_api/license_server_php/schema.sql](vendor_free_api/license_server_php/schema.sql):36
  - Python schema at [vendor_free_api/license_server/license_schema.sql](vendor_free_api/license_server/license_schema.sql):8
- Python license server also persists raw tokens in server rows:
  - insert at [vendor_free_api/license_server/license_server.py](vendor_free_api/license_server/license_server.py):125
  - list/status output includes the token at [vendor_free_api/license_server/license_server.py](vendor_free_api/license_server/license_server.py):162
- PHP registration also stores raw token in the server row at [vendor_free_api/license_server_php/index.php](vendor_free_api/license_server_php/index.php):268

Recommended fix:

- Store only a hash of client/master registration tokens.
- Show the full token once at creation/rotation time, then retain only:
  - token hash
  - token prefix / last 4
  - created_at
  - last_used_at
- Stop storing raw tokens in `servers.token`; persist a stable issuer ID instead.

### H4. Installer supply chain is not pinned or verified

Impact: a compromised upstream host, repository, or redirect target can take over freshly installed VPSes.

- Unpinned remote downloads in the transport stack:
  - Dropbear source at [vendor_free_api/transport_stack.sh](vendor_free_api/transport_stack.sh):320
  - Go toolchain at [vendor_free_api/transport_stack.sh](vendor_free_api/transport_stack.sh):401
  - dnstt source via `git clone` at [vendor_free_api/transport_stack.sh](vendor_free_api/transport_stack.sh):417 and [vendor_free_api/transport_stack.sh](vendor_free_api/transport_stack.sh):419
  - Xray install script at [vendor_free_api/transport_stack.sh](vendor_free_api/transport_stack.sh):521
- The hosted installer hardcodes the license origin at [vendor_free_api/build_installer.py](vendor_free_api/build_installer.py):25

Recommended fix:

- Pin versions and SHA256 checksums for every downloaded artifact.
- Prefer downloading release tarballs over live install scripts.
- Keep a manifest of approved artifact URLs and hashes.
- Add an offline/mirrored install mode for production rollouts.

### H5. Squid is configured as an open internet proxy

Impact: if `3128/tcp` is reachable from the internet, third parties can abuse the VPS for proxy traffic.

- Squid allows all traffic at [vendor_free_api/transport_stack.sh](vendor_free_api/transport_stack.sh):826

Recommended fix:

- Restrict Squid by source networks, auth, or nftables/iptables.
- Default to disabled unless explicitly enabled.
- If public access is intended, add bandwidth/rate abuse protections and clear documentation.

---

## Medium Findings

### M6. The VPS API accepts both the configured API key and the legacy DB key by default

Impact: old credentials remain valid longer than operators may realize, increasing the blast radius of a leaked historical key.

- Legacy key fallback is enabled by default at [vendor_free_api/iptunnel_api.py](vendor_free_api/iptunnel_api.py):38
- Accepted keys are merged from config and DB at [vendor_free_api/iptunnel_api.py](vendor_free_api/iptunnel_api.py):446 and [vendor_free_api/iptunnel_api.py](vendor_free_api/iptunnel_api.py):451

Recommended fix:

- Default `allow_legacy_db_key` to `false`.
- Add an explicit migration command to rotate off the DB key.
- Surface active credentials in the admin/runtime view so operators can see what still works.

### M7. Session cookie security is not proxy-aware

Impact: when the PHP panel sits behind a TLS-terminating reverse proxy, secure cookies may not be marked `Secure`, weakening session protection in common production deployments.

- Admin panel sets `session.cookie_secure` only when `$_SERVER['HTTPS'] === 'on'` at [vendor_free_api/license_server_php/admin.php](vendor_free_api/license_server_php/admin.php):21 and [vendor_free_api/license_server_php/admin.php](vendor_free_api/license_server_php/admin.php):24
- Client panel does the same at [vendor_free_api/license_server_php/client.php](vendor_free_api/license_server_php/client.php):15 and [vendor_free_api/license_server_php/client.php](vendor_free_api/license_server_php/client.php):18

Recommended fix:

- Add trusted-proxy aware scheme detection.
- Or make secure cookie behavior configurable through a deployment setting.

### M8. The license servers do not enforce request body size limits

Impact: a client can force unnecessary memory usage and noisy error paths with oversized bodies.

- Python license server reads `Content-Length` directly at [vendor_free_api/license_server/license_server.py](vendor_free_api/license_server/license_server.py):304
- PHP license server reads the raw body without a limit at [vendor_free_api/license_server_php/index.php](vendor_free_api/license_server_php/index.php):353

Recommended fix:

- Reject bodies over a small maximum size, e.g. 16 KB or 64 KB.
- Return a `413` instead of reading arbitrarily large request bodies.

### M9. Hysteria and OpenVPN UDP share an incompatible network model on one public IP

Impact: feature combinations are constrained by design and can silently break or require special-case toggles.

- Hysteria hop range is `10000:65000` at [vendor_free_api/transport_stack.sh](vendor_free_api/transport_stack.sh):31
- OpenVPN UDP is bound to `25000` at [vendor_free_api/transport_stack.sh](vendor_free_api/transport_stack.sh):1116
- The code now blocks enabling both together at [vendor_free_api/transport_stack.sh](vendor_free_api/transport_stack.sh):56 and [vendor_free_api/transport_stack.sh](vendor_free_api/transport_stack.sh):1597

Recommended fix:

- Present this as a first-class install profile instead of a late conflict.
- Offer either:
  - Hysteria profile
  - OpenVPN UDP profile
  - dual-IP deployment profile

### M10. The API process can self-terminate on license check-in failures

Impact: a temporary upstream outage, DNS issue, or operator mistake can turn into a full service outage.

- Missing `server_id` leads to forced exit after the grace window at [vendor_free_api/iptunnel_api.py](vendor_free_api/iptunnel_api.py):1462 and [vendor_free_api/iptunnel_api.py](vendor_free_api/iptunnel_api.py):1465
- Seven failed check-ins also terminate the API at [vendor_free_api/iptunnel_api.py](vendor_free_api/iptunnel_api.py):1489 and [vendor_free_api/iptunnel_api.py](vendor_free_api/iptunnel_api.py):1490

Recommended fix:

- Separate “licensing degraded” from “hard stop” unless explicitly configured.
- Add exponential backoff, alerting, and a maintenance override.

---

## Low Findings And Cleanup Opportunities

### L11. `server_stats()` interpolates `client_id` into SQL strings

This is low risk because the function currently receives integer values from server-side code, but it is still better practice to parameterize the queries.

- See [vendor_free_api/license_server_php/db.php](vendor_free_api/license_server_php/db.php):378

### L12. The installer globally enables SSH password authentication

This may be intentional for the product, but it broadens the host attack surface more than necessary.

- See [vendor_free_api/transport_stack.sh](vendor_free_api/transport_stack.sh):299

Safer alternatives:

- apply a `Match User` block for managed VPN accounts only
- or isolate app-managed SSH access from admin SSH access

---

## Improvement Roadmap

### License Panel / License API

- Unify on one license backend implementation to reduce drift between the Python and PHP servers.
- Replace reusable client tokens with scoped install tickets and hashed-at-rest long-lived secrets.
- Add trusted proxy configuration and a single canonical `real_client_ip()` helper.
- Add WebAuthn or TOTP MFA for admin accounts.
- Add optional MFA / email verification for client portal logins.
- Add per-client token scopes:
  - install
  - status read
  - admin
- Add token last-used tracking and IP metadata.
- Add webhook / email alerts for:
  - repeated failed logins
  - server revoke events
  - stale check-ins
  - unusual registration spikes

### VPS Installer / Runtime

- Add artifact checksum verification and pinned versions everywhere.
- Add a post-install self-test:
  - API health
  - nginx routing
  - SSH-SSL
  - SSH-WS
  - Xray WS/gRPC
  - SlowDNS public key presence
- Add rollback or “failed install summary” when a transport fails to start.
- Add real certificate automation (ACME / DNS challenge) instead of defaulting to self-signed certs.
- Add per-transport enable/disable profiles that are conflict-aware from the beginning.
- Add backup/export/import for:
  - database
  - config.json
  - transport credentials
  - nginx and systemd state
- Add systemd hardening to more services:
  - `ProtectSystem`
  - `ProtectHome`
  - `PrivateDevices`
  - `RestrictAddressFamilies`

### Operational Features Worth Adding

- Central dashboard for:
  - service health
  - cert expiry
  - check-in freshness
  - enabled transport modules
- Audit export and download from the panel.
- Per-client device inventory and revoke-by-device.
- Scoped admin roles:
  - superadmin
  - support
  - read-only auditor
- Automatic config snapshots before menu-driven changes.
- Safer update channel for IPTunnel components, with changelog and rollback.

---

## Recommended Fix Order

1. Fix the revoke-bypass logic in both license servers.
2. Fix IP authorization so it does not trust raw forwarding headers and does not return reusable client tokens.
3. Move registration tokens to hashed-at-rest storage.
4. Pin and verify all remote installer downloads.
5. Lock down or disable Squid by default.
6. Remove legacy DB key auth by default.
7. Make panel sessions proxy-aware and add stronger deployment guidance.
8. Add automated regression tests for licensing, registration, and transport toggles.
