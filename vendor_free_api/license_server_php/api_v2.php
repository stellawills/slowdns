<?php

function handle_api_v2(string $path, string $method): never {
    try {
        $route = substr($path, strlen('/api/v2'));
        $route = '/' . trim($route ?: '', '/');
        if ($route === '//') {
            $route = '/';
        }

        if ($route === '/' && $method === 'GET') {
            v2_out(200, [
                'name' => brand('name') . ' API',
                'version' => '2',
                'legacy_routes' => [
                    '/authorize',
                    '/register',
                    '/checkin',
                    '/revoke',
                    '/status',
                ],
            ]);
        }

        if ($route === '/healthz' && $method === 'GET') {
            v2_out(200, ['status' => 'ok', 'version' => '2']);
        }

        if ($route === '/slowdns/code/issue' && $method === 'POST') {
            v2_slowdns_issue_code();
        }

        if ($route === '/slowdns/install/precheck' && $method === 'POST') {
            v2_slowdns_precheck_install();
        }

        if ($route === '/slowdns/install/activate' && $method === 'POST') {
            v2_slowdns_activate_install();
        }

        if ($route === '/slowdns/install/confirm' && $method === 'POST') {
            v2_slowdns_confirm_install();
        }

        if ($route === '/slowdns/install/release' && $method === 'POST') {
            v2_slowdns_release_install();
        }

        if ($route === '/auth/login' && $method === 'POST') {
            v2_auth_login();
        }

        if ($route === '/auth/logout' && $method === 'POST') {
            v2_auth_logout();
        }

        if ($route === '/auth/me' && $method === 'GET') {
            v2_auth_me();
        }

        if ($route === '/clients' && $method === 'GET') {
            v2_list_clients();
        }

        if ($route === '/clients' && $method === 'POST') {
            v2_create_client();
        }

        if (preg_match('#^/clients/(\d+)$#', $route, $m)) {
            $client_id = (int) $m[1];
            if ($method === 'GET') {
                v2_get_client($client_id);
            }
            if ($method === 'PATCH') {
                v2_update_client($client_id);
            }
            if ($method === 'DELETE') {
                v2_delete_client($client_id);
            }
        }

        if (preg_match('#^/clients/(\d+)/token/rotate$#', $route, $m) && $method === 'POST') {
            v2_rotate_client_token((int) $m[1]);
        }

        if (preg_match('#^/clients/(\d+)/authorized-ips$#', $route, $m)) {
            $client_id = (int) $m[1];
            if ($method === 'GET') {
                v2_list_authorized_ips($client_id);
            }
            if ($method === 'POST') {
                v2_add_authorized_ip($client_id);
            }
        }

        if (preg_match('#^/clients/(\d+)/authorized-ips/(\d+)$#', $route, $m) && $method === 'DELETE') {
            v2_delete_authorized_ip((int) $m[1], (int) $m[2]);
        }

        if ($route === '/install-tickets/issue' && $method === 'POST') {
            v2_issue_install_ticket();
        }

        if ($route === '/servers' && $method === 'GET') {
            v2_list_servers();
        }

        if ($route === '/servers/register' && $method === 'POST') {
            v2_register_server();
        }

        if (preg_match('#^/servers/([^/]+)$#', $route, $m)) {
            $server_id = $m[1];
            if ($method === 'GET') {
                v2_get_server($server_id);
            }
            if ($method === 'DELETE') {
                v2_delete_server($server_id);
            }
        }

        if (preg_match('#^/servers/([^/]+)/check-in$#', $route, $m) && $method === 'POST') {
            v2_checkin_server($m[1]);
        }

        if (preg_match('#^/servers/([^/]+)/revoke$#', $route, $m) && $method === 'POST') {
            v2_revoke_server($m[1]);
        }

        if (preg_match('#^/servers/([^/]+)/restore$#', $route, $m) && $method === 'POST') {
            v2_restore_server($m[1]);
        }

        v2_error(404, 'not_found', 'Route not found.');
    } catch (Throwable $e) {
        error_log('License API v2 error: ' . $e->getMessage());
        if ($e instanceof PDOException && (string) $e->getCode() === '23000') {
            v2_error(409, 'conflict', 'The requested resource conflicts with an existing record.');
        }
        v2_error(500, 'internal_error', 'Internal server error.');
    }
}

function license_issue_install_ticket_for_ip(string $ip): array {
    $auth = get_authorized_ip($ip);
    if (!$auth) {
        return [
            'ok' => false,
            'status' => 404,
            'payload' => [
                'error' => 'IP not pre-authorized',
                'ip' => $ip,
                'message' => 'Ask your administrator to add this IP in the client portal',
            ],
        ];
    }

    if (!(bool) $auth['client_active']) {
        return [
            'ok' => false,
            'status' => 403,
            'payload' => ['error' => 'client account is suspended'],
        ];
    }

    $resolved_client_id = $auth['resolved_client_id'] !== null ? (int) $auth['resolved_client_id'] : null;
    $ticket = create_install_ticket($resolved_client_id, $ip);
    audit_log('ip_authorize', $ip, 'Client: ' . $auth['client_name'] . ' - install ticket issued', 'api');

    return [
        'ok' => true,
        'status' => 200,
        'payload' => [
            'authorized' => true,
            'token' => $ticket,
            'client' => $auth['client_name'],
            'client_id' => $resolved_client_id,
            'ip' => $ip,
        ],
    ];
}

