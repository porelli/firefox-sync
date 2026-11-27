package main

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"log"
	"regexp"
	"strings"
	"time"

	"github.com/go-sql-driver/mysql"
)

// ER_SPECIFIC_ACCESS_DENIED_ERROR, MySQL and MariaDB: e.g. CREATE USER without the privilege
const errSpecificAccessDenied = 1227

// Installed (again) on every start, after FxA's migrations: idempotent
var fxaPolicySQL = []string{
	"CREATE DATABASE IF NOT EXISTS ffs",
	`CREATE TABLE IF NOT EXISTS ffs.settings (
		name VARCHAR(64) PRIMARY KEY,
		value TEXT NOT NULL,
		updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
	)`,
	// entry byte for byte (utf8mb4_bin): the server's default collation would match
	// alice@exämple.org or a full-width ｅ to alice@example.org. An older table: allowlistBinary
	`CREATE TABLE IF NOT EXISTS ffs.signup_allowlist (
		entry VARCHAR(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin NOT NULL PRIMARY KEY,
		created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
	)`,
	// the accounts signed out everywhere (ffs.sign_out_all, so Disable, the procedures by email
	// and the sweep too) or deleted, whose access tokens are still in Redis: SQL cannot reach
	// them there. The admin UI revokes them within seconds and deletes the rows
	// (revocationsTable, docs/admin/accounts.md#sign-out-and-disable). One row per request
	`CREATE TABLE IF NOT EXISTS ` + revocationsTable + ` (
		id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
		uid BINARY(16) NOT NULL,
		requested_at BIGINT NOT NULL,
		KEY uid (uid)
	)`,
	"DROP FUNCTION IF EXISTS ffs.signup_allowed",
	"DROP FUNCTION IF EXISTS ffs.signup_refusal",
	// why a sign-up is refused, NULL when it is allowed. 'policy': not an email or a
	// domain (@example.com) of the allowlist, or anything but open, allowlist or closed
	// (e.g. a missing setting). 'full': FXA_MAX_ACCOUNTS accounts or more (a number, or
	// unlimited; missing: no limit, as before it existed; 0: nobody new).
	// The allowlist matches byte for byte after LOWER(TRIM()), in utf8mb4_bin whatever the
	// server's collation: no accented or full-width look-alike of an entry. Beyond ASCII, the
	// entry must spell out every such character: a domain entry for an address whose part
	// before the domain is ASCII (the auth server takes no other), and nothing lower-casing
	// changed in size (LOWER turns the Kelvin sign into a k: a look-alike of an ASCII entry)
	`CREATE FUNCTION ffs.signup_refusal(address VARCHAR(255) CHARACTER SET utf8mb4) RETURNS VARCHAR(16)
	READS SQL DATA
	SQL SECURITY DEFINER
	BEGIN
		DECLARE mode VARCHAR(16) DEFAULT NULL;
		DECLARE max_accounts VARCHAR(32) DEFAULT NULL;
		DECLARE trimmed, normalized VARCHAR(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin DEFAULT NULL;
		DECLARE domain VARCHAR(256) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin DEFAULT NULL;
		DECLARE local_ascii BOOLEAN DEFAULT FALSE;
		SET trimmed = TRIM(address);
		SET normalized = LOWER(trimmed);
		SET domain = CONCAT('@', SUBSTRING_INDEX(normalized, '@', -1));
		SET local_ascii = CHAR_LENGTH(normalized) - CHAR_LENGTH(domain) = LENGTH(normalized) - LENGTH(domain);
		SET mode = (SELECT value FROM ffs.settings WHERE name = 'signups');
		IF NOT (mode <=> 'open' OR (mode <=> 'allowlist' AND LENGTH(normalized) = LENGTH(trimmed)
				AND EXISTS (SELECT 1 FROM ffs.signup_allowlist WHERE entry = normalized COLLATE utf8mb4_bin
					OR (local_ascii AND entry = domain COLLATE utf8mb4_bin)))) THEN
			RETURN 'policy';
		END IF;
		SET max_accounts = (SELECT value FROM ffs.settings WHERE name = 'max_accounts');
		IF max_accounts IS NOT NULL AND max_accounts <> 'unlimited'
			AND (SELECT COUNT(*) FROM fxa.accounts) >= CAST(max_accounts AS UNSIGNED) THEN
			RETURN 'full';
		END IF;
		RETURN NULL;
	END`,
	`CREATE FUNCTION ffs.signup_allowed(address VARCHAR(255) CHARACTER SET utf8mb4) RETURNS BOOLEAN
	READS SQL DATA
	SQL SECURITY DEFINER
	RETURN ffs.signup_refusal(address) IS NULL`,
	"DROP FUNCTION IF EXISTS " + accessRefusedFunction,
	// whether the sign-up policy refuses an account as it is now ('policy', not 'full': it is
	// counted already): its current primary email, as given (the row of fxa.emails: changing it,
	// set_primary, leaves fxa.accounts, the email of the sign-up, as it was; that one without a
	// row). The one rule of ADMIN_ACCESS_EXTERNAL's ffs.enable_account and of the sweep, so that
	// an account the admin UI enables is one the next sweep keeps. In variables: the columns, the
	// function's value and a literal may have different collations, which MySQL refuses to
	// compare (1267)
	`CREATE FUNCTION ` + accessRefusedFunction + `(p_uid BINARY(16)) RETURNS BOOLEAN
	READS SQL DATA
	SQL SECURITY DEFINER
	BEGIN
		DECLARE v_email VARCHAR(255) CHARACTER SET utf8mb4 DEFAULT NULL;
		DECLARE v_refusal VARCHAR(16) DEFAULT NULL;
		SET v_email = (SELECT email FROM fxa.emails WHERE uid = p_uid AND isPrimary LIMIT 1);
		IF v_email IS NULL THEN
			SET v_email = (SELECT email FROM fxa.accounts WHERE uid = p_uid);
		END IF;
		SET v_refusal = ffs.signup_refusal(v_email);
		RETURN v_refusal <=> 'policy';
	END`,
	// sizes of the accounts databases for the admin UI, which has no access to their
	// tables: the view runs with the privileges of its definer
	`CREATE OR REPLACE SQL SECURITY DEFINER VIEW ffs.database_sizes AS
		SELECT table_schema AS name, SUM(data_length + index_length) AS bytes
		FROM information_schema.tables
		WHERE table_schema IN ('fxa', 'fxa_oauth', 'fxa_profile', 'pushbox', 'ffs')
		GROUP BY table_schema`,
	// sessions and devices for the admin UI without their token ids: a session token id
	// signs in as its account (Bearer fxs_<id>), ffs_admin never reads one
	// verified: the sign-in code (or the second step) was entered; the methods are
	// VERIFICATION_METHODS of the auth server (lib/tokens/session_token.js). ip: of a sign-in
	// still waiting for its code, from the security event of that sign-in (with
	// ACCOUNT_EVENTS_ENABLED only), matched on its verification id, which stays in here
	`CREATE OR REPLACE SQL SECURITY DEFINER VIEW ffs.sessions AS
		SELECT s.uid, LOWER(SHA2(s.tokenId, 256)) AS ref, s.uaBrowser, s.uaOS, s.createdAt, s.lastAccessTime,
			NOT EXISTS (SELECT 1 FROM fxa.unverifiedTokens u WHERE u.tokenId = s.tokenId) AS verified,
			CASE s.verificationMethod WHEN 0 THEN 'email' WHEN 1 THEN 'email-2fa' WHEN 2 THEN 'totp-2fa'
				WHEN 3 THEN 'recovery-code' WHEN 4 THEN 'sms-2fa' WHEN 5 THEN 'passkey' END AS verificationMethod,
			(SELECT e.ipAddr FROM fxa.unverifiedTokens u
				JOIN fxa.securityEvents e ON e.uid = u.uid AND e.tokenVerificationId = u.tokenVerificationId
				WHERE u.tokenId = s.tokenId ORDER BY e.createdAt LIMIT 1) AS ip
		FROM fxa.sessionTokens s`,
	// ref: the session the device signed in with (as in ffs.sessions), for its last use in Redis
	`CREATE OR REPLACE SQL SECURITY DEFINER VIEW ffs.devices AS
		SELECT d.uid, d.id, COALESCE(NULLIF(d.nameUtf8, ''), d.name) AS name, COALESCE(d.type, '') AS type,
			COALESCE(d.createdAt, 0) AS createdAt,
			GREATEST(COALESCE(s.lastAccessTime, 0), COALESCE(UNIX_TIMESTAMP(r.lastUsedAt) * 1000, 0)) AS lastUsed,
			LOWER(SHA2(s.tokenId, 256)) AS ref
		FROM fxa.devices d
		LEFT JOIN fxa.sessionTokens s ON s.tokenId = d.sessionTokenId
		LEFT JOIN fxa_oauth.refreshTokens r ON r.token = d.refreshTokenId`,
	// how each account signs in, without the secrets: never sharedSecret (TOTP), codeHash
	// (recovery codes), recoveryData (the wrapped keys), phoneNumber or the passkeys' keys.
	// keysChangedAt is NULL until the keys first change (FxA then uses verifierSetAt)
	`CREATE OR REPLACE SQL SECURITY DEFINER VIEW ffs.account_security AS
		SELECT a.uid,
			EXISTS (SELECT 1 FROM fxa.totp t WHERE t.uid = a.uid AND t.enabled AND t.verified) AS totp_enabled,
			EXISTS (SELECT 1 FROM fxa.recoveryKeys k WHERE k.uid = a.uid AND k.enabled) AS recovery_key,
			(SELECT COUNT(*) FROM fxa.recoveryCodes c WHERE c.uid = a.uid) AS recovery_codes_left,
			EXISTS (SELECT 1 FROM fxa.recoveryPhones p WHERE p.uid = a.uid) AS recovery_phone,
			(SELECT COUNT(*) FROM fxa.passkeys p WHERE p.uid = a.uid) AS passkeys,
			a.verifierSetAt, COALESCE(a.keysChangedAt, a.verifierSetAt, a.createdAt) AS keysChangedAt, a.lockedAt,
			(SELECT COUNT(*) FROM fxa.sessionTokens s JOIN fxa.unverifiedTokens u ON u.tokenId = s.tokenId
				WHERE s.uid = a.uid) AS unverified_sessions
		FROM fxa.accounts a`,
	// every address of an account, the primary one too (not their codes)
	`CREATE OR REPLACE SQL SECURITY DEFINER VIEW ffs.emails AS
		SELECT uid, email, isVerified, isPrimary, createdAt FROM fxa.emails`,
	// the security history of the account settings (Recent activity), written by the auth
	// server with ACCOUNT_EVENTS_ENABLED (FXA_ACCOUNT_EVENTS) only: the name of the event,
	// when, from which IP address, and verified (the sign-in of the event was confirmed,
	// then or later). Not the HMAC of the address, the token or additionalInfo. One collation
	// for the name, whatever the client's (the name of an unknown id: #id)
	`CREATE OR REPLACE SQL SECURITY DEFINER VIEW ffs.security_events AS
		SELECT e.uid, CONVERT(COALESCE(n.name, CONCAT('#', e.nameId)) USING utf8mb4) COLLATE utf8mb4_bin AS name,
			e.createdAt, e.verified, e.ipAddr
		FROM fxa.securityEvents e LEFT JOIN fxa.securityEventNames n ON n.id = e.nameId`,
	// signing out reads the token ids too: MySQL needs SELECT on the columns of a
	// DELETE ... WHERE, so these run with the privileges of their definer
	"DROP PROCEDURE IF EXISTS ffs.sign_out_session",
	// p_ref: SHA-256 of the token id, as shown by ffs.sessions
	`CREATE PROCEDURE ffs.sign_out_session(p_uid BINARY(16), p_ref BINARY(32))
	MODIFIES SQL DATA
	SQL SECURITY DEFINER
	BEGIN
		DECLARE v_token BINARY(32) DEFAULT NULL;
		DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
		SELECT tokenId INTO v_token FROM fxa.sessionTokens WHERE uid = p_uid AND UNHEX(SHA2(tokenId, 256)) = p_ref;
		IF v_token IS NULL THEN
			SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'no such session';
		END IF;
		START TRANSACTION;
		DELETE FROM fxa.devices WHERE uid = p_uid AND sessionTokenId = v_token;
		DELETE FROM fxa.sessionTokens WHERE tokenId = v_token;
		COMMIT;
	END`,
	"DROP PROCEDURE IF EXISTS ffs.sign_out_device",
	`CREATE PROCEDURE ffs.sign_out_device(p_uid BINARY(16), p_device BINARY(16))
	MODIFIES SQL DATA
	SQL SECURITY DEFINER
	BEGIN
		DECLARE v_found INT DEFAULT 0;
		DECLARE v_session, v_refresh BINARY(32) DEFAULT NULL;
		DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
		SELECT COUNT(*), MAX(sessionTokenId), MAX(refreshTokenId) INTO v_found, v_session, v_refresh
			FROM fxa.devices WHERE uid = p_uid AND id = p_device;
		IF v_found = 0 THEN
			SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'no such device';
		END IF;
		START TRANSACTION;
		IF v_session IS NOT NULL THEN
			DELETE FROM fxa.sessionTokens WHERE tokenId = v_session;
		END IF;
		IF v_refresh IS NOT NULL THEN
			DELETE FROM fxa_oauth.refreshTokens WHERE token = v_refresh;
		END IF;
		DELETE FROM fxa.devices WHERE uid = p_uid AND id = p_device;
		COMMIT;
	END`,
	// signing out everywhere: Mozilla's own procedure (sessions, key fetch, account reset,
	// password change and forgot tokens, devices and their commands, unverified tokens,
	// unblock codes, in its own transaction), then the OAuth tokens it does not know about.
	// The access tokens are in Redis only (fxa-auth v1.350.0): queued in the same transaction
	// for the admin UI, which revokes them there (revocationsTable)
	"DROP PROCEDURE IF EXISTS ffs.sign_out_all",
	`CREATE PROCEDURE ffs.sign_out_all(p_uid BINARY(16))
	MODIFIES SQL DATA
	SQL SECURITY DEFINER
	BEGIN
		DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
		IF NOT EXISTS (SELECT 1 FROM fxa.accounts WHERE uid = p_uid) THEN
			SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'no such account';
		END IF;
		CALL fxa.revokeAccountTokens_1(p_uid);
		START TRANSACTION;
		-- codes first: the token endpoint does not check disabledAt, a code traded
		-- in between would leave a refresh token
		DELETE FROM fxa_oauth.codes WHERE userId = p_uid;
		DELETE FROM fxa_oauth.refreshTokens WHERE userId = p_uid;
		DELETE FROM fxa_oauth.tokens WHERE userId = p_uid;
		` + queueRevocation + `
		COMMIT;
	END`,
	// disabledAt first, which refuses new sign-ins, then everything signed out: a sign-in
	// between the two would otherwise leave a session behind
	"DROP PROCEDURE IF EXISTS ffs.disable_account",
	`CREATE PROCEDURE ffs.disable_account(p_uid BINARY(16))
	MODIFIES SQL DATA
	SQL SECURITY DEFINER
	BEGIN
		IF NOT EXISTS (SELECT 1 FROM fxa.accounts WHERE uid = p_uid) THEN
			SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'no such account';
		END IF;
		UPDATE fxa.accounts SET disabledAt = FLOOR(UNIX_TIMESTAMP(NOW(3)) * 1000)
			WHERE uid = p_uid AND disabledAt IS NULL;
		CALL ffs.sign_out_all(p_uid);
	END`,
	"DROP PROCEDURE IF EXISTS ffs.enable_account",
	`CREATE PROCEDURE ffs.enable_account(p_uid BINARY(16))
	MODIFIES SQL DATA
	SQL SECURITY DEFINER
	BEGIN
		IF NOT EXISTS (SELECT 1 FROM fxa.accounts WHERE uid = p_uid) THEN
			SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'no such account';
		END IF;
		UPDATE fxa.accounts SET disabledAt = NULL WHERE uid = p_uid;
	END`,
	// turning off two-step authentication for someone locked out (a lost phone): the TOTP
	// secret with Mozilla's procedure, and the backup methods that only work with it
	"DROP PROCEDURE IF EXISTS ffs.remove_totp",
	`CREATE PROCEDURE ffs.remove_totp(p_uid BINARY(16))
	MODIFIES SQL DATA
	SQL SECURITY DEFINER
	BEGIN
		DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
		IF NOT EXISTS (SELECT 1 FROM fxa.accounts WHERE uid = p_uid) THEN
			SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'no such account';
		END IF;
		IF NOT EXISTS (SELECT 1 FROM fxa.totp WHERE uid = p_uid) THEN
			SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'two-step authentication is not on';
		END IF;
		START TRANSACTION;
		CALL fxa.deleteTotpToken_4(p_uid);
		DELETE FROM fxa.recoveryCodes WHERE uid = p_uid;
		DELETE FROM fxa.recoveryPhones WHERE uid = p_uid;
		COMMIT;
	END`,
	"DROP PROCEDURE IF EXISTS ffs.remove_recovery_key",
	`CREATE PROCEDURE ffs.remove_recovery_key(p_uid BINARY(16))
	MODIFIES SQL DATA
	SQL SECURITY DEFINER
	BEGIN
		IF NOT EXISTS (SELECT 1 FROM fxa.recoveryKeys WHERE uid = p_uid) THEN
			SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'no account recovery key';
		END IF;
		CALL fxa.deleteRecoveryKey_2(p_uid);
	END`,
	// confirming the email for someone whose code never arrived: Mozilla's procedure with
	// the account's own code, which ffs_admin never reads. Its sessions stay unconfirmed
	// (their own codes): the admin UI confirms those it listed with confirm_session
	"DROP PROCEDURE IF EXISTS ffs.confirm_email",
	`CREATE PROCEDURE ffs.confirm_email(p_uid BINARY(16))
	MODIFIES SQL DATA
	SQL SECURITY DEFINER
	BEGIN
		DECLARE v_code BINARY(16) DEFAULT NULL;
		DECLARE v_verified BOOLEAN DEFAULT NULL;
		SELECT emailCode, emailVerified INTO v_code, v_verified FROM fxa.accounts WHERE uid = p_uid;
		IF v_code IS NULL THEN
			SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'no such account';
		END IF;
		IF v_verified THEN
			SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'the email is already confirmed';
		END IF;
		CALL fxa.verifyEmail_9(p_uid, v_code);
	END`,
	// confirming a sign-in that never entered its code, for someone the admin vouches for:
	// what the auth server does with the right code (SessionToken.verify of fxa-shared, one
	// transaction): the method and time on the session (email-2fa, as the code would), then
	// Mozilla's verifyToken, which marks the security events of the sign-in confirmed and
	// deletes its unverified tokens (the session's, and its key fetch token's: one
	// verification id). Not before the email is confirmed (confirm_email first: FxA reads a
	// session as confirmed with its email only), nor with two-step authentication on (the
	// auth server wants the authenticator's code there, never an email code)
	"DROP PROCEDURE IF EXISTS ffs.confirm_session",
	`CREATE PROCEDURE ffs.confirm_session(p_uid BINARY(16), p_ref BINARY(32))
	MODIFIES SQL DATA
	SQL SECURITY DEFINER
	BEGIN
		DECLARE v_verified BOOLEAN DEFAULT NULL;
		DECLARE v_token BINARY(32) DEFAULT NULL;
		DECLARE v_verification BINARY(16) DEFAULT NULL;
		DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
		SELECT emailVerified INTO v_verified FROM fxa.accounts WHERE uid = p_uid;
		IF v_verified IS NULL THEN
			SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'no such account';
		END IF;
		IF NOT v_verified THEN
			SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '` + errEmailNotConfirmed + `';
		END IF;
		IF EXISTS (SELECT 1 FROM fxa.totp WHERE uid = p_uid AND enabled AND verified) THEN
			SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '` + errTwoStepSignIn + `';
		END IF;
		SELECT tokenId INTO v_token FROM fxa.sessionTokens WHERE uid = p_uid AND UNHEX(SHA2(tokenId, 256)) = p_ref;
		IF v_token IS NULL THEN
			SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'no such session';
		END IF;
		SELECT tokenVerificationId INTO v_verification FROM fxa.unverifiedTokens WHERE tokenId = v_token AND uid = p_uid;
		IF v_verification IS NULL THEN
			SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '` + errSignInConfirmed + `';
		END IF;
		START TRANSACTION;
		CALL fxa.verifyTokensWithMethod_3(v_token, 1, FLOOR(UNIX_TIMESTAMP(NOW(3)) * 1000));
		CALL fxa.verifyToken_3(v_verification, p_uid);
		COMMIT;
	END`,
	// deleting an account for good, disabled first (two steps, never one slip): what the
	// auth server's own deletion removes (deleteAccount_24), then what lives in the other
	// databases, and the exact email from the allowlist so that it cannot sign up again
	// (not with ADMIN_ACCESS_EXTERNAL: externalPolicySQL). Ours first: a failure leaves a
	// disabled account, not one half deleted
	"DROP PROCEDURE IF EXISTS ffs.delete_account",
	`CREATE PROCEDURE ffs.delete_account(p_uid BINARY(16))
	MODIFIES SQL DATA
	SQL SECURITY DEFINER
	BEGIN
		DECLARE v_found INT DEFAULT 0;
		DECLARE v_disabled BIGINT DEFAULT NULL;
		DECLARE v_email VARCHAR(255) CHARACTER SET utf8mb4 DEFAULT NULL;
		DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
		SELECT COUNT(*), MAX(disabledAt), MAX(normalizedEmail) INTO v_found, v_disabled, v_email
			FROM fxa.accounts WHERE uid = p_uid;
		IF v_found = 0 THEN
			SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'no such account';
		END IF;
		IF v_disabled IS NULL THEN
			SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'only a disabled account can be deleted: disable it first';
		END IF;
		START TRANSACTION;
		DELETE FROM fxa.recoveryPhones WHERE uid = p_uid;
		DELETE FROM fxa_oauth.codes WHERE userId = p_uid;
		DELETE FROM fxa_oauth.refreshTokens WHERE userId = p_uid;
		DELETE FROM fxa_oauth.tokens WHERE userId = p_uid;
		DELETE FROM fxa_oauth.accountActivity WHERE userId = p_uid;
		DELETE FROM fxa_oauth.accountAuthorizations WHERE uid = p_uid;
		DELETE FROM fxa_oauth.accountAuthorizations_v2 WHERE uid = p_uid;
		DELETE FROM fxa_profile.avatar_selected WHERE userId = p_uid;
		DELETE FROM fxa_profile.avatars WHERE userId = p_uid;
		DELETE FROM fxa_profile.profile WHERE userId = p_uid;
		DELETE FROM pushbox.pushboxv1 WHERE user_id IN (LOWER(HEX(p_uid)), HEX(p_uid));
		` + queueRevocation + `
		COMMIT;
		CALL fxa.deleteAccount_24(p_uid, 'fxa_admin_requested_account_delete');
		` + deleteAllowlistRow + `
	END`,
	// an account that never confirmed its email: the same deletion, the reason the auth
	// server gives its own cleanup of them. One account per call (the admin UI lists them
	// and counts those deleted), and only one created more than a day ago whatever the
	// caller asks: ffs_admin cannot delete fresh accounts with it
	"DROP PROCEDURE IF EXISTS ffs.delete_unconfirmed",
	`CREATE PROCEDURE ffs.delete_unconfirmed(p_uid BINARY(16), p_before BIGINT)
	MODIFIES SQL DATA
	SQL SECURITY DEFINER
	BEGIN
		DECLARE v_found INT DEFAULT 0;
		DECLARE v_before BIGINT DEFAULT 0;
		DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
		SET v_before = LEAST(p_before, UNIX_TIMESTAMP() * 1000 - 86400000);
		SELECT COUNT(*) INTO v_found FROM fxa.accounts a
			WHERE a.uid = p_uid AND a.emailVerified = 0 AND a.createdAt < v_before
			AND NOT EXISTS (SELECT 1 FROM fxa.emails e WHERE e.uid = a.uid AND e.isVerified);
		IF v_found = 0 THEN
			SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '` + errNotUnconfirmed + `';
		END IF;
		START TRANSACTION;
		DELETE FROM fxa_oauth.codes WHERE userId = p_uid;
		DELETE FROM fxa_oauth.refreshTokens WHERE userId = p_uid;
		DELETE FROM fxa_oauth.tokens WHERE userId = p_uid;
		DELETE FROM fxa_oauth.accountAuthorizations WHERE uid = p_uid;
		DELETE FROM fxa_oauth.accountAuthorizations_v2 WHERE uid = p_uid;
		COMMIT;
		CALL fxa.deleteAccount_24(p_uid, 'fxa_unverified_account_delete');
	END`,
	// expired tokens and codes, with Mozilla's own procedure: codes 30 days, tokens and
	// sessions without a device 4 weeks (a Firefox's session has its device: never). It
	// looks at one creation time per call, and stops for good at an old session that has
	// a device: the same rule once more for all of them. Then the OAuth codes (15 minutes,
	// as the auth server's script) and the security events of the account settings, which
	// it never prunes. The counts in the last result set (prune_10 sends its own first).
	// The times are the database's at most, the security events kept a day at least:
	// ffs_admin cannot empty the tables with a time in the future
	"DROP PROCEDURE IF EXISTS ffs.prune",
	`CREATE PROCEDURE ffs.prune(p_now BIGINT, p_events_before BIGINT)
	MODIFIES SQL DATA
	SQL SECURITY DEFINER
	BEGIN
		DECLARE v_unblock, v_signin, v_reset, v_forgot, v_change, v_sessions INT UNSIGNED DEFAULT 0;
		DECLARE v_more, v_codes, v_events INT DEFAULT 0;
		DECLARE v_now, v_events_before, v_cutoff BIGINT DEFAULT 0;
		DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
		SET v_now = LEAST(p_now, UNIX_TIMESTAMP() * 1000);
		SET v_events_before = LEAST(p_events_before, v_now - 86400000);
		SET v_cutoff = v_now - 2419200000;
		CALL fxa.prune_10(v_now, 2419200000, 2592000000, 100000, v_unblock, v_signin, v_reset, v_forgot, v_change, v_sessions);
		START TRANSACTION;
		DELETE u FROM fxa.unverifiedTokens u JOIN fxa.sessionTokens s ON s.tokenId = u.tokenId
			WHERE s.createdAt < v_cutoff
			AND NOT EXISTS (SELECT 1 FROM fxa.devices d WHERE d.uid = s.uid AND d.sessionTokenId = s.tokenId);
		DELETE s FROM fxa.sessionTokens s WHERE s.createdAt < v_cutoff
			AND NOT EXISTS (SELECT 1 FROM fxa.devices d WHERE d.uid = s.uid AND d.sessionTokenId = s.tokenId);
		SET v_more = ROW_COUNT();
		DELETE FROM fxa_oauth.codes WHERE createdAt < NOW() - INTERVAL 15 MINUTE;
		SET v_codes = ROW_COUNT();
		DELETE FROM fxa.securityEvents WHERE createdAt < v_events_before;
		SET v_events = ROW_COUNT();
		UPDATE fxa.dbMetadata SET value = CAST(v_now AS CHAR) WHERE name = 'prune-last-ran';
		COMMIT;
		SELECT v_unblock AS unblock_codes, v_signin AS signin_codes,
			v_reset + v_forgot + v_change AS account_tokens, v_sessions + v_more AS sessions,
			v_codes AS oauth_codes, v_events AS security_events;
	END`,
	// The accounts by email, for a system that manages who may sign up (ffs_access,
	// FXA_ACCESS_DB_PASSWORD, docs/admin/accounts.md#access-managed-elsewhere): the account that
	// signed up with the email (fxa.accounts.normalizedEmail: one account per email, and it never
	// changes, set_primary leaves it as it was; the email the system's list let in), normalized as
	// the accounts do, then byte for byte: no look-alike finds another account. Not any of its
	// emails: fxa.accounts and fxa.emails each have a unique key of their own, none over both,
	// so another account's email could be the same. Through the procedures above, so that
	// ffs_access needs nothing of fxa.*. Disable signs it out everywhere (ffs.disable_account);
	// delete takes a disabled account only (ffs.delete_account), not its Sync data. Enable is
	// its own UPDATE, not ffs.enable_account: with ADMIN_ACCESS_EXTERNAL that one asks the
	// sign-up policy, and the system that decides who has access must not be refused by it
	// (FXA_SIGNUPS=closed, an email it enables before adding it again)
	"DROP PROCEDURE IF EXISTS ffs.disable_account_by_email",
	`CREATE PROCEDURE ffs.disable_account_by_email(p_email VARCHAR(255) CHARACTER SET utf8mb4)
	MODIFIES SQL DATA
	SQL SECURITY DEFINER
	BEGIN
		DECLARE v_uid BINARY(16) DEFAULT NULL;
		DECLARE v_email VARCHAR(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin DEFAULT NULL;
		SET v_email = LOWER(TRIM(p_email));
		SELECT uid INTO v_uid FROM fxa.accounts WHERE normalizedEmail = v_email COLLATE utf8mb4_bin LIMIT 1;
		IF v_uid IS NULL THEN
			SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'no such account';
		END IF;
		CALL ffs.disable_account(v_uid);
	END`,
	"DROP PROCEDURE IF EXISTS ffs.enable_account_by_email",
	`CREATE PROCEDURE ffs.enable_account_by_email(p_email VARCHAR(255) CHARACTER SET utf8mb4)
	MODIFIES SQL DATA
	SQL SECURITY DEFINER
	BEGIN
		DECLARE v_uid BINARY(16) DEFAULT NULL;
		DECLARE v_email VARCHAR(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin DEFAULT NULL;
		SET v_email = LOWER(TRIM(p_email));
		SELECT uid INTO v_uid FROM fxa.accounts WHERE normalizedEmail = v_email COLLATE utf8mb4_bin LIMIT 1;
		IF v_uid IS NULL THEN
			SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'no such account';
		END IF;
		UPDATE fxa.accounts SET disabledAt = NULL WHERE uid = v_uid;
	END`,
	"DROP PROCEDURE IF EXISTS ffs.delete_account_by_email",
	`CREATE PROCEDURE ffs.delete_account_by_email(p_email VARCHAR(255) CHARACTER SET utf8mb4)
	MODIFIES SQL DATA
	SQL SECURITY DEFINER
	BEGIN
		DECLARE v_uid BINARY(16) DEFAULT NULL;
		DECLARE v_email VARCHAR(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin DEFAULT NULL;
		SET v_email = LOWER(TRIM(p_email));
		SELECT uid INTO v_uid FROM fxa.accounts WHERE normalizedEmail = v_email COLLATE utf8mb4_bin LIMIT 1;
		IF v_uid IS NULL THEN
			SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'no such account';
		END IF;
		CALL ffs.delete_account(v_uid);
	END`,
	// ffs_access's sweep, made with ADMIN_ACCESS_EXTERNAL only (externalOnlySQL): dropped at
	// every start, so a start without the mode leaves none behind
	"DROP PROCEDURE IF EXISTS " + sweepProcedure,
	"DROP TRIGGER IF EXISTS fxa.ffs_signup_policy",
	// the gate in front of the accounts API answers with a proper error first, this
	// catches whatever reaches the auth server another way. With a limit, sign-ups wait
	// for each other on its row (until the account's transaction ends): two at once
	// cannot both take the last place
	`CREATE TRIGGER fxa.ffs_signup_policy BEFORE INSERT ON fxa.accounts FOR EACH ROW
	BEGIN
		DECLARE refusal VARCHAR(16) DEFAULT NULL;
		DECLARE locked VARCHAR(32) DEFAULT NULL;
		DECLARE CONTINUE HANDLER FOR NOT FOUND SET locked = NULL;
		SELECT value INTO locked FROM ffs.settings WHERE name = 'max_accounts' FOR UPDATE;
		-- the email as given: normalizedEmail is the auth server's toLowerCase(), which turns
		-- the Kelvin sign into a k too
		SET refusal = ffs.signup_refusal(NEW.email);
		IF refusal = 'full' THEN
			SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Sign-up refused: the server is full (FXA_MAX_ACCOUNTS)';
		ELSEIF refusal IS NOT NULL THEN
			SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Sign-up refused by the firefox-sync sign-up policy';
		END IF;
	END`,
}

