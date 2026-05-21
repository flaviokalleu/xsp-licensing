<?php
/**
 * Landing PHP — variante server-side que detecta domínio via $_SERVER.
 * Útil se você quiser logar acessos, esconder do Google (robots), ou
 * validar a KEY contra a API ANTES de mostrar o comando.
 *
 * Hospede em /var/www/dl/index.php (Caddy serve automaticamente).
 */
$host  = $_SERVER['HTTP_HOST']  ?? 'exemplo.com';
$proto = (!empty($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off') ? 'https' : 'http';
$base  = $proto . '://' . $host;

// KEY pode vir por ?key=... ou ?k=...
$key = strtoupper(trim((string)($_GET['key'] ?? $_GET['k'] ?? '')));
$key = preg_replace('/[^A-Z0-9-]/', '', $key);
$validKey = (bool)preg_match('/^XSP-[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}$/', $key);

// Comando final
if ($validKey) {
    $cmd = "curl -sSL {$base}/install.sh | sudo bash -s -- {$key}";
} else {
    $cmd = "curl -sSL {$base}/install.sh | sudo bash";
}

// Opcional: log de acessos
// @file_put_contents('/var/log/xsp-landing.log',
//     date('c') . " {$_SERVER['REMOTE_ADDR']} {$host} key=" . ($validKey?'yes':'no') . "\n", FILE_APPEND);
?><!doctype html>
<html lang="pt-br">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Instalar Painel — <?= htmlspecialchars($host) ?></title>
<meta name="robots" content="noindex,nofollow">
<style>
  :root {
    --bg: #0a0e1a; --fg: #e8eef7; --mut: #8b94a7;
    --accent: #00d4aa; --accent-dim: #009975;
    --card: rgba(22, 27, 40, 0.7); --border: #2a3046;
  }
  * { box-sizing: border-box; margin: 0; padding: 0; }
  html, body { height: 100%; }
  body {
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
    background: var(--bg) radial-gradient(circle at top right, #1a1f3a 0%, #0a0e1a 60%);
    color: var(--fg); line-height: 1.5;
    min-height: 100vh; display: flex; flex-direction: column;
  }
  header {
    padding: 24px 32px; border-bottom: 1px solid var(--border);
    display: flex; justify-content: space-between; align-items: center;
  }
  header h1 { font-size: 18px; font-weight: 600; }
  header h1 .dot { color: var(--accent); }
  .domain-pill {
    background: rgba(0,212,170,0.15); color: var(--accent);
    padding: 2px 10px; border-radius: 999px;
    font-size: 12px; font-weight: 600; font-family: monospace;
  }
  main {
    flex: 1; display: flex; align-items: center; justify-content: center;
    padding: 40px 20px;
  }
  .container { max-width: 720px; width: 100%; }
  h2 { font-size: 32px; font-weight: 700; letter-spacing: -.8px; margin-bottom: 12px; }
  h2 .glow {
    background: linear-gradient(90deg, var(--accent), #00b8ff);
    -webkit-background-clip: text; -webkit-text-fill-color: transparent;
  }
  .subtitle { color: var(--mut); margin-bottom: 32px; font-size: 17px; }
  .step-row { display: flex; gap: 16px; margin-bottom: 24px; }
  .step-num {
    width: 36px; height: 36px; border-radius: 50%;
    background: var(--accent); color: #0a0e1a; font-weight: 700;
    display: flex; align-items: center; justify-content: center; flex-shrink: 0;
  }
  .step-body h3 { font-size: 17px; font-weight: 600; }
  .step-body p { color: var(--mut); font-size: 14px; margin-top: 4px; }
  .card {
    background: var(--card); border: 1px solid var(--border); border-radius: 12px;
    padding: 24px; margin: 16px 0 32px 52px; backdrop-filter: blur(8px);
  }
  .cmd {
    font-family: 'SF Mono', Consolas, monospace; background: #050810;
    border: 1px solid var(--border); color: #c9d9f0;
    padding: 14px 56px 14px 16px; border-radius: 8px; font-size: 13.5px;
    overflow-x: auto; white-space: nowrap; position: relative; user-select: all;
  }
  .copy-btn {
    position: absolute; top: 6px; right: 6px;
    background: var(--accent-dim); color: #0a0e1a; border: none;
    border-radius: 6px; padding: 6px 12px; font-size: 12px; font-weight: 600;
    cursor: pointer;
  }
  .copy-btn:hover { background: var(--accent); }
  .copy-btn.copied { background: #4ade80; }
  .cmd-wrap { position: relative; }
  .key-banner {
    background: rgba(0,212,170,0.1); border: 1px solid var(--accent);
    padding: 12px 16px; border-radius: 8px; margin-bottom: 24px;
    font-size: 14px;
  }
  .key-banner code { color: var(--accent); font-weight: 600; }
  .reqs {
    margin: 28px 0; padding: 16px 20px;
    background: rgba(0,212,170,0.06); border-left: 3px solid var(--accent);
    border-radius: 4px; font-size: 14px;
  }
  .reqs strong { color: var(--accent); }
  .reqs ul { margin-top: 8px; padding-left: 18px; color: var(--mut); }
  footer {
    border-top: 1px solid var(--border); padding: 20px 32px;
    color: var(--mut); font-size: 13px; text-align: center;
  }
  footer a { color: var(--accent); text-decoration: none; }
  @media (max-width: 600px) {
    h2 { font-size: 24px; } .card { margin-left: 0; padding: 16px; }
    .cmd { font-size: 11px; }
  }
</style>
</head>
<body>

<header>
  <h1>XSP<span class="dot">.</span> Painel Office Xtream</h1>
  <span class="domain-pill"><?= htmlspecialchars($host) ?></span>
</header>

<main>
<div class="container">

  <?php if ($validKey): ?>
    <div class="key-banner">
      ✓ KEY recebida: <code><?= htmlspecialchars($key) ?></code> — comando abaixo já vem pronto.
    </div>
  <?php endif; ?>

  <h2>Instale o painel em <span class="glow">3 minutos</span></h2>
  <p class="subtitle">
    Cole 1 comando no terminal da sua VPS. O instalador faz o resto.
  </p>

  <div class="step-row">
    <div class="step-num">1</div>
    <div class="step-body">
      <h3>Conecte-se à sua VPS Ubuntu via SSH</h3>
      <p>Requisitos: Ubuntu 22.04+, 2 vCPU, 4 GB RAM, portas 80/443 livres, root.</p>
    </div>
  </div>

  <div class="step-row">
    <div class="step-num">2</div>
    <div class="step-body">
      <h3>Cole este comando e pressione Enter</h3>
      <p>Tudo automático. Vai pedir seu domínio e e-mail durante a instalação.</p>
    </div>
  </div>

  <div class="card">
    <div class="cmd-wrap">
      <div class="cmd" id="cmd">
        <span style="color:var(--accent)">$</span>
        <span id="cmdText"><?= htmlspecialchars($cmd) ?></span>
      </div>
      <button class="copy-btn" id="copyBtn" onclick="copyCmd()">📋 Copiar</button>
    </div>
  </div>

  <div class="reqs">
    <strong>O que será instalado:</strong>
    <ul>
      <li>Docker + Docker Compose</li>
      <li>Painel cifrado (anti-pirataria)</li>
      <li>MariaDB com senha aleatória</li>
      <li>Validação online a cada 5 minutos</li>
    </ul>
  </div>

</div>
</main>

<footer>
  Domínio servidor: <code><?= htmlspecialchars($host) ?></code>
</footer>

<script>
function copyCmd() {
  const t = document.getElementById('cmdText').textContent;
  navigator.clipboard.writeText(t).then(() => {
    const b = document.getElementById('copyBtn');
    b.textContent = '✓ Copiado!'; b.classList.add('copied');
    setTimeout(() => { b.textContent = '📋 Copiar'; b.classList.remove('copied'); }, 2000);
  });
}
</script>

</body>
</html>
