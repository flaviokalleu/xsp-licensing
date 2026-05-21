<?php
/**
 * XSP Panel — bootstrap em claro.
 *
 * Este é o ÚNICO arquivo .php que fica legível dentro do container.
 * Responsabilidades:
 *   1. Validar licença online (via license_check.php).
 *   2. Receber a master key cifrada (com HWID) da API, decifrar localmente.
 *   3. Chamar xsp_unlock() na extensão C para destravar os .php.enc.
 *   4. Carregar o front controller real através do stream wrapper xsp://.
 *
 * Nenhum segredo permanente reside neste arquivo.
 */

declare(strict_types=1);

if (!extension_loaded('xsp_loader')) {
    http_response_code(500);
    die('xsp_loader extension not loaded');
}

require __DIR__ . '/license_check.php';

try {
    $tok = xsp_license_bootstrap();   // valida + faz unlock da extensão
} catch (Throwable $e) {
    http_response_code(402);
    header('Content-Type: application/json');
    echo json_encode([
        'error' => 'license_required',
        'message' => $e->getMessage(),
        'support' => 'suporte@seudominio.com',
    ]);
    exit;
}

// A partir daqui, o painel original está disponível via xsp://
// Roteia para o entrypoint real (index.php do painel atual).
$panelRoot = '/var/www/html';
require 'xsp://' . $panelRoot . '/' . ltrim($_SERVER['SCRIPT_NAME'] ?? '/index.php', '/');