// revocationsTable: the accounts whose access tokens the admin UI revokes in Redis
// (revokePending), queued by ffs.sign_out_all and ffs.delete_account (queueRevocation). Only
// ffs_admin reads and deletes its rows; ffs_access has nothing on it
const revocationsTable = "ffs.pending_revocations"

// queueRevocation: the statement of the procedures that queue an account (p_uid), inside their
// transaction: committed with the sign-out, never without it
const queueRevocation = "INSERT INTO " + revocationsTable + " (uid, requested_at) VALUES (p_uid, FLOOR(UNIX_TIMESTAMP(NOW(3)) * 1000));"

// deleteAllowlistRow: the last statement of ffs.delete_account without ADMIN_ACCESS_EXTERNAL
const deleteAllowlistRow = "DELETE FROM ffs.signup_allowlist WHERE entry = LOWER(v_email) COLLATE utf8mb4_bin;"

// errAccessElsewhere: ffs.enable_account's refusal with ADMIN_ACCESS_EXTERNAL, which the admin
// UI shows as it is (procedureError)
const errAccessElsewhere = "not on the access list managed elsewhere: the system that manages access enables this account"

// externalPolicySQL: with ADMIN_ACCESS_EXTERNAL (docs/admin/accounts.md#access-managed-elsewhere)
// another system decides who has access, and the admin UI's own procedures must not undo it.
// ffs.enable_account refuses an account whose current primary email the sign-up policy refuses
// (accessRefusedFunction, the sweep's rule; 'policy': not on
// the allowlist, FXA_SIGNUPS=closed), as a sign-up of it would be. Not 'full': the account is one
// of fxa.accounts, which FXA_MAX_ACCOUNTS counts disabled or not, enabling it adds none. Disable
// stays as it is (incident response), and ffs.enable_account_by_email of that system does not
// call this one. ffs.delete_account leaves the allowlist alone: a member deleted can sign up
// again, the system removes the row if it wants to. Generated per start rather than read from
// ffs.settings: fxa-policy makes the procedures again at every start, so a start without the
// mode has today's again, and nothing ffs_admin may write changes them
var externalPolicySQL = map[string]string{
	"ffs.enable_account": `CREATE PROCEDURE ffs.enable_account(p_uid BINARY(16))
	MODIFIES SQL DATA
	SQL SECURITY DEFINER
	BEGIN
		IF NOT EXISTS (SELECT 1 FROM fxa.accounts WHERE uid = p_uid) THEN
			SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'no such account';
		END IF;
		-- the sweep's rule (` + accessRefusedFunction + `): its current primary email
		IF ` + accessRefusedFunction + `(p_uid) THEN
			SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '` + errAccessElsewhere + `';
		END IF;
		UPDATE fxa.accounts SET disabledAt = NULL WHERE uid = p_uid;
	END`,
}

