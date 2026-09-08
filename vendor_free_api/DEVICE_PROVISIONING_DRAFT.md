# IPTunnel Device Provisioning Draft

## Goal

Protect the VPN business model by moving from shared configs to per-user, per-device credentials.

This does not make extraction impossible, but it makes leaks smaller, easier to detect, and easy to revoke.

For your case:

- 10k+ app users
- Android app already has `ANDROID_ID`
- current stack already has API v2, clients, servers, install tickets, and protocol account generation

the best practical model is:

- one app user account
- one or more registered devices under that user
- one credential set per device
- short-lived provisioning sessions
- server-side revocation and rotation

## What This Solves

- one leaked config no longer affects all users
- one user cannot casually share the same config with many other people
- you can limit devices per account
- you can revoke only the leaked device
- you can rotate credentials automatically
- you can detect suspicious reuse

## What This Does Not Solve

- it does not make standard protocols impossible to use in third-party apps forever
- it does not make `ANDROID_ID` a perfect trust signal
- it does not stop rooted, hooked, or repackaged apps completely

It is still the strongest realistic approach for a standard SSH/OpenVPN/Xray/Hysteria product.

## Core Model

Use four layers:

1. `app_users`
2. `user_devices`
3. `device_credentials`
4. `device_sessions`

Relationship:

- one `app_user` can have many `user_devices`
- one `user_device` can have one active credential set per protocol/server pool
- one `device_session` is short-lived and used only for app provisioning

## Identity Signals

Do not rely only on package name.

Do not rely only on `ANDROID_ID`.

Use these together:

- `ANDROID_ID`
- app-generated `install_id` or `app_instance_id`
- app signing cert digest
- app version / build number
- optional Play Integrity verdict
- optional device public key for challenge-response

Recommended trust rule:

- `ANDROID_ID` = device hint
- `install_id` = app instance identity
- attestation = stronger proof
- server-issued session token = actual authorization

## Recommended Tables

These tables belong in the control plane, next to the current PHP license/API v2 schema.

### 1. `app_users`

Represents end users of the VPN app.

