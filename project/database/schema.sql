-- schema.sql
-- Runs on the private-subnet MySQL tier (Azure Database for MySQL Flexible
-- Server, or a self-managed MySQL VM if you choose to build it that way).
--
-- This database is never exposed to the internet. Only the application-tier
-- subnet (snet-web) is allowed to reach it on port 3306, enforced by nsg-data.

CREATE DATABASE IF NOT EXISTS restaurant_db
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;

USE restaurant_db;

-- Application service account (least privilege: no DDL rights).
-- Run this once as an admin; change the password before using it anywhere real.
-- CREATE USER 'restaurant_app'@'%' IDENTIFIED BY 'change-this-password';
-- GRANT SELECT, INSERT, UPDATE ON restaurant_db.* TO 'restaurant_app'@'%';
-- FLUSH PRIVILEGES;

CREATE TABLE IF NOT EXISTS bookings (
    id                BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    reference         VARCHAR(12)      NOT NULL UNIQUE,
    name              VARCHAR(120)     NOT NULL,
    phone             VARCHAR(20)      NOT NULL,
    email             VARCHAR(255)     NOT NULL,
    guests            TINYINT UNSIGNED NOT NULL,
    booking_date      DATE             NOT NULL,
    booking_time      TIME             NOT NULL,
    special_requests  VARCHAR(500)     NULL,
    status            ENUM('pending', 'confirmed', 'cancelled') NOT NULL DEFAULT 'pending',
    created_at        DATETIME         NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at        DATETIME         NOT NULL DEFAULT CURRENT_TIMESTAMP
                                        ON UPDATE CURRENT_TIMESTAMP,

    INDEX idx_booking_date (booking_date),
    INDEX idx_email (email),
    INDEX idx_status (status)
) ENGINE=InnoDB;

-- Optional: a small table to support future capacity checks
-- (not wired up in booking.php yet — left here so you can extend the demo).
CREATE TABLE IF NOT EXISTS dining_tables (
    id         BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    label      VARCHAR(20)      NOT NULL,
    seats      TINYINT UNSIGNED NOT NULL
) ENGINE=InnoDB;

INSERT INTO dining_tables (label, seats) VALUES
    ('T1', 2), ('T2', 2), ('T3', 4), ('T4', 4),
    ('T5', 4), ('T6', 6), ('T7', 6), ('T8', 8),
    ('T9', 2), ('T10', 4), ('T11', 4), ('T12', 6);
