<?php
/**
 * LOCAL PREVIEW ROUTER — not for production
 * Usage: php -S localhost:8787 dev_router.php
 * Stubs out DB-dependent functions so UI pages render without MySQL.
 */

function brand(string $key): string {
    return match ($key) {
        'name'    => 'IPTunnel',
        'tagline' => 'Secure VPN server licensing',
        default   => 'IPTunnel',
    };
}
function client_ip(): string { return '127.0.0.1'; }
function slowdns_set_browser_cookie(): void {}

$uri    = strtok($_SERVER['REQUEST_URI'], '?');
$path   = '/' . trim($uri ?: '/', '/');
$method = $_SERVER['REQUEST_METHOD'];

if ($path !== '/' && file_exists(__DIR__ . $path) && !is_dir(__DIR__ . $path)) {
    return false;
}

// /docs and /docs/* — docs.php skips require_once db.php when brand() exists
if ($path === '/docs' || str_starts_with($path, '/docs/')) {
    require_once __DIR__ . '/docs.php';
    render_docs_page($path);
    exit;
}

// /slowdns
if ($path === '/slowdns') {
    $b = htmlspecialchars(brand('name'), ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
    echo '<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>' . $b . ' SlowDNS Install Code</title>
<style>
:root{--bg:#0f1117;--surface:#1a1d2e;--border:#2a2f45;--text:#e2e8f0;--text-secondary:#94a3b8;--muted:#64748b;--blue:#63b3ed;--blue-bg:#1a2e4a;--green:#68d391;--green-bg:#1c4532;--red:#fc8181}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font-family:-apple-system,BlinkMacSystemFont,\'Segoe UI\',sans-serif;padding:64px 20px 48px}
.wrap{max-width:800px;margin:0 auto}.top{display:flex;justify-content:space-between;align-items:center;gap:12px;margin-bottom:24px}
.card{background:var(--surface);border:1px solid var(--border);border-radius:14px;padding:24px}
h1{margin:0 0 8px;font-size:28px}p{color:var(--text-secondary);line-height:1.6}
.actions{display:flex;gap:10px;flex-wrap:wrap;margin-top:20px}
button,.btn{appearance:none;border:none;border-radius:10px;padding:12px 16px;font-weight:600;cursor:pointer;text-decoration:none}
button{background:var(--blue);color:#08111d}.btn{background:transparent;border:1px solid var(--border);color:var(--text)}
.code-box{margin-top:22px;padding:16px;border-radius:12px;border:1px dashed var(--border);background:#111521;cursor:pointer}
.code{font-family:Consolas,monospace;font-size:22px;letter-spacing:1px;word-break:break-all}
.meta{margin-top:8px;font-size:13px;color:var(--muted)}.ok{color:var(--green)}.err{color:var(--red)}
.install{width:100%;margin-top:26px;background:var(--surface);border:1px solid var(--border);border-radius:14px;padding:24px}
.section-label{font-size:11px;font-weight:600;text-transform:uppercase;letter-spacing:1px;color:var(--muted);margin-bottom:14px}
.cmd-row{background:var(--bg);border:1px solid var(--border);border-radius:8px;padding:11px 14px;display:flex;align-items:center;gap:10px;margin-bottom:14px}
.cmd-row code{font-family:\'SF Mono\',Consolas,monospace;font-size:12px;color:var(--text-secondary);flex:1;white-space:pre-wrap;overflow-wrap:anywhere}
.copy-btn{background:none;border:1px solid var(--border);border-radius:6px;color:var(--muted);cursor:pointer;padding:5px 10px;font-size:11px;white-space:nowrap;transition:all .15s;flex-shrink:0}
.copy-btn:hover{border-color:var(--blue);color:var(--blue)}
.copy-btn.ok{border-color:var(--green);color:var(--green)}
.cmd-note{font-size:11px;color:var(--muted);line-height:1.7;margin-top:2px}
</style></head><body>
<div class="wrap">
  <div class="top">
    <h1 style="margin:0;font-size:28px">' . $b . ' SlowDNS</h1>
    <a class="btn" href="./">Back Home</a>
  </div>
  <div class="card">
    <h1>Install Code</h1>
    <p>Generate a short-lived one-time install code, then paste it into the public GitHub SlowDNS installer when asked. The code expires in 5&nbsp;minutes and the install token is valid for 10&nbsp;minutes after activation.</p>
    <div class="actions">
      <button id="issueBtn" type="button">Generate Code</button>
      <button id="copyBtn" type="button" class="btn" disabled>Copy Code</button>
    </div>
    <div class="code-box" id="codeBox" title="Click to copy install code">
      <div class="code" id="codeValue">Not generated yet</div>
      <div class="meta" id="codeMeta">Use the button above to issue a fresh code.</div>
    </div>
    <div class="install">
      <div class="section-label">Quick Install</div>
      <div class="cmd-row">
        <code>bash &lt;(curl -4fsSL https://raw.githubusercontent.com/stellawills/slowdns/main/install.sh)</code>
        <button id="copyCmdBtn" type="button" class="copy-btn">Copy</button>
      </div>
      <div class="cmd-row">
        <code>SLOWDNS_INSTALL_CODE=IPT-SD-XXXXXX-XXXXXX-XXXXXX bash &lt;(curl -4fsSL https://raw.githubusercontent.com/stellawills/slowdns/main/install.sh)</code>
        <button id="copyEnvBtn" type="button" class="copy-btn">Copy</button>
      </div>
      <p class="cmd-note">Run as root on your Ubuntu VPS. Generate a one-time code above, then paste it into the installer when prompted.</p>
    </div>
  </div>
</div>
<script>
const issueBtn=document.getElementById(\'issueBtn\'),copyBtn=document.getElementById(\'copyBtn\'),
      copyCmdBtn=document.getElementById(\'copyCmdBtn\'),copyEnvBtn=document.getElementById(\'copyEnvBtn\'),
      codeValue=document.getElementById(\'codeValue\'),codeMeta=document.getElementById(\'codeMeta\'),
      codeBox=document.getElementById(\'codeBox\');
let currentCode=\'\';
const cmd=\'bash <(curl -4fsSL https://raw.githubusercontent.com/stellawills/slowdns/main/install.sh)\';
const cmdEnv=\'SLOWDNS_INSTALL_CODE=IPT-SD-XXXXXX-XXXXXX-XXXXXX \'+cmd;
function flash(btn){const o=btn.textContent;btn.textContent=\'Copied\';btn.classList.add(\'ok\');setTimeout(()=>{btn.textContent=o;btn.classList.remove(\'ok\');},1500);}
async function copy(val,msg){try{await navigator.clipboard.writeText(val);codeMeta.textContent=msg;return true;}catch(e){codeMeta.textContent=\'Copy failed.\';return false;}}
issueBtn.addEventListener(\'click\',()=>{currentCode=\'IPT-SD-PREVIEW-DEMO-ONLY\';codeValue.textContent=currentCode;codeMeta.textContent=\'Preview mode — real codes require live server\';copyBtn.disabled=false;});
copyBtn.addEventListener(\'click\',()=>copy(currentCode,\'Code copied.\'));
codeBox.addEventListener(\'click\',()=>{if(currentCode)copy(currentCode,\'Code copied.\');});
copyCmdBtn.addEventListener(\'click\',async()=>{if(await copy(cmd,\'Command copied.\'))flash(copyCmdBtn);});
copyEnvBtn.addEventListener(\'click\',async()=>{if(await copy(cmdEnv,\'Command copied.\'))flash(copyEnvBtn);});
</script></body></html>';
    exit;
}

// / home page
$b    = htmlspecialchars(brand('name'), ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
$host = htmlspecialchars($_SERVER['HTTP_HOST'] ?? 'localhost', ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
echo '<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>' . $b . ' License Server</title>
<style>
:root{--bg:#0f1117;--surface:#1a1d2e;--surface-hover:#1e2433;--border:#2a2f45;--text:#e2e8f0;--text-secondary:#94a3b8;--muted:#64748b;--blue:#63b3ed;--green:#68d391;--red:#fc8181;--blue-bg:#1a2e4a;--green-bg:#1c4532}
*,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
body{background:var(--bg);color:var(--text);font-family:-apple-system,BlinkMacSystemFont,\'Segoe UI\',sans-serif;min-height:100vh;display:flex;flex-direction:column;align-items:center;padding:64px 20px 48px}
.logo{display:flex;align-items:center;gap:14px;margin-bottom:10px}
.logo svg{width:52px;height:52px;color:var(--blue)}
.logo-wordmark{font-size:30px;font-weight:700;letter-spacing:-.5px}
.tagline{color:var(--text-secondary);font-size:14px;margin-bottom:48px;text-align:center}
.cards{display:grid;grid-template-columns:1fr 1fr;gap:16px;width:100%;max-width:640px;margin-bottom:32px}
.card{background:var(--surface);border:1px solid var(--border);border-radius:14px;padding:24px;text-decoration:none;color:inherit;transition:all .2s;display:flex;flex-direction:column;gap:8px}
.card:hover{transform:translateY(-2px)}
.card.blue:hover{border-color:var(--blue)}.card.green:hover{border-color:var(--green)}
.card-icon{width:42px;height:42px;border-radius:10px;display:flex;align-items:center;justify-content:center;margin-bottom:4px}
.card-icon.blue{background:var(--blue-bg);color:var(--blue)}.card-icon.green{background:var(--green-bg);color:var(--green)}
.card-icon svg{width:20px;height:20px}
.card-title{font-size:15px;font-weight:600}
.card-desc{font-size:12px;color:var(--text-secondary);line-height:1.55}
.card-link{margin-top:auto;padding-top:10px;font-size:12px;color:var(--muted)}
.install{width:100%;max-width:640px;background:var(--surface);border:1px solid var(--border);border-radius:14px;padding:24px;margin-bottom:24px}
.section-label{font-size:11px;font-weight:600;text-transform:uppercase;letter-spacing:1px;color:var(--muted);margin-bottom:14px}
.cmd-row{background:var(--bg);border:1px solid var(--border);border-radius:8px;padding:11px 14px;display:flex;align-items:center;gap:10px;margin-bottom:8px}
.cmd-row code{font-family:\'SF Mono\',Consolas,monospace;font-size:12px;color:var(--text-secondary);flex:1;overflow-x:auto;white-space:nowrap}
.copy-btn{background:none;border:1px solid var(--border);border-radius:6px;color:var(--muted);cursor:pointer;padding:5px 10px;font-size:11px;white-space:nowrap;transition:all .15s;flex-shrink:0}
.copy-btn:hover{border-color:var(--blue);color:var(--blue)}.copy-btn.ok{border-color:var(--green);color:var(--green)}
.cmd-note{font-size:11px;color:var(--muted);line-height:1.5;margin-top:4px}
.status-row{display:flex;align-items:center;gap:8px;font-size:12px;color:var(--muted);margin-bottom:32px}
.dot{width:8px;height:8px;border-radius:50%;background:var(--muted);flex-shrink:0}
.dot.ok{background:var(--green);box-shadow:0 0 6px var(--green)}
footer{font-size:11px;color:var(--muted)}
@media(max-width:520px){.cards{grid-template-columns:1fr}body{padding:40px 16px 32px}.logo-wordmark{font-size:24px}}
</style></head><body>
<div class="logo">
  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5"><path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/></svg>
  <div class="logo-wordmark">' . $b . '</div>
</div>
<p class="tagline">Secure VPN server licensing &amp; client management</p>
<div class="cards">
  <a href="docs" class="card blue">
    <div class="card-icon blue"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/><line x1="8" y1="13" x2="16" y2="13"/><line x1="8" y1="17" x2="13" y2="17"/></svg></div>
    <div class="card-title">Documentation</div>
    <div class="card-desc">Installation guides, authorization flows, and troubleshooting steps in one place.</div>
    <div class="card-link">Open docs &rarr;</div>
  </a>
  <a href="admin.php" class="card blue">
    <div class="card-icon blue"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2"/><circle cx="12" cy="7" r="4"/></svg></div>
    <div class="card-title">Admin Panel</div>
    <div class="card-desc">Manage clients, servers, activity logs and system settings.</div>
    <div class="card-link">Open panel &rarr;</div>
  </a>
  <a href="client.php" class="card green">
    <div class="card-icon green"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="2" y="2" width="20" height="8" rx="2"/><rect x="2" y="14" width="20" height="8" rx="2"/><line x1="6" y1="6" x2="6.01" y2="6"/><line x1="6" y1="18" x2="6.01" y2="18"/></svg></div>
    <div class="card-title">Client Portal</div>
    <div class="card-desc">View your registered servers, check status and manage your account.</div>
    <div class="card-link">Sign in &rarr;</div>
  </a>
  <a href="slowdns" class="card green">
    <div class="card-icon green"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M4 11a8 8 0 0 1 16 0"/><path d="M7 11a5 5 0 0 1 10 0"/><path d="M10 11a2 2 0 0 1 4 0"/><line x1="12" y1="13" x2="12" y2="20"/><circle cx="12" cy="21" r="1"/></svg></div>
    <div class="card-title">SlowDNS Install Code</div>
    <div class="card-desc">Generate a one-time IPT-SD code for the public GitHub SlowDNS installer.</div>
    <div class="card-link">Open SlowDNS page &rarr;</div>
  </a>
</div>
<div class="install">
  <div class="section-label">Quick Install</div>
  <div class="cmd-row">
    <code>bash &lt;(curl -4 -sk https://license.internetshub.com/iptunnel-install.sh)</code>
    <button class="copy-btn" id="c1">Copy</button>
  </div>
  <div class="cmd-row">
    <code>bash &lt;(curl -4 -sk https://license.internetshub.com/iptunnel-install.sh) --license-token YOUR_TOKEN</code>
    <button class="copy-btn" id="c2">Copy</button>
  </div>
  <p class="cmd-note">Run as root on your Ubuntu VPS. Replace YOUR_TOKEN with the token from the Client Portal or Admin Panel.</p>
</div>
<div class="status-row">
  <div class="dot ok"></div>
  <span>Preview mode &mdash; API status not checked</span>
</div>
<footer>' . $b . ' License Server &middot; ' . $host . '</footer>
<script>
document.getElementById(\'c1\').addEventListener(\'click\',()=>navigator.clipboard.writeText(\'bash <(curl -4 -sk https://license.internetshub.com/iptunnel-install.sh)\'));
document.getElementById(\'c2\').addEventListener(\'click\',()=>navigator.clipboard.writeText(\'bash <(curl -4 -sk https://license.internetshub.com/iptunnel-install.sh) --license-token YOUR_TOKEN\'));
</script>
</body></html>';
