-- The Sync server on your MariaDB 10.10+ or MySQL 8.0 or later server (9 by default in the stack; docs/databases.md#your-own-server).
-- Run as an administrator of the server. prepare_environment.sh fills in the placeholders
-- from .env and writes the result to database-setup.sql.
-- Two databases: the migrations of both keep their state in a table of the same name.
CREATE DATABASE IF NOT EXISTS `@SYNC_TOKENSERVER_DATABASE@`;
CREATE DATABASE IF NOT EXISTS `@SYNC_STORAGE_DATABASE@`;
CREATE USER IF NOT EXISTS '@SYNC_TOKENSERVER_USER@'@'%' IDENTIFIED BY '@SYNC_TOKENSERVER_PASSWORD@';
CREATE USER IF NOT EXISTS '@SYNC_STORAGE_USER@'@'%' IDENTIFIED BY '@SYNC_STORAGE_PASSWORD@';
-- (again: a new password after prepare_environment.sh ran again)
ALTER USER '@SYNC_TOKENSERVER_USER@'@'%' IDENTIFIED BY '@SYNC_TOKENSERVER_PASSWORD@';
ALTER USER '@SYNC_STORAGE_USER@'@'%' IDENTIFIED BY '@SYNC_STORAGE_PASSWORD@';
-- tables (migrations; REFERENCES for their foreign keys on MySQL 8.0.22+), the init
-- container's config table, CheckUserLimit procedure and BeforeInsertUser trigger (MAX_USERS),
-- and the procedures the admin UI calls (ffs_set_max_users...)
GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER, DROP, INDEX, REFERENCES,
  CREATE ROUTINE, ALTER ROUTINE, EXECUTE, TRIGGER ON `@SYNC_TOKENSERVER_DATABASE@`.* TO '@SYNC_TOKENSERVER_USER@'@'%';
-- tables (migrations; one of them creates, calls and drops a procedure)
GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER, DROP, INDEX, REFERENCES,
  CREATE ROUTINE, ALTER ROUTINE, EXECUTE ON `@SYNC_STORAGE_DATABASE@`.* TO '@SYNC_STORAGE_USER@'@'%';
-- The admin UI: its own database (the event log, the audit trail, notes, metrics, backup
-- runs) and two users of its own, which the two users above cannot reach. @ADMIN_USER@ has
-- its database only (DROP and LOCK TABLES: a restore of its dump). @ADMIN_SYNC_USER@ reads
-- the Sync databases, and changes them only through the init container's procedures
-- (EXECUTE: max users, rows of users) and by deleting stored data (DELETE on the storage:
-- purges, resets); it has nothing on the admin UI's database, so the code the users above
-- can put in their databases (procedures, views, SQL SECURITY INVOKER) cannot reach it.
CREATE DATABASE IF NOT EXISTS `@ADMIN_DATABASE@`;
CREATE USER IF NOT EXISTS '@ADMIN_USER@'@'%' IDENTIFIED BY '@ADMIN_PASSWORD@';
CREATE USER IF NOT EXISTS '@ADMIN_SYNC_USER@'@'%' IDENTIFIED BY '@ADMIN_PASSWORD@';
ALTER USER '@ADMIN_USER@'@'%' IDENTIFIED BY '@ADMIN_PASSWORD@';
ALTER USER '@ADMIN_SYNC_USER@'@'%' IDENTIFIED BY '@ADMIN_PASSWORD@';
GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER, INDEX, DROP, LOCK TABLES ON `@ADMIN_DATABASE@`.* TO '@ADMIN_USER@'@'%';
GRANT SELECT, EXECUTE ON `@SYNC_TOKENSERVER_DATABASE@`.* TO '@ADMIN_SYNC_USER@'@'%';
GRANT SELECT, DELETE ON `@SYNC_STORAGE_DATABASE@`.* TO '@ADMIN_SYNC_USER@'@'%';
-- With the storage database on another server, run there instead of the line above:
-- CREATE USER IF NOT EXISTS '@ADMIN_SYNC_USER@'@'%' IDENTIFIED BY '@ADMIN_PASSWORD@';
-- ALTER USER '@ADMIN_SYNC_USER@'@'%' IDENTIFIED BY '@ADMIN_PASSWORD@';
-- GRANT SELECT, DELETE ON `@SYNC_STORAGE_DATABASE@`.* TO '@ADMIN_SYNC_USER@'@'%';
