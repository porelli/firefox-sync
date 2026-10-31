-- Setup migration 001, scope fxa-bootstrap: the account the stack applies the setup migrations
-- of the accounts (scope fxa) with at every start, on your MySQL or MariaDB server of the
-- accounts (FXA_DB_BOOTSTRAP_USER, docs/databases.md#the-bootstrap-account).
-- Why: it creates and changes users (CREATE USER, on the whole server: on MariaDB any account,
-- root too, nothing protects one; on MySQL all but those with SYSTEM_USER, which db-setup.sh
-- requires of every administrator), reads which accounts exist and which are administrators
-- (an account of a stack name on another host is never widened to '%'), and has every privilege on the accounts' databases
-- only, with the right to grant them.
-- Released: with the setup migrations, the first file of the scope.
-- By hand: once, as an administrator of the server; prepare_environment.sh fills in the
-- placeholders and writes the result to database-bootstrap-fxa.sql.
-- Never edited once released (tests/setup_migrations.sh checks it against db/setup-manifest):
-- a change is a new file, with the next number, which the administrator runs (the bootstrap
-- account cannot give itself more).
CREATE USER IF NOT EXISTS '@BOOTSTRAP_USER@'@'%' IDENTIFIED BY '@BOOTSTRAP_PASSWORD@';
ALTER USER '@BOOTSTRAP_USER@'@'%' IDENTIFIED BY '@BOOTSTRAP_PASSWORD@';
GRANT CREATE USER ON *.* TO '@BOOTSTRAP_USER@'@'%';
-- which accounts exist and which are administrators: the names and hosts of mysql.user and
-- its administrator columns, never the passwords' hashes; on MySQL also mysql.global_grants
-- (who holds SYSTEM_USER: every administrator must, so that this account cannot change it).
-- The "-- MySQL: " line runs on MySQL only (prepare_environment.sh takes the comment out there)
GRANT SELECT (User, Host, Super_priv, Create_user_priv, Grant_priv) ON mysql.user TO '@BOOTSTRAP_USER@'@'%';
-- MySQL: GRANT SELECT ON mysql.global_grants TO '@BOOTSTRAP_USER@'@'%';
GRANT ALL PRIVILEGES ON `fxa`.* TO '@BOOTSTRAP_USER@'@'%' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON `fxa_oauth`.* TO '@BOOTSTRAP_USER@'@'%' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON `fxa_profile`.* TO '@BOOTSTRAP_USER@'@'%' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON `pushbox`.* TO '@BOOTSTRAP_USER@'@'%' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON `ffs`.* TO '@BOOTSTRAP_USER@'@'%' WITH GRANT OPTION;
