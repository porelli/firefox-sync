# Database users

Reference: the database users the stack uses on each backend, what each one can do, and why. The SQL files are the source, the [setup migrations](../databases.md#setup-migrations) of [db/mysql/setup/sync/](/db/mysql/setup/sync), [db/postgres/setup/sync/](/db/postgres/setup/sync), [db/mysql/setup/fxa-mysql/](/db/mysql/setup/fxa-mysql) and [db/mysql/setup/fxa-mariadb/](/db/mysql/setup/fxa-mariadb). How to run them on your own server: [Create the databases and users](../databases.md#create-the-databases-and-users).

## MariaDB and MySQL

[db/mysql/setup/sync/](/db/mysql/setup/sync) creates two databases, a user for each, and the admin UI's database and two users.

| User (setting, default) | Grants | What it does with them |
|---|---|---|
| tokenserver (`SYNC_TOKENSERVER_DB_USER`, `tokenserver`) | `SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER, DROP, INDEX, REFERENCES, CREATE ROUTINE, ALTER ROUTINE, EXECUTE, TRIGGER` on the tokenserver database | creates the tables (the migrations), the init container's `config` table, the `CheckUserLimit` procedure and the `BeforeInsertUser` trigger that enforce `SYNC_MAX_USERS`, and the procedures the admin UI calls: `ffs_set_max_users`, `ffs_delete_user_row` and `ffs_drop_admin_tables` |
| storage (`SYNC_STORAGE_DB_USER`, `syncstorage`) | the same on the storage database, without `TRIGGER` | creates the tables (the migrations; one of them creates, calls and drops a procedure) |
| `ffs_admin_ui` (`ADMIN_DB_USER`) | `SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER, INDEX, DROP, LOCK TABLES` on `ffs_admin` only | the admin UI's own data. `DROP` and `LOCK TABLES` are for a restore of its dump |
| `ffs_admin_sync` (`ADMIN_DB_SYNC_USER`) | `SELECT, EXECUTE` on the tokenserver database, `SELECT, DELETE` on the storage database | reads the Sync data. Changes max users and deletes rows of `users` only through the procedures above. Deletes stored data for purges and resets |

Notes:

- `REFERENCES` is needed on MySQL 8.0.22 and later, for the tokenserver's foreign keys.
- Two databases, not one: the migrations of both keep their state in a table of the same name.
- With the storage database on another server, run there the three `ffs_admin_sync` statements commented at the end of the file. Leave out the storage `GRANT` on the tokenserver's server. `ffs_admin_ui` and `ffs_admin` are on the tokenserver's server only.
- On MySQL the users have the server's default, `caching_sha2_password`.

## PostgreSQL

**Never run the Sync server, or your own `psql`, `pg_dump` or `pg_restore` on the Sync database, as a superuser.** Connect as the owner of the Sync tables: `SYNC_POSTGRES_APP_USER` in the stack's container, `SYNC_POSTGRES_USER` on your own server.

[db/postgres/setup/sync/](/db/postgres/setup/sync) creates:

| Role | What it is |
|---|---|
| `SYNC_POSTGRES_USER` (`syncserver`) | the owner of the Sync database. It creates the tables, the `post_bso` type, the `check_user_limit()` function and its trigger, and the `ffs_drop_admin_tables()` function. At every start it gives `ffs_admin_sync` its grants on them. No superuser, `CREATEDB` or `CREATEROLE` |
| `ffs_admin_ui` (`ADMIN_DB_USER`) | the owner of `ffs_admin`, which is closed to every other role. Nothing on the Sync database (no `CONNECT`) |
| `ffs_admin_sync` (`ADMIN_DB_SYNC_USER`) | on the Sync database: `CONNECT`, `SELECT` on its tables, `UPDATE (config_value)` of `config` (max users), `DELETE` on `users`, `bsos`, `user_collections`, `batches` and `batch_bsos`, and `EXECUTE` on `ffs_drop_admin_tables()`. Nothing on `ffs_admin` |

Running the file:

- Run it as a superuser, or as a role with `CREATEROLE` and `CREATEDB`, which is what managed services give you (tested). Its `GRANT ... TO CURRENT_USER` lets that role create a database owned by the new one, which PostgreSQL 16 and later require.
- Run again, `CREATE ROLE` and `CREATE DATABASE` fail with "already exists" and `psql -f` goes on. The `ALTER ROLE` sets the new password.
- The `REVOKE` keeps the other roles of a shared server out: no connections, no temporary tables.
- For a database that already exists: `ALTER DATABASE syncserver OWNER TO syncserver;`.
- Leave `SYNC_POSTGRES_APP_USER` empty on your own server: it is for the stack's container, where `SYNC_POSTGRES_USER` is a superuser.
- On PostgreSQL 11 to 14 every role can create objects in the `public` schema of every database. Close it in the Sync database, as a superuser (since PostgreSQL 15 it is the default):

  ```bash
  psql -h db.example.com -U postgres -d syncserver -c 'REVOKE CREATE ON SCHEMA public FROM PUBLIC; ALTER SCHEMA public OWNER TO syncserver;'
  ```

<details><summary>Why: template0, and the superuser of the stack's container</summary>

`ffs_admin` is a copy of `template0`, not of `template1`. On PostgreSQL 11 to 14 every role may create tables in `template1`, so the Sync server's role could leave `ffs_*` tables with triggers there, to be copied into `ffs_admin`. Its `public` schema also gives `PUBLIC` no `CREATE`. The admin UI does not start when something there (a table, function, operator, type or schema) is not `ffs_admin_ui`'s, and its setup check says what.

In the stack's container, `SYNC_POSTGRES_USER` is the image's superuser, and a superuser reaches every database. So the Sync server does not connect as it:

- `sync_role_init` creates `SYNC_POSTGRES_APP_USER` (`syncserver_app`, no superuser) before the migrations. At every start it gives that role the right to create tables, and every table, function and type of the Sync database ([sync_owner.sql](/db/postgres/init/sync_owner.sql) does that for an install from before it).
- The migrations, the init container's `db_init.sql` and the backups run as that role.
- As the superuser runs only what executes no code of the Sync tables' owner: creating and changing roles and databases, the grants and the change of owner, with only `pg_catalog` in the search path.
- Whatever reads or writes those tables does it as their owner, over a login of its own. Not with `SET ROLE`, which code can undo. A trigger, rule, view or function the Sync server's role put there runs with its own rights only.

`tests/e2e.sh` has that role plant code that would make it a superuser: triggers on `config` and `nodes`, `config` itself as a view calling its function, and an operator `<>` of its own in `public`. Then it runs the migrations and the init container again, and checks that none of it ran as a superuser.

Without `SYNC_POSTGRES_APP_USER` (an install from before it), the Sync server stays `SYNC_POSTGRES_USER`, and the admin UI's setup check of the event log fails, saying so.

</details>

## The accounts

[db/mysql/setup/fxa-mysql/](/db/mysql/setup/fxa-mysql) and [db/mysql/setup/fxa-mariadb/](/db/mysql/setup/fxa-mariadb) differ only in how the accounts' user signs in. `FXA_DB` picks the file. The database names are fixed (`fxa`, `fxa_oauth`, `fxa_profile`, `pushbox`, `ffs`): a server or instance of its own for the accounts is best.

| User (setting, default on your server) | Grants | What it does with them |
|---|---|---|
| `FXA_MYSQL_USER` (`fxa`) | `ALL PRIVILEGES` on `fxa`, `fxa_oauth`, `fxa_profile` and `pushbox` | Mozilla's migrations create the four databases, their tables and about 400 procedures. The accounts services use them |
| `FXA_MYSQL_POLICY_USER` (`ffs_policy`) | `ALL` on `ffs` with `GRANT OPTION`; `SELECT, UPDATE, DELETE, TRIGGER, EXECUTE` on `fxa` and `SELECT, DELETE` on `fxa_oauth`, both with `GRANT OPTION`; `SELECT, DELETE` on `fxa_profile` and `pushbox` | `fxa-policy` installs the [sign-up policy](../accounts.md#who-can-sign-up) and the admin UI's views and procedures at every start, and gives the admin UI's user its grants |
| `ffs_admin` (`FXA_ADMIN_DB_PASSWORD`) | what `fxa-policy` gives it: `SELECT` on a few columns of `fxa.accounts` and on the views, `EXECUTE` on the procedures | the admin UI's user on the accounts database |

How the accounts' user signs in:

- MySQL, with our accounts images: the server's default, `caching_sha2_password`.
- MySQL, with an image without mozilla/fxa#21554: `mysql_native_password`, the file's `-- native:` lines. `prepare_environment.sh` uses them for such an image. See [MySQL 9](../accounts.md#mysql-9).
- MariaDB: `mysql_native_password`, explicitly. MariaDB has no `caching_sha2_password`, and both drivers speak it.

What the policy user installs at every start ([admin/fxainit.go](/admin/fxainit.go)), and what the admin UI's user `ffs_admin` gets on it:

| Object | What it is | `ffs_admin` |
|---|---|---|
| `ffs.settings` | the sign-up policy, `FXA_MAX_ACCOUNTS`, and the last policy read from `.env` | `SELECT, INSERT, UPDATE, DELETE` |
| `ffs.signup_allowlist` | the emails and domains of the allowlist | `SELECT, INSERT, UPDATE, DELETE` |
| `ffs.signup_refusal()`, `ffs.signup_allowed()` | the functions that check an email against the policy and the max accounts | `EXECUTE` |
| a trigger on `fxa.accounts` | refuses the new account through `ffs.signup_refusal` | none |
| views `ffs.sessions`, `ffs.devices`, `ffs.emails`, `ffs.account_security`, `ffs.security_events`, `ffs.schema_levels`, `ffs.database_sizes` | what the admin UI lists, without any secret or token id | `SELECT` |
| procedures `ffs.disable_account`, `ffs.enable_account`, `ffs.sign_out_all`, `ffs.sign_out_device`, `ffs.sign_out_session`, `ffs.remove_totp`, `ffs.remove_recovery_key`, `ffs.confirm_email`, `ffs.delete_account`, `ffs.delete_unconfirmed`, `ffs.prune` | what the admin UI changes, run with the policy user's privileges | `EXECUTE` |
| `fxa.accounts` | Mozilla's table | `SELECT` on `uid`, `email`, `emailVerified`, `createdAt` and `disabledAt` only |

`ffs_admin` has nothing else: no `UPDATE` or `DELETE` on Mozilla's tables. `fxa-policy` revokes its grants first at every start, so grants from older releases go.

The procedures call Mozilla's own, and `fxa-policy` checks at every start that these exist: `revokeAccountTokens_1`, `deleteTotpToken_4`, `deleteRecoveryKey_2`, `verifyEmail_9`, `deleteAccount_24` and `prune_10`. When one is missing (a newer accounts release renamed it, or the policy user has no `EXECUTE` on `fxa`), it logs a warning naming it, and the accounts keep working. What needs it in the admin UI then answers with an error: disabling and signing out, turning off two-step authentication, removing a recovery key, confirming an email, deleting accounts and pruning ([Sign out and disable](../admin/accounts.md#sign-out-and-disable)).

Why each grant:

- `EXECUTE` on `fxa`: the procedures call Mozilla's own, listed above.
- `WITH GRANT OPTION`: to give the admin UI's user its grants.
- `SELECT` on `fxa_profile` and `pushbox`: the admin UI shows the size and schema level of all five databases. `DELETE` there removes the profile and the push messages of a deleted account.
- The grants are on whole databases because the tables don't exist yet when you run the file.
- `ffs_admin` is created by the file, not by `fxa-policy`. `CREATE USER` is a server-wide privilege that also lets its holder change the password of every other account (on MariaDB, `root` too), so the policy user does not get it.

`ffs_admin` is a user, not the admin UI's own database of the same name (`ADMIN_DB_NAME`). On one server for Sync and the accounts, both exist side by side, and this user has no grant on that database.

The admin UI's user never sees token ids: a session token id signs in as its account.

Installs whose SQL is older than these grants:

- Without `EXECUTE` in the policy user's grant on `fxa`, run this once, then restart `fxa-policy`:

  ```sql
  GRANT EXECUTE ON `fxa`.* TO '@FXA_POLICY_USER@'@'%' WITH GRANT OPTION;
  ```

- With only `SELECT` on `fxa_profile` and `pushbox`, run this once. Otherwise deleting an account in the admin UI fails, and changes nothing:

  ```sql
  GRANT DELETE ON `fxa_profile`.* TO '@FXA_POLICY_USER@'@'%';
  GRANT DELETE ON `pushbox`.* TO '@FXA_POLICY_USER@'@'%';
  ```

One user for both the accounts and the policy is possible (tested):

1. Leave `FXA_MYSQL_POLICY_USER` empty. `fxa-policy` then connects with `FXA_MYSQL_USER` and `FXA_MYSQL_PASSWORD`, and `FXA_MYSQL_POLICY_PASSWORD` is not used.
1. In `database-setup-fxa.sql`, delete the policy user's `CREATE USER` and `ALTER USER` lines, and put the name of `FXA_MYSQL_USER` in its `GRANT`s.

The accounts services face the internet, and then also hold `GRANT OPTION` on `fxa`, `fxa_oauth` and `ffs`: they could pass their access to the accounts on to any other user of the server.

## The admin UI's own database

The [admin UI](../admin/README.md) keeps the event log, the audit trail (who did what, on which account), the notes, its metrics, the schema levels seen, its daily jobs and the backup runs in a database of its own: `ADMIN_DB_NAME` (`ffs_admin`). It is on the tokenserver's server; with PostgreSQL, on the same server.

The Sync server's users have no grant on it. A Sync server that is broken into can change what it stores, but cannot read or rewrite the audit trail.

The admin UI has two users there, both with `ADMIN_DB_PASSWORD`. It is not given the Sync users' passwords.

- `ADMIN_DB_USER` (`ffs_admin_ui`) reaches `ffs_admin` and nothing else.
- `ADMIN_DB_SYNC_USER` (`ffs_admin_sync`) reads the Sync data, changes it only as the tables above say, and has nothing on `ffs_admin`.

<details><summary>Why two users</summary>

The tokenserver user owns its database and can put code there: procedures, functions and views over its tables, with `SQL SECURITY INVOKER` (PostgreSQL: `SECURITY INVOKER`, the default). That code runs with the privileges of whoever calls it or reads the view, and on MariaDB and MySQL a session reaches every database by its name.

With one user, the Sync server's user could replace `ffs_set_max_users` with a procedure that deletes `ffs_admin.ffs_events`. The next save of max users in the admin UI would run it, with the rights on the audit trail. So the admin UI runs the Sync databases' code only as `ffs_admin_sync`. `tests/e2e.sh` plants such a procedure and function, and checks that the event log stays as it was.

</details>

Who creates them:

- **The stack's MariaDB and MySQL containers**: [db/mysql/admin-user.sh](/db/mysql/admin-user.sh) runs before the image's entrypoint. At every start it has the server run its statements with all privileges (`--init-file`): the database, the two users and their grants. That works on the first start and on the volumes of an existing install alike, whose root password is random: no administrator password is needed anywhere. The storage container gets only `ffs_admin_sync` and its `SELECT, DELETE`.
- **The stack's PostgreSQL container**: the init container, as the superuser, as described in [PostgreSQL](#postgresql).
- **Your own server**: `database-setup.sql`, as its administrator, or the stack itself at every start ([Let the stack apply them](../databases.md#let-the-stack-apply-them)). Without them the start stops in `db-bootstrap`, which names them.

An install from before `ADMIN_DB_PASSWORD` keeps its admin UI tables in the tokenserver database. Moving them: [The admin UI's own database](../upgrading.md#the-admin-uis-own-database).
