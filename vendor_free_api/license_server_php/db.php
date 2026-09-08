<?php
// ---------------------------------------------------------------
// IPTunnel License Server — Database Layer (v2 — Multi-Client)
// ---------------------------------------------------------------
require_once __DIR__ . '/config.php';

function db(): PDO {
    static $pdo = null;
    if ($pdo === null) {
        $dsn = sprintf('mysql:host=%s;port=%d;dbname=%s;charset=utf8mb4',
            DB_HOST, DB_PORT, DB_NAME);
        $pdo = new PDO($dsn, DB_USER, DB_PASS, [
            PDO::ATTR_ERRMODE            => PDO::ERRMODE_EXCEPTION,
            PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
            PDO::ATTR_EMULATE_PREPARES   => false,
        ]);
        db_runtime_patch($pdo);
    }
    return $pdo;
}

function db_runtime_patch(PDO $pdo): void {
    static $patched = false;
    if ($patched) {
        return;
    }
    $patched = true;

    if (!db_column_exists($pdo, 'clients', 'token_hash')) {
        $pdo->exec("ALTER TABLE clients ADD COLUMN token_hash VARCHAR(64) NOT NULL DEFAULT '' AFTER token");
    }
    if (!db_column_exists($pdo, 'clients', 'token_prefix')) {
        $pdo->exec("ALTER TABLE clients ADD COLUMN token_prefix VARCHAR(16) NOT NULL DEFAULT '' AFTER token_hash");
    }
    if (!db_column_exists($pdo, 'clients', 'token_last4')) {
        $pdo->exec("ALTER TABLE clients ADD COLUMN token_last4 VARCHAR(4) NOT NULL DEFAULT '' AFTER token_prefix");
    }
    db_column_resize_if_needed($pdo, 'clients', 'token', 255);

    if (!db_column_exists($pdo, 'servers', 'token_hash')) {
        $pdo->exec("ALTER TABLE servers ADD COLUMN token_hash VARCHAR(64) NOT NULL DEFAULT '' AFTER token");
    }
    if (!db_index_exists($pdo, 'servers', 'idx_token_hash')) {
        $pdo->exec("ALTER TABLE servers ADD INDEX idx_token_hash (token_hash)");
    }
    if (!db_column_exists($pdo, 'servers', 'health_status')) {
        $pdo->exec("ALTER TABLE servers ADD COLUMN health_status VARCHAR(16) NOT NULL DEFAULT 'unknown' AFTER last_checkin");
    }
    if (!db_column_exists($pdo, 'servers', 'health_checked_at')) {
        $pdo->exec("ALTER TABLE servers ADD COLUMN health_checked_at DATETIME NULL DEFAULT NULL AFTER health_status");
    }
    if (!db_column_exists($pdo, 'servers', 'health_error')) {
        $pdo->exec("ALTER TABLE servers ADD COLUMN health_error VARCHAR(255) NOT NULL DEFAULT '' AFTER health_checked_at");
    }
    if (!db_column_exists($pdo, 'servers', 'health_endpoint')) {
        $pdo->exec("ALTER TABLE servers ADD COLUMN health_endpoint VARCHAR(255) NOT NULL DEFAULT '' AFTER health_error");
    }
    if (!db_index_exists($pdo, 'servers', 'idx_health_checked_at')) {
        $pdo->exec("ALTER TABLE servers ADD INDEX idx_health_checked_at (health_checked_at)");
    }

    migrate_master_token_storage($pdo);
    migrate_client_token_storage($pdo);
    migrate_server_token_storage($pdo);
    migrate_webhook_secret_storage($pdo);

    if (!db_index_exists($pdo, 'clients', 'uq_clients_token_hash')) {
        if (db_client_token_hashes_are_ready_for_unique_index($pdo)) {
            $pdo->exec("ALTER TABLE clients ADD UNIQUE KEY uq_clients_token_hash (token_hash)");
        } elseif (!db_index_exists($pdo, 'clients', 'idx_clients_token_hash')) {
            $pdo->exec("ALTER TABLE clients ADD INDEX idx_clients_token_hash (token_hash)");
            error_log('Client token hash unique index skipped because existing data still contains blank or duplicate hashes.');
        }
    }
}

function db_column_exists(PDO $pdo, string $table, string $column): bool {
    $stmt = $pdo->prepare(
        'SELECT COUNT(*)
           FROM INFORMATION_SCHEMA.COLUMNS
          WHERE TABLE_SCHEMA = DATABASE()
            AND TABLE_NAME = ?
            AND COLUMN_NAME = ?'
    );
    $stmt->execute([$table, $column]);
    return (int) $stmt->fetchColumn() > 0;
}

function db_index_exists(PDO $pdo, string $table, string $index): bool {
    $stmt = $pdo->prepare(
        'SELECT COUNT(*)
           FROM INFORMATION_SCHEMA.STATISTICS
          WHERE TABLE_SCHEMA = DATABASE()
            AND TABLE_NAME = ?
            AND INDEX_NAME = ?'
    );
    $stmt->execute([$table, $index]);
    return (int) $stmt->fetchColumn() > 0;
}

function db_table_exists(PDO $pdo, string $table): bool {
    $stmt = $pdo->prepare(
        'SELECT COUNT(*)
           FROM INFORMATION_SCHEMA.TABLES
          WHERE TABLE_SCHEMA = DATABASE()
            AND TABLE_NAME = ?'
    );
    $stmt->execute([$table]);
    return (int) $stmt->fetchColumn() > 0;
}

function db_client_token_hashes_are_ready_for_unique_index(PDO $pdo): bool {
    if (!db_table_exists($pdo, 'clients')) {
        return false;
    }

    $stmt = $pdo->query(
        "SELECT token_hash, COUNT(*) AS c
           FROM clients
          GROUP BY token_hash
         HAVING token_hash = '' OR token_hash IS NULL OR COUNT(*) > 1
          LIMIT 1"
    );
    return $stmt->fetch() === false;
}

function db_column_resize_if_needed(PDO $pdo, string $table, string $column, int $min_length): void {
    $stmt = $pdo->prepare(
        'SELECT CHARACTER_MAXIMUM_LENGTH
           FROM INFORMATION_SCHEMA.COLUMNS
          WHERE TABLE_SCHEMA = DATABASE()
            AND TABLE_NAME = ?
            AND COLUMN_NAME = ?'
    );
    $stmt->execute([$table, $column]);
    $length = (int) ($stmt->fetchColumn() ?: 0);
    if ($length > 0 && $length < $min_length) {
        $pdo->exec(sprintf(
            'ALTER TABLE `%s` MODIFY COLUMN `%s` VARCHAR(%d) NOT NULL DEFAULT \'\'',
            str_replace('`', '``', $table),
            str_replace('`', '``', $column),
            $min_length
        ));
    }
}

function normalize_secret_key_material(string $material): string {
    $decoded = base64_decode($material, true);
    if ($decoded === false || strlen($decoded) < 16) {
        $decoded = $material;
    }
    return hash('sha256', $decoded, true);
}

function candidate_secret_key_paths(string $path, string $filename): array {
    $paths = [];
    $path = trim($path);
    if ($path !== '') {
        $paths[] = $path;
    }

    $tmpBase = rtrim((string) sys_get_temp_dir(), DIRECTORY_SEPARATOR);
    if ($tmpBase !== '') {
        $paths[] = $tmpBase . DIRECTORY_SEPARATOR . 'iptunnel-license-server' . DIRECTORY_SEPARATOR . $filename;
    }

    return array_values(array_unique(array_filter($paths)));
}

function load_or_create_file_backed_secret_key(string $settingName, string $path): string {
    $paths = candidate_secret_key_paths($path, basename($path !== '' ? $path : strtolower($settingName) . '.key'));
    if ($paths === []) {
        throw new RuntimeException(sprintf(
            '%s is not configured. Set %s or %s_FILE before continuing.',
            $settingName,
            $settingName,
            $settingName
        ));
    }

    $lastError = '';
    $preferred = $paths[0];
    foreach ($paths as $candidate) {
        try {
            $dir = dirname($candidate);
            if (!is_dir($dir) && !@mkdir($dir, 0700, true) && !is_dir($dir)) {
                throw new RuntimeException(sprintf(
                    'Unable to create key directory %s. Set %s explicitly or make %s writable.',
                    $dir,
                    $settingName,
                    $dir
                ));
            }

            if (!is_file($candidate) || filesize($candidate) === 0) {
                $material = base64_encode(random_bytes(32));
                if (@file_put_contents($candidate, $material, LOCK_EX) === false) {
                    throw new RuntimeException(sprintf(
                        'Unable to write %s_FILE at %s. Set %s explicitly or make the path writable.',
                        $settingName,
                        $candidate,
                        $settingName
                    ));
                }
                @chmod($candidate, 0600);
            }

            $material = trim((string) @file_get_contents($candidate));
            if ($material === '') {
                throw new RuntimeException(sprintf('%s_FILE is empty: %s', $settingName, $candidate));
            }

            if ($candidate !== $preferred) {
                error_log(sprintf('%s_FILE fallback activated at %s', $settingName, $candidate));
            }

            return normalize_secret_key_material($material);
        } catch (Throwable $e) {
            $lastError = $e->getMessage();
        }
    }

    throw new RuntimeException($lastError !== '' ? $lastError : sprintf(
        'Unable to load or create %s_FILE. Configure %s explicitly before continuing.',
        $settingName,
        $settingName
    ));
}

