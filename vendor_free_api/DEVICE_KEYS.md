# Device-key SSH enrollment

Status: local implementation and unit tests. VPS authentication, Android
Keystore signing on a physical device, and forwarding are not yet verified.

The app uses its installation P-256 key to sign the SSH session authentication
request via Trilead AgentIdentity. A copied username cannot authenticate without
that key. Both Normal SSH and SocksHTTP authentication paths skip password,
keyboard-interactive and none authentication when managed SSH is selected.

The web API requires the existing attested session and single-use signed
challenge, then sends the verified public key to the private VPS API. The VPS
creates a dpk_ account whose root-managed authorized key has a 30-day expiry.
The web and app check that the returned key fingerprint matches enrollment.
On the first connection after expiry, the verified web request automatically
retries once as recovery and extends the same key for another configured TTL;
it does not rotate the installation key. App reinstall/key loss currently requires operator recovery
of the web device pin. Do not silently replace that pin.

## Menu-based host configuration

Run `iptunnel-menu`, select `Device provisioning`, and prepare SSH, OpenVPN, or
Xray. The menu creates required directories and the dedicated client CA, writes
the provisioning section in `/etc/iptunnel/config.json`, validates the selected
runtime, activates its services, and restores prior configuration on failure.
For SSH it installs managed-ssh.conf, verifies sshd, and reloads OpenSSH before
enabling provisioning.ssh_device_keys.
The provisioning endpoint checks effective sshd configuration before issuance.
Provisioning data must remain root-private under /var/lib/iptunnel-provisioning.

The private web registry must allow protocol ssh for the server. Published
server metadata must include DeviceProvisioning=true and ProvisioningServerId.
Use an OpenSSH transport endpoint. Dropbear and third-party SSH daemons are not
supported by this enrollment policy. Existing forwarded SSL/WS/SlowDNS endpoints
must terminate at that OpenSSH daemon; verify their actual target before use.

Test first enrollment, normal connect, reconnect, forwarding, copied username
in another client, altered fingerprint, expired key, offline API, app restart,
and reinstall. Confirm no password appears in app logs or exported config.
Expiry prevents new SSH authentication; it does not terminate existing tunnels.

## Managed Xray certificates

The app now includes a pinned native external-signing bridge for P-256 TLS
client authentication, including the uTLS path. Private keys remain in Android
Keystore. Reproduction sources and build script are under tools/native/xray
and tools/native/rebuild-xray-device.ps1 in the Android repository.

Managed VMess/VLESS/Trojan users are installed only in a separate Xray service.
Nginx requires a valid device certificate and matching certificate CN/path.
The public port defaults to 9443; loopback 19440-19442 and 19449 must be free.
Never expose the loopback listeners/API, forward legacy routes to them, or add
managed credentials to shared legacy listeners. A device with its own valid
key is authorized at TLS ingress; this is not hardware attestation at every
packet and does not detect a compromised/rooted authorized device.

Prepare Xray from the menu only on a staging VPS first. Provide its public port,
server name, server certificate and key when prompted. The client CA
must be dedicated to this enrollment service, root-private, with keyCertSign;
never use a public CA or publish its private key. Server certificates may use
root-owned Let's Encrypt symlinks. The server certificate must be trusted by
the app's TLS policy. Existing explicit SNI, WS Host and server pins are kept.
The app changes only the managed transport port/path and credentials.

Allow the managed public port in the firewall. In the private web registry,
allow the required protocols and set managed_port to the same integer. Keep
DeviceProvisioning disabled in published metadata until staging acceptance.
After acceptance, publish DeviceProvisioning=true and ProvisioningServerId.
Update the Android app before enabling this new certificate contract.

The dial endpoint must reach this listener with end-to-end TLS. An arbitrary
third-party TLS-terminating front cannot carry the device proof. There is no
password-only fallback if provisioning, TLS verification or signing fails.

## Managed OpenVPN certificates

Prepare OpenVPN from the menu. It discovers the installed IPTunnel profiles,
backs them up in memory for transactional rollback, adds the local management
sockets and dedicated client CA, validates each profile, then restarts OpenVPN
and its provisioning monitor. The resulting profiles must require
client certificates and the configured CA; the monitor checks certificate CN
against the unique username in addition to password and session admission.
Do not enable the catalogue flag until the monitor is healthy.

## Verification and limits

Local checks cover real certificate issuance, proof replay/substitution,
OpenVPN admission, installer parity, and real Nginx/Xray HTTP transfers through
the external signer for all three Xray protocols. The desktop signer uses a
fixture private key, not Android hardware. Android debug builds and unit tests
are separate from physical-device acceptance.

Client certificates expire after one day and renew through a fresh app proof.
Expiry rejects new TLS authentication; it does not kill established tunnels.
SSH/Xray do not claim two-device counting from TCP connections. OpenVPN retains
its authenticated-session limit and automatic suspension/expiry recovery.
Reinstall/key loss
requires deliberate operator recovery of the pinned identity, never an
automatic key reset. Do not erase provisioning databases during upgrades.

Still required before production: real Android SSH forwarding and OpenVPN/Xray
Keystore handshakes, restart/renewal/key-loss tests, Linux service activation,
and proving the deployed host has no alternate route to managed listeners.
No production deployment or physical-device launch is implied by local tests.
