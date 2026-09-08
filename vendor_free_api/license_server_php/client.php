<?php
// ---------------------------------------------------------------
// IPTunnel License — Client Portal
//
// Clients log in here to:
//   - View their API token
//   - See their registered servers
//   - Change their password
// Admin creates client accounts via admin
// ---------------------------------------------------------------
require_once __DIR__ . '/db.php';

// ── Session setup ───────────────────────────────────────────────
session_name('iptunnel_client');
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

// ── Auth helpers ────────────────────────────────────────────────

function is_client_authed(): bool {
    if (empty($_SESSION['client_id'])) return false;
    if (isset($_SESSION['last_activity']) && (time() - $_SESSION['last_activity']) > SESSION_LIFETIME) {
        session_destroy();
        return false;
    }
    $_SESSION['last_activity'] = time();
    return true;
}

function require_client_auth(): void {
    if (!is_client_authed()) {
        header('Location: client?page=login');
        exit;
    }
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

// ── Route ───────────────────────────────────────────────────────
$page    = $_GET['page'] ?? '';
$message = '';
$msg_type = 'success';

if (!is_setup_complete()) {
    header('Location: admin?page=setup');
    exit;
}

// ── POST Actions ────────────────────────────────────────────────
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    if ($page === 'login') {
        handle_client_login();
    } else {
        require_client_auth();
        if (!verify_csrf()) {
            $message = 'Invalid security token. Please try again.';
            $msg_type = 'error';
        } else {
            handle_client_post();
        }
    }
}

if (!in_array($page, ['login', 'logout', ''])) {
    require_client_auth();
}
if ($page === '' && is_client_authed()) {
    $page = 'dashboard';
} elseif ($page === '' && !is_client_authed()) {
    $page = 'login';
}

if ($page === 'logout') {
    audit_log('client_logout', $_SESSION['client_user'] ?? '', '');
    session_destroy();
    header('Location: client?page=login');
    exit;
}

// ── POST Handlers ───────────────────────────────────────────────

function handle_client_login(): void {
    global $message, $msg_type;

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

    $client = get_client($username);
    if ($client && $client['is_active'] && password_verify($password, $client['password'])) {
        record_login_attempt(true);
        record_login_history('client', (int) $client['id'], $username, true);
        session_regenerate_id(true);
        $_SESSION['client_id']   = $client['id'];
        $_SESSION['client_user'] = $client['username'];
        $_SESSION['client_name'] = $client['name'];
        $_SESSION['last_activity'] = time();
        update_client_login($client['id']);
        audit_log('client_login', $username, 'Client login', $username);
        header('Location: client?page=dashboard');
        exit;
    }

    if ($client && !$client['is_active']) {
        $message = 'Your account has been suspended. Contact the administrator.';
    } else {
        $message = 'Invalid username or password.';
    }

    record_login_attempt(false);
    record_login_history('client', (int) ($client['id'] ?? 0), $username, false);
    audit_log('client_login_failed', $username, 'Failed client login', 'anonymous');
    $msg_type = 'error';
}

function handle_client_post(): void {
    global $message, $msg_type;
    $action = $_POST['action'] ?? '';

    switch ($action) {
        case 'change_password':
            $current = $_POST['current_password'] ?? '';
            $new     = $_POST['new_password'] ?? '';
            $confirm = $_POST['confirm_password'] ?? '';

            $client = get_client($_SESSION['client_user']);
            if (!$client || !password_verify($current, $client['password'])) {
                $message = 'Current password is incorrect.';
                $msg_type = 'error';
                break;
            }
            if (strlen($new) < 6) {
                $message = 'New password must be at least 6 characters.';
                $msg_type = 'error';
                break;
            }
            if ($new !== $confirm) {
                $message = 'New passwords do not match.';
                $msg_type = 'error';
                break;
            }
            update_client_password($client['id'], $new);
            audit_log('client_change_password', '', '', $_SESSION['client_user']);
            $message = 'Password updated.';
            break;
    }
}

