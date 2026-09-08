-- IPTunnel License Server — Production Schema (v3 — Full Platform)
-- Run this in phpMyAdmin once after creating the database.
-- If upgrading from v2, run the ALTER/CREATE statements at the bottom.

CREATE TABLE IF NOT EXISTS `settings` (
    `setting_key`   VARCHAR(50)  NOT NULL,
    `setting_value` TEXT         NOT NULL DEFAULT '',
    PRIMARY KEY (`setting_key`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `admin_users` (
    `id`           INT          AUTO_INCREMENT PRIMARY KEY,
    `username`     VARCHAR(50)  NOT NULL UNIQUE,
    `password`     VARCHAR(255) NOT NULL,
    `role`         ENUM('superadmin','admin','viewer') NOT NULL DEFAULT 'admin',
    `created_at`   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `last_login`   DATETIME     NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `clients` (
    `id`            INT          AUTO_INCREMENT PRIMARY KEY,
    `name`          VARCHAR(100) NOT NULL,
    `email`         VARCHAR(255) NOT NULL DEFAULT '',
    `username`      VARCHAR(50)  NOT NULL UNIQUE,
    `password`      VARCHAR(255) NOT NULL,
    `token`         VARCHAR(255) NOT NULL DEFAULT '',
    `token_hash`    VARCHAR(64)  NOT NULL UNIQUE,
    `token_prefix`  VARCHAR(16)  NOT NULL DEFAULT '',
    `token_last4`   VARCHAR(4)   NOT NULL DEFAULT '',
    `max_servers`   INT          NOT NULL DEFAULT 0 COMMENT '0 = unlimited',
    `is_active`     TINYINT(1)   NOT NULL DEFAULT 1,
    `note`          TEXT         NOT NULL DEFAULT '',
    `created_at`    DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `last_login`    DATETIME     NULL,
    INDEX `idx_token`    (`token`),
    INDEX `idx_token_hint` (`token_prefix`, `token_last4`),
    INDEX `idx_active`   (`is_active`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `servers` (
    `server_id`     VARCHAR(32)  NOT NULL,
    `client_id`     INT          NULL DEFAULT NULL,
    `ip`            VARCHAR(45)  NOT NULL,
    `hostname`      VARCHAR(255) NOT NULL DEFAULT '',
    `token`         VARCHAR(255) NOT NULL DEFAULT '',
    `token_hash`    VARCHAR(64)  NOT NULL DEFAULT '',
    `country`       VARCHAR(2)   NOT NULL DEFAULT '' COMMENT 'ISO 3166-1 alpha-2',
    `city`          VARCHAR(100) NOT NULL DEFAULT '',
    `lat`           DECIMAL(9,6) NULL DEFAULT NULL,
    `lon`           DECIMAL(9,6) NULL DEFAULT NULL,
    `registered_at` DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `last_checkin`  DATETIME     NULL DEFAULT NULL,
    `health_status` VARCHAR(16)  NOT NULL DEFAULT 'unknown',
    `health_checked_at` DATETIME NULL DEFAULT NULL,
    `health_error`  VARCHAR(255) NOT NULL DEFAULT '',
    `health_endpoint` VARCHAR(255) NOT NULL DEFAULT '',
    `revoked`       TINYINT(1)   NOT NULL DEFAULT 0,
    `note`          TEXT         NOT NULL,
    PRIMARY KEY (`server_id`),
    INDEX `idx_ip`        (`ip`),
    INDEX `idx_token`     (`token`),
    INDEX `idx_token_hash` (`token_hash`),
    INDEX `idx_health_checked_at` (`health_checked_at`),
    INDEX `idx_client_id` (`client_id`),
    CONSTRAINT `fk_servers_client` FOREIGN KEY (`client_id`)
        REFERENCES `clients` (`id`) ON DELETE SET NULL ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `audit_logs` (
    `id`          INT          AUTO_INCREMENT PRIMARY KEY,
    `admin_user`  VARCHAR(50)  NOT NULL DEFAULT 'system',
    `action`      VARCHAR(50)  NOT NULL,
    `target`      VARCHAR(255) NOT NULL DEFAULT '',
    `detail`      TEXT         NOT NULL,
    `ip_address`  VARCHAR(45)  NOT NULL DEFAULT '',
    `created_at`  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    INDEX `idx_created` (`created_at`),
    INDEX `idx_action`  (`action`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `authorized_ips` (
    `id`         INT          AUTO_INCREMENT PRIMARY KEY,
    `client_id`  INT          NOT NULL,
    `ip`         VARCHAR(45)  NOT NULL,
    `label`      VARCHAR(100) NOT NULL DEFAULT '',
    `created_at` DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    INDEX `idx_ip`        (`ip`),
    INDEX `idx_client_id` (`client_id`),
    UNIQUE KEY `uq_client_ip` (`client_id`, `ip`),
    CONSTRAINT `fk_auth_ip_client` FOREIGN KEY (`client_id`)
        REFERENCES `clients` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `login_attempts` (
    `ip_address`   VARCHAR(45)  NOT NULL,
    `attempts`     INT          NOT NULL DEFAULT 0,
    `locked_until` DATETIME     NULL,
    `last_attempt` DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`ip_address`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ── v3 New Tables ─────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS `login_history` (
    `id`          INT          AUTO_INCREMENT PRIMARY KEY,
    `user_type`   ENUM('admin','client') NOT NULL,
    `user_id`     INT          NOT NULL,
    `username`    VARCHAR(50)  NOT NULL,
    `ip_address`  VARCHAR(45)  NOT NULL,
    `user_agent`  VARCHAR(500) NOT NULL DEFAULT '',
    `success`     TINYINT(1)   NOT NULL DEFAULT 1,
    `created_at`  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    INDEX `idx_user`    (`user_type`, `user_id`),
    INDEX `idx_created` (`created_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `webhooks` (
    `id`             INT          AUTO_INCREMENT PRIMARY KEY,
    `name`           VARCHAR(100) NOT NULL,
    `url`            VARCHAR(500) NOT NULL,
    `events`         VARCHAR(500) NOT NULL DEFAULT 'all' COMMENT 'Comma-separated: register,revoke,checkin_stale,client_login,all',
    `is_active`      TINYINT(1)   NOT NULL DEFAULT 1,
    `secret`         VARCHAR(255) NOT NULL DEFAULT '',
    `last_triggered` DATETIME     NULL,
    `last_status`    INT          NULL,
    `fail_count`     INT          NOT NULL DEFAULT 0,
    `created_at`     DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    INDEX `idx_active` (`is_active`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `subscriptions` (
    `id`          INT          AUTO_INCREMENT PRIMARY KEY,
    `client_id`   INT          NOT NULL,
    `plan`        VARCHAR(50)  NOT NULL DEFAULT 'free',
    `status`      ENUM('active','expired','cancelled','trial') NOT NULL DEFAULT 'active',
    `max_servers` INT          NOT NULL DEFAULT 0 COMMENT 'Overrides client.max_servers when active',
    `amount`      DECIMAL(10,2) NOT NULL DEFAULT 0.00,
    `currency`    VARCHAR(3)   NOT NULL DEFAULT 'USD',
    `starts_at`   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `expires_at`  DATETIME     NULL,
    `renewed_at`  DATETIME     NULL,
    `created_at`  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    INDEX `idx_client` (`client_id`),
    INDEX `idx_status` (`status`),
    INDEX `idx_expires` (`expires_at`),
    CONSTRAINT `fk_sub_client` FOREIGN KEY (`client_id`)
        REFERENCES `clients` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `install_tickets` (
    `ticket`      VARCHAR(64)  NOT NULL,
    `client_id`   INT          NOT NULL,
    `ip_address`  VARCHAR(45)  NOT NULL,
    `expires_at`  DATETIME     NOT NULL,
    `used_at`     DATETIME     NULL,
    `created_at`  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`ticket`),
    INDEX `idx_client` (`client_id`),
    INDEX `idx_expires` (`expires_at`),
    CONSTRAINT `fk_ticket_client` FOREIGN KEY (`client_id`)
        REFERENCES `clients` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `slowdns_install_codes` (
    `id` INT AUTO_INCREMENT PRIMARY KEY,
    `install_code` VARCHAR(32) NOT NULL UNIQUE,
    `request_ip` VARCHAR(45) NOT NULL DEFAULT '',
    `user_agent` VARCHAR(255) NOT NULL DEFAULT '',
    `status` ENUM('issued','consumed','expired') NOT NULL DEFAULT 'issued',
    `expires_at` DATETIME NOT NULL,
    `created_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `consumed_at` DATETIME NULL,
    INDEX `idx_status` (`status`),
    INDEX `idx_expires_at` (`expires_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `slowdns_install_activations` (
    `id` INT AUTO_INCREMENT PRIMARY KEY,
    `activation_id` VARCHAR(32) NOT NULL UNIQUE,
    `install_code_id` INT NOT NULL,
    `machine_id` VARCHAR(128) NOT NULL,
    `ssh_fingerprint` VARCHAR(255) NOT NULL,
    `public_ip` VARCHAR(45) NOT NULL,
    `hostname` VARCHAR(255) NOT NULL,
    `install_token` VARCHAR(1024) NOT NULL DEFAULT '',
    `install_token_expires_at` DATETIME NULL,
    `install_token_used_at` DATETIME NULL,
    `created_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `last_seen_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `released_at` DATETIME NULL,
    INDEX `idx_install_code_id` (`install_code_id`),
    INDEX `idx_binding` (`machine_id`, `ssh_fingerprint`(64)),
    CONSTRAINT `fk_slowdns_install_code` FOREIGN KEY (`install_code_id`)
        REFERENCES `slowdns_install_codes` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;


-- =====================================================================
-- UPGRADE FROM v2 → v3:
-- Run these statements if you already have v2 tables running.
-- =====================================================================
-- ALTER TABLE `admin_users` ADD COLUMN `role` ENUM('superadmin','admin','viewer') NOT NULL DEFAULT 'admin' AFTER `password`;
-- ALTER TABLE `servers` ADD COLUMN `country` VARCHAR(2) NOT NULL DEFAULT '' AFTER `token`;
-- ALTER TABLE `servers` ADD COLUMN `city` VARCHAR(100) NOT NULL DEFAULT '' AFTER `country`;
-- ALTER TABLE `servers` ADD COLUMN `lat` DECIMAL(9,6) NULL DEFAULT NULL AFTER `city`;
-- ALTER TABLE `servers` ADD COLUMN `lon` DECIMAL(9,6) NULL DEFAULT NULL AFTER `lat`;
-- ALTER TABLE `clients` MODIFY COLUMN `token` VARCHAR(255) NOT NULL DEFAULT '';
-- ALTER TABLE `clients` ADD COLUMN `token_hash` VARCHAR(64) NOT NULL DEFAULT '' AFTER `token`;
-- ALTER TABLE `clients` ADD COLUMN `token_prefix` VARCHAR(16) NOT NULL DEFAULT '' AFTER `token_hash`;
-- ALTER TABLE `clients` ADD COLUMN `token_last4` VARCHAR(4) NOT NULL DEFAULT '' AFTER `token_prefix`;
-- ALTER TABLE `clients` ADD UNIQUE KEY `uq_clients_token_hash` (`token_hash`);
-- ALTER TABLE `servers` ADD COLUMN `token_hash` VARCHAR(64) NOT NULL DEFAULT '' AFTER `token`;
-- ALTER TABLE `servers` ADD INDEX `idx_token_hash` (`token_hash`);
-- ALTER TABLE `webhooks` MODIFY COLUMN `secret` VARCHAR(255) NOT NULL DEFAULT '';
-- Then run the CREATE TABLE IF NOT EXISTS statements above for login_history, webhooks, subscriptions, install_tickets.


-- =====================================================================
-- UPGRADE FROM v1 → v3 (skip v2):
-- Run ALL the v2 upgrade steps first, then the v3 steps above.
-- =====================================================================
-- ALTER TABLE `servers` ADD COLUMN `client_id` INT NULL DEFAULT NULL AFTER `server_id`;
-- CREATE TABLE IF NOT EXISTS `clients` (...);   -- full v2 clients table
-- CREATE TABLE IF NOT EXISTS `authorized_ips` (...);  -- full v2 authorized_ips table
-- ALTER TABLE `servers` ADD INDEX `idx_client_id` (`client_id`);
-- ALTER TABLE `servers` ADD CONSTRAINT `fk_servers_client` FOREIGN KEY (`client_id`)
--     REFERENCES `clients` (`id`) ON DELETE SET NULL ON UPDATE CASCADE;
-- Then run the v3 upgrade steps above.


-- =====================================================================
-- PATCH: Add unique constraint to authorized_ips (run if upgrading)
-- =====================================================================
-- DELETE a1 FROM authorized_ips a1, authorized_ips a2 WHERE a1.id > a2.id AND a1.client_id = a2.client_id AND a1.ip = a2.ip;
-- ALTER TABLE authorized_ips ADD UNIQUE KEY `uq_client_ip` (`client_id`, `ip`);

-- =====================================================================
-- PATCH: Allow admin-owned zero-touch (no client required)
-- Run these if you want admin servers to support zero-touch install.
-- =====================================================================
-- ALTER TABLE `authorized_ips`
--   DROP FOREIGN KEY `fk_auth_ip_client`,
--   DROP INDEX `uq_client_ip`,
--   MODIFY `client_id` INT NULL DEFAULT NULL;
-- ALTER TABLE `install_tickets`
--   DROP FOREIGN KEY `fk_ticket_client`,
--   MODIFY `client_id` INT NULL DEFAULT NULL;