function license_register_server(string $token, string $ip, string $hostname): array {
    if ($token === '' || $ip === '') {
        return [
            'ok' => false,
            'status' => 400,
            'payload' => ['error' => "missing 'token' and/or 'ip'"],
        ];
    }

    $client = get_client_by_token($token);
    $client_id = null;

    if ($client) {
        if (!(bool) $client['is_active']) {
            return [
                'ok' => false,
                'status' => 403,
                'payload' => ['error' => 'client account is suspended'],
            ];
        }
        $client_id = (int) $client['id'];

        if ((int) $client['max_servers'] > 0) {
            $current = client_server_count($client_id);
            $stmt = db()->prepare('SELECT server_id FROM servers WHERE ip = ? AND client_id = ?');
            $stmt->execute([$ip, $client_id]);
            $is_reregister = (bool) $stmt->fetch();

            if (!$is_reregister && $current >= (int) $client['max_servers']) {
                return [
                    'ok' => false,
                    'status' => 403,
                    'payload' => [
                        'error' => 'server limit reached',
                        'limit' => (int) $client['max_servers'],
                        'current' => $current,
                    ],
                ];
            }
        }
    } elseif (str_starts_with($token, 'itk_')) {
        $ticket = consume_install_ticket($token, $ip);
        if (!$ticket || !(bool) $ticket['is_active']) {
            return [
                'ok' => false,
                'status' => 403,
                'payload' => ['error' => 'invalid or expired install ticket'],
            ];
        }
        $client = $ticket;
        $client_id = $ticket['client_id'] !== null ? (int) $ticket['client_id'] : null;
        $token = $ticket['token'] ?? 'manual';
    } elseif (!verify_master_token($token)) {
        return [
            'ok' => false,
            'status' => 403,
            'payload' => ['error' => 'invalid token'],
        ];
    }

    $pdo = db();
    // Look up by IP only — the token can change between installs
    // (e.g. client-token → manual via zero-touch, or vice versa)
    $stmt = $pdo->prepare('SELECT server_id, revoked, token AS old_token, token_hash AS old_token_hash FROM servers WHERE ip = ? ORDER BY registered_at DESC LIMIT 1');
    $stmt->execute([$ip]);
    $existing = $stmt->fetch();

    if ($existing) {
        if ((bool) $existing['revoked']) {
            audit_log('register_blocked_revoked', $existing['server_id'], "IP: $ip - attempted re-register while revoked", 'api');
            return [
                'ok' => false,
                'status' => 403,
                'payload' => [
                    'error' => 'server is revoked',
                    'server_id' => $existing['server_id'],
                    'message' => 'This server has been revoked. Contact your administrator to restore access.',
                ],
            ];
        }
        $sid = $existing['server_id'];
        $serverTokenValues = server_token_storage_values($token);
        $pdo->prepare(
            'UPDATE servers SET last_checkin = NOW(), hostname = ?, client_id = ?, token = ?, token_hash = ? WHERE server_id = ?'
        )->execute([$hostname, $client_id, $serverTokenValues['stored'], $serverTokenValues['hash'], $sid]);
        $oldTokenHint = server_token_hint_from_storage((string) ($existing['old_token'] ?? ''));
        $newTokenHint = token_hint($token);
        $tokenChange = $oldTokenHint !== $newTokenHint ? ($oldTokenHint . '->' . $newTokenHint) : $newTokenHint;
        audit_log('register_reactivate', $sid, "IP: $ip, Host: $hostname, Token: $tokenChange, Client: " . ($client['name'] ?? 'admin'), 'api');
        /*
        audit_log('register_reactivate', $sid, "IP: $ip, Host: $hostname, Token: " . ($existing['old_token'] !== $token ? "{$existing['old_token']}→{$token}" : $token) . ", Client: " . ($client['name'] ?? 'admin'), 'api');
        */
    } else {
        $sid = bin2hex(random_bytes(8));
        $serverTokenValues = server_token_storage_values($token);
        $pdo->prepare(
            'INSERT INTO servers (server_id, client_id, ip, hostname, token, token_hash, note) VALUES (?, ?, ?, ?, ?, ?, ?)'
        )->execute([$sid, $client_id, $ip, $hostname, $serverTokenValues['stored'], $serverTokenValues['hash'], '']);
        audit_log('register_new', $sid, "IP: $ip, Host: $hostname, Client: " . ($client['name'] ?? 'admin'), 'api');
    }

    $geo = lookup_server_geo($ip);
    if ($geo) {
        update_server_geo($sid, $geo);
    }

    fire_webhooks('register', ['server_id' => $sid, 'ip' => $ip, 'hostname' => $hostname]);

    $server = license_get_server($sid);
    return [
        'ok' => true,
        'status' => 200,
        'payload' => array_merge(['status' => 'authorized'], $server ?? ['server_id' => $sid, 'ip' => $ip, 'hostname' => $hostname]),
    ];
}