```sql
CREATE TABLE IF NOT EXISTS `app_users` (
    `id` BIGINT AUTO_INCREMENT PRIMARY KEY,
    `client_id` INT NULL DEFAULT NULL,
    `email` VARCHAR(255) NOT NULL DEFAULT '',
    `phone` VARCHAR(32) NOT NULL DEFAULT '',
    `username` VARCHAR(64) NOT NULL UNIQUE,
    `password_hash` VARCHAR(255) NOT NULL,
    `status` ENUM('active','suspended','expired','deleted') NOT NULL DEFAULT 'active',
    `plan_code` VARCHAR(50) NOT NULL DEFAULT 'free',
    `max_devices` INT NOT NULL DEFAULT 1,
    `created_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `last_login_at` DATETIME NULL,
    INDEX `idx_status` (`status`),
    INDEX `idx_client_id` (`client_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

Notes:

- `client_id` is optional if you want app users grouped under an existing B2B client/reseller
- if this is direct-to-consumer only, `client_id` can stay `NULL`

### 2. `user_devices`

Represents one phone/install.

```sql
CREATE TABLE IF NOT EXISTS `user_devices` (
    `id` BIGINT AUTO_INCREMENT PRIMARY KEY,
    `app_user_id` BIGINT NOT NULL,
    `device_uuid` CHAR(36) NOT NULL UNIQUE,
    `install_id` CHAR(36) NOT NULL,
    `android_id_hash` CHAR(64) NOT NULL,
    `device_name` VARCHAR(120) NOT NULL DEFAULT '',
    `device_model` VARCHAR(120) NOT NULL DEFAULT '',
    `android_version` VARCHAR(50) NOT NULL DEFAULT '',
    `app_version` VARCHAR(50) NOT NULL DEFAULT '',
    `signing_cert_sha256` CHAR(64) NOT NULL DEFAULT '',
    `device_pubkey` TEXT NOT NULL DEFAULT '',
    `attestation_level` ENUM('none','basic','device','strong') NOT NULL DEFAULT 'none',
    `status` ENUM('pending','active','revoked','blocked') NOT NULL DEFAULT 'pending',
    `first_seen_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `last_seen_at` DATETIME NULL,
    `last_ip` VARCHAR(45) NOT NULL DEFAULT '',
    `note` TEXT NOT NULL,
    CONSTRAINT `fk_user_devices_user` FOREIGN KEY (`app_user_id`)
        REFERENCES `app_users` (`id`) ON DELETE CASCADE,
    INDEX `idx_user_status` (`app_user_id`, `status`),
    INDEX `idx_install_id` (`install_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

Notes:

- store `android_id_hash`, not raw `ANDROID_ID`
- `device_uuid` is server-side canonical device id
- `install_id` is app-generated and survives normal app use

### 3. `device_credentials`

Stores actual credentials issued for each protocol.

```sql
CREATE TABLE IF NOT EXISTS `device_credentials` (
    `id` BIGINT AUTO_INCREMENT PRIMARY KEY,
    `device_id` BIGINT NOT NULL,
    `server_id` VARCHAR(32) NOT NULL,
    `protocol` ENUM('ssh','openvpn','vmess','vless','trojan','hysteria') NOT NULL,
    `username` VARCHAR(64) NOT NULL DEFAULT '',
    `secret_hash` VARCHAR(255) NOT NULL DEFAULT '',
    `secret_preview` VARCHAR(12) NOT NULL DEFAULT '',
    `external_ref` VARCHAR(128) NOT NULL DEFAULT '',
    `issued_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `expires_at` DATETIME NULL,
    `revoked_at` DATETIME NULL,
    `last_used_at` DATETIME NULL,
    `status` ENUM('active','rotating','revoked','expired') NOT NULL DEFAULT 'active',
    CONSTRAINT `fk_device_creds_device` FOREIGN KEY (`device_id`)
        REFERENCES `user_devices` (`id`) ON DELETE CASCADE,
    INDEX `idx_device_protocol` (`device_id`, `protocol`, `status`),
    INDEX `idx_server_protocol` (`server_id`, `protocol`, `status`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

Notes:

- store hash of secret when possible
- `external_ref` can map to a VPS-side username, UUID, cert CN, or account id
- one device can have multiple protocol credentials, but each is isolated

### 4. `device_sessions`

Short-lived provisioning/auth sessions for the mobile app.

```sql
CREATE TABLE IF NOT EXISTS `device_sessions` (
    `id` BIGINT AUTO_INCREMENT PRIMARY KEY,
    `device_id` BIGINT NOT NULL,
    `session_token_hash` CHAR(64) NOT NULL UNIQUE,
    `scope` VARCHAR(100) NOT NULL DEFAULT 'provision',
    `issued_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `expires_at` DATETIME NOT NULL,
    `last_seen_at` DATETIME NULL,
    `ip_address` VARCHAR(45) NOT NULL DEFAULT '',
    `user_agent` VARCHAR(255) NOT NULL DEFAULT '',
    `revoked_at` DATETIME NULL,
    CONSTRAINT `fk_device_sessions_device` FOREIGN KEY (`device_id`)
        REFERENCES `user_devices` (`id`) ON DELETE CASCADE,
    INDEX `idx_device_expires` (`device_id`, `expires_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

### 5. `device_events`

Optional but strongly recommended.

```sql
CREATE TABLE IF NOT EXISTS `device_events` (
    `id` BIGINT AUTO_INCREMENT PRIMARY KEY,
    `device_id` BIGINT NOT NULL,
    `event_type` VARCHAR(50) NOT NULL,
    `ip_address` VARCHAR(45) NOT NULL DEFAULT '',
    `detail_json` JSON NULL,
    `created_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT `fk_device_events_device` FOREIGN KEY (`device_id`)
        REFERENCES `user_devices` (`id`) ON DELETE CASCADE,
    INDEX `idx_device_created` (`device_id`, `created_at`),
    INDEX `idx_event_type` (`event_type`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

Examples:

- `device_registered`
- `provision_granted`
- `credential_rotated`
- `credential_rejected`
- `integrity_failed`
- `too_many_devices`
- `suspicious_concurrent_use`

## Protocol Strategy

### SSH

Best fit for your current stack.

- create one VPS username/password per device
- username format:
  - `u<user_id>d<device_id>`
  - or a shorter encoded form like `u1d3k9`
- rotate password on revoke or suspicion

### SlowDNS

Reuse the same SSH username/password.

Reason:

- SlowDNS is only a transport to SSH
- no separate SlowDNS account is needed

### OpenVPN

Recommended phased approach:

Phase 1:

- shared server certs
- per-device OpenVPN username/password via `auth-user-pass`
- map that username/password to `device_credentials`

Phase 2:

- per-device client certificate or per-device client profile if you want stronger isolation

Reason:

- per-device certs are stronger
- per-device user/pass is much easier to operate at 10k+ scale

### VMess / VLESS / Trojan

- generate one UUID or password per device
- one device = one Xray client object
- revoke/remove only that device’s UUID

### Hysteria

- do not keep one global server password for all users if you want real anti-sharing
- issue per-device auth string or token
- if current Hysteria deployment stays server-wide, this protocol remains weaker than the others

## Recommended API v2 Additions

These routes should live under a dedicated app-facing namespace, not mixed into admin-only routes.

Base:

```text
/api/v2/app
```

### Auth

- `POST /api/v2/app/auth/login`
- `POST /api/v2/app/auth/logout`
- `POST /api/v2/app/auth/refresh`

### Device registration

- `POST /api/v2/app/devices/register`
- `POST /api/v2/app/devices/attest`
- `GET /api/v2/app/devices`
- `DELETE /api/v2/app/devices/{device_uuid}`

### Provisioning

- `POST /api/v2/app/devices/{device_uuid}/provision`
- `POST /api/v2/app/devices/{device_uuid}/rotate`
- `POST /api/v2/app/devices/{device_uuid}/heartbeat`

### Config fetch

- `GET /api/v2/app/devices/{device_uuid}/credentials`
- `GET /api/v2/app/devices/{device_uuid}/servers`

### Admin / support

- `GET /api/v2/app-users`
- `GET /api/v2/app-users/{user_id}/devices`
- `POST /api/v2/app-users/{user_id}/devices/{device_id}/revoke`
- `POST /api/v2/app-users/{user_id}/devices/{device_id}/rotate`

## Suggested Payloads

### `POST /api/v2/app/devices/register`

Request:

```json
{
  "install_id": "fb15400f-6b40-4b19-b0f1-7d55d2496d2b",
  "android_id": "raw-android-id-from-app",
  "device_name": "Redmi Note 13",
  "device_model": "23124RA7EO",
  "android_version": "14",
  "app_version": "3.2.1",
  "signing_cert_sha256": "....",
  "attestation": {
    "provider": "play_integrity",
    "token": "...."
  },
  "device_pubkey": "base64..."
}
```

Response:

```json
{
  "data": {
    "device_uuid": "8b4ca69d-570d-4a7f-885f-33d8a5304e0d",
    "status": "active",
    "max_devices": 2,
    "remaining_slots": 1,
    "session_token": "short-lived-device-session"
  },
  "meta": {
    "request_id": "..."
  },
  "error": null
}
```

### `POST /api/v2/app/devices/{device_uuid}/provision`

Request:

```json
{
  "preferred_region": "ng",
  "protocols": ["ssh", "openvpn", "vmess"],
  "transport_preferences": {
    "ssh": ["ws", "squid", "ssl"],
    "openvpn": ["tcp", "udp"]
  }
}
```

Response:

```json
{
  "data": {
    "device_uuid": "8b4ca69d-570d-4a7f-885f-33d8a5304e0d",
    "server": {
      "server_id": "srv_xxx",
      "hostname": "ng1.example.com",
      "region": "ng"
    },
    "credentials": {
      "ssh": {
        "username": "u18d442",
        "password": "random-secret",
        "ws_path": "/sshws",
        "squid_ports": "3128,8080"
      },
      "openvpn": {
        "profile_url": "https://...",
        "username": "ovpn_u18d442",
        "password": "random-secret"
      },
      "vmess": {
        "uuid": "...."
      }
    },
    "expires_at": "2026-03-20T15:00:00Z"
  },
  "meta": {
    "request_id": "..."
  },
  "error": null
}
```

## Device Limit Logic

Recommended default:

- free: `1` device
- paid basic: `2` devices
- premium: `3-5` devices

Rule:

- only `active` devices count toward the limit
- `revoked` and `deleted` devices do not count
- `pending` devices count only for a short registration window if you want to prevent spam

When limit is exceeded:

1. reject registration
2. return the user’s active devices
3. let the app revoke an old device

## Provisioning Flow

### Flow A: first login on device

1. user logs into app
2. app calls `POST /app/devices/register`
3. backend verifies plan and device limit
4. backend stores device
5. backend issues short-lived session token
6. app calls `POST /app/devices/{id}/provision`
7. backend picks server and issues per-device credentials
8. app stores only what it needs locally

### Flow B: app restart

1. app sends session token + device info
2. backend validates device and session
3. backend returns fresh credentials if rotated or near expiry

### Flow C: leaked credentials

1. detect suspicious reuse
2. mark credential `rotating` or `revoked`
3. app gets forced reprovision on next heartbeat
4. leaked config dies

## Rotation Rules

Rotate when:

- device is revoked
- same credential appears from unusual IP patterns
- impossible travel
- too many concurrent sessions
- app signature mismatch
- attestation fails repeatedly

Recommended expiries:

- device session token: `15-60 minutes`
- provisioned config package: `6-24 hours`
- protocol credentials: `7-30 days`, rotated silently when app checks in

## Detection Rules

Recommended signals:

- same device credential used from many countries in short time
- same credential used by many IPs simultaneously
- same user has many device registrations with weak attestation
- same `ANDROID_ID` reused across many accounts
- same `install_id` appears with different signing cert digests

These should create flags, not instant bans by default.

## VPS Integration Model

There are two good ways to connect this to your current server agents.

### Option A: control plane pushes changes

- control plane creates credential rows
- server agent polls for assignments
- server agent creates SSH/Xray/OpenVPN accounts locally

Good:

- simpler client API
- one central source of truth

Bad:

- requires sync workers

### Option B: app API requests provisioning, control plane asks target VPS live

- control plane picks a server
- control plane calls that VPS API
- VPS creates account immediately
- control plane stores resulting credential refs

Good:

- simpler rollout on current IPTunnel architecture

Bad:

- provisioning depends on live VPS availability

Recommended for you:

- start with Option B
- move to Option A later if scale or reliability needs it

## How `ANDROID_ID` Should Be Used

Good use:

- hash and store it
- compare it across sessions
- use it as one fingerprint input

Bad use:

- using it as the only device identity
- treating it as impossible to spoof

Recommended formula:

```text
device_fingerprint = sha256(android_id + install_id + signing_cert_sha256)
```

But keep raw components separately too if needed for support and risk scoring.

## Migration Plan

### Phase 1

- add control-plane tables
- add app login and device registration routes
- issue per-device SSH credentials only
- keep other protocols on current model temporarily

### Phase 2

- add per-device VMess/VLESS/Trojan credentials
- add device revoke and rotate
- add suspicious-use detection

### Phase 3

- add per-device OpenVPN credentials
- add stronger attestation checks
- stop serving long-lived shared configs

### Phase 4

- add support dashboard for:
  - active devices
  - revoke device
  - rotate device
  - suspicious device events

## Best First Cut

If you want the fastest version that gives real business protection:

1. add `app_users`
2. add `user_devices`
3. add `device_credentials`
4. implement app login
5. implement `register device`
6. implement per-device SSH credentials
7. let SlowDNS reuse those SSH credentials
8. later add the other protocols one by one

That gets you real value quickly without trying to solve every protocol in one release.

## Final Recommendation

For your app, the best design is:

- user account
- max device count
- one device record per install
- one credential set per device
- session-based provisioning
- `ANDROID_ID` as a signal, not the only trust source
- attestation when possible
- revoke and rotate aggressively

This will not make extraction impossible, but it will make mass sharing much harder and much more manageable.
