-- Self-hosted Mozilla accounts on your MySQL 8.4 or 9.x server (docs/reference/database-users.md#the-accounts); MariaDB: fxa-mariadb.sql.
-- Run as an administrator of the server. prepare_environment.sh fills in the placeholders
-- from .env and writes the result to database-setup-fxa.sql.
-- The server needs (my.cnf, or the parameter group of a managed service):
--   log_bin_trust_function_creators=ON (the sign-up policy's function and trigger)
-- The database names are fixed: fxa, fxa_oauth, fxa_profile, pushbox and ffs.
-- The accounts' user has the server's default authentication (caching_sha2_password): accounts
-- images with mozilla/fxa#21554 (the mysql2 driver; ours, docs/accounts.md#mysql-or-mariadb). The images
-- without it (Mozilla's, ours from before) speak mysql_native_password only: a MySQL 8.4 server
-- with mysql_native_password=ON, and the "-- native:" lines instead of the ones after them
-- (prepare_environment.sh does that for such an image)
-- (again: a new password after prepare_environment.sh ran again)
-- native: CREATE USER IF NOT EXISTS '@FXA_USER@'@'%' IDENTIFIED WITH mysql_native_password BY '@FXA_PASSWORD@';
CREATE USER IF NOT EXISTS '@FXA_USER@'@'%' IDENTIFIED BY '@FXA_PASSWORD@';
-- native: ALTER USER '@FXA_USER@'@'%' IDENTIFIED WITH mysql_native_password BY '@FXA_PASSWORD@';
ALTER USER '@FXA_USER@'@'%' IDENTIFIED BY '@FXA_PASSWORD@';
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
