-- Applied after syncstorage-rs has run its migrations.
-- The sync-1.5 service and the node for @DOMAIN@ are created by syncstorage-rs
-- itself (tokenserver migrations and SYNC_TOKENSERVER__INIT_NODE_URL).

-- Create configuration table if it doesn't exist
CREATE TABLE IF NOT EXISTS config (
    config_key VARCHAR(255) PRIMARY KEY,
    config_value VARCHAR(255) NOT NULL,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Update MAX_USERS configuration (always update to current value)
INSERT INTO config (config_key, config_value)
VALUES ('max_users', '@MAX_USERS@')
ON CONFLICT (config_key) DO UPDATE
SET config_value = EXCLUDED.config_value, updated_at = CURRENT_TIMESTAMP;

-- Create user limit function (idempotent)
-- syncstorage-rs inserts a new row for an existing account when its keys
-- change (e.g. password reset), so count accounts (emails), not rows, and
-- never block an account that is already registered.
CREATE OR REPLACE FUNCTION check_user_limit() RETURNS trigger AS $$
DECLARE
    user_count INT;
    max_users_setting INT;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM users WHERE email = NEW.email) THEN
        -- Get current account count
        SELECT COUNT(DISTINCT email) INTO user_count FROM users;

        -- Get max_users from config table
        SELECT CAST(config_value AS INTEGER) INTO max_users_setting
        FROM config
        WHERE config_key = 'max_users';

        -- Check if limit is exceeded
        IF user_count >= max_users_setting THEN
            RAISE EXCEPTION 'User limit exceeded';
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Create trigger (idempotent)
DROP TRIGGER IF EXISTS before_insert_user ON users;

CREATE TRIGGER before_insert_user
BEFORE INSERT ON users
FOR EACH ROW
EXECUTE FUNCTION check_user_limit();