function checkin_auth_required(): bool {
    return defined('CHECKIN_REQUIRE_AUTH') && (bool) CHECKIN_REQUIRE_AUTH;
}

function checkin_bearer_matches_server(array $server, string $token): bool {
    if ($token === '') {
        return false;
    }
    if (verify_master_token($token)) {
        return true;
    }
    return server_token_matches($server, $token);
}

function license_checkin_server(string $server_id): array {
    if ($server_id === '') {
        return [
            'ok' => false,
            'status' => 400,
            'payload' => ['error' => "missing 'server_id'"],
        ];
    }

    $stmt = db()->prepare('SELECT server_id, revoked, token, token_hash FROM servers WHERE server_id = ?');
    $stmt->execute([$server_id]);
    $server = $stmt->fetch();

    if (!$server) {
        return [
            'ok' => false,
            'status' => 404,
            'payload' => ['error' => 'unknown server_id'],
        ];
    }

    $bearer = v2_bearer_token();
    if ($bearer === '') {
        if (checkin_auth_required()) {
            return [
                'ok' => false,
                'status' => 401,
                'payload' => ['error' => 'bearer token required'],
            ];
        }
    } elseif (!checkin_bearer_matches_server($server, $bearer)) {
        return [
            'ok' => false,
            'status' => 401,
            'payload' => ['error' => 'invalid bearer token'],
        ];
    }

    if ((bool) $server['revoked']) {
        return [
            'ok' => false,
            'status' => 403,
            'payload' => ['status' => 'revoked', 'server_id' => $server_id],
        ];
    }

    db()->prepare('UPDATE servers SET last_checkin = NOW() WHERE server_id = ?')
        ->execute([$server_id]);

    return [
        'ok' => true,
        'status' => 200,
        'payload' => ['status' => 'ok', 'server_id' => $server_id],
    ];
}

function license_change_server_revocation(string $server_id, bool $revoked, string $actor = 'api'): array {
    if ($server_id === '') {
        return [
            'ok' => false,
            'status' => 400,
            'payload' => ['error' => "missing 'server_id'"],
        ];
    }

    $stmt = db()->prepare('UPDATE servers SET revoked = ? WHERE server_id = ?');
    $stmt->execute([$revoked ? 1 : 0, $server_id]);

    if ($stmt->rowCount() === 0) {
        return [
            'ok' => false,
            'status' => 404,
            'payload' => ['error' => 'unknown server_id'],
        ];
    }

    $action = $revoked ? 'revoke_api' : 'restore_api';
    $status = $revoked ? 'revoked' : 'active';
    audit_log($action, $server_id, '', $actor);
    fire_webhooks($revoked ? 'revoke' : 'restore', ['server_id' => $server_id]);

    return [
        'ok' => true,
        'status' => 200,
        'payload' => ['status' => $status, 'server_id' => $server_id],
    ];
}

function license_status_rows_for_token(string $token): array {
    if (verify_master_token($token)) {
        $rows = db()->query(
            'SELECT s.server_id, s.ip, s.hostname, s.registered_at, s.last_checkin, s.revoked, s.note, s.client_id, s.country, s.city, s.lat, s.lon, c.name AS client_name
             FROM servers s LEFT JOIN clients c ON s.client_id = c.id
             ORDER BY s.registered_at DESC'
        )->fetchAll();
        return ['ok' => true, 'status' => 200, 'scope' => 'master', 'rows' => $rows];
    }

    $client = get_client_by_token($token);
    if ($client) {
        $stmt = db()->prepare(
            'SELECT s.server_id, s.ip, s.hostname, s.registered_at, s.last_checkin, s.revoked, s.note, s.client_id, s.country, s.city, s.lat, s.lon, c.name AS client_name
             FROM servers s
             LEFT JOIN clients c ON s.client_id = c.id
             WHERE s.client_id = ?
             ORDER BY s.registered_at DESC'
        );
        $stmt->execute([$client['id']]);
        return [
            'ok' => true,
            'status' => 200,
            'scope' => 'client',
            'client' => $client,
            'rows' => $stmt->fetchAll(),
        ];
    }

    return [
        'ok' => false,
        'status' => 403,
        'payload' => ['error' => 'valid token required'],
    ];
}

