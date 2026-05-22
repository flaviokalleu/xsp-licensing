<?php
/**
 * Cliente de licença do painel.
 *
 * Funções principais:
 *   xsp_license_bootstrap(): valida licença com a API (ou usa cache local cifrado)
 *                             e destrava a extensão xsp_loader.
 *   xsp_compute_hwid():       deriva HWID estável da máquina.
 *
 * Cache local: token + master key cifrados com AES-256-GCM, chave derivada
 * do HWID. Validade máxima offline: 24h.
 */

declare(strict_types=1);

const XSP_STATE_DIR      = '/var/lib/xsp';
const XSP_TOKEN_CACHE    = XSP_STATE_DIR . '/token.cache';
const XSP_HEARTBEAT      = XSP_STATE_DIR . '/last_heartbeat';
const XSP_OFFLINE_MAX    = 86400; // 24h
const XSP_BEAT_EVERY     = 300;   // 5 min
const XSP_PANEL_ROOT     = '/var/www/html';
const XSP_MANIFEST_FILE  = XSP_PANEL_ROOT . '/.manifest';
const XSP_INTEGRITY_LOCK = XSP_STATE_DIR  . '/integrity.ok';
const XSP_INTEGRITY_TTL  = 3600; // re-verifica a cada 1h

function xsp_env(string $k, string $def = ''): string {
    $v = getenv($k);
    return ($v === false || $v === '') ? $def : $v;
}

function xsp_compute_hwid(): string {
    // Usa o HWID gravado pelo installer no .env — garante que bate com o valor
    // usado na ativação (o container não tem acesso ao blkid do host).
    $stored = xsp_env('XSP_HWID');
    if ($stored !== '') return $stored;

    // Fallback: recalcula (só funciona se rodando fora de container)
    $machineId = @trim((string)file_get_contents('/etc/machine-id'));
    $mac = '';
    foreach (glob('/sys/class/net/*/address') ?: [] as $f) {
        if (basename(dirname($f)) === 'lo') continue;
        $mac = trim((string)file_get_contents($f));
        if ($mac && $mac !== '00:00:00:00:00:00') break;
    }
    // Resolve UUID do root sem shell_exec (que pode estar em disable_functions).
    // Lê /proc/mounts para achar o device de / e depois resolve via /dev/disk/by-uuid/.
    $diskUuid = '';
    $rootDev  = '';
    foreach (file('/proc/mounts', FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) ?: [] as $line) {
        $parts = explode(' ', $line, 3);
        if (isset($parts[1]) && $parts[1] === '/') { $rootDev = realpath($parts[0]) ?: $parts[0]; break; }
    }
    if ($rootDev !== '') {
        foreach (glob('/dev/disk/by-uuid/*') ?: [] as $link) {
            if ((realpath($link) ?: readlink($link)) === $rootDev) {
                $diskUuid = basename($link);
                break;
            }
        }
    }
    $boardUuid = @trim((string)file_get_contents('/sys/class/dmi/id/product_uuid'));

    $sep = "\x1f";
    return hash('sha256', $machineId . $sep . $boardUuid . $sep . $diskUuid . $sep . $mac);
}

function xsp_seal(string $data, string $passphrase): string {
    $iv = random_bytes(12);
    $key = hash('sha256', $passphrase, true);
    $tag = '';
    $ct = openssl_encrypt($data, 'aes-256-gcm', $key, OPENSSL_RAW_DATA, $iv, $tag);
    if ($ct === false) {
        throw new RuntimeException('seal failed');
    }
    return base64_encode($iv . $tag . $ct);
}

function xsp_unseal(string $sealed, string $passphrase): ?string {
    $raw = base64_decode($sealed, true);
    if ($raw === false || strlen($raw) < 28) return null;
    $iv  = substr($raw, 0, 12);
    $tag = substr($raw, 12, 16);
    $ct  = substr($raw, 28);
    $key = hash('sha256', $passphrase, true);
    $pt = openssl_decrypt($ct, 'aes-256-gcm', $key, OPENSSL_RAW_DATA, $iv, $tag);
    return $pt === false ? null : $pt;
}

function xsp_unseal_master_from_api(string $sealedB64, string $nonceHex, string $hwid): string {
    $raw = base64_decode($sealedB64, true);
    if ($raw === false || strlen($raw) < 28) {
        throw new RuntimeException('invalid sealed master key');
    }
    $nonce = substr($raw, 0, 12);  // mesmos primeiros 12 bytes
    $ct = substr($raw, 12);
    $key = hash('sha256', $hwid . '|' . $nonceHex, true);
    $tagLen = 16;
    $body = substr($ct, 0, strlen($ct) - $tagLen);
    $tag  = substr($ct, -$tagLen);
    $pt = openssl_decrypt($body, 'aes-256-gcm', $key, OPENSSL_RAW_DATA, $nonce, $tag);
    if ($pt === false) {
        throw new RuntimeException('master_key unseal failed');
    }
    return bin2hex($pt);
}

