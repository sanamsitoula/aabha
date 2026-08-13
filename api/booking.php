<?php
/**
 * api/booking.php
 *
 * POST /api/booking.php
 * Accepts a JSON reservation request from the public website, validates it,
 * and stores it in the private MySQL tier. Returns a JSON response with a
 * human-readable booking reference.
 *
 * This file is deployed on the application-tier VMSS instances, behind the
 * Application Gateway. It never runs on, or talks directly to, anything
 * internet-facing other than through the load balancer.
 */

require_once __DIR__ . '/../config.php';
require_once __DIR__ . '/../db.php';

header('Content-Type: application/json');
header('Access-Control-Allow-Origin: ' . ALLOWED_ORIGIN);
header('Access-Control-Allow-Methods: POST, OPTIONS');
header('Access-Control-Allow-Headers: Content-Type');

// Preflight
if ($_SERVER['REQUEST_METHOD'] === 'OPTIONS') {
    http_response_code(204);
    exit;
}

if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
    http_response_code(405);
    echo json_encode(['success' => false, 'message' => 'Method not allowed.']);
    exit;
}

function fail(int $code, string $message): void
{
    http_response_code($code);
    echo json_encode(['success' => false, 'message' => $message]);
    exit;
}

$raw = file_get_contents('php://input');
$input = json_decode($raw, true);

if (!is_array($input)) {
    fail(400, 'Invalid request body.');
}

// --- Validate & sanitize ---
$name     = trim((string)($input['name'] ?? ''));
$phone    = trim((string)($input['phone'] ?? ''));
$email    = trim((string)($input['email'] ?? ''));
$guests   = (int)($input['guests'] ?? 0);
$date     = trim((string)($input['date'] ?? ''));
$time     = trim((string)($input['time'] ?? ''));
$requests = trim((string)($input['requests'] ?? ''));

if ($name === '' || mb_strlen($name) > 120) {
    fail(422, 'Please provide a valid name.');
}
if ($phone === '' || !preg_match('/^[0-9+\-\s()]{6,20}$/', $phone)) {
    fail(422, 'Please provide a valid phone number.');
}
if ($email === '' || !filter_var($email, FILTER_VALIDATE_EMAIL)) {
    fail(422, 'Please provide a valid email address.');
}
if ($guests < MIN_GUESTS || $guests > MAX_GUESTS) {
    fail(422, 'Party size must be between ' . MIN_GUESTS . ' and ' . MAX_GUESTS . '.');
}

$dt = DateTime::createFromFormat('Y-m-d', $date);
if (!$dt || $dt->format('Y-m-d') !== $date) {
    fail(422, 'Please provide a valid date.');
}
$today = new DateTime('today');
if ($dt < $today) {
    fail(422, 'Reservation date cannot be in the past.');
}

if (!preg_match('/^([01]\d|2[0-3]):[0-5]\d$/', $time)) {
    fail(422, 'Please provide a valid time.');
}

if (mb_strlen($requests) > 500) {
    fail(422, 'Notes must be under 500 characters.');
}

// --- Persist ---
$pdo = get_db_connection();

$reference = strtoupper(substr(bin2hex(random_bytes(4)), 0, 6));

try {
    $stmt = $pdo->prepare(
        'INSERT INTO bookings
            (reference, name, phone, email, guests, booking_date, booking_time, special_requests, status, created_at)
         VALUES
            (:reference, :name, :phone, :email, :guests, :booking_date, :booking_time, :special_requests, "pending", NOW())'
    );

    $stmt->execute([
        ':reference'        => $reference,
        ':name'             => $name,
        ':phone'            => $phone,
        ':email'            => $email,
        ':guests'           => $guests,
        ':booking_date'     => $date,
        ':booking_time'     => $time,
        ':special_requests' => $requests !== '' ? $requests : null,
    ]);
} catch (PDOException $e) {
    error_log('Booking insert failed: ' . $e->getMessage());
    fail(500, 'Could not save your reservation. Please try again.');
}

http_response_code(201);
echo json_encode([
    'success'   => true,
    'message'   => 'Reservation received.',
    'reference' => $reference,
]);