function unique_secret_keys(array $keys): array {
    $unique = [];
    $seen = [];
    foreach ($keys as $key) {
        if (!is_string($key) || $key === '') {
            continue;
        }
        $id = bin2hex($key);
        if (isset($seen[$id])) {
            continue;
        }
        $seen[$id] = true;
        $unique[] = $key;
    }
    return $unique;
}

function decrypt_ciphertext_with_keys(
    string $ciphertext,
    array $keys,
    string $invalidMessage,
    string $decryptMessage
): array {
    if ($ciphertext === '' || !str_starts_with($ciphertext, 'enc:')) {
        return ['plain' => $ciphertext, 'legacy' => false];
    }

    $decoded = base64_decode(substr($ciphertext, 4), true);
    if ($decoded === false || strlen($decoded) < 17) {
        throw new RuntimeException($invalidMessage);
    }

    $iv = substr($decoded, 0, 16);
    $payload = substr($decoded, 16);
    foreach (unique_secret_keys($keys) as $index => $key) {
        $plain = openssl_decrypt($payload, 'aes-256-cbc', $key, OPENSSL_RAW_DATA, $iv);
        if ($plain !== false) {
            return ['plain' => $plain, 'legacy' => $index > 0];
        }
    }

    throw new RuntimeException($decryptMessage);
}

function token_secret_key(): string {
    static $key = null;
    if ($key !== null) {
        return $key;
    }

    $configured = defined('TOKEN_SECRET_KEY') ? trim((string) TOKEN_SECRET_KEY) : '';
    if ($configured !== '') {
        $key = hash('sha256', $configured, true);
        return $key;
    }

    $path = defined('TOKEN_SECRET_KEY_FILE') && trim((string) TOKEN_SECRET_KEY_FILE) !== ''
        ? trim((string) TOKEN_SECRET_KEY_FILE)
        : dirname(__DIR__) . DIRECTORY_SEPARATOR . '.license_server_keys' . DIRECTORY_SEPARATOR . 'tokens.key';
    $key = load_or_create_file_backed_secret_key('TOKEN_SECRET_KEY', $path);
    return $key;
}

function token_legacy_secret_keys(): array {
    $legacyConfigured = defined('WEBHOOK_SECRET_KEY') ? trim((string) WEBHOOK_SECRET_KEY) : '';
    if ($legacyConfigured === '') {
        return [];
    }
    return [hash('sha256', 'token:' . $legacyConfigured, true)];
}

function token_lookup_hash(string $token): string {
    return hash_hmac('sha256', $token, token_secret_key());
}

function encrypt_sensitive_token(string $token): string {
    if ($token === '' || $token === 'manual') {
        return $token;
    }
    if (str_starts_with($token, 'enc:')) {
        return $token;
    }

    $iv = random_bytes(16);
    $ciphertext = openssl_encrypt($token, 'aes-256-cbc', token_secret_key(), OPENSSL_RAW_DATA, $iv);
    if ($ciphertext === false) {
        throw new RuntimeException('Unable to encrypt token material.');
    }

    return 'enc:' . base64_encode($iv . $ciphertext);
}

function decrypt_sensitive_token(string $stored): string {
    return decrypt_sensitive_token_state($stored)['plain'];
}

function decrypt_sensitive_token_state(string $stored): array {
    if ($stored === '' || $stored === 'manual') {
        return ['plain' => $stored, 'legacy' => false];
    }

    return decrypt_ciphertext_with_keys(
        $stored,
        array_merge([token_secret_key()], token_legacy_secret_keys()),
        'Stored token ciphertext is invalid.',
        'Unable to decrypt stored token.'
    );
}

function token_prefix_value(string $token): string {
    if ($token === '') {
        return '';
    }
    if ($token === 'manual') {
        return 'manual';
    }
    return substr($token, 0, 8);
}

function token_last4_value(string $token): string {
    if ($token === '' || $token === 'manual') {
        return '';
    }
    return substr($token, -4);
}

function token_hint(string $token): string {
    if ($token === '' || $token === 'manual') {
        return $token;
    }
    $prefix = token_prefix_value($token);
    $last4 = token_last4_value($token);
    return $last4 !== '' ? $prefix . '...' . $last4 : $prefix . '...';
}

function token_preview_from_row(array $row): ?string {
    $prefix = trim((string) ($row['token_prefix'] ?? ''));
    $last4 = trim((string) ($row['token_last4'] ?? ''));
    if ($prefix === '' && $last4 === '') {
        try {
            $plain = decrypt_sensitive_token((string) ($row['token'] ?? ''));
        } catch (Throwable) {
            return null;
        }
        return $plain === '' ? null : token_hint($plain);
    }
    if ($prefix === 'manual') {
        return 'manual';
    }
    return $last4 !== '' ? $prefix . '...' . $last4 : $prefix . '...';
}

function client_token_storage_values(string $token): array {
    return [
        'stored' => encrypt_sensitive_token($token),
        'hash' => $token === '' ? '' : token_lookup_hash($token),
        'prefix' => token_prefix_value($token),
        'last4' => token_last4_value($token),
    ];
}

function server_token_storage_values(string $token): array {
    if ($token === '' || $token === 'manual') {
        return ['stored' => $token, 'hash' => ''];
    }
    return [
        'stored' => encrypt_sensitive_token($token),
        'hash' => token_lookup_hash($token),
    ];
}

function hydrate_client_row(array $row): array {
    if (array_key_exists('token', $row)) {
        try {
            $row['token'] = decrypt_sensitive_token((string) $row['token']);
        } catch (Throwable) {
            $row['token'] = '';
        }
    }
    $row['token_preview'] = token_preview_from_row($row);
    return $row;
}

function hydrate_client_rows(array $rows): array {
    foreach ($rows as $idx => $row) {
        $rows[$idx] = hydrate_client_row($row);
    }
    return $rows;
}

function store_master_token(string $token): void {
    set_setting('master_token', encrypt_sensitive_token($token));
    set_setting('master_token_hash', token_lookup_hash($token));
    set_setting('master_token_hint', token_hint($token));
}

function migrate_master_token_storage(PDO $pdo): void {
    $stmt = $pdo->prepare(
        "SELECT setting_key, setting_value
           FROM settings
          WHERE setting_key IN ('master_token', 'master_token_hash', 'master_token_hint')"
    );
    $stmt->execute();
    $settings = [];
    foreach ($stmt->fetchAll() as $row) {
        $settings[(string) $row['setting_key']] = (string) $row['setting_value'];
    }

    $stored = $settings['master_token'] ?? '';
    if ($stored === '') {
        return;
    }

    $plain = decrypt_sensitive_token($stored);
    if ($plain === '') {
        return;
    }

    $hash = token_lookup_hash($plain);
    $hint = token_hint($plain);
    $expectedStored = encrypt_sensitive_token($plain);

    if (($settings['master_token_hash'] ?? '') === $hash
        && ($settings['master_token_hint'] ?? '') === $hint
        && $stored === $expectedStored) {
        return;
    }

    $update = $pdo->prepare(
        'INSERT INTO settings (setting_key, setting_value)
         VALUES (?, ?)
         ON DUPLICATE KEY UPDATE setting_value = VALUES(setting_value)'
    );
    $update->execute(['master_token', $expectedStored]);
    $update->execute(['master_token_hash', $hash]);
    $update->execute(['master_token_hint', $hint]);
}

function migrate_client_token_storage(PDO $pdo): void {
    $rows = $pdo->query('SELECT id, token, token_hash, token_prefix, token_last4 FROM clients')->fetchAll();
    $update = $pdo->prepare(
        'UPDATE clients
            SET token = ?, token_hash = ?, token_prefix = ?, token_last4 = ?
          WHERE id = ?'
    );

    foreach ($rows as $row) {
        $plain = decrypt_sensitive_token((string) ($row['token'] ?? ''));
        if ($plain === '') {
            continue;
        }

        $values = client_token_storage_values($plain);
        $needsUpdate =
            (string) ($row['token'] ?? '') !== $values['stored']
            || (string) ($row['token_hash'] ?? '') !== $values['hash']
            || (string) ($row['token_prefix'] ?? '') !== $values['prefix']
            || (string) ($row['token_last4'] ?? '') !== $values['last4'];

        if ($needsUpdate) {
            $update->execute([
                $values['stored'],
                $values['hash'],
                $values['prefix'],
                $values['last4'],
                (int) $row['id'],
            ]);
        }
    }
}

