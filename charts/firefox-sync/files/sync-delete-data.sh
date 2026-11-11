# shellcheck shell=sh
# Sourced by the Sync server's container before syncserver starts (compose/sync.yml, the
# Quadlet firefox-sync-syncstorage.container, the chart's syncstorage container), in the
# syncstorage-rs image: its sh and python3 (with cryptography, of upstream's tools).
#
# SYNC_DELETE_DATA=true (docs/admin/accounts.md#sync-data-through-the-sync-server): the data
# deletion endpoint of syncstorage-rs 0.25.0 on, DELETE /1.0/users/<account id>/storage, for
# the admin UI. It takes only assertions signed with SYNC_DELETE_DATA_KEY, this install's
# key: its public half becomes the tokenserver's secondary JWK, the only one configured, with
# the audience and issuer the admin UI signs for (admin/deletedata.go). The key itself is not
# passed on to syncserver.
#
# A JWK configured, the tokenserver checks JWT access tokens with it alone instead of asking
# FXA_OAUTH_SERVER_URL for its keys: the self-hosted accounts' access tokens are not JWTs
# (JWT_ACCESS_TOKENS_ENABLED_CLIENT_IDS empty, its default), they still go to its /v1/verify.
# Mozilla's accounts may send JWTs: off with them. Anything wrong leaves the endpoint off, the
# Sync server starts as without it, and says so here (the admin UI's health page too).
ffs_delete_data() {
    [ "${SYNC_DELETE_DATA:-false}" = true ] || return 0
    case "${SYNC_TOKENSERVER__FXA_OAUTH_SERVER_URL:-}" in
        *firefox.com*|*mozaws.net*)
            echo "ERROR: SYNC_DELETE_DATA is for the self-hosted accounts, not Mozilla's (FXA_OAUTH_SERVER_URL): the data deletion endpoint stays off"
            return 0 ;;
    esac
    if [ -z "${SYNC_DELETE_DATA_KEY:-}" ]; then
        echo "ERROR: SYNC_DELETE_DATA is true but SYNC_DELETE_DATA_KEY is empty (./prepare_environment.sh --upgrade generates it): the data deletion endpoint stays off"
        return 0
    fi
    # the modulus and exponent of the key, in base64url (the key in PEM, as is or in base64)
    ffs_jwk=$(printf '%s' "${SYNC_DELETE_DATA_KEY}" | python3 -c '
import base64, sys
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives.serialization import load_pem_private_key
v = sys.stdin.read().strip().encode()
key = load_pem_private_key(v if v.startswith(b"-----BEGIN") else base64.b64decode(v), None)
assert isinstance(key, rsa.RSAPrivateKey) and key.key_size >= 2048
p = key.public_key().public_numbers()
b = lambda i: base64.urlsafe_b64encode(i.to_bytes((i.bit_length() + 7) // 8, "big")).rstrip(b"=").decode()
print(b(p.n), b(p.e))
' 2> /dev/null) || ffs_jwk=""
    if [ -z "${ffs_jwk}" ]; then
        echo "ERROR: SYNC_DELETE_DATA_KEY is not an RSA private key of 2048 bits or more: the data deletion endpoint stays off"
        return 0
    fi
    export SYNC_TOKENSERVER__FXA_DELETE_DATA_ENABLED=true \
        SYNC_TOKENSERVER__FXA_DELETE_DATA_AUDIENCE=urn:firefox-sync:sync-data-delete \
        SYNC_TOKENSERVER__FXA_DELETE_DATA_ISSUER=urn:firefox-sync:admin-ui \
        SYNC_TOKENSERVER__FXA_OAUTH_SECONDARY_JWK__KTY=RSA \
        SYNC_TOKENSERVER__FXA_OAUTH_SECONDARY_JWK__ALG=RS256 \
        SYNC_TOKENSERVER__FXA_OAUTH_SECONDARY_JWK__USE=sig \
        SYNC_TOKENSERVER__FXA_OAUTH_SECONDARY_JWK__KID=firefox-sync-delete-data \
        SYNC_TOKENSERVER__FXA_OAUTH_SECONDARY_JWK__N="${ffs_jwk% *}" \
        SYNC_TOKENSERVER__FXA_OAUTH_SECONDARY_JWK__E="${ffs_jwk#* }"
    echo "The data deletion endpoint is on (SYNC_DELETE_DATA): it takes the admin UI's assertions"
}
ffs_delete_data
unset SYNC_DELETE_DATA_KEY ffs_jwk
