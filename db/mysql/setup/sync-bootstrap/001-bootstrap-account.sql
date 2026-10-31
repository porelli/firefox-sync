-- Setup migration 001, scope sync-bootstrap: the account the stack applies the setup migrations
-- of Sync (scope sync) with at every start, on your MariaDB or MySQL server
-- (SYNC_DB_BOOTSTRAP_USER, docs/databases.md#the-bootstrap-account).
-- Why: it creates and changes users (CREATE USER, on the whole server: on MariaDB any account,
-- root too, nothing protects one; on MySQL all but those with SYSTEM_USER, which db-setup.sh
-- requires of every administrator, so other applications' accounts too), reads which accounts
-- exist (an account of a stack name on another host is never widened to '%'), and has every privilege on the stack's databases
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
-- which accounts exist: the names and hosts of mysql.user, never the passwords' hashes. On
-- MySQL also who is an administrator there (CREATE USER cannot change an account with
-- SYSTEM_USER: db-setup.sh requires it of every administrator): the privilege columns of
-- mysql.user and the privilege tables, which hold no secret. The "-- MySQL: " lines run on
-- MySQL only (prepare_environment.sh takes the comment out there)
GRANT SELECT (User, Host) ON mysql.user TO '@BOOTSTRAP_USER@'@'%';
-- MySQL: GRANT SELECT (Select_priv, Insert_priv, Update_priv, Delete_priv, Create_priv, Drop_priv, Reload_priv, Shutdown_priv, Process_priv, File_priv, Grant_priv, References_priv, Index_priv, Alter_priv, Show_db_priv, Super_priv, Create_tmp_table_priv, Lock_tables_priv, Execute_priv, Repl_slave_priv, Repl_client_priv, Create_view_priv, Show_view_priv, Create_routine_priv, Alter_routine_priv, Create_user_priv, Event_priv, Trigger_priv, Create_tablespace_priv, Create_role_priv, Drop_role_priv) ON mysql.user TO '@BOOTSTRAP_USER@'@'%';
-- MySQL: GRANT SELECT ON mysql.global_grants TO '@BOOTSTRAP_USER@'@'%';
-- MySQL: GRANT SELECT ON mysql.role_edges TO '@BOOTSTRAP_USER@'@'%';
-- MySQL: GRANT SELECT ON mysql.db TO '@BOOTSTRAP_USER@'@'%';
-- MySQL: GRANT SELECT ON mysql.tables_priv TO '@BOOTSTRAP_USER@'@'%';
-- MySQL: GRANT SELECT ON mysql.columns_priv TO '@BOOTSTRAP_USER@'@'%';
-- MySQL: GRANT SELECT ON mysql.procs_priv TO '@BOOTSTRAP_USER@'@'%';
-- MySQL: GRANT SELECT ON mysql.proxies_priv TO '@BOOTSTRAP_USER@'@'%';
GRANT ALL PRIVILEGES ON `@SYNC_TOKENSERVER_DATABASE@`.* TO '@BOOTSTRAP_USER@'@'%' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON `@SYNC_STORAGE_DATABASE@`.* TO '@BOOTSTRAP_USER@'@'%' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON `@ADMIN_DATABASE@`.* TO '@BOOTSTRAP_USER@'@'%' WITH GRANT OPTION;
