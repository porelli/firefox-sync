-- Setup migration 001, scope sync-bootstrap: the role the stack applies the setup migrations of
-- Sync (scope sync) with at every start, on your PostgreSQL server (SYNC_DB_BOOTSTRAP_USER,
-- docs/databases.md#the-bootstrap-account).
-- Why: no superuser, it creates roles and databases (CREATEROLE, CREATEDB); the stack's roles
-- are those it administers (ADMIN OPTION: the ones it creates, and below those that exist
-- already), never one of that name it does not. PostgreSQL 16 or later: before 16 CREATEROLE
-- reaches every role but the superusers (pg_* too), close to a superuser, and db-setup.sh
-- refuses the bootstrap there (run the setup by hand, check-only).
-- Released: with the setup migrations, the first file of the scope.
-- By hand: once, with psql as a superuser; prepare_environment.sh fills in the placeholders
-- and writes the result to database-bootstrap.sql.
-- Never edited once released (tests/setup_migrations.sh checks it against db/setup-manifest):
-- a change is a new file, with the next number, which the administrator runs (the bootstrap
-- account cannot give itself more).
SELECT 'CREATE ROLE @BOOTSTRAP_USER@ LOGIN' WHERE NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '@BOOTSTRAP_USER@')
\gexec
ALTER ROLE @BOOTSTRAP_USER@ LOGIN CREATEROLE CREATEDB NOSUPERUSER NOREPLICATION NOBYPASSRLS PASSWORD '@BOOTSTRAP_PASSWORD@';
-- the stack's roles that exist already (created by another role, e.g. database-setup.sql run
-- by hand): PostgreSQL 16+ lets a CREATEROLE role change only the roles it administers, and
-- the bootstrap takes a role of a stack name for the stack's only when it administers it. Run
-- by you, the superuser: make sure these roles are the stack's
SELECT format('GRANT %I TO @BOOTSTRAP_USER@ WITH ADMIN OPTION', rolname) FROM pg_catalog.pg_roles WHERE rolname IN ('@SYNC_POSTGRES_USER@', '@ADMIN_USER@', '@ADMIN_SYNC_USER@')
\gexec
