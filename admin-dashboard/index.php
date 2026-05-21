<?php
/**
 * XSP Admin Dashboard — painel para gerenciar licenças.
 *
 * Variáveis de ambiente:
 *   ADMIN_API_BASE    ex: http://api:8443
 *   ADMIN_API_TOKEN   mesmo ADMIN_TOKEN da api-license
 *   ADMIN_DASH_USER   usuário do dashboard
 *   ADMIN_DASH_PASS   senha (bcrypt ou plaintext)
 *   INSTALL_URL       URL do install.sh público (ex: https://painel.dom.com/install.sh)
 */

declare(strict_types=1);
session_start();

function env(string $k, string $d = ''): string {
    $v = getenv($k); return ($v === false || $v === '') ? $d : $v;
}

$API         = env('ADMIN_API_BASE',  'http://localhost:8443');
$TOK         = env('ADMIN_API_TOKEN', '');
$USER        = env('ADMIN_DASH_USER', 'admin');
$PASS        = env('ADMIN_DASH_PASS', 'admin');
$INSTALL_URL = env('INSTALL_URL',     '');

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

/* ---------- actions ---------- */
$flash  = null;
$newKey = null;   // KEY gerada nesta requisição (para mostrar o comando)

if ($logged && ($_POST['action'] ?? '') === 'create_key') {
    $r = api('POST', '/admin/keys', [
        'email'       => trim($_POST['email']  ?? ''),
        'name'        => trim($_POST['name']   ?? ''),
        'plan_code'   => $_POST['plan']        ?? 'basic',
        'period_days' => (int)($_POST['days']  ?? 30),
        'max_instances' => 1,   // uso único por padrão
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
    $r = api('PATCH', '/admin/keys/' . ($_POST['id'] ?? ''),
        ['extend_days' => (int)($_POST['days'] ?? 30)]);
    $flash = $r['code'] < 300 ? ['ok', 'Validade estendida.'] : ['err', json_encode($r['body'])];
}

if ($logged && ($_POST['action'] ?? '') === 'blacklist') {
    $r = api('POST', '/admin/blacklist', [
        'kind'   => $_POST['kind']   ?? '',
        'value'  => $_POST['value']  ?? '',
        'reason' => $_POST['reason'] ?? '',
    ]);
    $flash = $r['code'] < 300 ? ['ok', 'Bloqueado.'] : ['err', json_encode($r['body'])];
}

$licenses = [];
if ($logged) {
    $r = api('GET', '/admin/keys?limit=100&offset=0');
    if ($r['code'] === 200) $licenses = $r['body']['items'] ?? [];
}

/* ---------- helpers ---------- */
function installCmd(string $key, string $url): string {
    if (!$url) return '';
    return "curl -sSL {$url} | sudo bash -s -- {$key}";
}
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
    --accent:#3fb950; --danger:#f85149;
    --card:#161b22; --border:#30363d; --hl:#1c2333;
}
* { box-sizing:border-box; }
body { background:var(--bg); color:var(--fg);
       font-family:system-ui,-apple-system,sans-serif;
       margin:0; padding:24px; max-width:1400px; margin:auto; }
h1,h2 { margin:0 0 16px; }
header { display:flex; justify-content:space-between; align-items:center; margin-bottom:24px; }
.btn { background:var(--accent); border:none; color:#0b1020;
       padding:8px 14px; border-radius:6px; cursor:pointer; font-weight:600; }
.btn.danger { background:var(--danger); color:#fff; }
.btn.ghost  { background:transparent; color:var(--fg); border:1px solid var(--border); }
.btn.copy   { background:#21262d; color:var(--fg); border:1px solid var(--border);
               font-size:12px; padding:4px 10px; }
.card { background:var(--card); border:1px solid var(--border);
        border-radius:8px; padding:18px; margin-bottom:16px; }
.card.highlight { border-color:var(--accent); }
.row { display:flex; gap:10px; flex-wrap:wrap; }
.row > * { flex:1; min-width:140px; }
input, select { background:#0d1117; color:var(--fg); border:1px solid var(--border);
                padding:8px; border-radius:6px; width:100%; }
table { width:100%; border-collapse:collapse; font-size:13px; }
th, td { padding:8px 10px; border-bottom:1px solid var(--border); text-align:left; vertical-align:middle; }
th { background:#0d1117; color:var(--mut); font-weight:600; font-size:11px;
     text-transform:uppercase; letter-spacing:.5px; }
code { background:#0d1117; padding:2px 6px; border-radius:4px; font-size:12px; }
.badge { display:inline-block; padding:2px 8px; border-radius:999px;
         font-size:11px; font-weight:600; text-transform:uppercase; }
.badge.active    { background:#1f6f3f; color:#d3ffd3; }
.badge.expired   { background:#754200; color:#ffe1b2; }
.badge.revoked   { background:#6e1e1e; color:#ffd2d2; }
.badge.suspended { background:#3a3a3a; color:#ccc; }
.flash.ok  { background:#1f6f3f; color:#d3ffd3; padding:10px 14px;
             border-radius:6px; margin-bottom:16px; }
.flash.err { background:#6e1e1e; color:#ffd2d2; padding:10px 14px;
             border-radius:6px; margin-bottom:16px; }
.muted { color:var(--mut); font-size:12px; }
form.inline { display:inline; }

/* Caixa de comando de instalação */
.install-box {
    background:#0d1117; border:1px solid var(--accent);
    border-radius:6px; padding:12px 14px;
    font-family:monospace; font-size:13px;
    word-break:break-all; position:relative;
}
.install-box-sm {
    background:#0d1117; border:1px solid var(--border);
    border-radius:4px; padding:6px 10px;
    font-family:monospace; font-size:11px;
    word-break:break-all; max-width:480px;
}
.copy-row { display:flex; align-items:flex-start; gap:8px; }
.copy-row .install-box { flex:1; }
.copied { color:var(--accent); font-size:11px; display:none; }
</style>
</head>
<body>

<?php if (!$logged): ?>
<div class="card" style="max-width:380px;margin:80px auto;">
  <h1>XSP Admin</h1>
  <?php if (!empty($loginErr)): ?>
    <div class="flash err"><?= htmlspecialchars($loginErr) ?></div>
  <?php endif; ?>
  <form method="post">
    <input type="hidden" name="action" value="login">
    <p><input type="text"     name="user" placeholder="usuário" required autofocus></p>
    <p><input type="password" name="pass" placeholder="senha"   required></p>
    <p><button class="btn" type="submit">Entrar</button></p>
  </form>
</div>

<?php else: ?>

<header>
  <h1>XSP Admin</h1>
  <a class="btn ghost" href="?action=logout">Sair</a>
</header>

<?php if ($flash): ?>
  <div class="flash <?= $flash[0] ?>"><?= htmlspecialchars((string)$flash[1]) ?></div>
<?php endif; ?>

<?php /* ── KEY recém-gerada: mostra o comando de instalação em destaque ── */ ?>
<?php if ($newKey && $INSTALL_URL): ?>
<div class="card highlight">
  <h2>🎉 KEY gerada — envie este comando ao cliente</h2>
  <p>O cliente deve executar este comando na VPS dele (Ubuntu/Debian):</p>
  <div class="copy-row">
    <div class="install-box" id="newcmd"><?= htmlspecialchars(installCmd($newKey, $INSTALL_URL)) ?></div>
    <button class="btn" onclick="copyText('newcmd', 'newcmd-ok')">Copiar</button>
  </div>
  <span class="copied" id="newcmd-ok">✓ Copiado!</span>
  <p class="muted" style="margin-top:12px;">
    ⚠ KEY: <strong><?= htmlspecialchars($newKey) ?></strong> — válida para <strong>1 instalação</strong>.
    Após ativada, fica vinculada àquela VPS.
  </p>
</div>
<?php elseif ($newKey): ?>
<div class="card highlight">
  <h2>KEY gerada</h2>
  <code><?= htmlspecialchars($newKey) ?></code>
  <p class="muted">Configure INSTALL_URL no .env para ver o comando completo.</p>
</div>
<?php endif; ?>

<?php /* ── Criar nova KEY ── */ ?>
<div class="card">
  <h2>Criar nova licença</h2>
  <form method="post">
    <input type="hidden" name="action" value="create_key">
    <div class="row">
      <input type="email"  name="email" placeholder="cliente@exemplo.com" required>
      <input type="text"   name="name"  placeholder="Nome do cliente">
      <select name="plan">
        <option value="trial">Trial (7 dias)</option>
        <option value="basic" selected>Básico (30 dias)</option>
        <option value="pro">Profissional (30 dias)</option>
        <option value="enterprise">Enterprise (30 dias)</option>
      </select>
      <input type="number" name="days" value="30" min="1" max="365" title="Dias de validade">
      <button class="btn" type="submit">Gerar KEY</button>
    </div>
    <p class="muted" style="margin-top:8px;">Cada KEY gerada permite exatamente 1 instalação.</p>
  </form>
</div>

<?php /* ── Lista de licenças ── */ ?>
<div class="card">
  <h2>Licenças (<?= count($licenses) ?>)</h2>
  <table>
    <thead>
      <tr>
        <th>KEY</th>
        <th>Cliente</th>
        <th>Plano</th>
        <th>Status</th>
        <th>Expira</th>
        <th>Criada</th>
        <?php if ($INSTALL_URL): ?><th>Comando instalação</th><?php endif; ?>
        <th>Ações</th>
      </tr>
    </thead>
    <tbody>
    <?php foreach ($licenses as $i => $l):
        $key    = (string)($l['key']    ?? '???');
        $keyId  = (string)($l['id']     ?? '');
        $status = (string)($l['status'] ?? '');
        $expIn  = max(0, (int)((strtotime((string)$l['expires_at']) - time()) / 86400));
        $cmd    = ($INSTALL_URL && $status === 'active') ? installCmd($key, $INSTALL_URL) : '';
        $cid    = 'cmd' . $i;
    ?>
      <tr>
        <td><code><?= htmlspecialchars($key) ?></code></td>
        <td>
          <?= htmlspecialchars((string)($l['customer_email'] ?? $l['email'] ?? '')) ?>
          <?php if (!empty($l['customer_name'])): ?>
            <div class="muted"><?= htmlspecialchars((string)$l['customer_name']) ?></div>
          <?php endif; ?>
        </td>
        <td><?= htmlspecialchars((string)($l['plan_code'] ?? '')) ?></td>
        <td><span class="badge <?= htmlspecialchars($status) ?>"><?= htmlspecialchars($status) ?></span></td>
        <td>
          <?= htmlspecialchars(substr((string)$l['expires_at'], 0, 10)) ?>
          <div class="muted"><?= $expIn ?> dias</div>
        </td>
        <td><?= htmlspecialchars(substr((string)$l['created_at'], 0, 10)) ?></td>

        <?php if ($INSTALL_URL): ?>
        <td>
          <?php if ($cmd): ?>
          <div style="display:flex;align-items:center;gap:6px;">
            <div class="install-box-sm" id="<?= $cid ?>"><?= htmlspecialchars($cmd) ?></div>
            <button class="btn copy" onclick="copyText('<?= $cid ?>','<?= $cid ?>-ok')">Copiar</button>
          </div>
          <span class="copied" id="<?= $cid ?>-ok">✓</span>
          <?php else: ?>
          <span class="muted">—</span>
          <?php endif; ?>
        </td>
        <?php endif; ?>

        <td>
          <?php if ($status === 'active'): ?>
          <form class="inline" method="post" onsubmit="return confirm('Revogar esta KEY?');">
            <input type="hidden" name="action" value="revoke">
            <input type="hidden" name="id" value="<?= htmlspecialchars($keyId) ?>">
            <input type="hidden" name="reason" value="admin">
            <button class="btn danger" type="submit">Revogar</button>
          </form>
          <form class="inline" method="post">
            <input type="hidden" name="action" value="extend">
            <input type="hidden" name="id" value="<?= htmlspecialchars($keyId) ?>">
            <input type="hidden" name="days" value="30">
            <button class="btn ghost" type="submit">+30d</button>
          </form>
          <?php endif; ?>
        </td>
      </tr>
    <?php endforeach; ?>
    </tbody>
  </table>
</div>

<?php /* ── Blacklist ── */ ?>
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

<?php /* ── Próximos passos se INSTALL_URL não estiver configurado ── */ ?>
<?php if (!$INSTALL_URL): ?>
<div class="card" style="border-color:#754200;">
  <p class="muted">⚠ <strong>INSTALL_URL</strong> não configurado — os comandos de instalação não aparecerão.
  Verifique o <code>.env</code> no servidor.</p>
</div>
<?php endif; ?>

<p class="muted">XSP Admin · API: <?= htmlspecialchars($API) ?></p>

<script>
function copyText(srcId, okId) {
    const text = document.getElementById(srcId).textContent.trim();
    navigator.clipboard.writeText(text).then(() => {
        const el = document.getElementById(okId);
        el.style.display = 'inline';
        setTimeout(() => el.style.display = 'none', 2000);
    });
}
</script>

<?php endif; ?>
</body>
</html>
