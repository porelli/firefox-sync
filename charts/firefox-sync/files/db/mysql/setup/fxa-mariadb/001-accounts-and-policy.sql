-- Setup migration 001, scope fxa: self-hosted Mozilla accounts on your MariaDB 11.4 or later
-- server (FXA_DB=mariadb, docs/reference/database-users.md#the-accounts); 12.x with our accounts
-- images only: Mozilla's migrations drop foreign keys by names MariaDB 12 does not give them,
-- fixed in ours (docs/accounts.md#mariadb-12). MySQL: ../fxa-mysql/.
-- Why: the users of the accounts, of the sign-up policy and of the admin UI, as
-- database-setup-fxa.sql created them before the setup migrations: an install from then is
-- recorded as this file (baseline) when its server has all of it.
-- Released: with the setup migrations, the first file of the scope.
-- By hand: as an administrator of the server, the placeholders filled in from .env.
-- prepare_environment.sh writes every file of the scope into database-setup-fxa.sql, with the
-- INSERTs that record them; `db-setup.sh pending fxa` prints only those your server lacks
-- (docs/databases.md#when-a-release-needs-new-users-or-grants). Without FXA_ADMIN_DB_PASSWORD
-- the lines of the admin UI's user (ffs_admin) do not run.
-- Never edited once released (tests/setup_migrations.sh checks it against db/setup-manifest):
-- a change is a new file, with the next number (the same in fxa-mysql and fxa-mariadb).
-- The server needs (my.cnf, or the parameter group of a managed service):
--   log_bin_trust_function_creators=ON (with binary logging: the sign-up policy's function and trigger)
-- The database names are fixed: fxa, fxa_oauth, fxa_profile, pushbox and ffs.
-- mysql_native_password, explicit whatever the server's default: MariaDB has no caching_sha2_password,
-- and both of the accounts' drivers speak it (mysql, and mysql2 with mozilla/fxa#21554)
-- (again: a new password after prepare_environment.sh ran again)
CREATE USER IF NOT EXISTS '@FXA_USER@'@'%' IDENTIFIED VIA mysql_native_password USING PASSWORD('@FXA_PASSWORD@');
ALTER USER '@FXA_USER@'@'%' IDENTIFIED VIA mysql_native_password USING PASSWORD('@FXA_PASSWORD@');
-- the migrations create these 4 databases and ~400 procedures; the accounts services use them
GRANT ALL PRIVILEGES ON `fxa`.* TO '@FXA_USER@'@'%';
GRANT ALL PRIVILEGES ON `fxa_oauth`.* TO '@FXA_USER@'@'%';
GRANT ALL PRIVILEGES ON `fxa_profile`.* TO '@FXA_USER@'@'%';
GRANT ALL PRIVILEGES ON `pushbox`.* TO '@FXA_USER@'@'%';
-- the sign-up policy (fxa-policy): the database ffs, a trigger on fxa.accounts, views and
-- procedures reading and deleting tokens, disabling and deleting accounts, turning off two-step
-- authentication, confirming emails and pruning expired tokens with its privileges (they call
-- FxA's own procedures: EXECUTE; fxa_profile and pushbox: their sizes and schema levels in the
-- admin UI, and the profile and push messages of a deleted account), and the grants
-- of the admin UI's user: SELECT on a few columns and on views without the secrets, EXECUTE
-- on those procedures, nothing that changes FxA's tables itself
CREATE USER IF NOT EXISTS '@FXA_POLICY_USER@'@'%' IDENTIFIED BY '@FXA_POLICY_PASSWORD@';
ALTER USER '@FXA_POLICY_USER@'@'%' IDENTIFIED BY '@FXA_POLICY_PASSWORD@';
GRANT ALL PRIVILEGES ON `ffs`.* TO '@FXA_POLICY_USER@'@'%' WITH GRANT OPTION;
GRANT SELECT, UPDATE, DELETE, TRIGGER, EXECUTE ON `fxa`.* TO '@FXA_POLICY_USER@'@'%' WITH GRANT OPTION;
GRANT SELECT, DELETE ON `fxa_oauth`.* TO '@FXA_POLICY_USER@'@'%' WITH GRANT OPTION;
GRANT SELECT, DELETE ON `fxa_profile`.* TO '@FXA_POLICY_USER@'@'%';
GRANT SELECT, DELETE ON `pushbox`.* TO '@FXA_POLICY_USER@'@'%';
-- the admin UI's user, created here: CREATE USER would let the policy user change the
-- password of any account on the server. fxa-policy gives it its grants once the
-- tables exist
CREATE USER IF NOT EXISTS 'ffs_admin'@'%' IDENTIFIED BY '@FXA_ADMIN_PASSWORD@';
ALTER USER 'ffs_admin'@'%' IDENTIFIED BY '@FXA_ADMIN_PASSWORD@';
