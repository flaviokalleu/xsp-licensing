#!/usr/bin/env python3
"""
Gera os 3 ZIPs de distribuição do XSP Licensing.

Saída:
  dist/xsp-licensing-FULL.zip       — tudo (recomendado para você)
  dist/xsp-licensing-SERVER.zip     — só lado servidor (gerador de licenças)
  dist/xsp-licensing-PAINEL.zip     — só instalador do painel (cliente final)

Uso:  python _make_zips.py
"""
import os, sys, zipfile, stat, pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent  # licensing/
DIST = ROOT / 'dist'
DIST.mkdir(exist_ok=True)

# ───────────────────────────────────────────────────────────────────────────
# Helpers
# ───────────────────────────────────────────────────────────────────────────

EXCLUDE_DIRS = {'.git', 'node_modules', '__pycache__', 'dist',
                'build', 'modules', 'bin', '.cache', '.vscode'}
EXCLUDE_FILES = {'.DS_Store', 'Thumbs.db', '.env'}
EXCLUDE_SUFFIXES = ('.so', '.dylib', '.exe', '.log', '.bak',
                    '.swp', '.pyc')

def should_skip(path: pathlib.Path) -> bool:
    name = path.name
    if any(part in EXCLUDE_DIRS for part in path.parts):
        return True
    if name in EXCLUDE_FILES:
        return True
    if name.endswith(EXCLUDE_SUFFIXES):
        return True
    return False

def add_tree(zf: zipfile.ZipFile, src: pathlib.Path, arc_prefix: str = '') -> int:
    """Adiciona src e descendentes ao zip. Retorna nº arquivos."""
    count = 0
    if src.is_file():
        if should_skip(src):
            return 0
        arcname = (arc_prefix + src.name) if arc_prefix else src.name
        _add_file(zf, src, arcname)
        return 1

    base = src
    for p in sorted(src.rglob('*')):
        if not p.is_file() or should_skip(p):
            continue
        rel = p.relative_to(base)
        arcname = arc_prefix + str(rel).replace(os.sep, '/')
        _add_file(zf, p, arcname)
        count += 1
    return count

def _add_file(zf: zipfile.ZipFile, path: pathlib.Path, arcname: str):
    info = zipfile.ZipInfo(arcname)
    # Permissões POSIX: 0755 para scripts .sh / Makefile / arquivos C exec,
    # 0644 para o resto. Mantém compatibilidade com sistemas Unix.
    is_exec = (path.suffix == '.sh' or
               path.name == 'Makefile' or
               (path.stat().st_mode & 0o100))
    mode = 0o755 if is_exec else 0o644
    info.external_attr = (mode << 16) | 0x8000
    info.compress_type = zipfile.ZIP_DEFLATED
    with open(path, 'rb') as f:
        zf.writestr(info, f.read())

def make_zip(name: str, entries, description: str = '') -> str:
    """entries: lista de tuplas (caminho_no_disco, prefixo_no_zip)"""
    out = DIST / name
    if out.exists():
        out.unlink()
    total = 0
    with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
        for src, prefix in entries:
            p = ROOT / src if not pathlib.Path(src).is_absolute() else pathlib.Path(src)
            if not p.exists():
                print(f"  ⚠ {src} não existe — pulando")
                continue
            n = add_tree(zf, p, prefix)
            total += n
            kind = 'pasta' if p.is_dir() else 'arquivo'
            print(f"  + {src:35} ({n} {kind})")
    size_mb = out.stat().st_size / 1024 / 1024
    print(f"✓ {out.name}  ({total} arquivos · {size_mb:.2f} MB)\n")
    return str(out)

# ───────────────────────────────────────────────────────────────────────────
# Bundles
# ───────────────────────────────────────────────────────────────────────────

print("\n=== Gerando ZIPs de distribuição ===\n")

CORE = [
    ('README.md',             ''),
    ('CLAUDE.md',             ''),
    ('INSTALL.sh',            ''),
    ('install-server.sh',     ''),
    ('install-painel.sh',     ''),
    ('docker-compose.yml',    ''),
    ('Caddyfile',             ''),
    ('Makefile',              ''),
    ('.env.example',          ''),
    ('bootstrap-secrets.sh',  ''),
    ('api-license',           'api-license/'),
    ('xsp-loader',            'xsp-loader/'),
    ('painel-image',          'painel-image/'),
    ('admin-dashboard',       'admin-dashboard/'),
    ('customer-portal',       'customer-portal/'),
    ('builder',               'builder/'),
    ('landing',               'landing/'),
    ('docs',                  'docs/'),
]

# 1) FULL — tudo
print("📦  xsp-licensing-FULL.zip  (bundle completo)")
make_zip('xsp-licensing-FULL.zip',
    [(src, 'xsp-licensing/' + pre) for src, pre in CORE +
     [('installer-go', 'installer-go/')]])  # FULL inclui o installer-go alternativo

# 2) SERVER — lado servidor central (sem installer-go)
print("📦  xsp-licensing-SERVER.zip  (lado servidor)")
make_zip('xsp-licensing-SERVER.zip',
    [(src, 'xsp-server/' + pre) for src, pre in CORE])

# 3) PAINEL — só o instalador do cliente final + landing
print("📦  xsp-licensing-PAINEL.zip  (instalador cliente)")
make_zip('xsp-licensing-PAINEL.zip', [
    ('install-painel.sh',   'xsp-painel/'),
    ('landing',             'xsp-painel/landing/'),
    ('docs/OPERATIONS.md',  'xsp-painel/docs/'),
])

# 4) Cópia direta dos .sh sem zip para acesso rápido
import shutil
for s in ['INSTALL.sh', 'install-server.sh', 'install-painel.sh']:
    src = ROOT / s
    dst = DIST / s
    if src.exists():
        shutil.copy2(src, dst)

print("\n=== Conteúdo de dist/ ===")
for f in sorted(DIST.iterdir()):
    size = f.stat().st_size
    if size > 1024 * 1024:
        sz = f"{size/1024/1024:.2f} MB"
    elif size > 1024:
        sz = f"{size/1024:.1f} KB"
    else:
        sz = f"{size} B"
    print(f"  {f.name:35} {sz}")
print()
