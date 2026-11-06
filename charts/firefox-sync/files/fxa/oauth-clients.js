// Writes the OAuth clients Firefox needs (desktop, Android, iOS, the accounts
// settings page) and the Sync scope with its encryption keys (without it the
// accounts pages cannot give Firefox the Sync keys: "OAuth login completed
// without scoped keys") to the file named by $1, taken from the auth server's own
// config/dev.json so they follow upstream, with the redirect URIs pointing to
// this deployment ($CONTENT_SERVER_URL) instead of http://localhost:3030.
// The Firefox clients are all public (PKCE), Firefox never sends a secret: the secrets
// published in dev.json are replaced with the hash of a random one nobody knows.
// With $ADMIN_FXA_CLIENT_ID (and $ADMIN_OIDC_REDIRECT_URL) it also registers the
// admin UI as an OpenID Connect client: trusted (no consent screen), public with
// PKCE, or confidential with $ADMIN_FXA_CLIENT_SECRET (FxA then refuses PKCE).
// It also sets mfa.jwt.secretKey, the key of the tokens that let a session change the
// password, email, 2-step, recovery key or passkeys after a fresh confirmation code: derived
// from $OAUTH_SERVER_SECRET_KEY (an HMAC-SHA256, the same on every start and replica), unless
// $MFA__JWT__KEY is set. Without it the auth server used the published default ("foxes");
// since v1.349.0 it refuses to start in production with that or a key under 32 bytes.
// Run from the fxa-auth-server directory, before the key scripts (gen_keys.js...: they load
// the config, which needs that key) and bin/key_server.js.
const crypto = require('crypto');
const fs = require('fs');

const CLIENTS = [
  '5882386c6d801776', // Firefox (desktop)
  'a2270f727f45f648', // Fenix (Android)
  '1b1a3e44c54fbb58', // Firefox for iOS
  '3c49430b43dfba77', // Android Components Reference Browser
  'ea3ca969f8c6bb0d', // Firefox Accounts
  '98e6508e88680e1a', // Firefox Accounts Settings
];
const SCOPES = ['https://identity.mozilla.com/apps/oldsync'];
const contentUrl = process.env.CONTENT_SERVER_URL.replace(/\/$/, '');
const dev = JSON.parse(fs.readFileSync('config/dev.json', 'utf-8'));
const clients = dev.oauthServer.clients
  .filter((c) => CLIENTS.includes(c.id))
  .map(({ hashedSecret, hashedSecretPrevious, ...c }) => ({
    ...c,
    hashedSecret: crypto.createHash('sha256').update(crypto.randomBytes(32)).digest('hex'),
    redirectUri: c.redirectUri.split('http://localhost:3030').join(contentUrl),
  }));
const notPublic = clients.filter((c) => !c.publicClient).map((c) => c.id);
if (notPublic.length) {
  console.error(`Expected public OAuth clients only: ${notPublic.join(', ')}`);
  process.exit(1);
}
const missing = CLIENTS.filter((id) => !clients.some((c) => c.id === id));
if (missing.length) {
  console.error(`OAuth clients missing from config/dev.json: ${missing.join(', ')}`);
  process.exit(1);
}
const admin = adminClient();
if (admin) clients.push(admin);
const scopes = dev.oauthServer.scopes.filter((s) => SCOPES.includes(s.scope) && s.hasScopedKeys);
if (scopes.length !== SCOPES.length) {
  console.error(`Scopes with keys missing from config/dev.json: ${SCOPES.join(', ')}`);
  process.exit(1);
}

// sha256 of the secret's bytes, what the auth server compares at /v1/token
function hashSecret(hex) {
  return crypto.createHash('sha256').update(Buffer.from(hex, 'hex')).digest('hex');
}

function adminClient() {
  const id = process.env.ADMIN_FXA_CLIENT_ID || '';
  const secret = process.env.ADMIN_FXA_CLIENT_SECRET || '';
  const redirectUri = process.env.ADMIN_OIDC_REDIRECT_URL || '';
  if (!id) return null;
  const fail = (message) => {
    console.error(`Admin UI OAuth client: ${message}`);
    process.exit(1);
  };
  if (!/^[0-9a-f]{16}$/.test(id)) fail('ADMIN_FXA_CLIENT_ID must be 16 lowercase hex characters');
  if (secret && !/^[0-9a-f]{64}$/.test(secret)) fail('ADMIN_FXA_CLIENT_SECRET must be 64 lowercase hex characters');
  let url;
  try {
    url = new URL(redirectUri);
  } catch {
    fail('ADMIN_OIDC_REDIRECT_URL must be the public URL of /auth/callback of the admin UI');
  }
  if (!['https:', 'http:'].includes(url.protocol) || url.pathname !== '/auth/callback' || url.search || url.hash) {
    fail(`ADMIN_OIDC_REDIRECT_URL must end in /auth/callback: ${redirectUri}`);
  }
  if (clients.some((c) => c.id === id)) fail(`ADMIN_FXA_CLIENT_ID ${id} is taken by a Firefox client`);
  return {
    id,
    name: 'Firefox Sync admin',
    imageUri: '',
    redirectUri,
    // a public client gets the hash of a random secret nobody knows, like Firefox
    hashedSecret: hashSecret(secret || crypto.randomBytes(32).toString('hex')),
    trusted: true,
    canGrant: false,
    publicClient: !secret,
    allowedScopes: 'openid profile email',
  };
}

// (the environment wins over this file: an MFA__JWT__KEY of your own is used as it is)
const config = { oauthServer: { clients, scopes } };
if (!process.env.MFA__JWT__KEY) {
  const secret = process.env.OAUTH_SERVER_SECRET_KEY || '';
  if (!secret) {
    console.error('OAUTH_SERVER_SECRET_KEY is not set (FXA_OAUTH_SECRET of .env): no key for the MFA JWTs');
    process.exit(1);
  }
  const key = crypto.createHmac('sha256', secret).update('firefox-sync mfa.jwt.secretKey').digest('hex');
  config.mfa = { jwt: { secretKey: key } };
}
// (it holds a secret now: this user only, as the other keys of /fxa-keys)
fs.writeFileSync(process.argv[2], JSON.stringify(config, null, 2), { mode: 0o600 });
fs.chmodSync(process.argv[2], 0o600);
console.log(`Wrote ${clients.length} OAuth clients${admin ? ` (with the admin UI, ${admin.publicClient ? 'public' : 'confidential'})` : ''} and ${scopes.length} scopes for ${contentUrl}`);
