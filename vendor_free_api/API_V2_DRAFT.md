# IPTunnel API v2 Draft

## Goal

API v2 is a clean, versioned HTTP API for IPTunnel's control plane.

It replaces the current mix of:

- PHP license routes like `/authorize`, `/register`, `/checkin`, `/revoke`, `/status`
- legacy VPS routes like `/vps/sshvpn`, `/vps/listusersvmess`, `/vps/checkconfigvless/...`

This draft assumes a fresh rollout with no existing public consumers, so we can optimize for clarity and long-term maintenance instead of preserving the old route shape.

## Scope

API v2 should cover:

- admin authentication
- clients
- subscriptions
- authorized install IPs
- one-time install tickets
- server registration and check-in
- server inventory and revocation
- webhooks
- audit/login history
- VPS account management for SSH, VMess, VLESS, Trojan
- transport/runtime info for a VPS

Out of scope for the first v2 cut:

- payment processor integration
- public billing portal
- mobile app API
- protocol-level traffic metering beyond the current DB fields

## Base URL

```text
/api/v2
```

Examples:

- `/api/v2/auth/login`
- `/api/v2/clients`
- `/api/v2/servers`
- `/api/v2/vps/accounts/ssh`

## Auth Model

Use four auth types, each with clear scope.

### 1. Admin session

For the web panel only.

- cookie-based session
- CSRF-protected for browser form actions
- roles:
  - `superadmin`
  - `admin`
  - `viewer`

### 2. API bearer tokens

For programmatic access.

- `Authorization: Bearer <token>`
- token types:
  - `admin_api`
  - `client_api`

Recommended v2 change:

- store only token hashes at rest
- show token only at creation/regeneration
- keep a short display prefix in DB for identification

### 3. Install ticket

For zero-touch installer flow.

- short-lived
- one-time use
- bound to:
  - client
  - source IP
  - expiry

### 4. Server identity

For registered VPS heartbeat/control-plane identity.

- `server_id`
- optional signed server token later

## Response Format

All v2 endpoints should use one response envelope.

Success:

```json
{
  "data": {},
  "meta": {
    "request_id": "req_01...",
    "timestamp": "2026-03-19T12:00:00Z"
  },
  "error": null
}
```

Error:

```json
{
  "data": null,
  "meta": {
    "request_id": "req_01...",
    "timestamp": "2026-03-19T12:00:00Z"
  },
  "error": {
    "code": "validation_error",
    "message": "Field `ip` is required.",
    "details": {
      "field": "ip"
    }
  }
}
```

## Common Rules

### Pagination

Collection endpoints use:

- `page`
- `per_page`
- `sort`
- `direction`

Example:

```text
GET /api/v2/servers?page=1&per_page=20&sort=created_at&direction=desc
```

Collection response meta:

```json
{
  "pagination": {
    "page": 1,
    "per_page": 20,
    "total": 135,
    "pages": 7
  }
}
```

### Filtering

Use query filters instead of route variants.

Examples:

- `/api/v2/servers?status=revoked`
- `/api/v2/clients?status=active`
- `/api/v2/vps/accounts/vmess?locked=false`

### Status Codes

- `200` OK
- `201` Created
- `202` Accepted
- `204` No Content
- `400` Bad Request
- `401` Unauthorized
- `403` Forbidden
- `404` Not Found
- `409` Conflict
- `422` Validation Error
- `429` Rate Limited

## Resource Model

### Auth

#### `POST /api/v2/auth/login`

Admin login for panel/API session bootstrap.

Request:

```json
{
  "username": "admin",
  "password": "secret"
}
```

Response:

```json
{
  "data": {
    "admin": {
      "id": 1,
      "username": "admin",
      "role": "superadmin"
    }
  }
}
```

#### `POST /api/v2/auth/logout`

#### `GET /api/v2/auth/me`

Returns current authenticated admin/client identity.

### Clients

#### `GET /api/v2/clients`

Filters:

- `status=active|inactive`
- `search=...`

#### `POST /api/v2/clients`

Request:

```json
{
  "name": "John Doe",
  "email": "john@example.com",
  "username": "john",
  "password": "secret123",
  "max_servers": 5,
  "note": "Reseller"
}
```

