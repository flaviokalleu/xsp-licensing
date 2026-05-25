<?php
/**
 * XSP Admin Dashboard
 *
 * Env vars:
 *   ADMIN_API_BASE    ex: http://api:8443
 *   ADMIN_API_TOKEN   ADMIN_TOKEN da api-license
 *   ADMIN_DASH_USER   usuário do dashboard
 *   ADMIN_DASH_PASS   senha (bcrypt ou plaintext)
 *   INSTALL_URL       URL do install.sh público
 *   PUBLIC_HOST       domínio/IP público do install.sh
 *   API_SCHEME        http ou https
 */

declare(strict_types=1);
session_start();

function env(string $k, string $d = ''): string {
    $v = getenv($k); return ($v === false || $v === '') ? $d : $v;
}

function clean_public_host(string $host): string {
    $host = trim($host);
    $host = preg_replace('#^https?://#i', '', $host);
    $host = preg_replace('#/.*$#', '', $host);
    return preg_replace('/[^A-Za-z0-9.\-:\[\]]/', '', $host) ?? '';
}

function request_scheme(): string {
    $forwarded = strtolower(trim((string)($_SERVER['HTTP_X_FORWARDED_PROTO'] ?? '')));
    if ($forwarded === 'http' || $forwarded === 'https') {
        return $forwarded;
    }
    if (!empty($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off') {
        return 'https';
    }
    return (($_SERVER['SERVER_PORT'] ?? '') === '443') ? 'https' : 'http';
}

function normalize_install_url(string $url): string {
    $url = trim($url);
    if ($url === '' || str_contains($url, '__INSTALL_URL__') || str_contains($url, 'seudominio.com')) {
        return '';
    }
    if (!preg_match('#^https?://#i', $url)) {
        return '';
    }
    $path = (string)(parse_url($url, PHP_URL_PATH) ?: '');
    if (!str_ends_with($path, '/install.sh')) {
        $url = rtrim($url, '/') . '/install.sh';
    }
    return $url;
}

function resolve_install_url(): string {
    $fromEnv = normalize_install_url(env('INSTALL_URL', ''));
    if ($fromEnv !== '') {
        return $fromEnv;
    }

    $scheme = strtolower(env('API_SCHEME', request_scheme()));
    if ($scheme !== 'http' && $scheme !== 'https') {
        $scheme = request_scheme();
    }

    $publicHost = clean_public_host(env('PUBLIC_HOST', ''));
    if ($publicHost !== '') {
        return $scheme . '://' . $publicHost . '/install.sh';
    }

    $requestHost = clean_public_host((string)($_SERVER['HTTP_X_FORWARDED_HOST'] ?? $_SERVER['HTTP_HOST'] ?? ''));
    if (env('ACCESS_MODE', '') === 'I' || preg_match('/^([0-9]{1,3}\.){3}[0-9]{1,3}:(8080|8081|8082)$/', $requestHost)) {
        $requestHost = preg_replace('/:(8080|8081|8082)$/', '', $requestHost) ?? $requestHost;
    }
    if ($requestHost !== '') {
        return request_scheme() . '://' . $requestHost . '/install.sh';
    }

    return '';
}

$API         = env('ADMIN_API_BASE',  'http://localhost:8443');
$TOK         = env('ADMIN_API_TOKEN', '');
$USER        = env('ADMIN_DASH_USER', 'admin');
$PASS        = env('ADMIN_DASH_PASS', 'admin');
$INSTALL_URL = resolve_install_url();

/* ---------- auth ---------- */
function check_pw(string $given, string $stored): bool {
    if (str_starts_with($stored, '$2y$') || str_starts_with($stored, '$argon')) {
        return password_verify($given, $stored);
    }
    return hash_equals($stored, $given);
}

if (($_POST['action'] ?? '') === 'login') {
    if (($_POST['user'] ?? '') === $USER && check_pw($_POST['pass'] ?? '', $PASS)) {
        $_SESSION['ok'] = true;
        header('Location: ?'); exit;
    }
    $loginErr = 'Credenciais inválidas';
}
if (($_GET['action'] ?? '') === 'logout') {
    session_destroy(); header('Location: ?'); exit;
}
$logged = !empty($_SESSION['ok']);

/* ---------- API client ---------- */
function api(string $method, string $path, array $body = null): array {
    global $API, $TOK;
    $ch = curl_init($API . $path);
    curl_setopt_array($ch, [
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_CUSTOMREQUEST  => $method,
        CURLOPT_HTTPHEADER     => [
            'Authorization: Bearer ' . $TOK,
            'Content-Type: application/json',
        ],
        CURLOPT_TIMEOUT => 10,
    ]);
    if ($body !== null) {
        curl_setopt($ch, CURLOPT_POSTFIELDS, json_encode($body, JSON_UNESCAPED_UNICODE));
    }
    $r = curl_exec($ch);
    $c = curl_getinfo($ch, CURLINFO_HTTP_CODE);
    curl_close($ch);
    return ['code' => $c, 'body' => json_decode((string)$r, true) ?: ['raw' => $r]];
}

/* ---------- JSON endpoint for installations ---------- */
if ($logged && ($_GET['ajax'] ?? '') === 'installations') {
    $lid = preg_replace('/[^a-f0-9\-]/', '', $_GET['lid'] ?? '');
    $r   = api('GET', '/admin/keys/' . $lid . '/installations');
    header('Content-Type: application/json');
    echo json_encode($r['body']);
    exit;
}

/* ---------- actions ---------- */
$flash  = null;
$newKey = null;
$newEmail = '';
$newDomain = '';

if ($logged && ($_POST['action'] ?? '') === 'create_key') {
    $newEmail = trim($_POST['email'] ?? '');
    $newDomain = trim($_POST['domain'] ?? '');
    if ($newEmail === '') {
        $newEmail = 'admin-' . bin2hex(random_bytes(4)) . '@xsp.local';
    }
    $r = api('POST', '/admin/keys', [
        'email'         => $newEmail,
        'name'          => trim($_POST['name']   ?? ''),
        'plan_code'     => $_POST['plan']        ?? 'basic',
        'period_days'   => (int)($_POST['days']  ?? 30),
        'max_instances' => (int)($_POST['max_instances'] ?? 1),
    ]);
    if ($r['code'] === 201) {
        $newKey = $r['body']['key'] ?? '';
        $flash  = ['ok', 'KEY criada com sucesso!'];
    } else {
        $flash = ['err', json_encode($r['body'])];
    }
}

if ($logged && ($_POST['action'] ?? '') === 'revoke') {
    $r = api('PATCH', '/admin/keys/' . ($_POST['id'] ?? ''),
        ['status' => 'revoked', 'reason' => $_POST['reason'] ?? 'admin']);
    $flash = $r['code'] < 300 ? ['ok', 'KEY revogada.'] : ['err', json_encode($r['body'])];
}

if ($logged && ($_POST['action'] ?? '') === 'extend') {
    $days = max(1, (int)($_POST['days'] ?? 30));
    $r = api('PATCH', '/admin/keys/' . ($_POST['id'] ?? ''),
        ['extend_days' => $days]);
    $flash = $r['code'] < 300
        ? ['ok', "Validade estendida em {$days} dia(s)."]
        : ['err', json_encode($r['body'])];
}

if ($logged && ($_POST['action'] ?? '') === 'blacklist') {
    $r = api('POST', '/admin/blacklist', [
        'kind'   => $_POST['kind']   ?? '',
        'value'  => $_POST['value']  ?? '',
        'reason' => $_POST['reason'] ?? '',
    ]);
    $flash = $r['code'] < 300 ? ['ok', 'Bloqueado.'] : ['err', json_encode($r['body'])];
}

if ($logged && ($_POST['action'] ?? '') === 'deactivate_install') {
    $iid = preg_replace('/[^a-f0-9\-]/', '', $_POST['install_id'] ?? '');
    $r   = api('DELETE', '/admin/installations/' . $iid);
    $flash = $r['code'] < 300 ? ['ok', 'Instalação desativada.'] : ['err', json_encode($r['body'])];
}

$licenses = [];
if ($logged) {
    $r = api('GET', '/admin/keys?limit=500&offset=0');
    if ($r['code'] === 200) $licenses = $r['body']['items'] ?? [];
}

/* ---------- stats ---------- */
$stats = ['total' => 0, 'active' => 0, 'expired' => 0, 'revoked' => 0, 'trial' => 0];
foreach ($licenses as $l) {
    $stats['total']++;
    $s = $l['status'] ?? '';
    if ($s === 'active')   $stats['active']++;
    if ($s === 'expired')  $stats['expired']++;
    if ($s === 'revoked')  $stats['revoked']++;
    if (($l['plan_code'] ?? '') === 'trial') $stats['trial']++;
}

/* ---------- helpers ---------- */
function installCmd(string $key, string $url, string $domain = '', string $email = ''): string {
    if (!$url) return '';
    $cmd = 'curl -sSL ' . escapeshellarg($url)
        . ' | sudo bash -s -- ' . escapeshellarg($key);
    if ($domain !== '') {
        $cmd .= ' ' . escapeshellarg($domain);
    }
    if ($email !== '') {
        $cmd .= ' ' . escapeshellarg($email);
    }
    return $cmd;
}
function installFullCmd(string $key, string $url, string $domain = 'DOMINIO_OU_IP', string $email = 'email@cliente.com'): string {
    return installCmd($key, $url, $domain, $email);
}
function statusCmd(string $url): string {
    return $url ? 'curl -sSL ' . escapeshellarg($url) . ' | sudo bash -s -- --status' : '';
}
function updateCmd(string $url): string {
    return $url ? 'curl -sSL ' . escapeshellarg($url) . ' | sudo bash -s -- --update' : '';
}
function uninstallCmd(): string {
    return 'sudo bash /opt/xsp/uninstall.sh';
}
function commandList(string $key, string $url, string $domain = 'DOMINIO_OU_IP', string $email = 'email@cliente.com'): array {
    return [
        'install-full' => ['Instalar completo', installFullCmd($key, $url, $domain, $email)],
        'install-key'  => ['Instalar so com KEY', installCmd($key, $url)],
        'status'       => ['Status', statusCmd($url)],
        'update'       => ['Atualizar', updateCmd($url)],
        'remove'       => ['Remover', uninstallCmd()],
    ];
}
function h(string $s): string { return htmlspecialchars($s, ENT_QUOTES, 'UTF-8'); }
?>
<!doctype html>
<html lang="pt-br">
<head>
<meta charset="utf-8">
<title>XSP Admin</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
:root {
    --bg:#0b1020; --fg:#e6edf3; --mut:#7d8590;
    --accent:#3fb950; --danger:#f85149; --warn:#d29922;
    --card:#161b22; --border:#30363d; --hl:#1c2333;
    --modal-bg:rgba(0,0,0,.7);
}
* { box-sizing:border-box; margin:0; padding:0; }
body { background:var(--bg); color:var(--fg);
       font-family:system-ui,-apple-system,sans-serif;
       padding:24px; max-width:1500px; margin:auto; }
h1,h2,h3 { margin-bottom:16px; }
header { display:flex; justify-content:space-between; align-items:center; margin-bottom:28px; }
.btn { background:var(--accent); border:none; color:#0b1020;
       padding:8px 14px; border-radius:6px; cursor:pointer; font-weight:600; font-size:13px; }
.btn.danger  { background:var(--danger); color:#fff; }
.btn.ghost   { background:transparent; color:var(--fg); border:1px solid var(--border); }
.btn.copy    { background:#21262d; color:var(--fg); border:1px solid var(--border);
               font-size:12px; padding:4px 10px; }
.btn.sm      { padding:4px 10px; font-size:12px; }
.card { background:var(--card); border:1px solid var(--border);
        border-radius:8px; padding:18px; margin-bottom:16px; }
.card.highlight { border-color:var(--accent); }
.row { display:flex; gap:10px; flex-wrap:wrap; }
.row > * { flex:1; min-width:130px; }
input, select { background:#0d1117; color:var(--fg); border:1px solid var(--border);
                padding:8px; border-radius:6px; width:100%; font-size:13px; }
input:focus, select:focus { outline:none; border-color:var(--accent); }

/* ── Stats cards ── */
.stats { display:grid; grid-template-columns:repeat(auto-fit,minmax(140px,1fr)); gap:12px; margin-bottom:20px; }
.stat { background:var(--card); border:1px solid var(--border); border-radius:8px;
        padding:16px; text-align:center; }
.stat .num { font-size:28px; font-weight:700; line-height:1; margin-bottom:4px; }
.stat .lbl { font-size:11px; color:var(--mut); text-transform:uppercase; letter-spacing:.5px; }
.stat.s-active  .num { color:var(--accent); }
.stat.s-expired .num { color:var(--warn); }
.stat.s-revoked .num { color:var(--danger); }

/* ── Table ── */
table { width:100%; border-collapse:collapse; font-size:13px; }
th, td { padding:9px 10px; border-bottom:1px solid var(--border); text-align:left; vertical-align:middle; }
th { background:#0d1117; color:var(--mut); font-weight:600; font-size:11px;
     text-transform:uppercase; letter-spacing:.5px; white-space:nowrap; }
tr.inst-row td { background:#111827; font-size:12px; padding:0; }
tr.inst-row td > div { padding:10px 14px; }
code { background:#0d1117; padding:2px 6px; border-radius:4px; font-size:12px; }
.badge { display:inline-block; padding:2px 8px; border-radius:999px;
         font-size:11px; font-weight:600; text-transform:uppercase; }
.badge.active     { background:#1f6f3f; color:#d3ffd3; }
.badge.expired    { background:#754200; color:#ffe1b2; }
.badge.revoked    { background:#6e1e1e; color:#ffd2d2; }
.badge.suspended  { background:#3a3a3a; color:#ccc; }
.badge.deactivated{ background:#3a3a3a; color:#999; }
.flash.ok  { background:#1f6f3f; color:#d3ffd3; padding:10px 14px;
             border-radius:6px; margin-bottom:16px; }
.flash.err { background:#6e1e1e; color:#ffd2d2; padding:10px 14px;
             border-radius:6px; margin-bottom:16px; }
.muted { color:var(--mut); font-size:12px; }
form.inline { display:inline; }

.install-box { background:#0d1117; border:1px solid var(--accent);
    border-radius:6px; padding:12px 14px; font-family:monospace; font-size:13px;
    word-break:break-all; }
.install-box-sm { background:#0d1117; border:1px solid var(--border);
    border-radius:4px; padding:5px 9px; font-family:monospace; font-size:11px;
    word-break:break-all; max-width:460px; }
.copy-row { display:flex; align-items:flex-start; gap:8px; }
.copy-row .install-box { flex:1; }
.copied { color:var(--accent); font-size:11px; }
.command-list { display:grid; gap:10px; margin-top:12px; }
.command-item { display:grid; gap:5px; }
.command-label { color:var(--mut); font-size:11px; text-transform:uppercase; letter-spacing:.4px; }
.cmd-details summary { cursor:pointer; color:var(--accent); font-weight:600; }
.cmd-details[open] summary { margin-bottom:8px; }
.cmd-details .command-list { min-width:420px; }

/* ── Filters ── */
.filters { display:flex; gap:8px; flex-wrap:wrap; margin-bottom:12px; align-items:center; }
.filters input, .filters select { flex:1; min-width:150px; max-width:240px; }
.filters label { font-size:12px; color:var(--mut); margin-right:-4px; }

/* ── Expand toggle ── */
.expand-btn { background:none; border:none; color:var(--accent); cursor:pointer;
              font-size:16px; line-height:1; padding:0 4px; }

/* ── Modal ── */
.modal-overlay { display:none; position:fixed; inset:0; background:var(--modal-bg);
                 z-index:1000; justify-content:center; align-items:center; }
.modal-overlay.open { display:flex; }
.modal { background:var(--card); border:1px solid var(--border); border-radius:10px;
         padding:24px; width:360px; max-width:96vw; }
.modal h3 { margin-bottom:16px; }
.modal .row { margin-bottom:12px; }
.modal-actions { display:flex; gap:8px; justify-content:flex-end; margin-top:16px; }

/* ── Inst mini-table ── */
.inst-table { width:100%; border-collapse:collapse; font-size:12px; }
.inst-table th { background:#0d1117; color:var(--mut); padding:5px 8px; font-size:10px;
                 text-transform:uppercase; letter-spacing:.4px; }
.inst-table td { padding:5px 8px; border-bottom:1px solid #1e2535; vertical-align:middle; }
.online  { color:var(--accent); }
.offline { color:var(--mut); }
</style>
</head>
<body>

<?php if (!$logged): ?>
<div class="card" style="max-width:380px;margin:80px auto;">
  <h1>XSP Admin</h1>
  <?php if (!empty($loginErr)): ?>
    <div class="flash err"><?= h($loginErr) ?></div>
  <?php endif; ?>
  <form method="post">
    <input type="hidden" name="action" value="login">
    <p style="margin-bottom:10px"><input type="text"     name="user" placeholder="usuário" required autofocus></p>
    <p style="margin-bottom:14px"><input type="password" name="pass" placeholder="senha"   required></p>
    <button class="btn" type="submit">Entrar</button>
  </form>
</div>

<?php else: ?>

<header>
  <h1>XSP Admin</h1>
  <a class="btn ghost" href="?action=logout">Sair</a>
</header>

<?php if ($flash): ?>
  <div class="flash <?= $flash[0] ?>"><?= h((string)$flash[1]) ?></div>
<?php endif; ?>

<!-- ── Stats ── -->
<div class="stats">
  <div class="stat">
    <div class="num"><?= $stats['total'] ?></div>
    <div class="lbl">Total</div>
  </div>
  <div class="stat s-active">
    <div class="num"><?= $stats['active'] ?></div>
    <div class="lbl">Ativas</div>
  </div>
  <div class="stat s-expired">
    <div class="num"><?= $stats['expired'] ?></div>
    <div class="lbl">Expiradas</div>
  </div>
  <div class="stat s-revoked">
    <div class="num"><?= $stats['revoked'] ?></div>
    <div class="lbl">Revogadas</div>
  </div>
  <div class="stat">
    <div class="num"><?= $stats['trial'] ?></div>
    <div class="lbl">Trial</div>
  </div>
</div>

<!-- Instalador publico -->
<?php if ($INSTALL_URL): ?>
<div class="card">
  <h2>Instalador publico</h2>
  <p class="muted">O painel admin vai usar este dominio/IP para montar os comandos:</p>
  <code><?= h($INSTALL_URL) ?></code>
</div>
<?php endif; ?>

<?php if ($newKey && $INSTALL_URL): ?>
<div class="card highlight">
  <h2>KEY gerada — envie este comando ao cliente</h2>
  <p style="margin-bottom:10px">Informe o domínio/IP da VPS do cliente e confirme o e-mail antes de copiar:</p>
  <div class="row" style="margin-bottom:10px">
    <input id="new-domain" type="text" value="<?= h($newDomain) ?>" placeholder="dominio.com ou IP publico" oninput="updateInstallCommand('new')">
    <input id="new-email" type="email" value="<?= h($newEmail) ?>" placeholder="cliente@exemplo.com" oninput="updateInstallCommand('new')">
  </div>
  <div class="copy-row">
    <div class="install-box" id="newcmd"
         data-url="<?= h($INSTALL_URL) ?>"
         data-key="<?= h($newKey) ?>"><?= h(installFullCmd($newKey, $INSTALL_URL, $newDomain ?: 'DOMINIO_OU_IP', $newEmail ?: 'email@cliente.com')) ?></div>
    <button class="btn" onclick="copyText('newcmd','newcmd-ok')">Copiar</button>
  </div>
  <span class="copied" id="newcmd-ok" style="display:none">✓ Copiado!</span>
  <div class="command-list">
    <?php foreach ([
        'newcmd-key' => ['Instalar so com KEY', installCmd($newKey, $INSTALL_URL)],
        'newcmd-status' => ['Status', statusCmd($INSTALL_URL)],
        'newcmd-update' => ['Atualizar', updateCmd($INSTALL_URL)],
        'newcmd-remove' => ['Remover', uninstallCmd()],
    ] as $cmdId => $item): ?>
    <div class="command-item">
      <div class="command-label"><?= h($item[0]) ?></div>
      <div class="copy-row">
        <div class="install-box" id="<?= h($cmdId) ?>"><?= h($item[1]) ?></div>
        <button class="btn" onclick="copyText('<?= h($cmdId) ?>','<?= h($cmdId) ?>-ok')">Copiar</button>
      </div>
      <span class="copied" id="<?= h($cmdId) ?>-ok" style="display:none">Copiado!</span>
    </div>
    <?php endforeach; ?>
  </div>
  <p class="muted" style="margin-top:10px">KEY: <strong><?= h($newKey) ?></strong></p>
  <p class="muted">Install URL: <code><?= h($INSTALL_URL) ?></code></p>
</div>
<?php elseif ($newKey): ?>
<div class="card highlight">
  <h2>KEY gerada</h2>
  <code><?= h($newKey) ?></code>
  <p class="muted">Configure INSTALL_URL no .env para ver o comando completo.</p>
</div>
<?php endif; ?>

<!-- ── Criar nova KEY ── -->
<div class="card">
  <h2>Criar nova licença</h2>
  <form method="post">
    <input type="hidden" name="action" value="create_key">
    <div class="row" style="margin-bottom:8px">
      <input type="text"   name="domain" placeholder="dominio.com ou IP publico">
      <input type="email"  name="email" placeholder="cliente@exemplo.com (opcional)">
      <input type="text"   name="name"  placeholder="Nome do cliente">
      <select name="plan">
        <option value="trial">Trial (7 dias)</option>
        <option value="basic" selected>Básico</option>
        <option value="pro">Profissional</option>
        <option value="enterprise">Enterprise</option>
      </select>
      <input type="number" name="days" value="30" min="1" max="730" placeholder="Dias">
      <select name="max_instances">
        <option value="1" selected>1 instalação</option>
        <option value="2">2 instalações</option>
        <option value="5">5 instalações</option>
        <option value="10">10 instalações</option>
      </select>
      <button class="btn" type="submit">Gerar KEY</button>
    </div>
  </form>
</div>

<!-- ── Lista de licenças ── -->
<div class="card">
  <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:12px">
    <h2 style="margin:0">Licenças</h2>
    <span class="muted" id="visible-count"></span>
  </div>

  <!-- Filtros -->
  <div class="filters">
    <input id="f-search" type="search" placeholder="Buscar KEY, email, nome…" oninput="filterTable()">
    <select id="f-status" onchange="filterTable()">
      <option value="">Todos os status</option>
      <option value="active">Ativas</option>
      <option value="expired">Expiradas</option>
      <option value="revoked">Revogadas</option>
      <option value="suspended">Suspensas</option>
    </select>
    <select id="f-plan" onchange="filterTable()">
      <option value="">Todos os planos</option>
      <option value="trial">Trial</option>
      <option value="basic">Básico</option>
      <option value="pro">Pro</option>
      <option value="enterprise">Enterprise</option>
    </select>
  </div>

  <div style="overflow-x:auto">
  <table id="lic-table">
    <thead>
      <tr>
        <th></th>
        <th>KEY</th>
        <th>Cliente</th>
        <th>Plano</th>
        <th>Status</th>
        <th>Expira</th>
        <th>Inst.</th>
        <?php if ($INSTALL_URL): ?><th>Comando</th><?php endif; ?>
        <th>Ações</th>
      </tr>
    </thead>
    <tbody>
    <?php foreach ($licenses as $i => $l):
        $key    = (string)($l['key']      ?? '???');
        $keyId  = (string)($l['id']       ?? '');
        $status = (string)($l['status']   ?? '');
        $email  = (string)($l['customer_email'] ?? $l['email'] ?? '');
        $name   = (string)($l['customer_name']  ?? '');
        $plan   = (string)($l['plan_code'] ?? '');
        $maxI   = (int)($l['max_instances'] ?? 1);
        $exp    = (string)($l['expires_at'] ?? '');
        $expD   = $exp ? max(0, (int)(((int)strtotime($exp) - time()) / 86400)) : 0;
        $cmds   = ($INSTALL_URL && $status === 'active') ? commandList($key, $INSTALL_URL, 'DOMINIO_OU_IP', $email ?: 'email@cliente.com') : [];
        $cmd    = $cmds['install-full'][1] ?? '';
        $cid    = 'cmd'.$i;
        $rid    = 'row'.$i;
        $iid    = 'inst'.$i;
        $search = strtolower($key.' '.$email.' '.$name.' '.$status.' '.$plan);
    ?>
      <tr id="<?= $rid ?>" data-search="<?= h($search) ?>" data-status="<?= h($status) ?>" data-plan="<?= h($plan) ?>">
        <td>
          <button class="expand-btn" title="Ver instalações"
                  onclick="toggleInst('<?= $iid ?>','<?= h($keyId) ?>',this)">▶</button>
        </td>
        <td><code><?= h($key) ?></code></td>
        <td>
          <?= h($email) ?>
          <?php if ($name): ?><div class="muted"><?= h($name) ?></div><?php endif; ?>
        </td>
        <td><?= h($plan) ?></td>
        <td><span class="badge <?= h($status) ?>"><?= h($status) ?></span></td>
        <td>
          <?= h(substr($exp, 0, 10)) ?>
          <?php if ($status === 'active'): ?>
            <div class="muted"><?= $expD ?> dias</div>
          <?php endif; ?>
        </td>
        <td style="text-align:center"><?= $maxI ?></td>

        <?php if ($INSTALL_URL): ?>
        <td>
          <?php if ($cmd): ?>
          <details class="cmd-details">
            <summary>Ver comandos</summary>
            <div class="command-list">
              <div class="command-item">
                <div class="command-label">Instalar completo</div>
          <div style="display:flex;align-items:center;gap:5px;">
            <div class="install-box-sm" id="<?= $cid ?>"><?= h($cmd) ?></div>
            <button class="btn copy" onclick="copyText('<?= $cid ?>','<?= $cid ?>-ok')">Copiar</button>
          </div>
          <span class="copied" id="<?= $cid ?>-ok" style="display:none">✓</span>
              </div>
          <?php foreach ($cmds as $slug => $item):
              if ($slug === 'install-full') continue;
              $cmdId = $cid . '-' . $slug;
          ?>
          <div style="display:flex;align-items:center;gap:5px;margin-top:6px;">
            <span class="command-label" style="min-width:92px"><?= h($item[0]) ?></span>
            <div class="install-box-sm" id="<?= h($cmdId) ?>"><?= h($item[1]) ?></div>
            <button class="btn copy" onclick="copyText('<?= h($cmdId) ?>','<?= h($cmdId) ?>-ok')">Copiar</button>
          </div>
          <span class="copied" id="<?= h($cmdId) ?>-ok" style="display:none">OK</span>
          <?php endforeach; ?>
            </div>
          </details>
          <?php else: ?><span class="muted">—</span><?php endif; ?>
        </td>
        <?php endif; ?>

        <td style="white-space:nowrap">
          <?php if ($status === 'active'): ?>
          <form class="inline" method="post" onsubmit="return confirm('Revogar esta KEY?');">
            <input type="hidden" name="action" value="revoke">
            <input type="hidden" name="id"     value="<?= h($keyId) ?>">
            <input type="hidden" name="reason" value="admin">
            <button class="btn danger sm" type="submit">Revogar</button>
          </form>
          <button class="btn ghost sm" onclick="openExtend('<?= h($keyId) ?>')">Estender</button>
          <?php endif; ?>
        </td>
      </tr>
      <tr class="inst-row" id="<?= $iid ?>" style="display:none">
        <td colspan="<?= $INSTALL_URL ? 9 : 8 ?>">
          <div id="<?= $iid ?>-content"><span class="muted" style="padding:8px;display:block">Carregando…</span></div>
        </td>
      </tr>
    <?php endforeach; ?>
    </tbody>
  </table>
  </div>
</div>

<!-- ── Blacklist ── -->
<div class="card">
  <h2>Blacklist</h2>
  <form method="post">
    <input type="hidden" name="action" value="blacklist">
    <div class="row">
      <select name="kind">
        <option value="hwid">HWID</option>
        <option value="ip">IP</option>
        <option value="cidr">CIDR</option>
        <option value="key">KEY</option>
        <option value="email">E-mail</option>
      </select>
      <input type="text" name="value"  placeholder="valor (ex: 192.168.0.0/24)" required>
      <input type="text" name="reason" placeholder="motivo">
      <button class="btn danger" type="submit">Bloquear</button>
    </div>
  </form>
</div>

<?php if (!$INSTALL_URL): ?>
<div class="card" style="border-color:#754200;">
  <p class="muted">⚠ <strong>INSTALL_URL</strong> não configurado — os comandos de instalação não aparecerão.
  Verifique o <code>.env</code> no servidor.</p>
</div>
<?php endif; ?>

<p class="muted" style="margin-top:8px">XSP Admin · API: <?= h($API) ?></p>

<!-- ── Modal: estender validade ── -->
<div class="modal-overlay" id="extend-modal">
  <div class="modal">
    <h3>Estender validade</h3>
    <form method="post" id="extend-form">
      <input type="hidden" name="action" value="extend">
      <input type="hidden" name="id"     id="extend-id">
      <div class="row">
        <div>
          <label style="font-size:12px;color:var(--mut)">Dias a adicionar</label>
          <input type="number" name="days" id="extend-days" value="30" min="1" max="730" required style="margin-top:4px">
        </div>
      </div>
      <div class="modal-actions">
        <button type="button" class="btn ghost" onclick="closeExtend()">Cancelar</button>
        <button type="submit" class="btn">Confirmar</button>
      </div>
    </form>
  </div>
</div>

<script>
/* ── copy ── */
function copyText(srcId, okId) {
    const text = document.getElementById(srcId).textContent.trim();
    navigator.clipboard.writeText(text).then(() => {
        const el = document.getElementById(okId);
        el.style.display = 'inline';
        setTimeout(() => el.style.display = 'none', 2000);
    });
}

/* ── install command ── */
function shellArg(value) {
    value = String(value || '').trim();
    return "'" + value.replace(/'/g, "'\"'\"'") + "'";
}

function updateInstallCommand(prefix) {
    const box = document.getElementById(prefix + 'cmd');
    if (!box) return;
    const domain = document.getElementById(prefix + '-domain')?.value.trim() || 'DOMINIO_OU_IP';
    const email = document.getElementById(prefix + '-email')?.value.trim() || 'email@cliente.com';
    box.textContent = 'curl -sSL ' + shellArg(box.dataset.url)
        + ' | sudo bash -s -- ' + shellArg(box.dataset.key)
        + ' ' + shellArg(domain)
        + ' ' + shellArg(email);
}
updateInstallCommand('new');

/* ── extend modal ── */
function openExtend(id) {
    document.getElementById('extend-id').value = id;
    document.getElementById('extend-days').value = 30;
    document.getElementById('extend-modal').classList.add('open');
    document.getElementById('extend-days').focus();
}
function closeExtend() {
    document.getElementById('extend-modal').classList.remove('open');
}
document.getElementById('extend-modal').addEventListener('click', function(e) {
    if (e.target === this) closeExtend();
});

/* ── filter ── */
function filterTable() {
    const q     = document.getElementById('f-search').value.toLowerCase();
    const fSt   = document.getElementById('f-status').value;
    const fPl   = document.getElementById('f-plan').value;
    const rows  = document.querySelectorAll('#lic-table tbody tr:not(.inst-row)');
    let vis = 0;
    rows.forEach(tr => {
        const ok = (!q   || tr.dataset.search.includes(q))
                && (!fSt || tr.dataset.status === fSt)
                && (!fPl || tr.dataset.plan   === fPl);
        tr.style.display = ok ? '' : 'none';
        // hide the paired inst-row too
        const inst = tr.nextElementSibling;
        if (inst && inst.classList.contains('inst-row') && !ok) inst.style.display = 'none';
        if (ok) vis++;
    });
    document.getElementById('visible-count').textContent = vis + ' licença(s)';
}
filterTable();

/* ── expand installations ── */
const instCache = {};
async function toggleInst(iid, lid, btn) {
    const row     = document.getElementById(iid);
    const content = document.getElementById(iid + '-content');
    const open    = row.style.display !== 'none';
    if (open) {
        row.style.display = 'none';
        btn.textContent = '▶';
        return;
    }
    row.style.display = '';
    btn.textContent = '▼';
    if (instCache[lid]) { content.innerHTML = instCache[lid]; return; }
    try {
        const res  = await fetch('?ajax=installations&lid=' + encodeURIComponent(lid));
        const data = await res.json();
        const items = data.items || data || [];
        if (!items.length) {
            content.innerHTML = '<span class="muted" style="padding:8px;display:block">Nenhuma instalação ativa.</span>';
            instCache[lid] = content.innerHTML;
            return;
        }
        let html = '<table class="inst-table"><thead><tr>'
            + '<th>ID</th><th>Hostname</th><th>IP</th><th>Domínio</th>'
            + '<th>OS</th><th>Versão painel</th><th>Status</th>'
            + '<th>Ativado</th><th>Último ping</th><th></th>'
            + '</tr></thead><tbody>';
        const now = Date.now();
        items.forEach(inst => {
            const lastSeen  = new Date(inst.last_seen_at).getTime();
            const online    = (now - lastSeen) < 10 * 60 * 1000;
            const ping      = timeSince(inst.last_seen_at);
            const activated = inst.activated_at ? inst.activated_at.slice(0,10) : '—';
            const statusBadge = `<span class="badge ${inst.status}">${inst.status}</span>`;
            const deactBtn = inst.status === 'active'
                ? `<form method="post" style="display:inline" onsubmit="return confirm('Desativar esta instalação?')">
                     <input type="hidden" name="action"     value="deactivate_install">
                     <input type="hidden" name="install_id" value="${inst.id}">
                     <button class="btn danger sm" type="submit">Desativar</button>
                   </form>` : '';
            html += `<tr>
                <td><code style="font-size:10px">${inst.id.slice(0,8)}…</code></td>
                <td>${esc(inst.hostname)}</td>
                <td>${esc(inst.public_ip)}</td>
                <td>${esc(inst.domain)}</td>
                <td>${esc(inst.os)}</td>
                <td>${esc(inst.panel_version)}</td>
                <td>${statusBadge}</td>
                <td>${activated}</td>
                <td class="${online ? 'online' : 'offline'}" title="${esc(inst.last_seen_at)}">${ping}</td>
                <td>${deactBtn}</td>
            </tr>`;
        });
        html += '</tbody></table>';
        instCache[lid] = html;
        content.innerHTML = html;
    } catch(e) {
        content.innerHTML = `<span class="muted" style="padding:8px;display:block">Erro ao carregar instalações.</span>`;
    }
}

function esc(s) {
    const d = document.createElement('div');
    d.textContent = s || '—';
    return d.innerHTML;
}

function timeSince(iso) {
    if (!iso) return '—';
    const sec = Math.floor((Date.now() - new Date(iso).getTime()) / 1000);
    if (sec < 60)   return sec + 's atrás';
    if (sec < 3600) return Math.floor(sec/60) + 'min atrás';
    if (sec < 86400)return Math.floor(sec/3600) + 'h atrás';
    return Math.floor(sec/86400) + 'd atrás';
}
</script>

<?php endif; ?>
</body>
</html>
