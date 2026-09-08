<?php
// ---------------------------------------------------------------
// IPTunnel License Admin Panel — Production Build (v2 Multi-Client)
//
// Features:
//   - First-time setup wizard (creates admin + master token)
//   - Bcrypt password hashing
//   - CSRF protection on all POST requests
//   - Rate-limited login (5 attempts → 15min lockout)
//   - Session security (regeneration, timeout, secure flags)
//   - Full audit logging
//   - Client management (create, suspend, restore, delete)
//   - Server management (add, revoke, restore, delete, search)
//   - Activity log with pagination
//   - Settings (password change, token regeneration)
// ---------------------------------------------------------------
require_once __DIR__ . '/db.php';

// ── Session setup ───────────────────────────────────────────────
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

// ── CSRF ────────────────────────────────────────────────────────

function csrf_token(): string {
    if (empty($_SESSION['csrf_token'])) {
        $_SESSION['csrf_token'] = bin2hex(random_bytes(32));
    }
    return $_SESSION['csrf_token'];
}

function csrf_field(): string {
    return '<input type="hidden" name="_csrf" value="' . csrf_token() . '">';
}

function verify_csrf(): bool {
    $token = $_POST['_csrf'] ?? '';
    return $token !== '' && hash_equals(csrf_token(), $token);
}

function admin_json_out(int $status, array $payload): never {
    http_response_code($status);
    header('Content-Type: application/json; charset=utf-8');
    echo json_encode($payload, JSON_UNESCAPED_SLASHES);
    exit;
}

// ── Auth helpers ────────────────────────────────────────────────

function is_authed(): bool {
    if (empty($_SESSION['admin_id'])) return false;
    // Session timeout
    if (isset($_SESSION['last_activity']) && (time() - $_SESSION['last_activity']) > SESSION_LIFETIME) {
        session_destroy();
        return false;
    }
    if (empty($_SESSION['admin_role']) && !empty($_SESSION['admin_user'])) {
        $_SESSION['admin_role'] = get_admin_role($_SESSION['admin_user']);
    }
    $_SESSION['last_activity'] = time();
    return true;
}

function require_auth(): void {
    if (!is_authed()) {
        header('Location: admin?page=login');
        exit;
    }
}

function admin_role(): string {
    return $_SESSION['admin_role'] ?? 'viewer';
}

function page_permission(string $page): ?string {
    return match ($page) {
        'dashboard'     => 'view_dashboard',
        'clients',
        'client_detail' => 'manage_clients',
        'servers'       => 'manage_servers',
        'logs'          => 'view_logs',
        'settings'      => 'view_dashboard',
        default         => null,
    };
}

function ensure_page_permission(string &$page, string &$message, string &$msg_type): void {
    $permission = page_permission($page);
    if (!$permission || can_admin($permission)) {
        return;
    }
    $page = 'dashboard';
    $message = 'Your account does not have access to that page.';
    $msg_type = 'error';
}

