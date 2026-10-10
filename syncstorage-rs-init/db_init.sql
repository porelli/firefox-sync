-- Wait for migrations to complete by checking for required tables
-- This will be retried by the shell script until tables exist

-- Create configuration table if it doesn't exist
CREATE TABLE IF NOT EXISTS config (
    config_key VARCHAR(255) PRIMARY KEY,
    config_value VARCHAR(255) NOT NULL,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
);

-- The sync-1.5 service and the node for @DOMAIN@ are created by syncstorage-rs
-- itself (tokenserver migrations and SYNC_TOKENSERVER__INIT_NODE_URL).
-- Do not hardcode their ids here: on fresh databases sync-1.5 is not id 1.

-- Keep a single sync node. If SYNCSTORAGE_DOMAIN changed, syncstorage-rs added a
-- node for the new domain but the old one is still in rotation and its users still
-- point to it: move them to the current node and take the old nodes out
UPDATE nodes n
JOIN services s ON s.service = 'sync-1.5' AND n.service = s.id
SET n.downed = 0, n.available = n.capacity
WHERE n.node = '@DOMAIN@' AND n.downed = 1;

UPDATE users u
JOIN services s ON s.service = 'sync-1.5' AND u.service = s.id
JOIN nodes n ON n.service = s.id AND n.node = '@DOMAIN@'
SET u.nodeid = n.id
WHERE u.nodeid <> n.id;

UPDATE nodes n
JOIN services s ON s.service = 'sync-1.5' AND n.service = s.id
SET n.available = 0, n.downed = 1
WHERE n.node <> '@DOMAIN@';

-- Update MAX_USERS configuration (always update to current value)
INSERT INTO config (config_key, config_value) 
VALUES ('max_users', '@MAX_USERS@')
ON DUPLICATE KEY UPDATE config_value='@MAX_USERS@', updated_at=CURRENT_TIMESTAMP;

-- Create user limit stored procedure (idempotent)
-- syncstorage-rs inserts a new row for an existing account when its keys
-- change (e.g. password reset), so count accounts (emails), not rows, and
-- never block an account that is already registered.
DROP PROCEDURE IF EXISTS CheckUserLimit;

DELIMITER //
CREATE PROCEDURE CheckUserLimit(IN new_email VARCHAR(255))
BEGIN
    DECLARE user_count INT;
    DECLARE max_users_setting INT;

    IF NOT EXISTS (SELECT 1 FROM users WHERE email = new_email) THEN
        -- Get max_users from config table, locking the row so concurrent
        -- sign-ups are counted one at a time; a missing value denies
        SELECT CAST(config_value AS UNSIGNED) INTO max_users_setting
        FROM config
        WHERE config_key = 'max_users'
        FOR UPDATE;
        SET max_users_setting = COALESCE(max_users_setting, 0);

        -- Get current account count
        SELECT COUNT(DISTINCT email) INTO user_count FROM users;

        -- Check if limit is exceeded
        IF user_count >= max_users_setting THEN
            SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'User limit exceeded';
        END IF;
    END IF;
END //
DELIMITER ;

-- Create trigger (idempotent)
DROP TRIGGER IF EXISTS BeforeInsertUser;

DELIMITER //
CREATE TRIGGER BeforeInsertUser
BEFORE INSERT ON users
FOR EACH ROW
BEGIN
    CALL CheckUserLimit(NEW.email);
END //
DELIMITER ;