// accessRefusedFunction: the policy's question about an account as it is now, for
// ADMIN_ACCESS_EXTERNAL's ffs.enable_account and the sweep (fxaPolicySQL)
const accessRefusedFunction = "ffs.access_refused"

// sweepProcedure: ffs_access's sweep of the accounts its list no longer allows (externalOnlySQL)
const sweepProcedure = "ffs.disable_accounts_not_allowed"

// errSweepBrake: the SQLSTATE of the sweep's brake, its own (the other refusals are 45000), so
// that the system calling it can tell it apart. Its MESSAGE_TEXT: sweepBrakePrefix, then
// "<n> accounts would be disabled, more than p_max <p_max>"
const (
	errSweepBrake    = "45001"
	sweepBrakePrefix = "disable_accounts_not_allowed: "
)

// externalOnlySQL: procedures that exist with ADMIN_ACCESS_EXTERNAL only, each made right after
// its DROP of fxaPolicySQL (which every start runs: without the mode, none is left).
//
// ffs.disable_accounts_not_allowed(p_max): for the system that keeps the sign-up allowlist, which
// changes an email or a domain on its list, while an account's primary email can change after its
// sign-up (the *_by_email procedures match the sign-up's, fxa.accounts.normalizedEmail, which
// FxA's set_primary leaves as it was). It disables, and signs out everywhere with
// ffs.disable_account, every enabled account the sign-up policy refuses as it is now
// (accessRefusedFunction: its current primary email; the rule of ffs.enable_account above, so the
// admin UI never enables one the next sweep disables). The allowlist the system already keeps decides, not a list passed in: one source, nothing to parse in SQL.
// The brake: counted first, before any change; more than p_max refuses with errSweepBrake and
// changes nothing, so an allowlist emptied by mistake cannot disable everybody. p_max equal to
// the count passes, a NULL or negative one is refused. The uids counted are kept (16 bytes each,
// p_max at most) and checked again one by one before each is disabled: never more than counted.
// No transaction of its own, and none could hold it: fxa.revokeAccountTokens_1 and
// ffs.sign_out_all each run START TRANSACTION, which commits any open one (the caller's too),
// so each account is committed as it is disabled (docs/admin/accounts.md#the-sweep).
// The count of those disabled in a result set of one row, as ffs.prune: column disabled
var externalOnlySQL = map[string]string{
	"DROP PROCEDURE IF EXISTS " + sweepProcedure: `CREATE PROCEDURE ` + sweepProcedure + `(p_max INT)
	MODIFIES SQL DATA
	SQL SECURITY DEFINER
	BEGIN
		DECLARE v_end BOOLEAN DEFAULT FALSE;
		DECLARE v_uid BINARY(16) DEFAULT NULL;
		DECLARE v_found INT DEFAULT 0;
		DECLARE v_disabled BIGINT DEFAULT NULL;
		DECLARE v_count, v_i, v_done INT DEFAULT 0;
		DECLARE v_uids LONGBLOB;
		DECLARE v_msg VARCHAR(128) DEFAULT NULL;
		DECLARE c_enabled CURSOR FOR SELECT uid FROM fxa.accounts WHERE disabledAt IS NULL;
		DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_end = TRUE;
		IF p_max IS NULL OR p_max < 0 THEN
			SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '` + sweepBrakePrefix + `p_max must be a number, 0 or more';
		END IF;
		SET v_uids = '';
		-- counted, nothing changed yet
		OPEN c_enabled;
		scan: LOOP
			SET v_end = FALSE;
			FETCH c_enabled INTO v_uid;
			IF v_end THEN
				LEAVE scan;
			END IF;
			-- the rule of ffs.enable_account too: its current primary email
			IF ` + accessRefusedFunction + `(v_uid) THEN
				SET v_count = v_count + 1;
				IF v_count <= p_max THEN
					SET v_uids = CONCAT(v_uids, v_uid);
				END IF;
			END IF;
		END LOOP;
		CLOSE c_enabled;
		IF v_count > p_max THEN
			SET v_msg = CONCAT('` + sweepBrakePrefix + `', v_count, ' accounts would be disabled, more than p_max ', p_max);
			SIGNAL SQLSTATE '` + errSweepBrake + `' SET MESSAGE_TEXT = v_msg;
		END IF;
		-- each one checked again (enabled meanwhile, or its email on the list now: left alone)
		WHILE v_i < v_count DO
			SET v_uid = SUBSTRING(v_uids, v_i * 16 + 1, 16);
			SET v_i = v_i + 1;
			SELECT COUNT(*), MAX(disabledAt) INTO v_found, v_disabled FROM fxa.accounts WHERE uid = v_uid;
			IF v_found = 1 AND v_disabled IS NULL AND ` + accessRefusedFunction + `(v_uid) THEN
				CALL ffs.disable_account(v_uid);
				SET v_done = v_done + 1;
			END IF;
		END WHILE;
		SELECT v_done AS disabled;
	END`,
}

