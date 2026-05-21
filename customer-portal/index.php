<?php
/**
 * XSP — Portal do Cliente
 * Cliente entra com a KEY, vê status, renova, reseta HWID.
 *
 * Env vars:
 *   PORTAL_API_BASE   ex: http://api:8443
 *   PORTAL_MP_LINK    ex: https://mpago.la/abc123  (link de pagamento recorrente)
 */
declare(strict_types=1);
session_start();

$API = getenv('PORTAL_API_BASE') ?: 'http://api:8443';
$MP_LINK = getenv('PORTAL_MP_LINK') ?: '#';

function api(string $path, array $body): array {
    global $API;
    $ch = curl_init($API . $path);
    curl_setopt_array($ch, [
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_POST           => true,
        CURLOPT_HTTPHEADER     => ['Content-Type: application/json'],
        CURLOPT_POSTFIELDS     => json_encode($body),
        CURLOPT_TIMEOUT        => 8,
    ]);
    $r = curl_exec($ch);
    $c = curl_getinfo($ch, CURLINFO_HTTP_CODE);
    curl_close($ch);
    return ['code' => $c, 'body' => json_decode((string)$r, true) ?: ['raw' => $r]];
}

// Pega KEY de POST (login) ou GET (link com ?key=...)
$key = strtoupper(trim((string)($_POST['key'] ?? $_GET['key'] ?? $_SESSION['key'] ?? '')));
$key = preg_replace('/[^A-Z0-9-]/', '', $key);

if ($key && !preg_match('/^XSP-[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}$/', $key)) {
    $err = 'Formato de KEY inválido.';
    $key = '';
}

$status = null;
if ($key) {
    $r = api('/portal/status', ['key' => $key]);
    if ($r['code'] === 200) {
        $status = $r['body'];
        $_SESSION['key'] = $key;
    } else {
        $err = $r['body']['message'] ?? 'KEY não encontrada.';
        $key = '';
        unset($_SESSION['key']);
    }
}

// Reset HWID
$flash = null;
if ($key && ($_POST['action'] ?? '') === 'reset_hwid' && !empty($_POST['installation_id'])) {
    $r = api('/portal/reset-hwid', [
        'key' => $key,
        'installation_id' => $_POST['installation_id'],
    ]);
    $flash = $r['code'] === 200
        ? ['ok',  'HWID liberado. Você pode instalar em outra máquina agora.']
        : ['err', $r['body']['message'] ?? 'Erro ao resetar.'];
}