function xsp_sign_request(string $method, string $path, string $body,
                          string $ts, string $nonce, string $secret): string {
    // A API armazena o secret como hex e decodifica para binário antes de usar.
    // Deve-se fazer o mesmo aqui para que as assinaturas batam.
    $keyBin = ctype_xdigit($secret) && strlen($secret) % 2 === 0
        ? hex2bin($secret)
        : $secret;
    return hash_hmac('sha256', $method . $path . $body . $ts . $nonce, $keyBin);
}

function xsp_call_api(string $method, string $path, array $payload,
                      ?string $installId = null): array {
    $base   = xsp_env('XSP_API_BASE');
    $secret = xsp_env('XSP_PUBLIC_SECRET');
    if ($base === '' || $secret === '') {
        throw new RuntimeException('XSP_API_BASE/XSP_PUBLIC_SECRET missing');
    }
    $body  = json_encode($payload, JSON_UNESCAPED_UNICODE);
    $ts    = (string)time();
    $nonce = bin2hex(random_bytes(16));
    $sig   = xsp_sign_request($method, $path, $body, $ts, $nonce, $secret);

    $ch = curl_init($base . $path);
    $headers = [
        'Content-Type: application/json',
        'X-Timestamp: ' . $ts,
        'X-Nonce: ' . $nonce,
        'X-Signature: ' . $sig,
        'User-Agent: xsp-panel/' . xsp_env('XSP_VERSION'),
    ];
    if ($installId !== null) $headers[] = 'X-Installation-ID: ' . $installId;

    curl_setopt_array($ch, [
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_CUSTOMREQUEST  => $method,
        CURLOPT_POSTFIELDS     => $body,
        CURLOPT_HTTPHEADER     => $headers,
        CURLOPT_TIMEOUT        => 8,
        CURLOPT_SSL_VERIFYPEER => true,
    ]);
    $resp = curl_exec($ch);
    $code = curl_getinfo($ch, CURLINFO_HTTP_CODE);
    $err  = curl_error($ch);
    curl_close($ch);

    if ($resp === false) {
        throw new RuntimeException('curl: ' . $err);
    }
    if ($code >= 400) {
        throw new RuntimeException("api $path http $code: $resp");
    }
    return json_decode((string)$resp, true) ?: [];
}

function xsp_load_cached(string $hwid): ?array {
    if (!is_file(XSP_TOKEN_CACHE)) return null;
    $sealed = (string)file_get_contents(XSP_TOKEN_CACHE);
    $raw = xsp_unseal($sealed, $hwid);
    if ($raw === null) return null;
    $data = json_decode($raw, true);
    if (!is_array($data)) return null;
    $age = time() - ((int)($data['cached_at'] ?? 0));
    if ($age > XSP_OFFLINE_MAX) return null;
    return $data;
}

function xsp_save_cached(array $data, string $hwid): void {
    @mkdir(XSP_STATE_DIR, 0700, true);
    $data['cached_at'] = time();
    file_put_contents(XSP_TOKEN_CACHE,
        xsp_seal(json_encode($data), $hwid),
        LOCK_EX);
    @chmod(XSP_TOKEN_CACHE, 0600);
}

function xsp_should_heartbeat(): bool {
    if (!is_file(XSP_HEARTBEAT)) return true;
    return (time() - (int)file_get_contents(XSP_HEARTBEAT)) >= XSP_BEAT_EVERY;
}

function xsp_mark_heartbeat(): void {
    @mkdir(XSP_STATE_DIR, 0700, true);
    file_put_contents(XSP_HEARTBEAT, (string)time());
}

/**
 * Verifica integridade dos arquivos .php.enc contra o manifest assinado.
 * Se detectar adulteração: reporta à API e lança exceção.
 */