function license_get_server(string $server_id): ?array {
    $stmt = db()->prepare(
        'SELECT s.*, c.name AS client_name
         FROM servers s
         LEFT JOIN clients c ON s.client_id = c.id
         WHERE s.server_id = ?
         LIMIT 1'
    );
    $stmt->execute([$server_id]);
    return $stmt->fetch() ?: null;
}

function v2_auth_login(): never {
    if (is_rate_limited()) {
        v2_error(429, 'rate_limited', 'Too many login attempts.', ['retry_after' => lockout_remaining()]);
    }

    $body = v2_read_json(false);
    $username = trim((string) ($body['username'] ?? ''));
    $password = (string) ($body['password'] ?? '');
    if ($username === '' || $password === '') {
        v2_error(422, 'validation_error', 'Username and password are required.');
    }

    $admin = get_admin($username);
    if (!$admin || !password_verify($password, $admin['password'])) {
        record_login_attempt(false);
        record_login_history('admin', (int) ($admin['id'] ?? 0), $username, false);
        v2_error(401, 'invalid_credentials', 'Invalid username or password.');
    }

    record_login_attempt(true);
    v2_start_session();
    session_regenerate_id(true);
    $_SESSION['admin_id'] = (int) $admin['id'];
    $_SESSION['admin_user'] = $admin['username'];
    $_SESSION['admin_role'] = $admin['role'];
    $_SESSION['last_activity'] = time();
    update_admin_login((int) $admin['id']);
    record_login_history('admin', (int) $admin['id'], $admin['username'], true);

    v2_out(200, [
        'admin' => [
            'id' => (int) $admin['id'],
            'username' => $admin['username'],
            'role' => $admin['role'],
        ],
    ]);
}

function v2_auth_logout(): never {
    v2_start_session();
    $_SESSION = [];
    if (ini_get('session.use_cookies')) {
        $params = session_get_cookie_params();
        setcookie(session_name(), '', time() - 42000, $params['path'], $params['domain'], (bool) $params['secure'], (bool) $params['httponly']);
    }
    session_destroy();
    v2_out(200, ['logged_out' => true]);
}

function v2_auth_me(): never {
    $admin = v2_require_admin_session();
    v2_out(200, [
        'admin' => [
            'id' => (int) $admin['id'],
            'username' => $admin['username'],
            'role' => $admin['role'],
            'last_login' => $admin['last_login'] ?? null,
        ],
    ]);
}

function v2_list_clients(): never {
    v2_require_admin_bearer();
    $page = v2_query_int('page', 1, 1, 1000000);
    $per_page = v2_query_int('per_page', 20, 1, 100);
    $status = (string) ($_GET['status'] ?? 'all');
    $search = trim((string) ($_GET['search'] ?? ''));
    $filter = match ($status) {
        'active' => 'active',
        'inactive' => 'inactive',
        default => 'all',
    };

    $rows = get_clients($filter, $search, $page, $per_page);
    $total = count_clients($filter, $search);

    v2_out(200, [
        'clients' => array_map(fn(array $row): array => v2_client_resource($row), $rows),
    ], [
        'pagination' => v2_pagination_meta($page, $per_page, $total),
    ]);
}

function v2_create_client(): never {
    v2_require_admin_bearer();
    $body = v2_read_json(false);

    $name = trim((string) ($body['name'] ?? ''));
    $email = trim((string) ($body['email'] ?? ''));
    $username = trim((string) ($body['username'] ?? ''));
    $password = (string) ($body['password'] ?? '');
    $max_servers = (int) ($body['max_servers'] ?? 0);
    $note = trim((string) ($body['note'] ?? ''));

    if ($name === '' || $email === '' || $username === '' || $password === '') {
        v2_error(422, 'validation_error', 'Name, email, username, and password are required.');
    }

    $created = create_client($name, $email, $username, $password, $max_servers, $note);
    audit_log('create_client_v2', (string) $created['id'], 'Client created via API v2', 'api');

    $client = get_client_by_id((int) $created['id']);
    v2_out(201, [
        'client' => v2_client_resource($client ?: ['id' => $created['id'], 'name' => $name, 'email' => $email, 'username' => $username, 'max_servers' => $max_servers, 'note' => $note, 'is_active' => 1]),
        'token' => $created['token'],
    ]);
}

function v2_get_client(int $client_id): never {
    v2_require_admin_bearer();
    $client = get_client_by_id($client_id);
    if (!$client) {
        v2_error(404, 'not_found', 'Client not found.');
    }

    $subscription = get_subscription($client_id);
    v2_out(200, [
        'client' => v2_client_resource($client),
        'authorized_ips' => array_map(fn(array $row): array => v2_authorized_ip_resource($row), list_authorized_ips($client_id)),
        'subscription' => $subscription ? v2_subscription_resource($subscription) : null,
    ]);
}

