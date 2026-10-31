-- The Sync server on your PostgreSQL 11+ server (docs/databases.md#your-own-server).
-- Run with psql 10 or later as a superuser (or a role with CREATEROLE and CREATEDB).
-- prepare_environment.sh fills in the placeholders from .env and writes the result to
-- database-setup.sql. Run again, it changes nothing but the passwords: the roles and databases
-- are created when they are missing (\gexec runs the statement the SELECT before it returns,
-- none when it returns no row), so it runs with ON_ERROR_STOP too, as the stack's bootstrap
-- does (docs/databases.md#let-the-stack-apply-them). A database of that name that another role
-- owns is never taken over: it stops here, before any change.
SELECT EXISTS (SELECT FROM pg_catalog.pg_database WHERE datname = '@SYNC_POSTGRES_DATABASE@'
  AND pg_catalog.pg_get_userbyid(datdba) <> '@SYNC_POSTGRES_USER@') AS ffs_sync_foreign \gset
\if :ffs_sync_foreign
DO $$ BEGIN RAISE EXCEPTION 'the database @SYNC_POSTGRES_DATABASE@ exists and is not @SYNC_POSTGRES_USER@''s: database-setup.sql does not take it over. Give it to @SYNC_POSTGRES_USER@ yourself (ALTER DATABASE @SYNC_POSTGRES_DATABASE@ OWNER TO @SYNC_POSTGRES_USER@) if it is the stack''s, or choose another SYNC_POSTGRES_NAME (docs/databases.md#create-the-databases-and-users)'; END $$;
\quit
\endif
SELECT 'CREATE ROLE @SYNC_POSTGRES_USER@ LOGIN' WHERE NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '@SYNC_POSTGRES_USER@')
\gexec
-- (a new password after prepare_environment.sh ran again)
ALTER ROLE @SYNC_POSTGRES_USER@ LOGIN PASSWORD '@SYNC_POSTGRES_PASSWORD@';
-- CREATE DATABASE ... OWNER and REVOKE on that database need the role's membership, which
-- a CREATEROLE role does not get by itself on PostgreSQL 16+ (a superuser has it already)
SELECT 'GRANT @SYNC_POSTGRES_USER@ TO CURRENT_USER' WHERE NOT pg_catalog.pg_has_role(current_user, '@SYNC_POSTGRES_USER@', 'USAGE')
\gexec
-- the owner creates the tables (migrations), the post_bso type, check_user_limit() and
-- its trigger (MAX_USERS), and gives the admin UI's role its grants on them. No superuser
-- needed.
SELECT 'CREATE DATABASE @SYNC_POSTGRES_DATABASE@ OWNER @SYNC_POSTGRES_USER@' WHERE NOT EXISTS (SELECT FROM pg_catalog.pg_database WHERE datname = '@SYNC_POSTGRES_DATABASE@')
\gexec
-- other roles of a shared server: no connections, no temporary tables
REVOKE ALL ON DATABASE @SYNC_POSTGRES_DATABASE@ FROM PUBLIC;
-- The admin UI: its own database (the event log, the audit trail, notes, metrics, backup
-- runs), owned by @ADMIN_USER@ and closed to the other roles, the one above too; and
-- @ADMIN_SYNC_USER@, which reads the Sync tables and has nothing on the admin UI's database
-- (the code the owner above can put in its database runs as it). The init container (as
-- the owner of the Sync tables) gives it SELECT on them, UPDATE of max users, DELETE of rows
-- of users and of what they store (docs/reference/database-users.md#postgresql)
SELECT EXISTS (SELECT FROM pg_catalog.pg_database WHERE datname = '@ADMIN_DATABASE@'
  AND pg_catalog.pg_get_userbyid(datdba) <> '@ADMIN_USER@') AS ffs_admin_foreign \gset
\if :ffs_admin_foreign
DO $$ BEGIN RAISE EXCEPTION 'the database @ADMIN_DATABASE@ exists and is not @ADMIN_USER@''s: database-setup.sql does not take it over. Give it to @ADMIN_USER@ yourself if it is the stack''s, or choose another ADMIN_DB_NAME (docs/databases.md#create-the-databases-and-users)'; END $$;
\quit
\endif
SELECT 'CREATE ROLE @ADMIN_USER@ LOGIN' WHERE NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '@ADMIN_USER@')
\gexec
SELECT 'CREATE ROLE @ADMIN_SYNC_USER@ LOGIN' WHERE NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '@ADMIN_SYNC_USER@')
\gexec
ALTER ROLE @ADMIN_USER@ LOGIN PASSWORD '@ADMIN_PASSWORD@';
ALTER ROLE @ADMIN_SYNC_USER@ LOGIN PASSWORD '@ADMIN_PASSWORD@';
SELECT 'GRANT @ADMIN_USER@ TO CURRENT_USER' WHERE NOT pg_catalog.pg_has_role(current_user, '@ADMIN_USER@', 'USAGE')
\gexec
-- a copy of template0, not template1: on PostgreSQL 11 to 14 every role may create tables
-- in template1, the Sync server's role too (ffs_* tables of its own, with triggers, would
-- be copied here). No connection until PUBLIC lost them, no CREATE for PUBLIC in its public
-- schema (PostgreSQL 11 to 14 give it; as a role with CREATEROLE and CREATEDB only that
-- REVOKE may warn there: run it as a superuser). The admin UI does not start when a table
-- there is not its role's
SELECT 'CREATE DATABASE @ADMIN_DATABASE@ OWNER @ADMIN_USER@ TEMPLATE template0 ALLOW_CONNECTIONS false' WHERE NOT EXISTS (SELECT FROM pg_catalog.pg_database WHERE datname = '@ADMIN_DATABASE@')
\gexec
REVOKE ALL ON DATABASE @ADMIN_DATABASE@ FROM PUBLIC;
ALTER DATABASE @ADMIN_DATABASE@ ALLOW_CONNECTIONS true;
\connect @ADMIN_DATABASE@
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