function xsp_verify_integrity(?string $masterKeyHex): void {
    // Verifica no máximo 1x por hora (cache no volume de estado)
    if (is_file(XSP_INTEGRITY_LOCK)) {
        $age = time() - (int)file_get_contents(XSP_INTEGRITY_LOCK);
        if ($age < XSP_INTEGRITY_TTL) return;
    }

    if (!is_file(XSP_MANIFEST_FILE)) return; // imagem antiga sem manifest — ignora

    $lines = file(XSP_MANIFEST_FILE, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
    if ($lines === false) return;

    // Extrai HMAC da última linha de comentário
    $expectedHmac = null;
    $entries = [];
    foreach ($lines as $line) {
        if (str_starts_with($line, '# hmac-sha256:')) {
            $expectedHmac = trim(substr($line, strlen('# hmac-sha256:')));
        } elseif (!str_starts_with($line, '#')) {
            // formato: "<sha256>  <caminho relativo>"
            $parts = preg_split('/\s+/', $line, 2);
            if (count($parts) === 2) {
                $entries[$parts[1]] = $parts[0];
            }
        }
    }

    // Verifica HMAC do manifest usando master key (impede manifest falso)
    if ($masterKeyHex !== null && $expectedHmac !== null) {
        $manifestBody = implode("\n", array_filter($lines,
            fn($l) => !str_starts_with($l, '# hmac-sha256:')));
        $computedHmac = hash_hmac('sha256', $manifestBody . "\n", hex2bin($masterKeyHex));
        if (!hash_equals($expectedHmac, $computedHmac)) {
            xsp_report_tamper('manifest_hmac_invalid',
                ['expected' => substr($expectedHmac, 0, 8) . '...']);
            throw new RuntimeException('manifest integrity check failed');
        }
    }

    // Verifica SHA256 de cada arquivo .enc
    $tampered = [];
    foreach ($entries as $relPath => $expectedSha) {
        $absPath = XSP_PANEL_ROOT . '/' . $relPath;
        if (!is_file($absPath)) {
            $tampered[] = ['file' => $relPath, 'reason' => 'missing'];
            continue;
        }
        $actualSha = hash_file('sha256', $absPath);
        if ($actualSha !== $expectedSha) {
            $tampered[] = ['file' => $relPath, 'reason' => 'hash_mismatch',
                           'expected' => substr($expectedSha, 0, 8),
                           'got'      => substr($actualSha, 0, 8)];
        }
    }

    if (!empty($tampered)) {
        xsp_report_tamper('file_integrity_violation', ['files' => $tampered]);
        throw new RuntimeException('file integrity violation — panel tampered');
    }

    // Registra timestamp da última verificação bem-sucedida
    @mkdir(XSP_STATE_DIR, 0700, true);
    file_put_contents(XSP_INTEGRITY_LOCK, (string)time());
}

function xsp_report_tamper(string $kind, array $payload): void {
    try {
        $instId = xsp_env('XSP_INSTALLATION_ID');
        if ($instId === '') return;
        xsp_call_api('POST', '/v1/fraud', [
            'kind'     => $kind,
            'payload'  => $payload,
            'severity' => 5,
        ], $instId);
    } catch (Throwable) {
        // best-effort — não bloqueia o boot
    }
}

/**
 * Função principal. Garante licença válida + extensão destravada.
 * Lança RuntimeException se algo falhar.
 */
function xsp_license_bootstrap(): array {
    $hwid     = xsp_compute_hwid();
    $key      = xsp_env('XSP_LICENSE_KEY');
    $instId   = xsp_env('XSP_INSTALLATION_ID');

    // 1) Tenta cache primeiro (rota rápida)
    $cached = xsp_load_cached($hwid);
    if ($cached && !empty($cached['master_key_hex'])) {
        if (function_exists('xsp_unlock')) {
            xsp_unlock($cached['master_key_hex']);
        }
        // Verifica integridade dos arquivos cifrados (usa master key do cache)
        xsp_verify_integrity($cached['master_key_hex']);

        // Se passou da janela de heartbeat, faz async em best-effort
        if (xsp_should_heartbeat()) {
            try {
                xsp_perform_heartbeat($hwid, $instId);
                xsp_mark_heartbeat();
            } catch (Throwable $e) {
                // tolera falha de rede até 24h
            }
        }
        return $cached;
    }

    // 2) Sem cache válido — precisa de rede.
    if ($instId === '' || $key === '') {
        throw new RuntimeException('panel not activated yet (run installer)');
    }
    $data = xsp_perform_heartbeat($hwid, $instId);
    xsp_mark_heartbeat();
    // Verifica integridade após receber master key fresca da API
    xsp_verify_integrity($data['master_key_hex'] ?? null);
    return $data;
}

function xsp_perform_heartbeat(string $hwid, string $instId): array {
    if ($instId === '') {
        // bootstrap inicial dentro do container — usa /v1/activate
        $env = xsp_env('XSP_LICENSE_KEY');
        $resp = xsp_call_api('POST', '/v1/activate', [
            'key'              => $env,
            'hwid'             => $hwid,
            'hostname'         => gethostname(),
            'panel_version'    => xsp_env('XSP_VERSION'),
            'installer_version'=> xsp_env('XSP_VERSION'),
        ]);
    } else {
        $resp = xsp_call_api('POST', '/v1/heartbeat', [
            'hwid'         => $hwid,
            'panel_version'=> xsp_env('XSP_VERSION'),
        ], $instId);
    }

    if (empty($resp['master_key_sealed']) || empty($resp['master_key_nonce'])) {
        throw new RuntimeException('api missing master_key');
    }
    $masterHex = xsp_unseal_master_from_api(
        $resp['master_key_sealed'],
        $resp['master_key_nonce'],
        $hwid
    );
    if (function_exists('xsp_unlock')) {
        xsp_unlock($masterHex);
    } else {
        throw new RuntimeException('xsp_loader not loaded');
    }
    $data = $resp + ['master_key_hex' => $masterHex];
    xsp_save_cached($data, $hwid);
    // limpa hex local
    $masterHex = str_repeat("\0", strlen($masterHex));
    return $data;
}
