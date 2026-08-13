<?php
/**
 * db.php
 *
 * Returns a PDO connection to the private MySQL tier.
 * The application (web) tier is the only thing allowed to reach port 3306
 * on the database tier — enforced at the network layer by nsg-data
 * (see infra/main.bicep), not just at the application layer.
 */

require_once __DIR__ . '/config.php';

function get_db_connection(): PDO
{
    static $pdo = null;

    if ($pdo !== null) {
        return $pdo;
    }

    $dsn = sprintf(
        'mysql:host=%s;port=%s;dbname=%s;charset=utf8mb4',
        DB_HOST,
        DB_PORT,
        DB_NAME
    );

    $options = [
        PDO::ATTR_ERRMODE            => PDO::ERRMODE_EXCEPTION,
        PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
        PDO::ATTR_EMULATE_PREPARES   => false,
    ];

    try {
        $pdo = new PDO($dsn, DB_USER, DB_PASS, $options);
    } catch (PDOException $e) {
        http_response_code(503);
        header('Content-Type: application/json');
        echo json_encode([
            'success' => false,
            'message' => 'Reservation service is temporarily unavailable.',
        ]);
        // Log the real reason server-side only; never echo $e->getMessage() to the client.
        error_log('DB connection failed: ' . $e->getMessage());
        exit;
    }

    return $pdo;
}
