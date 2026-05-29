#!/usr/bin/env python3
"""
adapt-panel.py — Saneia o painel PHP original ANTES da cifragem.

O painel atual (em script/) tem credenciais de banco hardcoded em ~10 arquivos.
Este script:
  1. Substitui TODAS as credenciais hardcoded por leitura de env vars
     (DB_HOST, DB_NAME, DB_USER, DB_PASS) — que o container injeta.
  2. Cria um conector central _xsp_db.php em /var/www/html/
  3. Remove arquivos perigosos (tutoriais com credenciais, debug logs).
  4. Marca o output como pronto para a etapa de cifragem.

Uso:
    python adapt-panel.py <src_panel_dir> <dest_dir>

Idempotente — pode rodar várias vezes no mesmo destino.
"""
import os, re, sys, shutil, pathlib, json

if len(sys.argv) != 3:
    print("uso: adapt-panel.py <src> <dest>", file=sys.stderr)
    sys.exit(1)

SRC  = pathlib.Path(sys.argv[1]).resolve()
DEST = pathlib.Path(sys.argv[2]).resolve()
BRANDING_DIR = pathlib.Path(__file__).resolve().parents[1] / 'branding'

# ─── arquivos / padrões perigosos a NÃO incluir no destino ──────────────────
EXCLUDE_FILES = {
    'TUTORIAL.txt', 'README.md',
    '.env', '.env.local', '.env.backup',
    'error_log', 'debug_log.txt', 'webhook_log.txt',
    'teste_pix.php', 'teste_update.php', 'check_path.php',
    'debug_categorias.php', 'teste_db.php',
}
EXCLUDE_DIRS = {'.git', 'node_modules', 'backups', '__MACOSX', 'tests', 'samples'}
EXCLUDE_PREFIXES = ('error_log-', '.swp', 'php_error', '.htaccess.bak')
EXCLUDE_SUFFIXES = ('.bak', '.swp', '.swo', '.log', '.gz', '.zip')

# ─── 1) cópia limpa ─────────────────────────────────────────────────────────
print(f"→ Copiando árvore para {DEST}/ ...")
if DEST.exists():
    shutil.rmtree(DEST)

def ignore(dir_path, names):
    out = []
    for n in names:
        if n in EXCLUDE_FILES or n in EXCLUDE_DIRS:
            out.append(n); continue
        if any(n.startswith(p) for p in EXCLUDE_PREFIXES):
            out.append(n); continue
        if any(n.endswith(s) for s in EXCLUDE_SUFFIXES):
            out.append(n); continue
    return out

shutil.copytree(SRC, DEST, ignore=ignore)
print(f"✓ Árvore copiada.")

# ─── 2) regex de substituição de credenciais ────────────────────────────────
# Cada padrão captura: variável + valor literal. Resultado: getenv()
PATTERNS = [
    # mysqli style
    (re.compile(r"""(\$servername\s*=\s*)['"]([^'"]+)['"]\s*;"""),
        r"\1getenv('DB_HOST') ?: 'localhost';"),
    (re.compile(r"""(\$username_db\s*=\s*)['"]([^'"]+)['"]\s*;"""),
        r"\1getenv('DB_USER') ?: 'xsp';"),
    (re.compile(r"""(\$password_db\s*=\s*)['"]([^'"]*)['"]\s*;"""),
        r"\1getenv('DB_PASS') ?: '';"),

    # estilo $db_host / $db_user / $db_pass / $db_name
    (re.compile(r"""(\$db_host\s*=\s*)['"]([^'"]+)['"]\s*;"""),
        r"\1getenv('DB_HOST') ?: 'localhost';"),
    (re.compile(r"""(\$db_user\s*=\s*)['"]([^'"]+)['"]\s*;"""),
        r"\1getenv('DB_USER') ?: 'xsp';"),
    (re.compile(r"""(\$db_pass\s*=\s*)['"]([^'"]*)['"]\s*;"""),
        r"\1getenv('DB_PASS') ?: '';"),
    (re.compile(r"""(\$db_name\s*=\s*)['"]([^'"]+)['"]\s*;"""),
        r"\1getenv('DB_NAME') ?: 'xsp_panel';"),

    # estilo $endereco/$banco/$dbusuario/$dbsenha (db.php do painel)
    (re.compile(r"""(\$endereco\s*=\s*)['"]([^'"]+)['"]\s*;"""),
        r"\1getenv('DB_HOST') ?: 'localhost';"),
    (re.compile(r"""(\$banco\s*=\s*)['"]([^'"]+)['"]\s*;"""),
        r"\1getenv('DB_NAME') ?: 'xsp_panel';"),
    (re.compile(r"""(\$dbusuario\s*=\s*)['"]([^'"]+)['"]\s*;"""),
        r"\1getenv('DB_USER') ?: 'xsp';"),
    (re.compile(r"""(\$dbsenha\s*=\s*)['"]([^'"]*)['"]\s*;"""),
        r"\1getenv('DB_PASS') ?: '';"),

    # estilo $host/$dbname/$user/$pass (atualizador, importador_m3u)
    # Usado em funções, escopo limitado — basta substituir os 4 juntos.
    (re.compile(r"""(\s)(\$host\s*=\s*)['"]localhost['"]\s*;"""),
        r"\1\2getenv('DB_HOST') ?: 'localhost';"),
    (re.compile(r"""(\s)(\$dbname\s*=\s*)['"]u[0-9_a-z]+['"]\s*;"""),
        r"\1\2getenv('DB_NAME') ?: 'xsp_panel';"),
    (re.compile(r"""(\s)(\$user\s*=\s*)['"]u[0-9_a-z]+['"]\s*;"""),
        r"\1\2getenv('DB_USER') ?: 'xsp';"),
    (re.compile(r"""(\s)(\$pass\s*=\s*)['"][^'"]+['"]\s*;"""),
        r"\1\2getenv('DB_PASS') ?: '';"),

    # normaliza fallbacks legados que já estavam em getenv()
    (re.compile(r"""getenv\('DB_HOST'\)\s*\?:\s*['"][^'"]+['"]"""),
        r"getenv('DB_HOST') ?: 'localhost'"),
    (re.compile(r"""getenv\('DB_NAME'\)\s*\?:\s*['"][^'"]+['"]"""),
        r"getenv('DB_NAME') ?: 'xsp_panel'"),
    (re.compile(r"""getenv\('DB_USER'\)\s*\?:\s*['"][^'"]+['"]"""),
        r"getenv('DB_USER') ?: 'xsp'"),
    (re.compile(r"""getenv\('DB_PASS'\)\s*\?:\s*['"][^'"]*['"]"""),
        r"getenv('DB_PASS') ?: ''"),
]