// fxaPolicySQLFor: fxaPolicySQL as ADMIN_ACCESS_EXTERNAL says (externalPolicySQL, externalOnlySQL)
func fxaPolicySQLFor(external bool) []string {
	if !external {
		return fxaPolicySQL
	}
	stmts := make([]string, 0, len(fxaPolicySQL)+len(externalOnlySQL))
	for _, stmt := range fxaPolicySQL {
		header, _, _ := strings.Cut(stmt, "\n")
		name, _, _ := strings.Cut(strings.TrimPrefix(header, "CREATE PROCEDURE "), "(")
		switch {
		case !strings.HasPrefix(header, "CREATE PROCEDURE "):
		case externalPolicySQL[name] != "":
			stmt = externalPolicySQL[name]
		case name == "ffs.delete_account":
			stmt = strings.Replace(stmt, deleteAllowlistRow, "-- ADMIN_ACCESS_EXTERNAL: the allowlist is the other system's", 1)
		}
		stmts = append(stmts, stmt)
		if create := externalOnlySQL[stmt]; create != "" {
			stmts = append(stmts, create)
		}
	}
	return stmts
}

// The admin UI connects as ffs_admin: it reads the accounts, and changes them only
// through the procedures above (no UPDATE or DELETE on FxA's tables).
// Revoked first: what earlier versions granted goes (the token ids, the DELETEs). The REVOKE must stay first.
var fxaAdminGrants = []string{
	"REVOKE ALL PRIVILEGES, GRANT OPTION FROM 'ffs_admin'@'%'",
	"GRANT SELECT, INSERT, UPDATE, DELETE ON ffs.settings TO 'ffs_admin'@'%'",
	"GRANT SELECT, INSERT, UPDATE, DELETE ON ffs.signup_allowlist TO 'ffs_admin'@'%'",
	// the views are updatable: SELECT only
	"GRANT SELECT ON ffs.database_sizes TO 'ffs_admin'@'%'",
	"GRANT SELECT ON ffs.sessions TO 'ffs_admin'@'%'",
	"GRANT SELECT ON ffs.devices TO 'ffs_admin'@'%'",
	"GRANT SELECT ON ffs.account_security TO 'ffs_admin'@'%'",
	"GRANT SELECT ON ffs.emails TO 'ffs_admin'@'%'",
	"GRANT SELECT ON ffs.security_events TO 'ffs_admin'@'%'",
	"GRANT SELECT ON ffs.schema_levels TO 'ffs_admin'@'%'",
	// the setup migrations of the accounts' database server (setupmigrations.go)
	"GRANT SELECT ON ffs.ffs_setup_migrations TO 'ffs_admin'@'%'",
	"GRANT SELECT ON ffs.ffs_setup_state TO 'ffs_admin'@'%'",
	// the access tokens to revoke in Redis: read, and the rows done deleted
	"GRANT SELECT, DELETE ON " + revocationsTable + " TO 'ffs_admin'@'%'",
	"GRANT EXECUTE ON FUNCTION ffs.signup_allowed TO 'ffs_admin'@'%'",
	"GRANT EXECUTE ON FUNCTION ffs.signup_refusal TO 'ffs_admin'@'%'",
	"GRANT EXECUTE ON PROCEDURE ffs.sign_out_session TO 'ffs_admin'@'%'",
	"GRANT EXECUTE ON PROCEDURE ffs.sign_out_device TO 'ffs_admin'@'%'",
	"GRANT EXECUTE ON PROCEDURE ffs.sign_out_all TO 'ffs_admin'@'%'",
	"GRANT EXECUTE ON PROCEDURE ffs.disable_account TO 'ffs_admin'@'%'",
	"GRANT EXECUTE ON PROCEDURE ffs.enable_account TO 'ffs_admin'@'%'",
	"GRANT EXECUTE ON PROCEDURE ffs.remove_totp TO 'ffs_admin'@'%'",
	"GRANT EXECUTE ON PROCEDURE ffs.remove_recovery_key TO 'ffs_admin'@'%'",
	"GRANT EXECUTE ON PROCEDURE ffs.confirm_email TO 'ffs_admin'@'%'",
	"GRANT EXECUTE ON PROCEDURE ffs.confirm_session TO 'ffs_admin'@'%'",
	"GRANT EXECUTE ON PROCEDURE ffs.delete_account TO 'ffs_admin'@'%'",
	"GRANT EXECUTE ON PROCEDURE ffs.delete_unconfirmed TO 'ffs_admin'@'%'",
	"GRANT EXECUTE ON PROCEDURE ffs.prune TO 'ffs_admin'@'%'",
	"GRANT SELECT (uid, email, emailVerified, createdAt, disabledAt) ON fxa.accounts TO 'ffs_admin'@'%'",
}