function migrate_server_token_storage(PDO $pdo): void {
    $rows = $pdo->query('SELECT server_id, token, token_hash FROM servers')->fetchAll();
    $update = $pdo->prepare(
        'UPDATE servers SET token = ?, token_hash = ? WHERE server_id = ?'
    );

    foreach ($rows as $row) {
        $plain = decrypt_sensitive_token((string) ($row['token'] ?? ''));
        if ($plain === '') {
            continue;
        }

        $values = server_token_storage_values($plain);
        $needsUpdate =
            (string) ($row['token'] ?? '') !== $values['stored']
            || (string) ($row['token_hash'] ?? '') !== $values['hash'];

        if ($needsUpdate) {
            $update->execute([
                $values['stored'],
                $values['hash'],
                (string) $row['server_id'],
            ]);
        }
    }
}

function webhook_secret_key(): string {
    static $key = null;
    if ($key !== null) {
        return $key;
    }

    $configured = defined('WEBHOOK_SECRET_KEY') ? trim((string) WEBHOOK_SECRET_KEY) : '';
    if ($configured !== '') {
        $key = hash('sha256', $configured, true);
        return $key;
    }

    $path = defined('WEBHOOK_SECRET_KEY_FILE') && trim((string) WEBHOOK_SECRET_KEY_FILE) !== ''
        ? trim((string) WEBHOOK_SECRET_KEY_FILE)
        : dirname(__DIR__) . DIRECTORY_SEPARATOR . '.license_server_keys' . DIRECTORY_SEPARATOR . 'webhooks.key';
    $key = load_or_create_file_backed_secret_key('WEBHOOK_SECRET_KEY', $path);
    return $key;
}

function webhook_legacy_secret_keys(): array {
    $legacy = implode('|', [DB_HOST, DB_NAME, DB_USER, DB_PASS]);
    return [hash('sha256', $legacy, true)];
}

function encrypt_webhook_secret(string $secret): string {
    if ($secret === '') {
        return '';
    }
    if (str_starts_with($secret, 'enc:')) {
        return $secret;
    }
    $iv = random_bytes(16);
    $ciphertext = openssl_encrypt($secret, 'aes-256-cbc', webhook_secret_key(), OPENSSL_RAW_DATA, $iv);
    if ($ciphertext === false) {
        throw new RuntimeException('Unable to encrypt webhook secret.');
    }
    return 'enc:' . base64_encode($iv . $ciphertext);
}

function decrypt_webhook_secret(string $ciphertext): string {
    return decrypt_webhook_secret_state($ciphertext)['plain'];
}

function decrypt_webhook_secret_state(string $ciphertext): array {
    return decrypt_ciphertext_with_keys(
        $ciphertext,
        array_merge([webhook_secret_key()], webhook_legacy_secret_keys()),
        'Webhook secret is not valid ciphertext.',
        'Unable to decrypt webhook secret.'
    );
}

function normalize_webhook_secret_storage(int $id, string $secret): string {
    if ($secret === '') {
        return $secret;
    }
    if (str_starts_with($secret, 'enc:')) {
        $state = decrypt_webhook_secret_state($secret);
        if (!$state['legacy']) {
            return $secret;
        }
        $encrypted = encrypt_webhook_secret($state['plain']);
        db()->prepare('UPDATE webhooks SET secret = ? WHERE id = ?')->execute([$encrypted, $id]);
        return $encrypted;
    }
    $encrypted = encrypt_webhook_secret($secret);
    db()->prepare('UPDATE webhooks SET secret = ? WHERE id = ?')->execute([$encrypted, $id]);
    return $encrypted;
}

function migrate_webhook_secret_storage(PDO $pdo): void {
    if (!db_table_exists($pdo, 'webhooks')) {
        return;
    }
    $rows = $pdo->query('SELECT id, secret FROM webhooks WHERE secret <> ""')->fetchAll();
    foreach ($rows as $row) {
        try {
            normalize_webhook_secret_storage((int) $row['id'], (string) ($row['secret'] ?? ''));
        } catch (Throwable $e) {
            error_log(sprintf('Webhook #%d secret migration skipped: %s', (int) $row['id'], $e->getMessage()));
        }
    }
}

function is_public_routable_ip(string $ip): bool {
    return (bool) filter_var(
        $ip,
        FILTER_VALIDATE_IP,
        FILTER_FLAG_NO_PRIV_RANGE | FILTER_FLAG_NO_RES_RANGE
    );
}

// ── Settings ────────────────────────────────────────────────────

function get_setting(string $key, string $default = ''): string {
    $stmt = db()->prepare('SELECT setting_value FROM settings WHERE setting_key = ?');
    $stmt->execute([$key]);
    $row = $stmt->fetch();
    return $row ? $row['setting_value'] : $default;
}

function set_setting(string $key, string $value): void {
    $stmt = db()->prepare(
        'INSERT INTO settings (setting_key, setting_value) VALUES (?, ?)
         ON DUPLICATE KEY UPDATE setting_value = VALUES(setting_value)'
    );
    $stmt->execute([$key, $value]);
}

function get_master_token(): string {
    return decrypt_sensitive_token(get_setting('master_token', ''));
}

function get_master_token_hint(): string {
    return get_setting('master_token_hint', '');
}

function is_master_token_valid(string $token): bool {
    if ($token === '') {
        return false;
    }

    $hash = get_setting('master_token_hash', '');
    if ($hash !== '') {
        return hash_equals($hash, token_lookup_hash($token));
    }

    $master = get_master_token();
    return $master !== '' && hash_equals($master, $token);
}

function is_setup_complete(): bool {
    return get_setting('setup_complete') === '1';
}

// ── Admin Users ─────────────────────────────────────────────────

function get_admin(string $username): ?array {
    $stmt = db()->prepare('SELECT * FROM admin_users WHERE username = ?');
    $stmt->execute([$username]);
    return $stmt->fetch() ?: null;
}

function create_admin(string $username, string $password): void {
    $hash = password_hash($password, PASSWORD_BCRYPT, ['cost' => 12]);
    $role = admin_count() === 0 ? 'superadmin' : 'admin';
    db()->prepare('INSERT INTO admin_users (username, password, role) VALUES (?, ?, ?)')
        ->execute([$username, $hash, $role]);
}

function update_admin_password(int $id, string $password): void {
    $hash = password_hash($password, PASSWORD_BCRYPT, ['cost' => 12]);
    db()->prepare('UPDATE admin_users SET password = ? WHERE id = ?')
        ->execute([$hash, $id]);
}

function update_admin_login(int $id): void {
    db()->prepare('UPDATE admin_users SET last_login = NOW() WHERE id = ?')
        ->execute([$id]);
}

function admin_count(): int {
    return (int) db()->query('SELECT COUNT(*) FROM admin_users')->fetchColumn();
}

// ── Clients ─────────────────────────────────────────────────────

function create_client(string $name, string $email, string $username, string $password, int $max_servers = 0, string $note = ''): array {
    $hash = password_hash($password, PASSWORD_BCRYPT, ['cost' => 12]);
    $token = bin2hex(random_bytes(24));  // 48-char hex token
    $tokenValues = client_token_storage_values($token);
    db()->prepare(
        'INSERT INTO clients (name, email, username, password, token, token_hash, token_prefix, token_last4, max_servers, note)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)'
    )->execute([
        $name,
        $email,
        $username,
        $hash,
        $tokenValues['stored'],
        $tokenValues['hash'],
        $tokenValues['prefix'],
        $tokenValues['last4'],
        $max_servers,
        $note,
    ]);
    $id = (int) db()->lastInsertId();
    return ['id' => $id, 'token' => $token];
}

function get_client(string $username): ?array {
    $stmt = db()->prepare('SELECT * FROM clients WHERE username = ?');
    $stmt->execute([$username]);
    $row = $stmt->fetch() ?: null;
    return $row ? hydrate_client_row($row) : null;
}

function get_client_by_id(int $id): ?array {
    $stmt = db()->prepare('SELECT * FROM clients WHERE id = ?');
    $stmt->execute([$id]);
    $row = $stmt->fetch() ?: null;
    return $row ? hydrate_client_row($row) : null;
}

function get_client_by_token(string $token): ?array {
    $stmt = db()->prepare('SELECT * FROM clients WHERE token_hash = ? AND is_active = 1');
    $stmt->execute([token_lookup_hash($token)]);
    $row = $stmt->fetch() ?: null;
    return $row ? hydrate_client_row($row) : null;
}

