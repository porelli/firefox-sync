-- The account the stack applies database-setup-fxa.sql with at every start, on your MySQL or
-- MariaDB server of the accounts (FXA_DB_BOOTSTRAP_USER, docs/databases.md#the-bootstrap-account):
-- it creates and changes users (CREATE USER, on the whole server), and has every privilege on the
-- accounts' databases only, with the right to grant them. Run once as an administrator of the
-- server; prepare_environment.sh fills in the placeholders and writes the result to
-- database-bootstrap-fxa.sql.
CREATE USER IF NOT EXISTS '@BOOTSTRAP_USER@'@'%' IDENTIFIED BY '@BOOTSTRAP_PASSWORD@';
ALTER USER '@BOOTSTRAP_USER@'@'%' IDENTIFIED BY '@BOOTSTRAP_PASSWORD@';
GRANT CREATE USER ON *.* TO '@BOOTSTRAP_USER@'@'%';
GRANT ALL PRIVILEGES ON `fxa`.* TO '@BOOTSTRAP_USER@'@'%' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON `fxa_oauth`.* TO '@BOOTSTRAP_USER@'@'%' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON `fxa_profile`.* TO '@BOOTSTRAP_USER@'@'%' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON `pushbox`.* TO '@BOOTSTRAP_USER@'@'%' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON `ffs`.* TO '@BOOTSTRAP_USER@'@'%' WITH GRANT OPTION;