// ── Get current client data ─────────────────────────────────────

function current_client(): ?array {
    if (empty($_SESSION['client_id'])) return null;
    return get_client_by_id($_SESSION['client_id']);
}

// ── LOGIN PAGE ──────────────────────────────────────────────────

if ($page === 'login') {
    ?><!DOCTYPE html>
<html lang="en"><head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title><?= e(brand('name')) ?> — Client Portal</title>
<?= client_css() ?>
</head><body class="auth-page">
<div class="auth-container">
    <div class="auth-card">
        <div class="auth-logo">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" style="width:40px;height:40px;color:#b794f4"><path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/></svg>
        </div>
        <h2><?= e(brand('name')) ?> Client Portal</h2>
        <p class="subtext">Sign in to manage your servers</p>
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
            Account created by your administrator
        </p>
    </div>
</div>
</body></html><?php exit;
}

// ── MAIN LAYOUT ─────────────────────────────────────────────────

$client = current_client();
if (!$client) { header('Location: client?page=login'); exit; }

$stats = server_stats($client['id']);

?><!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title><?= e(brand('name')) ?> — <?= e($client['name']) ?></title>
<?= client_css() ?>
</head>
<body>
<div class="sidebar-overlay" id="sidebarOverlay" onclick="closeNav()"></div>
<div class="layout">

    <!-- Sidebar -->
    <aside class="sidebar" id="sidebar">
        <div class="sidebar-brand">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5"><path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/></svg>
            <span><?= e(brand('name')) ?></span>
        </div>
        <div class="sidebar-user">
            <div class="user-name"><?= e($client['name']) ?></div>
            <div class="user-role">@<?= e($client['username']) ?></div>
        </div>
        <nav class="sidebar-nav">
            <a href="client?page=dashboard" class="nav-item <?= $page==='dashboard'?'active':'' ?>">
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="3" y="3" width="7" height="7"/><rect x="14" y="3" width="7" height="7"/><rect x="14" y="14" width="7" height="7"/><rect x="3" y="14" width="7" height="7"/></svg>
                Dashboard
            </a>
            <a href="client?page=servers" class="nav-item <?= $page==='servers'?'active':'' ?>">
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="2" y="2" width="20" height="8" rx="2"/><rect x="2" y="14" width="20" height="8" rx="2"/><line x1="6" y1="6" x2="6.01" y2="6"/><line x1="6" y1="18" x2="6.01" y2="18"/></svg>
                My Servers
            </a>
            <a href="client?page=token" class="nav-item <?= $page==='token'?'active':'' ?>">
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="3" y="11" width="18" height="11" rx="2" ry="2"/><path d="M7 11V7a5 5 0 0 1 10 0v4"/></svg>
                API Token
            </a>
            <a href="client?page=account" class="nav-item <?= $page==='account'?'active':'' ?>">
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2"/><circle cx="12" cy="7" r="4"/></svg>
                Account
            </a>
        </nav>
        <div class="sidebar-footer">
            <a href="client?page=logout" class="nav-item">
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

        <?php
        match ($page) {
            'dashboard' => client_dashboard($client, $stats),
            'servers'   => client_servers($client),
            'token'     => client_token($client),
            'account'   => client_account($client),
            default     => client_dashboard($client, $stats),
        };
        ?>
    </main>

</div>
<script>
function openNav()  { document.getElementById('sidebar').classList.add('open'); document.getElementById('sidebarOverlay').classList.add('open'); }
function closeNav() { document.getElementById('sidebar').classList.remove('open'); document.getElementById('sidebarOverlay').classList.remove('open'); }
</script>
</body>
</html>
<?php

// ── Client Pages ────────────────────────────────────────────────

