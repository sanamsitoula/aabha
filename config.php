<?php
/**
 * config.php
 *
 * Central configuration for the booking backend.
 *
 * In the Azure deployment these values are injected as environment
 * variables on the application-tier VMSS instances (see infra/main.bicep,
 * the cloud-init customData block). Never hard-code real credentials here.
 * Falls back to local defaults so the app can also be run on a laptop
 * against a local MySQL instance for development.
 */

// --- Database tier (private subnet) ---
define('DB_HOST', getenv('DB_HOST') ?: '127.0.0.1');       // e.g. private IP / FQDN of MySQL flexible server
define('DB_PORT', getenv('DB_PORT') ?: '3306');
define('DB_NAME', getenv('DB_NAME') ?: 'restaurant_db');
define('DB_USER', getenv('DB_USER') ?: 'root');
define('DB_PASS', getenv('DB_PASS') ?: '');

// --- App behaviour ---
define('APP_ENV', getenv('APP_ENV') ?: 'development');     // development | production
define('ALLOWED_ORIGIN', getenv('ALLOWED_ORIGIN') ?: '*'); // restrict to your domain in production, e.g. https://www.aabha.example

// --- Reservation rules ---
define('MAX_GUESTS', 8);
define('MIN_GUESTS', 1);

// Show PHP errors only outside production
if (APP_ENV !== 'production') {
    ini_set('display_errors', '1');
    error_reporting(E_ALL);
} else {
    ini_set('display_errors', '0');
    error_reporting(0);
}