function get_clients(string $filter = 'all', string $search = '', int $page = 1, int $per_page = 20): array {
    $where = [];
    $params = [];

    if ($filter === 'active')   { $where[] = 'c.is_active = 1'; }
    if ($filter === 'inactive') { $where[] = 'c.is_active = 0'; }

    if ($search) {
        $where[] = '(c.name LIKE ? OR c.email LIKE ? OR c.username LIKE ? OR c.token_prefix LIKE ? OR c.token_last4 LIKE ?)';
        $like = "%$search%";
        array_push($params, $like, $like, $like, $like, $like);
    }

    $clause = $where ? 'WHERE ' . implode(' AND ', $where) : '';
    $offset = ($page - 1) * $per_page;
    $params[] = $per_page;
    $params[] = $offset;

    $stmt = db()->prepare(
        "SELECT c.*,
                (SELECT COUNT(*) FROM servers s WHERE s.client_id = c.id) AS server_count,
                (SELECT COUNT(*) FROM servers s WHERE s.client_id = c.id AND s.revoked = 0) AS active_servers
         FROM clients c $clause
         ORDER BY c.created_at DESC LIMIT ? OFFSET ?"
    );
    $stmt->execute($params);
    return hydrate_client_rows($stmt->fetchAll());
}

function count_clients(string $filter = 'all', string $search = ''): int {
    $where = [];
    $params = [];
    if ($filter === 'active')   { $where[] = 'is_active = 1'; }
    if ($filter === 'inactive') { $where[] = 'is_active = 0'; }
    if ($search) {
        $where[] = '(name LIKE ? OR email LIKE ? OR username LIKE ? OR token_prefix LIKE ? OR token_last4 LIKE ?)';
        $like = "%$search%";
        array_push($params, $like, $like, $like, $like, $like);
    }
    $clause = $where ? 'WHERE ' . implode(' AND ', $where) : '';
    $stmt = db()->prepare("SELECT COUNT(*) FROM clients $clause");
    $stmt->execute($params);
    return (int) $stmt->fetchColumn();
}

function client_export_cursor(string $filter = 'all', string $search = ''): PDOStatement {
    $where = [];
    $params = [];

    if ($filter === 'active')   { $where[] = 'c.is_active = 1'; }
    if ($filter === 'inactive') { $where[] = 'c.is_active = 0'; }

    if ($search) {
        $where[] = '(c.name LIKE ? OR c.email LIKE ? OR c.username LIKE ? OR c.token_prefix LIKE ? OR c.token_last4 LIKE ?)';
        $like = "%$search%";
        array_push($params, $like, $like, $like, $like, $like);
    }

    $clause = $where ? 'WHERE ' . implode(' AND ', $where) : '';
    $stmt = db()->prepare(
        "SELECT c.*,
                (SELECT COUNT(*) FROM servers s WHERE s.client_id = c.id) AS server_count,
                (SELECT COUNT(*) FROM servers s WHERE s.client_id = c.id AND s.revoked = 0) AS active_servers
         FROM clients c $clause
         ORDER BY c.created_at DESC"
    );
    $stmt->execute($params);
    return $stmt;
}

function client_stats(): array {
    $total    = (int) db()->query('SELECT COUNT(*) FROM clients')->fetchColumn();
    $active   = (int) db()->query('SELECT COUNT(*) FROM clients WHERE is_active = 1')->fetchColumn();
    $inactive = (int) db()->query('SELECT COUNT(*) FROM clients WHERE is_active = 0')->fetchColumn();
    return compact('total', 'active', 'inactive');
}

function update_client(int $id, string $name, string $email, int $max_servers, string $note): void {
    db()->prepare('UPDATE clients SET name = ?, email = ?, max_servers = ?, note = ? WHERE id = ?')
        ->execute([$name, $email, $max_servers, $note, $id]);
}

function update_client_password(int $id, string $password): void {
    $hash = password_hash($password, PASSWORD_BCRYPT, ['cost' => 12]);
    db()->prepare('UPDATE clients SET password = ? WHERE id = ?')
        ->execute([$hash, $id]);
}

function update_client_login(int $id): void {
    db()->prepare('UPDATE clients SET last_login = NOW() WHERE id = ?')
        ->execute([$id]);
}

function toggle_client(int $id, bool $active): void {
    db()->prepare('UPDATE clients SET is_active = ? WHERE id = ?')
        ->execute([$active ? 1 : 0, $id]);
}

function regenerate_client_token(int $id): string {
    $token = bin2hex(random_bytes(24));
    $values = client_token_storage_values($token);
    db()->prepare('UPDATE clients SET token = ?, token_hash = ?, token_prefix = ?, token_last4 = ? WHERE id = ?')
        ->execute([$values['stored'], $values['hash'], $values['prefix'], $values['last4'], $id]);
    return $token;
}

function delete_client(int $id): void {
    // Servers get client_id set to NULL via FK ON DELETE SET NULL
    db()->prepare('DELETE FROM clients WHERE id = ?')->execute([$id]);
}

function client_server_count(int $client_id): int {
    $stmt = db()->prepare('SELECT COUNT(*) FROM servers WHERE client_id = ? AND revoked = 0');
    $stmt->execute([$client_id]);
    return (int) $stmt->fetchColumn();
}

// ── Authorized IPs ──────────────────────────────────────────────

function get_authorized_ip(string $ip): ?array {
    // Returns auth info; client_id may be NULL for admin-owned IPs (treated as always active)
    $stmt = db()->prepare(
        'SELECT a.*, c.token AS client_token, c.name AS client_name,
                COALESCE(c.is_active, 1) AS client_active,
                COALESCE(c.max_servers, 0) AS max_servers,
                c.id AS resolved_client_id
         FROM authorized_ips a
         LEFT JOIN clients c ON a.client_id = c.id
         WHERE a.ip = ?
         LIMIT 1'
    );
    $stmt->execute([$ip]);
    return $stmt->fetch() ?: null;
}

function add_authorized_ip(?int $client_id, string $ip, string $label = ''): void {
    if (!is_public_routable_ip($ip)) {
        throw new InvalidArgumentException('IP must be a public routable address.');
    }
    // MySQL UNIQUE KEY doesn't catch NULL duplicates, so guard manually for admin IPs
    if ($client_id === null) {
        $chk = db()->prepare('SELECT id FROM authorized_ips WHERE client_id IS NULL AND ip = ?');
        $chk->execute([$ip]);
        if ($chk->fetch()) return;
        db()->prepare('INSERT INTO authorized_ips (client_id, ip, label) VALUES (NULL, ?, ?)')
            ->execute([$ip, $label]);
    } else {
        db()->prepare('INSERT IGNORE INTO authorized_ips (client_id, ip, label) VALUES (?, ?, ?)')
            ->execute([$client_id, $ip, $label]);
    }
}

function delete_authorized_ip(int $id): void {
    db()->prepare('DELETE FROM authorized_ips WHERE id = ?')->execute([$id]);
}

function list_authorized_ips(?int $client_id = null): array {
    if ($client_id !== null) {
        $stmt = db()->prepare('SELECT * FROM authorized_ips WHERE client_id = ? ORDER BY created_at DESC');
        $stmt->execute([$client_id]);
    } else {
        $stmt = db()->query(
            'SELECT a.*, COALESCE(c.name, \'Admin\') AS client_name
             FROM authorized_ips a LEFT JOIN clients c ON a.client_id = c.id
             ORDER BY a.created_at DESC'
        );
    }
    return $stmt->fetchAll();
}

// ── Rate Limiting ───────────────────────────────────────────────

function client_ip(): string {
    // Trusted proxy IPs — only honor forwarded headers from these sources.
    // Add your reverse proxy / load balancer IPs here.
    static $trusted_proxies = ['127.0.0.1', '::1'];

    $remote = $_SERVER['REMOTE_ADDR'] ?? '0.0.0.0';

    // Only trust forwarded headers if the immediate peer is a known proxy.
    if (in_array($remote, $trusted_proxies, true)) {
        // X-Real-IP is SET (not appended) by our nginx to $remote_addr, so it
        // cannot be spoofed by the client — prefer it.
        if (!empty($_SERVER['HTTP_X_REAL_IP'])) {
            return trim($_SERVER['HTTP_X_REAL_IP']);
        }
        // X-Forwarded-For is "client, proxy1, proxy2, <us>". nginx APPENDS the
        // real peer to whatever the client sent, so only the LAST hop is
        // trustworthy — never the leftmost value (that is client-controlled).
        if (!empty($_SERVER['HTTP_X_FORWARDED_FOR'])) {
            $ips = array_map('trim', explode(',', $_SERVER['HTTP_X_FORWARDED_FOR']));
            return end($ips) ?: $remote;
        }
    }

    return $remote;
}