function v2_update_client(int $client_id): never {
    v2_require_admin_bearer();
    $client = get_client_by_id($client_id);
    if (!$client) {
        v2_error(404, 'not_found', 'Client not found.');
    }

    $body = v2_read_json(false);
    $name = trim((string) ($body['name'] ?? $client['name']));
    $email = trim((string) ($body['email'] ?? $client['email']));
    $max_servers = array_key_exists('max_servers', $body) ? (int) $body['max_servers'] : (int) $client['max_servers'];
    $note = trim((string) ($body['note'] ?? $client['note']));
    $password = (string) ($body['password'] ?? '');
    $is_active = array_key_exists('is_active', $body) ? (bool) $body['is_active'] : (bool) $client['is_active'];

    update_client($client_id, $name, $email, $max_servers, $note);
    if ($password !== '') {
        update_client_password($client_id, $password);
    }
    toggle_client($client_id, $is_active);
    audit_log('update_client_v2', (string) $client_id, 'Client updated via API v2', 'api');

    $updated = get_client_by_id($client_id);
    v2_out(200, ['client' => v2_client_resource($updated ?: $client)]);
}

function v2_delete_client(int $client_id): never {
    v2_require_admin_bearer();
    $client = get_client_by_id($client_id);
    if (!$client) {
        v2_error(404, 'not_found', 'Client not found.');
    }

    delete_client($client_id);
    audit_log('delete_client_v2', (string) $client_id, 'Client deleted via API v2', 'api');
    v2_out(200, ['deleted' => true, 'client_id' => $client_id]);
}

function v2_rotate_client_token(int $client_id): never {
    v2_require_admin_bearer();
    $client = get_client_by_id($client_id);
    if (!$client) {
        v2_error(404, 'not_found', 'Client not found.');
    }

    $token = regenerate_client_token($client_id);
    audit_log('rotate_client_token_v2', (string) $client_id, 'Client token rotated via API v2', 'api');
    v2_out(200, ['client_id' => $client_id, 'token' => $token]);
}

function v2_list_authorized_ips(int $client_id): never {
    v2_require_admin_bearer();
    if (!get_client_by_id($client_id)) {
        v2_error(404, 'not_found', 'Client not found.');
    }

    $rows = list_authorized_ips($client_id);
    v2_out(200, ['authorized_ips' => array_map(fn(array $row): array => v2_authorized_ip_resource($row), $rows)]);
}

function v2_add_authorized_ip(int $client_id): never {
    v2_require_admin_bearer();
    if (!get_client_by_id($client_id)) {
        v2_error(404, 'not_found', 'Client not found.');
    }

    $body = v2_read_json(false);
    $ip = trim((string) ($body['ip'] ?? ''));
    $label = trim((string) ($body['label'] ?? ''));
    if ($ip === '' || !is_public_routable_ip($ip)) {
        v2_error(422, 'validation_error', 'IP must be a public routable address.');
    }

    try {
        add_authorized_ip($client_id, $ip, $label);
    } catch (InvalidArgumentException $e) {
        v2_error(422, 'validation_error', $e->getMessage());
    }
    audit_log('add_authorized_ip_v2', $ip, "Client ID: $client_id", 'api');

    $stmt = db()->prepare('SELECT * FROM authorized_ips WHERE client_id = ? AND ip = ? ORDER BY created_at DESC LIMIT 1');
    $stmt->execute([$client_id, $ip]);
    $row = $stmt->fetch() ?: ['id' => 0, 'client_id' => $client_id, 'ip' => $ip, 'label' => $label, 'created_at' => null];
    v2_out(201, ['authorized_ip' => v2_authorized_ip_resource($row)]);
}

function v2_delete_authorized_ip(int $client_id, int $authorized_ip_id): never {
    v2_require_admin_bearer();
    $stmt = db()->prepare('SELECT * FROM authorized_ips WHERE id = ? AND client_id = ?');
    $stmt->execute([$authorized_ip_id, $client_id]);
    $row = $stmt->fetch();
    if (!$row) {
        v2_error(404, 'not_found', 'Authorized IP not found.');
    }

    delete_authorized_ip($authorized_ip_id);
    audit_log('delete_authorized_ip_v2', $row['ip'], "Client ID: $client_id", 'api');
    v2_out(200, ['deleted' => true, 'authorized_ip_id' => $authorized_ip_id]);
}