// fxaAdminAccessGrants: what fxaAdminGrants gives ffs_admin on the sign-up policy
// (FXA_SIGNUPS, FXA_MAX_ACCOUNTS: ffs.settings) and the sign-up allowlist, which the admin UI's
// forms write. With ADMIN_ACCESS_EXTERNAL (docs/admin/accounts.md#access-managed-elsewhere)
// another system decides who may sign up, through ffs_access: ffs_admin then reads them only,
// and the database refuses the admin UI any change of them (fxaAdminGrantsFor)
var fxaAdminAccessGrants = map[string]string{
	"GRANT SELECT, INSERT, UPDATE, DELETE ON ffs.settings TO 'ffs_admin'@'%'":         "GRANT SELECT ON ffs.settings TO 'ffs_admin'@'%'",
	"GRANT SELECT, INSERT, UPDATE, DELETE ON ffs.signup_allowlist TO 'ffs_admin'@'%'": "GRANT SELECT ON ffs.signup_allowlist TO 'ffs_admin'@'%'",
}

// fxaAdminExternalRevokes: with ADMIN_ACCESS_EXTERNAL on your own server, where the REVOKE ALL
// of fxaAdminGrants is not allowed, the writes of a start without it revoked one by one (an
// error for a grant that is not there is fine, as for fxaObsoleteGrants)
var fxaAdminExternalRevokes = []string{
	"REVOKE INSERT, UPDATE, DELETE ON ffs.settings FROM 'ffs_admin'@'%'",
	"REVOKE INSERT, UPDATE, DELETE ON ffs.signup_allowlist FROM 'ffs_admin'@'%'",
}

