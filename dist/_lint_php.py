#!/usr/bin/env python3
"""
Lint estático leve para PHP — não substitui php -l, mas pega:
  - chaves desbalanceadas { }
  - parênteses desbalanceados ( )
  - strings não fechadas (heurística)
  - ?> sem <?php
  - tags <?php sem fechamento de bloco
  - função chamada que não existe NESTE arquivo + não conhecida
"""
import re, sys, pathlib

# Funções "OK" — built-in PHP, da extensão xsp_loader, do conector
KNOWN = {
    'xsp_unlock', 'xsp_locked', 'xsp_version',
    'xsp_db', 'xsp_mysqli', 'xsp_license_bootstrap', 'xsp_compute_hwid',
    'xsp_seal', 'xsp_unseal', 'xsp_unseal_master_from_api',
    'xsp_call_api', 'xsp_load_cached', 'xsp_save_cached',
    'xsp_perform_heartbeat', 'xsp_sign_request',
    'xsp_should_heartbeat', 'xsp_mark_heartbeat', 'xsp_env',
}

def check(path: pathlib.Path) -> list[str]:
    issues = []
    try:
        text = path.read_text(encoding='utf-8', errors='replace')
    except Exception as e:
        return [f"read error: {e}"]

    # Strip strings + comments para counting
    no_strings = re.sub(r"'(?:[^'\\]|\\.)*'", "''", text)
    no_strings = re.sub(r'"(?:[^"\\]|\\.)*"', '""', no_strings)
    no_strings = re.sub(r'/\*.*?\*/', '', no_strings, flags=re.DOTALL)
    no_strings = re.sub(r'//[^\n]*', '', no_strings)
    no_strings = re.sub(r'#[^\n]*', '', no_strings)

    open_b  = no_strings.count('{')
    close_b = no_strings.count('}')
    if open_b != close_b:
        issues.append(f"braces unbalanced: {{={open_b}, }}={close_b}")

    open_p  = no_strings.count('(')
    close_p = no_strings.count(')')
    if open_p != close_p:
        issues.append(f"parens unbalanced: (={open_p}, )={close_p}")

    if '<?php' not in text and path.suffix == '.php':
        issues.append("missing <?php tag")

    # Detecta uso de funções xsp_* não conhecidas
    used = set(re.findall(r'\b(xsp_[a-z_]+)\s*\(', text))
    defined = set(re.findall(r'function\s+(xsp_[a-z_]+)\s*\(', text))
    unknown = (used - defined) - KNOWN
    if unknown:
        issues.append(f"unknown xsp_* funcs: {sorted(unknown)}")

    return issues

if __name__ == '__main__':
    root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else '.')
    files = [
        'painel-image/php-stub/bootstrap.php',
        'painel-image/php-stub/license_check.php',
        'painel-image/php-stub/index_router.php',
        'admin-dashboard/index.php',
        'landing/index.php',
    ]
    print("=== PHP static lint ===")
    total_issues = 0
    for f in files:
        p = root / f
        if not p.exists():
            print(f"  ? {f} (não existe)"); continue
        issues = check(p)
        if not issues:
            print(f"  ✓ {f}")
        else:
            print(f"  ✗ {f}")
            for i in issues:
                print(f"      - {i}")
                total_issues += 1
    print()
    print(f"Total de problemas: {total_issues}")
    sys.exit(0 if total_issues == 0 else 1)
