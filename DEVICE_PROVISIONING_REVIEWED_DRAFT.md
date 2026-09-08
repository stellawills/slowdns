# IPTunnel Device Provisioning Reviewed Draft

## Why This Reviewed Draft Is Different

The first draft assumed a cleaner control-plane model with relational users, devices, and credentials from day one.

After reviewing your actual web/app backend in `C:\Users\ROG\Documents\Dev\IPTunnel Web`, the right design should adapt to what you already have:

- a PHP API at `api/v2/index.php`
- an admin SPA in plain HTML/JS
- device-centric app auth already in place
- Play Integrity support already present
- app session JWT support already present
- most app data currently stored in JSON files, not SQL tables

So the reviewed draft is:

- device-first now
- account-aware later
- reuse current app auth
- move only security-critical state to a stronger store first

## What Already Exists In Your Web/App Backend

From the current codebase:

- `deviceId` is already the main app-side identity
- signed app headers already exist:
  - `X-App-Device`
  - `X-App-Ts`
  - `X-App-Nonce`
  - `X-App-Sign`
  - `X-App-Session`
- app session JWTs already exist
- Play Integrity verification already exists
- coin sync and redeem logic already uses `deviceId`
- some records already carry `authUid`

That means you do **not** need to invent app-device identity from scratch.

You already have the foundation.

## Current Reality

Right now your backend treats one device as one app user for most operations.

That is visible in:

- `user_coins.json`
- `coin_ledger.json`
- `redeemed_codes.json`

and the API logic keyed by `deviceId`.

This is good for a first anti-sharing rollout, because:

- device identity already exists
- app auth already exists
- admin tooling already understands device-level users

But it also means:

- you do not yet have a true multi-device user model
- security state is still too file-centric for 10k+ users if you start issuing per-device VPN credentials

## Main Recommendation

Do this in two stages.

### Stage 1: Device-first provisioning

Keep your current app model:

- one `deviceId` = one app identity
- one device gets one VPN credential set
- one credential set = one active seat
- if the same credential is reused elsewhere, treat it as leaked or suspicious

This gives you real anti-sharing protection fast.

### Stage 2: Account + devices

Later, introduce a real user account layer:

- one `authUid` or app account
- many devices under that account
- device limits per account
- one login can still be limited to one active device if that is the product rule

This is the right long-term model, but it is not required for the first protection release.

## Reviewed Architecture

### Layer 1: Device identity

Use existing fields/signals:

- `deviceId`
- app signing headers
- app session JWT
- Play Integrity verdict
- `authUid` when available

### Layer 2: Device registry

Add a proper registry for devices.

Short term:

- SQLite or MySQL is strongly preferred
- avoid keeping credential lifecycle only in JSON files

### Layer 3: Device credentials

Each device gets its own credential set:

- SSH username/password
- SlowDNS reuses SSH credentials
- OpenVPN device profile for now
- VMess/VLESS/Trojan per-device UUID or password
- Hysteria per-device auth token when supported by your server model

### Layer 4: Single-seat enforcement, revocation, and rotation

If one config leaks:

- allow only one active seat per credential set
- if the same credential is used concurrently from another device or location, flag it
- revoke only that device
- rotate only that device's credentials
- keep everyone else online
- only hard-ban after repeated abuse or clear proof of sharing

## Best Fit With Your Current Backend

Because your current web backend is action-based, not REST-first, the fastest implementation is to stay close to the current shape.

Instead of immediately forcing:

- `/api/v2/app/devices/register`
- `/api/v2/app/devices/provision`

you can first add actions like:

- `action=device_register`
- `action=device_provision`
- `action=device_credentials`
- `action=device_rotate`
- `action=device_revoke`
- `action=device_heartbeat`

Long term, you can still move to cleaner REST routes.

## Recommended Storage Model

### Keep in JSON for now

These can stay file-backed for the moment:

- admin UI settings
- coin code pools
- UI preferences
- broadcast payloads

### Move out of JSON now

These should move to SQLite or MySQL first:

- device registry
- per-device VPN credentials
- revoke/rotate state
- device session history
- suspicious-use events

Reason:

- these are security-sensitive
- these are write-heavy
- they need safe concurrent updates
- JSON file storage becomes fragile at 10k+ active devices

## Minimum New Tables

These tables fit your current web/app backend better than the original draft.

### 1. `app_devices`

This is the new source of truth for devices.

```sql
CREATE TABLE IF NOT EXISTS app_devices (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    device_id VARCHAR(64) NOT NULL UNIQUE,
    auth_uid VARCHAR(128) NOT NULL DEFAULT '',
    android_id_hash CHAR(64) NOT NULL DEFAULT '',
    install_id VARCHAR(64) NOT NULL DEFAULT '',
    package_name VARCHAR(128) NOT NULL DEFAULT '',
    signing_cert_sha256 CHAR(64) NOT NULL DEFAULT '',
    app_version VARCHAR(50) NOT NULL DEFAULT '',
    status ENUM('active','revoked','blocked') NOT NULL DEFAULT 'active',
    integrity_level ENUM('none','basic','device','strong') NOT NULL DEFAULT 'none',
    first_seen_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    last_seen_at DATETIME NULL,
    last_ip VARCHAR(45) NOT NULL DEFAULT '',
    note TEXT NOT NULL
);
```

### 2. `app_device_credentials`