if (($_GET['logout'] ?? '') === '1') {
    session_destroy();
    header('Location: /');
    exit;
}
?><!doctype html>
<html lang="pt-br">
<head>
<meta charset="utf-8">
<title>Minha Conta — XSP</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex">
<style>
:root {
    --bg:#0a0e1a; --fg:#e8eef7; --mut:#8b94a7;
    --accent:#00d4aa; --accent-dim:#009975;
    --danger:#ff5f6d; --warn:#ffd479;
    --card:rgba(22,27,40,0.7); --border:#2a3046;
}
* { box-sizing:border-box; margin:0; padding:0; }
body {
    background:var(--bg) radial-gradient(circle at top right,#1a1f3a 0%,#0a0e1a 60%);
    color:var(--fg); font-family:-apple-system,'Segoe UI',sans-serif;
    min-height:100vh; padding:24px;
}
.wrap { max-width:720px; margin:0 auto; }
header { display:flex; justify-content:space-between; align-items:center; margin-bottom:32px; }
header h1 { font-size:20px; }
header h1 .dot { color:var(--accent); }
.btn { background:var(--accent); color:#0a0e1a; padding:10px 16px; border:none;
       border-radius:8px; font-weight:600; cursor:pointer; text-decoration:none;
       display:inline-block; }
.btn:hover { background:var(--accent-dim); }
.btn.ghost { background:transparent; color:var(--fg); border:1px solid var(--border); }
.btn.danger { background:var(--danger); color:#fff; }
.card { background:var(--card); border:1px solid var(--border); border-radius:12px;
        padding:24px; margin-bottom:16px; backdrop-filter:blur(8px); }
.input { width:100%; background:#050810; color:var(--fg); border:1px solid var(--border);
         padding:12px 14px; border-radius:8px; font-family:monospace; font-size:14px;
         letter-spacing:1px; text-transform:uppercase; }
.input:focus { outline:none; border-color:var(--accent); }
.row { display:grid; grid-template-columns:1fr 1fr; gap:16px; margin-top:16px; }
.row > div { padding:12px; background:#050810; border-radius:8px; border:1px solid var(--border); }
.row label { display:block; color:var(--mut); font-size:11px; font-weight:600;
             text-transform:uppercase; letter-spacing:0.5px; margin-bottom:4px; }
.row value { font-size:18px; font-weight:600; display:block; }
.badge { display:inline-block; padding:3px 10px; border-radius:999px; font-size:11px;
         font-weight:700; text-transform:uppercase; }
.badge.active   { background:#1f6f3f; color:#d3ffd3; }
.badge.expired  { background:#754200; color:#ffe1b2; }
.badge.revoked  { background:#6e1e1e; color:#ffd2d2; }
.badge.suspended{ background:#3a3a3a; color:#ccc; }
.flash { padding:12px 16px; border-radius:8px; margin-bottom:16px; }
.flash.ok  { background:rgba(0,212,170,0.15); color:var(--accent); border:1px solid var(--accent); }
.flash.err { background:rgba(255,95,109,0.15); color:var(--danger); border:1px solid var(--danger); }
h2 { font-size:18px; margin-bottom:12px; }
.muted { color:var(--mut); font-size:14px; }
.glow { background:linear-gradient(90deg,var(--accent),#00b8ff);
        -webkit-background-clip:text; -webkit-text-fill-color:transparent; }
</style>
</head>
<body>
<div class="wrap">

<header>
  <h1>XSP<span class="dot">.</span> Minha Conta</h1>
  <?php if ($status): ?>
    <a class="btn ghost" href="?logout=1">Sair</a>
  <?php endif; ?>
</header>

<?php if (!empty($err)): ?>
  <div class="flash err"><?= htmlspecialchars($err) ?></div>
<?php endif; ?>
<?php if ($flash): ?>
  <div class="flash <?= $flash[0] ?>"><?= htmlspecialchars((string)$flash[1]) ?></div>
<?php endif; ?>

<?php if (!$status): ?>

<div class="card">
  <h2>Acesse sua conta</h2>
  <p class="muted" style="margin-bottom:16px;">
    Use a <strong>KEY</strong> que você recebeu por e-mail/WhatsApp.
  </p>
  <form method="post" autocomplete="off">
    <input class="input" type="text" name="key"
           placeholder="XSP-AAAA-BBBB-CCCC-DDDD" required maxlength="23"
           value="<?= htmlspecialchars($key) ?>">
    <p style="margin-top:16px;">
      <button class="btn" type="submit">Entrar</button>
    </p>
  </form>
</div>

<?php else: ?>

<div class="card">
  <h2>Sua licença <span class="glow"><?= htmlspecialchars(strtoupper($status['plan'])) ?></span></h2>
  <div class="row">
    <div>
      <label>Status</label>
      <value><span class="badge <?= htmlspecialchars($status['status']) ?>">
        <?= htmlspecialchars($status['status']) ?>
      </span></value>
    </div>
    <div>
      <label>Dias restantes</label>
      <value style="color:<?= $status['days_left'] < 7 ? 'var(--warn)' : 'var(--fg)' ?>;">
        <?= (int)$status['days_left'] ?> dias
      </value>
    </div>
    <div>
      <label>Expira em</label>
      <value style="font-size:14px;">
        <?= htmlspecialchars(substr($status['expires_at'], 0, 10)) ?>
      </value>
    </div>
    <div>
      <label>Máq. permitidas</label>
      <value><?= (int)$status['max_instances'] ?></value>
    </div>
  </div>
</div>

<?php if ($status['days_left'] <= 14 || $status['status'] === 'expired'): ?>
<div class="card" style="border-color:var(--warn);">
  <h2>⚠ Renove sua assinatura</h2>
  <p class="muted" style="margin-bottom:16px;">
    Sua licença expira em <strong><?= (int)$status['days_left'] ?> dias</strong>.
    Renove agora para não perder acesso ao painel.
  </p>
  <a class="btn" href="<?= htmlspecialchars($MP_LINK) ?>" target="_blank">
    Renovar agora — Mercado Pago
  </a>
</div>
<?php endif; ?>

<div class="card">
  <h2>Sua KEY</h2>
  <input class="input" readonly value="<?= htmlspecialchars($key) ?>"
         onclick="this.select();document.execCommand('copy');">
  <p class="muted" style="margin-top:8px; font-size:12px;">
    Clique para copiar. Use no instalador na sua VPS.
  </p>
</div>

<div class="card">
  <h2>Trocar de VPS / Reset HWID</h2>
  <p class="muted" style="margin-bottom:16px;">
    Se você precisa reinstalar em outra máquina, libere a instalação atual.
    Em seguida, rode o instalador novamente na nova VPS.
  </p>
  <form method="post" onsubmit="return confirm('Liberar a instalação atual?');">
    <input type="hidden" name="action" value="reset_hwid">
    <input class="input" name="installation_id"
           placeholder="ID da instalação (veja no painel ou no email)"
           pattern="[0-9a-fA-F-]{36}" required>
    <p style="margin-top:12px;">
      <button class="btn danger" type="submit">Liberar Instalação</button>
    </p>
  </form>
</div>

<div class="card">
  <h2>Como instalar o painel</h2>
  <p class="muted" style="margin-bottom:12px;">
    Numa VPS Ubuntu 22.04+, rode:
  </p>
  <div style="background:#050810; border:1px solid var(--border);
              border-radius:8px; padding:12px; font-family:monospace;
              font-size:13px; user-select:all; word-break:break-all;">
    curl -sSL https://<?= htmlspecialchars($_SERVER['HTTP_HOST']) ?>/install.sh | sudo bash -s -- <?= htmlspecialchars($key) ?>
  </div>
</div>

<?php endif; ?>

<p class="muted" style="text-align:center; margin-top:32px; font-size:13px;">
  XSP — Painel Office Xtream
</p>

</div>
</body>
</html>
