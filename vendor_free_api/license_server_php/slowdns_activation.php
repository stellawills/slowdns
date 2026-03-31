<?php

// --- Constants ----------------------------------------------------------------

// Maximum activation attempts allowed per install code (includes released/failed retries).
const SLOWDNS_MAX_ACTIVATIONS_PER_CODE = 5;

// Install-token lifetime in seconds (10 minutes to accommodate slow VPS builds).
const SLOWDNS_TOKEN_TTL = 600;

// --- Schema -------------------------------------------------------------------

function slowdns_schema_ensure(): void {
    static $ready = false;
    if ($ready) {
        return;
    }

    db()->exec(
        "CREATE TABLE IF NOT EXISTS `slowdns_install_codes` (
            `id` INT AUTO_INCREMENT PRIMARY KEY,
            `install_code` VARCHAR(32) NOT NULL UNIQUE,
            `request_ip` VARCHAR(45) NOT NULL DEFAULT '',
            `user_agent` VARCHAR(255) NOT NULL DEFAULT '',
            `status` ENUM('issued','consumed','expired') NOT NULL DEFAULT 'issued',
            `activation_count` TINYINT UNSIGNED NOT NULL DEFAULT 0,
            `expires_at` DATETIME NOT NULL,
            `created_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
            `consumed_at` DATETIME NULL,
            INDEX `idx_status` (`status`),
            INDEX `idx_expires_at` (`expires_at`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4"
    );

    // Migrate existing tables that pre-date the activation_count column.
    try {
        db()->exec("ALTER TABLE `slowdns_install_codes` ADD COLUMN `activation_count` TINYINT UNSIGNED NOT NULL DEFAULT 0");
    } catch (Throwable $ignored) {
        // Column already present on upgraded installs — no action needed.
    }

    db()->exec(
        "CREATE TABLE IF NOT EXISTS `slowdns_install_activations` (
            `id` INT AUTO_INCREMENT PRIMARY KEY,
            `activation_id` VARCHAR(32) NOT NULL UNIQUE,
            `install_code_id` INT NOT NULL,
            `machine_id` VARCHAR(128) NOT NULL,
            `ssh_fingerprint` VARCHAR(255) NOT NULL,
            `public_ip` VARCHAR(45) NOT NULL DEFAULT '',
            `hostname` VARCHAR(255) NOT NULL DEFAULT '',
            `install_token` VARCHAR(1024) NOT NULL DEFAULT '',
            `install_token_expires_at` DATETIME NULL,
            `install_token_used_at` DATETIME NULL,
            `created_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
            `last_seen_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
            `released_at` DATETIME NULL,
            INDEX `idx_install_code_id` (`install_code_id`),
            INDEX `idx_binding` (`machine_id`, `ssh_fingerprint`(64)),
            CONSTRAINT `fk_slowdns_install_code` FOREIGN KEY (`install_code_id`)
                REFERENCES `slowdns_install_codes` (`id`) ON DELETE CASCADE
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4"
    );

    // Rate-limit buckets keyed by (ip, endpoint, window).
    db()->exec(
        "CREATE TABLE IF NOT EXISTS `slowdns_rate_limits` (
            `id` INT AUTO_INCREMENT PRIMARY KEY,
            `ip` VARCHAR(45) NOT NULL,
            `endpoint` VARCHAR(64) NOT NULL,
            `window` VARCHAR(20) NOT NULL,
            `hits` SMALLINT UNSIGNED NOT NULL DEFAULT 1,
            UNIQUE KEY `uk_rate` (`ip`, `endpoint`, `window`),
            INDEX `idx_window` (`window`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4"
    );

    $ready = true;
}

function slowdns_base64url_encode(string $value): string {
    return rtrim(strtr(base64_encode($value), '+/', '-_'), '=');
}

function slowdns_base64url_decode(string $value): string {
    $value = strtr($value, '-_', '+/');
    $pad = strlen($value) % 4;
    if ($pad > 0) {
        $value .= str_repeat('=', 4 - $pad);
    }
    $decoded = base64_decode($value, true);
    if ($decoded === false) {
        throw new RuntimeException('Invalid token payload.');
    }
    return $decoded;
}

function slowdns_signing_secret(): string {
    slowdns_schema_ensure();
    $secret = trim(get_setting('slowdns_activation_secret', ''));
    if ($secret !== '') {
        return $secret;
    }
    $secret = bin2hex(random_bytes(32));
    set_setting('slowdns_activation_secret', $secret);
    return $secret;
}

function slowdns_issuer(): string {
    slowdns_schema_ensure();
    $issuer = trim(get_setting('slowdns_activation_issuer', 'https://license.internetshub.com/slowdns'));
    return $issuer !== '' ? $issuer : 'https://license.internetshub.com/slowdns';
}

function slowdns_token_sign(array $payload): string {
    $header = ['alg' => 'HS256', 'typ' => 'SIT', 'kid' => 'v1'];
    $head = slowdns_base64url_encode(json_encode($header, JSON_UNESCAPED_SLASHES));
    $body = slowdns_base64url_encode(json_encode($payload, JSON_UNESCAPED_SLASHES));
    $message = $head . '.' . $body;
    $signature = hash_hmac('sha256', $message, slowdns_signing_secret(), true);
    return $message . '.' . slowdns_base64url_encode($signature);
}

function slowdns_token_verify(string $token): array {
    $parts = explode('.', $token);
    if (count($parts) !== 3) {
        throw new RuntimeException('Install token format is invalid.');
    }
    [$head, $body, $signature] = $parts;
    $message = $head . '.' . $body;
    $expected = slowdns_base64url_encode(hash_hmac('sha256', $message, slowdns_signing_secret(), true));
    if (!hash_equals($expected, $signature)) {
        throw new RuntimeException('Install token signature mismatch.');
    }
    $payload = json_decode(slowdns_base64url_decode($body), true);
    if (!is_array($payload)) {
        throw new RuntimeException('Install token payload is invalid.');
    }
    if ((int) ($payload['exp'] ?? 0) < time()) {
        throw new RuntimeException('Install token has expired.');
    }
    return $payload;
}

function slowdns_generate_install_code(): string {
    slowdns_schema_ensure();
    $alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    do {
        $parts = [];
        for ($i = 0; $i < 3; $i++) {
            $chunk = '';
            for ($j = 0; $j < 6; $j++) {
                $chunk .= $alphabet[random_int(0, strlen($alphabet) - 1)];
            }
            $parts[] = $chunk;
        }
        $code = 'IPT-SD-' . implode('-', $parts);
        $stmt = db()->prepare('SELECT id FROM slowdns_install_codes WHERE install_code = ? LIMIT 1');
        $stmt->execute([$code]);
    } while ($stmt->fetch());

    return $code;
}

function slowdns_validate_install_code(string $code): string {
    $code = strtoupper(trim($code));
    if (!preg_match('/^IPT-[A-Z]{2}-[A-Z0-9]{6}-[A-Z0-9]{6}-[A-Z0-9]{6}$/', $code)) {
        v2_error(422, 'validation_error', 'Install code format is invalid.', ['field' => 'install_code']);
    }
    return $code;
}

function slowdns_cleanup_codes(): void {
    slowdns_schema_ensure();
    db()->exec("UPDATE slowdns_install_codes SET status = 'expired' WHERE status = 'issued' AND expires_at < UTC_TIMESTAMP()");
}

// --- Rate limiting ------------------------------------------------------------

/**
 * Enforce an IP-based rate limit. Throws a 429 v2_error if the limit is exceeded.
 *
 * @param string $endpoint  Bucket label, e.g. 'issue_code' or 'activate'.
 * @param int    $max       Maximum hits allowed inside the window.
 * @param int    $window_s  Window size in seconds (3600 = per-hour, 86400 = per-day).
 */
function slowdns_rate_limit(string $endpoint, int $max, int $window_s = 86400): void {
    slowdns_schema_ensure();
    $ip     = client_ip();
    $window = gmdate('Y-m-d\TH', (int) (floor(time() / $window_s) * $window_s));

    // Upsert: insert on first hit, increment counter on subsequent ones.
    db()->prepare(
        "INSERT INTO `slowdns_rate_limits` (`ip`, `endpoint`, `window`, `hits`)
         VALUES (?, ?, ?, 1)
         ON DUPLICATE KEY UPDATE `hits` = `hits` + 1"
    )->execute([$ip, $endpoint, $window]);

    $stmt = db()->prepare(
        "SELECT `hits` FROM `slowdns_rate_limits` WHERE `ip` = ? AND `endpoint` = ? AND `window` = ?"
    );
    $stmt->execute([$ip, $endpoint, $window]);
    $hits = (int) ($stmt->fetchColumn() ?: 0);

    if ($hits > $max) {
        v2_error(429, 'rate_limit_exceeded', 'Too many requests. Please wait before trying again.');
    }
}

/**
 * Prune stale rate-limit rows so the table stays small.
 * Call this opportunistically alongside the regular cleanup passes.
 */
function slowdns_rate_limit_cleanup(int $window_s = 86400): void {
    $cutoff = gmdate('Y-m-d\TH', (int) (floor((time() - ($window_s * 2)) / $window_s) * $window_s));
    db()->prepare("DELETE FROM `slowdns_rate_limits` WHERE `window` < ?")->execute([$cutoff]);
}

function slowdns_install_code_resource(array $row): array {
    return [
        'install_code'     => $row['install_code'] ?? '',
        'status'           => $row['status'] ?? 'issued',
        'activation_count' => (int) ($row['activation_count'] ?? 0),
        'expires_at'       => isset($row['expires_at']) ? gmdate('c', strtotime((string) $row['expires_at'])) : null,
        'created_at'       => isset($row['created_at']) ? gmdate('c', strtotime((string) $row['created_at'])) : null,
        'consumed_at'      => !empty($row['consumed_at']) ? gmdate('c', strtotime((string) $row['consumed_at'])) : null,
    ];
}

function slowdns_activation_resource(array $row): array {
    return [
        'activation_id' => $row['activation_id'] ?? '',
        'hostname' => $row['hostname'] ?? '',
        'public_ip' => $row['public_ip'] ?? '',
        'machine_id' => $row['machine_id'] ?? '',
        'ssh_fingerprint' => $row['ssh_fingerprint'] ?? '',
        'install_token_expires_at' => !empty($row['install_token_expires_at']) ? gmdate('c', strtotime((string) $row['install_token_expires_at'])) : null,
        'install_token_used_at' => !empty($row['install_token_used_at']) ? gmdate('c', strtotime((string) $row['install_token_used_at'])) : null,
        'created_at' => !empty($row['created_at']) ? gmdate('c', strtotime((string) $row['created_at'])) : null,
        'last_seen_at' => !empty($row['last_seen_at']) ? gmdate('c', strtotime((string) $row['last_seen_at'])) : null,
        'released_at' => !empty($row['released_at']) ? gmdate('c', strtotime((string) $row['released_at'])) : null,
    ];
}

function slowdns_find_code(string $code): ?array {
    slowdns_schema_ensure();
    $stmt = db()->prepare('SELECT * FROM slowdns_install_codes WHERE install_code = ? LIMIT 1');
    $stmt->execute([$code]);
    return $stmt->fetch() ?: null;
}

function slowdns_find_activation(string $activation_id): ?array {
    slowdns_schema_ensure();
    $stmt = db()->prepare('SELECT * FROM slowdns_install_activations WHERE activation_id = ? LIMIT 1');
    $stmt->execute([$activation_id]);
    return $stmt->fetch() ?: null;
}

function v2_slowdns_issue_code(): never {
    // 10 code requests per IP per hour — generous enough for legitimate use,
    // tight enough to prevent automated enumeration.
    slowdns_rate_limit('issue_code', 10, 3600);
    slowdns_rate_limit_cleanup(3600);
    slowdns_cleanup_codes();

    $code    = slowdns_generate_install_code();
    $expires = time() + 300;

    db()->prepare(
        'INSERT INTO slowdns_install_codes (install_code, request_ip, user_agent, status, expires_at)
         VALUES (?, ?, ?, ?, ?)'
    )->execute([
        $code,
        client_ip(),
        substr((string) ($_SERVER['HTTP_USER_AGENT'] ?? ''), 0, 255),
        'issued',
        gmdate('Y-m-d H:i:s', $expires),
    ]);

    audit_log('slowdns_code_issue', $code, 'IP: ' . client_ip(), 'public');
    v2_out(201, [
        'install_code' => $code,
        'expires_at'   => gmdate('c', $expires),
        'ttl_seconds'  => 300,
    ], ['message' => 'SlowDNS install code issued']);
}

function v2_slowdns_activate_install(): never {
    // 5 activation attempts per IP per 24 hours.
    slowdns_rate_limit('activate', 5, 86400);
    slowdns_rate_limit_cleanup(86400);
    slowdns_cleanup_codes();

    $body = v2_read_json();

    $install_code      = slowdns_validate_install_code((string) ($body['install_code'] ?? $body['license_key'] ?? ''));
    $hostname          = strtolower(trim((string) ($body['hostname'] ?? '')));
    $public_ip         = trim((string) ($body['public_ip'] ?? ''));
    $machine_id        = trim((string) ($body['machine_id'] ?? ''));
    $ssh_fingerprint   = trim((string) ($body['ssh_fingerprint'] ?? ''));
    $requested_ref     = trim((string) ($body['requested_ref'] ?? 'main'));
    $installer_version = trim((string) ($body['installer_version'] ?? ''));

    if ($machine_id === '' || $ssh_fingerprint === '') {
        v2_error(422, 'validation_error', 'machine_id and ssh_fingerprint are required.');
    }

    $code = slowdns_find_code($install_code);
    if (!$code) {
        v2_error(404, 'install_code_not_found', 'Install code was not found.');
    }
    if (($code['status'] ?? 'issued') !== 'issued') {
        v2_error(403, 'install_code_used', 'Install code has already been consumed.');
    }
    if (!empty($code['expires_at']) && strtotime((string) $code['expires_at']) < time()) {
        db()->prepare("UPDATE slowdns_install_codes SET status = 'expired' WHERE id = ?")->execute([(int) $code['id']]);
        v2_error(403, 'install_code_expired', 'Install code has expired.');
    }

    // Block codes that have been cycled through too many activate/release loops.
    if ((int) ($code['activation_count'] ?? 0) >= SLOWDNS_MAX_ACTIVATIONS_PER_CODE) {
        v2_error(403, 'install_code_max_activations', 'This install code has reached the maximum number of activation attempts. Please generate a new code.');
    }

    $activation_id = 'act_' . bin2hex(random_bytes(8));
    $issued_at     = time();
    $expires_at    = $issued_at + SLOWDNS_TOKEN_TTL;

    $payload = [
        'iss' => slowdns_issuer(),
        'typ' => 'slowdns_install',
        'sub' => $activation_id,
        'code' => $install_code,
        'mid' => hash('sha256', $machine_id),
        'ssh' => hash('sha256', $ssh_fingerprint),
        'ip'  => $public_ip,
        'hst' => $hostname,
        'ref' => $requested_ref,
        'ver' => $installer_version,
        'iat' => $issued_at,
        'exp' => $expires_at,
        'jti' => bin2hex(random_bytes(8)),
    ];
    $token = slowdns_token_sign($payload);

    // Mark code consumed and increment the activation counter atomically.
    db()->prepare(
        "UPDATE slowdns_install_codes
         SET status = 'consumed', consumed_at = UTC_TIMESTAMP(), activation_count = activation_count + 1
         WHERE id = ?"
    )->execute([(int) $code['id']]);

    db()->prepare(
        'INSERT INTO slowdns_install_activations
         (activation_id, install_code_id, machine_id, ssh_fingerprint, public_ip, hostname,
          install_token, install_token_expires_at, created_at, last_seen_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, UTC_TIMESTAMP(), UTC_TIMESTAMP())'
    )->execute([
        $activation_id,
        (int) $code['id'],
        $machine_id,
        $ssh_fingerprint,
        $public_ip,
        $hostname,
        $token,
        gmdate('Y-m-d H:i:s', $expires_at),
    ]);

    audit_log(
        'slowdns_install_activate',
        $activation_id,
        'Code: ' . $install_code . ', Host: ' . ($hostname ?: 'n/a') . ', IP: ' . client_ip(),
        'public'
    );

    v2_out(200, [
        'activation_id'            => $activation_id,
        'install_token'            => $token,
        'install_token_expires_at' => gmdate('c', $expires_at),
        'install_code'             => $install_code,
        'machine_binding'          => [
            'hostname'        => $hostname,
            'public_ip'       => $public_ip,
            'machine_id'      => $machine_id,
            'ssh_fingerprint' => $ssh_fingerprint,
        ],
    ], ['message' => 'Install token issued']);
}

function v2_slowdns_confirm_install(): never {
    slowdns_schema_ensure();
    $body = v2_read_json();
    $activation_id = trim((string) ($body['activation_id'] ?? ''));
    $install_token = trim((string) ($body['install_token'] ?? ''));

    if ($activation_id === '' || $install_token === '') {
        v2_error(422, 'validation_error', 'activation_id and install_token are required.');
    }

    try {
        $payload = slowdns_token_verify($install_token);
    } catch (Throwable $e) {
        v2_error(403, 'token_invalid', $e->getMessage());
    }

    if (($payload['sub'] ?? '') !== $activation_id) {
        v2_error(403, 'token_mismatch', 'Install token does not match activation.');
    }

    $row = slowdns_find_activation($activation_id);
    if (!$row || !empty($row['released_at'])) {
        v2_error(404, 'activation_not_found', 'Activation was not found.');
    }
    if (($row['install_token'] ?? '') !== $install_token) {
        v2_error(403, 'token_mismatch', 'Install token is not valid for this activation.');
    }
    if (!empty($row['install_token_used_at'])) {
        v2_error(409, 'token_used', 'Install token has already been used.');
    }

    db()->prepare(
        'UPDATE slowdns_install_activations
         SET install_token_used_at = UTC_TIMESTAMP(), last_seen_at = UTC_TIMESTAMP()
         WHERE activation_id = ?'
    )->execute([$activation_id]);

    audit_log(
        'slowdns_install_confirm',
        $activation_id,
        'Host: ' . ($row['hostname'] ?? 'n/a') . ', IP: ' . client_ip(),
        'public'
    );
    v2_out(200, [
        'activation_id' => $activation_id,
        'status' => 'confirmed',
    ], ['message' => 'Install confirmed']);
}

function v2_slowdns_release_install(): never {
    slowdns_schema_ensure();
    $body = v2_read_json();
    $activation_id = trim((string) ($body['activation_id'] ?? ''));

    if ($activation_id === '') {
        v2_error(422, 'validation_error', 'activation_id is required.');
    }

    $row = slowdns_find_activation($activation_id);
    if (!$row || !empty($row['released_at'])) {
        v2_error(404, 'activation_not_found', 'Activation was not found.');
    }

    $code_id = (int) ($row['install_code_id'] ?? 0);
    $can_restore_code = empty($row['install_token_used_at']) && !empty($row['install_token_expires_at'])
        && strtotime((string) $row['install_token_expires_at']) >= time();

    db()->prepare(
        'UPDATE slowdns_install_activations
         SET released_at = UTC_TIMESTAMP(), last_seen_at = UTC_TIMESTAMP()
         WHERE activation_id = ?'
    )->execute([$activation_id]);

    if ($can_restore_code && $code_id > 0) {
        db()->prepare(
            "UPDATE slowdns_install_codes
             SET status = 'issued', consumed_at = NULL
             WHERE id = ?"
        )->execute([$code_id]);
    }

    audit_log(
        'slowdns_install_release',
        $activation_id,
        'Code restored: ' . ($can_restore_code ? 'yes' : 'no') . ', IP: ' . client_ip(),
        'public'
    );
    v2_out(200, [
        'activation_id' => $activation_id,
        'status' => 'released',
        'install_code_restored' => $can_restore_code,
    ], ['message' => 'Activation released']);
}