// fxaAdminGrantsFor: ffs_admin's grants, and what to revoke where REVOKE ALL is not allowed,
// as ADMIN_ACCESS_EXTERNAL says
func fxaAdminGrantsFor(external bool) (grants, obsolete []string) {
	if !external {
		return fxaAdminGrants, fxaObsoleteGrants
	}
	for _, g := range fxaAdminGrants {
		if read, ok := fxaAdminAccessGrants[g]; ok {
			g = read
		}
		grants = append(grants, g)
	}
	return grants, append(append([]string{}, fxaObsoleteGrants...), fxaAdminExternalRevokes...)
}

// fxaAccessUser: the user of a system that manages who may sign up (FXA_ACCESS_DB_PASSWORD,
// docs/admin/accounts.md#access-managed-elsewhere): the rows of the sign-up allowlist, and the
// accounts by email through the procedures above; nothing of fxa.*, not ffs.settings. Its grants
// given again at every start, after the procedures are made again (dropping a procedure drops
// its grants). The REVOKE must stay first
const fxaAccessUser = "ffs_access"

var fxaAccessGrants = []string{
	"REVOKE ALL PRIVILEGES, GRANT OPTION FROM 'ffs_access'@'%'",
	"GRANT SELECT, INSERT, DELETE ON ffs.signup_allowlist TO 'ffs_access'@'%'",
	"GRANT EXECUTE ON PROCEDURE ffs.disable_account_by_email TO 'ffs_access'@'%'",
	"GRANT EXECUTE ON PROCEDURE ffs.enable_account_by_email TO 'ffs_access'@'%'",
	"GRANT EXECUTE ON PROCEDURE ffs.delete_account_by_email TO 'ffs_access'@'%'",
}

// fxaAccessExternalGrants: with ADMIN_ACCESS_EXTERNAL, the procedures of externalOnlySQL too
var fxaAccessExternalGrants = []string{
	"GRANT EXECUTE ON PROCEDURE " + sweepProcedure + " TO 'ffs_access'@'%'",
}

// fxaAccessGrantsFor: ffs_access's grants as ADMIN_ACCESS_EXTERNAL says. Without the mode the
// sweep does not exist (fxaPolicySQL drops it, and its grant with it)
func fxaAccessGrantsFor(external bool) []string {
	if !external {
		return fxaAccessGrants
	}
	return append(append([]string{}, fxaAccessGrants...), fxaAccessExternalGrants...)
}

// fxaObsoleteGrants: what the previous version granted, revoked one by one where
// REVOKE ALL is not allowed (your own server); errors for grants that are not there
// (errNoSuchGrant, errNoSuchTableGrant) are fine
var fxaObsoleteGrants = []string{
	"REVOKE UPDATE (disabledAt) ON fxa.accounts FROM 'ffs_admin'@'%'",
	"REVOKE DELETE ON fxa.sessionTokens FROM 'ffs_admin'@'%'",
	"REVOKE SELECT (uid) ON fxa.sessionTokens FROM 'ffs_admin'@'%'",
	"REVOKE DELETE ON fxa_oauth.refreshTokens FROM 'ffs_admin'@'%'",
	"REVOKE SELECT (userId) ON fxa_oauth.refreshTokens FROM 'ffs_admin'@'%'",
	"REVOKE DELETE ON fxa_oauth.tokens FROM 'ffs_admin'@'%'",
	"REVOKE SELECT (userId) ON fxa_oauth.tokens FROM 'ffs_admin'@'%'",
	"REVOKE DELETE ON fxa_oauth.codes FROM 'ffs_admin'@'%'",
	"REVOKE SELECT (userId) ON fxa_oauth.codes FROM 'ffs_admin'@'%'",
}

const (
	errNoSuchGrant      = 1141
	errNoSuchTableGrant = 1147
)

// fxaPinnedProcedures: FxA's own procedures that the ones above call. Their names carry
// a version (_1): a new FxA release may replace one. fxa-init then installs stand-ins
// that refuse with a clear message (policySQL) rather than stopping: fxa-auth waits
// for fxa-init, and the accounts must keep working
var fxaPinnedProcedures = []string{"revokeAccountTokens_1", "deleteTotpToken_4", "deleteRecoveryKey_2", "verifyEmail_9", "verifyTokensWithMethod_3", "verifyToken_3", "deleteAccount_24", "prune_10"}

var procedureCall = regexp.MustCompile(`CALL (ffs|fxa)\.(\w+)\(`)

// policySQL is the procedures (fxaPolicySQLFor) with those that call a missing one (directly,
// or through another of ffs) replaced by procedures that only refuse
func policySQL(base, missing []string) []string {
	msg := strings.Join(missing, ", ") + " is missing from the accounts database: see the log of fxa-policy"
	if len(msg) > 128 { // the limit of MESSAGE_TEXT
		msg = "procedures of FxA are missing from the accounts database: see the log of fxa-policy"
	}
	unusable := map[string]bool{}
	for _, name := range missing {
		unusable[name] = true
	}
	stmts := make([]string, len(base))
	for i, stmt := range base {
		header, _, _ := strings.Cut(stmt, "\n")
		if name, ok := strings.CutPrefix(header, "CREATE PROCEDURE "); ok {
			name, _, _ = strings.Cut(name, "(")
			for _, call := range procedureCall.FindAllStringSubmatch(stmt, -1) {
				if unusable[call[1]+"."+call[2]] {
					unusable[name] = true
					stmt = header + `
	SQL SECURITY DEFINER
	SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '` + msg + "'"
					break
				}
			}
		}
		stmts[i] = stmt
	}
	return stmts
}

// missingProcedures lists the pinned procedures not in the accounts database
func missingProcedures(ctx context.Context, db *sql.DB) ([]string, error) {
	var missing []string
	for _, name := range fxaPinnedProcedures {
		var n int
		if err := db.QueryRowContext(ctx, `SELECT COUNT(*) FROM information_schema.ROUTINES
			WHERE ROUTINE_SCHEMA = 'fxa' AND ROUTINE_NAME = ? AND ROUTINE_TYPE = 'PROCEDURE'`, name).Scan(&n); err != nil {
			return nil, err
		}
		if n == 0 {
			missing = append(missing, "fxa."+name)
		}
	}
	return missing, nil
}

