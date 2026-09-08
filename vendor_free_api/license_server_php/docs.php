<?php

if (!function_exists('brand')) {
    require_once __DIR__ . '/db.php';
}

function docs_module_nav_groups(): array {
    return [
        'Overview' => [
            ['slug' => 'index',  'label' => 'Documentation Home'],
            ['slug' => 'faq',    'label' => 'FAQ'],
        ],
        'Install' => [
            ['slug' => 'install/iptunnel', 'label' => 'Install IPTunnel'],
            ['slug' => 'install/slowdns',  'label' => 'Install SlowDNS'],
        ],
        'Authorization' => [
            ['slug' => 'authorization/zero-touch',    'label' => 'Zero-Touch Authorization'],
            ['slug' => 'authorization/client-token',  'label' => 'Client-Token Install'],
        ],
        'SlowDNS' => [
            ['slug' => 'slowdns/dns-layout',           'label' => 'DNS Layout'],
            ['slug' => 'slowdns/activation-lifecycle', 'label' => 'Activation Lifecycle'],
            ['slug' => 'slowdns/environment-vars',     'label' => 'Environment Variables'],
            ['slug' => 'slowdns/rate-limits',          'label' => 'Rate Limits'],
        ],
        'Operations' => [
            ['slug' => 'troubleshooting', 'label' => 'Troubleshooting'],
            ['slug' => 'api',             'label' => 'API Reference'],
        ],
    ];
}