```sql
CREATE TABLE IF NOT EXISTS app_device_credentials (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    device_id VARCHAR(64) NOT NULL,
    protocol ENUM('ssh','openvpn','vmess','vless','trojan','hysteria') NOT NULL,
    server_id VARCHAR(64) NOT NULL,
    username VARCHAR(64) NOT NULL DEFAULT '',
    secret_hash VARCHAR(255) NOT NULL DEFAULT '',
    secret_preview VARCHAR(12) NOT NULL DEFAULT '',
    issued_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    expires_at DATETIME NULL,
    revoked_at DATETIME NULL,
    status ENUM('active','rotating','revoked','expired') NOT NULL DEFAULT 'active',
    INDEX idx_device_protocol (device_id, protocol, status),
    INDEX idx_server_protocol (server_id, protocol, status)
);
```

### 3. `app_device_events`

```sql
CREATE TABLE IF NOT EXISTS app_device_events (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    device_id VARCHAR(64) NOT NULL,
    event_type VARCHAR(64) NOT NULL,
    ip_address VARCHAR(45) NOT NULL DEFAULT '',
    detail_json JSON NULL,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_device_created (device_id, created_at),
    INDEX idx_type_created (event_type, created_at)
);
```

### 4. `app_device_sessions`

Only if you want to persist short-lived app session metadata server-side.

```sql
CREATE TABLE IF NOT EXISTS app_device_sessions (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    device_id VARCHAR(64) NOT NULL,
    session_token_hash CHAR(64) NOT NULL UNIQUE,
    issued_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    expires_at DATETIME NOT NULL,
    last_seen_at DATETIME NULL,
    revoked_at DATETIME NULL,
    INDEX idx_device_expires (device_id, expires_at)
);
```

## Protocol Mapping

### SSH

Best first protocol for true `username:password` enforcement.

- create one SSH username/password per device
- map it to `device_id`
- allow only one active seat for that credential
- rotate on revoke or suspicious reuse

### SlowDNS

Reuse SSH credentials.

Reason:

- SlowDNS is only transport to SSH
- no new account model is needed

### OpenVPN

Your current OpenVPN path is not yet true `username:password` auth.

Reviewed recommendation:

- first treat OpenVPN as one profile per device
- revoke or rotate the device profile if it leaks
- later add real `auth-user-pass` support if you want the same login model as SSH

### VMess / VLESS / Trojan

- per-device UUID or password
- one app device = one Xray client object

### Hysteria

Current Hysteria in your SSH stack is server-wide.

That means:

- it is weaker for anti-sharing than SSH/Xray unless you redesign it

Reviewed recommendation:

- do not block the whole rollout on Hysteria
- treat Hysteria as a later phase

## Reviewed API Actions

These fit your current `api/v2/index.php?action=...` design.

### `device_register`

Purpose:

- create or refresh a device registry record

Input:

- `deviceId`
- `androidIdHash`
- `installId`
- `authUid`
- `appVersion`
- `signingCertSha256`
- attestation payload

Output:

- device status
- whether provisioning is allowed

### `device_provision`

Purpose:

- issue or refresh device-specific VPN credentials

Input:

- `deviceId`
- requested protocol list
- preferred region or server pool

Output:

- credential set for that device only

### `device_credentials`

Purpose:

- return current active credentials for the calling device

### `device_rotate`

Purpose:

- revoke old device credentials
- create fresh ones

### `device_revoke`

Purpose:

- disable the device completely

### `device_heartbeat`

Purpose:

- mark last seen
- allow silent rotation on expiry

## How To Use `authUid`

Your current code already sometimes stores `authUid`.

That is the bridge to a future real account model.

Reviewed recommendation:

- Stage 1:
  - use `deviceId` as the primary subject
  - keep `authUid` optional metadata

- Stage 2:
  - make `authUid` the parent account identity
  - attach many devices under one `authUid`
  - add `max_devices_per_user`

So the migration path is smooth:

- now: device-first
- later: account + devices

## Device Limits

### Stage 1

If there is no stable user account system yet:

- no multi-device entitlement yet
- one device = one app identity

### Stage 2

When `authUid` or account login becomes authoritative:

- add per-plan device limits
- example:
  - free = 1
  - standard = 2
  - premium = 3 to 5

## Security Rules

### Good

- require current app auth headers
- require valid app session JWT for provisioning
- require Play Integrity for high-value actions
- hash `ANDROID_ID`, do not store raw if not necessary
- enforce one active seat per credential set where the protocol allows it
- rotate leaked credentials

### Avoid

- banning permanently on the first suspicious duplicate use
- trusting package name alone
- trusting `ANDROID_ID` alone
- leaving credentials global per protocol
- storing only in JSON files forever

## Best First Implementation For This Codebase

This is the fastest version that matches what you already built.

### Phase A

- keep current app auth exactly as it is
- add `app_devices`
- add `app_device_credentials`
- add `device_register`
- add `device_provision`
- issue per-device SSH credentials
- enforce one active seat per SSH credential
- let SlowDNS reuse SSH credentials

### Phase B

- add Xray per-device credentials
- add revoke and rotate
- add suspicious device event tracking
- add duplicate-use detection and response policy

### Phase C

- add `authUid`-based multi-device accounts
- add per-plan device limits
- add support dashboard for devices

### Phase D

- add per-device OpenVPN profiles
- later add OpenVPN `auth-user-pass` if you want true per-login username/password there
- redesign Hysteria if you want equal anti-sharing strength there

## Final Reviewed Recommendation

For your actual web server and app base, the best design is not:

- full relational user/device/account rewrite on day one

The best design is:

- reuse current app auth
- keep `deviceId` as the first rollout identity
- introduce a proper device registry
- issue VPN credentials per device
- enforce one active seat per credential where supported
- rotate and revoke per device
- later promote `authUid` into a true account layer

That gives you:

- a realistic implementation path
- minimal disruption to your current app/web code
- real anti-sharing improvement without trying to rebuild the whole platform first