func fxaInit(ctx context.Context) error {
	// the policy user, or the accounts' own (Quadlets have no ${a:-${b}}): docs/reference/database-users.md#the-accounts.
	// User and password as a pair: a policy password left over must not go with FXA_MYSQL_USER
	user, password := env("FXA_DB_ROOT_USER", ""), env("FXA_DB_ROOT_PASSWORD", "")
	if user == "" {
		user, password = env("FXA_MYSQL_USER", "root"), env("FXA_MYSQL_PASSWORD", "")
	}
	cfg := fxaConfig(user, password)
	db, err := sql.Open("mysql", cfg.FormatDSN())
	if err != nil {
		return err
	}
	defer db.Close()
	db.SetMaxOpenConns(1)

	// the migrations create fxa.accounts, compose and the quadlets start this after them
	deadline := time.Now().Add(time.Duration(envInt("FXA_INIT_TIMEOUT", 120)) * time.Second)
	for {
		var n int
		err = db.QueryRowContext(ctx, `SELECT COUNT(*) FROM information_schema.tables
			WHERE table_schema = 'fxa' AND table_name = 'accounts'`).Scan(&n)
		if err == nil && n == 1 {
			break
		}
		if time.Now().After(deadline) {
			if err == nil {
				err = fmt.Errorf("fxa.accounts does not exist, did the FxA migrations run?")
			}
			return err
		}
		log.Printf("waiting for the accounts database: %v", err)
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(2 * time.Second):
		}
	}

	// ADMIN_ACCESS_EXTERNAL: the procedures of the admin UI leave who has access alone (externalPolicySQL)
	external, err := envSwitch("ADMIN_ACCESS_EXTERNAL")
	if err != nil {
		return err
	}
	// information_schema lists only the routines this user may run: without EXECUTE on
	// fxa.* (your own server, docs/reference/database-users.md#the-accounts) they look missing too
	missing, err := missingProcedures(ctx, db)
	if err != nil {
		return err
	}
	stmts := fxaPolicySQLFor(external)
	if external {
		log.Printf("ADMIN_ACCESS_EXTERNAL: the admin UI's Enable refuses an email the sign-up policy refuses, its Delete leaves the sign-up allowlist alone")
	}
	if len(missing) > 0 {
		log.Printf("WARNING: %s missing from the accounts database (a newer FxA release renamed it, or %s has no EXECUTE on fxa.*, docs/reference/database-users.md#the-accounts): what the admin UI does with it answers with an error (docs/admin/accounts.md)",
			strings.Join(missing, ", "), user)
		stmts = policySQL(stmts, missing)
	}

	for _, stmt := range stmts {
		if _, err := db.ExecContext(ctx, stmt); err != nil {
			return fmt.Errorf("%s: %w", strings.SplitN(stmt, "\n", 2)[0], err)
		}
	}
	if err := allowlistBinary(ctx, db); err != nil {
		return fmt.Errorf("ffs.signup_allowlist: %w", err)
	}
	view, err := schemaLevelsView(ctx, db)
	if err != nil {
		return err
	}
	if _, err := db.ExecContext(ctx, view); err != nil {
		return fmt.Errorf("ffs.schema_levels: %w", err)
	}
	if err := recordFxaSetup(ctx, db); err != nil {
		return fmt.Errorf("the setup migrations: %w", err)
	}

	if password := env("FXA_ADMIN_DB_PASSWORD", ""); password != "" {
		grants, obsolete := fxaAdminGrantsFor(external)
		if err := fxaUser(ctx, db, "ffs_admin", password, grants, obsolete); err != nil {
			return err
		}
		if external {
			log.Printf("ffs_admin: SELECT only on ffs.settings and ffs.signup_allowlist (ADMIN_ACCESS_EXTERNAL: the database refuses the admin UI a change of who may sign up)")
		}
	}
	if password := env("FXA_ACCESS_DB_PASSWORD", ""); password != "" {
		if err := fxaUser(ctx, db, fxaAccessUser, password, fxaAccessGrantsFor(external), nil); err != nil {
			return err
		}
		log.Printf("%s: the user of the system that manages who may sign up (FXA_ACCESS_DB_PASSWORD)", fxaAccessUser)
	} else if err := dropFxaUser(ctx, db, fxaAccessUser); err != nil {
		return err
	}

	policy, err := applyEnvPolicy(ctx, db)
	if err != nil {
		return err
	}
	log.Printf("sign-ups: %s", describePolicy(policy))
	return applyEnvMaxAccounts(ctx, db)
}

// allowlistAlter: ffs.signup_allowlist.entry byte for byte, as the CREATE TABLE of fxaPolicySQL
// makes it. NOT NULL as before (its primary key)
const allowlistAlter = "ALTER TABLE ffs.signup_allowlist MODIFY entry VARCHAR(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin NOT NULL"

// allowlistBinary: a table made before by CREATE TABLE IF NOT EXISTS keeps the server's collation
// (utf8mb4_0900_ai_ci on MySQL, utf8mb4_uca1400_ai_ci on MariaDB 11.6+, latin1 on older ones: all
// blind to accents or widths). Converted once, at the first start that finds it, and only then. The
// primary key cannot conflict: entries distinct in a collation that equates more stay distinct byte
// for byte, and latin1 converts to utf8mb4 without loss
func allowlistBinary(ctx context.Context, db *sql.DB) error {
	var charset, collation string
	err := db.QueryRowContext(ctx, `SELECT COALESCE(CHARACTER_SET_NAME, ''), COALESCE(COLLATION_NAME, '') FROM information_schema.COLUMNS
		WHERE TABLE_SCHEMA = 'ffs' AND TABLE_NAME = 'signup_allowlist' AND COLUMN_NAME = 'entry'`).Scan(&charset, &collation)
	if err != nil {
		return err
	}
	if charset == "utf8mb4" && collation == "utf8mb4_bin" {
		return nil
	}
	if _, err := db.ExecContext(ctx, allowlistAlter); err != nil {
		return err
	}
	log.Printf("ffs.signup_allowlist: entry converted from %s to utf8mb4_bin, the allowlist now matches byte for byte (no accented or full-width look-alike)", collation)
	return nil
}

// fxaUser: a user of the accounts database with exactly its grants (the first, a REVOKE ALL),
// created with the policy user where it may (the stack's database), else made by the
// administrator of the server (docs/reference/database-users.md#the-accounts): only granted
// then, its obsolete grants revoked one by one
func fxaUser(ctx context.Context, db *sql.DB, name, password string, grants, obsolete []string) error {
	// created with the server's default plugin (mysql_native_password on MariaDB and on a
	// pinned mysql:8 with --authentication-policy=mysql_native_password), see the ALTER below
	_, err := db.ExecContext(ctx, "CREATE USER IF NOT EXISTS '"+name+"'@'%' IDENTIFIED BY ?", password)
	var myErr *mysql.MySQLError
	switch {
	case errors.As(err, &myErr) && myErr.Number == errSpecificAccessDenied:
		// your own server: no CREATE USER for the policy user (it could change any
		// account's password), the administrator created the user (docs/reference/database-users.md#the-accounts).
		// Nothing earlier versions granted to revoke there, and REVOKE ALL needs it too
		log.Printf("%s: created by the administrator of the database server, granting", name)
		grants = grants[1:]
		for _, stmt := range obsolete {
			if _, err := db.ExecContext(ctx, stmt); err != nil && !(errors.As(err, &myErr) && (myErr.Number == errNoSuchGrant || myErr.Number == errNoSuchTableGrant)) {
				return fmt.Errorf("%s: %w", stmt, err)
			}
		}
	case err != nil:
		return fmt.Errorf("creating %s: %w", name, err)
	default:
		// on MySQL caching_sha2_password, whatever the server's default: this driver speaks
		// it, and MySQL 9 has no mysql_native_password, which a pinned mysql:8 with
		// --authentication-policy=mysql_native_password gives it (docs/upgrading.md#mysql-8-to-9).
		// MariaDB has no caching_sha2_password: its default
		alter := "ALTER USER '" + name + "'@'%' IDENTIFIED BY ?"
		var version string
		if err := db.QueryRowContext(ctx, "SELECT VERSION()").Scan(&version); err != nil {
			return fmt.Errorf("the accounts database's version: %w", err)
		}
		if !strings.Contains(strings.ToLower(version), "mariadb") {
			alter = "ALTER USER '" + name + "'@'%' IDENTIFIED WITH caching_sha2_password BY ?"
		}
		if _, err := db.ExecContext(ctx, alter, password); err != nil {
			return fmt.Errorf("setting the %s password: %w", name, err)
		}
	}
	for _, stmt := range grants {
		if _, err := db.ExecContext(ctx, stmt); err != nil {
			return fmt.Errorf("%s: %w", stmt, err)
		}
	}
	return nil
}

// dropFxaUser: without its password the user goes, its grants with it (a user left with the
// grants of before would keep changing the allowlist). On your own server the policy user may
// not drop users: the administrator does, as they made it
func dropFxaUser(ctx context.Context, db *sql.DB, name string) error {
	_, err := db.ExecContext(ctx, "DROP USER IF EXISTS '"+name+"'@'%'")
	var myErr *mysql.MySQLError
	if err != nil && !(errors.As(err, &myErr) && myErr.Number == errSpecificAccessDenied) {
		return fmt.Errorf("dropping %s: %w", name, err)
	}
	return nil
}