#### `GET /api/v2/clients/{client_id}`

#### `PATCH /api/v2/clients/{client_id}`

Allowed fields:

- `name`
- `email`
- `max_servers`
- `note`
- `is_active`

#### `DELETE /api/v2/clients/{client_id}`

#### `POST /api/v2/clients/{client_id}/token/rotate`

Returns the newly created token once.

### Client Authorized IPs

#### `GET /api/v2/clients/{client_id}/authorized-ips`

#### `POST /api/v2/clients/{client_id}/authorized-ips`

```json
{
  "ip": "1.2.3.4",
  "label": "Lagos VPS"
}
```

#### `DELETE /api/v2/clients/{client_id}/authorized-ips/{authorized_ip_id}`

### Install Tickets

#### `POST /api/v2/install-tickets/issue`

Used when a pre-authorized IP asks for an installer credential.

Request:

```json
{
  "ip": "1.2.3.4"
}
```

Response:

```json
{
  "data": {
    "ticket": "itk_...",
    "expires_in": 600
  }
}
```

This endpoint should only return tickets, never reusable client tokens.

### Servers

#### `GET /api/v2/servers`

Filters:

- `status=active|revoked|stale|manual`
- `client_id`
- `search`

#### `POST /api/v2/servers/register`

Used by installer/VPS agent.

Request:

```json
{
  "credential": "itk_... or client token",
  "ip": "1.2.3.4",
  "hostname": "vps1.example.com"
}
```

Response:

```json
{
  "data": {
    "server": {
      "server_id": "srv_...",
      "client_id": 10,
      "ip": "1.2.3.4",
      "hostname": "vps1.example.com",
      "status": "active"
    }
  }
}
```

#### `POST /api/v2/servers/{server_id}/check-in`

Heartbeat endpoint.

#### `GET /api/v2/servers/{server_id}`

#### `PATCH /api/v2/servers/{server_id}`

Allowed fields:

- `note`
- `hostname`

#### `POST /api/v2/servers/{server_id}/revoke`

#### `POST /api/v2/servers/{server_id}/restore`

#### `DELETE /api/v2/servers/{server_id}`

### Subscriptions

#### `GET /api/v2/subscriptions`

Filters:

- `status=active|expired|cancelled|trial`
- `client_id`

#### `POST /api/v2/subscriptions`

```json
{
  "client_id": 10,
  "plan": "starter",
  "status": "active",
  "max_servers": 5,
  "amount": 20.0,
  "currency": "USD",
  "expires_at": "2026-04-19T23:59:59Z"
}
```

#### `GET /api/v2/subscriptions/{subscription_id}`

#### `PATCH /api/v2/subscriptions/{subscription_id}`

#### `POST /api/v2/subscriptions/{subscription_id}/cancel`

#### `POST /api/v2/subscriptions/{subscription_id}/expire`

### Webhooks

#### `GET /api/v2/webhooks`

#### `POST /api/v2/webhooks`

```json
{
  "name": "Discord Alerts",
  "url": "https://example.com/webhook",
  "events": [
    "server.registered",
    "server.revoked"
  ]
}
```

#### `GET /api/v2/webhooks/{webhook_id}`

#### `PATCH /api/v2/webhooks/{webhook_id}`

#### `DELETE /api/v2/webhooks/{webhook_id}`

#### `POST /api/v2/webhooks/{webhook_id}/test`

### Audit and Login History

#### `GET /api/v2/audit-logs`

Filters:

- `action`
- `actor`
- `target`

#### `GET /api/v2/login-history`

Filters:

- `user_type=admin|client`
- `user_id`
- `success=true|false`

### Branding and Settings

#### `GET /api/v2/settings/branding`

#### `PATCH /api/v2/settings/branding`

```json
{
  "brand_name": "IPTunnel",
  "brand_color": "#63b3ed",
  "brand_logo_url": "https://...",
  "support_email": "support@example.com",
  "support_url": "https://example.com/support"
}
```

#### `POST /api/v2/settings/cleanup`

```json
{
  "audit_days": 90,
  "history_days": 90
}
```

### Admin Users

#### `GET /api/v2/admin-users`

#### `POST /api/v2/admin-users`

