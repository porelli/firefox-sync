-- Setup migration 001, scope sync-bootstrap: the account the stack applies the setup migrations
-- of Sync (scope sync) with at every start, on your MariaDB or MySQL server
-- (SYNC_DB_BOOTSTRAP_USER, docs/databases.md#the-bootstrap-account).
-- Why: it creates and changes users (CREATE USER, on the whole server), reads which accounts
-- exist (the names and hosts of mysql.user, nothing else of it: an account of a stack name on
-- another host is never widened to '%'), and has every privilege on the stack's databases
-- only, with the right to grant them.
-- Released: with the setup migrations, the first file of the scope.
-- By hand: once, as an administrator of the server; prepare_environment.sh fills in the
-- placeholders and writes the result to database-bootstrap.sql.
-- Never edited once released (tests/setup_migrations.sh checks it against db/setup-manifest):
-- a change is a new file, with the next number, which the administrator runs (the bootstrap
-- account cannot give itself more).
CREATE USER IF NOT EXISTS '@BOOTSTRAP_USER@'@'%' IDENTIFIED BY '@BOOTSTRAP_PASSWORD@';
ALTER USER '@BOOTSTRAP_USER@'@'%' IDENTIFIED BY '@BOOTSTRAP_PASSWORD@';
GRANT CREATE USER ON *.* TO '@BOOTSTRAP_USER@'@'%';
GRANT SELECT (User, Host) ON mysql.user TO '@BOOTSTRAP_USER@'@'%';
GRANT ALL PRIVILEGES ON `@SYNC_TOKENSERVER_DATABASE@`.* TO '@BOOTSTRAP_USER@'@'%' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON `@SYNC_STORAGE_DATABASE@`.* TO '@BOOTSTRAP_USER@'@'%' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON `@ADMIN_DATABASE@`.* TO '@BOOTSTRAP_USER@'@'%' WITH GRANT OPTION;
