# SlowDNS License Activation

This folder contains a reference activation service for `license.internetshub.com/slowdns`.

Goal:

- gate installation with a real license activation flow
- issue short-lived install tokens instead of shipping static secrets
- bind each activation to the target machine
- keep the SlowDNS installer simple while moving trust decisions server-side

## Recommended Topology

- public base URL: `https://license.internetshub.com/slowdns`
- installer bootstrap hosted on your domain
- activation API protected by TLS
- SlowDNS installer calling the activation API before any protected install work continues

The bootstrap flow should look like:

```bash
bash <(curl -4fsSL https://license.internetshub.com/slowdns/install.sh)
```

That hosted bootstrap can then call the public GitHub installer while forcing activation:

```bash
SLOWDNS_LICENSE_URL=https://license.internetshub.com/slowdns
SLOWDNS_LICENSE_ENFORCE=true
```

The included [install.sh](C:/Users/ROG/Documents/Dev/Scripts/SSH/.codex-main-worktree/license_server/install.sh) is an example of that wrapper.

## API Endpoints

Health:

- `GET /api/v1/healthz`

Admin:

- `POST /api/v1/admin/licenses`
- `GET /api/v1/admin/licenses/{license_key}`
- `GET /api/v1/admin/licenses/{license_key}/activations`
- `POST /api/v1/admin/licenses/{license_key}/revoke`

Install flow:

- `POST /api/v1/install/activate`
- `POST /api/v1/install/confirm`
- `POST /api/v1/install/release`

Admin routes require:

```http
Authorization: Bearer <SLOWDNS_LICENSE_ADMIN_TOKEN>
```

## Request / Response Shape

All routes return the same envelope:

```json
{
  "data": {},
  "meta": {
    "request_id": "hex",
    "timestamp": "2026-03-30T00:00:00+00:00",
    "version": "2026.03.30",
    "message": "optional"
  },
  "error": null
}
```

Failures return:

```json
{
  "data": null,
  "meta": {
    "request_id": "hex",
    "timestamp": "2026-03-30T00:00:00+00:00",
    "version": "2026.03.30"
  },
  "error": {
    "code": "activation_limit",
    "message": "maximum activations reached for this key"
  }
}
```

### `POST /api/v1/admin/licenses`

Request:

```json
{
  "product": "slowdns",
  "max_activations": 1,
  "expires_in_days": 30,
  "note": "customer or order reference"
}
```

Response `201`:

```json
{
  "data": {
    "license_key": "IPT-SD-XXXXXX-XXXXXX-XXXXXX",
    "license_key_hint": "IPT-SD...XXXX",
    "product": "slowdns",
    "status": "active",
    "max_activations": 1,
    "expires_at": "2026-04-29T00:00:00+00:00",
    "note": "customer or order reference",
    "created_at": "2026-03-30T00:00:00+00:00",
    "revoked_at": null
  },
  "meta": {
    "message": "License created"
  },
  "error": null
}
```

### `POST /api/v1/install/activate`

Request:

```json
{
  "license_key": "IPT-SD-XXXXXX-XXXXXX-XXXXXX",
  "product": "slowdns",
  "hostname": "dns.iptunnel.eu.org",
  "public_ip": "45.79.202.89",
  "machine_id": "87c4bc1848a84471997203ee530d2fda",
  "ssh_fingerprint": "SHA256:WvM2...",
  "requested_ref": "main",
  "installer_version": "2026.03.30"
}
```

Response `200`:

```json
{
  "data": {
    "activation_id": "act_d09c18b179f7d820",
    "install_token": "<signed token>",
    "install_token_expires_at": "2026-03-30T00:05:00+00:00",
    "license": {
      "license_key_hint": "IPT-SD...XXXX",
      "product": "slowdns",
      "max_activations": 1,
      "expires_at": "2026-04-29T00:00:00+00:00",
      "status": "active"
    },
    "machine_binding": {
      "hostname": "dns.iptunnel.eu.org",
      "public_ip": "45.79.202.89",
      "machine_id": "87c4bc1848a84471997203ee530d2fda",
      "ssh_fingerprint": "SHA256:WvM2..."
    }
  },
  "meta": {
    "message": "Install token issued"
  },
  "error": null
}
```

### `POST /api/v1/install/confirm`

Request:

```json
{
  "activation_id": "act_d09c18b179f7d820",
  "install_token": "<signed token>"
}
```

Response:

```json
{
  "data": {
    "activation_id": "act_d09c18b179f7d820",
    "status": "confirmed"
  },
  "meta": {
    "message": "Install confirmed"
  },
  "error": null
}
```

### `POST /api/v1/install/release`

Use this when an install fails after activation and you want to free the machine slot.