#### `PATCH /api/v2/admin-users/{admin_id}`

#### `DELETE /api/v2/admin-users/{admin_id}`

Rule:

- only `superadmin` may manage admin users

## VPS API v2

This part replaces `/vps/...`.

### Design Rules

- protocol is a path segment, not encoded in many route names
- same verbs across protocols
- shared account model where possible

### Protocols

- `ssh`
- `vmess`
- `vless`
- `trojan`

### Accounts

#### `GET /api/v2/vps/accounts/{protocol}`

List accounts for a protocol.

#### `POST /api/v2/vps/accounts/{protocol}`

Create account.

SSH request:

```json
{
  "username": "demo",
  "password": "demo123",
  "expires_in_days": 7,
  "limit_ip": 1,
  "quota_gb": 10
}
```

Xray request:

```json
{
  "username": "demo",
  "secret": "uuid-or-password",
  "expires_in_days": 7,
  "limit_ip": 1,
  "quota_gb": 10
}
```

#### `GET /api/v2/vps/accounts/{protocol}/{username}`

#### `PATCH /api/v2/vps/accounts/{protocol}/{username}`

Allowed operations:

- renew
- rotate secret/password
- set quota
- set IP limit
- lock/unlock

Example:

```json
{
  "expires_in_days": 30,
  "quota_gb": 20,
  "reset_bandwidth": true
}
```

#### `DELETE /api/v2/vps/accounts/{protocol}/{username}`

### Trials

#### `POST /api/v2/vps/accounts/{protocol}/trials`

```json
{
  "duration": "1h"
}
```

### Runtime

#### `GET /api/v2/vps/runtime`

Returns:

- hostname
- public_ip
- enabled transports
- ports
- license state
- slowdns info
- hysteria info

#### `GET /api/v2/vps/services`

Current service state summary.

#### `POST /api/v2/vps/transports/{transport}/enable`

#### `POST /api/v2/vps/transports/{transport}/disable`

Where `transport` may be:

- `hysteria`
- `openvpn`
- `slowdns`

#### `GET /api/v2/vps/bandwidth`

Returns aggregate and per-user bandwidth from the local DB.

#### `POST /api/v2/vps/backup`

Creates a config backup.

#### `POST /api/v2/vps/restore`

Restores a chosen backup.

#### `POST /api/v2/vps/certificates/letsencrypt`

Issues and installs a trusted TLS cert.

## Event Names

Suggested webhook events:

- `server.registered`
- `server.revoked`
- `server.restored`
- `server.deleted`
- `server.stale`
- `client.created`
- `client.suspended`
- `client.activated`
- `subscription.created`
- `subscription.expired`
- `subscription.cancelled`
- `admin.login`
- `client.login`

## Rate Limits

Recommended defaults:

- auth login: `5 / 15 min / IP`
- install ticket issue: `10 / min / IP`
- server register: `20 / hour / IP`
- check-in: `1 / minute / server`
- admin API writes: `60 / min / token`

## Security Decisions

### Token storage

Store:

- `token_hash`
- `token_prefix`

Do not store full reusable API tokens in plaintext for v2.

### Install tickets

- one-time
- DB-backed
- IP-bound
- short-lived
- never expose the client token

### Trusted proxy handling

Make trusted proxies configurable, not hardcoded.

Suggested setting:

```php
TRUSTED_PROXIES=127.0.0.1,::1,10.0.0.0/8
```

### Auditability

Every write operation should record:

- actor type
- actor id
- action
- target type
- target id
- source IP
- timestamp

## Suggested Build Order

Because this is a fresh system, the safest order is:

1. implement `/api/v2/auth`, `/api/v2/clients`, `/api/v2/servers`
2. move installer/register/check-in flow to v2
3. implement `/api/v2/subscriptions`, `/api/v2/webhooks`, `/api/v2/settings`
4. implement `/api/v2/vps/accounts/*`
5. retire old `/authorize`, `/register`, `/checkin`, `/status`, and `/vps/...`

## Recommended Fresh-Cut Decision

Since you said there are no users yet:

- keep old endpoints only for internal migration/testing
- do not publicly document them
- build new work only on `/api/v2/...`

That avoids carrying legacy route debt into the new product.
