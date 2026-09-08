<?php
// ---------------------------------------------------------------
// IPTunnel License Server — Configuration
//
// ONLY edit the database credentials below.
// Everything else (admin account, master token) is managed
// through the admin panel setup wizard.
// ---------------------------------------------------------------

define('DB_HOST', 'localhost');
define('DB_NAME', 'your_database_name');
define('DB_USER', 'your_database_user');
define('DB_PASS', 'your_database_password');
define('DB_PORT', 3306);

// Session lifetime in seconds (30 minutes)
define('SESSION_LIFETIME', 1800);

// Max login attempts before lockout
define('MAX_LOGIN_ATTEMPTS', 5);

// Lockout duration in seconds (15 minutes)
define('LOCKOUT_DURATION', 900);

// Optional app-level key used to encrypt stored webhook secrets at rest.
// If left blank, the app will use a file-backed key outside the web root.
define('WEBHOOK_SECRET_KEY', '');
define('WEBHOOK_SECRET_KEY_FILE', dirname(__DIR__) . DIRECTORY_SEPARATOR . '.license_server_keys' . DIRECTORY_SEPARATOR . 'webhooks.key');

// Optional app-level key used to protect API tokens at rest. If left blank,
// the app will use a file-backed key outside the web root.
define('TOKEN_SECRET_KEY', '');
define('TOKEN_SECRET_KEY_FILE', dirname(__DIR__) . DIRECTORY_SEPARATOR . '.license_server_keys' . DIRECTORY_SEPARATOR . 'tokens.key');

// Server geo enrichment is disabled by default to avoid leaking IP inventory
// to third-party services. If you enable it, use an HTTPS endpoint template
// containing "{ip}".
define('SERVER_GEOLOOKUP_ENABLED', false);
define('SERVER_GEOLOOKUP_ENDPOINT', '');

// When enabled, server check-ins must include a valid bearer token.
// Use the same registration/master token that was used to register the server.
define('CHECKIN_REQUIRE_AUTH', true);

if (!function_exists('str_starts_with')) {
    function str_starts_with(string $haystack, string $needle): bool {
        if ($needle === '') {
            return true;
        }
        return strncmp($haystack, $needle, strlen($needle)) === 0;
    }
}
