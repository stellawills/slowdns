<?php
/**
 * IP Tunnel VPN - Device Provisioning API
 * Isolated entrypoint for per-device provisioning flows.
 */

// ========================================
// ERROR REPORTING & DEBUGGING
// ========================================
error_reporting(E_ALL);
ini_set('display_errors', 0);
ini_set('log_errors', 1);

$logFile = __DIR__ . '/api_debug.log';
$LAST_GOOGLE_ACCESS_TOKEN_ERROR = null;
$DEBUG_LOG_ENABLED = false;

function debugLog($message, $data = null) {
    global $logFile, $DEBUG_LOG_ENABLED;
    if (!$DEBUG_LOG_ENABLED) return;
    $log = "[" . date('Y-m-d H:i:s') . "] $message";
    if ($data !== null) {
        $log .= "\n" . print_r(sanitizeLogData($data), true);
    }
    @file_put_contents($logFile, $log . "\n", FILE_APPEND);
}

function sanitizeLogData($data) {
    $sensitiveKeys = [
        'password', 'pass', 'token', 'authorization', 'auth', 'jwt',
        'x-app-sign', 'x_app_sign', 'app_sign', 'signature', 'secret', 'private_key'
        , 'config', 'payload', 'server', 'message', 'certificate', 'publickey', 'vmess', 'vless'
    ];
    if (is_array($data)) {
        $out = [];
        foreach ($data as $k => $v) {
            $key = strtolower((string)$k);
            $isSensitive = false;
            foreach ($sensitiveKeys as $needle) {
                if (strpos($key, $needle) !== false) {
                    $isSensitive = true;
                    break;
                }
            }
            $out[$k] = $isSensitive ? '***' : sanitizeLogData($v);
        }
        return $out;
    }
    if (is_string($data) && strlen($data) > 512) {
        return substr($data, 0, 512) . '...(truncated)';
    }
    return $data;
}

function summarizeInputForLog($input, $rawInput) {
    $summary = [
        'type' => gettype($input),
        'raw_len' => is_string($rawInput) ? strlen($rawInput) : 0,
        'raw_sha256' => is_string($rawInput) ? hash('sha256', $rawInput) : ''
    ];
    if (is_array($input)) {
        $summary['keys'] = array_keys($input);
        if (isset($input['action'])) {
            $summary['action'] = (string)$input['action'];
        }
    }
    return $summary;
}

