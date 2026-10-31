-- The role the stack applies database-setup.sql with at every start, on your PostgreSQL
-- server (SYNC_DB_BOOTSTRAP_USER, docs/databases.md#the-bootstrap-account): no superuser, it
-- creates roles and databases (CREATEROLE, CREATEDB). Run once with psql as a superuser;
-- prepare_environment.sh fills in the placeholders and writes the result to database-bootstrap.sql.
SELECT 'CREATE ROLE @BOOTSTRAP_USER@ LOGIN' WHERE NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '@BOOTSTRAP_USER@')
\gexec
ALTER ROLE @BOOTSTRAP_USER@ LOGIN CREATEROLE CREATEDB NOSUPERUSER PASSWORD '@BOOTSTRAP_PASSWORD@';
-- the stack's roles that exist already (created by another role, e.g. database-setup.sql run
-- by hand): PostgreSQL 16+ lets a CREATEROLE role change only the roles it administers
SELECT format('GRANT %I TO @BOOTSTRAP_USER@ WITH ADMIN OPTION', rolname) FROM pg_catalog.pg_roles WHERE rolname IN ('@SYNC_POSTGRES_USER@', '@ADMIN_USER@', '@ADMIN_SYNC_USER@')
\gexec