function v2_issue_install_ticket(): never {
    $body = v2_read_json(true);
    $actor = v2_bearer_actor();
    $ttl = array_key_exists('ttl_seconds', $body) ? max(60, min(3600, (int) $body['ttl_seconds'])) : 600;

    if ($actor['type'] === 'invalid') {
        v2_error(401, 'unauthorized', 'The supplied bearer token is invalid.');
    }

    if ($actor['type'] === 'admin') {
        $client_id = (int) ($body['client_id'] ?? 0);
        $ip = trim((string) ($body['ip'] ?? client_ip()));
        if ($client_id <= 0 || $ip === '') {
            v2_error(422, 'validation_error', 'client_id and ip are required for admin-issued install tickets.');
        }
        $client = get_client_by_id($client_id);
        if (!$client) {
            v2_error(404, 'not_found', 'Client not found.');
        }
        if (!(bool) $client['is_active']) {
            v2_error(403, 'forbidden', 'Client account is suspended.');
        }
        $ticket = create_install_ticket($client_id, $ip, $ttl);
        audit_log('issue_install_ticket_v2', $ip, "Client: {$client['name']}", 'api');
        v2_out(201, [
            'ticket' => $ticket,
            'client' => ['id' => (int) $client['id'], 'name' => $client['name']],
            'ip' => $ip,
            'ttl_seconds' => $ttl,
        ]);
    }

    if ($actor['type'] === 'client') {
        $client = $actor['client'];
        $ip = trim((string) ($body['ip'] ?? client_ip()));
        $ticket = create_install_ticket((int) $client['id'], $ip, $ttl);
        audit_log('issue_install_ticket_v2', $ip, "Client: {$client['name']}", 'api');
        v2_out(201, [
            'ticket' => $ticket,
            'client' => ['id' => (int) $client['id'], 'name' => $client['name']],
            'ip' => $ip,
            'ttl_seconds' => $ttl,
        ]);
    }

    $result = license_issue_install_ticket_for_ip(client_ip());
    if (!$result['ok']) {
        v2_error($result['status'], $result['status'] === 404 ? 'not_found' : 'forbidden', $result['payload']['message'] ?? $result['payload']['error'], $result['payload']);
    }

    v2_out(201, [
        'ticket' => $result['payload']['token'],
        'client' => [
            'id' => (int) $result['payload']['client_id'],
            'name' => $result['payload']['client'],
        ],
        'ip' => $result['payload']['ip'],
        'ttl_seconds' => $ttl,
    ]);
}

function v2_list_servers(): never {
    $actor = v2_require_bearer_actor(true, true);
    $page = v2_query_int('page', 1, 1, 1000000);
    $per_page = v2_query_int('per_page', 20, 1, 100);
    $status = (string) ($_GET['status'] ?? 'all');
    $search = trim((string) ($_GET['search'] ?? ''));
    $filter = match ($status) {
        'active' => 'active',
        'revoked' => 'revoked',
        'manual' => 'manual',
        'stale' => 'stale',
        default => 'all',
    };
    $client_id = $actor['type'] === 'client' ? (int) $actor['client']['id'] : null;
    $rows = get_servers($filter, $search, $page, $per_page, $client_id);
    $total = count_servers($filter, $search, $client_id);

    v2_out(200, [
        'servers' => array_map(fn(array $row): array => v2_server_resource($row), $rows),
    ], [
        'pagination' => v2_pagination_meta($page, $per_page, $total),
        'scope' => $actor['type'],
    ]);
}

function v2_register_server(): never {
    $body = v2_read_json(false);
    $token = trim((string) ($body['token'] ?? $body['install_ticket'] ?? v2_bearer_token()));
    $ip = trim((string) ($body['ip'] ?? client_ip()));
    $hostname = trim((string) ($body['hostname'] ?? ''));

    $result = license_register_server($token, $ip, $hostname);
    if (!$result['ok']) {
        v2_error(v2_status_from_legacy($result['status']), v2_code_from_legacy_payload($result['payload']), $result['payload']['message'] ?? $result['payload']['error'], $result['payload']);
    }

    $payload = $result['payload'];
    v2_out(200, [
        'status' => $payload['status'],
        'server_id' => $payload['server_id'],
        'server' => v2_server_resource($payload),
    ]);
}

function v2_get_server(string $server_id): never {
    $actor = v2_require_bearer_actor(true, true);
    $server = license_get_server($server_id);
    if (!$server) {
        v2_error(404, 'not_found', 'Server not found.');
    }
    if ($actor['type'] === 'client' && (int) ($server['client_id'] ?? 0) !== (int) $actor['client']['id']) {
        v2_error(403, 'forbidden', 'You do not have access to this server.');
    }
    v2_out(200, ['server' => v2_server_resource($server)]);
}

function v2_checkin_server(string $server_id): never {
    $result = license_checkin_server($server_id);
    if (!$result['ok']) {
        v2_error(v2_status_from_legacy($result['status']), v2_code_from_legacy_payload($result['payload']), $result['payload']['error'] ?? 'Check-in failed.', $result['payload']);
    }
    v2_out(200, [
        'status' => $result['payload']['status'],
        'server_id' => $result['payload']['server_id'],
    ]);
}

function v2_revoke_server(string $server_id): never {
    v2_require_admin_bearer();
    $result = license_change_server_revocation($server_id, true, 'api_v2');
    if (!$result['ok']) {
        v2_error(v2_status_from_legacy($result['status']), v2_code_from_legacy_payload($result['payload']), $result['payload']['error'] ?? 'Unable to revoke server.', $result['payload']);
    }
    v2_out(200, $result['payload']);
}