function loadEnvFile($path) {
    $env = [];
    if (!file_exists($path)) return $env;
    $lines = @file($path, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
    if (!$lines) return $env;
    foreach ($lines as $line) {
        $line = trim($line);
        if ($line === '' || strpos($line, '#') === 0) continue;
        $pos = strpos($line, '=');
        if ($pos === false) continue;
        $key = trim(substr($line, 0, $pos));
        $val = trim(substr($line, $pos + 1));
        if ($val !== '' && (($val[0] === '"' && substr($val, -1) === '"') || ($val[0] === "'" && substr($val, -1) === "'"))) {
            $val = substr($val, 1, -1);
        }
        $env[$key] = $val;
    }
    return $env;
}

// ========================================
// CORS CONFIGURATION
// ========================================
$corsAllowedOrigins = [
    'https://iptunnel.internetshub.com'
];

$corsEnvRaw = '';
if (isset($_SERVER['CORS_ALLOWED_ORIGINS'])) {
    $corsEnvRaw = (string)$_SERVER['CORS_ALLOWED_ORIGINS'];
} elseif (isset($_ENV['CORS_ALLOWED_ORIGINS'])) {
    $corsEnvRaw = (string)$_ENV['CORS_ALLOWED_ORIGINS'];
} else {
    $tmp = getenv('CORS_ALLOWED_ORIGINS');
    if ($tmp !== false) $corsEnvRaw = (string)$tmp;
}
if ($corsEnvRaw === '') {
    $corsEnv = loadEnvFile(__DIR__ . '/.env');
    if (isset($corsEnv['CORS_ALLOWED_ORIGINS'])) {
        $corsEnvRaw = (string)$corsEnv['CORS_ALLOWED_ORIGINS'];
    }
}
if ($corsEnvRaw !== '') {
    $parts = preg_split('/\s*,\s*/', $corsEnvRaw);
    if (is_array($parts)) {
        foreach ($parts as $v) {
            $o = trim((string)$v);
            if ($o !== '') $corsAllowedOrigins[] = $o;
        }
    }
}

$host = trim((string)($_SERVER['HTTP_HOST'] ?? ''));
if ($host !== '') {
    $scheme = (!empty($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off') ? 'https' : 'http';
    $selfOrigin = $scheme . '://' . $host;
    $corsAllowedOrigins[] = $selfOrigin;
    if (stripos($host, 'localhost') !== false || stripos($host, '127.0.0.1') !== false) {
        $corsAllowedOrigins[] = 'http://localhost:8000';
        $corsAllowedOrigins[] = 'http://localhost:3000';
    }
}

$corsAllowedOrigins = array_values(array_unique(array_filter(array_map('trim', $corsAllowedOrigins), function ($v) {
    return $v !== '';
})));

$origin = trim((string)($_SERVER['HTTP_ORIGIN'] ?? ''));
$originAllowed = $origin !== '' && in_array($origin, $corsAllowedOrigins, true);

if ($originAllowed) {
    header("Access-Control-Allow-Origin: $origin");
    header('Access-Control-Allow-Credentials: true');
    header('Vary: Origin');
} elseif ($origin !== '') {
    header('Vary: Origin');
} elseif (count($corsAllowedOrigins) > 0) {
    header('Access-Control-Allow-Origin: ' . $corsAllowedOrigins[0]);
}

header('Access-Control-Allow-Methods: GET, POST, PUT, DELETE, OPTIONS');
header('Access-Control-Allow-Headers: Content-Type, Authorization, X-App-Id, X-App-Device, X-App-Ts, X-App-Nonce, X-App-Sign, X-App-Version, X-App-Session, X-App-Auth-Mode');
header('Content-Type: application/json');

if ($_SERVER['REQUEST_METHOD'] === 'OPTIONS') {
    if ($origin !== '' && !$originAllowed) {
        http_response_code(403);
        echo json_encode(['error' => 'cors_origin_denied']);
        exit;
    }
    http_response_code(204);
    exit;
}

$ENV = loadEnvFile(__DIR__ . '/.env');
if (isset($ENV['DEBUG_LOG_ENABLED'])) {
    $DEBUG_LOG_ENABLED = toBool($ENV['DEBUG_LOG_ENABLED'], false);
}
if (isset($_ENV['DEBUG_LOG_ENABLED'])) {
    $DEBUG_LOG_ENABLED = toBool($_ENV['DEBUG_LOG_ENABLED'], $DEBUG_LOG_ENABLED);
}
if (isset($_SERVER['DEBUG_LOG_ENABLED'])) {
    $DEBUG_LOG_ENABLED = toBool($_SERVER['DEBUG_LOG_ENABLED'], $DEBUG_LOG_ENABLED);
}
// Optional UI override from admin settings (app_policy).
$adminSettingsForDebug = readJsonFileSafe(__DIR__ . '/admin_settings.json', []);
if (isset($adminSettingsForDebug['debug_log_enabled'])) {
    $DEBUG_LOG_ENABLED = toBool($adminSettingsForDebug['debug_log_enabled'], $DEBUG_LOG_ENABLED);
}
function envValue($key, $default = null) {
    global $ENV;
    if (isset($_SERVER[$key])) return $_SERVER[$key];
    if (isset($_ENV[$key])) return $_ENV[$key];
    if (isset($ENV[$key])) return $ENV[$key];
    return $default;
}

debugLog("=== NEW REQUEST ===");
debugLog("Method: " . $_SERVER['REQUEST_METHOD']);
debugLog("URI: " . $_SERVER['REQUEST_URI']);

function readJsonFileSafe($path, $fallback = []) {
    if (!file_exists($path)) return $fallback;
    $raw = @file_get_contents($path);
    if ($raw === false || trim($raw) === '') return $fallback;
    $data = json_decode($raw, true);
    return is_array($data) ? $data : $fallback;
}

function toBool($value, $default = false) {
    if (is_bool($value)) return $value;
    if (is_int($value)) return $value !== 0;
    if (!is_string($value)) return $default;
    $v = strtolower(trim($value));
    if ($v === '1' || $v === 'true' || $v === 'yes' || $v === 'on') return true;
    if ($v === '0' || $v === 'false' || $v === 'no' || $v === 'off') return false;
    return $default;
}

function resolveEnvFilePath($value, $default = '') {
    $path = trim((string)$value);
    if ($path === '') $path = trim((string)$default);
    if ($path === '') return '';
    if (!preg_match('/^(\/|[A-Za-z]:[\\\\\\/])/', $path)) {
        $path = __DIR__ . '/' . ltrim($path, '/\\');
    }
    return $path;
}

// ========================================
// CONFIGURATION
// ========================================
define('ALLOW_INSECURE_DEFAULTS', toBool(envValue('ALLOW_INSECURE_DEFAULTS', '0'), false));
define('JWT_SECRET', trim((string)envValue('JWT_SECRET', '')));
define('ADMIN_USER', trim((string)envValue('ADMIN_USER', '')));
define('ADMIN_PASS_HASH', trim((string)envValue('ADMIN_PASS_HASH', '')));
define('CONFIG_FILE', __DIR__ . '/config.enc');
$serviceAccountEnv = resolveEnvFilePath(envValue('SERVICE_ACCOUNT_FILE', 'service-account.json'), 'service-account.json');
define('SERVICE_ACCOUNT_FILE', $serviceAccountEnv);
$fcmServiceAccountEnv = resolveEnvFilePath(envValue('FCM_SERVICE_ACCOUNT_FILE', SERVICE_ACCOUNT_FILE), SERVICE_ACCOUNT_FILE);
$playIntegrityServiceAccountEnv = resolveEnvFilePath(envValue('PLAY_INTEGRITY_SERVICE_ACCOUNT_FILE', SERVICE_ACCOUNT_FILE), SERVICE_ACCOUNT_FILE);
define('FCM_SERVICE_ACCOUNT_FILE', $fcmServiceAccountEnv);
define('PLAY_INTEGRITY_SERVICE_ACCOUNT_FILE', $playIntegrityServiceAccountEnv);
define('TOKEN_EXPIRY', (int)envValue('TOKEN_EXPIRY', 86400));
define('ADMIN_SETTINGS_FILE', __DIR__ . '/admin_settings.json');
define('APP_CLIENT_ID', (string)envValue('APP_CLIENT_ID', 'iptunnel-android'));
define('APP_SIGNING_SECRET', trim((string)envValue('APP_SIGNING_SECRET', '')));
define('APP_CONFIG_PASS', trim((string)envValue('APP_CONFIG_PASS', '')));
define('APP_IMPORT_KEY', trim((string)envValue('APP_IMPORT_KEY', '')));
define('APP_REQUEST_TOLERANCE', (int)envValue('APP_REQUEST_TOLERANCE', 300));
define('APP_REQUIRE_SESSION', toBool(envValue('APP_REQUIRE_SESSION', '0'), false));
define('APP_AUTH_ACCEPT_SESSION_V2', toBool(envValue('APP_AUTH_ACCEPT_SESSION_V2', '1'), true));
define('APP_STRICT_SECURITY_MODE', toBool(envValue('APP_STRICT_SECURITY_MODE', '1'), true));
define('APP_ALLOW_COIN_SYNC', toBool(envValue('APP_ALLOW_COIN_SYNC', '1'), true));
define('APP_ALLOW_LEGACY_REDEEM_CODES', toBool(envValue('APP_ALLOW_LEGACY_REDEEM_CODES', '0'), false));
define('APP_MAX_LEGACY_REDEEM_COINS', (int)envValue('APP_MAX_LEGACY_REDEEM_COINS', 200));
define('APP_COIN_UPDATES_FILE', __DIR__ . '/coin_updates.json');
define('APP_NONCE_CACHE_FILE', __DIR__ . '/app_nonce_cache.json');
define('APP_SESSION_SECRET', trim((string)envValue('APP_SESSION_SECRET', '')));
define('APP_SESSION_EXPIRY', (int)envValue('APP_SESSION_EXPIRY', 600));
define('APP_PACKAGE_NAME', (string)envValue('APP_PACKAGE_NAME', 'com.iptunnel.tunnel'));
define('APP_SIGNING_CERT_SHA256', (string)envValue('APP_SIGNING_CERT_SHA256', ''));
define('PLAY_INTEGRITY_REQUIRED_VERDICT', (string)envValue('PLAY_INTEGRITY_REQUIRED_VERDICT', 'MEETS_DEVICE_INTEGRITY'));
define('APP_MIN_VERSION_CODE', (int)envValue('APP_MIN_VERSION_CODE', 0));
define('APP_MIN_VERSION_NAME', (string)envValue('APP_MIN_VERSION_NAME', ''));
define('IMPORT_SIGNING_PRIVATE_KEY_FILE', (string)envValue('IMPORT_SIGNING_PRIVATE_KEY_FILE', ''));
define('IMPORT_SIGNING_KEY_ID', (string)envValue('IMPORT_SIGNING_KEY_ID', 'k1'));
define('REQUIRE_SIGNED_IMPORTS', toBool(envValue('REQUIRE_SIGNED_IMPORTS', '0'), false));
define('CLOUD_CONFIGS_FILE', __DIR__ . '/cloud_configs.json');
define('USER_COINS_FILE', __DIR__ . '/user_coins.json');
define('REDEEMED_CODES_FILE', __DIR__ . '/redeemed_codes.json');
define('COIN_LEDGER_FILE', __DIR__ . '/coin_ledger.json');
define('COIN_CODES_FILE', __DIR__ . '/coin_codes.json');
define('SUPPORT_REQUESTS_FILE', __DIR__ . '/support_requests.json');
define('ADMIN_UI_STATE_FILE', __DIR__ . '/admin_ui_state.json');
define('PLAY_INTEGRITY_SCOPE', 'https://www.googleapis.com/auth/playintegrity');
define('STORAGE_BACKEND', strtolower(trim((string)envValue('STORAGE_BACKEND', 'json'))));
define('DB_DSN', trim((string)envValue('DB_DSN', '')));
define('DB_USER', (string)envValue('DB_USER', ''));
define('DB_PASS', (string)envValue('DB_PASS', ''));
define('DB_SQLITE_FILE', trim((string)envValue('DB_SQLITE_FILE', __DIR__ . '/storage.sqlite')));
define('DB_AUTO_BOOTSTRAP', toBool(envValue('DB_AUTO_BOOTSTRAP', '1'), true));
define('STORAGE_FILE_MIRROR', toBool(envValue('STORAGE_FILE_MIRROR', '1'), true));
define('APP_RATE_LIMIT_FILE', __DIR__ . '/app_rate_limit.json');
define('APP_RATE_WINDOW_SECONDS', max(15, (int)envValue('APP_RATE_WINDOW_SECONDS', 60)));
define('APP_RATE_APP_IP_MAX', max(10, (int)envValue('APP_RATE_APP_IP_MAX', 120)));
define('APP_RATE_APP_DEVICE_MAX', max(10, (int)envValue('APP_RATE_APP_DEVICE_MAX', 90)));
define('APP_RATE_REDEEM_DEVICE_MAX', max(1, (int)envValue('APP_RATE_REDEEM_DEVICE_MAX', 30)));
define('APP_RATE_REDEEM_WINDOW_SECONDS', max(15, (int)envValue('APP_RATE_REDEEM_WINDOW_SECONDS', 60)));
define('APP_RATE_COIN_SYNC_DEVICE_MAX', max(3, (int)envValue('APP_RATE_COIN_SYNC_DEVICE_MAX', 24)));
define('APP_RATE_COIN_SYNC_WINDOW_SECONDS', max(15, (int)envValue('APP_RATE_COIN_SYNC_WINDOW_SECONDS', 60)));
define('APP_RATE_SUPPORT_MAX', max(1, (int)envValue('APP_RATE_SUPPORT_MAX', 8)));
define('APP_RATE_SUPPORT_WINDOW_SECONDS', max(60, (int)envValue('APP_RATE_SUPPORT_WINDOW_SECONDS', 300)));
define('ADMIN_LOGIN_RATE_MAX', max(3, (int)envValue('ADMIN_LOGIN_RATE_MAX', 8)));
define('ADMIN_LOGIN_RATE_WINDOW_SECONDS', max(30, (int)envValue('ADMIN_LOGIN_RATE_WINDOW_SECONDS', 300)));
define('ADMIN_UI_STATE_MAX_BYTES', max(20000, (int)envValue('ADMIN_UI_STATE_MAX_BYTES', 3000000)));
define('APP_COIN_SYNC_MAX_INCREASE', max(0, (int)envValue('APP_COIN_SYNC_MAX_INCREASE', 25)));
define('APP_COIN_SYNC_MAX_DECREASE', max(0, (int)envValue('APP_COIN_SYNC_MAX_DECREASE', 80)));
define('APP_NEW_USER_BONUS_COINS', max(0, (int)envValue('APP_NEW_USER_BONUS_COINS', 0)));
define('PROVISIONING_ENABLED', toBool(envValue('PROVISIONING_ENABLED', '0'), false));
define('PROVISIONING_BASE_URL', trim((string)envValue('PROVISIONING_BASE_URL', '')));
define('PROVISIONING_API_KEY', trim((string)envValue('PROVISIONING_API_KEY', '')));
define('PROVISIONING_SERVER_ID', trim((string)envValue('PROVISIONING_SERVER_ID', 'default')));
define('PROVISIONING_DEFAULT_PROTOCOL', strtolower(trim((string)envValue('PROVISIONING_DEFAULT_PROTOCOL', 'ssh'))));
define('PROVISIONING_SSH_EXPIRY_DAYS', max(1, (int)envValue('PROVISIONING_SSH_EXPIRY_DAYS', 30)));
define('PROVISIONING_SSH_LIMIT_IP', max(1, (int)envValue('PROVISIONING_SSH_LIMIT_IP', 1)));
define('PROVISIONING_SSH_QUOTA_GB', max(0, (int)envValue('PROVISIONING_SSH_QUOTA_GB', 0)));
define('PROVISIONING_REQUIRE_INTEGRITY', toBool(envValue('PROVISIONING_REQUIRE_INTEGRITY', '1'), true));
$STORAGE_INIT_ERROR = '';

function pathInsideDirectory($path, $baseDir) {
    $rp = realpath($path);
    $rb = realpath($baseDir);
    if ($rp === false || $rb === false) return false;
    $rp = rtrim(str_replace('\\', '/', $rp), '/');
    $rb = rtrim(str_replace('\\', '/', $rb), '/');
    return strpos($rp . '/', $rb . '/') === 0;
}

function enforceSensitiveFilePlacement() {
    if (ALLOW_INSECURE_DEFAULTS) return;
    $webRoot = __DIR__;

    $candidates = [];
    if (SERVICE_ACCOUNT_FILE !== '') $candidates[] = ['name' => 'SERVICE_ACCOUNT_FILE', 'path' => SERVICE_ACCOUNT_FILE];
    if (FCM_SERVICE_ACCOUNT_FILE !== '') $candidates[] = ['name' => 'FCM_SERVICE_ACCOUNT_FILE', 'path' => FCM_SERVICE_ACCOUNT_FILE];
    if (PLAY_INTEGRITY_SERVICE_ACCOUNT_FILE !== '') $candidates[] = ['name' => 'PLAY_INTEGRITY_SERVICE_ACCOUNT_FILE', 'path' => PLAY_INTEGRITY_SERVICE_ACCOUNT_FILE];
    if (IMPORT_SIGNING_PRIVATE_KEY_FILE !== '') {
        $keyPath = (string)IMPORT_SIGNING_PRIVATE_KEY_FILE;
        if (!preg_match('/^(\/|[A-Za-z]:[\\\\\\/])/', $keyPath)) {
            $keyPath = __DIR__ . '/' . ltrim($keyPath, '/\\');
        }
        $candidates[] = ['name' => 'IMPORT_SIGNING_PRIVATE_KEY_FILE', 'path' => $keyPath];
    }

    foreach ($candidates as $item) {
        $p = (string)$item['path'];
        if ($p === '' || !file_exists($p)) continue;
        if (pathInsideDirectory($p, $webRoot)) {
            http_response_code(500);
            echo json_encode([
                'error' => 'insecure_secret_file_location',
                'detail' => $item['name'] . ' must be outside api/v2 web root'
            ]);
            exit;
        }
    }
}

enforceSensitiveFilePlacement();

function sqlStorageRequested() {
    if (in_array(STORAGE_BACKEND, ['sql', 'sqlite', 'mysql', 'pgsql', 'postgres', 'pdo'], true)) {
        return true;
    }
    return DB_DSN !== '';
}

function resolveSqlitePath($path) {
    $p = trim((string)$path);
    if ($p === '') return __DIR__ . '/storage.sqlite';
    if (!preg_match('/^(\/|[A-Za-z]:[\\\\\\/])/', $p)) {
        $p = __DIR__ . '/' . ltrim($p, '/\\');
    }
    return $p;
}

function resolveStorageDsn() {
    if (DB_DSN !== '') return DB_DSN;
    if (!sqlStorageRequested()) return '';
    return 'sqlite:' . resolveSqlitePath(DB_SQLITE_FILE);
}

function initStorageSchema($pdo) {
    if (!DB_AUTO_BOOTSTRAP) return;
    $driver = strtolower((string)$pdo->getAttribute(PDO::ATTR_DRIVER_NAME));
    if ($driver === 'sqlite') {
        $pdo->exec("CREATE TABLE IF NOT EXISTS kv_store (
            k TEXT PRIMARY KEY,
            v TEXT NOT NULL,
            updated_at INTEGER NOT NULL
        )");
    } elseif ($driver === 'mysql') {
        $pdo->exec("CREATE TABLE IF NOT EXISTS kv_store (
            k VARCHAR(191) PRIMARY KEY,
            v LONGTEXT NOT NULL,
            updated_at BIGINT NOT NULL
        )");
    } else {
        // pgsql and other PDO drivers.
        $pdo->exec("CREATE TABLE IF NOT EXISTS kv_store (
            k VARCHAR(191) PRIMARY KEY,
            v TEXT NOT NULL,
            updated_at BIGINT NOT NULL
        )");
    }

    $pdo->exec("CREATE TABLE IF NOT EXISTS app_devices (
        device_id VARCHAR(64) PRIMARY KEY,
        auth_uid VARCHAR(128) NOT NULL,
        android_id_hash CHAR(64) NOT NULL,
        install_id VARCHAR(64) NOT NULL,
        package_name VARCHAR(128) NOT NULL,
        signing_cert_sha256 CHAR(64) NOT NULL,
        app_version VARCHAR(50) NOT NULL,
        status VARCHAR(16) NOT NULL,
        integrity_level VARCHAR(16) NOT NULL,
        last_integrity_json TEXT NOT NULL,
        first_seen_at BIGINT NOT NULL,
        last_seen_at BIGINT NOT NULL,
        last_ip VARCHAR(45) NOT NULL,
        note TEXT NOT NULL
    )");

    $pdo->exec("CREATE TABLE IF NOT EXISTS app_device_credentials (
        credential_id CHAR(32) PRIMARY KEY,
        device_id VARCHAR(64) NOT NULL,
        protocol VARCHAR(16) NOT NULL,
        server_id VARCHAR(64) NOT NULL,
        external_ref VARCHAR(64) NOT NULL,
        username VARCHAR(64) NOT NULL,
        secret_enc TEXT NOT NULL,
        secret_hash CHAR(64) NOT NULL,
        secret_preview VARCHAR(12) NOT NULL,
        payload_json TEXT NOT NULL,
        status VARCHAR(16) NOT NULL,
        issued_at BIGINT NOT NULL,
        expires_at BIGINT NOT NULL,
        last_used_at BIGINT NOT NULL,
        revoked_at BIGINT NOT NULL,
        revoked_reason VARCHAR(64) NOT NULL,
        parent_credential_id CHAR(32) NOT NULL
    )");

    $pdo->exec("CREATE TABLE IF NOT EXISTS app_device_events (
        event_id CHAR(32) PRIMARY KEY,
        device_id VARCHAR(64) NOT NULL,
        event_type VARCHAR(64) NOT NULL,
        ip_address VARCHAR(45) NOT NULL,
        detail_json TEXT NOT NULL,
        created_at BIGINT NOT NULL
    )");

    $pdo->exec("CREATE TABLE IF NOT EXISTS app_device_sessions (
        session_token_hash CHAR(64) PRIMARY KEY,
        device_id VARCHAR(64) NOT NULL,
        issued_at BIGINT NOT NULL,
        expires_at BIGINT NOT NULL,
        last_seen_at BIGINT NOT NULL,
        revoked_at BIGINT NOT NULL
    )");
}

function getStoragePdo() {
    global $STORAGE_INIT_ERROR;
    static $pdo = null;
    static $initDone = false;
    if ($initDone) return $pdo;
    $initDone = true;

    if (!sqlStorageRequested()) {
        $STORAGE_INIT_ERROR = '';
        return null;
    }
    if (!class_exists('PDO')) {
        $STORAGE_INIT_ERROR = 'PDO extension not available';
        debugLog('PDO extension not available, using JSON storage fallback');
        return null;
    }

    $dsn = resolveStorageDsn();
    if ($dsn === '') {
        $STORAGE_INIT_ERROR = 'Storage DSN is empty';
        return null;
    }

    try {
        $user = DB_USER !== '' ? DB_USER : null;
        $pass = DB_PASS !== '' ? DB_PASS : null;
        $pdo = new PDO($dsn, $user, $pass, [
            PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
            PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
        ]);
        initStorageSchema($pdo);
        $STORAGE_INIT_ERROR = '';
        return $pdo;
    } catch (Throwable $e) {
        $STORAGE_INIT_ERROR = $e->getMessage();
        debugLog('SQL storage init failed, falling back to JSON', ['error' => $e->getMessage(), 'dsn' => $dsn]);
        $pdo = null;
        return null;
    }
}

function sqlReadStoreJson($storeKey) {
    $pdo = getStoragePdo();
    if (!$pdo) return null;
    try {
        $stmt = $pdo->prepare('SELECT v FROM kv_store WHERE k = :k LIMIT 1');
        $stmt->execute([':k' => $storeKey]);
        $row = $stmt->fetch();
        if (!$row || !isset($row['v'])) return null;
        $decoded = json_decode((string)$row['v'], true);
        return is_array($decoded) ? $decoded : null;
    } catch (Throwable $e) {
        debugLog('sqlReadStoreJson failed', ['key' => $storeKey, 'error' => $e->getMessage()]);
        return null;
    }
}

function sqlWriteStoreJson($storeKey, $data) {
    $pdo = getStoragePdo();
    if (!$pdo) return false;
    try {
        $payload = json_encode($data, JSON_UNESCAPED_SLASHES);
        if (!is_string($payload)) return false;
        $now = (int)(microtime(true) * 1000);
        $driver = strtolower((string)$pdo->getAttribute(PDO::ATTR_DRIVER_NAME));
        if ($driver === 'mysql') {
            $sql = 'INSERT INTO kv_store (k, v, updated_at) VALUES (:k, :v, :u)
                    ON DUPLICATE KEY UPDATE v = VALUES(v), updated_at = VALUES(updated_at)';
        } else {
            $sql = 'INSERT INTO kv_store (k, v, updated_at) VALUES (:k, :v, :u)
                    ON CONFLICT(k) DO UPDATE SET v = excluded.v, updated_at = excluded.updated_at';
        }
        $stmt = $pdo->prepare($sql);
        return $stmt->execute([':k' => $storeKey, ':v' => $payload, ':u' => $now]);
    } catch (Throwable $e) {
        debugLog('sqlWriteStoreJson failed', ['key' => $storeKey, 'error' => $e->getMessage()]);
        return false;
    }
}

function storeKeyFromPath($path) {
    $base = strtolower((string)basename((string)$path));
    if ($base === '') $base = 'store';
    $base = preg_replace('/[^a-z0-9]+/', '_', $base);
    return 'json_' . trim($base, '_');
}

function readSharedStoreJson($storeKey, $path, $fallback = [], $asList = false) {
    $data = sqlReadStoreJson($storeKey);
    if (is_array($data)) {
        return $asList ? array_values($data) : $data;
    }

    $fileData = readJsonFileSafe($path, $fallback);
    if (!is_array($fileData)) $fileData = $fallback;
    if ($asList) $fileData = array_values($fileData);

    // First read on SQL backend: prime DB from existing JSON file.
    if (sqlStorageRequested() && getStoragePdo() && is_array($fileData) && !empty($fileData)) {
        sqlWriteStoreJson($storeKey, $fileData);
    }
    return $fileData;
}

function writeSharedStoreJson($storeKey, $path, $data, $asList = false) {
    if (!is_array($data)) $data = [];
    if ($asList) $data = array_values($data);

    $sqlOk = null;
    if (sqlStorageRequested()) {
        $sqlOk = sqlWriteStoreJson($storeKey, $data);
    }

    $fileOk = true;
    if (!sqlStorageRequested() || STORAGE_FILE_MIRROR || $sqlOk === false) {
        $fileOk = @file_put_contents(
            $path,
            json_encode($data, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES),
            LOCK_EX
        ) !== false;
    }

    if (sqlStorageRequested()) {
        if ($sqlOk === true) return true;
        return $fileOk;
    }
    return $fileOk;
}

function getStorageStatusInfo() {
    global $STORAGE_INIT_ERROR;
    $pdo = getStoragePdo();
    $dsn = resolveStorageDsn();
    $maskedDsn = $dsn;
    if (stripos($maskedDsn, 'mysql:') === 0) {
        $maskedDsn = preg_replace('/password=([^;]+)/i', 'password=***', $maskedDsn);
    }
    return [
        'requested' => sqlStorageRequested(),
        'backend' => STORAGE_BACKEND,
        'dsn' => $maskedDsn,
        'active' => $pdo ? true : false,
        'driver' => $pdo ? strtolower((string)$pdo->getAttribute(PDO::ATTR_DRIVER_NAME)) : 'json',
        'fileMirror' => STORAGE_FILE_MIRROR,
        'pdoAvailable' => class_exists('PDO'),
        'error' => (!$pdo && sqlStorageRequested()) ? (string)$STORAGE_INIT_ERROR : ''
    ];
}

function migrateJsonStoresToSql() {
    $pdo = getStoragePdo();
    if (!$pdo) {
        $status = getStorageStatusInfo();
        $detail = isset($status['error']) ? trim((string)$status['error']) : '';
        return [
            'ok' => false,
            'error' => 'sql storage not available',
            'detail' => $detail !== '' ? $detail : 'Unable to initialize SQL storage'
        ];
    }
    $stores = [
        ['path' => CLOUD_CONFIGS_FILE, 'list' => false],
        ['path' => USER_COINS_FILE, 'list' => false],
        ['path' => REDEEMED_CODES_FILE, 'list' => false],
        ['path' => COIN_CODES_FILE, 'list' => false],
        ['path' => COIN_LEDGER_FILE, 'list' => true],
        ['path' => SUPPORT_REQUESTS_FILE, 'list' => true],
        ['path' => ADMIN_UI_STATE_FILE, 'list' => false],
        ['path' => APP_NONCE_CACHE_FILE, 'list' => false],
        ['path' => APP_RATE_LIMIT_FILE, 'list' => false]
    ];
    $migrated = [];
    $failed = [];

    foreach ($stores as $s) {
        $path = (string)$s['path'];
        $asList = !empty($s['list']);
        $data = readJsonFileSafe($path, []);
        if (!is_array($data)) $data = [];
        if ($asList) $data = array_values($data);
        $ok = sqlWriteStoreJson(storeKeyFromPath($path), $data);
        if ($ok) {
            $migrated[] = basename($path);
        } else {
            $failed[] = basename($path);
        }
    }

    return [
        'ok' => empty($failed),
        'migrated' => $migrated,
        'failed' => $failed
    ];
}

function isLocalRequest() {
    $host = strtolower((string)($_SERVER['HTTP_HOST'] ?? ''));
    return strpos($host, 'localhost') !== false || strpos($host, '127.0.0.1') !== false;
}

function enforceCriticalConfig() {
    if (ALLOW_INSECURE_DEFAULTS && isLocalRequest()) {
        debugLog('WARNING: ALLOW_INSECURE_DEFAULTS enabled for local request');
        return;
    }
    $missing = [];
    if (JWT_SECRET === '') $missing[] = 'JWT_SECRET';
    if (ADMIN_USER === '') $missing[] = 'ADMIN_USER';
    if (ADMIN_PASS_HASH === '') $missing[] = 'ADMIN_PASS_HASH';
    if (APP_SIGNING_SECRET === '') $missing[] = 'APP_SIGNING_SECRET';
    if (APP_SESSION_SECRET === '') $missing[] = 'APP_SESSION_SECRET';

    if (!empty($missing)) {
        debugLog('Missing critical env config', $missing);
        http_response_code(500);
        echo json_encode([
            'error' => 'server_misconfigured',
            'message' => 'Critical environment variables are missing',
            'missing' => $missing
        ]);
        exit;
    }
}

enforceCriticalConfig();

// ========================================
// JWT FUNCTIONS
// ========================================
function base64UrlEncode($data) {
    return rtrim(strtr(base64_encode($data), '+/', '-_'), '=');
}

function base64UrlDecode($data) {
    return base64_decode(strtr($data, '-_', '+/'));
}

function normalizeSha256Digest($value) {
    $raw = trim((string)$value);
    if ($raw === '') return '';

    // Accept colon/dash/plain hex forms.
    $hex = preg_replace('/[^a-fA-F0-9]/', '', $raw);
    if (is_string($hex) && strlen($hex) === 64 && ctype_xdigit($hex)) {
        return strtoupper($hex);
    }

    // Accept base64url/base64 encoded 32-byte digest forms.
    $b64 = strtr($raw, '-_', '+/');
    $pad = strlen($b64) % 4;
    if ($pad > 0) {
        $b64 .= str_repeat('=', 4 - $pad);
    }
    $bin = base64_decode($b64, true);
    if (!is_string($bin) || strlen($bin) !== 32) {
        return '';
    }
    return strtoupper(bin2hex($bin));
}

function formatSha256HexWithColons($hex) {
    $h = strtoupper(trim((string)$hex));
    if (strlen($h) !== 64 || !ctype_xdigit($h)) return $h;
    return implode(':', str_split($h, 2));
}

function createJWT($username) {
    $header = json_encode(['typ' => 'JWT', 'alg' => 'HS256']);
    $payload = json_encode(['user' => $username, 'iat' => time(), 'exp' => time() + TOKEN_EXPIRY]);
    $base64UrlHeader = base64UrlEncode($header);
    $base64UrlPayload = base64UrlEncode($payload);
    $signature = hash_hmac('sha256', $base64UrlHeader . "." . $base64UrlPayload, JWT_SECRET, true);
    return $base64UrlHeader . "." . $base64UrlPayload . "." . base64UrlEncode($signature);
}

function verifyJWT($jwt) {
    debugLog("=== JWT VERIFICATION START ===");
    debugLog("Token prefix: " . substr($jwt, 0, 16) . "...");
    
    $parts = explode('.', $jwt);
    if (count($parts) !== 3) {
        debugLog("ERROR: Token has " . count($parts) . " parts, expected 3");
        return false;
    }
    
    list($header, $payload, $signature) = $parts;
    
    $validSig = base64UrlEncode(hash_hmac('sha256', $header . "." . $payload, JWT_SECRET, true));
    
    if (!hash_equals($validSig, $signature)) {
        debugLog("ERROR: Signature mismatch!");
        return false;
    }
    
    debugLog("âœ“ Signature valid");
    
    $data = json_decode(base64UrlDecode($payload), true);
    if (!is_array($data)) {
        debugLog("ERROR: Invalid token payload");
        return false;
    }
    debugLog("Decoded payload", $data);
    
    if (!isset($data['exp'])) {
        debugLog("ERROR: No expiry in token");
        return false;
    }
    
    debugLog("Token expires at: " . date('Y-m-d H:i:s', $data['exp']));
    debugLog("Current time: " . date('Y-m-d H:i:s', time()));
    
    if ($data['exp'] < time()) {
        debugLog("ERROR: Token expired!");
        return false;
    }
    
    debugLog("âœ“ Token valid, user: " . ($data['user'] ?? 'unknown'));
    debugLog("=== JWT VERIFICATION END ===");
    
    return $data;
}

function requireAuth() {
    $headers = getallheaders();
    $authHeader = $headers['Authorization'] ?? '';
    $maskedAuth = preg_replace('/Bearer\s+([A-Za-z0-9\-_\.]{8})[A-Za-z0-9\-_\.]*/i', 'Bearer $1...', $authHeader);
    debugLog("Auth header: " . $maskedAuth);
    if (!preg_match('/Bearer\s+(.*)$/i', $authHeader, $matches)) {
        http_response_code(401);
        echo json_encode(['error' => 'Missing authorization']);
        exit;
    }
    $payload = verifyJWT($matches[1]);
    if (!$payload) {
        http_response_code(401);
        echo json_encode(['error' => 'Invalid token']);
        exit;
    }
    return $payload;
}

function getHeaderValue($headers, $name) {
    foreach ($headers as $k => $v) {
        if (strtolower($k) === strtolower($name)) {
            return $v;
        }
    }
    return null;
}

function denyAppAuth($reason, $details = []) {
    debugLog("APP AUTH DENY: " . $reason, $details);
    http_response_code(401);
    echo json_encode(['error' => 'Unauthorized app request', 'reason' => $reason]);
    exit;
}

function getClientIpAddress() {
    $forwarded = (string)($_SERVER['HTTP_X_FORWARDED_FOR'] ?? '');
    if ($forwarded !== '') {
        $parts = explode(',', $forwarded);
        $first = trim((string)($parts[0] ?? ''));
        if ($first !== '') return $first;
    }
    $realIp = trim((string)($_SERVER['HTTP_X_REAL_IP'] ?? ''));
    if ($realIp !== '') return $realIp;
    return trim((string)($_SERVER['REMOTE_ADDR'] ?? '0.0.0.0'));
}

function getCurrentActionName() {
    $a = strtolower(trim((string)($_GET['action'] ?? '')));
    if ($a !== '') return $a;
    $uri = (string)($_SERVER['REQUEST_URI'] ?? '');
    if ($uri === '') return '';
    $q = parse_url($uri, PHP_URL_QUERY);
    if (!$q) return '';
    parse_str($q, $params);
    return strtolower(trim((string)($params['action'] ?? '')));
}

function loadNonceCacheStore() {
    return loadJsonMapStore(APP_NONCE_CACHE_FILE);
}

function saveNonceCacheStore($cache) {
    return saveJsonMapStore(APP_NONCE_CACHE_FILE, $cache);
}

function loadRateLimitStore() {
    return readSharedStoreJson('app_rate_limit', APP_RATE_LIMIT_FILE, [], false);
}

function saveRateLimitStore($store) {
    return writeSharedStoreJson('app_rate_limit', APP_RATE_LIMIT_FILE, $store, false);
}

function enforceSimpleRateLimit($bucket, $identifier, $limit, $windowSeconds, $errorCode = 'rate_limited', $httpStatus = 429) {
    $limit = (int)$limit;
    $windowSeconds = (int)$windowSeconds;
    if ($limit <= 0 || $windowSeconds <= 0) return;

    $id = trim((string)$identifier);
    if ($id === '') $id = 'unknown';
    $now = time();
    $resetAt = $now + $windowSeconds;

    $store = loadRateLimitStore();
    if (!is_array($store)) $store = [];
    if (!isset($store[$bucket]) || !is_array($store[$bucket])) $store[$bucket] = [];
    $bucketStore = $store[$bucket];

    foreach ($bucketStore as $k => $entry) {
        $entryResetAt = (int)($entry['resetAt'] ?? 0);
        if ($entryResetAt <= $now) {
            unset($bucketStore[$k]);
        }
    }

    $entryKey = hash('sha256', $bucket . '|' . $id);
    $entry = isset($bucketStore[$entryKey]) && is_array($bucketStore[$entryKey]) ? $bucketStore[$entryKey] : [
        'count' => 0,
        'resetAt' => $resetAt,
        'firstAt' => $now
    ];

    if ((int)($entry['resetAt'] ?? 0) <= $now) {
        $entry = [
            'count' => 0,
            'resetAt' => $resetAt,
            'firstAt' => $now
        ];
    }

    $count = (int)($entry['count'] ?? 0);
    if ($count >= $limit) {
        $retryAfter = max(1, (int)($entry['resetAt'] ?? $resetAt) - $now);
        $store[$bucket] = $bucketStore;
        saveRateLimitStore($store);
        debugLog('Rate limit exceeded', ['bucket' => $bucket, 'id' => $id, 'limit' => $limit, 'retryAfter' => $retryAfter]);
        http_response_code($httpStatus);
        header('Retry-After: ' . $retryAfter);
        echo json_encode(['error' => $errorCode, 'retryAfter' => $retryAfter]);
        exit;
    }

    $entry['count'] = $count + 1;
    $entry['resetAt'] = (int)($entry['resetAt'] ?? $resetAt);
    $bucketStore[$entryKey] = $entry;

    if (count($bucketStore) > 2500) {
        uasort($bucketStore, function ($a, $b) {
            return (int)($a['resetAt'] ?? 0) <=> (int)($b['resetAt'] ?? 0);
        });
        $bucketStore = array_slice($bucketStore, -2000, null, true);
    }

    $store[$bucket] = $bucketStore;
    saveRateLimitStore($store);
}

function parseAppVersionCode($raw) {
    if ($raw === null) return 0;
    $raw = trim((string)$raw);
    if ($raw === '') return 0;
    if (ctype_digit($raw)) return (int)$raw;
    if (preg_match('/(\d+)$/', $raw, $m)) return (int)$m[1];
    return 0;
}

function resolveNewUserBonusCoinsFromPolicy($policy = null) {
    if (!is_array($policy)) $policy = getAppPolicySettings();
    $enabledDefault = APP_NEW_USER_BONUS_COINS > 0;
    $enabled = toBool($policy['new_user_bonus_enabled'] ?? $enabledDefault, $enabledDefault);
    $coins = (int)($policy['new_user_bonus_coins'] ?? APP_NEW_USER_BONUS_COINS);
    if ($coins < 0) $coins = 0;
    return $enabled ? $coins : 0;
}

function getAppPolicySettings() {
    $file = readJsonFileSafe(ADMIN_SETTINGS_FILE, []);
    $settings = [
        'force_update_enabled' => toBool($file['force_update_enabled'] ?? (APP_MIN_VERSION_CODE > 0), (APP_MIN_VERSION_CODE > 0)),
        'min_version_code' => (int)($file['min_version_code'] ?? APP_MIN_VERSION_CODE),
        'min_version_name' => trim((string)($file['min_version_name'] ?? APP_MIN_VERSION_NAME)),
        'playstore_url' => trim((string)($file['playstore_url'] ?? '')),
        'require_app_session' => toBool($file['require_app_session'] ?? APP_REQUIRE_SESSION, APP_REQUIRE_SESSION),
        'require_signed_imports' => toBool($file['require_signed_imports'] ?? REQUIRE_SIGNED_IMPORTS, REQUIRE_SIGNED_IMPORTS),
        'strict_security_mode' => toBool($file['strict_security_mode'] ?? APP_STRICT_SECURITY_MODE, APP_STRICT_SECURITY_MODE),
        'allow_coin_sync' => toBool($file['allow_coin_sync'] ?? APP_ALLOW_COIN_SYNC, APP_ALLOW_COIN_SYNC),
        'new_user_bonus_enabled' => toBool($file['new_user_bonus_enabled'] ?? (APP_NEW_USER_BONUS_COINS > 0), (APP_NEW_USER_BONUS_COINS > 0)),
        'new_user_bonus_coins' => (int)($file['new_user_bonus_coins'] ?? APP_NEW_USER_BONUS_COINS),
        'coin_sync_rate_window_seconds' => (int)($file['coin_sync_rate_window_seconds'] ?? APP_RATE_COIN_SYNC_WINDOW_SECONDS),
        'coin_sync_rate_device_max' => (int)($file['coin_sync_rate_device_max'] ?? APP_RATE_COIN_SYNC_DEVICE_MAX),
        'coin_sync_max_increase' => (int)($file['coin_sync_max_increase'] ?? APP_COIN_SYNC_MAX_INCREASE),
        'coin_sync_max_decrease' => (int)($file['coin_sync_max_decrease'] ?? APP_COIN_SYNC_MAX_DECREASE),
        'allow_legacy_redeem_codes' => toBool($file['allow_legacy_redeem_codes'] ?? APP_ALLOW_LEGACY_REDEEM_CODES, APP_ALLOW_LEGACY_REDEEM_CODES),
        'max_legacy_redeem_coins' => (int)($file['max_legacy_redeem_coins'] ?? APP_MAX_LEGACY_REDEEM_COINS),
        'debug_log_enabled' => toBool($file['debug_log_enabled'] ?? $GLOBALS['DEBUG_LOG_ENABLED'], $GLOBALS['DEBUG_LOG_ENABLED']),
        'default_server_username' => trim((string)($file['default_server_username'] ?? '')),
        'default_server_password' => trim((string)($file['default_server_password'] ?? '')),
        'provisioning_enabled' => toBool($file['provisioning_enabled'] ?? PROVISIONING_ENABLED, PROVISIONING_ENABLED),
        'provisioning_base_url' => trim((string)($file['provisioning_base_url'] ?? PROVISIONING_BASE_URL)),
        'provisioning_api_key' => trim((string)($file['provisioning_api_key'] ?? PROVISIONING_API_KEY)),
        'provisioning_server_id' => trim((string)($file['provisioning_server_id'] ?? PROVISIONING_SERVER_ID)),
        'provisioning_default_protocol' => strtolower(trim((string)($file['provisioning_default_protocol'] ?? PROVISIONING_DEFAULT_PROTOCOL))),
        'provisioning_ssh_expiry_days' => (int)($file['provisioning_ssh_expiry_days'] ?? PROVISIONING_SSH_EXPIRY_DAYS),
        'provisioning_ssh_limit_ip' => (int)($file['provisioning_ssh_limit_ip'] ?? PROVISIONING_SSH_LIMIT_IP),
        'provisioning_ssh_quota_gb' => (int)($file['provisioning_ssh_quota_gb'] ?? PROVISIONING_SSH_QUOTA_GB),
        'provisioning_require_integrity' => toBool($file['provisioning_require_integrity'] ?? PROVISIONING_REQUIRE_INTEGRITY, PROVISIONING_REQUIRE_INTEGRITY)
    ];
    if ($settings['min_version_code'] < 0) $settings['min_version_code'] = 0;
    if ($settings['max_legacy_redeem_coins'] < 1) $settings['max_legacy_redeem_coins'] = 1;
    if ($settings['new_user_bonus_coins'] < 0) $settings['new_user_bonus_coins'] = 0;
    if ($settings['coin_sync_rate_window_seconds'] < 15) $settings['coin_sync_rate_window_seconds'] = 15;
    if ($settings['coin_sync_rate_device_max'] < 3) $settings['coin_sync_rate_device_max'] = 3;
    if ($settings['coin_sync_max_increase'] < 0) $settings['coin_sync_max_increase'] = 0;
    if ($settings['coin_sync_max_decrease'] < 0) $settings['coin_sync_max_decrease'] = 0;
    if (!in_array($settings['provisioning_default_protocol'], ['ssh', 'slowdns', 'vmess', 'vless', 'trojan', 'openvpn', 'hysteria'], true)) {
        $settings['provisioning_default_protocol'] = 'ssh';
    }
    if ($settings['provisioning_ssh_expiry_days'] < 1) $settings['provisioning_ssh_expiry_days'] = 1;
    if ($settings['provisioning_ssh_limit_ip'] < 1) $settings['provisioning_ssh_limit_ip'] = 1;
    if ($settings['provisioning_ssh_quota_gb'] < 0) $settings['provisioning_ssh_quota_gb'] = 0;
    if ($settings['strict_security_mode']) {
        $settings['require_app_session'] = true;
        $settings['require_signed_imports'] = true;
    }
    return $settings;
}

function saveAppPolicySettings($input) {
    $payload = is_array($input) ? $input : [];
    $current = getAppPolicySettings();

    $settings = [
        'force_update_enabled' => array_key_exists('force_update_enabled', $payload)
            ? toBool($payload['force_update_enabled'], (bool)$current['force_update_enabled'])
            : (bool)$current['force_update_enabled'],
        'min_version_code' => array_key_exists('min_version_code', $payload)
            ? max(0, (int)$payload['min_version_code'])
            : max(0, (int)$current['min_version_code']),
        'min_version_name' => array_key_exists('min_version_name', $payload)
            ? trim((string)$payload['min_version_name'])
            : trim((string)$current['min_version_name']),
        'playstore_url' => array_key_exists('playstore_url', $payload)
            ? trim((string)$payload['playstore_url'])
            : trim((string)$current['playstore_url']),
        'require_app_session' => array_key_exists('require_app_session', $payload)
            ? toBool($payload['require_app_session'], (bool)$current['require_app_session'])
            : (bool)$current['require_app_session'],
        'require_signed_imports' => array_key_exists('require_signed_imports', $payload)
            ? toBool($payload['require_signed_imports'], (bool)$current['require_signed_imports'])
            : (bool)$current['require_signed_imports'],
        'strict_security_mode' => array_key_exists('strict_security_mode', $payload)
            ? toBool($payload['strict_security_mode'], (bool)$current['strict_security_mode'])
            : (bool)$current['strict_security_mode'],
        'allow_coin_sync' => array_key_exists('allow_coin_sync', $payload)
            ? toBool($payload['allow_coin_sync'], (bool)$current['allow_coin_sync'])
            : (bool)$current['allow_coin_sync'],
        'new_user_bonus_enabled' => array_key_exists('new_user_bonus_enabled', $payload)
            ? toBool($payload['new_user_bonus_enabled'], (bool)$current['new_user_bonus_enabled'])
            : (bool)$current['new_user_bonus_enabled'],
        'new_user_bonus_coins' => array_key_exists('new_user_bonus_coins', $payload)
            ? max(0, (int)$payload['new_user_bonus_coins'])
            : max(0, (int)$current['new_user_bonus_coins']),
        'coin_sync_rate_window_seconds' => array_key_exists('coin_sync_rate_window_seconds', $payload)
            ? max(15, (int)$payload['coin_sync_rate_window_seconds'])
            : max(15, (int)$current['coin_sync_rate_window_seconds']),
        'coin_sync_rate_device_max' => array_key_exists('coin_sync_rate_device_max', $payload)
            ? max(3, (int)$payload['coin_sync_rate_device_max'])
            : max(3, (int)$current['coin_sync_rate_device_max']),
        'coin_sync_max_increase' => array_key_exists('coin_sync_max_increase', $payload)
            ? max(0, (int)$payload['coin_sync_max_increase'])
            : max(0, (int)$current['coin_sync_max_increase']),
        'coin_sync_max_decrease' => array_key_exists('coin_sync_max_decrease', $payload)
            ? max(0, (int)$payload['coin_sync_max_decrease'])
            : max(0, (int)$current['coin_sync_max_decrease']),
        'allow_legacy_redeem_codes' => array_key_exists('allow_legacy_redeem_codes', $payload)
            ? toBool($payload['allow_legacy_redeem_codes'], (bool)$current['allow_legacy_redeem_codes'])
            : (bool)$current['allow_legacy_redeem_codes'],
        'max_legacy_redeem_coins' => array_key_exists('max_legacy_redeem_coins', $payload)
            ? max(1, (int)$payload['max_legacy_redeem_coins'])
            : max(1, (int)$current['max_legacy_redeem_coins']),
        'debug_log_enabled' => array_key_exists('debug_log_enabled', $payload)
            ? toBool($payload['debug_log_enabled'], (bool)$current['debug_log_enabled'])
            : (bool)$current['debug_log_enabled'],
        'default_server_username' => array_key_exists('default_server_username', $payload)
            ? trim((string)$payload['default_server_username'])
            : trim((string)$current['default_server_username']),
        'default_server_password' => array_key_exists('default_server_password', $payload)
            ? trim((string)$payload['default_server_password'])
            : trim((string)$current['default_server_password']),
        'provisioning_enabled' => array_key_exists('provisioning_enabled', $payload)
            ? toBool($payload['provisioning_enabled'], (bool)$current['provisioning_enabled'])
            : (bool)$current['provisioning_enabled'],
        'provisioning_base_url' => array_key_exists('provisioning_base_url', $payload)
            ? trim((string)$payload['provisioning_base_url'])
            : trim((string)$current['provisioning_base_url']),
        'provisioning_api_key' => array_key_exists('provisioning_api_key', $payload)
            ? trim((string)$payload['provisioning_api_key'])
            : trim((string)$current['provisioning_api_key']),
        'provisioning_server_id' => array_key_exists('provisioning_server_id', $payload)
            ? trim((string)$payload['provisioning_server_id'])
            : trim((string)$current['provisioning_server_id']),
        'provisioning_default_protocol' => array_key_exists('provisioning_default_protocol', $payload)
            ? strtolower(trim((string)$payload['provisioning_default_protocol']))
            : strtolower(trim((string)$current['provisioning_default_protocol'])),
        'provisioning_ssh_expiry_days' => array_key_exists('provisioning_ssh_expiry_days', $payload)
            ? max(1, (int)$payload['provisioning_ssh_expiry_days'])
            : max(1, (int)$current['provisioning_ssh_expiry_days']),
        'provisioning_ssh_limit_ip' => array_key_exists('provisioning_ssh_limit_ip', $payload)
            ? max(1, (int)$payload['provisioning_ssh_limit_ip'])
            : max(1, (int)$current['provisioning_ssh_limit_ip']),
        'provisioning_ssh_quota_gb' => array_key_exists('provisioning_ssh_quota_gb', $payload)
            ? max(0, (int)$payload['provisioning_ssh_quota_gb'])
            : max(0, (int)$current['provisioning_ssh_quota_gb']),
        'provisioning_require_integrity' => array_key_exists('provisioning_require_integrity', $payload)
            ? toBool($payload['provisioning_require_integrity'], (bool)$current['provisioning_require_integrity'])
            : (bool)$current['provisioning_require_integrity']
    ];
    if ($settings['playstore_url'] !== '' && !filter_var($settings['playstore_url'], FILTER_VALIDATE_URL)) {
        return ['ok' => false, 'error' => 'Invalid playstore_url'];
    }
    if ($settings['provisioning_base_url'] !== '' && !filter_var($settings['provisioning_base_url'], FILTER_VALIDATE_URL)) {
        return ['ok' => false, 'error' => 'Invalid provisioning_base_url'];
    }
    if (!in_array($settings['provisioning_default_protocol'], ['ssh', 'slowdns', 'vmess', 'vless', 'trojan', 'openvpn', 'hysteria'], true)) {
        return ['ok' => false, 'error' => 'Invalid provisioning_default_protocol'];
    }
    if ($settings['strict_security_mode']) {
        $settings['require_app_session'] = true;
        $settings['require_signed_imports'] = true;
    }
    $ok = @file_put_contents(
        ADMIN_SETTINGS_FILE,
        json_encode($settings, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES),
        LOCK_EX
    );
    if ($ok === false) {
        return ['ok' => false, 'error' => 'Failed to save app policy file'];
    }
    return ['ok' => true, 'settings' => $settings];
}

function normalizeImportPayload($payload) {
    $obj = is_array($payload) ? $payload : [];
    return [
        'ExpireDate' => (int)($obj['ExpireDate'] ?? 0),
        'RootBlock' => toBool($obj['RootBlock'] ?? false, false),
        'MobileData' => toBool($obj['MobileData'] ?? false, false),
        'Message' => (string)($obj['Message'] ?? ''),
        'Config' => (string)($obj['Config'] ?? ''),
        'Server' => (string)($obj['Server'] ?? ''),
        'DeviceID' => (string)($obj['DeviceID'] ?? ''),
        'PSInstall' => toBool($obj['PSInstall'] ?? false, false),
        'isBlockVPN' => toBool($obj['isBlockVPN'] ?? false, false),
        'isBlockAppList' => toBool($obj['isBlockAppList'] ?? false, false),
        'ConfigAppBlockList' => (string)($obj['ConfigAppBlockList'] ?? ''),
        'isXposed' => toBool($obj['isXposed'] ?? false, false),
    ];
}

function importSignatureCanonical($payload, $sigTs, $sigKid, $sigV = 1) {
    $p = normalizeImportPayload($payload);
    $parts = [
        (string)$p['ExpireDate'],
        $p['RootBlock'] ? '1' : '0',
        $p['MobileData'] ? '1' : '0',
        $p['Message'],
        $p['Config'],
        $p['Server'],
        $p['DeviceID'],
        $p['PSInstall'] ? '1' : '0',
        $p['isBlockVPN'] ? '1' : '0',
        $p['isBlockAppList'] ? '1' : '0',
        $p['ConfigAppBlockList'],
        $p['isXposed'] ? '1' : '0',
        (string)((int)$sigTs),
        (string)$sigKid,
        (string)((int)$sigV)
    ];
    return implode("\n", $parts);
}

function loadImportSigningPrivateKey() {
    $path = trim((string)IMPORT_SIGNING_PRIVATE_KEY_FILE);
    if ($path === '') return null;
    if (!preg_match('/^(\/|[A-Za-z]:[\\\\\\/])/', $path)) {
        $path = __DIR__ . '/' . ltrim($path, '/\\');
    }
    if (!file_exists($path)) return null;
    $pem = @file_get_contents($path);
    if (!is_string($pem) || trim($pem) === '') return null;
    $key = openssl_pkey_get_private($pem);
    if (!$key) return null;
    return $key;
}

function signImportPayload($payload) {
    $key = loadImportSigningPrivateKey();
    if (!$key) {
        return ['ok' => false, 'error' => 'Import signing key not configured'];
    }
    $sigTs = time();
    $sigV = 1;
    $sigKid = IMPORT_SIGNING_KEY_ID;
    $canonical = importSignatureCanonical($payload, $sigTs, $sigKid, $sigV);
    $ok = openssl_sign($canonical, $rawSig, $key, OPENSSL_ALGO_SHA256);
    if (!$ok || !isset($rawSig)) {
        return ['ok' => false, 'error' => 'Failed to sign import payload'];
    }
    $signed = normalizeImportPayload($payload);
    $signed['SigAlg'] = 'RS256';
    $signed['SigTs'] = $sigTs;
    $signed['SigKid'] = $sigKid;
    $signed['SigV'] = $sigV;
    $signed['Sig'] = base64UrlEncode($rawSig);
    return ['ok' => true, 'payload' => $signed];
}

function loadCloudConfigs() {
    return loadJsonMapStore(CLOUD_CONFIGS_FILE);
}

function saveCloudConfigs($configs) {
    return saveJsonMapStore(CLOUD_CONFIGS_FILE, $configs);
}

function generateCloudConfigKey($configs) {
    $chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    for ($attempt = 0; $attempt < 20; $attempt++) {
        $key = '';
        for ($i = 0; $i < 8; $i++) {
            $key .= $chars[random_int(0, strlen($chars) - 1)];
        }
        if (!isset($configs[$key])) return $key;
    }
    return strtoupper(substr(bin2hex(random_bytes(8)), 0, 8));
}

function buildCloudConfigRecord($config, $configName, $autoDelete5Min, $deleteAfterFirstAccess) {
    $now = (int)(microtime(true) * 1000);
    $record = [
        'Config' => (string)$config,
        'CreatedAt' => $now,
        'AutoDelete5Min' => (bool)$autoDelete5Min,
        'DeleteAfterFirstAccess' => (bool)$deleteAfterFirstAccess,
        'AccessCount' => 0,
        'ConfigName' => (string)$configName,
        'Deleted' => false
    ];
    if ($record['AutoDelete5Min']) {
        $record['ExpiresAt'] = $now + (5 * 60 * 1000);
    }
    return $record;
}

function denyAppUpgradeRequired($currentVersionCode, $policy = null) {
    if (!is_array($policy)) $policy = getAppPolicySettings();
    $minCode = (int)($policy['min_version_code'] ?? APP_MIN_VERSION_CODE);
    $minName = (string)($policy['min_version_name'] ?? APP_MIN_VERSION_NAME);
    $storeUrl = (string)($policy['playstore_url'] ?? '');
    $message = 'App update required';
    if ($minName !== '') {
        $message .= ': minimum supported version is ' . $minName;
    } elseif ($minCode > 0) {
        $message .= ': minimum supported build is ' . $minCode;
    }
    debugLog('APP UPDATE REQUIRED', [
        'required' => $minCode,
        'current' => $currentVersionCode
    ]);
    http_response_code(426);
    echo json_encode([
        'error' => 'app_update_required',
        'message' => $message,
        'minVersionCode' => $minCode,
        'minVersionName' => $minName,
        'playStoreUrl' => $storeUrl,
        'currentVersionCode' => (int)$currentVersionCode
    ]);
    exit;
}

function createAppSessionJWT($deviceId, $integrity = []) {
    $header = json_encode(['typ' => 'JWT', 'alg' => 'HS256']);
    $payload = json_encode([
        'sub' => $deviceId,
        'iat' => time(),
        'exp' => time() + APP_SESSION_EXPIRY,
        'int' => $integrity
    ]);
    $base64UrlHeader = base64UrlEncode($header);
    $base64UrlPayload = base64UrlEncode($payload);
    $signature = hash_hmac('sha256', $base64UrlHeader . "." . $base64UrlPayload, APP_SESSION_SECRET, true);
    return $base64UrlHeader . "." . $base64UrlPayload . "." . base64UrlEncode($signature);
}

function verifyAppSessionJWT($jwt) {
    $parts = explode('.', $jwt);
    if (count($parts) !== 3) return false;
    list($header, $payload, $signature) = $parts;
    $validSig = base64UrlEncode(hash_hmac('sha256', $header . "." . $payload, APP_SESSION_SECRET, true));
    if (!hash_equals($validSig, $signature)) return false;
    $data = json_decode(base64UrlDecode($payload), true);
    if (!is_array($data) || empty($data['sub']) || empty($data['exp'])) return false;
    if ((int)$data['exp'] < time()) return false;
    return $data;
}

function requireAppAuth($requireSession = true) {
    $host = strtolower($_SERVER['HTTP_HOST'] ?? '');
    $isLocal = (strpos($host, 'localhost') !== false) || (strpos($host, '127.0.0.1') !== false);
    $isHttps = (
        (!empty($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off') ||
        (string)($_SERVER['SERVER_PORT'] ?? '') === '443' ||
        strtolower($_SERVER['HTTP_X_FORWARDED_PROTO'] ?? '') === 'https'
    );
    if (!$isHttps && !$isLocal) {
        denyAppAuth('https_required');
    }

    $headers = getallheaders();
    $appId = getHeaderValue($headers, 'X-App-Id') ?? '';
    $deviceId = getHeaderValue($headers, 'X-App-Device') ?? '';
    $tsRaw = getHeaderValue($headers, 'X-App-Ts') ?? '';
    $nonce = getHeaderValue($headers, 'X-App-Nonce') ?? '';
    $signature = strtolower(getHeaderValue($headers, 'X-App-Sign') ?? '');
    $authModeRaw = strtolower(trim((string)(getHeaderValue($headers, 'X-App-Auth-Mode') ?? '')));
    $appVersionRaw = getHeaderValue($headers, 'X-App-Version') ?? '';
    $actionName = getCurrentActionName();
    $clientIp = getClientIpAddress();
    $isAttestAction = ($actionName === 'app_attest');
    $appPolicy = getAppPolicySettings();
    $strictMode = toBool($appPolicy['strict_security_mode'] ?? APP_STRICT_SECURITY_MODE, APP_STRICT_SECURITY_MODE);
    $isSessionV2 = APP_AUTH_ACCEPT_SESSION_V2 && ($authModeRaw === 'session_v2' || $authModeRaw === 'v2_session');
    if ($strictMode && !$isSessionV2 && !$isAttestAction) {
        denyAppAuth('legacy_auth_disabled');
    }

    if ($appId !== APP_CLIENT_ID) {
        denyAppAuth('invalid_app_id', ['appId' => $appId]);
    }

    enforceSimpleRateLimit(
        'app_ip',
        $clientIp . '|' . $actionName,
        APP_RATE_APP_IP_MAX,
        APP_RATE_WINDOW_SECONDS,
        'app_rate_limited'
    );

    if (!preg_match('/^[a-f0-9]{32}$/', $deviceId)) {
        denyAppAuth('invalid_device', ['deviceId' => $deviceId]);
    }

    enforceSimpleRateLimit(
        'app_device',
        $deviceId . '|' . $actionName,
        APP_RATE_APP_DEVICE_MAX,
        APP_RATE_WINDOW_SECONDS,
        'app_rate_limited'
    );

    if (!ctype_digit((string)$tsRaw)) {
        denyAppAuth('invalid_timestamp', ['ts' => $tsRaw]);
    }
    $ts = (int)$tsRaw;
    if (abs(time() - $ts) > APP_REQUEST_TOLERANCE) {
        denyAppAuth('timestamp_out_of_range', ['ts' => $ts, 'now' => time()]);
    }

    if (!preg_match('/^[A-Za-z0-9._-]{8,80}$/', $nonce)) {
        denyAppAuth('invalid_nonce', ['nonce' => $nonce]);
    }

    if (!$isSessionV2) {
        if (!preg_match('/^[a-f0-9]{64}$/', $signature)) {
            denyAppAuth('invalid_signature_format');
        }
    }

    $appVersionCode = parseAppVersionCode($appVersionRaw);
    if ($appVersionCode <= 0) {
        denyAppAuth('invalid_app_version', ['version' => $appVersionRaw]);
    }
    $minCode = (int)($appPolicy['min_version_code'] ?? 0);
    $forceEnabled = toBool($appPolicy['force_update_enabled'] ?? false, false);
    if ($forceEnabled && $minCode > 0 && $appVersionCode < $minCode) {
        denyAppUpgradeRequired($appVersionCode, $appPolicy);
    }

    $requestUri = $_SERVER['REQUEST_URI'] ?? '';
    $canonical = strtoupper($_SERVER['REQUEST_METHOD']) . "\n" . $requestUri . "\n" . $deviceId . "\n" . $ts . "\n" . $nonce;
    if (!$isSessionV2) {
        $expected = hash_hmac('sha256', $canonical, APP_SIGNING_SECRET);
        if (!hash_equals($expected, $signature)) {
            denyAppAuth('signature_mismatch', ['canonical' => $canonical]);
        }
    }

    $nonceKey = hash('sha256', $deviceId . '|' . $ts . '|' . $nonce);
    $nonceCache = loadNonceCacheStore();
    $cutoff = time() - (APP_REQUEST_TOLERANCE * 2);
    foreach ($nonceCache as $k => $v) {
        if (!is_int($v) || $v < $cutoff) {
            unset($nonceCache[$k]);
        }
    }
    if (isset($nonceCache[$nonceKey])) {
        denyAppAuth('replay_detected');
    }
    $nonceCache[$nonceKey] = time();
    saveNonceCacheStore($nonceCache);

    $policyRequireSession = toBool($appPolicy['require_app_session'] ?? APP_REQUIRE_SESSION, APP_REQUIRE_SESSION);
    $effectiveRequireSession = $requireSession && $policyRequireSession;
    if ($strictMode && !$isAttestAction) {
        $effectiveRequireSession = true;
    }
    $sessionData = null;
    if ($effectiveRequireSession) {
        $sessionToken = getHeaderValue($headers, 'X-App-Session') ?? '';
        if (!$sessionToken) {
            denyAppAuth('missing_session', ['action' => $actionName, 'authMode' => ($isSessionV2 ? 'session_v2' : 'legacy_v1'), 'strictMode' => $strictMode, 'policyRequireSession' => $policyRequireSession, 'requireSessionArg' => $requireSession, 'effectiveRequireSession' => $effectiveRequireSession]);
        }
        $sessionData = verifyAppSessionJWT($sessionToken);
        if (!$sessionData) {
            denyAppAuth('invalid_session');
        }
        if (($sessionData['sub'] ?? '') !== $deviceId) {
            denyAppAuth('session_device_mismatch');
        }
    }

    return [
        'deviceId' => $deviceId,
        'ts' => $ts,
        'nonce' => $nonce,
        'appId' => $appId,
        'authMode' => $isSessionV2 ? 'session_v2' : 'legacy_v1',
        'appVersionCode' => $appVersionCode,
        'session' => $sessionData
    ];
}

function tryRequireAdminAuth() {
    $headers = getallheaders();
    $authHeader = getHeaderValue($headers, 'Authorization') ?? '';
    if (!preg_match('/Bearer\s+(.*)$/i', $authHeader, $matches)) {
        return null;
    }
    $payload = verifyJWT($matches[1]);
    return is_array($payload) ? $payload : null;
}

function provisioningNowMs() {
    return (int)(microtime(true) * 1000);
}

function provisioningRandomId($length = 32) {
    $bytes = max(8, (int)ceil($length / 2));
    return substr(bin2hex(random_bytes($bytes)), 0, $length);
}

function provisioningRandomPassword($length = 12) {
    $chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789';
    $max = strlen($chars) - 1;
    $out = '';
    for ($i = 0; $i < $length; $i++) {
        $out .= $chars[random_int(0, $max)];
    }
    return $out;
}

function provisioningPreviewSecret($secret) {
    $s = (string)$secret;
    $len = strlen($s);
    if ($len <= 4) return $s;
    if ($len <= 8) return substr($s, 0, 2) . '...' . substr($s, -2);
    return substr($s, 0, 3) . '...' . substr($s, -2);
}

function canonicalProvisioningProtocol($raw) {
    $value = strtolower(trim((string)$raw));
    if ($value === '' || $value === 'ssh' || $value === 'slowdns') return 'ssh';
    if (in_array($value, ['vmess', 'vless', 'trojan', 'openvpn', 'hysteria'], true)) return $value;
    return '';
}

function provisioningIntegrityLevelFromAuth($appAuth) {
    $int = is_array($appAuth['session']['int'] ?? null) ? $appAuth['session']['int'] : [];
    $deviceVerdict = (string)($int['deviceVerdict'] ?? '');
    if ($deviceVerdict !== '' && $deviceVerdict === PLAY_INTEGRITY_REQUIRED_VERDICT) {
        return 'device';
    }
    if (!empty($appAuth['session'])) return 'basic';
    return 'none';
}

function requireProvisioningAppAuth($requireIntegrity = false) {
    $appAuth = requireAppAuth();
    $policy = getAppPolicySettings();
    $mustHaveIntegrity = $requireIntegrity && toBool($policy['provisioning_require_integrity'] ?? PROVISIONING_REQUIRE_INTEGRITY, PROVISIONING_REQUIRE_INTEGRITY);
    if ($mustHaveIntegrity) {
        $level = provisioningIntegrityLevelFromAuth($appAuth);
        if ($level !== 'device') {
            http_response_code(401);
            echo json_encode(['error' => 'integrity_required']);
            exit;
        }
    }
    return $appAuth;
}

function requireProvisioningSqlPdo() {
    $pdo = getStoragePdo();
    if ($pdo) return $pdo;
    $status = getStorageStatusInfo();
    http_response_code(503);
    echo json_encode([
        'error' => 'sql_storage_required',
        'detail' => (string)($status['error'] ?? 'SQL storage is not active')
    ]);
    exit;
}

function provisioningCryptoKey() {
    $material = trim((string)APP_SESSION_SECRET);
    if ($material === '') $material = trim((string)JWT_SECRET);
    if ($material === '') $material = trim((string)APP_SIGNING_SECRET);
    if ($material === '') return '';
    return hash('sha256', 'iptunnel-device-provisioning-v1|' . $material, true);
}

function encryptProvisioningSecret($secret) {
    $key = provisioningCryptoKey();
    if ($key === '' || !function_exists('openssl_encrypt')) return '';
    $iv = random_bytes(12);
    $tag = '';
    $ciphertext = openssl_encrypt((string)$secret, 'aes-256-gcm', $key, OPENSSL_RAW_DATA, $iv, $tag);
    if (!is_string($ciphertext) || $ciphertext === '') return '';
    return base64_encode(json_encode([
        'iv' => base64_encode($iv),
        'tag' => base64_encode($tag),
        'data' => base64_encode($ciphertext)
    ], JSON_UNESCAPED_SLASHES));
}

function decryptProvisioningSecret($encoded) {
    $key = provisioningCryptoKey();
    if ($key === '' || !function_exists('openssl_decrypt')) return '';
    $raw = base64_decode((string)$encoded, true);
    if (!is_string($raw) || $raw === '') return '';
    $payload = json_decode($raw, true);
    if (!is_array($payload)) return '';
    $iv = base64_decode((string)($payload['iv'] ?? ''), true);
    $tag = base64_decode((string)($payload['tag'] ?? ''), true);
    $data = base64_decode((string)($payload['data'] ?? ''), true);
    if (!is_string($iv) || !is_string($tag) || !is_string($data)) return '';
    $plain = openssl_decrypt($data, 'aes-256-gcm', $key, OPENSSL_RAW_DATA, $iv, $tag);
    return is_string($plain) ? $plain : '';
}

function provisioningJsonEncode($value) {
    $json = json_encode($value, JSON_UNESCAPED_SLASHES);
    return is_string($json) ? $json : '{}';
}

function getProvisioningSettings() {
    $policy = getAppPolicySettings();
    return [
        'enabled' => toBool($policy['provisioning_enabled'] ?? PROVISIONING_ENABLED, PROVISIONING_ENABLED),
        'base_url' => rtrim((string)($policy['provisioning_base_url'] ?? PROVISIONING_BASE_URL), '/'),
        'api_key' => trim((string)($policy['provisioning_api_key'] ?? PROVISIONING_API_KEY)),
        'server_id' => trim((string)($policy['provisioning_server_id'] ?? PROVISIONING_SERVER_ID)),
        'default_protocol' => canonicalProvisioningProtocol($policy['provisioning_default_protocol'] ?? PROVISIONING_DEFAULT_PROTOCOL) ?: 'ssh',
        'ssh_expiry_days' => max(1, (int)($policy['provisioning_ssh_expiry_days'] ?? PROVISIONING_SSH_EXPIRY_DAYS)),
        'ssh_limit_ip' => max(1, (int)($policy['provisioning_ssh_limit_ip'] ?? PROVISIONING_SSH_LIMIT_IP)),
        'ssh_quota_gb' => max(0, (int)($policy['provisioning_ssh_quota_gb'] ?? PROVISIONING_SSH_QUOTA_GB))
    ];
}

function requireProvisioningSettings() {
    $settings = getProvisioningSettings();
    if (!$settings['enabled']) {
        http_response_code(503);
        echo json_encode(['error' => 'provisioning_disabled']);
        exit;
    }
    if ($settings['base_url'] === '' || $settings['api_key'] === '') {
        http_response_code(500);
        echo json_encode(['error' => 'provisioning_not_configured']);
        exit;
    }
    return $settings;
}

function provisioningApiRequest($settings, $method, $path, $body = null) {
    $url = $settings['base_url'] . $path;
    if (!function_exists('curl_init')) {
        return ['ok' => false, 'status' => 0, 'error' => 'curl_not_available'];
    }
    $headers = [
        'Accept: application/json',
        'Authorization: ' . $settings['api_key']
    ];
    if ($body !== null) {
        $json = json_encode($body, JSON_UNESCAPED_SLASHES);
        if (!is_string($json)) {
            return ['ok' => false, 'status' => 0, 'error' => 'json_encode_failed'];
        }
        $headers[] = 'Content-Type: application/json';
    } else {
        $json = null;
    }

    $ch = curl_init($url);
    curl_setopt_array($ch, [
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_CUSTOMREQUEST => strtoupper($method),
        CURLOPT_HTTPHEADER => $headers,
        CURLOPT_TIMEOUT => 25,
        CURLOPT_CONNECTTIMEOUT => 10,
        CURLOPT_FOLLOWLOCATION => false
    ]);
    if ($json !== null) {
        curl_setopt($ch, CURLOPT_POSTFIELDS, $json);
    }
    $response = curl_exec($ch);
    $curlErr = curl_error($ch);
    $httpCode = (int)curl_getinfo($ch, CURLINFO_HTTP_CODE);
    curl_close($ch);

    if ($response === false) {
        return ['ok' => false, 'status' => $httpCode, 'error' => $curlErr ?: 'curl_failed'];
    }
    $decoded = json_decode((string)$response, true);
    if (!is_array($decoded)) {
        return ['ok' => false, 'status' => $httpCode, 'error' => 'invalid_json_response', 'raw' => (string)$response];
    }
    if ($httpCode >= 200 && $httpCode < 300) {
        return ['ok' => true, 'status' => $httpCode, 'body' => $decoded];
    }
    $error = (string)($decoded['error']['message'] ?? $decoded['meta']['message'] ?? $decoded['error'] ?? 'remote_request_failed');
    return ['ok' => false, 'status' => $httpCode, 'error' => $error, 'body' => $decoded];
}

function makeProvisioningUsername($deviceId) {
    $base = strtolower(preg_replace('/[^a-z0-9]/', '', (string)$deviceId));
    if ($base === '') $base = 'device';
    return 'ip' . substr($base, 0, 10) . substr(provisioningRandomId(6), 0, 4);
}

function sanitizeProvisioningPayloadForStorage($protocol, $payload) {
    $clean = is_array($payload) ? $payload : [];
    if ($protocol === 'ssh') unset($clean['password']);
    return $clean;
}

function provisioningPayloadExpiryMs($payload) {
    $exp = trim((string)($payload['exp'] ?? ''));
    if ($exp === '') return 0;
    $ts = strtotime($exp . ' 23:59:59');
    if ($ts === false) return 0;
    return (int)$ts * 1000;
}

function fetchProvisioningDevice($pdo, $deviceId) {
    $stmt = $pdo->prepare('SELECT * FROM app_devices WHERE device_id = :device_id LIMIT 1');
    $stmt->execute([':device_id' => $deviceId]);
    $row = $stmt->fetch();
    return is_array($row) ? $row : null;
}

function upsertProvisioningDevice($pdo, $device) {
    $existing = fetchProvisioningDevice($pdo, (string)$device['device_id']);
    if ($existing) {
        $stmt = $pdo->prepare('UPDATE app_devices SET
            auth_uid = :auth_uid,
            android_id_hash = :android_id_hash,
            install_id = :install_id,
            package_name = :package_name,
            signing_cert_sha256 = :signing_cert_sha256,
            app_version = :app_version,
            status = :status,
            integrity_level = :integrity_level,
            last_integrity_json = :last_integrity_json,
            last_seen_at = :last_seen_at,
            last_ip = :last_ip,
            note = :note
            WHERE device_id = :device_id');
        return $stmt->execute([
            ':auth_uid' => (string)$device['auth_uid'],
            ':android_id_hash' => (string)$device['android_id_hash'],
            ':install_id' => (string)$device['install_id'],
            ':package_name' => (string)$device['package_name'],
            ':signing_cert_sha256' => (string)$device['signing_cert_sha256'],
            ':app_version' => (string)$device['app_version'],
            ':status' => (string)$device['status'],
            ':integrity_level' => (string)$device['integrity_level'],
            ':last_integrity_json' => provisioningJsonEncode($device['last_integrity'] ?? []),
            ':last_seen_at' => (int)$device['last_seen_at'],
            ':last_ip' => (string)$device['last_ip'],
            ':note' => (string)$device['note'],
            ':device_id' => (string)$device['device_id']
        ]);
    }
    $stmt = $pdo->prepare('INSERT INTO app_devices (
        device_id, auth_uid, android_id_hash, install_id, package_name,
        signing_cert_sha256, app_version, status, integrity_level, last_integrity_json,
        first_seen_at, last_seen_at, last_ip, note
    ) VALUES (
        :device_id, :auth_uid, :android_id_hash, :install_id, :package_name,
        :signing_cert_sha256, :app_version, :status, :integrity_level, :last_integrity_json,
        :first_seen_at, :last_seen_at, :last_ip, :note
    )');
    return $stmt->execute([
        ':device_id' => (string)$device['device_id'],
        ':auth_uid' => (string)$device['auth_uid'],
        ':android_id_hash' => (string)$device['android_id_hash'],
        ':install_id' => (string)$device['install_id'],
        ':package_name' => (string)$device['package_name'],
        ':signing_cert_sha256' => (string)$device['signing_cert_sha256'],
        ':app_version' => (string)$device['app_version'],
        ':status' => (string)$device['status'],
        ':integrity_level' => (string)$device['integrity_level'],
        ':last_integrity_json' => provisioningJsonEncode($device['last_integrity'] ?? []),
        ':first_seen_at' => (int)$device['first_seen_at'],
        ':last_seen_at' => (int)$device['last_seen_at'],
        ':last_ip' => (string)$device['last_ip'],
        ':note' => (string)$device['note']
    ]);
}

function insertProvisioningEvent($pdo, $deviceId, $eventType, $ipAddress, $detail = []) {
    $stmt = $pdo->prepare('INSERT INTO app_device_events (
        event_id, device_id, event_type, ip_address, detail_json, created_at
    ) VALUES (
        :event_id, :device_id, :event_type, :ip_address, :detail_json, :created_at
    )');
    return $stmt->execute([
        ':event_id' => provisioningRandomId(32),
        ':device_id' => (string)$deviceId,
        ':event_type' => (string)$eventType,
        ':ip_address' => (string)$ipAddress,
        ':detail_json' => provisioningJsonEncode($detail),
        ':created_at' => provisioningNowMs()
    ]);
}

function fetchActiveProvisioningCredential($pdo, $deviceId, $protocol) {
    $stmt = $pdo->prepare('SELECT * FROM app_device_credentials
        WHERE device_id = :device_id AND protocol = :protocol AND status = :status
        ORDER BY issued_at DESC LIMIT 1');
    $stmt->execute([
        ':device_id' => (string)$deviceId,
        ':protocol' => (string)$protocol,
        ':status' => 'active'
    ]);
    $row = $stmt->fetch();
    return is_array($row) ? $row : null;
}

function fetchProvisioningCredentials($pdo, $deviceId, $protocol = null) {
    if ($protocol !== null && $protocol !== '') {
        $stmt = $pdo->prepare('SELECT * FROM app_device_credentials
            WHERE device_id = :device_id AND protocol = :protocol AND status = :status
            ORDER BY issued_at DESC');
        $stmt->execute([
            ':device_id' => (string)$deviceId,
            ':protocol' => (string)$protocol,
            ':status' => 'active'
        ]);
        return $stmt->fetchAll();
    }
    $stmt = $pdo->prepare('SELECT * FROM app_device_credentials
        WHERE device_id = :device_id AND status = :status
        ORDER BY issued_at DESC');
    $stmt->execute([
        ':device_id' => (string)$deviceId,
        ':status' => 'active'
    ]);
    return $stmt->fetchAll();
}

function insertProvisioningCredential($pdo, $record) {
    $stmt = $pdo->prepare('INSERT INTO app_device_credentials (
        credential_id, device_id, protocol, server_id, external_ref, username,
        secret_enc, secret_hash, secret_preview, payload_json, status,
        issued_at, expires_at, last_used_at, revoked_at, revoked_reason, parent_credential_id
    ) VALUES (
        :credential_id, :device_id, :protocol, :server_id, :external_ref, :username,
        :secret_enc, :secret_hash, :secret_preview, :payload_json, :status,
        :issued_at, :expires_at, :last_used_at, :revoked_at, :revoked_reason, :parent_credential_id
    )');
    return $stmt->execute([
        ':credential_id' => (string)$record['credential_id'],
        ':device_id' => (string)$record['device_id'],
        ':protocol' => (string)$record['protocol'],
        ':server_id' => (string)$record['server_id'],
        ':external_ref' => (string)$record['external_ref'],
        ':username' => (string)$record['username'],
        ':secret_enc' => (string)$record['secret_enc'],
        ':secret_hash' => (string)$record['secret_hash'],
        ':secret_preview' => (string)$record['secret_preview'],
        ':payload_json' => provisioningJsonEncode($record['payload'] ?? []),
        ':status' => (string)$record['status'],
        ':issued_at' => (int)$record['issued_at'],
        ':expires_at' => (int)$record['expires_at'],
        ':last_used_at' => (int)$record['last_used_at'],
        ':revoked_at' => (int)$record['revoked_at'],
        ':revoked_reason' => (string)$record['revoked_reason'],
        ':parent_credential_id' => (string)$record['parent_credential_id']
    ]);
}

function revokeProvisioningCredential($pdo, $credentialId, $reason) {
    $stmt = $pdo->prepare('UPDATE app_device_credentials
        SET status = :status, revoked_at = :revoked_at, revoked_reason = :revoked_reason
        WHERE credential_id = :credential_id');
    return $stmt->execute([
        ':status' => 'revoked',
        ':revoked_at' => provisioningNowMs(),
        ':revoked_reason' => (string)$reason,
        ':credential_id' => (string)$credentialId
    ]);
}

function touchProvisioningCredential($pdo, $credentialId) {
    $stmt = $pdo->prepare('UPDATE app_device_credentials SET last_used_at = :last_used_at WHERE credential_id = :credential_id');
    return $stmt->execute([
        ':last_used_at' => provisioningNowMs(),
        ':credential_id' => (string)$credentialId
    ]);
}

function provisioningCredentialResponse($row) {
    $payload = json_decode((string)($row['payload_json'] ?? '{}'), true);
    if (!is_array($payload)) $payload = [];
    $secret = decryptProvisioningSecret((string)($row['secret_enc'] ?? ''));
    $protocol = (string)($row['protocol'] ?? '');
    if ($protocol === 'ssh' && $secret !== '') {
        $payload['password'] = $secret;
    }
    return [
        'credentialId' => (string)($row['credential_id'] ?? ''),
        'protocol' => $protocol,
        'serverId' => (string)($row['server_id'] ?? ''),
        'username' => (string)($row['username'] ?? ''),
        'status' => (string)($row['status'] ?? ''),
        'secretPreview' => (string)($row['secret_preview'] ?? ''),
        'transports' => $protocol === 'ssh' ? ['ssh', 'slowdns'] : [$protocol],
        'issuedAt' => (int)($row['issued_at'] ?? 0),
        'expiresAt' => (int)($row['expires_at'] ?? 0),
        'payload' => $payload
    ];
}

function buildProvisioningDeviceRecord($appAuth, $input, $existing = null) {
    $deviceId = normalizeUserId($input['deviceId'] ?? $appAuth['deviceId'] ?? '');
    if ($deviceId === '' || $deviceId !== ($appAuth['deviceId'] ?? '')) {
        http_response_code(400);
        echo json_encode(['error' => 'deviceId mismatch']);
        exit;
    }
    $androidIdHash = strtolower(trim((string)($input['androidIdHash'] ?? '')));
    if ($androidIdHash !== '' && !preg_match('/^[a-f0-9]{64}$/', $androidIdHash)) {
        http_response_code(400);
        echo json_encode(['error' => 'invalid_androidIdHash']);
        exit;
    }
    $signingCertSha256 = strtoupper(trim((string)($input['signingCertSha256'] ?? APP_SIGNING_CERT_SHA256)));
    $normalizedCert = $signingCertSha256 !== '' ? normalizeSha256Digest($signingCertSha256) : '';
    $sessionInt = is_array($appAuth['session']['int'] ?? null) ? $appAuth['session']['int'] : [];
    $now = provisioningNowMs();
    return [
        'device_id' => $deviceId,
        'auth_uid' => trim((string)($input['authUid'] ?? '')),
        'android_id_hash' => $androidIdHash,
        'install_id' => trim((string)($input['installId'] ?? '')),
        'package_name' => trim((string)($input['packageName'] ?? APP_PACKAGE_NAME)),
        'signing_cert_sha256' => $normalizedCert !== '' ? $normalizedCert : '',
        'app_version' => (string)($input['appVersion'] ?? $appAuth['appVersionCode'] ?? ''),
        'status' => (string)($existing['status'] ?? 'active'),
        'integrity_level' => provisioningIntegrityLevelFromAuth($appAuth),
        'last_integrity' => $sessionInt,
        'first_seen_at' => (int)($existing['first_seen_at'] ?? $now),
        'last_seen_at' => $now,
        'last_ip' => getClientIpAddress(),
        'note' => trim((string)($input['note'] ?? ($existing['note'] ?? '')))
    ];
}

function createProvisioningSshCredential($settings, $deviceId, $serverIdOverride = '') {
    $serverId = trim((string)$serverIdOverride);
    if ($serverId === '') $serverId = (string)$settings['server_id'];
    $password = provisioningRandomPassword(12);
    $lastError = 'provisioning_failed';
    for ($attempt = 0; $attempt < 3; $attempt++) {
        $username = makeProvisioningUsername($deviceId);
        $result = provisioningApiRequest($settings, 'POST', '/api/v2/vps/accounts/ssh', [
            'username' => $username,
            'password' => $password,
            'expired' => (int)$settings['ssh_expiry_days'],
            'limit_ip' => (int)$settings['ssh_limit_ip'],
            'quota_gb' => (int)$settings['ssh_quota_gb']
        ]);
        if ($result['ok']) {
            $data = is_array($result['body']['data'] ?? null) ? $result['body']['data'] : [];
            return [
                'ok' => true,
                'protocol' => 'ssh',
                'server_id' => $serverId,
                'external_ref' => $username,
                'username' => $username,
                'secret' => $password,
                'payload' => sanitizeProvisioningPayloadForStorage('ssh', $data),
                'expires_at' => provisioningPayloadExpiryMs($data)
            ];
        }
        $lastError = (string)($result['error'] ?? 'provisioning_failed');
        if ((int)($result['status'] ?? 0) !== 409) {
            break;
        }
    }
    return ['ok' => false, 'error' => $lastError];
}

function rotateProvisioningSshCredential($settings, $row) {
    $username = (string)($row['username'] ?? '');
    if ($username === '') return ['ok' => false, 'error' => 'missing_username'];
    $password = provisioningRandomPassword(12);
    $result = provisioningApiRequest($settings, 'PATCH', '/api/v2/vps/accounts/ssh/' . rawurlencode($username), [
        'password' => $password
    ]);
    if (!$result['ok']) {
        return ['ok' => false, 'error' => (string)($result['error'] ?? 'rotate_failed')];
    }
    $data = is_array($result['body']['data'] ?? null) ? $result['body']['data'] : [];
    return [
        'ok' => true,
        'protocol' => 'ssh',
        'server_id' => (string)($row['server_id'] ?? ''),
        'external_ref' => $username,
        'username' => $username,
        'secret' => $password,
        'payload' => sanitizeProvisioningPayloadForStorage('ssh', $data),
        'expires_at' => provisioningPayloadExpiryMs($data)
    ];
}

function revokeProvisioningSshCredentialRemote($settings, $row) {
    $username = (string)($row['username'] ?? '');
    if ($username === '') return ['ok' => false, 'error' => 'missing_username'];
    $result = provisioningApiRequest($settings, 'DELETE', '/api/v2/vps/accounts/ssh/' . rawurlencode($username));
    if ($result['ok']) return ['ok' => true];
    if ((int)($result['status'] ?? 0) === 404) return ['ok' => true];
    return ['ok' => false, 'error' => (string)($result['error'] ?? 'revoke_failed')];
}

// ========================================
// FIREBASE HELPER
// ========================================
function getGoogleAccessToken($scope, $serviceAccountFile = SERVICE_ACCOUNT_FILE) {
    global $LAST_GOOGLE_ACCESS_TOKEN_ERROR;
    $LAST_GOOGLE_ACCESS_TOKEN_ERROR = null;
    $serviceAccountPath = trim((string)$serviceAccountFile);
    if ($serviceAccountPath === '') $serviceAccountPath = SERVICE_ACCOUNT_FILE;
    if (!file_exists($serviceAccountPath)) {
        debugLog('SERVICE_ACCOUNT_FILE missing: ' . $serviceAccountPath);
        return null;
    }
    $serviceAccount = json_decode(file_get_contents($serviceAccountPath), true);
    if (!$serviceAccount || empty($serviceAccount['client_email']) || empty($serviceAccount['private_key'])) {
        debugLog('Invalid service account json', ['path' => $serviceAccountPath]);
        return null;
    }
    $now = time();
    $header = base64UrlEncode(json_encode(['alg' => 'RS256', 'typ' => 'JWT']));
    $payload = base64UrlEncode(json_encode([
        'iss' => $serviceAccount['client_email'],
        'scope' => $scope,
        'aud' => 'https://oauth2.googleapis.com/token',
        'iat' => $now,
        'exp' => $now + 3600
    ]));
    $signatureInput = "$header.$payload";
    openssl_sign($signatureInput, $signature, $serviceAccount['private_key'], 'SHA256');
    $jwtToken = "$signatureInput." . base64UrlEncode($signature);
    $tokenUrls = [
        'https://oauth2.googleapis.com/token',
        'https://www.googleapis.com/oauth2/v4/token'
    ];

    $lastErr = ['scope' => $scope, 'serviceAccountFile' => $serviceAccountPath];
    foreach ($tokenUrls as $tokenUrl) {
        $ch = curl_init($tokenUrl);
        curl_setopt_array($ch, [
            CURLOPT_POST => true,
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_CONNECTTIMEOUT => 12,
            CURLOPT_TIMEOUT => 20,
            CURLOPT_HTTP_VERSION => CURL_HTTP_VERSION_1_1,
            CURLOPT_POSTFIELDS => http_build_query([
                'grant_type' => 'urn:ietf:params:oauth:grant-type:jwt-bearer',
                'assertion' => $jwtToken
            ])
        ]);
        $response = curl_exec($ch);
        $curlErr = curl_error($ch);
        $httpCode = curl_getinfo($ch, CURLINFO_HTTP_CODE);
        curl_close($ch);

        $data = json_decode($response, true);
        if (is_array($data) && !empty($data['access_token'])) {
            return $data['access_token'];
        }
        $lastErr = [
            'scope' => $scope,
            'url' => $tokenUrl,
            'http' => $httpCode,
            'curlErr' => $curlErr,
            'response' => $response
        ];
    }

    $LAST_GOOGLE_ACCESS_TOKEN_ERROR = $lastErr;
    debugLog('Google access token error', $lastErr);
    return null;
}

function getFirebaseAccessToken() {
    return getGoogleAccessToken('https://www.googleapis.com/auth/firebase.messaging', FCM_SERVICE_ACCOUNT_FILE);
}

function decodeIntegrityTokenWithGoogle($integrityToken) {
    $accessToken = getGoogleAccessToken(PLAY_INTEGRITY_SCOPE, PLAY_INTEGRITY_SERVICE_ACCOUNT_FILE);
    if (!$accessToken) {
        return ['ok' => false, 'error' => 'play_integrity_access_token_failed'];
    }

    $url = 'https://playintegrity.googleapis.com/v1/' . APP_PACKAGE_NAME . ':decodeIntegrityToken';
    $ch = curl_init($url);
    curl_setopt_array($ch, [
        CURLOPT_POST => true,
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_HTTPHEADER => [
            'Authorization: Bearer ' . $accessToken,
            'Content-Type: application/json'
        ],
        CURLOPT_POSTFIELDS => json_encode(['integrity_token' => $integrityToken], JSON_UNESCAPED_SLASHES)
    ]);
    $response = curl_exec($ch);
    $httpCode = curl_getinfo($ch, CURLINFO_HTTP_CODE);
    curl_close($ch);

    $data = json_decode($response, true);
    if ($httpCode < 200 || $httpCode >= 300 || !is_array($data)) {
        return ['ok' => false, 'error' => 'play_integrity_decode_failed', 'http' => $httpCode, 'response' => $response];
    }

    return ['ok' => true, 'data' => $data];
}

function loadJsonMapStore($path) {
    $data = readSharedStoreJson(storeKeyFromPath($path), $path, [], false);
    return is_array($data) ? $data : [];
}

function saveJsonMapStore($path, $data) {
    return writeSharedStoreJson(storeKeyFromPath($path), $path, $data, false);
}

function loadJsonListStore($path) {
    $data = readSharedStoreJson(storeKeyFromPath($path), $path, [], true);
    return is_array($data) ? array_values($data) : [];
}

function saveJsonListStore($path, $data) {
    return writeSharedStoreJson(storeKeyFromPath($path), $path, $data, true);
}

function normalizeSupportStatus($status, $default = 'new') {
    $s = strtolower(trim((string)$status));
    if ($s === 'new' || $s === 'done' || $s === 'declined') return $s;
    return $default;
}

function generateSupportRequestId() {
    $prefix = 'SR-' . date('Ymd') . '-';
    $alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    $suffix = '';
    for ($i = 0; $i < 6; $i++) {
        $suffix .= $alphabet[random_int(0, strlen($alphabet) - 1)];
    }
    return $prefix . $suffix;
}

function loadSupportRequests() {
    return loadJsonListStore(SUPPORT_REQUESTS_FILE);
}

function saveSupportRequests($items) {
    return saveJsonListStore(SUPPORT_REQUESTS_FILE, $items);
}

function loadAdminUiState() {
    $state = loadJsonMapStore(ADMIN_UI_STATE_FILE);
    if (!is_array($state)) $state = [];
    if (!isset($state['settings']) || !is_array($state['settings'])) $state['settings'] = [];
    if (!isset($state['config']) || !is_array($state['config'])) $state['config'] = [];
    return $state;
}

function saveAdminUiState($state) {
    if (!is_array($state)) $state = [];
    if (!isset($state['settings']) || !is_array($state['settings'])) $state['settings'] = [];
    if (!isset($state['config']) || !is_array($state['config'])) $state['config'] = [];
    $state['updatedAt'] = date('c');
    return saveJsonMapStore(ADMIN_UI_STATE_FILE, $state);
}

function normalizeUserId($value) {
    $id = strtolower(trim((string)$value));
    if ($id === '') return '';
    if (!preg_match('/^[a-z0-9._:-]{6,128}$/', $id)) return '';
    return $id;
}

function normalizeRedeemCode($value) {
    $code = trim((string)$value);
    if ($code === '') return '';
    if (strlen($code) > 256) return '';
    return $code;
}

function defaultCoinUser($deviceId) {
    $now = (int)(microtime(true) * 1000);
    $newUserBonusCoins = resolveNewUserBonusCoinsFromPolicy();
    return [
        'deviceId' => (string)$deviceId,
        'coins' => $newUserBonusCoins,
        'lastUpdated' => $now,
        'lastActive' => $now,
        'banned' => false,
        'canRedeem' => true,
        'canReceiveCoins' => true,
        'canSendCoins' => true,
        'adOnlyEarning' => false
    ];
}

function loadUserCoins() {
    return loadJsonMapStore(USER_COINS_FILE);
}

function saveUserCoins($users) {
    return saveJsonMapStore(USER_COINS_FILE, $users);
}

function loadRedeemedCodes() {
    return loadJsonMapStore(REDEEMED_CODES_FILE);
}

function saveRedeemedCodes($codes) {
    return saveJsonMapStore(REDEEMED_CODES_FILE, $codes);
}

function loadCoinCodePool() {
    return loadJsonMapStore(COIN_CODES_FILE);
}

function saveCoinCodePool($pool) {
    return saveJsonMapStore(COIN_CODES_FILE, $pool);
}

function loadCoinLedger() {
    return loadJsonListStore(COIN_LEDGER_FILE);
}

function saveCoinLedger($ledger) {
    return saveJsonListStore(COIN_LEDGER_FILE, $ledger);
}

function appendCoinLedgerEntry($entry) {
    $ledger = loadCoinLedger();
    $entry['createdAt'] = (int)($entry['createdAt'] ?? (microtime(true) * 1000));
    $ledger[] = $entry;
    if (count($ledger) > 5000) {
        $ledger = array_slice($ledger, -5000);
    }
    return saveCoinLedger($ledger);
}

function getUserOrDefault($users, $deviceId) {
    if (isset($users[$deviceId]) && is_array($users[$deviceId])) {
        $user = $users[$deviceId];
        $defaults = defaultCoinUser($deviceId);
        foreach ($defaults as $k => $v) {
            if (!array_key_exists($k, $user)) $user[$k] = $v;
        }
        $user['deviceId'] = $deviceId;
        $user['coins'] = (int)($user['coins'] ?? 0);
        $user['banned'] = toBool($user['banned'] ?? false, false);
        $user['canRedeem'] = toBool($user['canRedeem'] ?? true, true);
        $user['canReceiveCoins'] = toBool($user['canReceiveCoins'] ?? true, true);
        $user['canSendCoins'] = toBool($user['canSendCoins'] ?? true, true);
        $user['adOnlyEarning'] = toBool($user['adOnlyEarning'] ?? false, false);
        return $user;
    }
    return defaultCoinUser($deviceId);
}

function saveUserBack($users, $user) {
    $deviceId = normalizeUserId($user['deviceId'] ?? '');
    if ($deviceId === '') return false;
    $users[$deviceId] = $user;
    return saveUserCoins($users);
}

function generateCoinCode() {
    $alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    $code = '';
    for ($i = 0; $i < 12; $i++) {
        $code .= $alphabet[random_int(0, strlen($alphabet) - 1)];
    }
    return $code;
}

// ========================================
// PARSE REQUEST
// ========================================
$method = $_SERVER['REQUEST_METHOD'];
$rawInput = file_get_contents('php://input');
$input = json_decode($rawInput, true);

debugLog("InputSummary", summarizeInputForLog($input, $rawInput));

$action = $input['action'] ?? $_GET['action'] ?? null;
debugLog("Action: " . ($action ?? 'NULL') . ", Method: $method");

$allowedDeviceActions = [
    'device_register',
    'device_provision',
    'device_credentials',
    'device_rotate',
    'device_revoke',
    'device_heartbeat'
];

if (!in_array((string)$action, $allowedDeviceActions, true)) {
    debugLog('DEVICE API NO MATCH', ['action' => $action, 'method' => $method]);
    http_response_code(404);
    $notFound = ['error' => 'Unknown device action'];
    if ($DEBUG_LOG_ENABLED) {
        $notFound['action'] = $action;
        $notFound['method'] = $method;
    }
    echo json_encode($notFound);
    exit;
}

// ========================================
// ROUTES
// ========================================

// LOGIN
if ($action === 'login' && $method === 'POST') {
    $username = $input['username'] ?? '';
    $password = $input['password'] ?? '';
    $loginIp = ($_SERVER['REMOTE_ADDR'] ?? 'unknown');
    enforceSimpleRateLimit(
        'admin_login_ip',
        $loginIp,
        ADMIN_LOGIN_RATE_MAX,
        ADMIN_LOGIN_RATE_WINDOW_SECONDS,
        'login_rate_limited',
        429
    );
    $loginIdentifier = strtolower(trim((string)$username));
    if ($loginIdentifier === '') $loginIdentifier = 'unknown';
    $loginIdentifier .= '|' . $loginIp;
    enforceSimpleRateLimit(
        'admin_login',
        $loginIdentifier,
        ADMIN_LOGIN_RATE_MAX,
        ADMIN_LOGIN_RATE_WINDOW_SECONDS,
        'login_rate_limited',
        429
    );
    
    debugLog("=== LOGIN ATTEMPT ===");
    debugLog("Password provided: " . (empty($password) ? 'NO' : 'YES'));
    
    if ($username === ADMIN_USER) {
        debugLog("âœ“ Username matches");
        $passValid = password_verify($password, ADMIN_PASS_HASH);
        debugLog("Password verify result: " . ($passValid ? 'VALID' : 'INVALID'));
        
        if ($passValid) {
            $token = createJWT($username);
            debugLog("âœ“ Login successful, token created");
            echo json_encode(['token' => $token, 'expires_in' => TOKEN_EXPIRY, 'user' => $username]);
        } else {
            debugLog("âœ— Invalid password");
            http_response_code(401);
            echo json_encode(['error' => 'Invalid credentials']);
        }
    } else {
        debugLog("âœ— Username mismatch");
        http_response_code(401);
        echo json_encode(['error' => 'Invalid credentials']);
    }
    exit;
}

// PING
if ($action === 'admin_ping' && $method === 'GET') {
    $payload = requireAuth();
    echo json_encode(['ok' => true, 'user' => $payload['user']]);
    exit;
}

if ($action === 'storage_status' && $method === 'GET') {
    requireAuth();
    echo json_encode(['success' => true, 'storage' => getStorageStatusInfo()]);
    exit;
}

if ($action === 'storage_migrate' && $method === 'POST') {
    requireAuth();
    $result = migrateJsonStoresToSql();
    if (!$result['ok']) {
        http_response_code(500);
        echo json_encode(['error' => $result['error'] ?? 'storage migration failed', 'result' => $result]);
        exit;
    }
    echo json_encode(['success' => true, 'result' => $result, 'storage' => getStorageStatusInfo()]);
    exit;
}

if ($action === 'app_policy' && $method === 'GET') {
    requireAuth();
    echo json_encode(['success' => true, 'settings' => getAppPolicySettings()]);
    exit;
}

if ($action === 'app_policy' && $method === 'POST') {
    requireAuth();
    $save = saveAppPolicySettings($input);
    if (!$save['ok']) {
        http_response_code(400);
        echo json_encode(['error' => $save['error'] ?? 'Failed to save app policy']);
        exit;
    }
    echo json_encode(['success' => true, 'settings' => $save['settings']]);
    exit;
}

if ($action === 'crypto_keys' && $method === 'GET') {
    requireAuth();
    if (APP_CONFIG_PASS === '' || APP_IMPORT_KEY === '') {
        http_response_code(503);
        echo json_encode(['error' => 'crypto_keys_not_configured']);
        exit;
    }
    echo json_encode([
        'success' => true,
        'configPass' => APP_CONFIG_PASS,
        'importKey' => APP_IMPORT_KEY
    ]);
    exit;
}

if ($action === 'app_policy_public' && $method === 'GET') {
    requireAppAuth();
    $policy = getAppPolicySettings();
    echo json_encode([
        'success' => true,
        'settings' => [
            'default_server_username' => (string)($policy['default_server_username'] ?? ''),
            'default_server_password' => (string)($policy['default_server_password'] ?? '')
        ]
    ]);
    exit;
}

if ($action === 'sign_import_config' && $method === 'POST') {
    requireAuth();
    $payload = $input['payload'] ?? null;
    if (!is_array($payload)) {
        http_response_code(400);
        echo json_encode(['error' => 'payload object required']);
        exit;
    }
    $policy = getAppPolicySettings();
    $requireSigned = toBool($policy['require_signed_imports'] ?? REQUIRE_SIGNED_IMPORTS, REQUIRE_SIGNED_IMPORTS);
    $strictMode = toBool($policy['strict_security_mode'] ?? APP_STRICT_SECURITY_MODE, APP_STRICT_SECURITY_MODE);
    if (!$requireSigned && !$strictMode) {
        echo json_encode(['success' => true, 'payload' => normalizeImportPayload($payload), 'signed' => false]);
        exit;
    }
    $signed = signImportPayload($payload);
    if (!$signed['ok']) {
        http_response_code(500);
        echo json_encode(['error' => $signed['error'] ?? 'signing_failed']);
        exit;
    }
    echo json_encode(['success' => true, 'payload' => $signed['payload'], 'signed' => true]);
    exit;
}

if ($action === 'app_sign_import' && $method === 'POST') {
    requireAppAuth();
    $payload = $input['payload'] ?? null;
    if (!is_array($payload)) {
        http_response_code(400);
        echo json_encode(['error' => 'payload object required']);
        exit;
    }
    $policy = getAppPolicySettings();
    $requireSigned = toBool($policy['require_signed_imports'] ?? REQUIRE_SIGNED_IMPORTS, REQUIRE_SIGNED_IMPORTS);
    $strictMode = toBool($policy['strict_security_mode'] ?? APP_STRICT_SECURITY_MODE, APP_STRICT_SECURITY_MODE);
    if (!$requireSigned && !$strictMode) {
        echo json_encode(['success' => true, 'payload' => normalizeImportPayload($payload), 'signed' => false]);
        exit;
    }
    $signed = signImportPayload($payload);
    if (!$signed['ok']) {
        http_response_code(500);
        echo json_encode(['error' => $signed['error'] ?? 'signing_failed']);
        exit;
    }
    echo json_encode(['success' => true, 'payload' => $signed['payload'], 'signed' => true]);
    exit;
}

if ($action === 'cloud_publish' && $method === 'POST') {
    requireAuth();
    $config = (string)($input['Config'] ?? $input['config'] ?? '');
    if ($config === '') {
        http_response_code(400);
        echo json_encode(['error' => 'Config is required']);
        exit;
    }
    $configName = (string)($input['ConfigName'] ?? $input['configName'] ?? 'Cloud Config');
    $autoDelete5Min = toBool($input['AutoDelete5Min'] ?? $input['autoDelete5Min'] ?? false, false);
    $deleteAfterFirstAccess = toBool($input['DeleteAfterFirstAccess'] ?? $input['deleteAfterFirstAccess'] ?? false, false);

    $configs = loadCloudConfigs();
    $key = generateCloudConfigKey($configs);
    $configs[$key] = buildCloudConfigRecord($config, $configName, $autoDelete5Min, $deleteAfterFirstAccess);
    if (!saveCloudConfigs($configs)) {
        http_response_code(500);
        echo json_encode(['error' => 'Failed to save cloud config']);
        exit;
    }
    echo json_encode(['success' => true, 'key' => $key]);
    exit;
}

if ($action === 'app_cloud_publish' && $method === 'POST') {
    requireAppAuth();
    $config = (string)($input['Config'] ?? $input['config'] ?? '');
    if ($config === '') {
        http_response_code(400);
        echo json_encode(['error' => 'Config is required']);
        exit;
    }
    $configName = (string)($input['ConfigName'] ?? $input['configName'] ?? 'Cloud Config');
    $autoDelete5Min = toBool($input['AutoDelete5Min'] ?? $input['autoDelete5Min'] ?? false, false);
    $deleteAfterFirstAccess = toBool($input['DeleteAfterFirstAccess'] ?? $input['deleteAfterFirstAccess'] ?? false, false);

    $configs = loadCloudConfigs();
    $key = generateCloudConfigKey($configs);
    $configs[$key] = buildCloudConfigRecord($config, $configName, $autoDelete5Min, $deleteAfterFirstAccess);
    if (!saveCloudConfigs($configs)) {
        http_response_code(500);
        echo json_encode(['error' => 'Failed to save cloud config']);
        exit;
    }
    echo json_encode(['success' => true, 'key' => $key]);
    exit;
}

if ($action === 'cloud_fetch' && $method === 'GET') {
    requireAppAuth();
    $key = strtoupper(trim((string)($_GET['key'] ?? '')));
    if ($key === '') {
        http_response_code(400);
        echo json_encode(['error' => 'key is required']);
        exit;
    }
    $configs = loadCloudConfigs();
    if (!isset($configs[$key])) {
        http_response_code(404);
        echo json_encode(['error' => 'Config not found']);
        exit;
    }
    $item = $configs[$key];
    if (!empty($item['Deleted'])) {
        http_response_code(410);
        echo json_encode(['error' => 'Config deleted', 'DeleteReason' => (string)($item['DeleteReason'] ?? '')]);
        exit;
    }
    $now = (int)(microtime(true) * 1000);
    if (!empty($item['ExpiresAt']) && $now > (int)$item['ExpiresAt']) {
        $item['Deleted'] = true;
        $item['DeletedAt'] = $now;
        $item['DeleteReason'] = 'Config expired (5-minute auto-delete)';
        $configs[$key] = $item;
        saveCloudConfigs($configs);
        http_response_code(410);
        echo json_encode(['error' => 'Config expired', 'DeleteReason' => $item['DeleteReason']]);
        exit;
    }
    echo json_encode([
        'success' => true,
        'key' => $key,
        'Config' => (string)($item['Config'] ?? ''),
        'DeleteAfterFirstAccess' => !empty($item['DeleteAfterFirstAccess']),
        'AutoDelete5Min' => !empty($item['AutoDelete5Min']),
        'AccessCount' => (int)($item['AccessCount'] ?? 0),
        'ConfigName' => (string)($item['ConfigName'] ?? '')
    ]);
    exit;
}

if ($action === 'cloud_touch' && $method === 'POST') {
    requireAppAuth();
    $key = strtoupper(trim((string)($input['key'] ?? '')));
    $mode = strtolower(trim((string)($input['mode'] ?? 'touch')));
    if ($key === '') {
        http_response_code(400);
        echo json_encode(['error' => 'key is required']);
        exit;
    }
    $configs = loadCloudConfigs();
    if (!isset($configs[$key])) {
        http_response_code(404);
        echo json_encode(['error' => 'Config not found']);
        exit;
    }
    $item = $configs[$key];
    $now = (int)(microtime(true) * 1000);
    if ($mode === 'delete') {
        $item['Deleted'] = true;
        $item['DeletedAt'] = $now;
        $item['DeleteReason'] = 'One-time config already used';
    } elseif ($mode === 'expire') {
        $item['Deleted'] = true;
        $item['DeletedAt'] = $now;
        $item['DeleteReason'] = 'Config expired (5-minute auto-delete)';
    } else {
        $item['AccessCount'] = (int)($item['AccessCount'] ?? 0) + 1;
    }
    $configs[$key] = $item;
    if (!saveCloudConfigs($configs)) {
        http_response_code(500);
        echo json_encode(['error' => 'Failed to update config']);
        exit;
    }
    echo json_encode(['success' => true]);
    exit;
}

if ($action === 'app_attest' && $method === 'POST') {
    $appAuth = requireAppAuth(false);
    $integrityToken = $input['integrityToken'] ?? '';
    $nonceFromBody = $input['nonce'] ?? '';
    $deviceFromBody = strtolower($input['deviceId'] ?? '');
    $attestLogBase = [
        'headerDevice' => (string)($appAuth['deviceId'] ?? ''),
        'bodyDevice' => (string)$deviceFromBody,
        'headerNonceSha256' => hash('sha256', (string)($appAuth['nonce'] ?? '')),
        'bodyNonceSha256' => hash('sha256', (string)$nonceFromBody)
    ];

    if (!$integrityToken || !$nonceFromBody || !$deviceFromBody) {
        debugLog('APP_ATTEST_DENY missing required fields', [
            'hasIntegrityToken' => $integrityToken !== '',
            'hasNonce' => $nonceFromBody !== '',
            'hasDevice' => $deviceFromBody !== ''
        ]);
        http_response_code(400);
        echo json_encode(['error' => 'integrityToken, nonce, deviceId required']);
        exit;
    }
    if ($nonceFromBody !== $appAuth['nonce']) {
        debugLog('APP_ATTEST_DENY nonce mismatch', $attestLogBase);
        http_response_code(401);
        echo json_encode(['error' => 'nonce mismatch']);
        exit;
    }
    if ($deviceFromBody !== $appAuth['deviceId']) {
        debugLog('APP_ATTEST_DENY device mismatch', $attestLogBase);
        http_response_code(401);
        echo json_encode(['error' => 'device mismatch']);
        exit;
    }

    $decoded = decodeIntegrityTokenWithGoogle($integrityToken);
    if (!$decoded['ok']) {
        debugLog('APP_ATTEST_DENY integrity verification failed', [
            'detail' => (string)($decoded['error'] ?? 'unknown'),
            'http' => (int)($decoded['http'] ?? 0)
        ]);
        http_response_code(401);
        echo json_encode(['error' => 'integrity verification failed', 'detail' => $decoded['error'] ?? 'unknown']);
        exit;
    }

    $payload = $decoded['data']['tokenPayloadExternal'] ?? [];
    $requestDetails = $payload['requestDetails'] ?? [];
    $appIntegrity = $payload['appIntegrity'] ?? [];
    $deviceIntegrity = $payload['deviceIntegrity'] ?? [];
    $nonceEcho = $requestDetails['nonce'] ?? '';
    $pkgEcho = $requestDetails['requestPackageName'] ?? '';
    $verdict = $appIntegrity['appRecognitionVerdict'] ?? '';
    $certDigests = $appIntegrity['certificateSha256Digest'] ?? [];
    $deviceVerdicts = $deviceIntegrity['deviceRecognitionVerdict'] ?? [];

    if ($nonceEcho !== $nonceFromBody) {
        debugLog('APP_ATTEST_DENY integrity nonce mismatch', [
            'bodyNonceSha256' => hash('sha256', (string)$nonceFromBody),
            'echoNonceSha256' => hash('sha256', (string)$nonceEcho)
        ]);
        http_response_code(401);
        echo json_encode(['error' => 'integrity nonce mismatch']);
        exit;
    }
    if ($pkgEcho !== APP_PACKAGE_NAME) {
        debugLog('APP_ATTEST_DENY package mismatch', [
            'expectedPackage' => APP_PACKAGE_NAME,
            'receivedPackage' => (string)$pkgEcho
        ]);
        http_response_code(401);
        echo json_encode(['error' => 'invalid package name']);
        exit;
    }
    if ($verdict !== 'PLAY_RECOGNIZED') {
        debugLog('APP_ATTEST_DENY app verdict mismatch', [
            'expectedVerdict' => 'PLAY_RECOGNIZED',
            'receivedVerdict' => (string)$verdict
        ]);
        http_response_code(401);
        echo json_encode(['error' => 'app not recognized by Play Integrity', 'verdict' => $verdict]);
        exit;
    }
    if (empty(APP_SIGNING_CERT_SHA256)) {
        debugLog('APP_ATTEST_DENY server misconfigured: APP_SIGNING_CERT_SHA256 missing');
        http_response_code(500);
        echo json_encode(['error' => 'server misconfigured: APP_SIGNING_CERT_SHA256 missing']);
        exit;
    }
    $expectedCertNormalized = normalizeSha256Digest(APP_SIGNING_CERT_SHA256);
    if ($expectedCertNormalized === '') {
        debugLog('APP_ATTEST_DENY server misconfigured: APP_SIGNING_CERT_SHA256 invalid format', [
            'configuredValue' => APP_SIGNING_CERT_SHA256
        ]);
        http_response_code(500);
        echo json_encode(['error' => 'server misconfigured: APP_SIGNING_CERT_SHA256 invalid format']);
        exit;
    }
    $okCert = false;
    $receivedCertNormalized = [];
    foreach ((array)$certDigests as $d) {
        $norm = normalizeSha256Digest((string)$d);
        if ($norm !== '') {
            $receivedCertNormalized[] = formatSha256HexWithColons($norm);
        }
        if ($norm !== '' && hash_equals($expectedCertNormalized, $norm)) {
            $okCert = true;
            break;
        }
    }
    if (!$okCert) {
        debugLog('APP_ATTEST_DENY signing certificate mismatch', [
            'expectedSigningCertSha256Raw' => APP_SIGNING_CERT_SHA256,
            'expectedSigningCertSha256Normalized' => formatSha256HexWithColons($expectedCertNormalized),
            'receivedCertDigestsRaw' => array_values((array)$certDigests),
            'receivedCertDigestsNormalized' => $receivedCertNormalized
        ]);
        http_response_code(401);
        echo json_encode(['error' => 'signing certificate mismatch']);
        exit;
    }
    if (!in_array(PLAY_INTEGRITY_REQUIRED_VERDICT, (array)$deviceVerdicts, true)) {
        debugLog('APP_ATTEST_DENY device integrity verdict mismatch', [
            'requiredVerdict' => PLAY_INTEGRITY_REQUIRED_VERDICT,
            'receivedVerdicts' => array_values((array)$deviceVerdicts)
        ]);
        http_response_code(401);
        echo json_encode(['error' => 'device integrity requirement not met', 'required' => PLAY_INTEGRITY_REQUIRED_VERDICT]);
        exit;
    }

    debugLog('APP_ATTEST_OK session issued', [
        'deviceId' => $deviceFromBody,
        'requiredVerdict' => PLAY_INTEGRITY_REQUIRED_VERDICT,
        'receivedVerdicts' => array_values((array)$deviceVerdicts)
    ]);
    $session = createAppSessionJWT($deviceFromBody, [
        'deviceVerdict' => PLAY_INTEGRITY_REQUIRED_VERDICT,
        'appVerdict' => $verdict
    ]);
    echo json_encode([
        'success' => true,
        'app_session' => $session,
        'expires_in' => APP_SESSION_EXPIRY
    ]);
    exit;
}

if ($action === 'device_register' && $method === 'POST') {
    $appAuth = requireProvisioningAppAuth(false);
    $pdo = requireProvisioningSqlPdo();
    $existing = fetchProvisioningDevice($pdo, (string)$appAuth['deviceId']);
    if ($existing && (string)($existing['status'] ?? '') === 'blocked') {
        http_response_code(403);
        echo json_encode(['error' => 'device_blocked']);
        exit;
    }
    $device = buildProvisioningDeviceRecord($appAuth, $input, $existing);
    if (!upsertProvisioningDevice($pdo, $device)) {
        http_response_code(500);
        echo json_encode(['error' => 'device_register_failed']);
        exit;
    }
    $mismatch = [];
    if ($existing) {
        foreach (['install_id', 'android_id_hash', 'package_name', 'signing_cert_sha256'] as $field) {
            $before = trim((string)($existing[$field] ?? ''));
            $after = trim((string)($device[$field] ?? ''));
            if ($before !== '' && $after !== '' && !hash_equals($before, $after)) {
                $mismatch[$field] = ['before' => $before, 'after' => $after];
            }
        }
    }
    insertProvisioningEvent($pdo, $device['device_id'], empty($existing) ? 'device_register' : 'device_register_refresh', getClientIpAddress(), [
        'integrityLevel' => $device['integrity_level'],
        'hasMismatch' => !empty($mismatch),
        'mismatch' => $mismatch
    ]);
    echo json_encode([
        'success' => true,
        'device' => [
            'deviceId' => $device['device_id'],
            'status' => $device['status'],
            'integrityLevel' => $device['integrity_level'],
            'firstSeenAt' => (int)$device['first_seen_at'],
            'lastSeenAt' => (int)$device['last_seen_at']
        ]
    ]);
    exit;
}

if ($action === 'device_provision' && $method === 'POST') {
    $appAuth = requireProvisioningAppAuth(true);
    $pdo = requireProvisioningSqlPdo();
    $settings = requireProvisioningSettings();
    $protocol = canonicalProvisioningProtocol($input['protocol'] ?? $settings['default_protocol']);
    if ($protocol === '') {
        http_response_code(400);
        echo json_encode(['error' => 'invalid_protocol']);
        exit;
    }
    if ($protocol !== 'ssh') {
        http_response_code(400);
        echo json_encode(['error' => 'protocol_not_supported_in_stage1', 'protocol' => $protocol]);
        exit;
    }
    $existingDevice = fetchProvisioningDevice($pdo, (string)$appAuth['deviceId']);
    if ($existingDevice && (string)($existingDevice['status'] ?? '') === 'blocked') {
        http_response_code(403);
        echo json_encode(['error' => 'device_blocked']);
        exit;
    }
    $device = buildProvisioningDeviceRecord($appAuth, $input, $existingDevice);
    if (!upsertProvisioningDevice($pdo, $device)) {
        http_response_code(500);
        echo json_encode(['error' => 'device_upsert_failed']);
        exit;
    }

    $active = fetchActiveProvisioningCredential($pdo, $device['device_id'], 'ssh');
    $forceRotate = toBool($input['forceRotate'] ?? false, false);
    if ($active && !$forceRotate) {
        touchProvisioningCredential($pdo, (string)$active['credential_id']);
        insertProvisioningEvent($pdo, $device['device_id'], 'device_provision_reuse', getClientIpAddress(), [
            'protocol' => 'ssh',
            'credentialId' => (string)$active['credential_id']
        ]);
        echo json_encode([
            'success' => true,
            'reused' => true,
            'credential' => provisioningCredentialResponse($active)
        ]);
        exit;
    }

    if ($active && $forceRotate) {
        $provisioned = rotateProvisioningSshCredential($settings, $active);
        if (!$provisioned['ok']) {
            http_response_code(502);
            echo json_encode(['error' => 'provisioning_rotate_failed', 'detail' => (string)($provisioned['error'] ?? '')]);
            exit;
        }
        revokeProvisioningCredential($pdo, (string)$active['credential_id'], 'rotated');
        $parentCredentialId = (string)$active['credential_id'];
        $eventType = 'device_rotate';
    } else {
        $provisioned = createProvisioningSshCredential($settings, $device['device_id'], (string)($input['serverId'] ?? ''));
        if (!$provisioned['ok']) {
            http_response_code(502);
            echo json_encode(['error' => 'provisioning_create_failed', 'detail' => (string)($provisioned['error'] ?? '')]);
            exit;
        }
        $parentCredentialId = '';
        $eventType = 'device_provision';
    }

    $secretEnc = encryptProvisioningSecret((string)$provisioned['secret']);
    if ($secretEnc === '') {
        http_response_code(500);
        echo json_encode(['error' => 'secret_encryption_failed']);
        exit;
    }
    $record = [
        'credential_id' => provisioningRandomId(32),
        'device_id' => $device['device_id'],
        'protocol' => 'ssh',
        'server_id' => (string)$provisioned['server_id'],
        'external_ref' => (string)$provisioned['external_ref'],
        'username' => (string)$provisioned['username'],
        'secret_enc' => $secretEnc,
        'secret_hash' => hash('sha256', (string)$provisioned['secret']),
        'secret_preview' => provisioningPreviewSecret((string)$provisioned['secret']),
        'payload' => $provisioned['payload'],
        'status' => 'active',
        'issued_at' => provisioningNowMs(),
        'expires_at' => (int)$provisioned['expires_at'],
        'last_used_at' => 0,
        'revoked_at' => 0,
        'revoked_reason' => '',
        'parent_credential_id' => $parentCredentialId
    ];
    if (!insertProvisioningCredential($pdo, $record)) {
        http_response_code(500);
        echo json_encode(['error' => 'credential_store_failed']);
        exit;
    }
    $created = fetchActiveProvisioningCredential($pdo, $device['device_id'], 'ssh');
    insertProvisioningEvent($pdo, $device['device_id'], $eventType, getClientIpAddress(), [
        'protocol' => 'ssh',
        'serverId' => (string)$record['server_id'],
        'username' => (string)$record['username']
    ]);
    echo json_encode([
        'success' => true,
        'reused' => false,
        'credential' => provisioningCredentialResponse($created ?: $record)
    ]);
    exit;
}

if ($action === 'device_credentials' && $method === 'GET') {
    $appAuth = requireProvisioningAppAuth(true);
    $pdo = requireProvisioningSqlPdo();
    $existingDevice = fetchProvisioningDevice($pdo, (string)$appAuth['deviceId']);
    if ($existingDevice && (string)($existingDevice['status'] ?? '') === 'blocked') {
        http_response_code(403);
        echo json_encode(['error' => 'device_blocked']);
        exit;
    }
    $protocol = canonicalProvisioningProtocol($_GET['protocol'] ?? '');
    if ($protocol === '') $protocol = null;
    if ($protocol !== null && $protocol !== 'ssh') {
        http_response_code(400);
        echo json_encode(['error' => 'protocol_not_supported_in_stage1', 'protocol' => $protocol]);
        exit;
    }
    $rows = fetchProvisioningCredentials($pdo, (string)$appAuth['deviceId'], $protocol);
    $credentials = [];
    foreach ($rows as $row) {
        if (is_array($row)) {
            touchProvisioningCredential($pdo, (string)$row['credential_id']);
            $credentials[] = provisioningCredentialResponse($row);
        }
    }
    insertProvisioningEvent($pdo, (string)$appAuth['deviceId'], 'device_credentials_read', getClientIpAddress(), [
        'count' => count($credentials),
        'protocol' => $protocol ?: 'all'
    ]);
    echo json_encode([
        'success' => true,
        'credentials' => $credentials
    ]);
    exit;
}

if ($action === 'device_rotate' && $method === 'POST') {
    $appAuth = requireProvisioningAppAuth(true);
    $pdo = requireProvisioningSqlPdo();
    $settings = requireProvisioningSettings();
    $existingDevice = fetchProvisioningDevice($pdo, (string)$appAuth['deviceId']);
    if ($existingDevice && (string)($existingDevice['status'] ?? '') === 'blocked') {
        http_response_code(403);
        echo json_encode(['error' => 'device_blocked']);
        exit;
    }
    $protocol = canonicalProvisioningProtocol($input['protocol'] ?? 'ssh');
    if ($protocol !== 'ssh') {
        http_response_code(400);
        echo json_encode(['error' => 'protocol_not_supported_in_stage1', 'protocol' => $protocol]);
        exit;
    }
    $active = fetchActiveProvisioningCredential($pdo, (string)$appAuth['deviceId'], 'ssh');
    if (!$active) {
        http_response_code(404);
        echo json_encode(['error' => 'active_credential_not_found']);
        exit;
    }
    $rotated = rotateProvisioningSshCredential($settings, $active);
    if (!$rotated['ok']) {
        http_response_code(502);
        echo json_encode(['error' => 'rotate_failed', 'detail' => (string)($rotated['error'] ?? '')]);
        exit;
    }
    $secretEnc = encryptProvisioningSecret((string)$rotated['secret']);
    if ($secretEnc === '') {
        http_response_code(500);
        echo json_encode(['error' => 'secret_encryption_failed']);
        exit;
    }
    revokeProvisioningCredential($pdo, (string)$active['credential_id'], 'rotated');
    $record = [
        'credential_id' => provisioningRandomId(32),
        'device_id' => (string)$appAuth['deviceId'],
        'protocol' => 'ssh',
        'server_id' => (string)$rotated['server_id'],
        'external_ref' => (string)$rotated['external_ref'],
        'username' => (string)$rotated['username'],
        'secret_enc' => $secretEnc,
        'secret_hash' => hash('sha256', (string)$rotated['secret']),
        'secret_preview' => provisioningPreviewSecret((string)$rotated['secret']),
        'payload' => $rotated['payload'],
        'status' => 'active',
        'issued_at' => provisioningNowMs(),
        'expires_at' => (int)$rotated['expires_at'],
        'last_used_at' => 0,
        'revoked_at' => 0,
        'revoked_reason' => '',
        'parent_credential_id' => (string)$active['credential_id']
    ];
    if (!insertProvisioningCredential($pdo, $record)) {
        http_response_code(500);
        echo json_encode(['error' => 'credential_store_failed']);
        exit;
    }
    $created = fetchActiveProvisioningCredential($pdo, (string)$appAuth['deviceId'], 'ssh');
    insertProvisioningEvent($pdo, (string)$appAuth['deviceId'], 'device_rotate', getClientIpAddress(), [
        'protocol' => 'ssh',
        'previousCredentialId' => (string)$active['credential_id'],
        'username' => (string)$record['username']
    ]);
    echo json_encode([
        'success' => true,
        'credential' => provisioningCredentialResponse($created ?: $record)
    ]);
    exit;
}

if ($action === 'device_revoke' && $method === 'POST') {
    $adminAuth = tryRequireAdminAuth();
    $appAuth = null;
    if (!$adminAuth) {
        $appAuth = requireProvisioningAppAuth(true);
    }
    $pdo = requireProvisioningSqlPdo();
    $settings = requireProvisioningSettings();
    $protocol = canonicalProvisioningProtocol($input['protocol'] ?? 'ssh');
    if ($protocol !== 'ssh') {
        http_response_code(400);
        echo json_encode(['error' => 'protocol_not_supported_in_stage1', 'protocol' => $protocol]);
        exit;
    }
    $deviceId = $adminAuth
        ? normalizeUserId($input['deviceId'] ?? $input['userId'] ?? '')
        : normalizeUserId($appAuth['deviceId'] ?? '');
    if ($deviceId === '') {
        http_response_code(400);
        echo json_encode(['error' => 'deviceId required']);
        exit;
    }
    $active = fetchActiveProvisioningCredential($pdo, $deviceId, 'ssh');
    if (!$active) {
        echo json_encode(['success' => true, 'revoked' => false]);
        exit;
    }
    $remote = revokeProvisioningSshCredentialRemote($settings, $active);
    if (!$remote['ok']) {
        http_response_code(502);
        echo json_encode(['error' => 'revoke_failed', 'detail' => (string)($remote['error'] ?? '')]);
        exit;
    }
    revokeProvisioningCredential($pdo, (string)$active['credential_id'], 'revoked');
    if ($adminAuth && toBool($input['blockDevice'] ?? false, false)) {
        $stmt = $pdo->prepare('UPDATE app_devices SET status = :status, last_seen_at = :last_seen_at WHERE device_id = :device_id');
        $stmt->execute([
            ':status' => 'blocked',
            ':last_seen_at' => provisioningNowMs(),
            ':device_id' => $deviceId
        ]);
    }
    insertProvisioningEvent($pdo, $deviceId, 'device_revoke', getClientIpAddress(), [
        'protocol' => 'ssh',
        'credentialId' => (string)$active['credential_id'],
        'adminUser' => (string)($adminAuth['user'] ?? '')
    ]);
    echo json_encode(['success' => true, 'revoked' => true]);
    exit;
}

if ($action === 'device_heartbeat' && $method === 'POST') {
    $appAuth = requireProvisioningAppAuth(false);
    $pdo = requireProvisioningSqlPdo();
    $existing = fetchProvisioningDevice($pdo, (string)$appAuth['deviceId']);
    if ($existing && (string)($existing['status'] ?? '') === 'blocked') {
        http_response_code(403);
        echo json_encode(['error' => 'device_blocked']);
        exit;
    }
    $device = buildProvisioningDeviceRecord($appAuth, $input, $existing);
    if (!upsertProvisioningDevice($pdo, $device)) {
        http_response_code(500);
        echo json_encode(['error' => 'device_heartbeat_failed']);
        exit;
    }
    $rows = fetchProvisioningCredentials($pdo, $device['device_id']);
    $active = [];
    foreach ($rows as $row) {
        if (is_array($row)) {
            $active[] = [
                'credentialId' => (string)($row['credential_id'] ?? ''),
                'protocol' => (string)($row['protocol'] ?? ''),
                'username' => (string)($row['username'] ?? ''),
                'status' => (string)($row['status'] ?? ''),
                'expiresAt' => (int)($row['expires_at'] ?? 0)
            ];
        }
    }
    insertProvisioningEvent($pdo, $device['device_id'], 'device_heartbeat', getClientIpAddress(), [
        'activeCredentials' => count($active)
    ]);
    echo json_encode([
        'success' => true,
        'device' => [
            'deviceId' => $device['device_id'],
            'status' => $device['status'],
            'integrityLevel' => $device['integrity_level'],
            'lastSeenAt' => (int)$device['last_seen_at']
        ],
        'activeCredentials' => $active
    ]);
    exit;
}

if ($action === 'app_coin_state' && $method === 'GET') {
    $appAuth = requireAppAuth();
    $deviceId = normalizeUserId($_GET['deviceId'] ?? $appAuth['deviceId'] ?? '');
    if ($deviceId === '' || $deviceId !== $appAuth['deviceId']) {
        http_response_code(401);
        echo json_encode(['error' => 'device mismatch']);
        exit;
    }

    $users = loadUserCoins();
    $user = getUserOrDefault($users, $deviceId);

    echo json_encode([
        'success' => true,
        'deviceId' => $deviceId,
        'coins' => (int)($user['coins'] ?? 0),
        'banned' => toBool($user['banned'] ?? false, false),
        'canRedeem' => toBool($user['canRedeem'] ?? true, true),
        'canReceiveCoins' => toBool($user['canReceiveCoins'] ?? true, true),
        'canSendCoins' => toBool($user['canSendCoins'] ?? true, true),
        'adOnlyEarning' => toBool($user['adOnlyEarning'] ?? false, false),
        'lastUpdated' => (int)($user['lastUpdated'] ?? 0)
    ]);
    exit;
}

if ($action === 'app_coin_sync' && $method === 'POST') {
    $appAuth = requireAppAuth();
    $policy = getAppPolicySettings();
    $allowCoinSync = toBool($policy['allow_coin_sync'] ?? APP_ALLOW_COIN_SYNC, APP_ALLOW_COIN_SYNC);
    if (!$allowCoinSync) {
        http_response_code(403);
        echo json_encode(['error' => 'coin sync disabled by admin policy']);
        exit;
    }
    $deviceId = normalizeUserId($input['deviceId'] ?? '');
    $coins = (int)($input['coins'] ?? 0);
    $authUid = (string)($input['authUid'] ?? '');
    if ($deviceId === '' || $deviceId !== $appAuth['deviceId']) {
        http_response_code(401);
        echo json_encode(['error' => 'device mismatch']);
        exit;
    }
    if ($coins < 0) {
        http_response_code(400);
        echo json_encode(['error' => 'invalid coins']);
        exit;
    }
    $rateWindow = max(15, (int)($policy['coin_sync_rate_window_seconds'] ?? APP_RATE_COIN_SYNC_WINDOW_SECONDS));
    $rateMax = max(3, (int)($policy['coin_sync_rate_device_max'] ?? APP_RATE_COIN_SYNC_DEVICE_MAX));
    $maxIncrease = max(0, (int)($policy['coin_sync_max_increase'] ?? APP_COIN_SYNC_MAX_INCREASE));
    $maxDecrease = max(0, (int)($policy['coin_sync_max_decrease'] ?? APP_COIN_SYNC_MAX_DECREASE));
    enforceSimpleRateLimit(
        'app_coin_sync_device',
        $deviceId,
        $rateMax,
        $rateWindow,
        'coin_sync_rate_limited'
    );

    $users = loadUserCoins();
    $isNewUserDevice = !isset($users[$deviceId]) || !is_array($users[$deviceId]);
    $newUserBonusCoins = resolveNewUserBonusCoinsFromPolicy($policy);
    if ($isNewUserDevice && $newUserBonusCoins > 0 && $coins < $newUserBonusCoins) {
        // First sync on a fresh install: keep minimum onboarding compensation.
        $coins = $newUserBonusCoins;
    }
    $user = getUserOrDefault($users, $deviceId);
    $nowMs = (int)(microtime(true) * 1000);
    $before = (int)($user['coins'] ?? 0);
    $delta = $coins - $before;
    $rejectReason = '';

    // Anti-tamper guards: limit per-request drift so stale/malicious clients
    // cannot quickly overwrite authoritative server balances.
    if ($delta > $maxIncrease) {
        $rejectReason = 'increase_delta_exceeded';
    } elseif ((-$delta) > $maxDecrease) {
        $rejectReason = 'decrease_delta_exceeded';
    }
    if ($rejectReason !== '') {
        appendCoinLedgerEntry([
            'deviceId' => $deviceId,
            'action' => 'APP_SYNC_REJECTED',
            'requestedCoins' => $coins,
            'beforeCoins' => $before,
            'afterCoins' => $before,
            'delta' => $delta,
            'reason' => $rejectReason,
            'source' => 'app_coin_sync',
            'createdAt' => $nowMs
        ]);
        http_response_code(409);
        echo json_encode([
            'error' => 'coin_sync_rejected',
            'reason' => $rejectReason,
            'coins' => $before,
            'serverAuthoritative' => true
        ]);
        exit;
    }

    $user['coins'] = $coins;
    $user['lastUpdated'] = $nowMs;
    $user['lastActive'] = $nowMs;
    if ($authUid !== '') $user['authUid'] = $authUid;
    $users[$deviceId] = $user;

    if (!saveUserCoins($users)) {
        http_response_code(500);
        echo json_encode(['error' => 'coin sync failed']);
        exit;
    }

    appendCoinLedgerEntry([
        'deviceId' => $deviceId,
        'action' => 'APP_SYNC',
        'coins' => $coins,
        'beforeCoins' => $before,
        'afterCoins' => $coins,
        'delta' => $delta,
        'source' => 'app_coin_sync',
        'createdAt' => $nowMs
    ]);

    echo json_encode(['success' => true, 'coins' => $coins]);
    exit;
}

if ($action === 'app_redeem_code' && $method === 'POST') {
    $appAuth = requireAppAuth();
    $policy = getAppPolicySettings();
    $allowLegacyRedeem = toBool($policy['allow_legacy_redeem_codes'] ?? APP_ALLOW_LEGACY_REDEEM_CODES, APP_ALLOW_LEGACY_REDEEM_CODES);
    $maxLegacyRedeemCoins = (int)($policy['max_legacy_redeem_coins'] ?? APP_MAX_LEGACY_REDEEM_COINS);
    if ($maxLegacyRedeemCoins < 1) $maxLegacyRedeemCoins = 1;
    $deviceId = normalizeUserId($input['deviceId'] ?? '');
    $code = normalizeRedeemCode($input['code'] ?? '');
    $coins = (int)($input['coins'] ?? 0);
    $authUid = (string)($input['authUid'] ?? '');

    if ($deviceId === '' || $deviceId !== $appAuth['deviceId']) {
        http_response_code(401);
        echo json_encode(['error' => 'device mismatch']);
        exit;
    }
    enforceSimpleRateLimit(
        'app_redeem_device',
        $deviceId,
        APP_RATE_REDEEM_DEVICE_MAX,
        APP_RATE_REDEEM_WINDOW_SECONDS,
        'redeem_rate_limited'
    );
    if ($code === '') {
        http_response_code(400);
        echo json_encode(['error' => 'code required']);
        exit;
    }

    $users = loadUserCoins();
    $user = getUserOrDefault($users, $deviceId);
    if (($user['banned'] ?? false) === true || ($user['canRedeem'] ?? true) === false) {
        http_response_code(403);
        echo json_encode(['error' => 'redeem disabled for this user']);
        exit;
    }

    $redeemed = loadRedeemedCodes();
    if (isset($redeemed[$code])) {
        http_response_code(409);
        echo json_encode(['error' => 'code already redeemed']);
        exit;
    }

    $codePool = loadCoinCodePool();
    $codeItem = isset($codePool[$code]) && is_array($codePool[$code]) ? $codePool[$code] : null;
    if (!$codeItem && !$allowLegacyRedeem) {
        http_response_code(404);
        echo json_encode(['error' => 'invalid code']);
        exit;
    }

    $nowMs = (int)(microtime(true) * 1000);
    $coinsToAdd = 0;
    $isLegacyRedeem = false;
    if ($codeItem) {
        $expiresAt = (int)($codeItem['expiresAt'] ?? 0);
        if ($expiresAt > 0 && $nowMs > $expiresAt) {
            http_response_code(410);
            echo json_encode(['error' => 'code expired']);
            exit;
        }
        if (!empty($codeItem['used'])) {
            http_response_code(409);
            echo json_encode(['error' => 'code already redeemed']);
            exit;
        }
        $coinsToAdd = (int)($codeItem['coins'] ?? 0);
        if ($coinsToAdd <= 0 && $coins > 0) {
            $coinsToAdd = $coins;
        }
    } else {
        $isLegacyRedeem = true;
        if ($coins <= 0) {
            http_response_code(400);
            echo json_encode(['error' => 'legacy redeem requires coins value']);
            exit;
        }
        if ($coins > $maxLegacyRedeemCoins) {
            http_response_code(400);
            echo json_encode(['error' => 'legacy redeem exceeds max allowed coins', 'max' => $maxLegacyRedeemCoins]);
            exit;
        }
        $coinsToAdd = $coins;
    }
    if ($coinsToAdd <= 0) {
        http_response_code(400);
        echo json_encode(['error' => 'invalid code amount']);
        exit;
    }

    $redeemed[$code] = [
        'redeemedAt' => $nowMs,
        'redeemedBy' => $deviceId,
        'coins' => $coinsToAdd
    ];
    if (!saveRedeemedCodes($redeemed)) {
        http_response_code(500);
        echo json_encode(['error' => 'failed to mark redeemed']);
        exit;
    }

    $before = (int)($user['coins'] ?? 0);
    $after = $before + $coinsToAdd;
    $user['coins'] = $after;
    $user['lastUpdated'] = $nowMs;
    $user['lastActive'] = $nowMs;
    $user['lastRedeemAt'] = $nowMs;
    if ($authUid !== '') $user['authUid'] = $authUid;
    $users[$deviceId] = $user;
    if (!saveUserCoins($users)) {
        http_response_code(500);
        echo json_encode(['error' => 'redeem saved but coin update failed']);
        exit;
    }

    if (!$isLegacyRedeem) {
        $codeItem['used'] = true;
        $codeItem['usedBy'] = $deviceId;
        $codeItem['usedAt'] = $nowMs;
        $codePool[$code] = $codeItem;
        saveCoinCodePool($codePool);
    }

    appendCoinLedgerEntry([
        'deviceId' => $deviceId,
        'action' => $isLegacyRedeem ? 'REDEEM_LEGACY' : 'REDEEM',
        'coins' => $coinsToAdd,
        'beforeCoins' => $before,
        'afterCoins' => $after,
        'code' => $code,
        'createdAt' => $nowMs
    ]);

    echo json_encode(['success' => true, 'beforeCoins' => $before, 'afterCoins' => $after]);
    exit;
}

// APP OTA CONFIG (APP-SIGNED)
if ($action === 'app_config' && $method === 'GET') {
    $appAuth = requireAppAuth();
    debugLog('APP CONFIG REQUEST', $appAuth);
    if (!file_exists(CONFIG_FILE)) {
        http_response_code(404);
        echo json_encode(['error' => 'Config not found']);
        exit;
    }
    header('Content-Type: text/plain');
    echo file_get_contents(CONFIG_FILE);
    exit;
}

// APP COIN UPDATES (APP-SIGNED)
if ($action === 'app_coin_updates' && $method === 'GET') {
    $appAuth = requireAppAuth();
    debugLog('APP COIN UPDATE REQUEST', $appAuth);
    header('Content-Type: text/plain');
    if (!file_exists(APP_COIN_UPDATES_FILE)) {
        echo '[]';
        exit;
    }
    $raw = file_get_contents(APP_COIN_UPDATES_FILE);
    echo ($raw === false || trim($raw) === '') ? '[]' : $raw;
    exit;
}

// GET CONFIG
if ($method === 'GET' && !$action) {
    requireAuth();
    if (!file_exists(CONFIG_FILE)) {
        http_response_code(404);
        echo json_encode(['error' => 'Config not found']);
        exit;
    }
    header('Content-Type: text/plain');
    echo file_get_contents(CONFIG_FILE);
    exit;
}

// PUBLISH CONFIG
if (($action === 'publish' || $action === 'publish_config') && $method === 'POST') {
    requireAuth();
    $config = $input['config'] ?? '';
    if (empty($config)) {
        http_response_code(400);
        echo json_encode(['error' => 'Config required']);
        exit;
    }
    file_put_contents(CONFIG_FILE, $config);
    echo json_encode(['success' => true, 'saved_bytes' => strlen($config)]);
    exit;
}

// USER MANAGEMENT
if ($action === 'users' && $method === 'GET') {
    requireAuth();
    $usersMap = loadUserCoins();
    $users = array_values($usersMap);
    usort($users, function ($a, $b) {
        return (int)($b['coins'] ?? 0) <=> (int)($a['coins'] ?? 0);
    });
    echo json_encode(['success' => true, 'users' => $users]);
    exit;
}

if ($action === 'ban_user' && $method === 'POST') {
    requireAuth();
    $deviceId = normalizeUserId($input['userId'] ?? $input['deviceId'] ?? '');
    if ($deviceId === '') {
        http_response_code(400);
        echo json_encode(['error' => 'deviceId required']);
        exit;
    }
    $users = loadUserCoins();
    $user = getUserOrDefault($users, $deviceId);
    $nowMs = (int)(microtime(true) * 1000);
    $before = (int)($user['coins'] ?? 0);
    $user['banned'] = true;
    $user['canRedeem'] = false;
    $user['canReceiveCoins'] = false;
    $user['canSendCoins'] = false;
    $user['adOnlyEarning'] = true;
    $user['coins'] = 0;
    $user['lastUpdated'] = $nowMs;
    $user['banUpdatedAt'] = $nowMs;
    $users[$deviceId] = $user;
    if (!saveUserCoins($users)) {
        http_response_code(500);
        echo json_encode(['error' => 'failed to ban user']);
        exit;
    }
    appendCoinLedgerEntry([
        'deviceId' => $deviceId,
        'action' => 'BAN_RESET',
        'coins' => -$before,
        'beforeCoins' => $before,
        'afterCoins' => 0,
        'createdAt' => $nowMs
    ]);
    echo json_encode(['success' => true, 'userId' => $deviceId]);
    exit;
}

if ($action === 'unban_user' && $method === 'POST') {
    requireAuth();
    $deviceId = normalizeUserId($input['userId'] ?? $input['deviceId'] ?? '');
    if ($deviceId === '') {
        http_response_code(400);
        echo json_encode(['error' => 'deviceId required']);
        exit;
    }
    $users = loadUserCoins();
    $user = getUserOrDefault($users, $deviceId);
    $nowMs = (int)(microtime(true) * 1000);
    $user['banned'] = false;
    $user['canRedeem'] = true;
    $user['canReceiveCoins'] = true;
    $user['canSendCoins'] = true;
    $user['adOnlyEarning'] = false;
    $user['lastUpdated'] = $nowMs;
    $user['banUpdatedAt'] = $nowMs;
    $users[$deviceId] = $user;
    if (!saveUserCoins($users)) {
        http_response_code(500);
        echo json_encode(['error' => 'failed to restore user']);
        exit;
    }
    appendCoinLedgerEntry([
        'deviceId' => $deviceId,
        'action' => 'UNBAN',
        'coins' => 0,
        'beforeCoins' => (int)($user['coins'] ?? 0),
        'afterCoins' => (int)($user['coins'] ?? 0),
        'createdAt' => $nowMs
    ]);
    echo json_encode(['success' => true, 'userId' => $deviceId]);
    exit;
}

if ($action === 'update_coins' && $method === 'POST') {
    requireAuth();
    $deviceId = normalizeUserId($input['userId'] ?? $input['deviceId'] ?? '');
    $coins = (int)($input['coins'] ?? 0);
    $reason = trim((string)($input['reason'] ?? ''));
    if ($deviceId === '') {
        http_response_code(400);
        echo json_encode(['error' => 'deviceId required']);
        exit;
    }
    if ($coins <= 0) {
        http_response_code(400);
        echo json_encode(['error' => 'coins must be > 0']);
        exit;
    }
    $users = loadUserCoins();
    $user = getUserOrDefault($users, $deviceId);
    if (($user['banned'] ?? false) === true || ($user['canReceiveCoins'] ?? true) === false) {
        http_response_code(403);
        echo json_encode(['error' => 'user cannot receive coins']);
        exit;
    }
    $nowMs = (int)(microtime(true) * 1000);
    $before = (int)($user['coins'] ?? 0);
    $after = $before + $coins;
    $user['coins'] = $after;
    $user['lastUpdated'] = $nowMs;
    $user['lastAdminGrantAt'] = $nowMs;
    $users[$deviceId] = $user;
    if (!saveUserCoins($users)) {
        http_response_code(500);
        echo json_encode(['error' => 'failed to update coins']);
        exit;
    }
    appendCoinLedgerEntry([
        'deviceId' => $deviceId,
        'action' => 'ADMIN_GRANT',
        'coins' => $coins,
        'beforeCoins' => $before,
        'afterCoins' => $after,
        'reason' => $reason,
        'createdAt' => $nowMs
    ]);
    echo json_encode(['success' => true, 'userId' => $deviceId, 'beforeCoins' => $before, 'afterCoins' => $after]);
    exit;
}

if ($action === 'coin_compensate_existing' && $method === 'POST') {
    $auth = requireAuth();
    $coins = (int)($input['coins'] ?? 0);
    $onlyZeroBalance = toBool($input['onlyZeroBalance'] ?? true, true);
    $excludeBanned = toBool($input['excludeBanned'] ?? true, true);
    $dryRun = toBool($input['dryRun'] ?? false, false);
    $reason = trim((string)($input['reason'] ?? ''));
    if ($coins <= 0) {
        http_response_code(400);
        echo json_encode(['error' => 'coins must be > 0']);
        exit;
    }

    $users = loadUserCoins();
    if (!is_array($users)) $users = [];
    if (empty($users)) {
        echo json_encode([
            'success' => true,
            'updatedUsers' => 0,
            'skippedUsers' => 0,
            'totalCoinsGranted' => 0,
            'dryRun' => $dryRun,
            'ledgerSaved' => true
        ]);
        exit;
    }

    $nowMs = (int)(microtime(true) * 1000);
    $entries = $users;
    $updatedUsers = 0;
    $skippedUsers = 0;
    $totalCoinsGranted = 0;
    $ledgerEntries = [];

    foreach ($entries as $entryKey => $row) {
        if (!is_array($row)) {
            $skippedUsers++;
            continue;
        }
        $deviceId = normalizeUserId($row['deviceId'] ?? $entryKey);
        if ($deviceId === '') {
            $skippedUsers++;
            continue;
        }

        $user = $row;
        $user['deviceId'] = $deviceId;
        $user['coins'] = (int)($user['coins'] ?? 0);
        $user['banned'] = toBool($user['banned'] ?? false, false);
        $user['canReceiveCoins'] = toBool($user['canReceiveCoins'] ?? true, true);

        if ($excludeBanned && $user['banned']) {
            $skippedUsers++;
            continue;
        }
        if (!$user['canReceiveCoins']) {
            $skippedUsers++;
            continue;
        }
        if ($onlyZeroBalance && $user['coins'] > 0) {
            $skippedUsers++;
            continue;
        }

        $before = (int)$user['coins'];
        $after = $before + $coins;

        $updatedUsers++;
        $totalCoinsGranted += $coins;
        if (!$dryRun) {
            $user['coins'] = $after;
            $user['lastUpdated'] = $nowMs;
            $user['lastActive'] = $nowMs;
            $user['lastAdminGrantAt'] = $nowMs;
            $users[$deviceId] = $user;
            if ($deviceId !== $entryKey && isset($users[$entryKey])) unset($users[$entryKey]);
            $ledgerEntries[] = [
                'deviceId' => $deviceId,
                'action' => 'ADMIN_COMPENSATE_EXISTING',
                'coins' => $coins,
                'beforeCoins' => $before,
                'afterCoins' => $after,
                'reason' => $reason,
                'criteria' => $onlyZeroBalance ? 'zero_balance_only' : 'all_existing',
                'createdAt' => $nowMs,
                'by' => (string)($auth['user'] ?? 'admin')
            ];
        }
    }

    if ($updatedUsers === 0) {
        echo json_encode([
            'success' => true,
            'updatedUsers' => 0,
            'skippedUsers' => $skippedUsers,
            'totalCoinsGranted' => 0,
            'dryRun' => $dryRun,
            'ledgerSaved' => true
        ]);
        exit;
    }

    if ($dryRun) {
        echo json_encode([
            'success' => true,
            'updatedUsers' => $updatedUsers,
            'skippedUsers' => $skippedUsers,
            'totalCoinsGranted' => $totalCoinsGranted,
            'dryRun' => true,
            'ledgerSaved' => true,
            'criteria' => [
                'onlyZeroBalance' => $onlyZeroBalance,
                'excludeBanned' => $excludeBanned
            ]
        ]);
        exit;
    }

    if (!saveUserCoins($users)) {
        http_response_code(500);
        echo json_encode(['error' => 'failed to save user compensation']);
        exit;
    }

    $ledgerSaved = true;
    if (!empty($ledgerEntries)) {
        $ledger = loadCoinLedger();
        if (!is_array($ledger)) $ledger = [];
        foreach ($ledgerEntries as $entry) {
            $ledger[] = $entry;
        }
        if (count($ledger) > 5000) {
            $ledger = array_slice($ledger, -5000);
        }
        $ledgerSaved = saveCoinLedger($ledger);
        if (!$ledgerSaved) {
            debugLog('coin_compensate_existing: failed to save ledger batch', ['count' => count($ledgerEntries)]);
        }
    }

    echo json_encode([
        'success' => true,
        'updatedUsers' => $updatedUsers,
        'skippedUsers' => $skippedUsers,
        'totalCoinsGranted' => $totalCoinsGranted,
        'dryRun' => false,
        'ledgerSaved' => $ledgerSaved,
        'criteria' => [
            'onlyZeroBalance' => $onlyZeroBalance,
            'excludeBanned' => $excludeBanned
        ]
    ]);
    exit;
}

// ACTIVITY LOG
if ($action === 'activity' && $method === 'GET') {
    requireAuth();
    $limit = (int)($_GET['limit'] ?? 100);
    if ($limit <= 0) $limit = 100;
    if ($limit > 500) $limit = 500;
    $ledger = loadCoinLedger();
    $activities = array_slice(array_reverse($ledger), 0, $limit);
    echo json_encode(['success' => true, 'activities' => $activities]);
    exit;
}

if ($action === 'log_activity' && $method === 'POST') {
    requireAuth();
    $entry = [
        'action' => (string)($input['actionName'] ?? 'ADMIN_ACTION'),
        'deviceId' => (string)($input['deviceId'] ?? ''),
        'details' => is_array($input['details'] ?? null) ? $input['details'] : [],
        'createdAt' => (int)(microtime(true) * 1000)
    ];
    appendCoinLedgerEntry($entry);
    echo json_encode(['success' => true]);
    exit;
}

// CODE GENERATION
if ($action === 'generate_codes' && $method === 'POST') {
    requireAuth();
    $count = max(1, min(200, (int)($input['count'] ?? 1)));
    $coins = (int)($input['coins'] ?? 10);
    $hours = max(1, min(24 * 30, (int)($input['hours'] ?? 24)));
    if ($coins <= 0) {
        http_response_code(400);
        echo json_encode(['error' => 'coins must be > 0']);
        exit;
    }
    $pool = loadCoinCodePool();
    $nowMs = (int)(microtime(true) * 1000);
    $expiresAt = $nowMs + ($hours * 60 * 60 * 1000);
    $codes = [];
    for ($i = 0; $i < $count; $i++) {
        do {
            $code = generateCoinCode();
        } while (isset($pool[$code]));
        $pool[$code] = [
            'code' => $code,
            'coins' => $coins,
            'createdAt' => $nowMs,
            'expiresAt' => $expiresAt,
            'used' => false
        ];
        $codes[] = [
            'code' => $code,
            'coins' => $coins,
            'createdAt' => $nowMs,
            'expiresAt' => $expiresAt
        ];
    }
    if (!saveCoinCodePool($pool)) {
        http_response_code(500);
        echo json_encode(['error' => 'failed to save code pool']);
        exit;
    }
    echo json_encode(['success' => true, 'codes' => $codes]);
    exit;
}

if ($action === 'codes' && $method === 'GET') {
    requireAuth();
    $pool = loadCoinCodePool();
    $codes = array_values($pool);
    usort($codes, function ($a, $b) {
        return (int)($b['createdAt'] ?? 0) <=> (int)($a['createdAt'] ?? 0);
    });
    $limit = (int)($_GET['limit'] ?? 200);
    if ($limit <= 0) $limit = 200;
    if ($limit > 1000) $limit = 1000;
    echo json_encode(['success' => true, 'codes' => array_slice($codes, 0, $limit)]);
    exit;
}

if ($action === 'redeem_code' && $method === 'POST') {
    requireAuth();
    $deviceId = normalizeUserId($input['userId'] ?? $input['deviceId'] ?? '');
    $code = normalizeRedeemCode($input['code'] ?? '');
    if ($deviceId === '' || $code === '') {
        http_response_code(400);
        echo json_encode(['error' => 'deviceId and code required']);
        exit;
    }
    $users = loadUserCoins();
    $user = getUserOrDefault($users, $deviceId);
    if (($user['banned'] ?? false) === true || ($user['canReceiveCoins'] ?? true) === false) {
        http_response_code(403);
        echo json_encode(['error' => 'user cannot receive coins']);
        exit;
    }
    $redeemed = loadRedeemedCodes();
    if (isset($redeemed[$code])) {
        http_response_code(409);
        echo json_encode(['error' => 'code already redeemed']);
        exit;
    }
    $pool = loadCoinCodePool();
    $codeItem = isset($pool[$code]) && is_array($pool[$code]) ? $pool[$code] : null;
    if (!$codeItem) {
        http_response_code(404);
        echo json_encode(['error' => 'invalid code']);
        exit;
    }
    $nowMs = (int)(microtime(true) * 1000);
    if (!empty($codeItem['used'])) {
        http_response_code(409);
        echo json_encode(['error' => 'code already redeemed']);
        exit;
    }
    $expiresAt = (int)($codeItem['expiresAt'] ?? 0);
    if ($expiresAt > 0 && $nowMs > $expiresAt) {
        http_response_code(410);
        echo json_encode(['error' => 'code expired']);
        exit;
    }
    $coins = (int)($codeItem['coins'] ?? 0);
    if ($coins <= 0) {
        http_response_code(400);
        echo json_encode(['error' => 'invalid code amount']);
        exit;
    }
    $before = (int)($user['coins'] ?? 0);
    $after = $before + $coins;
    $user['coins'] = $after;
    $user['lastUpdated'] = $nowMs;
    $user['lastRedeemAt'] = $nowMs;
    $users[$deviceId] = $user;
    $redeemed[$code] = [
        'redeemedAt' => $nowMs,
        'redeemedBy' => $deviceId,
        'coins' => $coins,
        'via' => 'admin'
    ];
    $codeItem['used'] = true;
    $codeItem['usedBy'] = $deviceId;
    $codeItem['usedAt'] = $nowMs;
    $pool[$code] = $codeItem;
    $okUsers = saveUserCoins($users);
    $okRedeemed = saveRedeemedCodes($redeemed);
    $okPool = saveCoinCodePool($pool);
    if (!$okUsers || !$okRedeemed || !$okPool) {
        http_response_code(500);
        echo json_encode(['error' => 'failed to redeem code']);
        exit;
    }
    appendCoinLedgerEntry([
        'deviceId' => $deviceId,
        'action' => 'REDEEM_ADMIN',
        'coins' => $coins,
        'beforeCoins' => $before,
        'afterCoins' => $after,
        'code' => $code,
        'createdAt' => $nowMs
    ]);
    echo json_encode(['success' => true, 'beforeCoins' => $before, 'afterCoins' => $after]);
    exit;
}

if ($action === 'publish_coin_updates' && $method === 'POST') {
    requireAuth();
    $encrypted = $input['encrypted'] ?? '';
    if (is_string($encrypted) && trim($encrypted) !== '') {
        file_put_contents(APP_COIN_UPDATES_FILE, trim($encrypted));
        echo json_encode(['success' => true, 'mode' => 'encrypted']);
        exit;
    }
    $updates = $input['updates'] ?? null;
    if (!is_array($updates)) {
        http_response_code(400);
        echo json_encode(['error' => 'encrypted string or updates array required']);
        exit;
    }
    file_put_contents(APP_COIN_UPDATES_FILE, json_encode($updates, JSON_UNESCAPED_SLASHES));
    echo json_encode(['success' => true, 'saved' => count($updates)]);
    exit;
}

// BROADCAST
if ($action === 'broadcast' && $method === 'POST') {
    requireAuth();
    $title = $input['title'] ?? '';
    $body = $input['body'] ?? '';
    if (empty($title) || empty($body)) {
        http_response_code(400);
        echo json_encode(['error' => 'Title and body required']);
        exit;
    }
    $rawData = $input['data'] ?? [];
    $dataMap = [];
    if (is_array($rawData)) {
        foreach ($rawData as $k => $v) {
            if (is_string($k) && $k !== '') {
                if (is_scalar($v) || $v === null) {
                    $dataMap[$k] = (string)$v;
                } else {
                    $dataMap[$k] = json_encode($v, JSON_UNESCAPED_SLASHES);
                }
            }
        }
    }
    $accessToken = getFirebaseAccessToken();
    if (!$accessToken) {
        global $LAST_GOOGLE_ACCESS_TOKEN_ERROR;
        $detail = '';
        if (is_array($LAST_GOOGLE_ACCESS_TOKEN_ERROR)) {
            $detail = $LAST_GOOGLE_ACCESS_TOKEN_ERROR['curlErr'] ?? '';
            if (!$detail && !empty($LAST_GOOGLE_ACCESS_TOKEN_ERROR['http'])) {
                $detail = 'HTTP ' . $LAST_GOOGLE_ACCESS_TOKEN_ERROR['http'];
            }
        }
        http_response_code(500);
        echo json_encode([
            'error' => 'Google OAuth token fetch failed',
            'detail' => $detail ?: 'Unable to reach oauth2.googleapis.com from server',
            'hint' => 'Server DNS/outbound connection issue, not frontend Firebase settings'
        ]);
        exit;
    }
    $serviceAccount = json_decode(file_get_contents(FCM_SERVICE_ACCOUNT_FILE), true);
    $projectId = $serviceAccount['project_id'];
    $ch = curl_init("https://fcm.googleapis.com/v1/projects/$projectId/messages:send");
    curl_setopt_array($ch, [
        CURLOPT_POST => true,
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_CONNECTTIMEOUT => 12,
        CURLOPT_TIMEOUT => 25,
        CURLOPT_HTTP_VERSION => CURL_HTTP_VERSION_1_1,
        CURLOPT_HTTPHEADER => [
            'Authorization: Bearer ' . $accessToken,
            'Content-Type: application/json',
            'Expect:'
        ],
        CURLOPT_POSTFIELDS => json_encode([
            'message' => [
                'topic' => 'all',
                'notification' => ['title' => $title, 'body' => $body],
                'data' => (object)$dataMap
            ]
        ])
    ]);
    $response = curl_exec($ch);
    $curlErr = curl_error($ch);
    $httpCode = curl_getinfo($ch, CURLINFO_HTTP_CODE);
    curl_close($ch);
    if ($httpCode === 200) {
        echo json_encode(['success' => true, 'message' => 'Broadcast sent']);
    } else {
        $decoded = json_decode($response, true);
        $detail = '';
        if (is_array($decoded) && isset($decoded['error'])) {
            if (is_array($decoded['error'])) {
                $detail = ($decoded['error']['message'] ?? '') ?: json_encode($decoded['error']);
            } else {
                $detail = (string)$decoded['error'];
            }
        }
        if (!$detail) {
            $detail = $curlErr ?: ('HTTP ' . $httpCode);
        }
        debugLog('Broadcast failed', [
            'http' => $httpCode,
            'curlErr' => $curlErr,
            'response' => $response
        ]);
        http_response_code(500);
        echo json_encode(['error' => 'Broadcast failed', 'detail' => $detail]);
    }
    exit;
}

// SUPPORT REQUESTS (APP -> PANEL)
if ($action === 'support_submit' && $method === 'POST') {
    $payload = is_array($input) ? $input : [];
    $allowedCategories = [
        'bug_report',
        'feature_request',
        'server_request',
        'tweak_request',
        'connection_issue',
        'telegram_bot_issue',
        'payment_issue',
        'account_issue',
        'other'
    ];

    $category = strtolower(trim((string)($payload['category'] ?? 'other')));
    if (!in_array($category, $allowedCategories, true)) {
        $category = 'other';
    }
    $categoryLabel = trim((string)($payload['categoryLabel'] ?? ''));
    if ($categoryLabel === '') $categoryLabel = ucwords(str_replace('_', ' ', $category));

    $subject = trim((string)($payload['subject'] ?? ''));
    if ($subject === '') $subject = $categoryLabel;
    if (strlen($subject) > 140) $subject = substr($subject, 0, 140);

    $message = trim((string)($payload['message'] ?? ''));
    if ($message === '') {
        http_response_code(400);
        echo json_encode(['error' => 'message is required']);
        exit;
    }
    if (strlen($message) > 6000) $message = substr($message, 0, 6000);

    $remoteIp = getClientIpAddress();
    $rateDevice = normalizeUserId($payload['deviceId'] ?? '');
    $rateKey = $remoteIp . '|' . ($rateDevice !== '' ? $rateDevice : 'unknown');
    enforceSimpleRateLimit(
        'support_submit',
        $rateKey,
        APP_RATE_SUPPORT_MAX,
        APP_RATE_SUPPORT_WINDOW_SECONDS,
        'support_rate_limited'
    );

    $nowMs = (int)(microtime(true) * 1000);
    $item = [
        'id' => generateSupportRequestId(),
        'category' => $category,
        'categoryLabel' => $categoryLabel,
        'subject' => $subject,
        'message' => $message,
        'status' => 'new',
        'createdAt' => $nowMs,
        'updatedAt' => $nowMs,
        'source' => 'app',
        'remoteIp' => $remoteIp
    ];

    $stringFields = [
        'protocol',
        'deviceId',
        'time',
        'appVersionName',
        'androidVersion',
        'manufacturer',
        'model',
        'brand',
        'device'
    ];
    foreach ($stringFields as $f) {
        if (isset($payload[$f])) {
            $v = trim((string)$payload[$f]);
            if ($v !== '') $item[$f] = (strlen($v) > 255) ? substr($v, 0, 255) : $v;
        }
    }
    $intFields = ['appVersionCode', 'androidApi'];
    foreach ($intFields as $f) {
        if (isset($payload[$f])) $item[$f] = (int)$payload[$f];
    }

    $items = loadSupportRequests();
    $items[] = $item;
    if (count($items) > 5000) {
        $items = array_slice($items, -5000);
    }
    if (!saveSupportRequests($items)) {
        http_response_code(500);
        echo json_encode(['error' => 'failed to save request']);
        exit;
    }

    echo json_encode(['success' => true, 'id' => $item['id']]);
    exit;
}

if ($action === 'support_requests' && $method === 'GET') {
    requireAuth();
    $items = loadSupportRequests();
    usort($items, function ($a, $b) {
        return (int)($b['createdAt'] ?? 0) <=> (int)($a['createdAt'] ?? 0);
    });

    $counts = ['new' => 0, 'done' => 0, 'declined' => 0];
    foreach ($items as $row) {
        $s = normalizeSupportStatus($row['status'] ?? 'new');
        if (isset($counts[$s])) $counts[$s]++;
    }

    $statusRaw = strtolower(trim((string)($_GET['status'] ?? 'all')));
    if (!in_array($statusRaw, ['all', 'new', 'done', 'declined'], true)) {
        $statusRaw = 'all';
    }
    if ($statusRaw !== 'all') {
        $items = array_values(array_filter($items, function ($row) use ($statusRaw) {
            return normalizeSupportStatus($row['status'] ?? 'new') === $statusRaw;
        }));
    }

    $q = strtolower(trim((string)($_GET['q'] ?? '')));
    if ($q !== '') {
        $items = array_values(array_filter($items, function ($row) use ($q) {
            $hay = strtolower(
                (string)($row['id'] ?? '') . ' ' .
                (string)($row['subject'] ?? '') . ' ' .
                (string)($row['message'] ?? '') . ' ' .
                (string)($row['deviceId'] ?? '')
            );
            return strpos($hay, $q) !== false;
        }));
    }

    $limit = (int)($_GET['limit'] ?? 200);
    if ($limit <= 0) $limit = 200;
    if ($limit > 1000) $limit = 1000;

    echo json_encode([
        'success' => true,
        'counts' => $counts,
        'status' => $statusRaw,
        'total' => array_sum($counts),
        'filtered' => count($items),
        'items' => array_slice($items, 0, $limit)
    ]);
    exit;
}

if ($action === 'support_update' && $method === 'POST') {
    $payload = is_array($input) ? $input : [];
    $auth = requireAuth();
    $id = trim((string)($payload['id'] ?? ''));
    $statusRaw = strtolower(trim((string)($payload['status'] ?? '')));
    if ($id === '' || !in_array($statusRaw, ['new', 'done', 'declined'], true)) {
        http_response_code(400);
        echo json_encode(['error' => 'id and valid status are required']);
        exit;
    }
    $adminNote = trim((string)($payload['adminNote'] ?? ''));
    if (strlen($adminNote) > 1000) $adminNote = substr($adminNote, 0, 1000);

    $items = loadSupportRequests();
    $found = false;
    $updated = null;
    $nowMs = (int)(microtime(true) * 1000);
    foreach ($items as &$row) {
        if ((string)($row['id'] ?? '') !== $id) continue;
        $row['status'] = $statusRaw;
        $row['updatedAt'] = $nowMs;
        $row['handledBy'] = (string)($auth['user'] ?? 'admin');
        if (array_key_exists('adminNote', $payload)) {
            $row['adminNote'] = $adminNote;
        } elseif ($adminNote !== '') {
            $row['adminNote'] = $adminNote;
        }
        $updated = $row;
        $found = true;
        break;
    }
    unset($row);

    if (!$found) {
        http_response_code(404);
        echo json_encode(['error' => 'request not found']);
        exit;
    }
    if (!saveSupportRequests($items)) {
        http_response_code(500);
        echo json_encode(['error' => 'failed to save request']);
        exit;
    }
    echo json_encode(['success' => true, 'item' => $updated]);
    exit;
}

// STATS
if ($action === 'stats' && $method === 'GET') {
    requireAuth();
    echo json_encode(['success' => true, 'stats' => ['total_users' => 0]]);
    exit;
}

if ($action === 'admin_ui_state' && $method === 'GET') {
    requireAuth();
    $state = loadAdminUiState();
    echo json_encode([
        'success' => true,
        'settings' => $state['settings'] ?? [],
        'config' => $state['config'] ?? [],
        'updatedAt' => (string)($state['updatedAt'] ?? '')
    ]);
    exit;
}

if ($action === 'admin_ui_state' && $method === 'POST') {
    requireAuth();
    $state = loadAdminUiState();
    if (isset($input['settings']) && is_array($input['settings'])) {
        $settingsJson = json_encode($input['settings'], JSON_UNESCAPED_SLASHES);
        if (!is_string($settingsJson) || strlen($settingsJson) > ADMIN_UI_STATE_MAX_BYTES) {
            http_response_code(400);
            echo json_encode(['error' => 'settings payload too large']);
            exit;
        }
        $state['settings'] = $input['settings'];
    }
    if (isset($input['config']) && is_array($input['config'])) {
        $configJson = json_encode($input['config'], JSON_UNESCAPED_SLASHES);
        if (!is_string($configJson) || strlen($configJson) > ADMIN_UI_STATE_MAX_BYTES) {
            http_response_code(400);
            echo json_encode(['error' => 'config payload too large']);
            exit;
        }
        $state['config'] = $input['config'];
    }
    if (!saveAdminUiState($state)) {
        http_response_code(500);
        echo json_encode(['error' => 'failed_to_save_admin_ui_state']);
        exit;
    }
    echo json_encode(['success' => true, 'updatedAt' => $state['updatedAt'] ?? date('c')]);
    exit;
}

// 404
debugLog("NO MATCH");
http_response_code(404);
$notFound = ['error' => 'Unknown action'];
if ($DEBUG_LOG_ENABLED) {
    $notFound['action'] = $action;
    $notFound['method'] = $method;
}
echo json_encode($notFound);
