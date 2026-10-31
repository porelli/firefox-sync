-- The account the stack applies database-setup.sql with at every start, on your MariaDB or
-- MySQL server (SYNC_DB_BOOTSTRAP_USER, docs/databases.md#the-bootstrap-account): it creates and
-- changes users (CREATE USER, on the whole server), and has every privilege on the stack's
-- databases only, with the right to grant them. Run once as an administrator of the server;
-- prepare_environment.sh fills in the placeholders and writes the result to database-bootstrap.sql.
CREATE USER IF NOT EXISTS '@BOOTSTRAP_USER@'@'%' IDENTIFIED BY '@BOOTSTRAP_PASSWORD@';
ALTER USER '@BOOTSTRAP_USER@'@'%' IDENTIFIED BY '@BOOTSTRAP_PASSWORD@';
GRANT CREATE USER ON *.* TO '@BOOTSTRAP_USER@'@'%';
GRANT ALL PRIVILEGES ON `@SYNC_TOKENSERVER_DATABASE@`.* TO '@BOOTSTRAP_USER@'@'%' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON `@SYNC_STORAGE_DATABASE@`.* TO '@BOOTSTRAP_USER@'@'%' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON `@ADMIN_DATABASE@`.* TO '@BOOTSTRAP_USER@'@'%' WITH GRANT OPTION;