function client_dashboard(array $client, array $stats): void {
    ?>
    <div class="page-header">
        <h2>Dashboard</h2>
        <p class="subtext">Welcome back, <?= e($client['name']) ?></p>
    </div>

    <div class="stats-grid">
        <div class="stat-card">
            <div class="stat-icon blue"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="2" y="3" width="20" height="14" rx="2"/><line x1="8" y1="21" x2="16" y2="21"/><line x1="12" y1="17" x2="12" y2="21"/></svg></div>
            <div class="stat-num"><?= $stats['total'] ?></div>
            <div class="stat-label">Total Servers</div>
        </div>
        <div class="stat-card">
            <div class="stat-icon green"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M22 11.08V12a10 10 0 1 1-5.93-9.14"/><polyline points="22 4 12 14.01 9 11.01"/></svg></div>
            <div class="stat-num"><?= $stats['active'] ?></div>
            <div class="stat-label">Active</div>
        </div>
        <div class="stat-card">
            <div class="stat-icon yellow"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="10"/><polyline points="12 6 12 12 16 14"/></svg></div>
            <div class="stat-num"><?= $stats['checkedin'] ?></div>
            <div class="stat-label">Healthy (48h)</div>
        </div>
        <div class="stat-card">
            <div class="stat-icon red"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="10"/><line x1="15" y1="9" x2="9" y2="15"/><line x1="9" y1="9" x2="15" y2="15"/></svg></div>
            <div class="stat-num"><?= $stats['revoked'] ?></div>
            <div class="stat-label">Revoked</div>
        </div>
    </div>

    <?php if ($client['max_servers'] > 0): ?>
    <div class="card">
        <div class="card-body">
            <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:8px">
                <span class="muted">Server usage</span>
                <span><strong><?= $stats['active'] ?></strong> / <?= $client['max_servers'] ?></span>
            </div>
            <div class="progress-bar">
                <div class="progress-fill" style="width:<?= min(100, ($stats['active'] / max(1, $client['max_servers'])) * 100) ?>%"></div>
            </div>
        </div>
    </div>
    <?php endif; ?>

    <!-- Quick Token -->
    <div class="card">
        <div class="card-header"><h3>Your API Token</h3></div>
        <div class="card-body">
            <p class="muted" style="margin-bottom:8px;font-size:12px">Use this token when installing VPN servers.</p>
            <div class="token-display">
                <code class="token-value" id="qt"><?= e($client['token']) ?></code>
                <button class="btn btn-sm btn-ghost" onclick="navigator.clipboard.writeText(document.getElementById('qt').textContent)">Copy</button>
            </div>
            <pre class="code-block" style="margin-top:12px">bash &lt;(curl -4 -sk https://license.internetshub.com/iptunnel-install.sh) --license-token <?= e($client['token']) ?></pre>
        </div>
    </div>
    <?php
}

function client_servers(array $client): void {
    $filter = $_GET['filter'] ?? 'all';
    $servers = get_servers($filter, '', 1, 100, $client['id']);
    $stats = server_stats($client['id']);
    ?>
    <div class="page-header">
        <h2>My Servers</h2>
        <p class="subtext"><?= $stats['total'] ?> registered</p>
    </div>

    <div class="filter-bar">
        <a href="client?page=servers" class="filter-tab <?= $filter==='all'?'active':'' ?>">All <span class="count"><?= $stats['total'] ?></span></a>
        <a href="client?page=servers&filter=active" class="filter-tab <?= $filter==='active'?'active':'' ?>">Active <span class="count"><?= $stats['active'] ?></span></a>
        <a href="client?page=servers&filter=revoked" class="filter-tab <?= $filter==='revoked'?'active':'' ?>">Revoked <span class="count"><?= $stats['revoked'] ?></span></a>
    </div>

    <div class="card">
        <table>
            <thead>
                <tr>
                    <th>Status</th>
                    <th>IP Address</th>
                    <th>Hostname</th>
                    <th>Server ID</th>
                    <th>Registered</th>
                    <th>Last Check-in</th>
                </tr>
            </thead>
            <tbody>
            <?php if (empty($servers)): ?>
                <tr><td colspan="6" class="empty">No servers registered yet. Install the VPN server with your token to get started.</td></tr>
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
                    <td><code class="sid" onclick="navigator.clipboard.writeText('<?= e($s['server_id']) ?>')" title="Click to copy"><?= e($s['server_id']) ?></code></td>
                    <td class="muted" title="<?= e($s['registered_at']) ?>"><?= time_ago($s['registered_at']) ?></td>
                    <td class="<?= $stale ? 'text-yellow' : 'muted' ?>">
                        <?= $ci ? time_ago($ci) : '<span class="text-muted">Never</span>' ?>
                    </td>
                </tr>
            <?php endforeach; endif; ?>
            </tbody>
        </table>
    </div>
    <?php
}

function client_token(array $client): void {
    ?>
    <div class="page-header">
        <h2>API Token</h2>
        <p class="subtext">Your unique license token</p>
    </div>

    <div class="card">
        <div class="card-body">
            <p class="muted" style="margin-bottom:12px">This token identifies you when registering VPN servers. Keep it private.</p>
            <div class="token-display" style="margin-bottom:16px">
                <code class="token-value" id="full-token"><?= e($client['token']) ?></code>
                <button class="btn btn-sm btn-ghost" onclick="navigator.clipboard.writeText(document.getElementById('full-token').textContent)">Copy</button>
            </div>

            <h4 style="margin:24px 0 8px;font-size:14px;color:var(--text-secondary)">Usage</h4>
            <pre class="code-block">bash &lt;(curl -4 -sk https://license.internetshub.com/iptunnel-install.sh) --license-token <?= e($client['token']) ?></pre>

            <?php if ($client['max_servers'] > 0): ?>
            <div class="info-grid" style="margin-top:20px">
                <div class="info-row"><span class="muted">Server Limit</span><span><?= $client['max_servers'] ?></span></div>
                <div class="info-row"><span class="muted">Active Servers</span><span><?= client_server_count($client['id']) ?></span></div>
            </div>
            <?php else: ?>
            <div class="info-grid" style="margin-top:20px">
                <div class="info-row"><span class="muted">Server Limit</span><span>Unlimited</span></div>
            </div>
            <?php endif; ?>

            <p class="muted" style="margin-top:20px;font-size:11px">Need a new token? Contact your administrator.</p>
        </div>
    </div>
    <?php
}

function client_account(array $client): void {
    $subscription = get_subscription((int) $client['id']);
    $login_history = get_login_history('client', (int) $client['id'], 10);
    ?>
    <div class="page-header">
        <h2>Account</h2>
        <p class="subtext">Manage your credentials</p>
    </div>

    <div class="settings-grid">
        <div class="card">
            <div class="card-header"><h3>Account Info</h3></div>
            <div class="card-body">
                <div class="info-grid">
                    <div class="info-row"><span class="muted">Name</span><span><?= e($client['name']) ?></span></div>
                    <div class="info-row"><span class="muted">Username</span><span class="mono">@<?= e($client['username']) ?></span></div>
                    <div class="info-row"><span class="muted">Email</span><span><?= e($client['email'] ?: "\xe2\x80\x94") ?></span></div>
                    <div class="info-row"><span class="muted">Status</span><span class="text-green">Active</span></div>
                    <div class="info-row"><span class="muted">Member Since</span><span><?= e(substr($client['created_at'], 0, 10)) ?></span></div>
                    <?php if ($subscription): ?>
                    <div class="info-row"><span class="muted">Plan</span><span><?= e($subscription['plan']) ?></span></div>
                    <div class="info-row"><span class="muted">Subscription</span><span><?= e($subscription['status']) ?></span></div>
                    <div class="info-row"><span class="muted">Expiry</span><span><?= e($subscription['expires_at'] ?: 'Never') ?></span></div>
                    <?php endif; ?>
                    <?php if (brand('support_email')): ?>
                    <div class="info-row"><span class="muted">Support Email</span><span><?= e(brand('support_email')) ?></span></div>
                    <?php endif; ?>
                </div>
            </div>
        </div>

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
                        <input type="password" name="new_password" required minlength="6">
                    </div>
                    <div class="field">
                        <label>Confirm New Password</label>
                        <input type="password" name="confirm_password" required minlength="6">
                    </div>
                    <button type="submit" class="btn btn-primary">Update Password</button>
                </div>
            </form>
        </div>
    </div>

    <div class="card">
        <div class="card-header"><h3>Login History</h3></div>
        <table>
            <thead><tr><th>Time</th><th>IP</th><th>Result</th></tr></thead>
            <tbody>
            <?php if (empty($login_history)): ?>
                <tr><td colspan="3" class="empty">No login history recorded yet.</td></tr>
            <?php else: foreach ($login_history as $entry): ?>
                <tr>
                    <td class="muted"><?= e(substr($entry['created_at'], 0, 16)) ?></td>
                    <td class="mono"><?= e($entry['ip_address']) ?></td>
                    <td><span class="badge badge-<?= $entry['success'] ? 'green' : 'red' ?>"><?= $entry['success'] ? 'Success' : 'Failed' ?></span></td>
                </tr>
            <?php endforeach; endif; ?>
            </tbody>
        </table>
    </div>
    <?php
}

// ── CSS ─────────────────────────────────────────────────────────

function client_css(): string {
    $brandColor = e(brand('color') ?: '#b794f4');
    return '<style>
:root {
  --bg: #0f1117;  --surface: #1a1d2e;  --surface-hover: #1e2433;
  --border: #2d3748;  --border-light: #374151;
  --text: #e2e8f0;  --text-secondary: #a0aec0;  --muted: #718096;
  --blue: #63b3ed;  --green: #68d391;  --red: #fc8181;  --yellow: #f6e05e;
  --purple: ' . $brandColor . ';
  --blue-bg: #1a2e4a;  --green-bg: #1c4532;  --red-bg: #4a1c1c;
  --yellow-bg: #3d3519;  --purple-bg: #2d1f54;
  --sidebar-w: 240px;
}
*, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
body { font-family: system-ui, -apple-system, "Segoe UI", sans-serif; background: var(--bg); color: var(--text); min-height: 100vh; font-size: 14px; }

.auth-page { display: flex; align-items: center; justify-content: center; min-height: 100vh; }
.auth-container { width: 100%; max-width: 380px; padding: 20px; }
.auth-card { background: var(--surface); border: 1px solid var(--border); border-radius: 16px; padding: 40px 36px; text-align: center; }
.auth-logo { margin-bottom: 16px; }
.auth-card h2 { font-size: 22px; margin-bottom: 4px; }
.auth-card .subtext { color: var(--muted); font-size: 13px; margin-bottom: 24px; }
.auth-card form { text-align: left; }

.layout { display: flex; min-height: 100vh; }
.sidebar { width: var(--sidebar-w); background: var(--surface); border-right: 1px solid var(--border); display: flex; flex-direction: column; position: fixed; top: 0; left: 0; bottom: 0; z-index: 100; }
.sidebar-brand { padding: 20px 20px 12px; border-bottom: 1px solid var(--border); display: flex; align-items: center; gap: 10px; }
.sidebar-brand svg { width: 28px; height: 28px; color: var(--purple); flex-shrink: 0; }
.sidebar-brand span { font-weight: 700; font-size: 15px; letter-spacing: .3px; }
.sidebar-user { padding: 14px 20px; border-bottom: 1px solid var(--border); }
.user-name { font-weight: 600; font-size: 14px; }
.user-role { font-size: 12px; color: var(--muted); }
.sidebar-nav { flex: 1; padding: 12px 10px; }
.nav-item { display: flex; align-items: center; gap: 10px; padding: 10px 14px; border-radius: 8px; color: var(--text-secondary); text-decoration: none; font-size: 13px; font-weight: 500; margin-bottom: 2px; transition: all .15s; }
.nav-item:hover { background: var(--surface-hover); color: var(--text); }
.nav-item.active { background: var(--purple-bg); color: var(--purple); }
.nav-item svg { width: 18px; height: 18px; flex-shrink: 0; }
.sidebar-footer { padding: 12px 10px; border-top: 1px solid var(--border); }
.sidebar-footer .nav-item { color: var(--muted); }
.sidebar-footer .nav-item:hover { color: var(--red); background: var(--red-bg); }
.main { margin-left: var(--sidebar-w); flex: 1; padding: 28px 32px; max-width: 1000px; }

.page-header { display: flex; align-items: center; justify-content: space-between; margin-bottom: 24px; }
.page-header h2 { font-size: 22px; font-weight: 700; }
.subtext { color: var(--muted); font-size: 13px; }

.stats-grid { display: grid; grid-template-columns: repeat(4, 1fr); gap: 16px; margin-bottom: 24px; }
.stat-card { background: var(--surface); border: 1px solid var(--border); border-radius: 12px; padding: 20px; }
.stat-icon { width: 40px; height: 40px; border-radius: 10px; display: flex; align-items: center; justify-content: center; margin-bottom: 12px; }
.stat-icon svg { width: 20px; height: 20px; }
.stat-icon.blue   { background: var(--blue-bg);   color: var(--blue); }
.stat-icon.green  { background: var(--green-bg);  color: var(--green); }
.stat-icon.red    { background: var(--red-bg);    color: var(--red); }
.stat-icon.yellow { background: var(--yellow-bg); color: var(--yellow); }
.stat-num { font-size: 32px; font-weight: 700; line-height: 1; }
.stat-label { font-size: 12px; color: var(--muted); margin-top: 4px; text-transform: uppercase; letter-spacing: .5px; }

.card { background: var(--surface); border: 1px solid var(--border); border-radius: 12px; margin-bottom: 20px; overflow: hidden; }
.card-header { padding: 14px 20px; border-bottom: 1px solid var(--border); display: flex; align-items: center; justify-content: space-between; }
.card-header h3 { font-size: 14px; font-weight: 600; color: var(--text-secondary); text-transform: uppercase; letter-spacing: .5px; }
.card-body { padding: 20px; }

table { width: 100%; border-collapse: collapse; }
th { padding: 10px 16px; text-align: left; font-size: 11px; color: var(--muted); text-transform: uppercase; letter-spacing: .5px; border-bottom: 1px solid var(--border); font-weight: 600; }
td { padding: 12px 16px; border-bottom: 1px solid #1e2433; vertical-align: middle; }
tr:last-child td { border-bottom: none; }
tr:hover td { background: var(--surface-hover); }
.empty { text-align: center; color: var(--muted); padding: 32px 16px !important; }

.badge { display: inline-block; padding: 3px 10px; border-radius: 999px; font-size: 11px; font-weight: 600; white-space: nowrap; }
.badge-green  { background: var(--green-bg);  color: var(--green); }
.badge-red    { background: var(--red-bg);    color: var(--red); }
.badge-yellow { background: var(--yellow-bg); color: var(--yellow); }

.btn { display: inline-flex; align-items: center; padding: 8px 16px; border-radius: 8px; font-size: 13px; font-weight: 600; border: none; cursor: pointer; text-decoration: none; transition: all .15s; color: var(--text); }
.btn:hover { opacity: .85; }
.btn-primary { background: #553c9a; color: #fff; }
.btn-ghost { background: transparent; color: var(--text-secondary); border: 1px solid var(--border); }
.btn-ghost:hover { background: var(--surface-hover); }
.btn-sm { padding: 4px 10px; font-size: 12px; border-radius: 6px; }
.btn-full { width: 100%; justify-content: center; padding: 10px; font-size: 14px; }

.field { margin-bottom: 14px; }
.field label { display: block; font-size: 12px; color: var(--muted); margin-bottom: 5px; font-weight: 500; }
.field input { width: 100%; background: var(--bg); border: 1px solid var(--border); color: var(--text); border-radius: 8px; padding: 9px 13px; font-size: 14px; outline: none; transition: border-color .15s; }
.field input:focus { border-color: var(--purple); }
.field-stack .field { margin-bottom: 16px; }

.filter-bar { display: flex; align-items: center; gap: 4px; margin-bottom: 16px; }
.filter-tab { padding: 6px 14px; border-radius: 8px; font-size: 13px; color: var(--muted); text-decoration: none; font-weight: 500; transition: all .15s; }
.filter-tab:hover { background: var(--surface-hover); color: var(--text); }
.filter-tab.active { background: var(--purple-bg); color: var(--purple); }
.filter-tab .count { font-size: 11px; opacity: .7; }

.token-display { display: flex; align-items: center; gap: 8px; background: var(--bg); border: 1px solid var(--border); border-radius: 8px; padding: 10px 14px; }
.token-value { font-size: 13px; color: var(--green); word-break: break-all; flex: 1; font-family: "SF Mono", "Cascadia Code", Consolas, monospace; }

.progress-bar { height: 8px; background: var(--bg); border-radius: 4px; overflow: hidden; }
.progress-fill { height: 100%; background: var(--purple); border-radius: 4px; transition: width .3s; }

.settings-grid { display: grid; grid-template-columns: repeat(2, 1fr); gap: 20px; }
.info-grid { display: flex; flex-direction: column; gap: 10px; }
.info-row { display: flex; justify-content: space-between; padding: 4px 0; border-bottom: 1px solid var(--border); font-size: 13px; }
.info-row:last-child { border-bottom: none; }

.alert { padding: 12px 16px; border-radius: 8px; font-size: 13px; margin-bottom: 16px; }
.alert-success { background: var(--green-bg); border: 1px solid #276749; color: var(--green); }
.alert-error   { background: var(--red-bg);   border: 1px solid #9b2c2c; color: var(--red); }

.mono { font-family: "SF Mono", "Cascadia Code", Consolas, monospace; font-size: 12px; }
.muted { color: var(--muted); }
.text-green { color: var(--green); }
.text-yellow { color: var(--yellow); }
.text-muted { color: var(--muted); }
code { font-family: "SF Mono", "Cascadia Code", Consolas, monospace; }
.sid { font-size: 11px; color: var(--text-secondary); cursor: pointer; padding: 2px 6px; border-radius: 4px; background: var(--bg); }
.sid:hover { background: var(--purple-bg); color: var(--purple); }
.code-block { background: var(--bg); border: 1px solid var(--border); border-radius: 8px; padding: 12px 16px; font-family: monospace; font-size: 12px; color: var(--text-secondary); overflow-x: auto; white-space: pre; }

/* Mobile hamburger */
.menu-toggle { display: none; align-items: center; justify-content: center; width: 38px; height: 38px; background: var(--surface); border: 1px solid var(--border); border-radius: 8px; cursor: pointer; color: var(--text-secondary); margin-bottom: 16px; flex-shrink: 0; }
.menu-toggle:hover { color: var(--text); border-color: var(--purple); }
.menu-toggle svg { width: 20px; height: 20px; }
.sidebar-overlay { display: none; position: fixed; inset: 0; background: rgba(0,0,0,.6); z-index: 90; }

@media (max-width: 1024px) {
  .stats-grid { grid-template-columns: repeat(2, 1fr); }
  .settings-grid { grid-template-columns: 1fr; }
}
@media (max-width: 768px) {
  .sidebar { transform: translateX(-100%); transition: transform .25s ease; z-index: 100; }
  .sidebar.open { transform: translateX(0); box-shadow: 8px 0 32px rgba(0,0,0,.5); }
  .sidebar-overlay.open { display: block; }
  .menu-toggle { display: flex; }
  .main { margin-left: 0; padding: 16px; }
  .stats-grid { grid-template-columns: 1fr 1fr; }
  .filter-bar { flex-wrap: wrap; }
  table { font-size: 12px; }
  th, td { padding: 8px 10px; }
}
</style>';
}