function is_rate_limited(): bool {
    $ip = client_ip();
    $stmt = db()->prepare('SELECT attempts, locked_until FROM login_attempts WHERE ip_address = ?');
    $stmt->execute([$ip]);
    $row = $stmt->fetch();
    if (!$row) return false;
    if ($row['locked_until'] && strtotime($row['locked_until']) > time()) return true;
    if ($row['attempts'] >= MAX_LOGIN_ATTEMPTS) {
        // Apply lockout
        db()->prepare('UPDATE login_attempts SET locked_until = DATE_ADD(NOW(), INTERVAL ? SECOND) WHERE ip_address = ?')
            ->execute([LOCKOUT_DURATION, $ip]);
        return true;
    }
    return false;
}

function record_login_attempt(bool $success): void {
    $ip = client_ip();
    if ($success) {
        db()->prepare('DELETE FROM login_attempts WHERE ip_address = ?')->execute([$ip]);
        return;
    }
    $stmt = db()->prepare(
        'INSERT INTO login_attempts (ip_address, attempts, last_attempt)
         VALUES (?, 1, NOW())
         ON DUPLICATE KEY UPDATE attempts = attempts + 1, last_attempt = NOW()'
    );
    $stmt->execute([$ip]);
}

function lockout_remaining(): int {
    $ip = client_ip();
    $stmt = db()->prepare('SELECT locked_until FROM login_attempts WHERE ip_address = ?');
    $stmt->execute([$ip]);
    $row = $stmt->fetch();
    if (!$row || !$row['locked_until']) return 0;
    return max(0, strtotime($row['locked_until']) - time());
}

// ── Audit Logging ───────────────────────────────────────────────

function audit_log(string $action, string $target = '', string $detail = '', string $user = ''): void {
    if (!$user) $user = $_SESSION['admin_user'] ?? $_SESSION['client_user'] ?? 'system';
    db()->prepare(
        'INSERT INTO audit_logs (admin_user, action, target, detail, ip_address) VALUES (?, ?, ?, ?, ?)'
    )->execute([$user, $action, $target, $detail, client_ip()]);
}

function get_audit_logs(int $page = 1, int $per_page = 25, string $action_filter = ''): array {
    $offset = ($page - 1) * $per_page;
    $where = '';
    $params = [];
    if ($action_filter) {
        $where = 'WHERE action = ?';
        $params[] = $action_filter;
    }
    $params[] = $per_page;
    $params[] = $offset;
    $stmt = db()->prepare("SELECT * FROM audit_logs $where ORDER BY created_at DESC LIMIT ? OFFSET ?");
    $stmt->execute($params);
    return $stmt->fetchAll();
}

function count_audit_logs(string $action_filter = ''): int {
    if ($action_filter) {
        $stmt = db()->prepare('SELECT COUNT(*) FROM audit_logs WHERE action = ?');
        $stmt->execute([$action_filter]);
    } else {
        $stmt = db()->query('SELECT COUNT(*) FROM audit_logs');
    }
    return (int) $stmt->fetchColumn();
}

// ── Servers ─────────────────────────────────────────────────────

function get_servers(string $filter = 'all', string $search = '', int $page = 1, int $per_page = 20, ?int $client_id = null): array {
    $where = [];
    $params = [];

    if ($client_id !== null) {
        $where[] = 's.client_id = ?';
        $params[] = $client_id;
    }

    if ($filter === 'active')  { $where[] = 's.revoked = 0'; }
    if ($filter === 'revoked') { $where[] = 's.revoked = 1'; }
    if ($filter === 'manual')  { $where[] = "s.token = 'manual'"; }
    if ($filter === 'stale')   { $where[] = 's.revoked = 0 AND s.last_checkin IS NOT NULL AND s.last_checkin < DATE_SUB(NOW(), INTERVAL 48 HOUR)'; }

    if ($search) {
        $where[] = '(s.ip LIKE ? OR s.hostname LIKE ? OR s.server_id LIKE ? OR s.note LIKE ?)';
        $like = "%$search%";
        array_push($params, $like, $like, $like, $like);
    }

    $clause = $where ? 'WHERE ' . implode(' AND ', $where) : '';
    $offset = ($page - 1) * $per_page;
    $params[] = $per_page;
    $params[] = $offset;
    $stmt = db()->prepare(
        "SELECT s.*, c.name AS client_name
         FROM servers s
         LEFT JOIN clients c ON s.client_id = c.id
         $clause ORDER BY s.registered_at DESC LIMIT ? OFFSET ?"
    );
    $stmt->execute($params);
    return $stmt->fetchAll();
}

function count_servers(string $filter = 'all', string $search = '', ?int $client_id = null): int {
    $where = [];
    $params = [];

    if ($client_id !== null) {
        $where[] = 'client_id = ?';
        $params[] = $client_id;
    }

    if ($filter === 'active')  { $where[] = 'revoked = 0'; }
    if ($filter === 'revoked') { $where[] = 'revoked = 1'; }
    if ($filter === 'manual')  { $where[] = "token = 'manual'"; }
    if ($filter === 'stale')   { $where[] = 'revoked = 0 AND last_checkin IS NOT NULL AND last_checkin < DATE_SUB(NOW(), INTERVAL 48 HOUR)'; }
    if ($search) {
        $where[] = '(ip LIKE ? OR hostname LIKE ? OR server_id LIKE ? OR note LIKE ?)';
        $like = "%$search%";
        array_push($params, $like, $like, $like, $like);
    }
    $clause = $where ? 'WHERE ' . implode(' AND ', $where) : '';
    $stmt = db()->prepare("SELECT COUNT(*) FROM servers $clause");
    $stmt->execute($params);
    return (int) $stmt->fetchColumn();
}

function server_export_cursor(string $filter = 'all', string $search = '', ?int $client_id = null): PDOStatement {
    $where = [];
    $params = [];

    if ($client_id !== null) {
        $where[] = 's.client_id = ?';
        $params[] = $client_id;
    }

    if ($filter === 'active')  { $where[] = 's.revoked = 0'; }
    if ($filter === 'revoked') { $where[] = 's.revoked = 1'; }
    if ($filter === 'manual')  { $where[] = "s.token = 'manual'"; }
    if ($filter === 'stale')   { $where[] = 's.revoked = 0 AND s.last_checkin IS NOT NULL AND s.last_checkin < DATE_SUB(NOW(), INTERVAL 48 HOUR)'; }

    if ($search) {
        $where[] = '(s.ip LIKE ? OR s.hostname LIKE ? OR s.server_id LIKE ? OR s.note LIKE ?)';
        $like = "%$search%";
        array_push($params, $like, $like, $like, $like);
    }

    $clause = $where ? 'WHERE ' . implode(' AND ', $where) : '';
    $stmt = db()->prepare(
        "SELECT s.*, c.name AS client_name
         FROM servers s
         LEFT JOIN clients c ON s.client_id = c.id
         $clause ORDER BY s.registered_at DESC"
    );
    $stmt->execute($params);
    return $stmt;
}

function server_stats(?int $client_id = null): array {
    $cond     = $client_id !== null ? ' WHERE client_id = ?' : '';
    $cond_and = $client_id !== null ? ' AND client_id = ?'   : '';
    $p        = $client_id !== null ? [$client_id]           : [];

    $s1 = db()->prepare("SELECT COUNT(*) FROM servers$cond");
    $s1->execute($p); $total = (int) $s1->fetchColumn();

    $s2 = db()->prepare("SELECT COUNT(*) FROM servers WHERE revoked = 0$cond_and");
    $s2->execute($p); $active = (int) $s2->fetchColumn();

    $s3 = db()->prepare("SELECT COUNT(*) FROM servers WHERE revoked = 1$cond_and");
    $s3->execute($p); $revoked = (int) $s3->fetchColumn();

    $s4 = db()->prepare(
        "SELECT COUNT(*) FROM servers WHERE revoked = 0 AND last_checkin IS NOT NULL
         AND last_checkin > DATE_SUB(NOW(), INTERVAL 48 HOUR)$cond_and"
    );
    $s4->execute($p); $checkedin = (int) $s4->fetchColumn();

    return compact('total', 'active', 'revoked', 'checkedin');
}

// ── Login History ──────────────────────────────────────────────

function record_login_history(string $user_type, int $user_id, string $username, bool $success): void {
    db()->prepare(
        'INSERT INTO login_history (user_type, user_id, username, ip_address, user_agent, success)
         VALUES (?, ?, ?, ?, ?, ?)'
    )->execute([
        $user_type, $user_id, $username, client_ip(),
        substr($_SERVER['HTTP_USER_AGENT'] ?? '', 0, 500),
        $success ? 1 : 0,
    ]);
}

