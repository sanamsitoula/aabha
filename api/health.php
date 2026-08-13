<?php
/**
 * api/health.php
 *
 * Lightweight health probe used by the Application Gateway backend health
 * check and the VMSS autoscale/monitoring pipeline. Verifies the app tier
 * can reach the database tier without doing any real work.
 */

header('Content-Type: application/json');

require_once __DIR__ . '/../config.php';
require_once __DIR__ . '/../db.php';

try {
    $pdo = get_db_connection();
    $pdo->query('SELECT 1');
    http_response_code(200);
    echo json_encode(['status' => 'ok']);
} catch (Throwable $e) {
    http_response_code(503);
    echo json_encode(['status' => 'unhealthy']);
}
