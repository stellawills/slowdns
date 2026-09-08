<?php
// ---------------------------------------------------------------
// IPTunnel License Server — Public API (v2 — Multi-Client)
//
// Endpoints:
//   GET  /           — Landing page (HTML)
//   GET  /healthz    — liveness probe
//   POST /register   — VPN server self-registers (client token)
//   POST /checkin    — daily heartbeat
//   POST /revoke     — revoke a server (master token)
//   GET  /status     — list servers (master or client token)
// ---------------------------------------------------------------
require_once __DIR__ . '/db.php';
require_once __DIR__ . '/api_v2.php';
require_once __DIR__ . '/slowdns_activation.php';
require_once __DIR__ . '/docs.php';

$uri    = strtok($_SERVER['REQUEST_URI'], '?');
$base   = rtrim(dirname($_SERVER['SCRIPT_NAME']), '/');
$path   = $base !== '' ? substr($uri, strlen($base)) : $uri;
$path   = '/' . trim($path ?: '', '/');
$method = $_SERVER['REQUEST_METHOD'];


if ($path === '/' && $method === 'GET') {
    ?><!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title><?= htmlspecialchars(brand('name'), ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?> License Server</title>
<style>
:root {
  --bg:#0f1117; --surface:#1a1d2e; --surface-hover:#1e2433;
  --border:#2a2f45; --text:#e2e8f0; --text-secondary:#94a3b8;
  --muted:#64748b; --blue:#63b3ed; --green:#68d391; --red:#fc8181;
  --blue-bg:#1a2e4a; --green-bg:#1c4532;
}
*,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
body{background:var(--bg);color:var(--text);font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;min-height:100vh;display:flex;flex-direction:column;align-items:center;padding:64px 20px 48px}
.logo{display:flex;align-items:center;gap:14px;margin-bottom:10px}
.logo svg{width:52px;height:52px;color:var(--blue)}
.logo-wordmark{font-size:30px;font-weight:700;letter-spacing:-.5px}
.logo-wordmark span{color:var(--blue)}
.tagline{color:var(--text-secondary);font-size:14px;margin-bottom:48px;text-align:center}
.cards{display:grid;grid-template-columns:1fr 1fr;gap:16px;width:100%;max-width:640px;margin-bottom:32px}
.card{background:var(--surface);border:1px solid var(--border);border-radius:14px;padding:24px;text-decoration:none;color:inherit;transition:all .2s;display:flex;flex-direction:column;gap:8px}
.card:hover{transform:translateY(-2px)}
.card.blue:hover{border-color:var(--blue)}
.card.green:hover{border-color:var(--green)}
.card-icon{width:42px;height:42px;border-radius:10px;display:flex;align-items:center;justify-content:center;margin-bottom:4px}
.card-icon.blue{background:var(--blue-bg);color:var(--blue)}
.card-icon.green{background:var(--green-bg);color:var(--green)}
.card-icon svg{width:20px;height:20px}
.card-title{font-size:15px;font-weight:600}
.card-desc{font-size:12px;color:var(--text-secondary);line-height:1.55}
.card-link{margin-top:auto;padding-top:10px;font-size:12px;color:var(--muted)}
.install{width:100%;max-width:640px;background:var(--surface);border:1px solid var(--border);border-radius:14px;padding:24px;margin-bottom:24px}
.section-label{font-size:11px;font-weight:600;text-transform:uppercase;letter-spacing:1px;color:var(--muted);margin-bottom:14px}
.cmd-row{background:var(--bg);border:1px solid var(--border);border-radius:8px;padding:11px 14px;display:flex;align-items:center;gap:10px;margin-bottom:8px}
.cmd-row code{font-family:'SF Mono',Consolas,monospace;font-size:12px;color:var(--text-secondary);flex:1;overflow-x:auto;white-space:nowrap}
.cmd-row code .kw{color:var(--blue)}
.cmd-row code .arg{color:var(--green)}
.copy-btn{background:none;border:1px solid var(--border);border-radius:6px;color:var(--muted);cursor:pointer;padding:5px 10px;font-size:11px;white-space:nowrap;transition:all .15s;flex-shrink:0}
.copy-btn:hover{border-color:var(--blue);color:var(--blue)}
.copy-btn.ok{border-color:var(--green);color:var(--green)}
.cmd-note{font-size:11px;color:var(--muted);line-height:1.5;margin-top:4px}
.status-row{display:flex;align-items:center;gap:8px;font-size:12px;color:var(--muted);margin-bottom:32px}
.dot{width:8px;height:8px;border-radius:50%;background:var(--muted);transition:background .3s;flex-shrink:0}
.dot.ok{background:var(--green);box-shadow:0 0 6px var(--green)}
.dot.err{background:var(--red)}
footer{font-size:11px;color:var(--muted)}
@media(max-width:520px){
  .cards{grid-template-columns:1fr}
  body{padding:40px 16px 32px}
  .logo-wordmark{font-size:24px}
  .cmd-row code{font-size:11px}
}
</style>
</head>
<body>

<div class="logo">
  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5"><path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/></svg>
  <div class="logo-wordmark"><?= htmlspecialchars(brand('name'), ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></div>
</div>
<p class="tagline">Secure VPN server licensing &amp; client management</p>

<div class="cards">
  <a href="docs" class="card blue">
    <div class="card-icon blue">
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/><line x1="8" y1="13" x2="16" y2="13"/><line x1="8" y1="17" x2="13" y2="17"/></svg>
    </div>
    <div class="card-title">Documentation</div>
    <div class="card-desc">Installation guides, authorization flows, and troubleshooting steps in one place.</div>
    <div class="card-link">Open docs &rarr;</div>
  </a>
  <a href="admin.php" class="card blue">
    <div class="card-icon blue">
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2"/><circle cx="12" cy="7" r="4"/></svg>
    </div>
    <div class="card-title">Admin Panel</div>
    <div class="card-desc">Manage clients, servers, activity logs and system settings.</div>
    <div class="card-link">Open panel &rarr;</div>
  </a>
  <a href="client.php" class="card green">
    <div class="card-icon green">
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="2" y="2" width="20" height="8" rx="2"/><rect x="2" y="14" width="20" height="8" rx="2"/><line x1="6" y1="6" x2="6.01" y2="6"/><line x1="6" y1="18" x2="6.01" y2="18"/></svg>
    </div>
    <div class="card-title">Client Portal</div>
    <div class="card-desc">View your registered servers, check status and manage your account.</div>
    <div class="card-link">Sign in &rarr;</div>
  </a>
  <a href="slowdns" class="card green">
    <div class="card-icon green">
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M4 11a8 8 0 0 1 16 0"/><path d="M7 11a5 5 0 0 1 10 0"/><path d="M10 11a2 2 0 0 1 4 0"/><line x1="12" y1="13" x2="12" y2="20"/><circle cx="12" cy="21" r="1"/></svg>
    </div>
    <div class="card-title">SlowDNS Install Code</div>
    <div class="card-desc">Generate a one-time IPT-SD code for the public GitHub SlowDNS installer.</div>
    <div class="card-link">Open SlowDNS page &rarr;</div>
  </a>
</div>

<div class="install">
  <div class="section-label">Quick Install</div>
  <div class="cmd-row">
    <code><span class="kw">bash</span> &lt;(curl -4 -sk https://license.internetshub.com/iptunnel-install.sh)</code>
    <button class="copy-btn" onclick="cp(this,'bash <(curl -4 -sk https://license.internetshub.com/iptunnel-install.sh)')">Copy</button>
  </div>
  <div class="cmd-row">
    <code><span class="kw">bash</span> &lt;(curl -4 -sk https://license.internetshub.com/iptunnel-install.sh) --license-token <span class="arg">YOUR_TOKEN</span></code>
    <button class="copy-btn" onclick="cp(this,'bash <(curl -4 -sk https://license.internetshub.com/iptunnel-install.sh) --license-token YOUR_TOKEN')">Copy</button>
  </div>
  <p class="cmd-note">Run as root on your Ubuntu VPS. Replace <code style="color:var(--green)">YOUR_TOKEN</code> with the token from the Client Portal or Admin Panel. Need the zero-touch flow? Open the documentation page first.</p>
</div>

<div class="status-row">
  <div class="dot" id="sdot"></div>
  <span id="slabel">Checking API status...</span>
</div>

<footer><?= htmlspecialchars(brand('name'), ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?> License Server &middot; <?= htmlspecialchars($_SERVER['HTTP_HOST'] ?? 'localhost', ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></footer>

<script>
function cp(btn, text) {
  navigator.clipboard.writeText(text).then(() => {
    var orig = btn.textContent;
    btn.textContent = 'Copied!';
    btn.classList.add('ok');
    setTimeout(function(){ btn.textContent = orig; btn.classList.remove('ok'); }, 2000);
  });
}
fetch('healthz').then(function(r){ return r.json(); }).then(function(){
  document.getElementById('sdot').className = 'dot ok';
  document.getElementById('slabel').textContent = 'API operational';
}).catch(function(){
  document.getElementById('sdot').className = 'dot err';
  document.getElementById('slabel').textContent = 'API unavailable';
});
</script>
</body>
</html>
<?php
    exit;
}

if (($path === '/docs' || strpos($path, '/docs/') === 0) && $method === 'GET') {
    render_docs_page($path);
}

if ($path === '/slowdns' && $method === 'GET') {
    slowdns_set_browser_cookie();
    ?><!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title><?= htmlspecialchars(brand('name'), ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?> SlowDNS Install Code</title>
<style>
:root{--bg:#0f1117;--surface:#1a1d2e;--surface-hover:#1e2433;--border:#2a2f45;--text:#e2e8f0;--text-secondary:#94a3b8;--muted:#64748b;--blue:#63b3ed;--blue-bg:#1a2e4a;--green:#68d391;--green-bg:#1c4532;--red:#fc8181}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;padding:64px 20px 48px}
.wrap{max-width:800px;margin:0 auto}.top{display:flex;justify-content:space-between;align-items:center;gap:12px;margin-bottom:24px}.card{background:var(--surface);border:1px solid var(--border);border-radius:14px;padding:24px}
h1{margin:0 0 8px;font-size:28px}p{color:var(--text-secondary);line-height:1.6}.actions{display:flex;gap:10px;flex-wrap:wrap;margin-top:20px}
button,.btn{appearance:none;border:none;border-radius:10px;padding:12px 16px;font-weight:600;cursor:pointer;text-decoration:none}
button{background:var(--blue);color:#08111d}.btn{background:transparent;border:1px solid var(--border);color:var(--text)}
.code-box{margin-top:22px;padding:16px;border-radius:12px;border:1px dashed var(--border);background:#111521;cursor:pointer}
.code{font-family:Consolas,monospace;font-size:22px;letter-spacing:1px;word-break:break-all}
.meta{margin-top:8px;font-size:13px;color:var(--muted)}.ok{color:var(--green)}.err{color:var(--red)}
.install{width:100%;margin-top:26px;background:var(--surface);border:1px solid var(--border);border-radius:14px;padding:24px}
.section-label{font-size:11px;font-weight:600;text-transform:uppercase;letter-spacing:1px;color:var(--muted);margin-bottom:14px}
.cmd-row{background:var(--bg);border:1px solid var(--border);border-radius:8px;padding:11px 14px;display:flex;align-items:center;gap:10px;margin-bottom:14px}
.cmd-row code{font-family:'SF Mono',Consolas,monospace;font-size:12px;color:var(--text-secondary);flex:1;white-space:pre-wrap;overflow-wrap:anywhere}
.copy-btn{background:none;border:1px solid var(--border);border-radius:6px;color:var(--muted);cursor:pointer;padding:5px 10px;font-size:11px;white-space:nowrap;transition:all .15s;flex-shrink:0}
.copy-btn:hover{border-color:var(--blue);color:var(--blue)}
.copy-btn.ok{border-color:var(--green);color:var(--green)}
.cmd-note{font-size:11px;color:var(--muted);line-height:1.7;margin-top:2px}
@media(max-width:700px){.wrap{max-width:100%}.top{flex-direction:column;align-items:flex-start}body{padding:40px 16px 32px}.card{padding:22px}.cmd-row{padding:10px 12px}.cmd-row code{font-size:11px}}
</style>
</head>
<body>
<div class="wrap">
  <div class="top">
    <h1 style="margin:0;font-size:28px"><?= htmlspecialchars(brand('name'), ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?> SlowDNS</h1>
    <a class="btn" href="./">Back Home</a>
  </div>
  <div class="card">
    <h1>Install Code</h1>
    <p>Generate a short-lived one-time install code, then paste it into the public GitHub SlowDNS installer when asked. The code expires in 5 minutes and the install token is valid for 10 minutes after activation.</p>
    <div class="actions">
      <button id="issueBtn" type="button">Generate Code</button>
      <button id="copyBtn" type="button" class="btn" disabled>Copy Code</button>
    </div>
    <div class="code-box" id="codeBox" title="Click to copy install code">
      <div class="code" id="codeValue">Not generated yet</div>
      <div class="meta" id="codeMeta">Use the button above to issue a fresh code, then click the code box or Copy Code.</div>
    </div>
    <div class="install">
      <div class="section-label">Quick Install</div>
      <div class="cmd-row">
        <code id="installCmd">bash &lt;(curl -4fsSL https://raw.githubusercontent.com/stellawills/slowdns/main/install.sh)</code>
        <button id="copyCmdBtn" type="button" class="copy-btn">Copy</button>
      </div>
      <div class="cmd-row">
        <code id="envInstallCmd">SLOWDNS_INSTALL_CODE=IPT-SD-XXXXXX-XXXXXX-XXXXXX bash &lt;(curl -4fsSL https://raw.githubusercontent.com/stellawills/slowdns/main/install.sh)</code>
        <button id="copyEnvBtn" type="button" class="copy-btn">Copy</button>
      </div>
      <p class="cmd-note">Run as root on your Ubuntu VPS. Generate a one-time code above, then paste it into the installer when prompted. For non-interactive installs, replace <code style="color:var(--green)">IPT-SD-XXXXXX-XXXXXX-XXXXXX</code> with the generated code.</p>
    </div>
  </div>
</div>
<script>
const issueBtn = document.getElementById('issueBtn');
const copyBtn = document.getElementById('copyBtn');
const copyCmdBtn = document.getElementById('copyCmdBtn');
const copyEnvBtn = document.getElementById('copyEnvBtn');
const codeValue = document.getElementById('codeValue');
const codeMeta = document.getElementById('codeMeta');
const codeBox = document.getElementById('codeBox');
let currentCode = '';
const installCommand = 'bash <(curl -4fsSL https://raw.githubusercontent.com/stellawills/slowdns/main/install.sh)';
const installCommandWithEnv = 'SLOWDNS_INSTALL_CODE=IPT-SD-XXXXXX-XXXXXX-XXXXXX bash <(curl -4fsSL https://raw.githubusercontent.com/stellawills/slowdns/main/install.sh)';

function flashCopyButton(button) {
  const original = button.textContent;
  button.textContent = 'Copied';
  button.classList.add('ok');
  setTimeout(() => {
    button.textContent = original;
    button.classList.remove('ok');
  }, 1500);
}

async function copyText(value, successMessage) {
  if (!value) return false;
  try {
    if (navigator.clipboard && navigator.clipboard.writeText) {
      await navigator.clipboard.writeText(value);
    } else {
      const input = document.createElement('textarea');
      input.value = value;
      input.setAttribute('readonly', '');
      input.style.position = 'absolute';
      input.style.left = '-9999px';
      document.body.appendChild(input);
      input.select();
      document.execCommand('copy');
      document.body.removeChild(input);
    }
    codeMeta.innerHTML = '<span class="ok">' + successMessage + '</span>';
    return true;
  } catch (err) {
    codeMeta.innerHTML = '<span class="err">Copy failed. Select and copy manually.</span>';
    return false;
  }
}

issueBtn.addEventListener('click', async () => {
  issueBtn.disabled = true;
  codeMeta.textContent = 'Generating code...';
  try {
    const res = await fetch('/api/v2/slowdns/code/issue', {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: '{}'
    });
    const data = await res.json();
    if (!res.ok || !data.data || !data.data.install_code) {
      throw new Error((data.error && data.error.message) || 'Unable to issue install code');
    }
    currentCode = data.data.install_code;
    codeValue.textContent = currentCode;
    codeMeta.innerHTML = '<span class="ok">Expires:</span> ' + (data.data.expires_at || 'unknown');
    copyBtn.disabled = false;
  } catch (err) {
    codeValue.textContent = 'Generation failed';
    codeMeta.innerHTML = '<span class="err">' + (err.message || 'Unknown error') + '</span>';
    copyBtn.disabled = true;
  } finally {
    issueBtn.disabled = false;
  }
});

copyBtn.addEventListener('click', async () => {
  await copyText(currentCode, 'Install code copied. Paste it into the GitHub installer.');
});

codeBox.addEventListener('click', async () => {
  if (!currentCode) return;
  await copyText(currentCode, 'Install code copied. Paste it into the GitHub installer.');
});

copyCmdBtn.addEventListener('click', async () => {
  const ok = await copyText(installCommand, 'Install command copied.');
  if (ok) {
    flashCopyButton(copyCmdBtn);
  }
});

copyEnvBtn.addEventListener('click', async () => {
  const ok = await copyText(installCommandWithEnv, 'Install command with env example copied.');
  if (ok) {
    flashCopyButton(copyEnvBtn);
  }
});
</script>
</body>
</html>
<?php
    exit;
}

if (($path === '/version.json' || $path === '/api/v2/version') && $method === 'GET') {
    serve_version_manifest();
}

header('Content-Type: application/json');

try {
    if (!is_setup_complete()) {
        json_out(503, ['error' => 'License server not configured. Visit /admin to complete setup.']);
    }

    if (str_starts_with($path, '/api/v2')) {
        handle_api_v2($path, $method);
    }

    match (true) {
        $path === '/healthz' && $method === 'GET'
            => json_out(200, ['status' => 'ok']),

        $path === '/authorize' && $method === 'GET'
            => handle_authorize(),

        $path === '/register' && $method === 'POST'
            => handle_register(),

        $path === '/checkin' && $method === 'POST'
            => handle_checkin(),

        $path === '/revoke' && $method === 'POST'
            => handle_revoke(),

        $path === '/status' && $method === 'GET'
            => handle_status(),

        default
            => json_out(404, ['error' => 'not found']),
    };
} catch (Throwable $e) {
    error_log('License API error: ' . $e->getMessage());
    json_out(500, ['error' => 'internal server error']);
}

// ── Handlers ─────────────────────────────────────────────────────

function handle_authorize(): never {
    $result = license_issue_install_ticket_for_ip(client_ip());
    json_out($result['status'], $result['payload']);
}

function handle_register(): never {
    $body = read_json();
    $token    = trim($body['token'] ?? '');
    $ip       = trim($body['ip'] ?? '');
    $hostname = trim($body['hostname'] ?? '');
    $result = license_register_server($token, $ip, $hostname);
    json_out($result['status'], $result['payload']);
}

function handle_checkin(): never {
    $body      = read_json();
    $server_id = trim($body['server_id'] ?? '');
    $result = license_checkin_server($server_id);
    json_out($result['status'], $result['payload']);
}

function handle_revoke(): never {
    require_master_token();
    $body      = read_json();
    $server_id = trim($body['server_id'] ?? '');
    $result = license_change_server_revocation($server_id, true, 'api');
    json_out($result['status'], $result['payload']);
}

function handle_status(): never {
    $auth = $_SERVER['HTTP_AUTHORIZATION'] ?? '';
    $token = preg_replace('/^bearer\\s+/i', '', trim($auth));
    $result = license_status_rows_for_token($token);
    if (!$result['ok']) {
        json_out($result['status'], $result['payload']);
    }
    json_out(200, ['count' => count($result['rows']), 'servers' => $result['rows']]);
}

// ── Helpers ──────────────────────────────────────────────────────

function verify_master_token(string $token): bool {
    return is_master_token_valid($token);
}

function require_master_token(): void {
    $auth = $_SERVER['HTTP_AUTHORIZATION'] ?? '';
    $token = preg_replace('/^bearer\\s+/i', '', trim($auth));
    if (!verify_master_token($token)) json_out(403, ['error' => 'master token required']);
}

function read_json(): array {
    $len = (int) ($_SERVER['CONTENT_LENGTH'] ?? 0);
    if ($len > 65536) json_out(413, ['error' => 'request body too large (max 64KB)']);
    $raw = file_get_contents('php://input', false, null, 0, 65536);
    if (!$raw) json_out(400, ['error' => 'empty body']);
    $data = json_decode($raw, true);
    if (!is_array($data)) json_out(400, ['error' => 'invalid JSON']);
    return $data;
}

function json_out(int $status, array $data): never {
    http_response_code($status);
    echo json_encode($data, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES);
    exit;
}

function serve_version_manifest(): never {
    $manifestCandidates = [
        __DIR__ . '/version.json',
        __DIR__ . '/version.data.json',
    ];
    $manifestPath = null;
    foreach ($manifestCandidates as $candidate) {
        if (is_file($candidate)) {
            $manifestPath = $candidate;
            break;
        }
    }
    if ($manifestPath === null) {
        http_response_code(404);
        header('Content-Type: application/json');
        echo json_encode(['error' => 'version manifest not found'], JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES);
        exit;
    }

    $raw = file_get_contents($manifestPath);
    if ($raw === false) {
        http_response_code(500);
        header('Content-Type: application/json');
        echo json_encode(['error' => 'unable to read version manifest'], JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES);
        exit;
    }

    $data = json_decode($raw, true);
    if (!is_array($data)) {
        http_response_code(500);
        header('Content-Type: application/json');
        echo json_encode(['error' => 'invalid version manifest'], JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES);
        exit;
    }

    header('Content-Type: application/json');
    header('Cache-Control: public, max-age=300');
    echo json_encode($data, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES);
    exit;
}