function get_login_history(string $user_type, int $user_id, int $limit = 20): array {
    $stmt = db()->prepare(
        'SELECT * FROM login_history WHERE user_type = ? AND user_id = ?
         ORDER BY created_at DESC LIMIT ?'
    );
    $stmt->execute([$user_type, $user_id, $limit]);
    return $stmt->fetchAll();
}

function get_all_login_history(int $page = 1, int $per_page = 30): array {
    $offset = ($page - 1) * $per_page;
    $stmt = db()->prepare(
        'SELECT * FROM login_history ORDER BY created_at DESC LIMIT ? OFFSET ?'
    );
    $stmt->execute([$per_page, $offset]);
    return $stmt->fetchAll();
}

function count_login_history(): int {
    return (int) db()->query('SELECT COUNT(*) FROM login_history')->fetchColumn();
}

// ── Webhooks ───────────────────────────────────────────────────

function get_webhooks(): array {
    $rows = db()->query('SELECT * FROM webhooks ORDER BY created_at DESC')->fetchAll();
    foreach ($rows as &$row) {
        $row['secret'] = normalize_webhook_secret_storage((int) $row['id'], (string) $row['secret']);
    }
    unset($row);
    return $rows;
}

function get_webhook(int $id): ?array {
    $stmt = db()->prepare('SELECT * FROM webhooks WHERE id = ?');
    $stmt->execute([$id]);
    $row = $stmt->fetch() ?: null;
    if ($row) {
        $row['secret'] = normalize_webhook_secret_storage((int) $row['id'], (string) $row['secret']);
    }
    return $row;
}

function create_webhook(string $name, string $url, string $events = 'all', string $secret = ''): int {
    if (!$secret) $secret = bin2hex(random_bytes(16));
    $secret = encrypt_webhook_secret($secret);
    db()->prepare(
        'INSERT INTO webhooks (name, url, events, secret) VALUES (?, ?, ?, ?)'
    )->execute([$name, $url, $events, $secret]);
    return (int) db()->lastInsertId();
}

function update_webhook(int $id, string $name, string $url, string $events, bool $active): void {
    db()->prepare(
        'UPDATE webhooks SET name = ?, url = ?, events = ?, is_active = ? WHERE id = ?'
    )->execute([$name, $url, $events, $active ? 1 : 0, $id]);
}

function delete_webhook(int $id): void {
    db()->prepare('DELETE FROM webhooks WHERE id = ?')->execute([$id]);
}

function resolve_public_webhook_ips(string $host): array {
    if (filter_var($host, FILTER_VALIDATE_IP)) {
        return filter_var($host, FILTER_VALIDATE_IP, FILTER_FLAG_NO_PRIV_RANGE | FILTER_FLAG_NO_RES_RANGE)
            ? [$host]
            : [];
    }

    $records = @dns_get_record($host, DNS_A + DNS_AAAA);
    if (!is_array($records) || $records === []) {
        return [];
    }

    $ips = [];
    foreach ($records as $record) {
        $candidate = (string) ($record['ip'] ?? $record['ipv6'] ?? '');
        if ($candidate === '') {
            continue;
        }
        if (!filter_var($candidate, FILTER_VALIDATE_IP, FILTER_FLAG_NO_PRIV_RANGE | FILTER_FLAG_NO_RES_RANGE)) {
            return [];
        }
        $ips[] = $candidate;
    }

    return array_values(array_unique($ips));
}

function parse_safe_webhook_target(string $url): ?array {
    $parsed = parse_url($url);
    if (!$parsed || !isset($parsed['scheme'], $parsed['host'])) {
        return null;
    }

    $scheme = strtolower((string) $parsed['scheme']);
    if ($scheme !== 'https' || isset($parsed['user']) || isset($parsed['pass'])) {
        return null;
    }

    $port = isset($parsed['port']) ? (int) $parsed['port'] : 443;
    if ($port < 1 || $port > 65535) {
        return null;
    }

    $ips = resolve_public_webhook_ips((string) $parsed['host']);
    if ($ips === []) {
        return null;
    }

    return [
        'url' => $url,
        'host' => (string) $parsed['host'],
        'port' => $port,
        'ips' => $ips,
    ];
}

function is_safe_webhook_url(string $url): bool {
    return parse_safe_webhook_target($url) !== null;
}

function send_webhook_request(array $target, string $body, string $signature): int {
    $headers = [
        'Content-Type: application/json',
        'X-Webhook-Signature: sha256=' . $signature,
    ];

    if (!function_exists('curl_init')) {
        error_log('Webhook delivery skipped because the PHP cURL extension is unavailable.');
        return 0;
    }

    foreach ($target['ips'] as $ip) {
        $ch = curl_init($target['url']);
        curl_setopt_array($ch, [
            CURLOPT_POST => true,
            CURLOPT_HTTPHEADER => $headers,
            CURLOPT_POSTFIELDS => $body,
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_CONNECTTIMEOUT => 5,
            CURLOPT_TIMEOUT => 5,
            CURLOPT_PROTOCOLS => CURLPROTO_HTTPS,
            CURLOPT_REDIR_PROTOCOLS => CURLPROTO_HTTPS,
            CURLOPT_FOLLOWLOCATION => false,
            CURLOPT_SSL_VERIFYPEER => true,
            CURLOPT_SSL_VERIFYHOST => 2,
            CURLOPT_RESOLVE => [$target['host'] . ':' . $target['port'] . ':' . $ip],
        ]);

        curl_exec($ch);
        $status = (int) curl_getinfo($ch, CURLINFO_RESPONSE_CODE);
        $errno = curl_errno($ch);
        curl_close($ch);

        if ($errno === 0) {
            return $status;
        }
    }

    return 0;
}

function fire_webhooks(string $event, array $payload): void {
    $hooks = db()->prepare(
        'SELECT * FROM webhooks WHERE is_active = 1 AND (events = ? OR events LIKE ? OR events LIKE ? OR events LIKE ?)'
    );
    $hooks->execute(['all', "$event,%", "%,$event,%", "%,$event"]);

    foreach ($hooks->fetchAll() as $hook) {
        $target = parse_safe_webhook_target((string) $hook['url']);
        if ($target === null) {
            error_log("Webhook #{$hook['id']} blocked: URL is not an approved HTTPS public endpoint");
            db()->prepare(
                'UPDATE webhooks SET last_triggered = NOW(), last_status = 0, fail_count = fail_count + 1 WHERE id = ?'
            )->execute([$hook['id']]);
            continue;
        }

        $body = json_encode([
            'event'     => $event,
            'timestamp' => date('c'),
            'data'      => $payload,
        ]);
        $stored_secret = normalize_webhook_secret_storage((int) $hook['id'], (string) $hook['secret']);
        $sig = hash_hmac('sha256', $body, decrypt_webhook_secret($stored_secret));
        $status = send_webhook_request($target, $body, $sig);
        $fail = ($status < 200 || $status >= 300) ? ((int) $hook['fail_count'] + 1) : 0;
        db()->prepare(
            'UPDATE webhooks SET last_triggered = NOW(), last_status = ?, fail_count = ? WHERE id = ?'
        )->execute([$status, $fail, $hook['id']]);

        // Auto-disable after 10 consecutive failures
        if ($fail >= 10) {
            db()->prepare('UPDATE webhooks SET is_active = 0 WHERE id = ?')
                ->execute([$hook['id']]);
        }
    }
}

// ── Subscriptions ──────────────────────────────────────────────

function get_subscription(int $client_id): ?array {
    $stmt = db()->prepare(
        'SELECT * FROM subscriptions WHERE client_id = ? ORDER BY created_at DESC LIMIT 1'
    );
    $stmt->execute([$client_id]);
    return $stmt->fetch() ?: null;
}

function get_subscriptions(int $page = 1, int $per_page = 20, string $filter = 'all'): array {
    $where = [];
    $params = [];
    if ($filter === 'active')    { $where[] = "s.status = 'active'"; }
    if ($filter === 'expired')   { $where[] = "s.status = 'expired'"; }
    if ($filter === 'cancelled') { $where[] = "s.status = 'cancelled'"; }
    if ($filter === 'trial')     { $where[] = "s.status = 'trial'"; }
    $clause = $where ? 'WHERE ' . implode(' AND ', $where) : '';
    $offset = ($page - 1) * $per_page;
    $params[] = $per_page;
    $params[] = $offset;
    $stmt = db()->prepare(
        "SELECT s.*, c.name AS client_name, c.username AS client_username
         FROM subscriptions s
         LEFT JOIN clients c ON s.client_id = c.id
         $clause ORDER BY s.created_at DESC LIMIT ? OFFSET ?"
    );
    $stmt->execute($params);
    return $stmt->fetchAll();
}

