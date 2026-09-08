<?php

if (PHP_SAPI !== 'cli') {
    http_response_code(403);
    echo "CLI only\n";
    exit(1);
}

require_once __DIR__ . '/db.php';
require_once __DIR__ . '/slowdns_activation.php';

$healthLimit = 25;
$healthInterval = 300;
foreach (array_slice($argv ?? [], 1) as $arg) {
    if (preg_match('/^--health-limit=(\d+)$/', $arg, $m)) {
        $healthLimit = max(1, min((int) $m[1], 250));
    } elseif (preg_match('/^--health-interval=(\d+)$/', $arg, $m)) {
        $healthInterval = max(60, (int) $m[1]);
    }
}

function maintenance_count(string $sql): int {
    $value = db()->query($sql)->fetchColumn();
    return (int) ($value ?: 0);
}

slowdns_schema_ensure();

$before = [
    'expired_codes' => maintenance_count("SELECT COUNT(*) FROM slowdns_install_codes WHERE status = 'expired'"),
    'released_activations' => maintenance_count("SELECT COUNT(*) FROM slowdns_install_activations WHERE released_at IS NOT NULL"),
    'confirmed_activations' => maintenance_count("SELECT COUNT(*) FROM slowdns_install_activations WHERE install_token_used_at IS NOT NULL"),
    'rate_limit_rows' => maintenance_count("SELECT COUNT(*) FROM slowdns_rate_limits"),
];

slowdns_cleanup_codes();
slowdns_cleanup_history();
slowdns_rate_limit_cleanup(3600);
slowdns_rate_limit_cleanup(86400);
$healthResults = refresh_due_servers_health($healthLimit, $healthInterval);
$healthCounts = ['online' => 0, 'offline' => 0, 'unknown' => 0];
foreach ($healthResults as $row) {
    $status = strtolower((string) ($row['health_status'] ?? 'unknown'));
    if (!isset($healthCounts[$status])) {
        $status = 'unknown';
    }
    $healthCounts[$status]++;
}

$after = [
    'expired_codes' => maintenance_count("SELECT COUNT(*) FROM slowdns_install_codes WHERE status = 'expired'"),
    'released_activations' => maintenance_count("SELECT COUNT(*) FROM slowdns_install_activations WHERE released_at IS NOT NULL"),
    'confirmed_activations' => maintenance_count("SELECT COUNT(*) FROM slowdns_install_activations WHERE install_token_used_at IS NOT NULL"),
    'rate_limit_rows' => maintenance_count("SELECT COUNT(*) FROM slowdns_rate_limits"),
];

echo "SlowDNS maintenance complete\n";
echo "Expired codes: " . $before['expired_codes'] . " -> " . $after['expired_codes'] . "\n";
echo "Released activations retained: " . $before['released_activations'] . " -> " . $after['released_activations'] . "\n";
echo "Confirmed activations retained: " . $before['confirmed_activations'] . " -> " . $after['confirmed_activations'] . "\n";
echo "Rate-limit rows: " . $before['rate_limit_rows'] . " -> " . $after['rate_limit_rows'] . "\n";
echo "Health checks: " . count($healthResults)
    . " (online=" . $healthCounts['online']
    . ", offline=" . $healthCounts['offline']
    . ", unknown=" . $healthCounts['unknown'] . ")\n";