// applyEnvMaxAccounts sets FXA_MAX_ACCOUNTS like MAX_USERS: N, fixed:N or unlimited on
// every start (read-only in the admin UI), initial:N only when there is none yet (then
// the admin UI manages it); not set: initial:unlimited. Anything else stops fxa-policy,
// and with it the accounts service: never a limit other than the one written
func applyEnvMaxAccounts(ctx context.Context, db *sql.DB) error {
	setting := env("FXA_MAX_ACCOUNTS", "")
	value, fixed, err := parseLimitSetting(setting, "initial:"+unlimitedSetting)
	if err != nil {
		return fmt.Errorf("FXA_MAX_ACCOUNTS=%q is not valid: %v, optionally after fixed: (the default, set on every start) or initial: (set once, then managed in the admin UI)", setting, err)
	}
	if err := setMaxAccounts(ctx, db, value, fixed); err != nil {
		return fmt.Errorf("FXA_MAX_ACCOUNTS: %w", err)
	}
	current := &FxaDB{db: db}
	max, unlimited, err := current.MaxAccounts(ctx)
	if err != nil {
		return err
	}
	now := Limit{Max: max, Unlimited: unlimited}.Setting()
	if fixed {
		log.Printf("max accounts: %s (FXA_MAX_ACCOUNTS, set on every start, read-only in the admin UI)", now)
	} else {
		log.Printf("max accounts: %s (FXA_MAX_ACCOUNTS=initial:%s applies to a new database only, the admin UI manages it)", now, value)
	}
	return nil
}

// schemaDatabases: the accounts databases whose migrations keep a schema-patch-level
var schemaDatabases = []string{"fxa", "fxa_oauth", "fxa_profile", "pushbox"}

// schemaLevelsView: ffs.schema_levels, the schema-patch-level (and prune-last-ran, when
// the auth server last pruned old tokens) of the accounts databases, from the dbMetadata
// tables that exist: a release without one must not stop fxa-policy
func schemaLevelsView(ctx context.Context, db *sql.DB) (string, error) {
	rows, err := db.QueryContext(ctx, `SELECT table_schema FROM information_schema.tables
		WHERE table_name = 'dbMetadata' AND table_schema IN ('fxa', 'fxa_oauth', 'fxa_profile', 'pushbox') ORDER BY table_schema`)
	if err != nil {
		return "", err
	}
	defer rows.Close()
	var found []string
	for rows.Next() {
		var name string
		if err := rows.Scan(&name); err != nil {
			return "", err
		}
		found = append(found, name)
	}
	if err := rows.Err(); err != nil {
		return "", err
	}
	return schemaLevelsSQL(found), nil
}

func schemaLevelsSQL(databases []string) string {
	var selects []string
	for _, name := range databases {
		known := false
		for _, d := range schemaDatabases {
			known = known || d == name
		}
		if !known {
			continue
		}
		// one collation for the UNION: the databases may have different defaults
		selects = append(selects, fmt.Sprintf(`SELECT '%s' AS db, CONVERT(name USING utf8mb4) COLLATE utf8mb4_bin AS name,
			CONVERT(value USING utf8mb4) COLLATE utf8mb4_bin AS value FROM %s.dbMetadata
			WHERE name IN ('schema-patch-level', 'prune-last-ran')`, name, name))
	}
	if len(selects) == 0 {
		selects = []string{"SELECT 'none' AS db, 'none' AS name, 'none' AS value FROM DUAL WHERE FALSE"}
	}
	return "CREATE OR REPLACE SQL SECURITY DEFINER VIEW ffs.schema_levels AS " + strings.Join(selects, "\nUNION ALL ")
}

// applyEnvPolicy sets FXA_SIGNUPS and FXA_SIGNUP_ALLOWLIST from .env when they changed
// since the last start (or on the first one); otherwise the values set in the admin
// UI stay
func applyEnvPolicy(ctx context.Context, db *sql.DB) (*SignupPolicy, error) {
	mode, err := ParseMode(env("FXA_SIGNUPS", SignupsOpen))
	if err != nil {
		return nil, err
	}
	allowlist, err := ParseAllowlist(env("FXA_SIGNUP_ALLOWLIST", ""))
	if err != nil {
		return nil, fmt.Errorf("FXA_SIGNUP_ALLOWLIST: %w", err)
	}
	external, err := envSwitch("ADMIN_ACCESS_EXTERNAL")
	if err != nil {
		return nil, err
	}
	if external {
		return applyExternalPolicy(ctx, db, mode, allowlist)
	}
	if mode == SignupsAllowlist && len(allowlist) == 0 {
		log.Printf("warning: FXA_SIGNUPS=allowlist with an empty FXA_SIGNUP_ALLOWLIST, nobody can sign up")
	}
	policy := &SignupPolicy{Mode: mode, Allowlist: allowlist}
	snapshot := mode + " " + strings.Join(allowlist, ",")

	var last string
	err = db.QueryRowContext(ctx, "SELECT value FROM ffs.settings WHERE name = 'env'").Scan(&last)
	if err != nil && err != sql.ErrNoRows {
		return nil, err
	}
	if err == nil && last == snapshot {
		current := &FxaDB{db: db}
		return current.Policy(ctx)
	}
	return policy, setPolicy(ctx, db, policy, nil, snapshot)
}

// applyExternalPolicy: ADMIN_ACCESS_EXTERNAL, another system keeps the rows of the sign-up
// allowlist (as ffs_access): FXA_SIGNUPS set on every start (the admin UI changes nothing
// then), the rows left as they are. A FXA_SIGNUP_ALLOWLIST would be a second source: refused.
// The snapshot is that of an empty list: turned off later with the same FXA_SIGNUPS, the rows
// stay, for the admin UI to manage
func applyExternalPolicy(ctx context.Context, db *sql.DB, mode string, allowlist []string) (*SignupPolicy, error) {
	if len(allowlist) > 0 {
		return nil, errors.New("ADMIN_ACCESS_EXTERNAL is on, so the sign-up allowlist is kept by the system that manages access: leave FXA_SIGNUP_ALLOWLIST empty (docs/admin/accounts.md#access-managed-elsewhere)")
	}
	for _, stmt := range []struct{ query, value string }{
		{"INSERT INTO ffs.settings (name, value) VALUES ('signups', ?) ON DUPLICATE KEY UPDATE value = VALUES(value)", mode},
		{"INSERT INTO ffs.settings (name, value) VALUES ('env', ?) ON DUPLICATE KEY UPDATE value = VALUES(value)", mode + " "},
	} {
		if _, err := db.ExecContext(ctx, stmt.query, stmt.value); err != nil {
			return nil, err
		}
	}
	log.Printf("ADMIN_ACCESS_EXTERNAL: sign-ups %s from FXA_SIGNUPS, the sign-up allowlist left to the system that manages access", mode)
	current := &FxaDB{db: db}
	return current.Policy(ctx)
}

func describePolicy(p *SignupPolicy) string {
	if p.Mode == SignupsAllowlist {
		return fmt.Sprintf("allowlist (%s)", strings.Join(p.Allowlist, ", "))
	}
	return p.Mode
}

// recordFxaSetup: the record of the setup migrations of the accounts (db/db-setup.sh,
// docs/databases.md#the-record-of-the-setup-migrations) in ffs, for the admin UI: its tables (the
// admin UI's grants need them), and with the stack's fxa-db (FXA_DB_CONTAINERS not 0), whose root
// the accounts and this run as, the files of this image (how 'containers'). With your own server
// fxa-db-bootstrap records what it ran or found, never this
func recordFxaSetup(ctx context.Context, db *sql.DB) error {
	var version string
	if err := db.QueryRowContext(ctx, "SELECT VERSION()").Scan(&version); err != nil {
		return err
	}
	dir := "mysql/setup/fxa-mysql"
	if strings.Contains(strings.ToLower(version), "mariadb") {
		dir = "mysql/setup/fxa-mariadb"
	}
	stmts := []string{
		"CREATE TABLE IF NOT EXISTS ffs.ffs_setup_migrations (scope VARCHAR(32) NOT NULL, number INT NOT NULL, name VARCHAR(128) NOT NULL, " +
			"checksum CHAR(64) NOT NULL, how VARCHAR(16) NOT NULL, applied_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP, PRIMARY KEY (scope, number))",
		"CREATE TABLE IF NOT EXISTS ffs.ffs_setup_state (scope VARCHAR(32) PRIMARY KEY, result VARCHAR(16) NOT NULL, expected INT NOT NULL, " +
			"detail TEXT NOT NULL, checked_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP)",
	}
	for _, stmt := range stmts {
		if _, err := db.ExecContext(ctx, stmt); err != nil {
			return err
		}
	}
	// with your own server db-bootstrap records them, from the files it ran: an image newer than
	// those files must not record what never ran there
	if env("FXA_DB_CONTAINERS", "1") == "0" {
		return nil
	}
	sums := map[string]string{}
	for _, line := range strings.Split(setupManifestText, "\n") {
		if f := strings.Fields(line); len(f) == 2 {
			sums[f[0]] = f[1]
		}
	}
	added := 0
	for _, f := range shippedSetup(setupManifestText, dir) {
		res, err := db.ExecContext(ctx, "INSERT IGNORE INTO ffs.ffs_setup_migrations (scope, number, name, checksum, how) VALUES ('fxa', ?, ?, ?, 'containers')",
			f.Number, f.Name, sums[dir+"/"+f.Name])
		if err != nil {
			return err
		}
		if n, _ := res.RowsAffected(); n > 0 {
			added++
		}
	}
	if added > 0 {
		log.Printf("setup migrations: %d recorded (the stack's accounts database)", added)
	}
	return nil
}