function count_subscriptions(string $filter = 'all'): int {
    $where = '';
    $params = [];
    if ($filter === 'active')    { $where = "WHERE status = 'active'"; }
    if ($filter === 'expired')   { $where = "WHERE status = 'expired'"; }
    if ($filter === 'cancelled') { $where = "WHERE status = 'cancelled'"; }
    $stmt = db()->prepare("SELECT COUNT(*) FROM subscriptions $where");
    $stmt->execute($params);
    return (int) $stmt->fetchColumn();
}

function create_subscription(int $client_id, string $plan, int $max_servers, float $amount, string $currency, ?string $expires_at): int {
    db()->prepare(
        'INSERT INTO subscriptions (client_id, plan, max_servers, amount, currency, expires_at) VALUES (?, ?, ?, ?, ?, ?)'
    )->execute([$client_id, $plan, $max_servers, $amount, $currency, $expires_at]);
    // Update client max_servers to match subscription
    if ($max_servers > 0) {
        db()->prepare('UPDATE clients SET max_servers = ? WHERE id = ?')
            ->execute([$max_servers, $client_id]);
    }
    return (int) db()->lastInsertId();
}

function update_subscription_status(int $id, string $status): void {
    db()->prepare('UPDATE subscriptions SET status = ? WHERE id = ?')
        ->execute([$status, $id]);
}

function expire_subscriptions(): int {
    $stmt = db()->prepare(
        "UPDATE subscriptions SET status = 'expired'
         WHERE status = 'active' AND expires_at IS NOT NULL AND expires_at < NOW()"
    );
    $stmt->execute();
    return $stmt->rowCount();
}

function subscription_stats(): array {
    $total    = (int) db()->query('SELECT COUNT(*) FROM subscriptions')->fetchColumn();
    $active   = (int) db()->query("SELECT COUNT(*) FROM subscriptions WHERE status = 'active'")->fetchColumn();
    $expired  = (int) db()->query("SELECT COUNT(*) FROM subscriptions WHERE status = 'expired'")->fetchColumn();
    $revenue  = (float) db()->query("SELECT COALESCE(SUM(amount), 0) FROM subscriptions WHERE status IN ('active','expired')")->fetchColumn();
    return compact('total', 'active', 'expired', 'revenue');
}

// ── Install Tickets ─────────────────────────────────────────────

function create_install_ticket(?int $client_id, string $ip, int $ttl_seconds = 600): string {
    $ticket = 'itk_' . bin2hex(random_bytes(24));
    db()->prepare(
        'INSERT INTO install_tickets (ticket, client_id, ip_address, expires_at)
         VALUES (?, ?, ?, DATE_ADD(NOW(), INTERVAL ? SECOND))'
    )->execute([$ticket, $client_id, $ip, $ttl_seconds]);
    return $ticket;
}

