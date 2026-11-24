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

-- Keep a single sync node. If SYNC_PUBLIC_URL changed, syncstorage-rs added a
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

-- MAX_USERS (validated by db_init.sh): N or fixed:N sets the limit on every start
-- (the flag below is 1), initial:N only when there is none yet (first start, 0),
-- then it is managed in the admin UI and kept. N is a number or 'unlimited'.
INSERT INTO config (config_key, config_value)
VALUES ('max_users', '@MAX_USERS@')
ON DUPLICATE KEY UPDATE config_value = IF(@MAX_USERS_FIXED@, '@MAX_USERS@', config_value);

-- written by older versions, no longer used
DELETE FROM config WHERE config_key = 'max_users_env';

-- Create user limit stored procedure (idempotent)
-- syncstorage-rs inserts a new row for an existing account when its keys
-- change (e.g. password reset), so count accounts (emails), not rows, and
-- never block an account that is already registered.
DROP PROCEDURE IF EXISTS CheckUserLimit;

DELIMITER //
CREATE PROCEDURE CheckUserLimit(IN new_email VARCHAR(255))
BEGIN
    DECLARE user_count INT;
    DECLARE max_users_value VARCHAR(255) DEFAULT NULL;
    DECLARE max_users_setting INT;

    IF NOT EXISTS (SELECT 1 FROM users WHERE email = new_email) THEN
        -- Get max_users from config table, locking the row so concurrent
        -- sign-ups are counted one at a time; a missing value denies
        SELECT config_value INTO max_users_value
        FROM config
        WHERE config_key = 'max_users'
        FOR UPDATE;

        -- 'unlimited' (MAX_USERS=unlimited): no limit, nothing to count
        IF max_users_value IS NULL OR max_users_value <> 'unlimited' THEN
            SET max_users_setting = COALESCE(CAST(max_users_value AS UNSIGNED), 0);

            -- Get current account count
            SELECT COUNT(DISTINCT email) INTO user_count FROM users;

            -- Check if limit is exceeded
            IF user_count >= max_users_setting THEN
                SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'User limit exceeded';
            END IF;
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

-- What the admin UI changes here, with the privileges of this user: its own user
-- (ADMIN_DB_SYNC_USER) has SELECT on this database and EXECUTE on these procedures, nothing
-- that writes (db_init.sh gives the EXECUTE after this file, none on ffs_set_max_users with
-- ADMIN_ACCESS_EXTERNAL; docs/reference/database-users.md#mariadb-and-mysql)

-- max users, from the admin UI (MAX_USERS=initial:N): a number or 'unlimited', as above
DROP PROCEDURE IF EXISTS ffs_set_max_users;

DELIMITER //
CREATE PROCEDURE ffs_set_max_users(IN new_value VARCHAR(255))
BEGIN
    IF new_value <> 'unlimited' AND new_value NOT REGEXP '^[0-9]{1,10}$' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'max users must be a number or unlimited';
    END IF;
    UPDATE config SET config_value = new_value WHERE config_key = 'max_users';
END //
DELIMITER ;

-- one row of users (resets that free the max users slot, deleted accounts, purges)
DROP PROCEDURE IF EXISTS ffs_delete_user_row;

DELIMITER //
CREATE PROCEDURE ffs_delete_user_row(IN row_uid BIGINT)
BEGIN
    DELETE FROM users WHERE uid = row_uid;
END //
DELIMITER ;

-- the admin UI's tables of before ADMIN_DB_PASSWORD, once it moved them into its own
-- database
DROP PROCEDURE IF EXISTS ffs_drop_admin_tables;

DELIMITER //
CREATE PROCEDURE ffs_drop_admin_tables()
BEGIN
    DROP TABLE IF EXISTS ffs_events, ffs_metrics, ffs_gauges, ffs_account_notes,
        ffs_schema_levels, ffs_jobs, ffs_backups;
END //
DELIMITER ;