function portal_scheme(): string {
    if (
        (isset($_SERVER['HTTPS']) && $_SERVER['HTTPS'] === 'on') ||
        (isset($_SERVER['HTTP_X_FORWARDED_PROTO']) && $_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https')
    ) {
        return 'https';
    }
    return 'http';
}

function portal_base_url(): string {
    $base = rtrim(dirname($_SERVER['SCRIPT_NAME'] ?? ''), '/');
    return portal_scheme() . '://' . ($_SERVER['HTTP_HOST'] ?? 'localhost') . $base;
}

function e(string $s): string {
    return htmlspecialchars($s, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
}

function time_ago(string $datetime): string {
    $ts = strtotime($datetime);
    $diff = time() - $ts;
    if ($diff < 60)    return $diff . 's ago';
    if ($diff < 3600)  return floor($diff / 60) . 'm ago';
    if ($diff < 86400) return floor($diff / 3600) . 'h ago';
    return floor($diff / 86400) . 'd ago';
}

function server_health_meta(array $server): array {
    $status = strtolower(trim((string) ($server['health_status'] ?? 'unknown')));
    if (!in_array($status, ['online', 'offline', 'unknown'], true)) {
        $status = 'unknown';
    }

    $label = match ($status) {
        'online' => 'Healthy',
        'offline' => 'Offline',
        default => 'Unknown',
    };
    $class = match ($status) {
        'online' => 'badge badge-green',
        'offline' => 'badge badge-red',
        default => 'badge badge-blue',
    };

    $detail = 'No health probe yet.';
    if (!empty($server['health_checked_at'])) {
        $detail = 'Checked ' . time_ago((string) $server['health_checked_at']);
        if (!empty($server['health_endpoint'])) {
            $detail .= ' via ' . (string) $server['health_endpoint'];
        }
    }
    if ($status === 'offline' && !empty($server['health_error'])) {
        $detail = (string) $server['health_error'];
    }

    return [
        'status' => $status,
        'label' => $label,
        'class' => $class,
        'detail' => $detail,
    ];
}

// ── Route ───────────────────────────────────────────────────────
$page    = $_GET['page'] ?? '';
$message = '';
$msg_type = 'success';

// Redirect to setup if not configured
if (!is_setup_complete() && $page !== 'setup') {
    header('Location: admin?page=setup');
    exit;
}

// ── POST Actions ────────────────────────────────────────────────
if ($_SERVER['REQUEST_METHOD'] === 'POST') {

    // Actions that don't need CSRF: login, setup
    if ($page === 'login') {
        handle_login();
    } elseif ($page === 'setup') {
        handle_setup();
    } else {
        // All other POSTs require auth + CSRF
        require_auth();
        if (!verify_csrf()) {
            $message = 'Invalid security token. Please try again.';
            $msg_type = 'error';
        } else {
            handle_post_action();
        }
    }
}

// All pages except login/setup/logout require auth
if (!in_array($page, ['login', 'setup', 'logout', ''])) {
    require_auth();
}
if ($page === '' && is_authed()) {
    $page = 'dashboard';
} elseif ($page === '' && !is_authed()) {
    $page = 'login';
}

if (!in_array($page, ['login', 'setup', 'logout', ''], true) && is_authed()) {
    ensure_page_permission($page, $message, $msg_type);
}

if ($page === 'logout') {
    audit_log('logout', '', '');
    session_destroy();
    header('Location: admin?page=login');
    exit;
}

// ── POST Handlers ───────────────────────────────────────────────

function handle_login(): void {
    global $message, $msg_type, $page;

    if (is_rate_limited()) {
        $rem = lockout_remaining();
        $message = "Too many attempts. Try again in " . ceil($rem / 60) . " minutes.";
        $msg_type = 'error';
        return;
    }

    $username = trim($_POST['username'] ?? '');
    $password = $_POST['password'] ?? '';

    if (!$username || !$password) {
        $message = 'Username and password are required.';
        $msg_type = 'error';
        return;
    }

    $admin = get_admin($username);
    if ($admin && password_verify($password, $admin['password'])) {
        record_login_attempt(true);
        record_login_history('admin', (int) $admin['id'], $username, true);
        session_regenerate_id(true);
        $_SESSION['admin_id']   = $admin['id'];
        $_SESSION['admin_user'] = $admin['username'];
        $_SESSION['admin_role'] = $admin['role'] ?? 'admin';
        $_SESSION['last_activity'] = time();
        update_admin_login($admin['id']);
        audit_log('login', $username, 'Successful login');
        header('Location: admin?page=dashboard');
        exit;
    }

    record_login_attempt(false);
    record_login_history('admin', (int) ($admin['id'] ?? 0), $username, false);
    audit_log('login_failed', $username, 'Failed login attempt', 'anonymous');
    $message = 'Invalid username or password.';
    $msg_type = 'error';
}

function handle_setup(): void {
    global $message, $msg_type;

    if (is_setup_complete()) {
        header('Location: admin');
        exit;
    }

    $username = trim($_POST['username'] ?? '');
    $password = $_POST['password'] ?? '';
    $confirm  = $_POST['confirm_password'] ?? '';

    if (!$username || !$password) {
        $message = 'Username and password are required.';
        $msg_type = 'error';
        return;
    }
    if (strlen($password) < 8) {
        $message = 'Password must be at least 8 characters.';
        $msg_type = 'error';
        return;
    }
    if ($password !== $confirm) {
        $message = 'Passwords do not match.';
        $msg_type = 'error';
        return;
    }

    // Create admin
    create_admin($username, $password);

    // Generate master token
    $token = bin2hex(random_bytes(24));
    store_master_token($token);
    set_setting('setup_complete', '1');

    audit_log('setup', '', 'Initial setup completed', $username);

    session_regenerate_id(true);
    $admin = get_admin($username);
    $_SESSION['admin_id']   = $admin['id'];
    $_SESSION['admin_user'] = $admin['username'];
    $_SESSION['admin_role'] = $admin['role'] ?? 'superadmin';
    $_SESSION['last_activity'] = time();

    header('Location: admin?page=settings&setup=1');
    exit;
}

function handle_post_action(): void {
    global $message, $msg_type;
    $action = $_POST['action'] ?? '';
    $permission_map = [
        'add_server' => 'manage_servers',
        'revoke' => 'manage_servers',
        'restore' => 'manage_servers',
        'delete' => 'manage_servers',
        'update_note' => 'manage_servers',
        'bulk_revoke' => 'manage_servers',
        'bulk_restore' => 'manage_servers',
        'bulk_delete' => 'manage_servers',
        'edit_server' => 'manage_servers',
        'refresh_server_health' => 'manage_servers',
        'create_client' => 'manage_clients',
        'suspend_client' => 'manage_clients',
        'activate_client' => 'manage_clients',
        'delete_client' => 'manage_clients',
        'regenerate_client_token' => 'manage_clients',
        'add_authorized_ip' => 'manage_clients',
        'delete_authorized_ip' => 'manage_clients',
        'edit_client' => 'manage_clients',
        'create_subscription' => 'manage_clients',
        'update_subscription_status' => 'manage_clients',
        'change_password' => 'manage_settings',
        'regenerate_token' => 'manage_settings',
        'save_branding' => 'manage_settings',
        'cleanup_data' => 'manage_settings',
        'create_webhook' => 'manage_settings',
        'toggle_webhook' => 'manage_settings',
        'delete_webhook' => 'manage_settings',
        'create_admin_user' => 'manage_settings',
        'update_admin_role' => 'manage_settings',
        'delete_admin_user' => 'manage_settings',
    ];
    if (isset($permission_map[$action]) && !can_admin($permission_map[$action])) {
        $message = 'Your account does not have permission to perform that action.';
        $msg_type = 'error';
        return;
    }
    if (in_array($action, ['create_admin_user', 'update_admin_role', 'delete_admin_user'], true) && admin_role() !== 'superadmin') {
        $message = 'Only a superadmin can manage administrator accounts.';
        $msg_type = 'error';
        return;
    }

    switch ($action) {
        // ── Server actions ──
        case 'add_server':
            $ip       = trim($_POST['ip'] ?? '');
            $hostname = trim($_POST['hostname'] ?? '');
            $note     = trim($_POST['note'] ?? '');
            $cid      = (int) ($_POST['client_id'] ?? 0) ?: null;
            $authorize_ip = !empty($_POST['authorize_ip']);
            if (!$ip || !filter_var($ip, FILTER_VALIDATE_IP)) {
                $message = 'A valid IP address is required.';
                $msg_type = 'error';
                break;
            }
            $sid = bin2hex(random_bytes(8));
            db()->prepare('INSERT INTO servers (server_id, client_id, ip, hostname, token, note) VALUES (?, ?, ?, ?, ?, ?)')
                ->execute([$sid, $cid, $ip, $hostname, 'manual', $note]);
            $geo = lookup_server_geo($ip);
            if ($geo) update_server_geo($sid, $geo);
            if ($authorize_ip) {
                add_authorized_ip($cid, $ip, $hostname ?: $note);
            }
            audit_log('add_server', $sid, "IP: $ip, Host: $hostname" . ($cid ? ", Client: $cid" : ''));
            $message = "Server added — ID: $sid";
            if ($authorize_ip) {
                $message .= ' (IP authorized for zero-touch install)';
            }
            break;

        case 'revoke':
            $sid = trim($_POST['server_id'] ?? '');
            db()->prepare('UPDATE servers SET revoked = 1 WHERE server_id = ?')->execute([$sid]);
            audit_log('revoke', $sid, '');
            $message = "Server $sid revoked.";
            break;

        case 'restore':
            $sid = trim($_POST['server_id'] ?? '');
            db()->prepare('UPDATE servers SET revoked = 0 WHERE server_id = ?')->execute([$sid]);
            audit_log('restore', $sid, '');
            $message = "Server $sid restored.";
            break;

        case 'delete':
            $sid = trim($_POST['server_id'] ?? '');
            db()->prepare('DELETE FROM servers WHERE server_id = ?')->execute([$sid]);
            audit_log('delete_server', $sid, '');
            $message = "Server $sid deleted.";
            break;

        case 'bulk_revoke':
        case 'bulk_restore':
        case 'bulk_delete':
            $ids = array_values(array_filter(array_map('trim', (array) ($_POST['server_ids'] ?? []))));
            if (!$ids) {
                $message = 'Select at least one server first.';
                $msg_type = 'error';
                break;
            }
            $placeholders = implode(',', array_fill(0, count($ids), '?'));
            if ($action === 'bulk_revoke') {
                db()->prepare("UPDATE servers SET revoked = 1 WHERE server_id IN ($placeholders)")->execute($ids);
                audit_log('bulk_revoke', implode(', ', $ids), 'Bulk revoke');
                $message = count($ids) . ' server(s) revoked.';
            } elseif ($action === 'bulk_restore') {
                db()->prepare("UPDATE servers SET revoked = 0 WHERE server_id IN ($placeholders)")->execute($ids);
                audit_log('bulk_restore', implode(', ', $ids), 'Bulk restore');
                $message = count($ids) . ' server(s) restored.';
            } else {
                db()->prepare("DELETE FROM servers WHERE server_id IN ($placeholders)")->execute($ids);
                audit_log('bulk_delete_server', implode(', ', $ids), 'Bulk delete');
                $message = count($ids) . ' server(s) deleted.';
            }
            break;

        case 'update_note':
            $sid  = trim($_POST['server_id'] ?? '');
            $note = trim($_POST['note'] ?? '');
            db()->prepare('UPDATE servers SET note = ? WHERE server_id = ?')->execute([$note, $sid]);
            $message = "Note updated.";
            break;

        case 'edit_server':
            $sid          = trim($_POST['server_id'] ?? '');
            $hostname     = trim($_POST['hostname'] ?? '');
            $note         = trim($_POST['note'] ?? '');
            $cid          = (int) ($_POST['client_id'] ?? 0) ?: null;
            $authorize_ip = !empty($_POST['authorize_ip']);
            $row = db()->prepare('SELECT ip, country FROM servers WHERE server_id = ?')->execute([$sid])->fetch();
            db()->prepare('UPDATE servers SET hostname = ?, note = ?, client_id = ? WHERE server_id = ?')
                ->execute([$hostname, $note, $cid, $sid]);
            if ($row && empty($row['country'])) {
                $geo = lookup_server_geo($row['ip']);
                if ($geo) update_server_geo($sid, $geo);
            }
            if ($authorize_ip && $row) {
                try { add_authorized_ip($cid, $row['ip'], $hostname ?: $note ?: 'Admin edit'); } catch (InvalidArgumentException $e) {}
            }
            audit_log('edit_server', $sid, "Host: $hostname, Client: " . ($cid ?? 'none'));
            $message = "Server updated.";
            break;

        case 'refresh_server_health':
            $ids = array_values(array_filter(array_map('trim', (array) ($_POST['server_ids'] ?? []))));
            if (!$ids) {
                admin_json_out(422, [
                    'ok' => false,
                    'message' => 'No server IDs were provided.',
                    'results' => [],
                ]);
            }
            admin_json_out(200, [
                'ok' => true,
                'message' => 'Server health refreshed.',
                'results' => refresh_servers_health($ids),
            ]);

        // ── Client actions ──
        case 'create_client':
            $name     = trim($_POST['name'] ?? '');
            $email    = trim($_POST['email'] ?? '');
            $username = trim($_POST['client_username'] ?? '');
            $password = $_POST['client_password'] ?? '';
            $max      = max(0, (int) ($_POST['max_servers'] ?? 0));
            $note     = trim($_POST['note'] ?? '');

            if (!$name || !$username || !$password) {
                $message = 'Name, username, and password are required.';
                $msg_type = 'error';
                break;
            }
            if (strlen($password) < 6) {
                $message = 'Password must be at least 6 characters.';
                $msg_type = 'error';
                break;
            }
            if (get_client($username)) {
                $message = "Username '$username' is already taken.";
                $msg_type = 'error';
                break;
            }

            $result = create_client($name, $email, $username, $password, $max, $note);
            audit_log('create_client', $username, "Name: $name, Token: " . substr($result['token'], 0, 8) . '...');
            $message = "Client '$name' created. Token: " . $result['token'];
            break;

        case 'suspend_client':
            $cid = (int) ($_POST['client_id'] ?? 0);
            toggle_client($cid, false);
            audit_log('suspend_client', (string) $cid, '');
            $message = "Client suspended. Their servers will stop registering.";
            break;

        case 'activate_client':
            $cid = (int) ($_POST['client_id'] ?? 0);
            toggle_client($cid, true);
            audit_log('activate_client', (string) $cid, '');
            $message = "Client activated.";
            break;

        case 'delete_client':
            $cid = (int) ($_POST['client_id'] ?? 0);
            $cl = get_client_by_id($cid);
            delete_client($cid);
            audit_log('delete_client', $cl['username'] ?? (string) $cid, '');
            $message = "Client deleted. Their servers are now unassigned.";
            break;

        case 'regenerate_client_token':
            $cid = (int) ($_POST['client_id'] ?? 0);
            $new_token = regenerate_client_token($cid);
            audit_log('regenerate_client_token', (string) $cid, 'New token: ' . substr($new_token, 0, 8) . '...');
            $message = "New token: $new_token";
            break;

        case 'add_authorized_ip':
            $cid_raw = trim($_POST['client_id'] ?? '');
            $cid = ($cid_raw !== '' && (int)$cid_raw > 0) ? (int)$cid_raw : null;
            $ip  = trim($_POST['ip'] ?? '');
            $lbl = trim($_POST['label'] ?? '');
            if (!$ip || !is_public_routable_ip($ip)) {
                $message = 'IP must be a public routable address.';
                $msg_type = 'error';
                break;
            }
            try {
                add_authorized_ip($cid, $ip, $lbl);
            } catch (InvalidArgumentException $e) {
                $message = $e->getMessage();
                $msg_type = 'error';
                break;
            }
            audit_log('add_authorized_ip', $ip, "Client: $cid, Label: $lbl");
            $message = "IP $ip authorized for zero-touch install.";
            break;

        case 'delete_authorized_ip':
            $aid = (int) ($_POST['authorized_ip_id'] ?? 0);
            delete_authorized_ip($aid);
            audit_log('delete_authorized_ip', (string) $aid, '');
            $message = "IP authorization removed.";
            break;

        case 'edit_client':
            $cid  = (int) ($_POST['client_id'] ?? 0);
            $name = trim($_POST['name'] ?? '');
            $email = trim($_POST['email'] ?? '');
            $max  = max(0, (int) ($_POST['max_servers'] ?? 0));
            $note = trim($_POST['note'] ?? '');
            if (!$name) { $message = 'Name is required.'; $msg_type = 'error'; break; }
            update_client($cid, $name, $email, $max, $note);
            $new_pw = $_POST['new_password'] ?? '';
            if ($new_pw) {
                if (strlen($new_pw) < 6) { $message = 'Password must be at least 6 characters.'; $msg_type = 'error'; break; }
                update_client_password($cid, $new_pw);
            }
            audit_log('edit_client', (string) $cid, "Name: $name");
            $message = "Client updated.";
            break;

        case 'create_subscription':
            $cid = (int) ($_POST['client_id'] ?? 0);
            $plan = trim($_POST['plan'] ?? 'free');
            $max = max(0, (int) ($_POST['max_servers'] ?? 0));
            $amount = (float) ($_POST['amount'] ?? 0);
            $currency = strtoupper(trim($_POST['currency'] ?? 'USD'));
            $expires_at = trim($_POST['expires_at'] ?? '');
            $expires = $expires_at !== '' ? $expires_at . ' 23:59:59' : null;
            create_subscription($cid, $plan, $max, $amount, $currency ?: 'USD', $expires);
            audit_log('create_subscription', (string) $cid, "Plan: $plan");
            $message = 'Subscription saved.';
            break;

        case 'update_subscription_status':
            $sub_id = (int) ($_POST['subscription_id'] ?? 0);
            $status = trim($_POST['status'] ?? 'active');
            if (!in_array($status, ['active', 'expired', 'cancelled', 'trial'], true)) {
                $message = 'Invalid subscription status.';
                $msg_type = 'error';
                break;
            }
            update_subscription_status($sub_id, $status);
            audit_log('update_subscription_status', (string) $sub_id, "Status: $status");
            $message = 'Subscription status updated.';
            break;

        // ── Settings actions ──
        case 'change_password':
            $current = $_POST['current_password'] ?? '';
            $new     = $_POST['new_password'] ?? '';
            $confirm = $_POST['confirm_password'] ?? '';
            $admin   = get_admin($_SESSION['admin_user']);
            if (!$admin || !password_verify($current, $admin['password'])) {
                $message = 'Current password is incorrect.';
                $msg_type = 'error';
                break;
            }
            if (strlen($new) < 8) {
                $message = 'New password must be at least 8 characters.';
                $msg_type = 'error';
                break;
            }
            if ($new !== $confirm) {
                $message = 'New passwords do not match.';
                $msg_type = 'error';
                break;
            }
            update_admin_password($admin['id'], $new);
            audit_log('change_password', '', '');
            $message = 'Password updated.';
            break;

        case 'regenerate_token':
            $token = bin2hex(random_bytes(24));
            store_master_token($token);
            audit_log('regenerate_token', '', 'Master token regenerated');
            $message = 'Master token regenerated. Update your VPN server installers.';
            break;

        case 'save_branding':
            set_branding(
                trim($_POST['brand_name'] ?? ''),
                trim($_POST['brand_color'] ?? ''),
                trim($_POST['brand_logo_url'] ?? ''),
                trim($_POST['support_email'] ?? ''),
                trim($_POST['support_url'] ?? '')
            );
            audit_log('save_branding', '', 'Brand settings updated');
            $message = 'Branding updated.';
            break;

        case 'cleanup_data':
            $audit_days = max(1, (int) ($_POST['audit_days'] ?? 90));
            $history_days = max(1, (int) ($_POST['history_days'] ?? 90));
            $deleted = cleanup_old_data($audit_days, $history_days);
            audit_log('cleanup_data', '', json_encode($deleted));
            $message = sprintf(
                'Cleanup complete. Audit: %d, Login history: %d, Login attempts: %d, Install tickets: %d.',
                $deleted['audit_deleted'],
                $deleted['history_deleted'],
                $deleted['attempts_deleted'],
                $deleted['tickets_deleted']
            );
            break;

        case 'create_webhook':
            $name = trim($_POST['name'] ?? '');
            $url = trim($_POST['url'] ?? '');
            $events = trim($_POST['events'] ?? 'all');
            if ($name === '' || $url === '' || !filter_var($url, FILTER_VALIDATE_URL)) {
                $message = 'Webhook name and a valid URL are required.';
                $msg_type = 'error';
                break;
            }
            if (!is_safe_webhook_url($url)) {
                $message = 'Webhook URL must not point to a private or reserved IP address.';
                $msg_type = 'error';
                break;
            }
            $id = create_webhook($name, $url, $events ?: 'all');
            audit_log('create_webhook', (string) $id, $url);
            $message = 'Webhook created.';
            break;

        case 'toggle_webhook':
            $id = (int) ($_POST['webhook_id'] ?? 0);
            $hook = get_webhook($id);
            if (!$hook) {
                $message = 'Webhook not found.';
                $msg_type = 'error';
                break;
            }
            update_webhook($id, $hook['name'], $hook['url'], $hook['events'], !(bool) $hook['is_active']);
            audit_log('toggle_webhook', (string) $id, 'Webhook state toggled');
            $message = 'Webhook updated.';
            break;

        case 'delete_webhook':
            $id = (int) ($_POST['webhook_id'] ?? 0);
            delete_webhook($id);
            audit_log('delete_webhook', (string) $id, '');
            $message = 'Webhook deleted.';
            break;

        case 'create_admin_user':
            $username = trim($_POST['admin_username'] ?? '');
            $password = $_POST['admin_password'] ?? '';
            $role = trim($_POST['admin_role'] ?? 'admin');
            if ($username === '' || strlen($password) < 8) {
                $message = 'Admin username and an 8+ character password are required.';
                $msg_type = 'error';
                break;
            }
            if (!in_array($role, ['superadmin', 'admin', 'viewer'], true)) {
                $message = 'Invalid administrator role.';
                $msg_type = 'error';
                break;
            }
            if (get_admin($username)) {
                $message = "Username '$username' is already taken.";
                $msg_type = 'error';
                break;
            }
            create_admin_user($username, $password, $role);
            audit_log('create_admin_user', $username, "Role: $role");
            $message = 'Administrator created.';
            break;

        case 'update_admin_role':
            $id = (int) ($_POST['admin_id'] ?? 0);
            $role = trim($_POST['admin_role'] ?? 'admin');
            if (!in_array($role, ['superadmin', 'admin', 'viewer'], true)) {
                $message = 'Invalid administrator role.';
                $msg_type = 'error';
                break;
            }
            if ((int) ($_SESSION['admin_id'] ?? 0) === $id && $role === 'viewer') {
                $message = 'You cannot demote yourself to viewer.';
                $msg_type = 'error';
                break;
            }
            update_admin_role($id, $role);
            audit_log('update_admin_role', (string) $id, "Role: $role");
            $message = 'Administrator role updated.';
            break;

        case 'delete_admin_user':
            $id = (int) ($_POST['admin_id'] ?? 0);
            if ((int) ($_SESSION['admin_id'] ?? 0) === $id) {
                $message = 'You cannot delete your own administrator account.';
                $msg_type = 'error';
                break;
            }
            delete_admin_user($id);
            audit_log('delete_admin_user', (string) $id, '');
            $message = 'Administrator deleted.';
            break;
    }
}

// ── Page Rendering ──────────────────────────────────────────────

function render_page(string $page): string {
    ob_start();
    match ($page) {
        'dashboard' => page_dashboard(),
        'clients'   => page_clients(),
        'client_detail' => page_client_detail(),
        'servers'   => page_servers(),
        'logs'      => page_logs(),
        'settings'  => page_settings(),
        'login'     => page_login(),
        'setup'     => page_setup(),
        default     => page_dashboard(),
    };
    return ob_get_clean();
}

// ── DASHBOARD ───────────────────────────────────────────────────

function page_dashboard(): void {
    $stats = server_stats();
    $cstats = client_stats();
    $substats = subscription_stats();
    $countries = server_country_summary();
    $locations = server_locations();
    $recent = get_audit_logs(1, 10);
    ?>
    <div class="page-header">
        <h2>Dashboard</h2>
        <p class="subtext">License server overview</p>
    </div>

    <div class="stats-grid">
        <div class="stat-card">
            <div class="stat-icon purple"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M23 21v-2a4 4 0 0 0-3-3.87"/><path d="M16 3.13a4 4 0 0 1 0 7.75"/></svg></div>
            <div class="stat-num"><?= $cstats['active'] ?></div>
            <div class="stat-label">Active Clients</div>
        </div>
        <div class="stat-card">
            <div class="stat-icon blue"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="2" y="3" width="20" height="14" rx="2"/><line x1="8" y1="21" x2="16" y2="21"/><line x1="12" y1="17" x2="12" y2="21"/></svg></div>
            <div class="stat-num"><?= $stats['total'] ?></div>
            <div class="stat-label">Total Servers</div>
        </div>
        <div class="stat-card">
            <div class="stat-icon green"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M22 11.08V12a10 10 0 1 1-5.93-9.14"/><polyline points="22 4 12 14.01 9 11.01"/></svg></div>
            <div class="stat-num"><?= $stats['active'] ?></div>
            <div class="stat-label">Active Servers</div>
        </div>
        <div class="stat-card">
            <div class="stat-icon yellow"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="10"/><polyline points="12 6 12 12 16 14"/></svg></div>
            <div class="stat-num"><?= $stats['checkedin'] ?></div>
            <div class="stat-label">Healthy (48h)</div>
        </div>
    </div>

    <div class="stats-grid" style="grid-template-columns: repeat(3, 1fr)">
        <div class="stat-card">
            <div class="stat-num"><?= $substats['active'] ?></div>
            <div class="stat-label">Active Subscriptions</div>
        </div>
        <div class="stat-card">
            <div class="stat-num"><?= $substats['expired'] ?></div>
            <div class="stat-label">Expired Subscriptions</div>
        </div>
        <div class="stat-card">
            <div class="stat-num">$<?= number_format($substats['revenue'], 2) ?></div>
            <div class="stat-label">Tracked Revenue</div>
        </div>
    </div>

    <div class="detail-grid">
        <div class="card">
            <div class="card-header">
                <h3>Server Map</h3>
                <span class="muted"><?= count($locations) ?> geocoded</span>
            </div>
            <div class="card-body">
                <?php if (empty($locations)): ?>
                    <p class="muted">Server coordinates will appear here after new registrations complete geo lookup.</p>
                <?php else: ?>
                    <div id="smap-tip" style="position:fixed;display:none;background:#1a2535;color:#cdd;padding:5px 11px;border-radius:6px;font-size:12px;pointer-events:none;border:1px solid var(--border);white-space:nowrap;z-index:9999"></div>
                    <div style="border-radius:10px;border:1px solid var(--border);overflow:hidden">
                    <svg viewBox="0 20 720 310" style="width:100%;height:auto;display:block;background:#080e08">
                        <line x1="0" y1="180" x2="720" y2="180" stroke="rgba(255,255,255,0.05)" stroke-width="0.5"/>
                        <line x1="360" y1="0" x2="360" y2="360" stroke="rgba(255,255,255,0.05)" stroke-width="0.5"/>
                        <!-- Equirectangular: x=(lon+180)*2  y=(90-lat)*2 -->
                        <g fill="#162616" stroke="#1e3a1e" stroke-width="0.7" stroke-linejoin="round">
                            <!-- North America: Pacific→Alaska→Arctic→Atlantic→Gulf of Mexico concavity→Central Am -->
                            <path d="M204,164 L180,150 L162,146 L140,132 L126,116 L112,84 L96,68 L60,64 L24,72 L24,48 L80,40 L140,34 L210,54 L254,86 L220,96 L210,110 L200,132 L196,126 L186,120 L182,122 L166,128 L166,136 L168,142 L186,138 L184,148 L194,160Z"/>
                            <!-- Greenland -->
                            <path d="M254,60 L316,60 L320,36 L300,28 L256,14 L236,28 L224,52Z"/>
                            <!-- Iceland -->
                            <path d="M324,52 L336,48 L340,54 L330,58Z"/>
                            <!-- South America -->
                            <path d="M204,164 L236,158 L260,170 L290,192 L288,200 L282,226 L256,246 L230,290 L216,280 L210,258 L206,184Z"/>
                            <!-- Europe: Iberian→Scandinavia→Ural→Black Sea→Greece→Med -->
                            <path d="M348,108 L342,102 L342,92 L356,86 L364,78 L354,64 L370,56 L390,40 L416,38 L420,40 L480,70 L470,86 L440,88 L418,98 L404,106 L390,106 L384,92 L370,94 L366,98 L360,102Z"/>
                            <!-- UK -->
                            <path d="M350,78 L355,66 L350,64 L346,68 L348,76Z"/>
                            <!-- Africa: N.coast→Horn→S.Africa tip→W.coast-->
                            <path d="M348,108 L360,110 L380,106 L410,116 L424,118 L434,136 L446,156 L462,156 L442,182 L440,202 L430,230 L412,248 L398,250 L388,224 L378,180 L364,170 L344,172 L328,158 L326,150 L326,138 L332,124Z"/>
                            <!-- Arabian Peninsula -->
                            <path d="M430,122 L434,136 L446,156 L460,156 L474,136 L472,128 L458,124 L448,122Z"/>
                            <!-- Asia: Turkey→Levant→Gulf→India W+S+E→SE Asia→China→Siberia -->
                            <path d="M418,98 L432,106 L450,114 L456,120 L474,132 L480,136 L492,136 L500,142 L506,150 L514,164 L520,148 L536,136 L544,136 L558,148 L560,168 L568,160 L576,138 L588,136 L602,118 L602,106 L616,104 L620,96 L624,94 L646,86 L664,66 L686,64 L700,48 L700,36 L640,34 L560,34 L480,34 L480,70Z"/>
                            <!-- Japan -->
                            <path d="M622,118 L626,108 L638,106 L644,92 L650,94 L642,108 L630,118Z"/>
                            <!-- Australia -->
                            <path d="M588,224 L588,232 L586,248 L596,250 L618,246 L634,252 L638,250 L652,256 L660,254 L662,228 L652,216 L634,206 L620,204 L608,212Z"/>
                            <!-- New Zealand -->
                            <path d="M672,270 L676,258 L678,264 L674,272Z"/>
                            <!-- Antarctica strip -->
                            <path d="M0,332 L720,332 L720,314 L540,310 L360,320 L180,312 L0,318Z"/>
                        </g>
                        <?php foreach ($locations as $loc):
                            $sx  = number_format(((float)$loc['lon'] + 180.0) * 2.0, 2, '.', '');
                            $sy  = number_format((90.0 - (float)$loc['lat']) * 2.0, 2, '.', '');
                            $col = $loc['revoked'] ? '#ef4444' : '#4ade80';
                            $gl  = $loc['revoked'] ? 'rgba(239,68,68,0.25)' : 'rgba(74,222,128,0.25)';
                            $lbl = htmlspecialchars(($loc['hostname'] ?: $loc['ip']) . ' — ' . trim(($loc['city'] ? $loc['city'].', ' : '') . ($loc['country'] ?: '')), ENT_QUOTES);
                        ?>
                        <circle cx="<?= $sx ?>" cy="<?= $sy ?>" r="6" fill="<?= $gl ?>"/>
                        <circle class="sdot" cx="<?= $sx ?>" cy="<?= $sy ?>" r="3" fill="<?= $col ?>" data-label="<?= $lbl ?>" style="cursor:pointer"/>
                        <?php endforeach; ?>
                    </svg>
                    </div>
                    <script>
                    (function(){
                        var tip = document.getElementById('smap-tip');
                        document.querySelectorAll('.sdot').forEach(function(d){
                            d.addEventListener('mouseenter', function(){ tip.textContent = this.dataset.label; tip.style.display = 'block'; });
                            d.addEventListener('mousemove',  function(e){ tip.style.left = (e.clientX+14)+'px'; tip.style.top = (e.clientY-10)+'px'; });
                            d.addEventListener('mouseleave', function(){ tip.style.display = 'none'; });
                        });
                    })();
                    </script>
                    <p class="muted" style="margin-top:8px;font-size:12px">Hover a dot for server details.</p>
                <?php endif; ?>
            </div>
        </div>

        <div class="card">
            <div class="card-header">
                <h3>Server Geography</h3>
                <span class="muted">Top countries</span>
            </div>
            <div class="card-body">
                <?php if (empty($countries)): ?>
                    <p class="muted">No country data yet.</p>
                <?php else: ?>
                    <div class="info-grid">
                        <?php foreach ($countries as $row): ?>
                        <div class="info-row">
                            <span><?= e($row['country']) ?></span>
                            <span><?= (int) $row['total'] ?> server(s)</span>
                        </div>
                        <?php endforeach; ?>
                    </div>
                <?php endif; ?>
            </div>
        </div>
    </div>

    <div class="card">
        <div class="card-header">
            <h3>Recent Activity</h3>
            <a href="admin?page=logs" class="btn btn-ghost">View all</a>
        </div>
        <table>
            <thead><tr><th>Time</th><th>User</th><th>Action</th><th>Target</th></tr></thead>
            <tbody>
            <?php if (empty($recent)): ?>
                <tr><td colspan="4" class="empty">No activity yet</td></tr>
            <?php else: foreach ($recent as $log): ?>
                <tr>
                    <td class="muted"><?= time_ago($log['created_at']) ?></td>
                    <td><?= e($log['admin_user']) ?></td>
                    <td><span class="badge badge-<?= action_color($log['action']) ?>"><?= e($log['action']) ?></span></td>
                    <td class="mono"><?= e($log['target']) ?></td>
                </tr>
            <?php endforeach; endif; ?>
            </tbody>
        </table>
    </div>
    <?php
}

function action_color(string $action): string {
    return match (true) {
        str_contains($action, 'login_failed')  => 'red',
        str_contains($action, 'revoke')         => 'red',
        str_contains($action, 'delete')         => 'red',
        str_contains($action, 'suspend')        => 'red',
        str_contains($action, 'login')          => 'green',
        str_contains($action, 'register')       => 'green',
        str_contains($action, 'restore')        => 'green',
        str_contains($action, 'activate')       => 'green',
        str_contains($action, 'create')         => 'blue',
        str_contains($action, 'add')            => 'blue',
        str_contains($action, 'webhook')        => 'blue',
        str_contains($action, 'subscription')   => 'purple',
        str_contains($action, 'cleanup')        => 'yellow',
        str_contains($action, 'branding')       => 'yellow',
        str_contains($action, 'setup')          => 'blue',
        str_contains($action, 'token')          => 'yellow',
        str_contains($action, 'password')       => 'yellow',
        str_contains($action, 'edit')           => 'yellow',
        default                                 => 'default',
    };
}

// ── CLIENTS ─────────────────────────────────────────────────────

function page_clients(): void {
    $filter = $_GET['filter'] ?? 'all';
    $search = trim($_GET['search'] ?? '');
    $pg     = max(1, (int)($_GET['pg'] ?? 1));
    $pp     = 20;

    $clients = get_clients($filter, $search, $pg, $pp);
    $total   = count_clients($filter, $search);
    $pages   = (int) ceil($total / $pp);
    $cstats  = client_stats();
    if (($_GET['export'] ?? '') === 'csv') {
        header('Content-Type: text/csv; charset=utf-8');
        header('Content-Disposition: attachment; filename="iptunnel-clients.csv"');
        $out = fopen('php://output', 'w');
        fputcsv($out, ['id', 'name', 'email', 'username', 'max_servers', 'is_active', 'created_at', 'last_login', 'server_count', 'active_servers']);
        $cursor = client_export_cursor($filter, $search);
        while ($row = $cursor->fetch()) {
            fputcsv($out, [
                $row['id'],
                $row['name'],
                $row['email'],
                $row['username'],
                $row['max_servers'],
                $row['is_active'],
                $row['created_at'],
                $row['last_login'],
                $row['server_count'],
                $row['active_servers'],
            ]);
        }
        $cursor->closeCursor();
        fclose($out);
        exit;
    }
    ?>
    <div class="page-header">
        <h2>Clients</h2>
        <div class="action-group">
            <a href="admin?page=clients&filter=<?= e($filter) ?>&search=<?= urlencode($search) ?>&export=csv" class="btn btn-ghost">Export CSV</a>
            <button onclick="document.getElementById('add-client-form').classList.toggle('hidden')" class="btn btn-primary">
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" style="width:16px;height:16px;vertical-align:-3px;margin-right:4px"><line x1="12" y1="5" x2="12" y2="19"/><line x1="5" y1="12" x2="19" y2="12"/></svg>
                New Client
            </button>
        </div>
    </div>

    <!-- Create Client Form -->
    <div id="add-client-form" class="card hidden" style="margin-bottom:20px">
        <div class="card-header"><h3>Create Client Account</h3></div>
        <form method="POST" style="padding:16px 20px">
            <?= csrf_field() ?>
            <input type="hidden" name="action" value="create_client">
            <div class="form-grid-2">
                <div class="field">
                    <label>Display Name *</label>
                    <input type="text" name="name" placeholder="John Doe" required>
                </div>
                <div class="field">
                    <label>Email</label>
                    <input type="email" name="email" placeholder="john@example.com">
                </div>
                <div class="field">
                    <label>Username *</label>
                    <input type="text" name="client_username" placeholder="johndoe" required autocomplete="off">
                </div>
                <div class="field">
                    <label>Password *</label>
                    <input type="password" name="client_password" placeholder="min 6 chars" required minlength="6" autocomplete="new-password">
                </div>
                <div class="field">
                    <label>Max Servers <span class="muted">(0 = unlimited)</span></label>
                    <input type="number" name="max_servers" value="0" min="0">
                </div>
                <div class="field">
                    <label>Note</label>
                    <input type="text" name="note" placeholder="Internal note...">
                </div>
            </div>
            <div style="margin-top:12px">
                <button type="submit" class="btn btn-primary">Create Client</button>
            </div>
        </form>
    </div>

    <!-- Filters -->
    <div class="filter-bar">
        <a href="admin?page=clients" class="filter-tab <?= $filter==='all'?'active':'' ?>">All <span class="count"><?= $cstats['total'] ?></span></a>
        <a href="admin?page=clients&filter=active" class="filter-tab <?= $filter==='active'?'active':'' ?>">Active <span class="count"><?= $cstats['active'] ?></span></a>
        <a href="admin?page=clients&filter=inactive" class="filter-tab <?= $filter==='inactive'?'active':'' ?>">Suspended <span class="count"><?= $cstats['inactive'] ?></span></a>
        <form method="GET" class="search-box">
            <input type="hidden" name="page" value="clients">
            <input type="hidden" name="filter" value="<?= e($filter) ?>">
            <input type="text" name="search" value="<?= e($search) ?>" placeholder="Search name, email, username...">
        </form>
    </div>

    <!-- Client Table -->
    <div class="card">
        <table>
            <thead>
                <tr>
                    <th>Status</th>
                    <th>Name</th>
                    <th>Username</th>
                    <th>Servers</th>
                    <th>Limit</th>
                    <th>Token</th>
                    <th>Created</th>
                    <th>Last Login</th>
                    <th style="text-align:right">Actions</th>
                </tr>
            </thead>
            <tbody>
            <?php if (empty($clients)): ?>
                <tr><td colspan="9" class="empty">No clients yet. Create one above.</td></tr>
            <?php else: foreach ($clients as $c): ?>
                <tr>
                    <td>
                        <?php if ($c['is_active']): ?>
                            <span class="badge badge-green">Active</span>
                        <?php else: ?>
                            <span class="badge badge-red">Suspended</span>
                        <?php endif; ?>
                    </td>
                    <td>
                        <a href="admin?page=client_detail&id=<?= $c['id'] ?>" class="client-link">
                            <strong><?= e($c['name']) ?></strong>
                            <?php if ($c['email']): ?>
                                <span class="muted" style="font-size:11px;display:block"><?= e($c['email']) ?></span>
                            <?php endif; ?>
                        </a>
                    </td>
                    <td class="mono"><?= e($c['username']) ?></td>
                    <td>
                        <span class="<?= $c['active_servers'] > 0 ? 'text-green' : 'muted' ?>"><?= $c['active_servers'] ?></span>
                        <span class="muted">/ <?= $c['server_count'] ?></span>
                    </td>
                    <td class="muted"><?= $c['max_servers'] ?: '&infin;' ?></td>
                    <td>
                        <code class="sid"><?= e($c['token_preview'] ?? 'Hidden') ?></code>
                    </td>
                    <td class="muted" title="<?= e($c['created_at']) ?>"><?= time_ago($c['created_at']) ?></td>
                    <td class="muted"><?= $c['last_login'] ? time_ago($c['last_login']) : '<span class="text-muted">Never</span>' ?></td>
                    <td style="text-align:right">
                        <div class="action-group">
                            <a href="admin?page=client_detail&id=<?= $c['id'] ?>" class="btn btn-sm btn-ghost">View</a>
                            <?php if ($c['is_active']): ?>
                            <form method="POST" class="inline"><?= csrf_field() ?>
                                <input type="hidden" name="action" value="suspend_client">
                                <input type="hidden" name="client_id" value="<?= $c['id'] ?>">
                                <button class="btn btn-sm btn-danger" onclick="return confirm('Suspend this client? Their token will stop working.')">Suspend</button>
                            </form>
                            <?php else: ?>
                            <form method="POST" class="inline"><?= csrf_field() ?>
                                <input type="hidden" name="action" value="activate_client">
                                <input type="hidden" name="client_id" value="<?= $c['id'] ?>">
                                <button class="btn btn-sm btn-success">Activate</button>
                            </form>
                            <?php endif; ?>
                        </div>
                    </td>
                </tr>
            <?php endforeach; endif; ?>
            </tbody>
        </table>
    </div>

    <?php if ($pages > 1): ?>
    <div class="pagination">
        <?php for ($i = 1; $i <= $pages; $i++): ?>
            <a href="admin?page=clients&filter=<?= e($filter) ?>&search=<?= urlencode($search) ?>&pg=<?= $i ?>"
               class="pg-btn <?= $i === $pg ? 'active' : '' ?>"><?= $i ?></a>
        <?php endfor; ?>
    </div>
    <?php endif;
}

// ── CLIENT DETAIL ───────────────────────────────────────────────

function page_client_detail(): void {
    global $message, $msg_type;
    $cid = (int) ($_GET['id'] ?? 0);
    $client = get_client_by_id($cid);
    if (!$client) { echo '<div class="alert alert-error">Client not found.</div>'; return; }

    $filter = $_GET['filter'] ?? 'all';
    $servers = get_servers($filter, '', 1, 100, $cid);
    $stats = server_stats($cid);
    $subscription = get_subscription($cid);
    $login_history = get_login_history('client', $cid, 15);
    ?>
    <div class="page-header">
        <div>
            <a href="admin?page=clients" class="muted" style="text-decoration:none;font-size:12px">&larr; Back to Clients</a>
            <h2 style="margin-top:4px"><?= e($client['name']) ?></h2>
            <p class="subtext">@<?= e($client['username']) ?> &middot; <?= $client['is_active'] ? '<span class="text-green">Active</span>' : '<span class="text-red">Suspended</span>' ?></p>
        </div>
        <div class="action-group">
            <?php if ($client['is_active']): ?>
            <form method="POST" class="inline"><?= csrf_field() ?>
                <input type="hidden" name="action" value="suspend_client">
                <input type="hidden" name="client_id" value="<?= $cid ?>">
                <button class="btn btn-danger" onclick="return confirm('Suspend this client?')">Suspend</button>
            </form>
            <?php else: ?>
            <form method="POST" class="inline"><?= csrf_field() ?>
                <input type="hidden" name="action" value="activate_client">
                <input type="hidden" name="client_id" value="<?= $cid ?>">
                <button class="btn btn-success">Activate</button>
            </form>
            <?php endif; ?>
            <form method="POST" class="inline"><?= csrf_field() ?>
                <input type="hidden" name="action" value="delete_client">
                <input type="hidden" name="client_id" value="<?= $cid ?>">
                <button class="btn btn-ghost" onclick="return confirm('Permanently delete this client? Servers will become unassigned.')">Delete</button>
            </form>
        </div>
    </div>

    <!-- Client Info Cards -->
    <div class="detail-grid">
        <!-- Token Card -->
        <div class="card">
            <div class="card-header"><h3>API Token</h3></div>
            <div class="card-body">
                <p class="muted" style="margin-bottom:8px;font-size:12px">Client uses this token in <code>--license-token</code> when installing VPN servers.</p>
                <div class="token-display">
                    <code id="client-token" class="token-value"><?= e($client['token']) ?></code>
                    <button class="btn btn-sm btn-ghost" onclick="navigator.clipboard.writeText(document.getElementById('client-token').textContent)">Copy</button>
                </div>
                <form method="POST" style="margin-top:12px"><?= csrf_field() ?>
                    <input type="hidden" name="action" value="regenerate_client_token">
                    <input type="hidden" name="client_id" value="<?= $cid ?>">
                    <button class="btn btn-sm btn-danger" onclick="return confirm('Regenerate token? Client must update all their installers.')">Regenerate</button>
                </form>
            </div>
        </div>

        <!-- Edit Card -->
        <div class="card">
            <div class="card-header"><h3>Edit Client</h3></div>
            <form method="POST" class="card-body">
                <?= csrf_field() ?>
                <input type="hidden" name="action" value="edit_client">
                <input type="hidden" name="client_id" value="<?= $cid ?>">
                <div class="form-grid-2">
                    <div class="field">
                        <label>Display Name *</label>
                        <input type="text" name="name" value="<?= e($client['name']) ?>" required>
                    </div>
                    <div class="field">
                        <label>Email</label>
                        <input type="email" name="email" value="<?= e($client['email']) ?>">
                    </div>
                    <div class="field">
                        <label>Max Servers <span class="muted">(0 = unlimited)</span></label>
                        <input type="number" name="max_servers" value="<?= $client['max_servers'] ?>" min="0">
                    </div>
                    <div class="field">
                        <label>New Password <span class="muted">(leave blank to keep)</span></label>
                        <input type="password" name="new_password" placeholder="min 6 chars" autocomplete="new-password">
                    </div>
                </div>
                <div class="field">
                    <label>Note</label>
                    <input type="text" name="note" value="<?= e($client['note']) ?>">
                </div>
                <button type="submit" class="btn btn-primary">Save Changes</button>
            </form>
        </div>
    </div>

    <!-- Server Stats -->
    <div class="stats-grid" style="grid-template-columns: repeat(4, 1fr); margin-top:20px">
        <div class="stat-card">
            <div class="stat-num" style="font-size:24px"><?= $stats['total'] ?></div>
            <div class="stat-label">Total Servers</div>
        </div>
        <div class="stat-card">
            <div class="stat-num text-green" style="font-size:24px"><?= $stats['active'] ?></div>
            <div class="stat-label">Active</div>
        </div>
        <div class="stat-card">
            <div class="stat-num text-yellow" style="font-size:24px"><?= $stats['checkedin'] ?></div>
            <div class="stat-label">Healthy (48h)</div>
        </div>
        <div class="stat-card">
            <div class="stat-num text-red" style="font-size:24px"><?= $stats['revoked'] ?></div>
            <div class="stat-label">Revoked</div>
        </div>
    </div>

    <div class="detail-grid" style="margin-top:16px">
        <div class="card">
            <div class="card-header"><h3>Subscription</h3></div>
            <div class="card-body">
                <?php if ($subscription): ?>
                    <div class="info-grid" style="margin-bottom:16px">
                        <div class="info-row"><span class="muted">Plan</span><span><?= e($subscription['plan']) ?></span></div>
                        <div class="info-row"><span class="muted">Status</span><span><?= e($subscription['status']) ?></span></div>
                        <div class="info-row"><span class="muted">Max Servers</span><span><?= (int) $subscription['max_servers'] ?></span></div>
                        <div class="info-row"><span class="muted">Amount</span><span><?= e($subscription['currency']) ?> <?= number_format((float) $subscription['amount'], 2) ?></span></div>
                        <div class="info-row"><span class="muted">Expires</span><span><?= e($subscription['expires_at'] ?: 'Never') ?></span></div>
                    </div>
                    <form method="POST" class="form-row">
                        <?= csrf_field() ?>
                        <input type="hidden" name="action" value="update_subscription_status">
                        <input type="hidden" name="subscription_id" value="<?= (int) $subscription['id'] ?>">
                        <div class="field">
                            <label>Status</label>
                            <select name="status">
                                <?php foreach (['active', 'expired', 'cancelled', 'trial'] as $status): ?>
                                    <option value="<?= $status ?>" <?= $subscription['status'] === $status ? 'selected' : '' ?>><?= ucfirst($status) ?></option>
                                <?php endforeach; ?>
                            </select>
                        </div>
                        <div class="field">
                            <label>&nbsp;</label>
                            <button type="submit" class="btn btn-ghost">Update Status</button>
                        </div>
                    </form>
                <?php else: ?>
                    <p class="muted" style="margin-bottom:16px">No subscription recorded for this client yet.</p>
                <?php endif; ?>

                <form method="POST" class="form-grid-2" style="margin-top:12px">
                    <?= csrf_field() ?>
                    <input type="hidden" name="action" value="create_subscription">
                    <input type="hidden" name="client_id" value="<?= $cid ?>">
                    <div class="field">
                        <label>Plan</label>
                        <input type="text" name="plan" value="<?= e($subscription['plan'] ?? 'starter') ?>">
                    </div>
                    <div class="field">
                        <label>Max Servers</label>
                        <input type="number" name="max_servers" min="0" value="<?= (int) ($subscription['max_servers'] ?? $client['max_servers']) ?>">
                    </div>
                    <div class="field">
                        <label>Amount</label>
                        <input type="number" name="amount" min="0" step="0.01" value="<?= e((string) ($subscription['amount'] ?? '0.00')) ?>">
                    </div>
                    <div class="field">
                        <label>Currency</label>
                        <input type="text" name="currency" maxlength="3" value="<?= e($subscription['currency'] ?? 'USD') ?>">
                    </div>
                    <div class="field">
                        <label>Expiry Date</label>
                        <input type="date" name="expires_at" value="<?= e($subscription && $subscription['expires_at'] ? substr($subscription['expires_at'], 0, 10) : '') ?>">
                    </div>
                    <div class="field">
                        <label>&nbsp;</label>
                        <button type="submit" class="btn btn-primary">Save Subscription</button>
                    </div>
                </form>
            </div>
        </div>

        <div class="card">
            <div class="card-header"><h3>Login History</h3></div>
            <div class="card-body">
                <?php if (empty($login_history)): ?>
                    <p class="muted">No login history recorded yet.</p>
                <?php else: ?>
                    <table>
                        <thead><tr><th>Time</th><th>IP</th><th>Result</th></tr></thead>
                        <tbody>
                        <?php foreach ($login_history as $entry): ?>
                            <tr>
                                <td class="muted"><?= e(substr($entry['created_at'], 0, 16)) ?></td>
                                <td class="mono"><?= e($entry['ip_address']) ?></td>
                                <td><span class="badge badge-<?= $entry['success'] ? 'green' : 'red' ?>"><?= $entry['success'] ? 'Success' : 'Failed' ?></span></td>
                            </tr>
                        <?php endforeach; ?>
                        </tbody>
                    </table>
                <?php endif; ?>
            </div>
        </div>
    </div>

    <!-- Client's Servers -->
    <div class="card" style="margin-top:16px">
        <div class="card-header">
            <h3>Servers (<?= $stats['total'] ?>)</h3>
            <div class="filter-bar" style="margin-bottom:0;gap:2px">
                <a href="admin?page=client_detail&id=<?= $cid ?>" class="filter-tab <?= $filter==='all'?'active':'' ?>">All</a>
                <a href="admin?page=client_detail&id=<?= $cid ?>&filter=active" class="filter-tab <?= $filter==='active'?'active':'' ?>">Active</a>
                <a href="admin?page=client_detail&id=<?= $cid ?>&filter=revoked" class="filter-tab <?= $filter==='revoked'?'active':'' ?>">Revoked</a>
            </div>
        </div>
        <table>
            <thead>
                <tr>
                    <th>Status</th>
                    <th>IP Address</th>
                    <th>Hostname</th>
                    <th>Server ID</th>
                    <th>Last Check-in</th>
                    <th style="text-align:right">Actions</th>
                </tr>
            </thead>
            <tbody>
            <?php if (empty($servers)): ?>
                <tr><td colspan="6" class="empty">No servers registered by this client</td></tr>
            <?php else: foreach ($servers as $s):
                $rev   = (bool)$s['revoked'];
                $ci    = $s['last_checkin'];
                $stale = !$rev && $ci && (time() - strtotime($ci)) > 172800;
            ?>
                <tr>
                    <td>
                        <?php if ($rev): ?><span class="badge badge-red">Revoked</span>
                        <?php elseif ($stale): ?><span class="badge badge-yellow">Stale</span>
                        <?php else: ?><span class="badge badge-green">Active</span>
                        <?php endif; ?>
                    </td>
                    <td class="mono"><?= e($s['ip']) ?></td>
                    <td><?= e($s['hostname'] ?: "\xe2\x80\x94") ?></td>
                    <td><code class="sid" title="Click to copy" onclick="navigator.clipboard.writeText('<?= e($s['server_id']) ?>')"><?= e($s['server_id']) ?></code></td>
                    <td class="<?= $stale ? 'text-yellow' : 'muted' ?>"><?= $ci ? time_ago($ci) : '<span class="text-muted">Never</span>' ?></td>
                    <td style="text-align:right">
                        <div class="action-group">
                            <?php if (!$rev): ?>
                            <form method="POST" class="inline"><?= csrf_field() ?>
                                <input type="hidden" name="action" value="revoke">
                                <input type="hidden" name="server_id" value="<?= e($s['server_id']) ?>">
                                <button class="btn btn-sm btn-danger" onclick="return confirm('Revoke this server?')">Revoke</button>
                            </form>
                            <?php else: ?>
                            <form method="POST" class="inline"><?= csrf_field() ?>
                                <input type="hidden" name="action" value="restore">
                                <input type="hidden" name="server_id" value="<?= e($s['server_id']) ?>">
                                <button class="btn btn-sm btn-success">Restore</button>
                            </form>
                            <?php endif; ?>
                        </div>
                    </td>
                </tr>
            <?php endforeach; endif; ?>
            </tbody>
        </table>
    </div>

    <!-- Authorized IPs — Zero-touch installer flow -->
    <?php $auth_ips = list_authorized_ips($cid); ?>
    <div class="card" style="margin-top:16px">
        <div class="card-header">
            <h3>Authorized IPs</h3>
            <span class="muted" style="font-size:12px">Enables <code>bash iptunnel-install.sh</code> with no flags</span>
        </div>
        <div style="padding:16px 20px;border-bottom:1px solid var(--border)">
            <form method="POST" class="form-row">
                <?= csrf_field() ?>
                <input type="hidden" name="action" value="add_authorized_ip">
                <input type="hidden" name="client_id" value="<?= $cid ?>">
                <div class="field" style="flex:0 0 180px">
                    <label>IP Address *</label>
                    <input type="text" name="ip" placeholder="41.x.x.x" required>
                </div>
                <div class="field" style="flex:1">
                    <label>Label <span class="muted">(optional)</span></label>
                    <input type="text" name="label" placeholder="e.g. John's Lagos VPS">
                </div>
                <div class="field">
                    <label>&nbsp;</label>
                    <button type="submit" class="btn btn-primary">Add IP</button>
                </div>
            </form>
        </div>
        <table>
            <thead>
                <tr><th>IP Address</th><th>Label</th><th>Added</th><th style="text-align:right">Actions</th></tr>
            </thead>
            <tbody>
            <?php if (empty($auth_ips)): ?>
                <tr><td colspan="4" class="empty">No IPs authorized yet — add one to enable zero-touch installation.</td></tr>
            <?php else: foreach ($auth_ips as $aip): ?>
                <tr>
                    <td class="mono"><?= e($aip['ip']) ?></td>
                    <td class="muted"><?= e($aip['label'] ?: "\xe2\x80\x94") ?></td>
                    <td class="muted" title="<?= e($aip['created_at']) ?>"><?= time_ago($aip['created_at']) ?></td>
                    <td style="text-align:right">
                        <form method="POST" class="inline"><?= csrf_field() ?>
                            <input type="hidden" name="action" value="delete_authorized_ip">
                            <input type="hidden" name="authorized_ip_id" value="<?= $aip['id'] ?>">
                            <input type="hidden" name="client_id" value="<?= $cid ?>">
                            <button class="btn btn-sm btn-danger" onclick="return confirm('Remove this IP?')">Remove</button>
                        </form>
                    </td>
                </tr>
            <?php endforeach; endif; ?>
            </tbody>
        </table>
        <div style="padding:10px 20px;border-top:1px solid var(--border)">
            <p class="muted" style="font-size:12px">
                When a pre-authorized IP runs the installer, it receives a short-lived one-time install ticket.
                The reusable client token can still be used directly: <code>--license-token &lt;token&gt;</code>
            </p>
        </div>
    </div>

    <!-- Client Info Footer -->
    <div class="card" style="margin-top:16px">
        <div class="card-body">
            <div class="info-grid">
                <div class="info-row"><span class="muted">Created</span><span><?= e($client['created_at']) ?></span></div>
                <div class="info-row"><span class="muted">Last Login</span><span><?= $client['last_login'] ? e($client['last_login']) : 'Never' ?></span></div>
                <div class="info-row"><span class="muted">Note</span><span><?= e($client['note'] ?: "\xe2\x80\x94") ?></span></div>
                <div class="info-row">
                    <span class="muted">Client Portal URL</span>
                    <span class="mono" style="font-size:12px"><?= e((isset($_SERVER['HTTPS']) ? 'https' : 'http') . '://' . $_SERVER['HTTP_HOST'] . dirname($_SERVER['SCRIPT_NAME'])) ?>/client</span>
                </div>
            </div>
        </div>
    </div>
    <?php
}

// ── SERVERS ─────────────────────────────────────────────────────

function page_servers(): void {
    $filter = $_GET['filter'] ?? 'all';
    $search = trim($_GET['search'] ?? '');
    $pg     = max(1, (int)($_GET['pg'] ?? 1));
    $pp     = 20;

    $servers = get_servers($filter, $search, $pg, $pp);
    $total   = count_servers($filter, $search);
    $pages   = (int) ceil($total / $pp);
    $stats   = server_stats();

    if (($_GET['export'] ?? '') === 'csv') {
        header('Content-Type: text/csv; charset=utf-8');
        header('Content-Disposition: attachment; filename="iptunnel-servers.csv"');
        $out = fopen('php://output', 'w');
        fputcsv($out, ['server_id', 'ip', 'hostname', 'client_name', 'country', 'city', 'registered_at', 'last_checkin', 'revoked', 'note']);
        $cursor = server_export_cursor($filter, $search);
        while ($row = $cursor->fetch()) {
            fputcsv($out, [
                $row['server_id'],
                $row['ip'],
                $row['hostname'],
                $row['client_name'] ?? '',
                $row['country'] ?? '',
                $row['city'] ?? '',
                $row['registered_at'],
                $row['last_checkin'],
                (int) $row['revoked'],
                $row['note'],
            ]);
        }
        $cursor->closeCursor();
        fclose($out);
        exit;
    }

    // Get clients for dropdown
    $all_clients = get_clients('all', '', 1, 100);
    $authorized_ip_map = [];
    foreach (list_authorized_ips() as $row) {
        $key = ($row['client_id'] ?? 'null') . '|' . $row['ip'];
        $authorized_ip_map[$key] = (int) $row['id'];
    }
    ?>
    <div class="page-header">
        <div>
            <h2>Servers</h2>
            <div class="muted" style="font-size:12px;margin-top:6px">Use this page to manage live/manual server records. Zero-touch install is still client-linked because authorized IPs belong to clients.</div>
            <div id="healthRefreshStatus" class="muted" style="font-size:12px;margin-top:6px">Health status is kept fresh by maintenance runs and live-updates here while this page is open.</div>
        </div>
        <div class="action-group">
            <a href="admin?page=servers&filter=<?= e($filter) ?>&search=<?= urlencode($search) ?>&export=csv" class="btn btn-ghost">Export CSV</a>
            <button type="button" id="refreshHealthBtn" class="btn btn-ghost">Refresh Health</button>
            <button onclick="document.getElementById('add-form').classList.toggle('hidden')" class="btn btn-primary">
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" style="width:16px;height:16px;vertical-align:-3px;margin-right:4px"><line x1="12" y1="5" x2="12" y2="19"/><line x1="5" y1="12" x2="19" y2="12"/></svg>
                Add Server
            </button>
        </div>
    </div>

    <!-- Add Server Form -->
    <div id="add-form" class="card hidden" style="margin-bottom:20px">
        <div class="card-header"><h3>Add Server Manually</h3></div>
        <form method="POST" class="form-row" style="padding:16px 20px">
            <?= csrf_field() ?>
            <input type="hidden" name="action" value="add_server">
            <div class="field">
                <label>IP Address *</label>
                <input type="text" name="ip" placeholder="41.x.x.x" required>
            </div>
            <div class="field">
                <label>Hostname</label>
                <input type="text" name="hostname" placeholder="api.example.com">
            </div>
            <div class="field">
                <label>Client</label>
                <select name="client_id">
                    <option value="">— No client (admin) —</option>
                    <?php foreach ($all_clients as $c): ?>
                        <option value="<?= $c['id'] ?>"><?= e($c['name']) ?> (@<?= e($c['username']) ?>)</option>
                    <?php endforeach; ?>
                </select>
            </div>
            <div class="field">
                <label>Note</label>
                <input type="text" name="note" placeholder="Personal server">
            </div>
            <div class="field" style="flex:1 1 100%;max-width:none;margin-top:4px">
                <label style="display:flex;align-items:flex-start;gap:10px;cursor:pointer;margin-bottom:0">
                    <input type="checkbox" name="authorize_ip" value="1" style="margin-top:3px;flex-shrink:0;width:auto">
                    <span>
                        <span style="display:block;font-size:13px;color:var(--text);font-weight:500">Zero-touch Install</span>
                        <span class="muted" style="display:block;font-size:12px;line-height:1.45;margin-top:3px">Also authorize this IP for no-token install.</span>
                    </span>
                </label>
            </div>
            <div class="field">
                <label>&nbsp;</label>
                <button type="submit" class="btn btn-primary">Add</button>
            </div>
        </form>
    </div>

    <!-- Filters -->
    <div class="filter-bar">
        <a href="admin?page=servers" class="filter-tab <?= $filter==='all'?'active':'' ?>">All <span class="count"><?= $stats['total'] ?></span></a>
        <a href="admin?page=servers&filter=active" class="filter-tab <?= $filter==='active'?'active':'' ?>">Active <span class="count"><?= $stats['active'] ?></span></a>
        <a href="admin?page=servers&filter=revoked" class="filter-tab <?= $filter==='revoked'?'active':'' ?>">Revoked <span class="count"><?= $stats['revoked'] ?></span></a>
        <a href="admin?page=servers&filter=stale" class="filter-tab <?= $filter==='stale'?'active':'' ?>">Stale</a>
        <a href="admin?page=servers&filter=manual" class="filter-tab <?= $filter==='manual'?'active':'' ?>">Manual</a>
        <form method="GET" class="search-box">
            <input type="hidden" name="page" value="servers">
            <input type="hidden" name="filter" value="<?= e($filter) ?>">
            <input type="text" name="search" value="<?= e($search) ?>" placeholder="Search IP, hostname, ID...">
        </form>
    </div>

    <!-- Server Table -->
    <!-- Bulk-action form is a standalone element (not wrapping the table) so it
         does not nest the per-row action forms below. Checkboxes/buttons attach
         to it via the HTML form="" attribute. -->
    <form id="bulk-servers-form" method="POST"><?= csrf_field() ?></form>
    <div class="card">
        <div class="card-header">
            <h3>Bulk Actions</h3>
            <div class="action-group">
                <button type="submit" form="bulk-servers-form" name="action" value="bulk_revoke" class="btn btn-sm btn-danger" onclick="return confirm('Revoke selected servers?')">Revoke Selected</button>
                <button type="submit" form="bulk-servers-form" name="action" value="bulk_restore" class="btn btn-sm btn-success">Restore Selected</button>
                <button type="submit" form="bulk-servers-form" name="action" value="bulk_delete" class="btn btn-sm btn-ghost" onclick="return confirm('Delete selected servers?')">Delete Selected</button>
            </div>
        </div>
        <div style="overflow-x:auto">
        <table style="min-width:1120px" data-server-health-table>
            <thead>
                <tr>
                    <th><input type="checkbox" onclick="document.querySelectorAll('.server-check').forEach(cb => cb.checked = this.checked)"></th>
                    <th>Status</th>
                    <th>Health</th>
                    <th>IP Address</th>
                    <th>Hostname</th>
                    <th>Client</th>
                    <th>Geo</th>
                    <th>Server ID</th>
                    <th>Registered</th>
                    <th>Health Checked</th>
                    <th>Note</th>
                    <th style="text-align:right;white-space:nowrap">Actions</th>
                </tr>
            </thead>
            <tbody>
            <?php if (empty($servers)): ?>
                <tr><td colspan="12" class="empty">No servers found</td></tr>
            <?php else: foreach ($servers as $s):
                $rev    = (bool)$s['revoked'];
                $manual = $s['token'] === 'manual';
                $ci     = $s['last_checkin'];
                $stale  = !$rev && $ci && (time() - strtotime($ci)) > 172800;
                $auth_key = ($s['client_id'] ?? 'null') . '|' . ($s['ip'] ?? '');
                $ip_authorized = isset($authorized_ip_map[$auth_key]);
                $authorized_ip_id = $ip_authorized ? $authorized_ip_map[$auth_key] : 0;
            ?>
                <tr data-server-id="<?= e($s['server_id']) ?>" data-server-revoked="<?= $rev ? '1' : '0' ?>">
                    <td><input type="checkbox" class="server-check" form="bulk-servers-form" name="server_ids[]" value="<?= e($s['server_id']) ?>"></td>
                    <td>
                        <?php if ($rev): ?>
                            <span class="badge badge-red">Revoked</span>
                        <?php elseif ($stale): ?>
                            <span class="badge badge-yellow">Stale</span>
                        <?php elseif ($manual): ?>
                            <span class="badge badge-blue">Manual</span>
                        <?php else: ?>
                            <span class="badge badge-green">Active</span>
                        <?php endif; ?>
                    </td>
                    <?php $health = server_health_meta($s); ?>
                    <td data-health-cell>
                        <span class="<?= e($health['class']) ?>" data-health-badge><?= e($health['label']) ?></span>
                        <div class="muted" data-health-detail style="font-size:11px;margin-top:4px" title="<?= e($health['detail']) ?>"><?= e($health['detail']) ?></div>
                    </td>
                    <td class="mono"><?= e($s['ip']) ?></td>
                    <td><?= e($s['hostname'] ?: "\xe2\x80\x94") ?></td>
                    <td>
                        <?php if ($s['client_id']): ?>
                            <a href="admin?page=client_detail&id=<?= $s['client_id'] ?>" class="client-link-sm"><?= e($s['client_name'] ?? 'Unknown') ?></a>
                            <div class="muted" style="font-size:11px;margin-top:4px">
                                <?= $ip_authorized ? 'Zero-touch enabled' : 'Zero-touch not enabled' ?>
                            </div>
                        <?php else: ?>
                            <span class="muted">&mdash;</span>
                        <?php endif; ?>
                    </td>
                    <td class="muted">
                        <?php if (!empty($s['country']) || !empty($s['city'])): ?>
                            <?= e(trim(($s['city'] ? $s['city'] . ', ' : '') . ($s['country'] ?: ''))) ?>
                        <?php else: ?>
                            &mdash;
                        <?php endif; ?>
                    </td>
                    <td>
                        <code class="sid" title="Click to copy" onclick="navigator.clipboard.writeText('<?= e($s['server_id']) ?>')"><?= e($s['server_id']) ?></code>
                    </td>
                    <td class="muted" title="<?= e($s['registered_at']) ?>"><?= time_ago($s['registered_at']) ?></td>
                    <td class="muted" data-health-checked title="<?= e($s['health_checked_at'] ?? 'Never') ?>">
                        <?= !empty($s['health_checked_at']) ? e(time_ago($s['health_checked_at'])) : '<span class="text-muted">Never</span>' ?>
                    </td>
                    <td class="muted" style="max-width:120px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap" title="<?= e($s['note']) ?>">
                        <?= e($s['note'] ?: "\xe2\x80\x94") ?>
                    </td>
                    <td style="text-align:right;white-space:nowrap">
                        <div class="action-group">
                            <?php if (!$rev): ?>
                            <form method="POST" class="inline"><?= csrf_field() ?>
                                <input type="hidden" name="action" value="revoke">
                                <input type="hidden" name="server_id" value="<?= e($s['server_id']) ?>">
                                <button class="btn btn-sm btn-danger" onclick="return confirm('Revoke this server?')">Revoke</button>
                            </form>
                            <?php else: ?>
                            <form method="POST" class="inline"><?= csrf_field() ?>
                                <input type="hidden" name="action" value="restore">
                                <input type="hidden" name="server_id" value="<?= e($s['server_id']) ?>">
                                <button class="btn btn-sm btn-success">Restore</button>
                            </form>
                            <?php endif; ?>
                            <form method="POST" class="inline"><?= csrf_field() ?>
                                <input type="hidden" name="action" value="delete">
                                <input type="hidden" name="server_id" value="<?= e($s['server_id']) ?>">
                                <button class="btn btn-sm btn-ghost" onclick="return confirm('Permanently delete this server?')">Delete</button>
                            </form>
                            <?php if (!$ip_authorized): ?>
                            <form method="POST" class="inline"><?= csrf_field() ?>
                                <input type="hidden" name="action" value="add_authorized_ip">
                                <input type="hidden" name="client_id" value="<?= (int) ($s['client_id'] ?? 0) ?: '' ?>">
                                <input type="hidden" name="ip" value="<?= e($s['ip']) ?>">
                                <input type="hidden" name="label" value="<?= e($s['hostname'] ?: ($s['note'] ?: 'Server page authorize')) ?>">
                                <button class="btn btn-sm btn-primary">Zero-touch</button>
                            </form>
                            <?php else: ?>
                            <form method="POST" class="inline"><?= csrf_field() ?>
                                <input type="hidden" name="action" value="delete_authorized_ip">
                                <input type="hidden" name="authorized_ip_id" value="<?= $authorized_ip_id ?>">
                                <button class="btn btn-sm btn-ghost" onclick="return confirm('Remove zero-touch for this server?')">- Zero-touch</button>
                            </form>
                            <?php endif; ?>
                        </div>
                    </td>
                </tr>
            <?php endforeach; endif; ?>
            </tbody>
        </table>
        </div>
    </div>

    <script>
    (function () {
        const table = document.querySelector('[data-server-health-table]');
        if (!table) return;

        const refreshBtn = document.getElementById('refreshHealthBtn');
        const statusEl = document.getElementById('healthRefreshStatus');
        const csrf = <?= json_encode(csrf_token(), JSON_UNESCAPED_SLASHES) ?>;
        let inflight = false;
        let queuedRefresh = false;
        let timerId = null;

        function setStatus(text, isError) {
            if (!statusEl) return;
            statusEl.textContent = text;
            statusEl.className = isError ? 'text-red' : 'muted';
        }

        function visibleServerIds() {
            return Array.from(table.querySelectorAll('tr[data-server-id][data-server-revoked="0"]'))
                .map((row) => row.getAttribute('data-server-id'))
                .filter(Boolean);
        }

        function updateRow(result) {
            const row = table.querySelector(`tr[data-server-id="${result.server_id}"]`);
            if (!row) return;

            const badge = row.querySelector('[data-health-badge]');
            const detail = row.querySelector('[data-health-detail]');
            const checked = row.querySelector('[data-health-checked]');
            if (!badge || !detail) return;

            let label = 'Unknown';
            let className = 'badge badge-blue';
            if (result.health_status === 'online') {
                label = 'Healthy';
                className = 'badge badge-green';
            } else if (result.health_status === 'offline') {
                label = 'Offline';
                className = 'badge badge-red';
            }

            badge.textContent = label;
            badge.className = className;

            let detailText = 'No health probe yet.';
            if (result.health_status === 'offline') {
                detailText = result.health_error || 'Health probe failed.';
            } else if (result.health_checked_at) {
                detailText = 'Checked just now';
                if (result.health_endpoint) {
                    detailText += ` via ${result.health_endpoint}`;
                }
            }

            detail.textContent = detailText;
            detail.setAttribute('title', detailText);

            if (checked) {
                const checkedText = result.health_checked_at ? 'just now' : 'Never';
                checked.textContent = checkedText;
                checked.setAttribute('title', result.health_checked_at || 'Never');
            }
        }

        async function refreshHealth(source) {
            const ids = visibleServerIds();
            if (!ids.length) return;
            if (inflight) {
                if (source === 'manual') {
                    queuedRefresh = true;
                    setStatus('A refresh is already running. Your manual refresh will run next.', false);
                }
                return;
            }

            inflight = true;
            queuedRefresh = false;
            if (refreshBtn) {
                refreshBtn.disabled = true;
                refreshBtn.textContent = source === 'manual' ? 'Refreshing...' : 'Auto Refreshing...';
            }
            setStatus(source === 'manual' ? 'Refreshing visible server health...' : 'Auto-refreshing visible server health...', false);

            const body = new URLSearchParams();
            body.set('action', 'refresh_server_health');
            body.set('_csrf', csrf);
            ids.forEach((id) => body.append('server_ids[]', id));

            try {
                const response = await fetch('admin?page=servers', {
                    method: 'POST',
                    credentials: 'same-origin',
                    headers: {
                        'Content-Type': 'application/x-www-form-urlencoded;charset=UTF-8',
                        'X-Requested-With': 'XMLHttpRequest'
                    },
                    body: body.toString()
                });

                const payload = await response.json();
                if (!response.ok || !payload.ok) {
                    throw new Error(payload.message || 'Health refresh failed.');
                }

                (payload.results || []).forEach(updateRow);
                setStatus(source === 'manual' ? 'Server health updated.' : 'Server health updated automatically.', false);
            } catch (error) {
                setStatus(error.message || 'Health refresh failed.', true);
            } finally {
                inflight = false;
                if (refreshBtn) {
                    refreshBtn.disabled = false;
                    refreshBtn.textContent = 'Refresh Health';
                }
                clearTimeout(timerId);
                if (queuedRefresh) {
                    queuedRefresh = false;
                    refreshHealth('manual');
                    return;
                }
                timerId = window.setTimeout(function () { refreshHealth('auto'); }, 60000);
            }
        }

        if (refreshBtn) {
            refreshBtn.addEventListener('click', function () {
                clearTimeout(timerId);
                refreshHealth('manual');
            });
        }

        window.refreshServerHealthNow = function () {
            clearTimeout(timerId);
            refreshHealth('manual');
        };

        refreshHealth('auto');
    })();
    </script>

    <?php if ($pages > 1): ?>
    <div class="pagination">
        <?php for ($i = 1; $i <= $pages; $i++): ?>
            <a href="admin?page=servers&filter=<?= e($filter) ?>&search=<?= urlencode($search) ?>&pg=<?= $i ?>"
               class="pg-btn <?= $i === $pg ? 'active' : '' ?>"><?= $i ?></a>
        <?php endfor; ?>
    </div>
    <?php endif; ?>

    <?php
}

// ── ACTIVITY LOG ────────────────────────────────────────────────

function page_logs(): void {
    $action_filter = $_GET['action'] ?? '';
    $pg = max(1, (int)($_GET['pg'] ?? 1));
    $pp = 30;
    $logs  = get_audit_logs($pg, $pp, $action_filter);
    $total = count_audit_logs($action_filter);
    $pages = (int) ceil($total / $pp);
    $login_history = get_all_login_history(1, 20);
    ?>
    <div class="page-header">
        <h2>Activity Log</h2>
        <p class="subtext"><?= $total ?> events recorded</p>
    </div>

    <div class="filter-bar">
        <a href="admin?page=logs" class="filter-tab <?= !$action_filter ? 'active' : '' ?>">All</a>
        <?php foreach (['login', 'login_failed', 'register_new', 'revoke', 'restore', 'delete_server', 'add_server', 'create_client', 'suspend_client', 'activate_client', 'change_password', 'regenerate_token'] as $a): ?>
            <a href="admin?page=logs&action=<?= $a ?>" class="filter-tab <?= $action_filter === $a ? 'active' : '' ?>"><?= $a ?></a>
        <?php endforeach; ?>
    </div>

    <div class="card">
        <table>
            <thead><tr><th>Time</th><th>User</th><th>Action</th><th>Target</th><th>Detail</th><th>IP</th></tr></thead>
            <tbody>
            <?php if (empty($logs)): ?>
                <tr><td colspan="6" class="empty">No log entries</td></tr>
            <?php else: foreach ($logs as $log): ?>
                <tr>
                    <td class="muted nowrap" title="<?= e($log['created_at']) ?>"><?= e(substr($log['created_at'], 0, 16)) ?></td>
                    <td><?= e($log['admin_user']) ?></td>
                    <td><span class="badge badge-<?= action_color($log['action']) ?>"><?= e($log['action']) ?></span></td>
                    <td class="mono"><?= e($log['target']) ?></td>
                    <td class="muted" style="max-width:200px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap"><?= e($log['detail']) ?></td>
                    <td class="mono muted"><?= e($log['ip_address']) ?></td>
                </tr>
            <?php endforeach; endif; ?>
            </tbody>
        </table>
    </div>

    <?php if ($pages > 1): ?>
    <div class="pagination">
        <?php for ($i = 1; $i <= $pages; $i++): ?>
            <a href="admin?page=logs&action=<?= urlencode($action_filter) ?>&pg=<?= $i ?>"
               class="pg-btn <?= $i === $pg ? 'active' : '' ?>"><?= $i ?></a>
        <?php endfor; ?>
    </div>
    <?php endif; ?>

    <div class="card" style="margin-top:20px">
        <div class="card-header">
            <h3>Login History</h3>
            <span class="muted">Latest 20 admin and client login attempts</span>
        </div>
        <table>
            <thead><tr><th>Time</th><th>Type</th><th>Username</th><th>IP</th><th>Result</th><th>User Agent</th></tr></thead>
            <tbody>
            <?php if (empty($login_history)): ?>
                <tr><td colspan="6" class="empty">No login history recorded</td></tr>
            <?php else: foreach ($login_history as $entry): ?>
                <tr>
                    <td class="muted nowrap"><?= e(substr($entry['created_at'], 0, 16)) ?></td>
                    <td><span class="badge badge-blue"><?= e($entry['user_type']) ?></span></td>
                    <td><?= e($entry['username']) ?></td>
                    <td class="mono muted"><?= e($entry['ip_address']) ?></td>
                    <td><span class="badge badge-<?= $entry['success'] ? 'green' : 'red' ?>"><?= $entry['success'] ? 'Success' : 'Failed' ?></span></td>
                    <td class="muted" style="max-width:220px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap" title="<?= e($entry['user_agent']) ?>"><?= e($entry['user_agent']) ?></td>
                </tr>
            <?php endforeach; endif; ?>
            </tbody>
        </table>
    </div>
    <?php
}

// ── SETTINGS ────────────────────────────────────────────────────

function page_settings(): void {
    $token = get_master_token();
    $show_setup_banner = isset($_GET['setup']);
    $manageSettings = can_admin('manage_settings');
    $hooks = get_webhooks();
    $admins = get_all_admins();
    $substats = subscription_stats();
    $current_brand = [
        'name' => brand('name'),
        'color' => brand('color'),
        'logo' => brand('logo'),
        'support_email' => brand('support_email'),
        'support_url' => brand('support_url'),
    ];
    ?>
    <?php if ($show_setup_banner): ?>
    <div class="alert alert-success" style="margin-bottom:20px">
        <strong>Setup complete!</strong> Save your master token below. You'll need it when installing VPN servers.
    </div>
    <?php endif; ?>

    <div class="page-header">
        <h2>Settings</h2>
        <p class="subtext">Security, branding, automations, and platform controls</p>
    </div>

    <div class="stats-grid" style="grid-template-columns: repeat(3, 1fr)">
        <div class="stat-card">
            <div class="stat-num"><?= count($hooks) ?></div>
            <div class="stat-label">Webhooks</div>
        </div>
        <div class="stat-card">
            <div class="stat-num"><?= $substats['active'] ?></div>
            <div class="stat-label">Active Subscriptions</div>
        </div>
        <div class="stat-card">
            <div class="stat-num"><?= count_login_history() ?></div>
            <div class="stat-label">Login History Rows</div>
        </div>
    </div>

    <div class="settings-grid">
        <?php if ($manageSettings): ?>
        <div class="card">
            <div class="card-header"><h3>Master Token</h3></div>
            <div class="card-body">
                <p class="muted" style="margin-bottom:12px">Admin-level API access. Use for admin operations or direct server registration.</p>
                <div class="token-display">
                    <code id="master-token" class="token-value"><?= e($token) ?></code>
                    <button class="btn btn-sm btn-ghost" onclick="navigator.clipboard.writeText(document.getElementById('master-token').textContent)">Copy</button>
                </div>
                <form method="POST" style="margin-top:16px">
                    <?= csrf_field() ?>
                    <input type="hidden" name="action" value="regenerate_token">
                    <button class="btn btn-sm btn-danger" onclick="return confirm('Regenerate master token? Existing admin API integrations will need updating.')">Regenerate Token</button>
                </form>
            </div>
        </div>
        <?php endif; ?>

        <div class="card">
            <div class="card-header"><h3>Change Password</h3></div>
            <form method="POST" class="card-body">
                <?= csrf_field() ?>
                <input type="hidden" name="action" value="change_password">
                <div class="field-stack">
                    <div class="field">
                        <label>Current Password</label>
                        <input type="password" name="current_password" required>
                    </div>
                    <div class="field">
                        <label>New Password</label>
                        <input type="password" name="new_password" required minlength="8">
                    </div>
                    <div class="field">
                        <label>Confirm New Password</label>
                        <input type="password" name="confirm_password" required minlength="8">
                    </div>
                    <button type="submit" class="btn btn-primary">Update Password</button>
                </div>
            </form>
        </div>

        <?php if ($manageSettings): ?>
        <div class="card">
            <div class="card-header"><h3>White-Label Branding</h3></div>
            <form method="POST" class="card-body">
                <?= csrf_field() ?>
                <input type="hidden" name="action" value="save_branding">
                <div class="field">
                    <label>Brand Name</label>
                    <input type="text" name="brand_name" value="<?= e($current_brand['name']) ?>">
                </div>
                <div class="field">
                    <label>Primary Color</label>
                    <input type="text" name="brand_color" value="<?= e($current_brand['color']) ?>" placeholder="#63b3ed">
                </div>
                <div class="field">
                    <label>Logo URL</label>
                    <input type="url" name="brand_logo_url" value="<?= e($current_brand['logo']) ?>">
                </div>
                <div class="field">
                    <label>Support Email</label>
                    <input type="email" name="support_email" value="<?= e($current_brand['support_email']) ?>">
                </div>
                <div class="field">
                    <label>Support URL</label>
                    <input type="url" name="support_url" value="<?= e($current_brand['support_url']) ?>">
                </div>
                <button type="submit" class="btn btn-primary">Save Branding</button>
            </form>
        </div>

        <div class="card">
            <div class="card-header"><h3>Audit Cleanup</h3></div>
            <form method="POST" class="card-body">
                <?= csrf_field() ?>
                <input type="hidden" name="action" value="cleanup_data">
                <div class="field">
                    <label>Audit Log Retention (days)</label>
                    <input type="number" name="audit_days" min="1" value="90">
                </div>
                <div class="field">
                    <label>Login History Retention (days)</label>
                    <input type="number" name="history_days" min="1" value="90">
                </div>
                <button type="submit" class="btn btn-ghost" onclick="return confirm('Purge old audit and login history rows now?')">Run Cleanup</button>
            </form>
        </div>
        <?php endif; ?>

        <div class="card">
            <div class="card-header"><h3>API Reference</h3></div>
            <div class="card-body">
                <p class="muted" style="margin-bottom:12px">Primary API: <code>/api/v2</code>. Token types: <strong>Master token</strong> (admin), <strong>Client token</strong> (per-client), or <strong>one-time install tickets</strong> issued from <code>/api/v2/install-tickets/issue</code>.</p>
                <div class="api-ref">
                    <div class="api-row"><span class="method get">GET</span>  <code>/api/v2/healthz</code><span class="muted">Liveness probe</span></div>
                    <div class="api-row"><span class="method post">POST</span> <code>/api/v2/install-tickets/issue</code><span class="muted">Issue one-time install ticket</span></div>
                    <div class="api-row"><span class="method post">POST</span> <code>/api/v2/servers/register</code><span class="muted">Register a server</span></div>
                    <div class="api-row"><span class="method post">POST</span> <code>/api/v2/servers/{server_id}/check-in</code><span class="muted">Daily heartbeat</span></div>
                    <div class="api-row"><span class="method get">GET</span>  <code>/api/v2/servers</code><span class="muted">List servers (scoped by bearer token)</span></div>
                    <div class="api-row"><span class="method get">GET</span>  <code>/api/v2/clients</code><span class="muted">List clients (master token only)</span></div>
                </div>
                <p class="muted" style="margin-top:16px">Legacy routes remain available during migration, but new installs now prefer <code>/api/v2</code>.</p>
                <p class="muted" style="margin-top:12px">Client install usage:</p>
                <pre class="code-block">bash &lt;(curl -4 -sk https://license.internetshub.com/iptunnel-install.sh) \
  --license-token &lt;client_token_here&gt;</pre>
            </div>
        </div>

        <div class="card">
            <div class="card-header"><h3>System Info</h3></div>
            <div class="card-body">
                <div class="info-grid">
                    <div class="info-row"><span class="muted">PHP Version</span><span><?= PHP_VERSION ?></span></div>
                    <div class="info-row"><span class="muted">Server</span><span><?= e($_SERVER['SERVER_SOFTWARE'] ?? 'unknown') ?></span></div>
                    <div class="info-row"><span class="muted">Database</span><span><?= e(DB_NAME) ?></span></div>
                    <div class="info-row"><span class="muted">Admin User</span><span><?= e($_SESSION['admin_user'] ?? '') ?></span></div>
                    <div class="info-row"><span class="muted">Role</span><span><?= e(admin_role()) ?></span></div>
                    <div class="info-row"><span class="muted">Session Timeout</span><span><?= SESSION_LIFETIME / 60 ?> min</span></div>
                    <div class="info-row"><span class="muted">Client Portal</span><span class="mono" style="font-size:12px"><?= e(portal_base_url()) ?>/client</span></div>
                </div>
            </div>
        </div>
    </div>

    <?php if ($manageSettings): ?>
    <div class="card" style="margin-top:20px">
        <div class="card-header"><h3>Webhooks</h3></div>
        <div class="card-body">
            <form method="POST" class="form-grid-2" style="margin-bottom:18px">
                <?= csrf_field() ?>
                <input type="hidden" name="action" value="create_webhook">
                <div class="field">
                    <label>Name</label>
                    <input type="text" name="name" placeholder="Discord alerts">
                </div>
                <div class="field">
                    <label>URL</label>
                    <input type="url" name="url" placeholder="https://example.com/webhook">
                </div>
                <div class="field">
                    <label>Events</label>
                    <input type="text" name="events" value="all" placeholder="all or register,revoke">
                </div>
                <div class="field">
                    <label>&nbsp;</label>
                    <button type="submit" class="btn btn-primary">Add Webhook</button>
                </div>
            </form>
            <table>
                <thead><tr><th>Name</th><th>Events</th><th>Status</th><th>Last Status</th><th>Failures</th><th style="text-align:right">Actions</th></tr></thead>
                <tbody>
                <?php if (empty($hooks)): ?>
                    <tr><td colspan="6" class="empty">No webhooks configured</td></tr>
                <?php else: foreach ($hooks as $hook): ?>
                    <tr>
                        <td>
                            <strong><?= e($hook['name']) ?></strong>
                            <div class="muted" style="font-size:11px"><?= e($hook['url']) ?></div>
                        </td>
                        <td class="mono"><?= e($hook['events']) ?></td>
                        <td><span class="badge badge-<?= $hook['is_active'] ? 'green' : 'red' ?>"><?= $hook['is_active'] ? 'Active' : 'Disabled' ?></span></td>
                        <td class="muted"><?= e((string) ($hook['last_status'] ?: '—')) ?></td>
                        <td class="muted"><?= (int) $hook['fail_count'] ?></td>
                        <td style="text-align:right">
                            <div class="action-group">
                                <form method="POST" class="inline"><?= csrf_field() ?>
                                    <input type="hidden" name="action" value="toggle_webhook">
                                    <input type="hidden" name="webhook_id" value="<?= (int) $hook['id'] ?>">
                                    <button class="btn btn-sm btn-ghost"><?= $hook['is_active'] ? 'Disable' : 'Enable' ?></button>
                                </form>
                                <form method="POST" class="inline"><?= csrf_field() ?>
                                    <input type="hidden" name="action" value="delete_webhook">
                                    <input type="hidden" name="webhook_id" value="<?= (int) $hook['id'] ?>">
                                    <button class="btn btn-sm btn-danger" onclick="return confirm('Delete this webhook?')">Delete</button>
                                </form>
                            </div>
                        </td>
                    </tr>
                <?php endforeach; endif; ?>
                </tbody>
            </table>
        </div>
    </div>
    <?php endif; ?>

    <?php if ($manageSettings && admin_role() === 'superadmin'): ?>
    <div class="card" style="margin-top:20px">
        <div class="card-header"><h3>Administrator Accounts</h3></div>
        <div class="card-body">
            <form method="POST" class="form-grid-2" style="margin-bottom:18px">
                <?= csrf_field() ?>
                <input type="hidden" name="action" value="create_admin_user">
                <div class="field">
                    <label>Username</label>
                    <input type="text" name="admin_username" required>
                </div>
                <div class="field">
                    <label>Password</label>
                    <input type="password" name="admin_password" minlength="8" required>
                </div>
                <div class="field">
                    <label>Role</label>
                    <select name="admin_role">
                        <option value="admin">admin</option>
                        <option value="viewer">viewer</option>
                        <option value="superadmin">superadmin</option>
                    </select>
                </div>
                <div class="field">
                    <label>&nbsp;</label>
                    <button type="submit" class="btn btn-primary">Create Admin</button>
                </div>
            </form>
            <table>
                <thead><tr><th>Username</th><th>Role</th><th>Created</th><th>Last Login</th><th style="text-align:right">Actions</th></tr></thead>
                <tbody>
                <?php foreach ($admins as $admin): ?>
                    <tr>
                        <td><?= e($admin['username']) ?><?= (int) $admin['id'] === (int) ($_SESSION['admin_id'] ?? 0) ? ' <span class="muted">(you)</span>' : '' ?></td>
                        <td>
                            <form method="POST" class="form-row" style="gap:8px;align-items:center">
                                <?= csrf_field() ?>
                                <input type="hidden" name="action" value="update_admin_role">
                                <input type="hidden" name="admin_id" value="<?= (int) $admin['id'] ?>">
                                <select name="admin_role">
                                    <?php foreach (['viewer', 'admin', 'superadmin'] as $role): ?>
                                        <option value="<?= $role ?>" <?= $admin['role'] === $role ? 'selected' : '' ?>><?= $role ?></option>
                                    <?php endforeach; ?>
                                </select>
                                <button type="submit" class="btn btn-sm btn-ghost">Save</button>
                            </form>
                        </td>
                        <td class="muted"><?= e(substr($admin['created_at'], 0, 16)) ?></td>
                        <td class="muted"><?= $admin['last_login'] ? e(substr($admin['last_login'], 0, 16)) : 'Never' ?></td>
                        <td style="text-align:right">
                            <?php if ((int) $admin['id'] !== (int) ($_SESSION['admin_id'] ?? 0)): ?>
                            <form method="POST" class="inline">
                                <?= csrf_field() ?>
                                <input type="hidden" name="action" value="delete_admin_user">
                                <input type="hidden" name="admin_id" value="<?= (int) $admin['id'] ?>">
                                <button type="submit" class="btn btn-sm btn-danger" onclick="return confirm('Delete this administrator?')">Delete</button>
                            </form>
                            <?php endif; ?>
                        </td>
                    </tr>
                <?php endforeach; ?>
                </tbody>
            </table>
        </div>
    </div>
    <?php endif; ?>
    <?php
}

// ── LOGIN PAGE ──────────────────────────────────────────────────

function page_login(): void {
    global $message, $msg_type;
    ?><!DOCTYPE html>
<html lang="en"><head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title><?= e(brand('name')) ?> License — Admin Sign In</title>
<?= render_css() ?>
</head><body class="auth-page">
<div class="auth-container">
    <div class="auth-card">
        <div class="auth-logo">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" style="width:40px;height:40px;color:#63b3ed"><path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/></svg>
        </div>
        <h2><?= e(brand('name')) ?> License</h2>
        <p class="subtext">Admin panel — sign in to manage</p>
        <?php if ($message): ?>
            <div class="alert alert-<?= $msg_type ?>"><?= e($message) ?></div>
        <?php endif; ?>
        <form method="POST">
            <div class="field">
                <label>Username</label>
                <input type="text" name="username" required autofocus autocomplete="username">
            </div>
            <div class="field">
                <label>Password</label>
                <input type="password" name="password" required autocomplete="current-password">
            </div>
            <button type="submit" class="btn btn-primary btn-full">Sign In</button>
        </form>
        <p class="subtext" style="margin-top:16px;font-size:11px">
            <a href="client" style="color:var(--muted);text-decoration:none">Client portal &rarr;</a>
        </p>
    </div>
</div>
</body></html><?php exit;
}

// ── SETUP WIZARD ────────────────────────────────────────────────

function page_setup(): void {
    global $message, $msg_type;
    if (is_setup_complete()) { header('Location: admin'); exit; }
    ?><!DOCTYPE html>
<html lang="en"><head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title><?= e(brand('name')) ?> License — Setup</title>
<?= render_css() ?>
</head><body class="auth-page">
<div class="auth-container">
    <div class="auth-card" style="max-width:420px">
        <div class="auth-logo">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" style="width:40px;height:40px;color:#68d391"><path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/></svg>
        </div>
        <h2>Welcome to <?= e(brand('name')) ?></h2>
        <p class="subtext">Create your admin account to get started.</p>
        <?php if ($message): ?>
            <div class="alert alert-<?= $msg_type ?>"><?= e($message) ?></div>
        <?php endif; ?>
        <form method="POST">
            <div class="field">
                <label>Admin Username</label>
                <input type="text" name="username" required autofocus autocomplete="off" placeholder="admin">
            </div>
            <div class="field">
                <label>Password (min 8 chars)</label>
                <input type="password" name="password" required minlength="8" autocomplete="new-password">
            </div>
            <div class="field">
                <label>Confirm Password</label>
                <input type="password" name="confirm_password" required minlength="8" autocomplete="new-password">
            </div>
            <button type="submit" class="btn btn-primary btn-full">Create Account & Generate Token</button>
        </form>
        <p class="subtext" style="margin-top:16px;font-size:11px">A master API token will be generated automatically.</p>
    </div>
</div>
</body></html><?php exit;
}

// ── CSS ─────────────────────────────────────────────────────────

function render_css(): string {
    $brandColor = e(brand('color') ?: '#63b3ed');
    return '<style>
:root {
  --bg: #0f1117;  --surface: #1a1d2e;  --surface-hover: #1e2433;
  --border: #2d3748;  --border-light: #374151;
  --text: #e2e8f0;  --text-secondary: #a0aec0;  --muted: #718096;
  --blue: ' . $brandColor . ';  --green: #68d391;  --red: #fc8181;  --yellow: #f6e05e;
  --purple: #b794f4;
  --blue-bg: #1a2e4a;  --green-bg: #1c4532;  --red-bg: #4a1c1c;
  --yellow-bg: #3d3519;  --purple-bg: #2d1f54;
  --sidebar-w: 250px;
}
*, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
body { font-family: system-ui, -apple-system, "Segoe UI", sans-serif; background: var(--bg); color: var(--text); min-height: 100vh; font-size: 14px; }

/* Auth pages */
.auth-page { display: flex; align-items: center; justify-content: center; min-height: 100vh; }
.auth-container { width: 100%; max-width: 380px; padding: 20px; }
.auth-card { background: var(--surface); border: 1px solid var(--border); border-radius: 16px; padding: 40px 36px; text-align: center; }
.auth-logo { margin-bottom: 16px; }
.auth-card h2 { font-size: 22px; margin-bottom: 4px; }
.auth-card .subtext { color: var(--muted); font-size: 13px; margin-bottom: 24px; }
.auth-card form { text-align: left; }

/* Layout */
.layout { display: flex; min-height: 100vh; }
.sidebar { width: var(--sidebar-w); background: var(--surface); border-right: 1px solid var(--border); display: flex; flex-direction: column; position: fixed; top: 0; left: 0; bottom: 0; z-index: 100; }
.sidebar-brand { padding: 20px 20px 16px; border-bottom: 1px solid var(--border); display: flex; align-items: center; gap: 10px; }
.sidebar-brand svg { width: 28px; height: 28px; color: var(--blue); flex-shrink: 0; }
.sidebar-brand span { font-weight: 700; font-size: 15px; letter-spacing: .3px; }
.sidebar-nav { flex: 1; padding: 12px 10px; }
.nav-item { display: flex; align-items: center; gap: 10px; padding: 10px 14px; border-radius: 8px; color: var(--text-secondary); text-decoration: none; font-size: 13px; font-weight: 500; margin-bottom: 2px; transition: all .15s; }
.nav-item:hover { background: var(--surface-hover); color: var(--text); }
.nav-item.active { background: var(--blue-bg); color: var(--blue); }
.nav-item svg { width: 18px; height: 18px; flex-shrink: 0; }
.sidebar-footer { padding: 12px 10px; border-top: 1px solid var(--border); }
.sidebar-footer .nav-item { color: var(--muted); }
.sidebar-footer .nav-item:hover { color: var(--red); background: var(--red-bg); }
.main { margin-left: var(--sidebar-w); flex: 1; padding: 28px 32px; max-width: 1200px; }

/* Page header */
.page-header { display: flex; align-items: center; justify-content: space-between; margin-bottom: 24px; }
.page-header h2 { font-size: 22px; font-weight: 700; }
.subtext { color: var(--muted); font-size: 13px; }

/* Stats */
.stats-grid { display: grid; grid-template-columns: repeat(4, 1fr); gap: 16px; margin-bottom: 24px; }
.stat-card { background: var(--surface); border: 1px solid var(--border); border-radius: 12px; padding: 20px; }
.stat-icon { width: 40px; height: 40px; border-radius: 10px; display: flex; align-items: center; justify-content: center; margin-bottom: 12px; }
.stat-icon svg { width: 20px; height: 20px; }
.stat-icon.blue   { background: var(--blue-bg);   color: var(--blue); }
.stat-icon.green  { background: var(--green-bg);  color: var(--green); }
.stat-icon.red    { background: var(--red-bg);    color: var(--red); }
.stat-icon.yellow { background: var(--yellow-bg); color: var(--yellow); }
.stat-icon.purple { background: var(--purple-bg); color: var(--purple); }
.stat-num { font-size: 32px; font-weight: 700; line-height: 1; }
.stat-label { font-size: 12px; color: var(--muted); margin-top: 4px; text-transform: uppercase; letter-spacing: .5px; }

/* Cards */
.card { background: var(--surface); border: 1px solid var(--border); border-radius: 12px; margin-bottom: 20px; overflow: hidden; }
.card-header { padding: 14px 20px; border-bottom: 1px solid var(--border); display: flex; align-items: center; justify-content: space-between; }
.card-header h3 { font-size: 14px; font-weight: 600; color: var(--text-secondary); text-transform: uppercase; letter-spacing: .5px; }
.card-body { padding: 20px; }

/* Tables */
table { width: 100%; border-collapse: collapse; }
th { padding: 10px 16px; text-align: left; font-size: 11px; color: var(--muted); text-transform: uppercase; letter-spacing: .5px; border-bottom: 1px solid var(--border); font-weight: 600; }
td { padding: 12px 16px; border-bottom: 1px solid #1e2433; vertical-align: middle; }
tr:last-child td { border-bottom: none; }
tr:hover td { background: var(--surface-hover); }
.empty { text-align: center; color: var(--muted); padding: 32px 16px !important; }

/* Badges */
.badge { display: inline-block; padding: 3px 10px; border-radius: 999px; font-size: 11px; font-weight: 600; white-space: nowrap; }
.badge-green   { background: var(--green-bg);  color: var(--green); }
.badge-red     { background: var(--red-bg);    color: var(--red); }
.badge-yellow  { background: var(--yellow-bg); color: var(--yellow); }
.badge-blue    { background: var(--blue-bg);   color: var(--blue); }
.badge-purple  { background: var(--purple-bg); color: var(--purple); }
.badge-default { background: var(--surface-hover); color: var(--muted); }

/* Buttons */
.btn { display: inline-flex; align-items: center; padding: 8px 16px; border-radius: 8px; font-size: 13px; font-weight: 600; border: none; cursor: pointer; text-decoration: none; transition: all .15s; color: var(--text); }
.btn:hover { opacity: .85; }
.btn-primary { background: #2b6cb0; color: #fff; }
.btn-danger  { background: var(--red-bg); color: var(--red); }
.btn-success { background: var(--green-bg); color: var(--green); }
.btn-ghost   { background: transparent; color: var(--text-secondary); border: 1px solid var(--border); }
.btn-ghost:hover { background: var(--surface-hover); }
.btn-sm { padding: 4px 10px; font-size: 12px; border-radius: 6px; }
.btn-full { width: 100%; justify-content: center; padding: 10px; font-size: 14px; }

/* Forms */
.field { margin-bottom: 14px; }
.field label { display: block; font-size: 12px; color: var(--muted); margin-bottom: 5px; font-weight: 500; }
.field input, .field select { width: 100%; background: var(--bg); border: 1px solid var(--border); color: var(--text); border-radius: 8px; padding: 9px 13px; font-size: 14px; outline: none; transition: border-color .15s; }
.field input:focus, .field select:focus { border-color: var(--blue); }
.form-row { display: flex; gap: 12px; flex-wrap: wrap; align-items: flex-end; }
.form-row .field { margin-bottom: 0; }
.form-grid-2 { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; }
.field-stack .field { margin-bottom: 16px; }

/* Filter bar */
.filter-bar { display: flex; align-items: center; gap: 4px; margin-bottom: 16px; flex-wrap: wrap; }
.filter-tab { padding: 6px 14px; border-radius: 8px; font-size: 13px; color: var(--muted); text-decoration: none; font-weight: 500; transition: all .15s; }
.filter-tab:hover { background: var(--surface-hover); color: var(--text); }
.filter-tab.active { background: var(--blue-bg); color: var(--blue); }
.filter-tab .count { font-size: 11px; opacity: .7; }
.search-box { margin-left: auto; }
.search-box input { background: var(--surface); border: 1px solid var(--border); color: var(--text); border-radius: 8px; padding: 6px 12px; font-size: 13px; outline: none; width: 220px; }
.search-box input:focus { border-color: var(--blue); }

/* Pagination */
.pagination { display: flex; gap: 4px; margin-top: 16px; justify-content: center; }
.pg-btn { padding: 6px 12px; border-radius: 6px; background: var(--surface); border: 1px solid var(--border); color: var(--text-secondary); text-decoration: none; font-size: 13px; }
.pg-btn:hover { background: var(--surface-hover); }
.pg-btn.active { background: var(--blue-bg); color: var(--blue); border-color: transparent; }

/* Alerts */
.alert { padding: 12px 16px; border-radius: 8px; font-size: 13px; margin-bottom: 16px; }
.alert-success { background: var(--green-bg); border: 1px solid #276749; color: var(--green); }
.alert-error   { background: var(--red-bg);   border: 1px solid #9b2c2c; color: var(--red); }

/* Utility */
.mono { font-family: "SF Mono", "Cascadia Code", Consolas, monospace; font-size: 12px; }
.muted { color: var(--muted); }
.text-green { color: var(--green); }
.text-red { color: var(--red); }
.text-yellow { color: var(--yellow); }
.text-muted { color: var(--muted); }
.nowrap { white-space: nowrap; }
.inline { display: inline; }
.hidden { display: none !important; }
.action-group { display: flex; gap: 6px; justify-content: flex-end; }
code { font-family: "SF Mono", "Cascadia Code", Consolas, monospace; }
.sid { font-size: 11px; color: var(--text-secondary); cursor: pointer; padding: 2px 6px; border-radius: 4px; background: var(--bg); }
.sid:hover { background: var(--blue-bg); color: var(--blue); }

/* Client links */
.client-link { color: var(--purple); text-decoration: none; }
.client-link:hover { text-decoration: underline; }
.client-link-sm { color: var(--purple); text-decoration: none; font-size: 12px; }
.client-link-sm:hover { text-decoration: underline; }

/* Token display */
.token-display { display: flex; align-items: center; gap: 8px; background: var(--bg); border: 1px solid var(--border); border-radius: 8px; padding: 10px 14px; }
.token-value { font-size: 13px; color: var(--green); word-break: break-all; flex: 1; }

/* Settings & detail grids */
.settings-grid { display: grid; grid-template-columns: repeat(2, 1fr); gap: 20px; }
.detail-grid { display: grid; grid-template-columns: repeat(2, 1fr); gap: 20px; }

/* API reference */
.api-ref { display: flex; flex-direction: column; gap: 8px; }
.api-row { display: flex; align-items: center; gap: 10px; padding: 6px 0; }
.method { font-size: 11px; font-weight: 700; padding: 2px 8px; border-radius: 4px; font-family: monospace; }
.method.get  { background: var(--green-bg); color: var(--green); }
.method.post { background: var(--blue-bg);  color: var(--blue); }
.api-row code { font-size: 13px; color: var(--text); }
.api-row .muted { font-size: 12px; margin-left: auto; }

/* Info grid */
.info-grid { display: flex; flex-direction: column; gap: 10px; }
.info-row { display: flex; justify-content: space-between; padding: 4px 0; border-bottom: 1px solid var(--border); font-size: 13px; }
.info-row:last-child { border-bottom: none; }

/* Code block */
.code-block { background: var(--bg); border: 1px solid var(--border); border-radius: 8px; padding: 12px 16px; font-family: monospace; font-size: 12px; color: var(--text-secondary); overflow-x: auto; white-space: pre; }

/* Mobile hamburger toggle (hidden on desktop) */
.menu-toggle { display: none; align-items: center; justify-content: center; width: 38px; height: 38px; background: var(--surface); border: 1px solid var(--border); border-radius: 8px; cursor: pointer; color: var(--text-secondary); margin-bottom: 16px; }
.menu-toggle:hover { color: var(--text); border-color: var(--blue); }
.menu-toggle svg { width: 20px; height: 20px; }
.sidebar-overlay { display: none; position: fixed; inset: 0; background: rgba(0,0,0,.6); z-index: 90; }

/* Responsive */
@media (max-width: 1024px) {
  .stats-grid { grid-template-columns: repeat(2, 1fr); }
  .settings-grid, .detail-grid, .form-grid-2 { grid-template-columns: 1fr; }
}
@media (max-width: 768px) {
  .sidebar { transform: translateX(-100%); transition: transform .25s ease; z-index: 100; }
  .sidebar.open { transform: translateX(0); box-shadow: 8px 0 32px rgba(0,0,0,.5); }
  .sidebar-overlay.open { display: block; }
  .menu-toggle { display: flex; }
  .main { margin-left: 0; padding: 16px; }
  .stats-grid { grid-template-columns: 1fr 1fr; }
  .filter-bar { flex-wrap: wrap; }
  .search-box { margin-left: 0; width: 100%; margin-top: 8px; }
  .search-box input { width: 100%; }
}
</style>';
}

// ── Layout ──────────────────────────────────────────────────────

$content = render_page($page);

// Login/setup render their own full HTML
if (in_array($page, ['login', 'setup'])) exit;

?><!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title><?= e(brand('name')) ?> License — <?= ucfirst(e($page)) ?></title>
<?= render_css() ?>
</head>
<body>
<div class="sidebar-overlay" id="sidebarOverlay" onclick="closeNav()"></div>
<div class="layout">

    <!-- Sidebar -->
    <aside class="sidebar" id="sidebar">
        <div class="sidebar-brand">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5"><path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/></svg>
            <span><?= e(brand('name')) ?> License</span>
        </div>
        <nav class="sidebar-nav">
            <a href="admin?page=dashboard" class="nav-item <?= $page==='dashboard'?'active':'' ?>">
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="3" y="3" width="7" height="7"/><rect x="14" y="3" width="7" height="7"/><rect x="14" y="14" width="7" height="7"/><rect x="3" y="14" width="7" height="7"/></svg>
                Dashboard
            </a>
            <?php if (can_admin('manage_clients')): ?>
            <a href="admin?page=clients" class="nav-item <?= in_array($page, ['clients','client_detail'])?'active':'' ?>">
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M23 21v-2a4 4 0 0 0-3-3.87"/><path d="M16 3.13a4 4 0 0 1 0 7.75"/></svg>
                Clients
            </a>
            <?php endif; ?>
            <?php if (can_admin('manage_servers')): ?>
            <a href="admin?page=servers" class="nav-item <?= $page==='servers'?'active':'' ?>">
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="2" y="2" width="20" height="8" rx="2"/><rect x="2" y="14" width="20" height="8" rx="2"/><line x1="6" y1="6" x2="6.01" y2="6"/><line x1="6" y1="18" x2="6.01" y2="18"/></svg>
                Servers
            </a>
            <?php endif; ?>
            <?php if (can_admin('view_logs')): ?>
            <a href="admin?page=logs" class="nav-item <?= $page==='logs'?'active':'' ?>">
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/><line x1="16" y1="13" x2="8" y2="13"/><line x1="16" y1="17" x2="8" y2="17"/></svg>
                Activity Log
            </a>
            <?php endif; ?>
            <?php if (can_admin('view_dashboard')): ?>
            <a href="admin?page=settings" class="nav-item <?= $page==='settings'?'active':'' ?>">
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1 0 2.83 2 2 0 0 1-2.83 0l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-2 2 2 2 0 0 1-2-2v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83 0 2 2 0 0 1 0-2.83l.06-.06A1.65 1.65 0 0 0 4.68 15a1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1-2-2 2 2 0 0 1 2-2h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 0-2.83 2 2 0 0 1 2.83 0l.06.06A1.65 1.65 0 0 0 9 4.68a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 2-2 2 2 0 0 1 2 2v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 0 2 2 0 0 1 0 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 2 2 2 2 0 0 1-2 2h-.09a1.65 1.65 0 0 0-1.51 1z"/></svg>
                Settings
            </a>
            <?php endif; ?>
        </nav>
        <div class="sidebar-footer">
            <a href="admin?page=logout" class="nav-item">
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4"/><polyline points="16 17 21 12 16 7"/><line x1="21" y1="12" x2="9" y2="12"/></svg>
                Sign Out
            </a>
        </div>
    </aside>

    <!-- Main -->
    <main class="main">
        <button class="menu-toggle" onclick="openNav()" aria-label="Open menu">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><line x1="3" y1="6" x2="21" y2="6"/><line x1="3" y1="12" x2="21" y2="12"/><line x1="3" y1="18" x2="21" y2="18"/></svg>
        </button>
        <?php if ($message): ?>
            <div class="alert alert-<?= $msg_type ?>"><?= e($message) ?></div>
        <?php endif; ?>
        <?= $content ?>
    </main>

</div>
<script>
function openNav()  { document.getElementById('sidebar').classList.add('open'); document.getElementById('sidebarOverlay').classList.add('open'); }
function closeNav() { document.getElementById('sidebar').classList.remove('open'); document.getElementById('sidebarOverlay').classList.remove('open'); }
</script>
</body>
</html>