function v2_restore_server(string $server_id): never {
    v2_require_admin_bearer();
    $result = license_change_server_revocation($server_id, false, 'api_v2');
    if (!$result['ok']) {
        v2_error(v2_status_from_legacy($result['status']), v2_code_from_legacy_payload($result['payload']), $result['payload']['error'] ?? 'Unable to restore server.', $result['payload']);
    }
    v2_out(200, $result['payload']);
}

function v2_delete_server(string $server_id): never {
    v2_require_admin_bearer();
    $server = license_get_server($server_id);
    if (!$server) {
        v2_error(404, 'not_found', 'Server not found.');
    }

    db()->prepare('DELETE FROM servers WHERE server_id = ?')->execute([$server_id]);
    audit_log('delete_server_v2', $server_id, '', 'api');
    fire_webhooks('delete', ['server_id' => $server_id]);
    v2_out(200, ['deleted' => true, 'server_id' => $server_id]);
}

function v2_out(int $status, array $data, array $meta = []): never {
    http_response_code($status);
    echo json_encode([
        'data' => $data,
        'meta' => array_merge([
            'request_id' => v2_request_id(),
            'timestamp' => gmdate('c'),
        ], $meta),
        'error' => null,
    ], JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES);
    exit;
}

function v2_error(int $status, string $code, string $message, array $details = []): never {
    http_response_code($status);
    echo json_encode([
        'data' => null,
        'meta' => [
            'request_id' => v2_request_id(),
            'timestamp' => gmdate('c'),
        ],
        'error' => [
            'code' => $code,
            'message' => $message,
            'details' => $details === [] ? (object) [] : $details,
        ],
    ], JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES);
    exit;
}

function v2_request_id(): string {
    static $request_id = null;
    if ($request_id === null) {
        $request_id = 'req_' . bin2hex(random_bytes(8));
    }
    return $request_id;
}

function v2_read_json(bool $allow_empty = false): array {
    $len = (int) ($_SERVER['CONTENT_LENGTH'] ?? 0);
    if ($len > 65536) {
        v2_error(413, 'request_too_large', 'Request body too large.');
    }
    if ($len === 0) {
        return $allow_empty ? [] : v2_error(400, 'invalid_body', 'Request body is required.');
    }
    $raw = file_get_contents('php://input', false, null, 0, 65536);
    if ($raw === false || trim($raw) === '') {
        return $allow_empty ? [] : v2_error(400, 'invalid_body', 'Request body is required.');
    }
    $data = json_decode($raw, true);
    if (!is_array($data)) {
        v2_error(400, 'invalid_json', 'Invalid JSON body.');
    }
    return $data;
}

function v2_query_int(string $key, int $default, int $min, int $max): int {
    if (!isset($_GET[$key]) || $_GET[$key] === '') {
        return $default;
    }
    if (!is_numeric($_GET[$key])) {
        v2_error(422, 'validation_error', "Query parameter `$key` must be numeric.");
    }
    return max($min, min($max, (int) $_GET[$key]));
}

function v2_pagination_meta(int $page, int $per_page, int $total): array {
    return [
        'page' => $page,
        'per_page' => $per_page,
        'total' => $total,
        'pages' => $per_page > 0 ? (int) ceil($total / $per_page) : 0,
    ];
}

function v2_bearer_token(): string {
    $auth = $_SERVER['HTTP_AUTHORIZATION'] ?? '';
    return preg_replace('/^bearer\s+/i', '', trim($auth));
}

function v2_bearer_actor(): array {
    $token = v2_bearer_token();
    if ($token === '') {
        return ['type' => 'none'];
    }
    if (verify_master_token($token)) {
        return ['type' => 'admin', 'token' => $token];
    }
    $client = get_client_by_token($token);
    if ($client) {
        return ['type' => 'client', 'token' => $token, 'client' => $client];
    }
    return ['type' => 'invalid'];
}

function v2_require_bearer_actor(bool $allow_admin, bool $allow_client): array {
    $actor = v2_bearer_actor();
    if (
        ($allow_admin && $actor['type'] === 'admin') ||
        ($allow_client && $actor['type'] === 'client')
    ) {
        return $actor;
    }
    v2_error(401, 'unauthorized', 'A valid bearer token is required.');
}

function v2_require_admin_bearer(): void {
    v2_require_bearer_actor(true, false);
}

