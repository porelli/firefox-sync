-- Wait for migrations to complete by checking for required tables
-- This will be retried by the shell script until tables exist

-- Create configuration table if it doesn't exist
CREATE TABLE IF NOT EXISTS config (
    config_key VARCHAR(255) PRIMARY KEY,
    config_value VARCHAR(255) NOT NULL,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
);

-- Add service info (idempotent)
INSERT IGNORE INTO services (id, service, pattern) 
VALUES ('1', 'sync-1.5', '{node}/1.5/{uid}');

-- Add/update node info (idempotent)
INSERT INTO nodes (id, service, node, available, current_load, capacity, downed, backoff)
VALUES ('1', '1', '@DOMAIN@', '1', '0', '5', '0', '0') 
ON DUPLICATE KEY UPDATE node='@DOMAIN@';

-- Update MAX_USERS configuration (always update to current value)
INSERT INTO config (config_key, config_value) 
VALUES ('max_users', '@MAX_USERS@')
ON DUPLICATE KEY UPDATE config_value='@MAX_USERS@', updated_at=CURRENT_TIMESTAMP;

-- Create user limit stored procedure (idempotent)
DROP PROCEDURE IF EXISTS CheckUserLimit;

DELIMITER //
CREATE PROCEDURE CheckUserLimit()
BEGIN
    DECLARE user_count INT;
    DECLARE max_users_setting INT;
    
    -- Get current user count
    SELECT COUNT(*) INTO user_count FROM users;
    
    -- Get max_users from config table
    SELECT CAST(config_value AS UNSIGNED) INTO max_users_setting 
    FROM config 
    WHERE config_key = 'max_users';
    
    -- Check if limit is exceeded
    IF user_count >= max_users_setting THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'User limit exceeded';
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
    CALL CheckUserLimit();
END //
DELIMITER ;