# Padrões "leaks de credenciais" — emite warning se ainda existirem após patches
LEAK_RE = re.compile(
    r"""A82838188Agno|u874781703_painelags|Jean#909110|u535247987_tvbox|movei5087_painel|Meliodas2015""",
    re.IGNORECASE,
)

PANEL_DISPLAY_VERSION = 'Alfa v15'
PANEL_BRAND_NAME = 'PB&Ctv'

INCLUDE_RE = re.compile(
    r"""\b(require|require_once|include|include_once)(\s*\(?\s*)(['"])([^'"]+\.php)(\3)(\s*\)?)""",
    re.IGNORECASE,
)
DOCROOT_INCLUDE_RE = re.compile(
    r"""\b(require|require_once|include|include_once)(\s*\(?\s*)\$_SERVER\s*\[\s*['"]DOCUMENT_ROOT['"]\s*\]\s*\.\s*(['"])(/[^'"]+\.php)(\3)(\s*\)?)""",
    re.IGNORECASE,
)

def normalize_relative_include(current_file: pathlib.Path, include_path: str) -> str:
    if re.match(r"""^[a-z][a-z0-9+.-]*://""", include_path, re.IGNORECASE):
        return include_path

    # Paths that are relative to the panel source must also be loaded through
    # the encrypted stream wrapper after the build deletes clear PHP files.
    if include_path.startswith('/var/www/html/'):
        rel = pathlib.PurePosixPath(include_path.removeprefix('/var/www/html/'))
    elif include_path == '/var/www/html':
        return include_path
    elif include_path.startswith('/'):
        rel = pathlib.PurePosixPath(include_path.lstrip('/'))
    else:
        current_rel_dir = current_file.relative_to(DEST).parent
        rel = pathlib.PurePosixPath(current_rel_dir.as_posix()) / include_path

    normalized_parts = []
    for part in rel.parts:
        if part in ('', '.'):
            continue
        if part == '..':
            if normalized_parts:
                normalized_parts.pop()
            continue
        normalized_parts.append(part)

    if not normalized_parts:
        return include_path
    return 'xsp:///var/www/html/' + '/'.join(normalized_parts)

def rewrite_relative_includes(current_file: pathlib.Path, text: str) -> str:
    def docroot_repl(match: re.Match) -> str:
        rewritten = normalize_relative_include(current_file, '/var/www/html' + match.group(4))
        return f"{match.group(1)}{match.group(2)}'{rewritten}'{match.group(6)}"

    def repl(match: re.Match) -> str:
        path = match.group(4)
        rewritten = normalize_relative_include(current_file, path)
        return f"{match.group(1)}{match.group(2)}{match.group(3)}{rewritten}{match.group(5)}{match.group(6)}"

    text = DOCROOT_INCLUDE_RE.sub(docroot_repl, text)
    return INCLUDE_RE.sub(repl, text)