Request:

```json
{
  "activation_id": "act_d09c18b179f7d820",
  "license_key": "IPT-SD-XXXXXX-XXXXXX-XXXXXX"
}
```

Response:

```json
{
  "data": {
    "activation_id": "act_d09c18b179f7d820",
    "status": "released"
  },
  "meta": {
    "message": "Activation released"
  },
  "error": null
}
```

## Install Handshake

1. User runs the hosted bootstrap on `license.internetshub.com`.
2. Bootstrap sets `SLOWDNS_LICENSE_URL` and `SLOWDNS_LICENSE_ENFORCE=true`.
3. SlowDNS installer asks for `IPT-SD-...` if `SLOWDNS_LICENSE_KEY` was not pre-supplied.
4. Installer detects:
   - `machine_id` from `/etc/machine-id`
   - `ssh_fingerprint` from the local SSH host public key
   - public hostname and public IP from the install prompts
5. Installer calls `POST /api/v1/install/activate`.
6. License API validates:
   - product matches
   - key is active
   - key is not expired
   - activation count is within limit
7. License API returns a 5-minute single-use signed token.
8. Installer completes package install, config render, key generation, and service start.
9. Installer calls `POST /api/v1/install/confirm`.
10. If install fails before confirmation, installer calls `POST /api/v1/install/release`.

## Machine Binding

Binding uses:

- `machine_id`
- `ssh_fingerprint`

Those two fields are the identity anchor. `public_ip` and `hostname` are stored for audit visibility, not as the only identity check.

## Database Schema

The service stores two tables in SQLite.

### `licenses`

- `license_key TEXT PRIMARY KEY`
- `product TEXT NOT NULL`
- `status TEXT NOT NULL DEFAULT 'active'`
- `max_activations INTEGER NOT NULL DEFAULT 1`
- `expires_at TEXT`
- `note TEXT NOT NULL DEFAULT ''`
- `created_at TEXT NOT NULL`
- `revoked_at TEXT`

### `activations`

- `activation_id TEXT PRIMARY KEY`
- `license_key TEXT NOT NULL`
- `product TEXT NOT NULL`
- `machine_id TEXT NOT NULL`
- `ssh_fingerprint TEXT NOT NULL`
- `public_ip TEXT NOT NULL`
- `hostname TEXT NOT NULL`
- `install_token TEXT`
- `install_token_expires_at TEXT`
- `install_token_used_at TEXT`
- `created_at TEXT NOT NULL`
- `last_seen_at TEXT NOT NULL`
- `released_at TEXT`

Indexes:

- `idx_activations_license_key`
- unique active binding index on `(license_key, machine_id, ssh_fingerprint)` where `released_at IS NULL`

## Signed Token Format

Install tokens are compact HMAC-SHA256 signed strings:

```text
base64url(header).base64url(payload).base64url(signature)
```

Header example:

```json
{
  "alg": "HS256",
  "typ": "LIT",
  "kid": "v1"
}
```

Payload fields:

- `iss`: issuer, for example `https://license.internetshub.com/slowdns`
- `typ`: `slowdns_install`
- `sub`: activation id
- `prd`: product id
- `key`: license key
- `mid`: SHA-256 of machine id
- `ssh`: SHA-256 of SSH host fingerprint
- `ip`: public IP seen during activation
- `hst`: public hostname seen during activation
- `ref`: installer ref, usually `main`
- `ver`: installer version
- `iat`: issued-at epoch
- `exp`: expiry epoch
- `jti`: random token id

Properties:

- single-use
- short-lived
- machine-bound
- not intended as a long-lived license bearer token

## Running The License API

Required environment variables:

- `SLOWDNS_LICENSE_SIGNING_SECRET`

Recommended environment variables:

- `SLOWDNS_LICENSE_BIND=127.0.0.1`
- `SLOWDNS_LICENSE_PORT=8787`
- `SLOWDNS_LICENSE_DB=/opt/slowdns-license/license.db`
- `SLOWDNS_LICENSE_ADMIN_TOKEN=<strong random secret>`
- `SLOWDNS_LICENSE_ISSUER=https://license.internetshub.com/slowdns`

Example:

```bash
export SLOWDNS_LICENSE_SIGNING_SECRET="$(openssl rand -hex 32)"
export SLOWDNS_LICENSE_ADMIN_TOKEN="$(openssl rand -hex 24)"
export SLOWDNS_LICENSE_ISSUER="https://license.internetshub.com/slowdns"
python3 license_api.py
```

Then place a reverse proxy in front of it and strip the `/slowdns` prefix so:

- `https://license.internetshub.com/slowdns/api/v1/...`

maps to the running service.