function v2_start_session(): void {
    if (session_status() === PHP_SESSION_ACTIVE) {
        return;
    }
    session_name('iptunnel_admin');
    ini_set('session.cookie_httponly', '1');
    ini_set('session.cookie_samesite', 'Strict');
    ini_set('session.use_strict_mode', '1');
    if (
        (isset($_SERVER['HTTPS']) && $_SERVER['HTTPS'] === 'on') ||
        (isset($_SERVER['HTTP_X_FORWARDED_PROTO']) && $_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https')
    ) {
        ini_set('session.cookie_secure', '1');
    }
    session_start();
}

function v2_require_admin_session(): array {
    v2_start_session();
    $lastActivity = (int) ($_SESSION['last_activity'] ?? 0);
    if ($lastActivity > 0 && (time() - $lastActivity) > SESSION_LIFETIME) {
        $_SESSION = [];
        if (ini_get('session.use_cookies')) {
            $params = session_get_cookie_params();
            setcookie(session_name(), '', time() - 42000, $params['path'], $params['domain'], (bool) $params['secure'], (bool) $params['httponly']);
        }
        session_destroy();
        v2_error(401, 'session_expired', 'Admin session expired. Please sign in again.');
    }
    $username = $_SESSION['admin_user'] ?? '';
    if ($username === '') {
        v2_error(401, 'unauthorized', 'An authenticated admin session is required.');
    }
    $admin = get_admin($username);
    if (!$admin) {
        v2_error(401, 'unauthorized', 'Admin session is no longer valid.');
    }
    $_SESSION['last_activity'] = time();
    return $admin;
}

function v2_client_resource(array $row): array {
    return [
        'id' => (int) ($row['id'] ?? 0),
        'name' => $row['name'] ?? '',
        'email' => $row['email'] ?? '',
        'username' => $row['username'] ?? '',
        'status' => ((int) ($row['is_active'] ?? 0) === 1) ? 'active' : 'inactive',
        'max_servers' => (int) ($row['max_servers'] ?? 0),
        'note' => $row['note'] ?? '',
        'server_count' => isset($row['server_count']) ? (int) $row['server_count'] : client_server_count((int) ($row['id'] ?? 0)),
        'active_servers' => isset($row['active_servers']) ? (int) $row['active_servers'] : client_server_count((int) ($row['id'] ?? 0)),
        'token_preview' => token_preview_from_row($row),
        'created_at' => $row['created_at'] ?? null,
        'last_login' => $row['last_login'] ?? null,
    ];
}

function v2_authorized_ip_resource(array $row): array {
    return [
        'id' => (int) ($row['id'] ?? 0),
        'client_id' => (int) ($row['client_id'] ?? 0),
        'ip' => $row['ip'] ?? '',
        'label' => $row['label'] ?? '',
        'created_at' => $row['created_at'] ?? null,
    ];
}

function v2_subscription_resource(array $row): array {
    return [
        'id' => (int) ($row['id'] ?? 0),
        'client_id' => (int) ($row['client_id'] ?? 0),
        'plan' => $row['plan'] ?? '',
        'status' => $row['status'] ?? '',
        'max_servers' => (int) ($row['max_servers'] ?? 0),
        'amount' => (float) ($row['amount'] ?? 0),
        'currency' => $row['currency'] ?? 'USD',
        'starts_at' => $row['starts_at'] ?? null,
        'expires_at' => $row['expires_at'] ?? null,
    ];
}

function v2_server_resource(array $row): array {
    return [
        'id' => $row['server_id'] ?? '',
        'ip' => $row['ip'] ?? '',
        'hostname' => $row['hostname'] ?? '',
        'status' => ((int) ($row['revoked'] ?? 0) === 1) ? 'revoked' : 'active',
        'client_id' => isset($row['client_id']) ? (int) $row['client_id'] : null,
        'client_name' => $row['client_name'] ?? null,
        'country' => $row['country'] ?? '',
        'city' => $row['city'] ?? '',
        'lat' => isset($row['lat']) ? (float) $row['lat'] : null,
        'lon' => isset($row['lon']) ? (float) $row['lon'] : null,
        'note' => $row['note'] ?? '',
        'registered_at' => $row['registered_at'] ?? null,
        'last_checkin' => $row['last_checkin'] ?? null,
    ];
}

function v2_status_from_legacy(int $status): int {
    return $status;
}

function v2_code_from_legacy_payload(array $payload): string {
    if (($payload['status'] ?? '') === 'revoked') {
        return 'revoked';
    }
    if (($payload['error'] ?? '') === 'unknown server_id') {
        return 'not_found';
    }
    if (($payload['error'] ?? '') === 'invalid token') {
        return 'unauthorized';
    }
    if (in_array(($payload['error'] ?? ''), ['bearer token required', 'invalid bearer token'], true)) {
        return 'unauthorized';
    }
    if (($payload['error'] ?? '') === 'client account is suspended') {
        return 'forbidden';
    }
    if (($payload['error'] ?? '') === 'server limit reached') {
        return 'conflict';
    }
    return match ($payload['error'] ?? '') {
        "missing 'token' and/or 'ip'", "missing 'server_id'" => 'validation_error',
        default => 'request_failed',
    };
}