function docs_module_pages(): array { // phpcs:ignore
    return [
        'index' => [
            'eyebrow' => 'Documentation',
            'title'   => 'Installers, Authorization, and Operations',
            'summary' => 'Everything you need to install IPTunnel or SlowDNS, configure DNS, understand the activation lifecycle, and operate a running server.',
            'sections' => [
                [
                    'id'    => 'what-youll-find',
                    'title' => "What you'll find here",
                    'body'  => <<<'HTML'
<p>Documentation is organized by operator task. Start with the installer guide that matches your product, then use the reference pages as needed.</p>
<ul>
  <li><strong>Install IPTunnel</strong> &mdash; the full stack installer with zero-touch and client-token paths.</li>
  <li><strong>Install SlowDNS</strong> &mdash; the public GitHub installer with private license activation including prompts, expected output, retry behavior, and environment variable overrides.</li>
  <li><strong>Activation Lifecycle</strong> &mdash; a detailed walkthrough of <code>issue_code</code>, <code>precheck</code>, <code>activate</code>, <code>confirm</code>, and <code>release</code>.</li>
  <li><strong>DNS Layout</strong> &mdash; the exact A and NS records you need and how to verify them.</li>
  <li><strong>Environment Variables</strong> &mdash; every <code>SLOWDNS_*</code> variable the installer accepts for unattended or scripted deployments.</li>
  <li><strong>Rate Limits</strong> &mdash; the public-code issuance controls, browser-session requirements, and activation throttles.</li>
  <li><strong>Troubleshooting</strong> &mdash; specific error codes, their causes, and exact commands to diagnose them.</li>
  <li><strong>API Reference</strong> &mdash; all routes with request and response examples.</li>
</ul>
HTML,
                ],
                [
                    'id'    => 'prerequisites',
                    'title' => 'Prerequisites',
                    'body'  => <<<'HTML'
<p>All paths require:</p>
<ul>
  <li>An Ubuntu 20.04 / 22.04 / 24.04 VPS with a root shell.</li>
  <li>A reachable public IPv4 address on the VPS.</li>
  <li>Outbound HTTPS to this license server and to GitHub.</li>
  <li>For SlowDNS specifically: a domain you control with the ability to add <code>A</code> and <code>NS</code> records.</li>
</ul>
<p class="note">Debian 11/12 works but is not the primary test target. Other distros are not supported.</p>
HTML,
                ],
                [
                    'id'    => 'choose-path',
                    'title' => 'Choose the right installer',
                    'body'  => <<<'HTML'
<table style="width:100%;border-collapse:collapse;font-size:14px">
  <thead>
    <tr style="border-bottom:1px solid #2a2f45;text-align:left">
      <th style="padding:8px 12px">Scenario</th>
      <th style="padding:8px 12px">Use</th>
    </tr>
  </thead>
  <tbody style="color:#94a3b8">
    <tr style="border-bottom:1px solid #1e2235">
      <td style="padding:8px 12px">Full IPTunnel stack</td>
      <td style="padding:8px 12px"><a href="/docs/install/iptunnel">IPTunnel installer</a></td>
    </tr>
    <tr style="border-bottom:1px solid #1e2235">
      <td style="padding:8px 12px">Standalone SlowDNS only</td>
      <td style="padding:8px 12px"><a href="/docs/install/slowdns">SlowDNS installer</a></td>
    </tr>
    <tr style="border-bottom:1px solid #1e2235">
      <td style="padding:8px 12px">VPS IP is already known in advance</td>
      <td style="padding:8px 12px"><a href="/docs/authorization/zero-touch">Zero-touch authorization</a></td>
    </tr>
    <tr>
      <td style="padding:8px 12px">Installing for a specific client account</td>
      <td style="padding:8px 12px"><a href="/docs/authorization/client-token">Client-token install</a></td>
    </tr>
  </tbody>
</table>
HTML,
                ],
                [
                    'id'    => 'quick-links',
                    'title' => 'Quick links',
                    'body'  => <<<'HTML'
<ul>
  <li><a href="/docs/install/slowdns">SlowDNS installation guide</a></li>
  <li><a href="/docs/slowdns/activation-lifecycle">Activation lifecycle explained</a></li>
  <li><a href="/docs/slowdns/dns-layout">DNS layout and verification</a></li>
  <li><a href="/docs/slowdns/environment-vars">Environment variable reference</a></li>
  <li><a href="/docs/troubleshooting">Troubleshooting error codes</a></li>
  <li><a href="/docs/api">API reference with request/response examples</a></li>
  <li><a href="/docs/faq">FAQ</a></li>
</ul>
HTML,
                ],
            ],
        ],
        'install/iptunnel' => [
            'eyebrow' => 'Install',
            'title' => 'Install IPTunnel',
            'summary' => 'Use the main installer when you want the full IPTunnel stack. This page covers both zero-touch and client-token installation paths.',
            'sections' => [
                [
                    'id' => 'overview',
                    'title' => 'Overview',
                    'body' => <<<'HTML'
<p>The IPTunnel installer supports two operator flows: zero-touch authorization and explicit client-token installation. Both use the same base installer, but the authorization rules are different.</p>
HTML,
                ],
                [
                    'id' => 'commands',
                    'title' => 'Install commands',
                    'body' => <<<'HTML'
<pre><code>bash &lt;(curl -4 -sk https://license.internetshub.com/iptunnel-install.sh)</code></pre>
<pre><code>bash &lt;(curl -4 -sk https://license.internetshub.com/iptunnel-install.sh) --license-token YOUR_TOKEN</code></pre>
<p class="note">Use the IPv4-safe form to avoid IPv6-based mismatches during authorization and registration.</p>
HTML,
                ],
                [
                    'id' => 'step-by-step',
                    'title' => 'Step-by-step',
                    'body' => <<<'HTML'
<ol>
  <li>Connect to the VPS as <strong>root</strong>.</li>
  <li>Choose the correct installer path: zero-touch or client token.</li>
  <li>Run the installer and allow it to install packages and register the server.</li>
  <li>Wait for the services to start and verify the server record in the panel if needed.</li>
</ol>
HTML,
                ],
                [
                    'id' => 'verification',
                    'title' => 'Verification',
                    'body' => <<<'HTML'
<p>After install, verify the server appears in the panel and that the expected services are active on the VPS.</p>
<pre><code>systemctl status --no-pager
hostname -I
</code></pre>
HTML,
                ],
                [
                    'id' => 'failure-cases',
                    'title' => 'Common failure cases',
                    'body' => <<<'HTML'
<ul>
  <li>The VPS public IPv4 was not authorized for zero-touch install.</li>
  <li>The wrong client token was provided.</li>
  <li>The server cannot reach the license backend or outbound package mirrors.</li>
</ul>
HTML,
                ],
            ],
        ],
        'install/slowdns' => [
            'eyebrow' => 'Install',
            'title'   => 'Install SlowDNS',
            'summary' => 'SlowDNS installs from the public GitHub repository but activates through this private license backend using a single-use install code. The installer prechecks the code first, then binds the final hostname and public IP only after you confirm them.',
            'sections' => [
                [
                    'id'    => 'overview',
                    'title' => 'How it works',
                    'body'  => <<<'HTML'
<p>The installer is hosted publicly on GitHub but is gated by a one-time <code>IPT-SD-XXXXXX-XXXXXX-XXXXXX</code> install code issued from this panel. The flow is:</p>
<ol>
  <li>You generate a code from <strong>/slowdns</strong>. The code is valid for <strong>5 minutes</strong> and single-use.</li>
  <li>The installer performs a <strong>precheck</strong> using the code plus machine identity (<code>/etc/machine-id</code> and the SSH host fingerprint). The code stays in <code>issued</code> state and the server returns a signed <strong>15-minute precheck token</strong>.</li>
  <li>You enter the public hostname, delegated tunnel domain, and public IP only after the code is accepted.</li>
  <li>The installer then <strong>activates</strong> the install. This is the step that binds the chosen hostname and public IP, marks the code as <code>consumed</code>, and returns a signed <strong>10-minute install token</strong>.</li>
  <li>Once all services are live and verified, the installer <strong>confirms</strong> the activation and permanently consumes the install token.</li>
  <li>If anything fails before confirmation, the installer calls <strong>release</strong> so the code can be restored and retried.</li>
</ol>
HTML,
                ],
                [
                    'id'    => 'command',
                    'title' => 'Install command',
                    'body'  => <<<'HTML'
<pre><code>bash &lt;(curl -4fsSL https://raw.githubusercontent.com/stellawills/slowdns/main/install.sh)</code></pre>
<p class="note">The installer requires root. Run it on an Ubuntu 20.04 / 22.04 / 24.04 VPS. It installs <code>python3</code>, <code>curl</code>, <code>unzip</code>, <code>openssh-server</code>, and builds the dnstt server and client from source if prebuilt binaries are not provided.</p>
HTML,
                ],
                [
                    'id'    => 'step-by-step',
                    'title' => 'Step-by-step',
                    'body'  => <<<'HTML'
<ol>
  <li>Open <strong>/slowdns</strong> in this panel and click <em>Generate Code</em>. Copy the <code>IPT-SD-...</code> value. The code expires in 5 minutes, so do this only when you are ready to install.</li>
  <li>SSH into your VPS as root.</li>
  <li>Run the install command above.</li>
  <li>If the session is interactive over SSH and <code>screen</code> is available, the installer re-launches itself inside <code>screen -S slowdns-install</code> so it can survive a dropped connection.</li>
  <li>When prompted, paste the install code. The installer validates it immediately and will let you retry before asking for anything else if the code is invalid, used, expired, or blocked.</li>
  <li>Enter the public hostname &mdash; the <code>A</code> record host that points to this VPS (for example <code>dns.example.com</code>).</li>
  <li>Enter the delegated tunnel domain &mdash; the subdomain whose <code>NS</code> record points to the public hostname (for example <code>slowdns.example.com</code>). The installer suggests a default based on the hostname.</li>
  <li>Confirm or enter the VPS public IPv4. The installer auto-detects it; press Enter to accept.</li>
  <li>The installer builds dnstt, generates SSH host keys, writes systemd units, and starts services.</li>
  <li>On success you will see <em>Activation confirmed</em> and the install code in the summary line.</li>
</ol>
HTML,
                ],
                [
                    'id'    => 'expected-output',
                    'title' => 'Expected terminal output',
                    'body'  => <<<'HTML'
<p>A healthy install looks like this end to end:</p>
<pre><code>============================================================
 SlowDNS Install Code
============================================================
 Generate code at: https://license.internetshub.com/slowdns
 This code is single-use and expires quickly.

 Enter install code: IPT-SD-XXXXXX-XXXXXX-XXXXXX
Validating install code...
 Install code accepted. Continue with the SlowDNS host prompts.

SlowDNS public hostname (A record host) [ns1.example.com]:
SlowDNS delegated tunnel domain [slowdns.example.com]:
Public IPv4 for this VPS [1.2.3.4]:

Preparing SlowDNS files...
Starting SlowDNS services...
Confirming activation...
 Activation confirmed.

============================================================
 SlowDNS installed successfully
============================================================
  Installed at:  /opt/slowdns
  API status:    systemctl status slowdns-api
  dnstt status:  systemctl status slowdns-dnstt
  Menu:          slowdns-menu
  Install code:  IPT-SD-XXXXXX-XXXXXX-XXXXXX activated via https://license.internetshub.com</code></pre>
HTML,
                ],
                [
                    'id'    => 'resume',
                    'title' => 'Resuming after network issues',
                    'body'  => <<<'HTML'
<p>If the installer re-launches itself in <code>screen</code>, you can safely reconnect and reattach with:</p>
<pre><code>screen -r slowdns-install</code></pre>
<p>If the VPS build is especially slow, precheck buys you time: the code itself expires in 5 minutes, but once precheck succeeds the installer has a separate 15-minute token to reach the final activation step.</p>
HTML,
                ],
                [
                    'id'    => 'unattended',
                    'title' => 'Unattended / scripted install',
                    'body'  => <<<'HTML'
<p>Pass configuration as environment variables to skip all interactive prompts:</p>
<pre><code>SLOWDNS_INSTALL_CODE="IPT-SD-XXXXXX-XXXXXX-XXXXXX" \
SLOWDNS_HOSTNAME="ns1.example.com" \
SLOWDNS_TUNNEL_DOMAIN="slowdns.example.com" \
SLOWDNS_PUBLIC_IP="1.2.3.4" \
bash &lt;(curl -4fsSL https://raw.githubusercontent.com/stellawills/slowdns/main/install.sh)</code></pre>
<p>See <a href="/docs/slowdns/environment-vars">Environment Variables</a> for the full list.</p>
HTML,
                ],
                [
                    'id'    => 'post-install',
                    'title' => 'After install',
                    'body'  => <<<'HTML'
<p>Once the installer finishes:</p>
<ul>
  <li>Run <code>slowdns-menu</code> to manage SSH accounts, view runtime info, and check service status.</li>
  <li>Verify DNS propagation with <code>dig +short A ns1.example.com</code> and <code>dig +short NS slowdns.example.com</code>.</li>
  <li>The API is available locally at <code>http://127.0.0.1:8091/api/v2/healthz</code>.</li>
  <li>Activation metadata is stored at <code>/opt/slowdns/config/license.json</code>.</li>
</ul>
HTML,
                ],
                [
                    'id'    => 'failure-cases',
                    'title' => 'Common failure cases',
                    'body'  => <<<'HTML'
<table style="width:100%;border-collapse:collapse;font-size:14px">
  <thead>
    <tr style="border-bottom:1px solid #2a2f45;text-align:left">
      <th style="padding:8px 12px">Error message</th>
      <th style="padding:8px 12px">Cause and fix</th>
    </tr>
  </thead>
  <tbody style="color:#94a3b8">
    <tr style="border-bottom:1px solid #1e2235">
      <td style="padding:8px 12px">Install code already used</td>
      <td style="padding:8px 12px">The code was consumed by an earlier run. Generate a new code from <strong>/slowdns</strong>.</td>
    </tr>
    <tr style="border-bottom:1px solid #1e2235">
      <td style="padding:8px 12px">Install code expired</td>
      <td style="padding:8px 12px">More than 5 minutes passed between generating and using the code. Generate a fresh one and run the installer immediately.</td>
    </tr>
    <tr style="border-bottom:1px solid #1e2235">
      <td style="padding:8px 12px">Install code exceeded max activation attempts</td>
      <td style="padding:8px 12px">The same code was activated and released too many times. Generate a new code.</td>
    </tr>
    <tr style="border-bottom:1px solid #1e2235">
      <td style="padding:8px 12px">Too many requests</td>
      <td style="padding:8px 12px">Rate limit hit. Wait before trying again. See <a href="/docs/slowdns/rate-limits">Rate Limits</a>.</td>
    </tr>
    <tr style="border-bottom:1px solid #1e2235">
      <td style="padding:8px 12px">Install token has expired</td>
      <td style="padding:8px 12px">The install took more than 10 minutes (usually when building dnstt from source on a very slow VPS). Retry; consider providing prebuilt binaries via <code>DNSTT_SERVER_URL</code> / <code>DNSTT_CLIENT_URL</code>.</td>
    </tr>
    <tr>
      <td style="padding:8px 12px">Could not reach the license server</td>
      <td style="padding:8px 12px">The VPS cannot reach the license server over HTTPS. Check outbound connectivity: <code>curl -4v https://license.internetshub.com/api/v2/healthz</code></td>
    </tr>
  </tbody>
</table>
HTML,
                ],
            ],
        ],
        'authorization/zero-touch' => [
            'eyebrow' => 'Authorization',
            'title' => 'Zero-Touch Authorization',
            'summary' => 'Zero-touch installation works only when the VPS public IPv4 is explicitly authorized for the client before the installer runs.',
            'sections' => [
                [
                    'id' => 'how-it-works',
                    'title' => 'How it works',
                    'body' => <<<'HTML'
<p>Zero-touch authorization lets a VPS install without a client token, but only if its public IPv4 is already present in the client's <strong>Authorized IPs</strong> list.</p>
HTML,
                ],
                [
                    'id' => 'steps',
                    'title' => 'Step-by-step',
                    'body' => <<<'HTML'
<ol>
  <li>Open the correct client in the admin panel.</li>
  <li>Add the VPS public IPv4 to the client's <strong>Authorized IPs</strong>.</li>
  <li>Run the zero-touch installer on the VPS.</li>
</ol>
HTML,
                ],
                [
                    'id' => 'common-mistakes',
                    'title' => 'Common mistakes',
                    'body' => <<<'HTML'
<ul>
  <li>Adding the server to the Servers list instead of the Authorized IPs list.</li>
  <li>Using a stale IPv4 after the VPS address changed.</li>
  <li>Expecting zero-touch to work before the authorized IP entry is saved.</li>
</ul>
HTML,
                ],
            ],
        ],
        'authorization/client-token' => [
            'eyebrow' => 'Authorization',
            'title' => 'Client-Token Install',
            'summary' => 'Use the client-token path when you do not want to pre-authorize an IP or when the server should not be enrolled through zero-touch onboarding.',
            'sections' => [
                [
                    'id' => 'when-to-use',
                    'title' => 'When to use it',
                    'body' => <<<'HTML'
<p>Client-token installation is best when the VPS public IP may change, when the operator is installing on behalf of a specific client, or when you do not want to maintain pre-authorized IP entries.</p>
HTML,
                ],
                [
                    'id' => 'steps',
                    'title' => 'Step-by-step',
                    'body' => <<<'HTML'
<ol>
  <li>Get the client token from the client portal or admin panel.</li>
  <li>Run the installer with <code>--license-token YOUR_TOKEN</code>.</li>
  <li>Let the installer register the server and start the services.</li>
  <li>Verify the server record in the panel if needed.</li>
</ol>
HTML,
                ],
                [
                    'id' => 'verification',
                    'title' => 'Verification',
                    'body' => <<<'HTML'
<p>After install, confirm the server is attached to the correct client account and that the token was accepted without zero-touch checks.</p>
HTML,
                ],
            ],
        ],
        'slowdns/dns-layout' => [
            'eyebrow' => 'SlowDNS',
            'title' => 'SlowDNS DNS Layout',
            'summary' => 'SlowDNS depends on the correct relationship between the public host and the delegated tunnel domain.',
            'sections' => [
                [
                    'id' => 'overview',
                    'title' => 'Overview',
                    'body' => <<<'HTML'
<p>SlowDNS needs two related names: the public host that resolves to the VPS, and the delegated tunnel domain that points to that host via an <code>NS</code> record.</p>
HTML,
                ],
                [
                    'id' => 'example',
                    'title' => 'Example layout',
                    'body' => <<<'HTML'
<p>If you install with:</p>
<ul>
  <li>Public hostname: <code>dns.example.com</code></li>
  <li>Delegated tunnel domain: <code>slowdns.example.com</code></li>
</ul>
<p>Then your DNS should look like this:</p>
<pre><code>A   dns.example.com        1.2.3.4
NS  slowdns.example.com   dns.example.com</code></pre>
HTML,
                ],
                [
                    'id' => 'verification',
                    'title' => 'Verify DNS',
                    'body' => <<<'HTML'
<pre><code>dig +short A dns.example.com
dig +short NS slowdns.example.com</code></pre>
<p>The <code>A</code> lookup should return the VPS IPv4. The <code>NS</code> lookup should return the public hostname that serves the delegated tunnel zone.</p>
HTML,
                ],
                [
                    'id' => 'failure-cases',
                    'title' => 'Common failure cases',
                    'body' => <<<'HTML'
<ul>
  <li>The public host has no <code>A</code> record.</li>
  <li>The delegated tunnel domain points to the wrong nameserver host.</li>
  <li>The client is configured with the public host instead of the delegated tunnel domain.</li>
</ul>
HTML,
                ],
            ],
        ],
        'troubleshooting' => [
            'eyebrow' => 'Operations',
            'title'   => 'Troubleshooting',
            'summary' => 'Specific error codes, their causes, and exact commands to diagnose and resolve them.',
            'sections' => [
                [
                    'id'    => 'activation-error-codes',
                    'title' => 'Activation error codes',
                    'body'  => <<<'HTML'
<table style="width:100%;border-collapse:collapse;font-size:14px">
  <thead>
    <tr style="border-bottom:1px solid #2a2f45;text-align:left">
      <th style="padding:8px 12px">Code</th>
      <th style="padding:8px 12px">HTTP</th>
      <th style="padding:8px 12px">Meaning and action</th>
    </tr>
  </thead>
  <tbody style="color:#94a3b8">
    <tr style="border-bottom:1px solid #1e2235">
      <td style="padding:8px 12px"><code>install_code_not_found</code></td>
      <td style="padding:8px 12px">404</td>
      <td style="padding:8px 12px">The code does not exist. Check for typos or generate a new one.</td>
    </tr>
    <tr style="border-bottom:1px solid #1e2235">
      <td style="padding:8px 12px"><code>install_code_used</code></td>
      <td style="padding:8px 12px">403</td>
      <td style="padding:8px 12px">The code was already consumed by a previous activation. Generate a new code.</td>
    </tr>
    <tr style="border-bottom:1px solid #1e2235">
      <td style="padding:8px 12px"><code>install_code_expired</code></td>
      <td style="padding:8px 12px">403</td>
      <td style="padding:8px 12px">The 5-minute window elapsed. Generate a new code and run the installer immediately.</td>
    </tr>
    <tr style="border-bottom:1px solid #1e2235">
      <td style="padding:8px 12px"><code>install_code_max_activations</code></td>
      <td style="padding:8px 12px">403</td>
      <td style="padding:8px 12px">The code was cycled through activate/release too many times (limit: 5). Generate a new code.</td>
    </tr>
    <tr style="border-bottom:1px solid #1e2235">
      <td style="padding:8px 12px"><code>rate_limit_exceeded</code></td>
      <td style="padding:8px 12px">429</td>
      <td style="padding:8px 12px">Too many requests from your IP in the current window. See <a href="/docs/slowdns/rate-limits">Rate Limits</a>. Wait before retrying.</td>
    </tr>
    <tr style="border-bottom:1px solid #1e2235">
      <td style="padding:8px 12px"><code>token_invalid</code></td>
      <td style="padding:8px 12px">403</td>
      <td style="padding:8px 12px">The install token signature is wrong or the token has expired (10-minute window). Restart the install from step 1.</td>
    </tr>
    <tr style="border-bottom:1px solid #1e2235">
      <td style="padding:8px 12px"><code>token_mismatch</code></td>
      <td style="padding:8px 12px">403</td>
      <td style="padding:8px 12px">The token does not match the activation_id. This should not happen in normal flow; restart the install.</td>
    </tr>
    <tr style="border-bottom:1px solid #1e2235">
      <td style="padding:8px 12px"><code>token_used</code></td>
      <td style="padding:8px 12px">409</td>
      <td style="padding:8px 12px">Confirm was called twice for the same activation. The install is already confirmed; check the server is running correctly.</td>
    </tr>
    <tr>
      <td style="padding:8px 12px"><code>activation_not_found</code></td>
      <td style="padding:8px 12px">404</td>
      <td style="padding:8px 12px">The activation_id no longer exists (already released or never created). Restart the install.</td>
    </tr>
  </tbody>
</table>
HTML,
                ],
                [
                    'id'    => 'service-checks',
                    'title' => 'Service-layer checks',
                    'body'  => <<<'HTML'
<p>Run these after install to verify all three services are active:</p>
<pre><code>systemctl status slowdns-api slowdns-dnstt slowdns-udp53-redirect --no-pager</code></pre>
<p>Check the API health endpoint directly:</p>
<pre><code>curl -s http://127.0.0.1:8091/api/v2/healthz</code></pre>
<p>Expected response: <code>{"data":{"status":"ok"}, ...}</code></p>
<p>Check the license metadata written by the installer:</p>
<pre><code>cat /opt/slowdns/config/license.json</code></pre>
<p>If this file is missing or empty, the install did not complete the confirm step.</p>
HTML,
                ],
                [
                    'id'    => 'log-collection',
                    'title' => 'Log collection',
                    'body'  => <<<'HTML'
<p>Collect the last 120 lines from all three service logs before making changes:</p>
<pre><code>journalctl -u slowdns-api -u slowdns-dnstt -u slowdns-udp53-redirect --no-pager -n 120</code></pre>
<p>For API-layer errors only:</p>
<pre><code>journalctl -u slowdns-api -n 50 --no-pager</code></pre>
<p>For dnstt tunnel errors (no client connections, key mismatch):</p>
<pre><code>journalctl -u slowdns-dnstt -n 50 --no-pager</code></pre>
HTML,
                ],
                [
                    'id'    => 'dns-checks',
                    'title' => 'DNS verification',
                    'body'  => <<<'HTML'
<p>If services are healthy but clients cannot connect, verify DNS before changing any config:</p>
<pre><code># A record for the public host must return the VPS IPv4
dig +short A ns1.example.com

# NS delegation must return the public host
dig +short NS slowdns.example.com

# Test that the NS delegation resolves through the dnstt server
dig @ns1.example.com slowdns.example.com NS</code></pre>
<p>If the NS record is missing or points to the wrong host, no amount of service restarts will fix client connections.</p>
HTML,
                ],
                [
                    'id'    => 'reinstall',
                    'title' => 'Reinstalling on an existing server',
                    'body'  => <<<'HTML'
<p>The installer is idempotent. Re-running it on a server where SlowDNS is already installed will:</p>
<ul>
  <li>Require a fresh install code (the old one was consumed at first install).</li>
  <li>Preserve existing SSH accounts and the SQLite database.</li>
  <li>Overwrite the dnstt binary and service files with the latest versions.</li>
  <li>Restart all services at the end.</li>
</ul>
<p>Generate a new code from <strong>/slowdns</strong>, then rerun the install command.</p>
HTML,
                ],
            ],
        ],
        'api' => [
            'eyebrow' => 'Operations',
            'title'   => 'API Reference',
            'summary' => 'All public and activation-lifecycle routes with request and response examples.',
            'sections' => [
                [
                    'id'    => 'health',
                    'title' => 'Health check',
                    'body'  => <<<'HTML'
<pre><code>GET /api/v2/healthz</code></pre>
<p><strong>Response 200</strong></p>
<pre><code>{
  "data": { "status": "ok" },
  "meta": { "message": "OK" }
}</code></pre>
HTML,
                ],
                [
                    'id'    => 'slowdns-issue',
                    'title' => 'Issue install code',
                    'body'  => <<<'HTML'
<pre><code>POST /api/v2/slowdns/code/issue</code></pre>
<p>No request body is required, but the caller must first load <code>GET /slowdns</code> so the browser receives the <code>slowdns_browser</code> session cookie. The endpoint is rate limited at <strong>3 per IP per hour</strong>, <strong>10 per IP per day</strong>, with extra per-session and per-fingerprint caps.</p>
<p><strong>Response 201</strong></p>
<pre><code>{
  "data": {
    "install_code": "IPT-SD-XXXXXX-XXXXXX-XXXXXX",
    "expires_at": "2026-03-31T12:05:00+00:00",
    "ttl_seconds": 300
  },
  "meta": { "message": "SlowDNS install code issued" }
}</code></pre>
<p><strong>Response 403</strong> &mdash; browser session missing or expired</p>
<pre><code>{ "error": { "code": "browser_session_required", "message": "Open the SlowDNS page first before requesting an install code." } }</code></pre>
<p><strong>Response 429</strong> &mdash; rate limit exceeded</p>
<pre><code>{ "error": { "code": "rate_limit_exceeded", "message": "Too many requests. Please wait before trying again." } }</code></pre>
HTML,
                ],
                [
                    'id'    => 'slowdns-precheck',
                    'title' => 'Precheck install code',
                    'body'  => <<<'HTML'
<pre><code>POST /api/v2/slowdns/install/precheck</code></pre>
<p>Called by the installer immediately after the code is entered. This validates the code and machine identity <strong>before</strong> hostname, tunnel domain, or public IP are collected.</p>
<p><strong>Request body</strong></p>
<pre><code>{
  "install_code": "IPT-SD-XXXXXX-XXXXXX-XXXXXX",
  "machine_id": "&lt;/etc/machine-id contents&gt;",
  "ssh_fingerprint": "SHA256:...",
  "product": "slowdns",
  "installer_version": "2026.08.27.1"
}</code></pre>
<p><strong>Response 200</strong></p>
<pre><code>{
  "data": {
    "install_code": "IPT-SD-XXXXXX-XXXXXX-XXXXXX",
    "install_code_hint": "IPT-SD-XXXX...XXXXXX",
    "precheck_token": "eyJhbGciOiJIUzI1NiJ9...",
    "precheck_expires_at": "2026-03-31T12:15:00+00:00",
    "machine_binding": {
      "machine_id": "...",
      "ssh_fingerprint": "SHA256:..."
    }
  },
  "meta": { "message": "Install code validated" }
}</code></pre>
HTML,
                ],
                [
                    'id'    => 'slowdns-activate',
                    'title' => 'Activate install code',
                    'body'  => <<<'HTML'
<pre><code>POST /api/v2/slowdns/install/activate</code></pre>
<p>Rate limited to <strong>5 requests per IP per 24 hours</strong> and <strong>5 requests per machine per 24 hours</strong>. Called by the installer only after the operator confirms the final hostname and public IP.</p>
<p><strong>Request body</strong></p>
<pre><code>{
  "install_code": "IPT-SD-XXXXXX-XXXXXX-XXXXXX",
  "precheck_token": "eyJhbGciOiJIUzI1NiJ9...",
  "hostname": "ns1.example.com",
  "public_ip": "1.2.3.4",
  "machine_id": "&lt;/etc/machine-id contents&gt;",
  "ssh_fingerprint": "SHA256:...",
  "requested_ref": "main",
  "installer_version": "2026.08.27.1"
}</code></pre>
<p><strong>Response 200</strong></p>
<pre><code>{
  "data": {
    "activation_id": "act_a1b2c3d4e5f6a7b8",
    "install_token": "eyJhbGciOiJIUzI1NiJ9...",
    "install_token_expires_at": "2026-03-31T12:15:00+00:00",
    "install_code": "IPT-SD-XXXXXX-XXXXXX-XXXXXX",
    "machine_binding": {
      "hostname": "ns1.example.com",
      "public_ip": "1.2.3.4",
      "machine_id": "...",
      "ssh_fingerprint": "SHA256:..."
    }
  },
  "meta": { "message": "Install token issued" }
}</code></pre>
HTML,
                ],
                [
                    'id'    => 'slowdns-confirm',
                    'title' => 'Confirm install',
                    'body'  => <<<'HTML'
<pre><code>POST /api/v2/slowdns/install/confirm</code></pre>
<p>Called by the installer after all services are confirmed active. Permanently consumes the install token.</p>
<p><strong>Request body</strong></p>
<pre><code>{
  "activation_id": "act_a1b2c3d4e5f6a7b8",
  "install_token": "eyJhbGciOiJIUzI1NiJ9..."
}</code></pre>
<p><strong>Response 200</strong></p>
<pre><code>{
  "data": { "activation_id": "act_a1b2c3d4e5f6a7b8", "status": "confirmed" },
  "meta": { "message": "Install confirmed" }
}</code></pre>
HTML,
                ],
                [
                    'id'    => 'slowdns-release',
                    'title' => 'Release / rollback',
                    'body'  => <<<'HTML'
<pre><code>POST /api/v2/slowdns/install/release</code></pre>
<p>Called automatically by the installer's <code>EXIT</code> trap when the install fails before confirmation. If the install token has not been used and has not expired, the install code is restored to <code>issued</code> so the operator can retry.</p>
<p><strong>Request body</strong></p>
<pre><code>{
  "activation_id": "act_a1b2c3d4e5f6a7b8"
}</code></pre>
<p><strong>Response 200</strong></p>
<pre><code>{
  "data": {
    "activation_id": "act_a1b2c3d4e5f6a7b8",
    "status": "released",
    "install_code_restored": true
  },
  "meta": { "message": "Activation released" }
}</code></pre>
HTML,
                ],
                [
                    'id'    => 'error-envelope',
                    'title' => 'Error response format',
                    'body'  => <<<'HTML'
<p>All v2 error responses use the same envelope:</p>
<pre><code>{
  "error": {
    "code": "install_code_expired",
    "message": "Install code has expired."
  }
}</code></pre>
<p>The <code>code</code> field is a machine-readable string. The <code>message</code> field is human-readable and safe to display to operators.</p>
HTML,
                ],
                [
                    'id'    => 'main-stack',
                    'title' => 'Main stack routes',
                    'body'  => <<<'HTML'
<pre><code>POST /register
POST /checkin
POST /revoke
GET  /status</code></pre>
<p>Legacy-compatible routes used by the IPTunnel installer and server agents for registration, periodic check-ins, and server revocation.</p>
HTML,
                ],
            ],
        ],
        'faq' => [
            'eyebrow' => 'Overview',
            'title'   => 'FAQ',
            'summary' => 'Common questions about install codes, DNS, service operation, and reinstalls.',
            'sections' => [
                [
                    'id'    => 'code-expired',
                    'title' => 'The code expired before I could use it',
                    'body'  => <<<'HTML'
<p>Install codes expire in <strong>5 minutes</strong> from generation. Generate a new code from <strong>/slowdns</strong> and run the installer immediately after copying the code. If you are on a slow connection, have the terminal and the panel open side by side before you generate.</p>
HTML,
                ],
                [
                    'id'    => 'code-already-used',
                    'title' => 'The code says "already used" but the install failed',
                    'body'  => <<<'HTML'
<p>The installer automatically calls the <code>release</code> endpoint on failure, which restores the code if the install token was not yet used. If you see "already used," it means either:</p>
<ul>
  <li>A previous run on the same machine did activate and confirm successfully (check <code>/opt/slowdns/config/license.json</code>).</li>
  <li>The install token expired (10 minutes) before the release call completed &mdash; the code cannot be restored in that case. Generate a new one.</li>
</ul>
HTML,
                ],
                [
                    'id'    => 'reinstall',
                    'title' => 'Can I reinstall on the same server?',
                    'body'  => <<<'HTML'
<p>Yes. Generate a new install code, then rerun the same install command. The installer is idempotent &mdash; existing SSH accounts and the SQLite database are preserved. Binaries, service files, and config are overwritten.</p>
HTML,
                ],
                [
                    'id'    => 'multiple-servers',
                    'title' => 'Can I use one code for multiple servers?',
                    'body'  => <<<'HTML'
<p>No. Each install code is single-use. Generate a separate code for each server you install on.</p>
HTML,
                ],
                [
                    'id'    => 'no-confirmation',
                    'title' => 'Install finished but I never saw "Activation confirmed"',
                    'body'  => <<<'HTML'
<p>This means the confirm step was skipped (the installer exited before calling the confirm endpoint). Common causes:</p>
<ul>
  <li>A service failed to start &mdash; check <code>systemctl status slowdns-api slowdns-dnstt --no-pager</code>.</li>
  <li>The install token expired (10-minute window exceeded &mdash; usually only on very slow VPS builds). Reinstall with a new code.</li>
</ul>
<p>The file <code>/opt/slowdns/config/license.json</code> will be missing or absent if confirmation did not complete.</p>
HTML,
                ],
                [
                    'id'    => 'client-not-connecting',
                    'title' => 'Client connects to dnstt but gets no tunnel',
                    'body'  => <<<'HTML'
<p>The most common cause is a DNS misconfiguration. Check in this order:</p>
<ol>
  <li><code>dig +short A ns1.example.com</code> &mdash; must return the VPS IPv4.</li>
  <li><code>dig +short NS slowdns.example.com</code> &mdash; must return <code>ns1.example.com</code>.</li>
  <li><code>systemctl is-active slowdns-dnstt</code> &mdash; must return <code>active</code>.</li>
  <li>Check that the client is configured with the <em>delegated tunnel domain</em> (<code>slowdns.example.com</code>), not the public host (<code>ns1.example.com</code>).</li>
</ol>
HTML,
                ],
                [
                    'id'    => 'menu',
                    'title' => 'How do I manage the server after install?',
                    'body'  => <<<'HTML'
<p>Run <code>slowdns-menu</code> (or <code>menu</code>) on the VPS for an interactive management menu with options to create/renew/delete accounts, restart services, view logs, and check runtime info including DNS records.</p>
HTML,
                ],
            ],
        ],
        'slowdns/activation-lifecycle' => [
            'eyebrow' => 'SlowDNS',
            'title'   => 'Activation Lifecycle',
            'summary' => 'What happens from the moment you generate a code to the moment the install is confirmed, including the precheck step and failure recovery path.',
            'sections' => [
                [
                    'id'    => 'overview',
                    'title' => 'The five steps',
                    'body'  => <<<'HTML'
<p>Every SlowDNS installation goes through five license-server interactions:</p>
<ol>
  <li><strong>Issue</strong> &mdash; You click Generate Code in the panel. The server creates a single-use <code>IPT-SD-...</code> code with a 5-minute TTL and returns it.</li>
  <li><strong>Precheck</strong> &mdash; The installer sends only the code plus machine identity (machine-id and SSH host fingerprint). The server validates the code without consuming it and returns a signed 15-minute precheck token.</li>
  <li><strong>Activate</strong> &mdash; After the operator confirms hostname and public IP, the installer sends the code, precheck token, machine identity, hostname, and IP. The server marks the code as consumed, increments its activation counter, and returns a signed 10-minute install token bound to that machine and configuration.</li>
  <li><strong>Confirm</strong> &mdash; After all services are verified active, the installer sends the install token back. The server marks it as used. The install is complete.</li>
  <li><strong>Release</strong> (on failure only) &mdash; If the installer exits before reaching confirm, its <code>EXIT</code> trap calls release. If the install token has not been used and has not expired, the code is restored to <code>issued</code> and the activation counter is rolled back so the operator can retry.</li>
</ol>
HTML,
                ],
                [
                    'id'    => 'token-details',
                    'title' => 'About the signed tokens',
                    'body'  => <<<'HTML'
<p>The license flow uses two signed tokens:</p>
<ul>
  <li><strong>Precheck token</strong> &mdash; issued after code validation. It contains the code, hashed machine identity, requested product, installer version, and a 15-minute expiry. The installer cannot activate without it.</li>
  <li><strong>Install token</strong> &mdash; issued after activation. It contains the activation ID, hashed machine identity, hostname, public IP, installer version, requested Git ref, and a 10-minute expiry.</li>
</ul>
<p>The install token is an HMAC-SHA256 signed structure (similar in shape to a JWT) that contains:</p>
<ul>
  <li>The activation ID (<code>sub</code>)</li>
  <li>SHA-256 hashes of the machine-id and SSH fingerprint (<code>mid</code>, <code>ssh</code>)</li>
  <li>The public IP and hostname sent at activation time</li>
  <li>The installer version and requested Git ref</li>
  <li>Issue time (<code>iat</code>), expiry time (<code>exp</code>), and a unique nonce (<code>jti</code>)</li>
</ul>
<p>The install token expires 10 minutes after activation. It can only be confirmed once &mdash; a second confirm attempt returns <code>token_used</code>.</p>
HTML,
                ],
                [
                    'id'    => 'code-states',
                    'title' => 'Install code states',
                    'body'  => <<<'HTML'
<table style="width:100%;border-collapse:collapse;font-size:14px">
  <thead>
    <tr style="border-bottom:1px solid #2a2f45;text-align:left">
      <th style="padding:8px 12px">State</th>
      <th style="padding:8px 12px">Meaning</th>
    </tr>
  </thead>
  <tbody style="color:#94a3b8">
    <tr style="border-bottom:1px solid #1e2235">
      <td style="padding:8px 12px"><code>issued</code></td>
      <td style="padding:8px 12px">Generated, not yet used, not yet expired. Ready for precheck or activate.</td>
    </tr>
    <tr style="border-bottom:1px solid #1e2235">
      <td style="padding:8px 12px"><code>consumed</code></td>
      <td style="padding:8px 12px">Activate was called. The install is in progress or already confirmed. The code cannot be reused while in this state.</td>
    </tr>
    <tr>
      <td style="padding:8px 12px"><code>expired</code></td>
      <td style="padding:8px 12px">The 5-minute window elapsed without activation. The code is permanently unusable.</td>
    </tr>
  </tbody>
</table>
<p class="note">Precheck does not change the code state. A consumed code returns to <code>issued</code> only if the release endpoint is called, the install token was never used, and the install token has not expired. The activation counter is rolled back at the same time.</p>
HTML,
                ],
                [
                    'id'    => 'max-activations',
                    'title' => 'Maximum activation attempts',
                    'body'  => <<<'HTML'
<p>Each install code has a hard limit of <strong>5 activation attempts</strong>. This prevents an attacker from activating and releasing the same code in a loop to probe the system. Failed installs that properly release the code have their counter rolled back, so a legitimate operator retrying after a genuine failure will not hit this limit in normal use.</p>
<p>Once the limit is reached, generate a new code.</p>
HTML,
                ],
            ],
        ],
        'slowdns/environment-vars' => [
            'eyebrow' => 'SlowDNS',
            'title'   => 'Environment Variables',
            'summary' => 'All SLOWDNS_* variables accepted by the installer. Set them to skip prompts and enable unattended or scripted installs.',
            'sections' => [
                [
                    'id'    => 'required',
                    'title' => 'Required for unattended install',
                    'body'  => <<<'HTML'
<table style="width:100%;border-collapse:collapse;font-size:14px">
  <thead>
    <tr style="border-bottom:1px solid #2a2f45;text-align:left">
      <th style="padding:8px 12px">Variable</th>
      <th style="padding:8px 12px">Description</th>
    </tr>
  </thead>
  <tbody style="color:#94a3b8">
    <tr style="border-bottom:1px solid #1e2235">
      <td style="padding:8px 12px"><code>SLOWDNS_INSTALL_CODE</code></td>
      <td style="padding:8px 12px">The one-time <code>IPT-SD-...</code> install code. Skips the interactive prompt.</td>
    </tr>
    <tr style="border-bottom:1px solid #1e2235">
      <td style="padding:8px 12px"><code>SLOWDNS_HOSTNAME</code></td>
      <td style="padding:8px 12px">Public hostname for the A record (e.g. <code>ns1.example.com</code>).</td>
    </tr>
    <tr style="border-bottom:1px solid #1e2235">
      <td style="padding:8px 12px"><code>SLOWDNS_TUNNEL_DOMAIN</code></td>
      <td style="padding:8px 12px">Delegated tunnel domain whose NS record points to the hostname (e.g. <code>slowdns.example.com</code>). Defaults to <code>slowdns.&lt;rest-of-hostname&gt;</code>.</td>
    </tr>
    <tr>
      <td style="padding:8px 12px"><code>SLOWDNS_PUBLIC_IP</code></td>
      <td style="padding:8px 12px">VPS public IPv4. Auto-detected via <code>api.ipify.org</code> if not set.</td>
    </tr>
  </tbody>
</table>
HTML,
                ],
                [
                    'id'    => 'optional-network',
                    'title' => 'Network and port settings',
                    'body'  => <<<'HTML'
<table style="width:100%;border-collapse:collapse;font-size:14px">
  <thead>
    <tr style="border-bottom:1px solid #2a2f45;text-align:left">
      <th style="padding:8px 12px">Variable</th>
      <th style="padding:8px 12px">Default</th>
      <th style="padding:8px 12px">Description</th>
    </tr>
  </thead>
  <tbody style="color:#94a3b8">
    <tr style="border-bottom:1px solid #1e2235">
      <td style="padding:8px 12px"><code>SLOWDNS_LISTEN_PORT</code></td>
      <td style="padding:8px 12px">5300</td>
      <td style="padding:8px 12px">UDP port dnstt listens on internally.</td>
    </tr>
    <tr style="border-bottom:1px solid #1e2235">
      <td style="padding:8px 12px"><code>SLOWDNS_PUBLIC_PORT</code></td>
      <td style="padding:8px 12px">53</td>
      <td style="padding:8px 12px">UDP port clients connect to. Usually 53.</td>
    </tr>
    <tr style="border-bottom:1px solid #1e2235">
      <td style="padding:8px 12px"><code>SLOWDNS_REDIRECT_53</code></td>
      <td style="padding:8px 12px">true (when public=53, listen port differs from 53)</td>
      <td style="padding:8px 12px">Whether to add an iptables redirect from port 53 to the listen port.</td>
    </tr>
    <tr style="border-bottom:1px solid #1e2235">
      <td style="padding:8px 12px"><code>SLOWDNS_API_BIND</code></td>
      <td style="padding:8px 12px">127.0.0.1</td>
      <td style="padding:8px 12px">Address the local API binds to.</td>
    </tr>
    <tr style="border-bottom:1px solid #1e2235">
      <td style="padding:8px 12px"><code>SLOWDNS_API_PORT</code></td>
      <td style="padding:8px 12px">8091</td>
      <td style="padding:8px 12px">Port the local API listens on.</td>
    </tr>
    <tr style="border-bottom:1px solid #1e2235">
      <td style="padding:8px 12px"><code>SLOWDNS_MTU</code></td>
      <td style="padding:8px 12px">512</td>
      <td style="padding:8px 12px">MTU passed to dnstt-server. Lower this if tunnels stall on restrictive networks.</td>
    </tr>
    <tr>
      <td style="padding:8px 12px"><code>SLOWDNS_NS_HOST</code></td>
      <td style="padding:8px 12px">(same as hostname)</td>
      <td style="padding:8px 12px">Override the NS record target if it differs from the public hostname.</td>
    </tr>
  </tbody>
</table>
HTML,
                ],
                [
                    'id'    => 'optional-build',
                    'title' => 'Build and binary overrides',
                    'body'  => <<<'HTML'
<table style="width:100%;border-collapse:collapse;font-size:14px">
  <thead>
    <tr style="border-bottom:1px solid #2a2f45;text-align:left">
      <th style="padding:8px 12px">Variable</th>
      <th style="padding:8px 12px">Description</th>
    </tr>
  </thead>
  <tbody style="color:#94a3b8">
    <tr style="border-bottom:1px solid #1e2235">
      <td style="padding:8px 12px"><code>DNSTT_SERVER_URL</code></td>
      <td style="padding:8px 12px">URL to a prebuilt <code>dnstt-server</code> binary. Skips the Go source build entirely, which is much faster on slow VPS hosts.</td>
    </tr>
    <tr style="border-bottom:1px solid #1e2235">
      <td style="padding:8px 12px"><code>DNSTT_CLIENT_URL</code></td>
      <td style="padding:8px 12px">URL to a prebuilt <code>dnstt-client</code> binary.</td>
    </tr>
    <tr style="border-bottom:1px solid #1e2235">
      <td style="padding:8px 12px"><code>SLOWDNS_LICENSE_URL</code></td>
      <td style="padding:8px 12px">Override the license server URL. Must start with <code>https://</code>. Default: <code>https://license.internetshub.com</code>.</td>
    </tr>
    <tr>
      <td style="padding:8px 12px"><code>SLOWDNS_LICENSE_KEY</code></td>
      <td style="padding:8px 12px">Alias for <code>SLOWDNS_INSTALL_CODE</code>. Both are accepted.</td>
    </tr>
  </tbody>
</table>
HTML,
                ],
            ],
        ],
        'slowdns/rate-limits' => [
            'eyebrow' => 'SlowDNS',
            'title'   => 'Rate Limits',
            'summary' => 'Public-code issuance is protected by layered limits: browser session, browser fingerprint, source IP, and machine-bound activation buckets.',
            'sections' => [
                [
                    'id'    => 'limits',
                    'title' => 'Current limits',
                    'body'  => <<<'HTML'
<table style="width:100%;border-collapse:collapse;font-size:14px">
  <thead>
    <tr style="border-bottom:1px solid #2a2f45;text-align:left">
      <th style="padding:8px 12px">Endpoint</th>
      <th style="padding:8px 12px">Limit</th>
      <th style="padding:8px 12px">Window</th>
    </tr>
  </thead>
  <tbody style="color:#94a3b8">
    <tr style="border-bottom:1px solid #1e2235">
      <td style="padding:8px 12px"><code>POST /api/v2/slowdns/code/issue</code></td>
      <td style="padding:8px 12px">3 requests</td>
      <td style="padding:8px 12px">Per IP per hour</td>
    </tr>
    <tr style="border-bottom:1px solid #1e2235">
      <td style="padding:8px 12px"><code>POST /api/v2/slowdns/code/issue</code></td>
      <td style="padding:8px 12px">10 requests</td>
      <td style="padding:8px 12px">Per IP per 24 hours</td>
    </tr>
    <tr style="border-bottom:1px solid #1e2235">
      <td style="padding:8px 12px"><code>POST /api/v2/slowdns/code/issue</code></td>
      <td style="padding:8px 12px">2 requests</td>
      <td style="padding:8px 12px">Per browser session per hour</td>
    </tr>
    <tr style="border-bottom:1px solid #1e2235">
      <td style="padding:8px 12px"><code>POST /api/v2/slowdns/code/issue</code></td>
      <td style="padding:8px 12px">6 requests</td>
      <td style="padding:8px 12px">Per browser fingerprint per 24 hours</td>
    </tr>
    <tr style="border-bottom:1px solid #1e2235">
      <td style="padding:8px 12px"><code>POST /api/v2/slowdns/install/precheck</code></td>
      <td style="padding:8px 12px">10 requests</td>
      <td style="padding:8px 12px">Per IP and per machine per 24 hours</td>
    </tr>
    <tr>
      <td style="padding:8px 12px"><code>POST /api/v2/slowdns/install/activate</code></td>
      <td style="padding:8px 12px">5 requests</td>
      <td style="padding:8px 12px">Per IP and per machine per 24 hours</td>
    </tr>
  </tbody>
</table>
<p class="note">The <code>confirm</code> and <code>release</code> endpoints are not rate-limited &mdash; they require a valid activation ID and signed token, which already act as a hard cap.</p>
HTML,
                ],
                [
                    'id'    => '429-response',
                    'title' => 'What a 429 looks like',
                    'body'  => <<<'HTML'
<p>When the limit is exceeded the server returns HTTP 429 with this body:</p>
<pre><code>{
  "error": {
    "code": "rate_limit_exceeded",
    "message": "Too many requests. Please wait before trying again."
  }
}</code></pre>
<p>The public code-issue endpoint also requires a valid browser session cookie from <code>/slowdns</code>. Even if the IP limit has not been reached, the request can still be rejected if the browser session expired or if the browser-session bucket has been exhausted.</p>
HTML,
                ],
                [
                    'id'    => 'windows',
                    'title' => 'How windows are counted',
                    'body'  => <<<'HTML'
<p>Windows are fixed UTC time buckets, not rolling windows. The hourly bucket for <code>issue_code</code> resets at each UTC hour boundary (for example 14:00, 15:00). The daily buckets for <code>issue_code</code>, <code>precheck</code>, and <code>activate</code> reset at UTC midnight. If you are right at the window boundary, the limit resets within the next minute.</p>
HTML,
                ],
            ],
        ],
    ];
}

function docs_module_page_url(string $slug): string {
    return $slug === 'index' ? '/docs' : '/docs/' . $slug;
}

function render_docs_page(string $path): never {
    $slug = $path === '/docs' ? 'index' : trim(substr($path, strlen('/docs/')), '/');
    $pages = docs_module_pages();
    if (!isset($pages[$slug])) {
        http_response_code(404);
        $slug = 'index';
    }

    $page = $pages[$slug];
    $navGroups = docs_module_nav_groups();
    ?><!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title><?= htmlspecialchars($page['title'] . ' - ' . brand('name') . ' Docs', ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></title>
<style>
:root{--bg:#0f1117;--surface:#1a1d2e;--surface-2:#141826;--border:#2a2f45;--text:#e2e8f0;--text-secondary:#94a3b8;--muted:#64748b;--blue:#63b3ed;--blue-soft:#1a2e4a;--green:#68d391}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif}
a{color:var(--blue);text-decoration:none}a:hover{text-decoration:underline}
.shell{max-width:1240px;margin:0 auto;padding:32px 20px 40px}
.top{display:flex;justify-content:space-between;align-items:center;gap:12px;margin-bottom:24px}
.brand{font-size:13px;color:var(--muted);letter-spacing:.3px}
.home-link{display:inline-block;padding:10px 14px;border:1px solid var(--border);border-radius:10px;color:var(--text);text-decoration:none}
.layout{display:grid;grid-template-columns:260px minmax(0,1fr);gap:20px}
.sidebar{position:sticky;top:24px;align-self:start;background:var(--surface);border:1px solid var(--border);border-radius:16px;padding:18px}
.sidebar-title{font-size:13px;font-weight:700;margin-bottom:14px}
.nav-group+.nav-group{margin-top:16px}
.nav-heading{font-size:11px;text-transform:uppercase;letter-spacing:1px;color:var(--muted);margin-bottom:8px}
.nav-list{display:flex;flex-direction:column;gap:4px}
.nav-link{display:block;padding:9px 10px;border-radius:10px;color:var(--text-secondary);text-decoration:none;font-size:14px;line-height:1.4}
.nav-link:hover{background:var(--surface-2);color:var(--text);text-decoration:none}
.nav-link.active{background:var(--blue-soft);color:var(--text);border:1px solid rgba(99,179,237,.25)}
.content{min-width:0}
.hero{background:var(--surface);border:1px solid var(--border);border-radius:18px;padding:28px;margin-bottom:18px}
.eyebrow{font-size:11px;font-weight:700;letter-spacing:1px;text-transform:uppercase;color:var(--muted);margin-bottom:12px}
.hero h1{margin:0 0 10px;font-size:38px;line-height:1.1}
.hero p{margin:0;color:var(--text-secondary);line-height:1.7;font-size:16px}
.article{background:var(--surface);border:1px solid var(--border);border-radius:18px;padding:28px}
.article section+section{margin-top:26px;padding-top:26px;border-top:1px solid var(--border)}
.article h2{margin:0 0 12px;font-size:24px;line-height:1.2}
.article h3{margin:18px 0 8px;font-size:16px}
.article p{margin:0 0 12px;color:var(--text-secondary);line-height:1.75}
.article ul,.article ol{margin:12px 0 0 22px;color:var(--text-secondary);line-height:1.75}
.article li+li{margin-top:8px}
pre{margin:14px 0 0;background:var(--bg);border:1px solid var(--border);border-radius:12px;padding:14px;overflow:auto;color:var(--text-secondary)}
code{font-family:'SF Mono',Consolas,monospace}
.note{font-size:13px;color:var(--muted)}
@media(max-width:980px){.layout{grid-template-columns:1fr}.sidebar{position:static}}
@media(max-width:700px){.shell{padding:24px 16px 32px}.top{flex-direction:column;align-items:flex-start}.hero h1{font-size:30px}.article,.hero,.sidebar{padding:22px}}
</style>
</head>
<body>
<div class="shell">
  <div class="top">
    <div>
      <div class="brand"><?= htmlspecialchars(brand('name'), ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?> Documentation</div>
    </div>
    <a class="home-link" href="/">Back Home</a>
  </div>
  <div class="layout">
    <aside class="sidebar">
      <div class="sidebar-title">Docs</div>
      <?php foreach ($navGroups as $groupLabel => $items): ?>
      <div class="nav-group">
        <div class="nav-heading"><?= htmlspecialchars($groupLabel, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></div>
        <div class="nav-list">
          <?php foreach ($items as $item): ?>
          <a class="nav-link<?= $item['slug'] === $slug ? ' active' : '' ?>" href="<?= htmlspecialchars(docs_module_page_url($item['slug']), ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>"><?= htmlspecialchars($item['label'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></a>
          <?php endforeach; ?>
        </div>
      </div>
      <?php endforeach; ?>
    </aside>
    <main class="content">
      <div class="hero">
        <div class="eyebrow"><?= htmlspecialchars($page['eyebrow'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></div>
        <h1><?= htmlspecialchars($page['title'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></h1>
        <p><?= htmlspecialchars($page['summary'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></p>
      </div>
      <article class="article">
        <?php foreach ($page['sections'] as $section): ?>
        <section id="<?= htmlspecialchars($section['id'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>">
          <h2><?= htmlspecialchars($section['title'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></h2>
          <?= $section['body'] ?>
        </section>
        <?php endforeach; ?>
      </article>
    </main>
  </div>
</div>
</body>
</html>
<?php
    exit;
}

if (
    ($_SERVER['REQUEST_METHOD'] ?? 'GET') === 'GET' &&
    basename((string) ($_SERVER['SCRIPT_NAME'] ?? '')) === 'docs.php'
) {
    $uri = strtok((string) ($_SERVER['REQUEST_URI'] ?? '/docs'), '?');
    $path = '/' . trim($uri ?: '/docs', '/');
    if ($path === '/' || $path === '/docs.php') {
        $path = '/docs';
    }
    render_docs_page($path);
}