function consume_install_ticket(string $ticket, string $ip): ?array {
    $stmt = db()->prepare(
        'SELECT t.ticket, t.client_id, c.*,
                COALESCE(c.is_active, 1) AS is_active,
                COALESCE(c.name, \'Admin\') AS name,
                COALESCE(c.token, \'manual\') AS token
         FROM install_tickets t
         LEFT JOIN clients c ON t.client_id = c.id
         WHERE t.ticket = ?
           AND t.used_at IS NULL
           AND t.expires_at > NOW()
           AND t.ip_address = ?
         LIMIT 1'
    );
    $stmt->execute([$ticket, $ip]);
    $row = $stmt->fetch();
    if (!$row) {
        return null;
    }
    db()->prepare('UPDATE install_tickets SET used_at = NOW() WHERE ticket = ?')
        ->execute([$ticket]);
    if (array_key_exists('token', $row)) {
        try {
            $row['token'] = decrypt_sensitive_token((string) $row['token']);
        } catch (Throwable) {
            $row['token'] = '';
        }
    }
    return $row;
}

function server_token_matches(array $server, string $token): bool {
    if ($token === '') {
        return false;
    }

    $hash = (string) ($server['token_hash'] ?? '');
    if ($hash !== '') {
        return hash_equals($hash, token_lookup_hash($token));
    }

    $stored = decrypt_sensitive_token((string) ($server['token'] ?? ''));
    return $stored !== '' && $stored !== 'manual' && hash_equals($stored, $token);
}

function server_token_hint_from_storage(?string $stored): string {
    try {
        $plain = decrypt_sensitive_token((string) $stored);
    } catch (Throwable) {
        return '';
    }
    return token_hint($plain);
}

// ── Admin Roles ────────────────────────────────────────────────

function get_admin_role(string $username): string {
    $admin = get_admin($username);
    return $admin['role'] ?? 'admin';
}

function can_admin(string $action): bool {
    $role = $_SESSION['admin_role'] ?? 'viewer';
    $permissions = [
        'superadmin' => ['*'],
        'admin'      => ['manage_servers', 'manage_clients', 'view_logs', 'manage_settings', 'view_dashboard'],
        'viewer'     => ['view_dashboard', 'view_logs'],
    ];
    $perms = $permissions[$role] ?? [];
    return in_array('*', $perms) || in_array($action, $perms);
}

function get_all_admins(): array {
    return db()->query('SELECT id, username, role, created_at, last_login FROM admin_users ORDER BY created_at')->fetchAll();
}

function create_admin_user(string $username, string $password, string $role = 'admin'): void {
    $hash = password_hash($password, PASSWORD_BCRYPT, ['cost' => 12]);
    db()->prepare('INSERT INTO admin_users (username, password, role) VALUES (?, ?, ?)')
        ->execute([$username, $hash, $role]);
}

function update_admin_role(int $id, string $role): void {
    db()->prepare('UPDATE admin_users SET role = ? WHERE id = ?')
        ->execute([$role, $id]);
}

function delete_admin_user(int $id): void {
    db()->prepare('DELETE FROM admin_users WHERE id = ?')->execute([$id]);
}

// ── Server Geo Lookup ──────────────────────────────────────────

function lookup_server_geo(string $ip): array {
    if (!defined('SERVER_GEOLOOKUP_ENABLED') || !SERVER_GEOLOOKUP_ENABLED) {
        return [];
    }

    $template = trim((string) (defined('SERVER_GEOLOOKUP_ENDPOINT') ? SERVER_GEOLOOKUP_ENDPOINT : ''));
    if ($template === '') {
        return [];
    }

    $url = str_replace('{ip}', rawurlencode($ip), $template);
    $parsed = parse_url($url);
    if (!$parsed || strtolower((string) ($parsed['scheme'] ?? '')) !== 'https') {
        return [];
    }

    if (!function_exists('curl_init')) {
        return [];
    }

    $ch = curl_init($url);
    curl_setopt_array($ch, [
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_CONNECTTIMEOUT => 3,
        CURLOPT_TIMEOUT => 3,
        CURLOPT_PROTOCOLS => CURLPROTO_HTTPS,
        CURLOPT_REDIR_PROTOCOLS => CURLPROTO_HTTPS,
        CURLOPT_FOLLOWLOCATION => false,
        CURLOPT_SSL_VERIFYPEER => true,
        CURLOPT_SSL_VERIFYHOST => 2,
    ]);
    $raw = curl_exec($ch);
    $status = (int) curl_getinfo($ch, CURLINFO_RESPONSE_CODE);
    curl_close($ch);

    if ($raw === false || $status < 200 || $status >= 300) {
        return [];
    }

    $data = json_decode($raw, true);
    if (!is_array($data) || ($data['status'] ?? '') !== 'success') {
        return [];
    }

    return [
        'country' => $data['countryCode'] ?? '',
        'city'    => $data['city'] ?? '',
        'lat'     => (float) ($data['lat'] ?? 0),
        'lon'     => (float) ($data['lon'] ?? 0),
    ];
}

function update_server_geo(string $server_id, array $geo): void {
    db()->prepare(
        'UPDATE servers SET country = ?, city = ?, lat = ?, lon = ? WHERE server_id = ?'
    )->execute([
        $geo['country'] ?? '', $geo['city'] ?? '',
        $geo['lat'] ?? null, $geo['lon'] ?? null,
        $server_id,
    ]);
}

function server_health_probe_urls(array $server): array {
    $urls = [];
    $seen = [];
    foreach (['hostname', 'ip'] as $field) {
        $host = trim((string) ($server[$field] ?? ''));
        if ($host === '') {
            continue;
        }
        $key = strtolower($host);
        if (isset($seen[$key])) {
            continue;
        }
        $seen[$key] = true;

        $paths = ['/api/v2/healthz', '/healthz'];
        $schemes = filter_var($host, FILTER_VALIDATE_IP) ? ['http', 'https'] : ['https', 'http'];
        foreach ($schemes as $scheme) {
            foreach ($paths as $path) {
                $urls[] = sprintf('%s://%s%s', $scheme, $host, $path);
            }
        }
    }
    return $urls;
}

function probe_server_health(array $server): array {
    $checkedAt = gmdate('Y-m-d H:i:s');
    if (!function_exists('curl_init')) {
        return [
            'health_status' => 'unknown',
            'health_checked_at' => $checkedAt,
            'health_error' => 'cURL is not available on the license server.',
            'health_endpoint' => '',
        ];
    }

    $lastError = 'No reachable health endpoint.';
    foreach (server_health_probe_urls($server) as $url) {
        $parsed = parse_url($url);
        $scheme = strtolower((string) ($parsed['scheme'] ?? 'http'));
        $protocols = $scheme === 'https' ? CURLPROTO_HTTPS : CURLPROTO_HTTP;

        $ch = curl_init($url);
        curl_setopt_array($ch, [
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_CONNECTTIMEOUT => 3,
            CURLOPT_TIMEOUT => 5,
            CURLOPT_PROTOCOLS => $protocols,
            CURLOPT_REDIR_PROTOCOLS => $protocols,
            CURLOPT_FOLLOWLOCATION => false,
            CURLOPT_SSL_VERIFYPEER => $scheme === 'https',
            CURLOPT_SSL_VERIFYHOST => $scheme === 'https' ? 2 : 0,
            CURLOPT_HTTPHEADER => ['Accept: application/json'],
            CURLOPT_USERAGENT => 'IPTunnel-Admin-HealthCheck/1.0',
        ]);
        $raw = curl_exec($ch);
        $errno = curl_errno($ch);
        $error = $errno !== 0 ? curl_error($ch) : '';
        $status = (int) curl_getinfo($ch, CURLINFO_RESPONSE_CODE);
        curl_close($ch);

        if ($raw === false) {
            $lastError = $error !== '' ? $error : sprintf('Connection failed for %s', $url);
            continue;
        }

        if ($status >= 200 && $status < 300) {
            $payload = json_decode($raw, true);
            $isHealthy = true;
            if (is_array($payload)) {
                $healthValue = strtolower((string) (($payload['data']['status'] ?? $payload['status'] ?? 'ok')));
                $isHealthy = in_array($healthValue, ['ok', 'healthy', 'online'], true);
            }
            if ($isHealthy) {
                return [
                    'health_status' => 'online',
                    'health_checked_at' => $checkedAt,
                    'health_error' => '',
                    'health_endpoint' => $url,
                ];
            }
            $lastError = sprintf('Unexpected health payload from %s', $url);
            continue;
        }

        $lastError = sprintf('HTTP %d from %s', $status, $url);
    }

    return [
        'health_status' => 'offline',
        'health_checked_at' => $checkedAt,
        'health_error' => substr($lastError, 0, 255),
        'health_endpoint' => '',
    ];
}

function update_server_health(string $server_id, array $result): void {
    db()->prepare(
        'UPDATE servers
            SET health_status = ?, health_checked_at = ?, health_error = ?, health_endpoint = ?
          WHERE server_id = ?'
    )->execute([
        $result['health_status'] ?? 'unknown',
        $result['health_checked_at'] ?? null,
        $result['health_error'] ?? '',
        $result['health_endpoint'] ?? '',
        $server_id,
    ]);
}

function get_servers_by_ids(array $server_ids): array {
    $ids = array_values(array_filter(array_map('trim', $server_ids)));
    if (empty($ids)) {
        return [];
    }
    $placeholders = implode(',', array_fill(0, count($ids), '?'));
    $stmt = db()->prepare(
        "SELECT s.*, c.name AS client_name
           FROM servers s
           LEFT JOIN clients c ON s.client_id = c.id
          WHERE s.server_id IN ($placeholders)"
    );
    $stmt->execute($ids);
    $rows = $stmt->fetchAll();
    $ordered = [];
    foreach ($rows as $row) {
        $ordered[(string) $row['server_id']] = $row;
    }
    $result = [];
    foreach ($ids as $id) {
        if (isset($ordered[$id])) {
            $result[] = $ordered[$id];
        }
    }
    return $result;
}

function get_due_server_health_ids(int $limit = 25, int $interval_seconds = 300): array {
    $limit = max(1, min($limit, 250));
    $interval_seconds = max(60, $interval_seconds);

    $stmt = db()->prepare(
        "SELECT server_id
           FROM servers
          WHERE revoked = 0
            AND (
                health_checked_at IS NULL
                OR health_checked_at < DATE_SUB(NOW(), INTERVAL ? SECOND)
            )
          ORDER BY COALESCE(health_checked_at, '1970-01-01 00:00:00') ASC, registered_at ASC
          LIMIT ?"
    );
    $stmt->execute([$interval_seconds, $limit]);
    return array_values(array_filter(array_map(
        static fn($value): string => trim((string) $value),
        $stmt->fetchAll(PDO::FETCH_COLUMN)
    )));
}

function refresh_servers_health(array $server_ids, bool $skip_revoked = true): array {
    $rows = get_servers_by_ids($server_ids);
    $results = [];
    foreach ($rows as $row) {
        if ($skip_revoked && (int) ($row['revoked'] ?? 0) === 1) {
            continue;
        }
        $health = probe_server_health($row);
        update_server_health((string) $row['server_id'], $health);
        $results[] = [
            'server_id' => (string) $row['server_id'],
            'health_status' => $health['health_status'],
            'health_checked_at' => $health['health_checked_at'],
            'health_error' => $health['health_error'],
            'health_endpoint' => $health['health_endpoint'],
        ];
    }
    return $results;
}

function refresh_due_servers_health(int $limit = 25, int $interval_seconds = 300): array {
    $ids = get_due_server_health_ids($limit, $interval_seconds);
    if (empty($ids)) {
        return [];
    }
    return refresh_servers_health($ids, true);
}

// ── White-Label Helpers ────────────────────────────────────────

function brand(string $key): string {
    static $cache = null;
    if ($cache === null) {
        $cache = [
            'name'  => get_setting('brand_name', 'IPTunnel'),
            'color' => get_setting('brand_color', '#63b3ed'),
            'logo'  => get_setting('brand_logo_url', ''),
            'support_email' => get_setting('support_email', ''),
            'support_url'   => get_setting('support_url', ''),
        ];
    }
    return $cache[$key] ?? '';
}

function set_branding(string $name, string $color, string $logo, string $support_email, string $support_url): void {
    set_setting('brand_name', trim($name) !== '' ? trim($name) : 'IPTunnel');
    set_setting('brand_color', trim($color) !== '' ? trim($color) : '#63b3ed');
    set_setting('brand_logo_url', trim($logo));
    set_setting('support_email', trim($support_email));
    set_setting('support_url', trim($support_url));
}

function server_country_summary(int $limit = 8): array {
    $stmt = db()->prepare(
        "SELECT country, COUNT(*) AS total
         FROM servers
         WHERE country <> ''
         GROUP BY country
         ORDER BY total DESC, country ASC
         LIMIT ?"
    );
    $stmt->execute([$limit]);
    return $stmt->fetchAll();
}

function server_locations(int $limit = 50): array {
    $stmt = db()->prepare(
        "SELECT server_id, ip, hostname, country, city, lat, lon, revoked, last_checkin
         FROM servers
         WHERE lat IS NOT NULL AND lon IS NOT NULL
         ORDER BY registered_at DESC
         LIMIT ?"
    );
    $stmt->execute([$limit]);
    return $stmt->fetchAll();
}

// ── Audit Log Cleanup ──────────────────────────────────────────

function cleanup_old_data(int $audit_days = 90, int $login_history_days = 90): array {
    $s1 = db()->prepare('DELETE FROM audit_logs WHERE created_at < DATE_SUB(NOW(), INTERVAL ? DAY)');
    $s1->execute([$audit_days]);
    $audit_deleted = $s1->rowCount();

    $s2 = db()->prepare('DELETE FROM login_history WHERE created_at < DATE_SUB(NOW(), INTERVAL ? DAY)');
    $s2->execute([$login_history_days]);
    $history_deleted = $s2->rowCount();

    $s3 = db()->prepare('DELETE FROM login_attempts WHERE last_attempt < DATE_SUB(NOW(), INTERVAL 7 DAY)');
    $s3->execute();
    $attempts_deleted = $s3->rowCount();

    $s4 = db()->prepare('DELETE FROM install_tickets WHERE used_at IS NOT NULL OR expires_at < NOW()');
    $s4->execute();
    $tickets_deleted = $s4->rowCount();

    return compact('audit_deleted', 'history_deleted', 'attempts_deleted', 'tickets_deleted');
}