def normalize_frontend_versions(text: str) -> str:
    text = re.sub(r"""AGS\s+PLAY""", PANEL_BRAND_NAME, text, flags=re.IGNORECASE)
    text = re.sub(r"""Ags\s+Play""", PANEL_BRAND_NAME, text, flags=re.IGNORECASE)
    text = re.sub(
        r"""BEM[-\s]+VINDOS?\s+AO\s+PAINEL\s+PB&Ctv!?""",
        f"BEM-VINDOS AO PAINEL {PANEL_BRAND_NAME}!",
        text,
        flags=re.IGNORECASE,
    )
    text = text.replace('O Melhor Conteúdo', 'O melhor conteúdo')
    text = re.sub(
        r"""Versão atual\s*:\s*[^<]+""",
        f"Versão atual : {PANEL_DISPLAY_VERSION} ",
        text,
        flags=re.IGNORECASE,
    )
    text = re.sub(
        r"""(\$currentVersion\s*=\s*)['"][^'"]+['"]\s*;""",
        rf"\1'{PANEL_DISPLAY_VERSION}';",
        text,
    )
    text = re.sub(
        r"""(\$latestVersion\s*=\s*)['"][^'"]+['"]\s*;""",
        rf"\1'{PANEL_DISPLAY_VERSION}';",
        text,
    )
    text = re.sub(
        r"""Atualização\s+[0-9]+(?:\.[0-9]+)+""",
        f"Atualização {PANEL_DISPLAY_VERSION}",
        text,
        flags=re.IGNORECASE,
    )
    text = re.sub(
        r"""Painel Office\s+[0-9]+(?:\.[0-9]+)+""",
        f"Painel Office {PANEL_DISPLAY_VERSION}",
        text,
        flags=re.IGNORECASE,
    )
    text = re.sub(
        r"""PLAYER API\s+v[0-9]+(?:\.[0-9]+)+""",
        f"PLAYER API {PANEL_DISPLAY_VERSION}",
        text,
        flags=re.IGNORECASE,
    )
    return text

# ─── 3) aplica nas .php ─────────────────────────────────────────────────────
print("→ Substituindo credenciais hardcoded por getenv()...")
modified = 0
scanned  = 0
leaks_remaining = []

for php in DEST.rglob('*.php'):
    scanned += 1
    try:
        text = php.read_text(encoding='utf-8', errors='replace')
    except Exception as e:
        print(f"  ⚠ falha ao ler {php}: {e}")
        continue
    original = text
    for pat, repl in PATTERNS:
        text = pat.sub(repl, text)
    text = rewrite_relative_includes(php, text)
    text = re.sub(
        r"""ini_set\(\s*['"]display_errors['"]\s*,\s*1\s*\)\s*;""",
        "ini_set('display_errors', 0);",
        text,
    )
    text = re.sub(
        r"""ini_set\(\s*['"]display_startup_errors['"]\s*,\s*1\s*\)\s*;""",
        "ini_set('display_startup_errors', 0);",
        text,
    )
    text = re.sub(r"""error_reporting\(\s*E_ALL\s*\)\s*;""", "error_reporting(0);", text)
    text = re.sub(
        r"""die\(\s*['"]Erro na conexão com o banco de dados:\s*['"]\s*\.\s*\$e->getMessage\(\)\s*\)\s*;""",
        "error_log('Erro na conexão com o banco de dados: ' . $e->getMessage()); die('Erro na conexão com o banco de dados.');",
        text,
    )
    if text != original:
        php.write_text(text, encoding='utf-8')
        modified += 1
    if LEAK_RE.search(text):
        leaks_remaining.append(str(php.relative_to(DEST)))

print(f"✓ {modified}/{scanned} arquivos PHP modificados.")
if leaks_remaining:
    print(f"⚠ ATENÇÃO: ainda há vestígios de credenciais nestes {len(leaks_remaining)} arquivos:")
    for f in leaks_remaining[:10]:
        print(f"    - {f}")
    if len(leaks_remaining) > 10:
        print(f"    ... e mais {len(leaks_remaining)-10}.")
    print("  → revise manualmente OU adicione padrões em PATTERNS.")

# ─── 3.1) normaliza versões exibidas no frontend ────────────────────────────
print(f"→ Normalizando versões visíveis para {PANEL_DISPLAY_VERSION}...")
version_modified = 0
text_files = []
for suffix in ('*.php', '*.html', '*.json', '*.txt', '*.css', '*.js'):
    text_files.extend(DEST.rglob(suffix))
for f in text_files:
    try:
        text = f.read_text(encoding='utf-8', errors='replace')
    except Exception as e:
        print(f"  ⚠ falha ao ler {f}: {e}")
        continue
    normalized = normalize_frontend_versions(text)
    if normalized != text:
        f.write_text(normalized, encoding='utf-8')
        version_modified += 1
print(f"✓ Versão frontend atualizada em {version_modified} arquivos.")

# ─── 3.2) substitui logos da marca ─────────────────────────────────────────
brand_logo = BRANDING_DIR / 'pbctv-logo.png'
brand_banner = BRANDING_DIR / 'pbctv-banner.png'
if brand_logo.is_file():
    print("→ Aplicando logos PB&Ctv...")
    img_dir = DEST / 'img'
    img_dir.mkdir(parents=True, exist_ok=True)
    for name in (
        'logo.png',
        'logo_tranparente.png',
        'logo_tranparente2.png',
        'logo_1376x509.png',
        'logo1_1376x509.png',
        'logo2_1376x509.png',
        'icon.png',
    ):
        shutil.copyfile(brand_logo, img_dir / name)
    if brand_banner.is_file():
        shutil.copyfile(brand_banner, img_dir / 'pbctv-banner.png')
    print("✓ Logos PB&Ctv aplicadas.")
else:
    print("⚠ Logos PB&Ctv não encontradas; mantendo imagens originais.")

# ─── 4) cria conector central (opcional, recomenda-se incluir) ──────────────
print("→ Escrevendo _xsp_db.php (conector central)...")
connector = """<?php
/**
 * _xsp_db.php — Conector central do painel.
 *
 * Use SEMPRE este arquivo para abrir conexão com o banco. Não coloque
 * credenciais em outros lugares — todas as conexões devem passar por aqui.
 *
 *   $pdo = xsp_db();
 *   $stmt = $pdo->prepare('SELECT * FROM clientes WHERE id = ?');
 */
declare(strict_types=1);

if (!function_exists('xsp_db')) {
    function xsp_db(): PDO {
        static $pdo = null;
        if ($pdo !== null) return $pdo;

        $host = getenv('DB_HOST') ?: 'db';
        $name = getenv('DB_NAME') ?: 'xsp_panel';
        $user = getenv('DB_USER') ?: 'xsp';
        $pass = getenv('DB_PASS') ?: '';

        $dsn = "mysql:host={$host};dbname={$name};charset=utf8mb4";
        $pdo = new PDO($dsn, $user, $pass, [
            PDO::ATTR_ERRMODE            => PDO::ERRMODE_EXCEPTION,
            PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
            PDO::MYSQL_ATTR_INIT_COMMAND => "SET NAMES utf8mb4",
        ]);
        return $pdo;
    }
}

/** Versão mysqli (alguns arquivos do painel ainda usam mysqli) */
if (!function_exists('xsp_mysqli')) {
    function xsp_mysqli(): mysqli {
        static $conn = null;
        if ($conn !== null) return $conn;

        $host = getenv('DB_HOST') ?: 'db';
        $name = getenv('DB_NAME') ?: 'xsp_panel';
        $user = getenv('DB_USER') ?: 'xsp';
        $pass = getenv('DB_PASS') ?: '';

        $conn = new mysqli($host, $user, $pass, $name);
        if ($conn->connect_error) {
            error_log('mysqli connect failed: ' . $conn->connect_error);
            throw new RuntimeException('db connection failed');
        }
        $conn->set_charset('utf8mb4');
        return $conn;
    }
}
"""
(DEST / '_xsp_db.php').write_text(connector, encoding='utf-8')
print("✓ _xsp_db.php criado.")

# ─── 5) escreve README de adaptação ─────────────────────────────────────────
note = f"""# Painel adaptado ({DEST.name})

Este diretório é o resultado de `adapt-panel.py` rodando sobre o painel
original. Nada aqui é cifrado — a cifragem acontece depois, em `encrypt.sh`.

## O que foi alterado

- Credenciais de banco substituídas por `getenv('DB_*')`.
- Adicionado `_xsp_db.php` como conector central.
- Removidos: TUTORIAL.txt, error_log, *.bak, *.log, *.gz, backups/.

## Como conectar ao DB nos arquivos NOVOS

```php
require_once 'xsp:///var/www/html/_xsp_db.php';
$pdo = xsp_db();
```

Para arquivos que ainda usam variáveis soltas, ainda funciona — as vars
agora vêm de env e apontam para o MariaDB do container.

## Próximo passo

```
bash encrypt.sh {DEST} /caminho/saida
```
"""
(DEST / '_ADAPTED.md').write_text(note, encoding='utf-8')

# ─── 6) sumário ─────────────────────────────────────────────────────────────
print()
print(f"📂 Origem:  {SRC}")
print(f"📂 Destino: {DEST}")
print(f"📊 PHPs varridos:   {scanned}")
print(f"📊 PHPs alterados:  {modified}")
print(f"📊 Vazamentos ainda presentes: {len(leaks_remaining)}")
print()
print("→ Próximo passo: cifrar este diretório com encrypt.sh")
