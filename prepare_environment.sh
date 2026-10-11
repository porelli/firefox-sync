#!/bin/bash

# Firefox Sync Environment Preparation Script
# Supports both Docker and Podman

# Set the locale to UTF-8
export LC_CTYPE=C

# Detect container runtime
detect_runtime() {
    if command -v podman &> /dev/null; then
        echo "podman"
    elif command -v docker &> /dev/null; then
        echo "docker"
    else
        echo "none"
    fi
}

CONTAINER_RUNTIME=$(detect_runtime)

generate_random_string() {
  local length="${1}"
  tr -dc '[:alnum:]' < /dev/urandom | head -c "${length}"
}

apply_sed() {
    local file=${1}
    shift
    local expression=${@}

    if [[ "${OSTYPE}" == "darwin"* ]]; then
        # macOS: BSD sed requires an empty string with -i option
        sed -i '' "${expression}" "${file}"
    else
        # Linux and other Unix-like systems: GNU sed does not require anything after -i
        sed -i "${expression}" "${file}"
    fi
}

# domain
DOMAIN_EXAMPLE='firefox-sync.example.com'
read -e -p "Enter FQDN for your Firefox sync server [${DOMAIN_EXAMPLE}]: " SYNCSTORAGE_DOMAIN
SYNCSTORAGE_DOMAIN=${SYNCSTORAGE_DOMAIN:-${DOMAIN_EXAMPLE}}

# compose dir
CURRENT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
read -e -p "Enter full path for the docker-compose file [${CURRENT_DIR}]: " SCRIPT_DIR
SCRIPT_DIR=${SCRIPT_DIR:-${CURRENT_DIR}}

# listening port
DEFAULT_CONTAINER_EXPORT_PORT=5000
read -e -p "Listening port for syncstorage-rs [${DEFAULT_CONTAINER_EXPORT_PORT}]: " CONTAINER_EXPORT_PORT
CONTAINER_EXPORT_PORT=${CONTAINER_EXPORT_PORT:-${DEFAULT_CONTAINER_EXPORT_PORT}}

# max users
DEFAULT_MAX_USERS=1
read -e -p "Max allowed users [${DEFAULT_MAX_USERS}]: " MAX_USERS
MAX_USERS=${MAX_USERS:-${DEFAULT_MAX_USERS}}

# database backend
DEFAULT_DATABASE_BACKEND=mariadb
read -e -p "Database backend [mariadb/postgres] [${DEFAULT_DATABASE_BACKEND}]: " DATABASE_BACKEND
DATABASE_BACKEND=${DATABASE_BACKEND:-${DEFAULT_DATABASE_BACKEND}}
case "${DATABASE_BACKEND}" in
    mariadb|postgres) ;;
    *)
        echo "ERROR: unknown database backend '${DATABASE_BACKEND}'"
        exit 1
        ;;
esac

# Container runtime detection
echo ""
echo "Detected container runtime: ${CONTAINER_RUNTIME}"

if [ "${CONTAINER_RUNTIME}" = "none" ]; then
    echo "WARNING: Neither Docker nor Podman detected!"
    echo "Please install Docker or Podman before proceeding."
    read -e -p "Continue anyway? (y/N): " CONTINUE
    if [ "${CONTINUE}" != "y" ] && [ "${CONTINUE}" != "Y" ]; then
        exit 1
    fi
fi

# Ask about deployment method
if [ "${CONTAINER_RUNTIME}" = "podman" ]; then
    echo ""
    echo "Podman detected! Choose deployment method:"
    echo "  1) Quadlets (systemd integration, recommended, MariaDB only)"
    echo "  2) docker compose with the Podman socket"
    read -e -p "Deployment method [1]: " DEPLOY_METHOD
    case "${DEPLOY_METHOD:-1}" in
        1) DEPLOY_METHOD=quadlets ;;
        2) DEPLOY_METHOD=compose ;;
        *) echo "ERROR: unknown deployment method '${DEPLOY_METHOD}'"; exit 1 ;;
    esac
    if [ "${DEPLOY_METHOD}" = "quadlets" ] && [ "${DATABASE_BACKEND}" = "postgres" ]; then
        echo "WARNING: Quadlets are only provided for MariaDB, using docker compose with the Podman socket"
        DEPLOY_METHOD=compose
    fi
fi

# docker/podman user (for systemd service)
DEFAULT_CONTAINER_USER=${USER}
read -e -p "Container user [${DEFAULT_CONTAINER_USER}]: " CONTAINER_USER
CONTAINER_USER=${CONTAINER_USER:-${DEFAULT_CONTAINER_USER}}

# syncstorage image tag
DEFAULT_SYNCSTORAGE_IMAGE_TAG=latest
read -e -p "Syncstorage image tag [latest/<tag>] [${DEFAULT_SYNCSTORAGE_IMAGE_TAG}]: " SYNCSTORAGE_IMAGE_TAG
SYNCSTORAGE_IMAGE_TAG=${SYNCSTORAGE_IMAGE_TAG:-${DEFAULT_SYNCSTORAGE_IMAGE_TAG}}

# random passwords
MARIADB_TOKENSERVER_PASSWORD=$(generate_random_string 24)
MARIADB_SYNCSTORAGE_PASSWORD=$(generate_random_string 24)
POSTGRES_PASSWORD=$(generate_random_string 24)
SYNC_MASTER_SECRET=$(generate_random_string 24)
METRICS_HASH_SECRET=$(generate_random_string 24)

# prepare .env file
cp ${SCRIPT_DIR}/.env-example ${SCRIPT_DIR}/.env
apply_sed ${SCRIPT_DIR}/.env "s|MARIADB_TOKENSERVER_PASSWORD=.*|MARIADB_TOKENSERVER_PASSWORD=${MARIADB_TOKENSERVER_PASSWORD}|"
apply_sed ${SCRIPT_DIR}/.env "s|MARIADB_SYNCSTORAGE_PASSWORD=.*|MARIADB_SYNCSTORAGE_PASSWORD=${MARIADB_SYNCSTORAGE_PASSWORD}|"
apply_sed ${SCRIPT_DIR}/.env "s|POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=${POSTGRES_PASSWORD}|"
apply_sed ${SCRIPT_DIR}/.env "s|SYNC_MASTER_SECRET=.*|SYNC_MASTER_SECRET=${SYNC_MASTER_SECRET}|"
apply_sed ${SCRIPT_DIR}/.env "s|METRICS_HASH_SECRET=.*|METRICS_HASH_SECRET=${METRICS_HASH_SECRET}|"
apply_sed ${SCRIPT_DIR}/.env "s|SYNCSTORAGE_DOMAIN=.*|SYNCSTORAGE_DOMAIN=https://${SYNCSTORAGE_DOMAIN}|"
apply_sed ${SCRIPT_DIR}/.env "s|CONTAINER_EXPORT_PORT=.*|CONTAINER_EXPORT_PORT=${CONTAINER_EXPORT_PORT}|"
apply_sed ${SCRIPT_DIR}/.env "s|MAX_USERS=.*|MAX_USERS=${MAX_USERS}|"
apply_sed ${SCRIPT_DIR}/.env "s|SYNCSTORAGE_IMAGE_TAG=.*|SYNCSTORAGE_IMAGE_TAG=${SYNCSTORAGE_IMAGE_TAG}|"
if [ "${DATABASE_BACKEND}" = "postgres" ]; then
    apply_sed ${SCRIPT_DIR}/.env "s|# COMPOSE_FILE=.*|COMPOSE_FILE=docker-compose.postgres.yml|"
    apply_sed ${SCRIPT_DIR}/.env "s|SYNCSTORAGE_IMAGE=.*|SYNCSTORAGE_IMAGE=syncstorage-rs-postgres|"
    apply_sed ${SCRIPT_DIR}/.env "s|SYNCSTORAGE_INIT_IMAGE=.*|SYNCSTORAGE_INIT_IMAGE=syncstorage-rs-postgres-init|"
fi

# prepare nginx example
cp ${SCRIPT_DIR}/config/nginx/syncstorage-rs-example.conf ${SCRIPT_DIR}/config/nginx/syncstorage-rs.conf
apply_sed ${SCRIPT_DIR}/config/nginx/syncstorage-rs.conf "s/firefox-sync.example.com/${SYNCSTORAGE_DOMAIN}/g"
apply_sed ${SCRIPT_DIR}/config/nginx/syncstorage-rs.conf "s|<CONTAINER_EXPORT_PORT>|${CONTAINER_EXPORT_PORT}|"

# prepare systemd example (for docker compose; with Podman, Quadlets start at boot instead)
cp ${SCRIPT_DIR}/config/systemd/syncstorage-rs-example.service ${SCRIPT_DIR}/config/systemd/syncstorage-rs.service
apply_sed ${SCRIPT_DIR}/config/systemd/syncstorage-rs.service "s|<DOCKER_USER>|${CONTAINER_USER}|"
apply_sed ${SCRIPT_DIR}/config/systemd/syncstorage-rs.service "s|<COMPOSE_DIR>|${SCRIPT_DIR}|"

# Setup Quadlets if requested
if [ "${CONTAINER_RUNTIME}" = "podman" ] && [ "${DEPLOY_METHOD}" = "quadlets" ]; then
    echo ""
    echo "Setting up Podman Quadlets..."
    
    QUADLET_DIR="${QUADLET_DIR:-${HOME}/.config/containers/systemd}"

    # load the generated values (database names, users, FxA endpoints, etc.)
    set -a
    source ${SCRIPT_DIR}/.env
    set +a
    mkdir -p "${QUADLET_DIR}"
    
    echo "Processing quadlet files..."
    for file in ${SCRIPT_DIR}/config/quadlet/*.{network,volume,container}; do
        if [ -f "$file" ]; then
            filename=$(basename "$file")
            echo "  Processing: $filename"
            
            # Replace environment variables
            sed -e "s|%MARIADB_SYNCSTORAGE_DATABASE%|${MARIADB_SYNCSTORAGE_DATABASE}|g" \
                -e "s|%MARIADB_SYNCSTORAGE_USER%|${MARIADB_SYNCSTORAGE_USER}|g" \
                -e "s|%MARIADB_SYNCSTORAGE_PASSWORD%|${MARIADB_SYNCSTORAGE_PASSWORD}|g" \
                -e "s|%MARIADB_TOKENSERVER_DATABASE%|${MARIADB_TOKENSERVER_DATABASE}|g" \
                -e "s|%MARIADB_TOKENSERVER_USER%|${MARIADB_TOKENSERVER_USER}|g" \
                -e "s|%MARIADB_TOKENSERVER_PASSWORD%|${MARIADB_TOKENSERVER_PASSWORD}|g" \
                -e "s|%SYNC_MASTER_SECRET%|${SYNC_MASTER_SECRET}|g" \
                -e "s|%METRICS_HASH_SECRET%|${METRICS_HASH_SECRET}|g" \
                -e "s|%SYNCSTORAGE_DOMAIN%|${SYNCSTORAGE_DOMAIN}|g" \
                -e "s|%CONTAINER_EXPORT_PORT%|${CONTAINER_EXPORT_PORT}|g" \
                -e "s|%MAX_USERS%|${MAX_USERS}|g" \
                -e "s|%FXA_EMAIL_DOMAIN%|${FXA_EMAIL_DOMAIN}|g" \
                -e "s|%FXA_OAUTH_SERVER_URL%|${FXA_OAUTH_SERVER_URL}|g" \
                -e "s|%REPOSITORY%|${REPOSITORY}|g" \
                -e "s|%SYNCSTORAGE_IMAGE%|${SYNCSTORAGE_IMAGE}|g" \
                -e "s|%SYNCSTORAGE_IMAGE_TAG%|${SYNCSTORAGE_IMAGE_TAG}|g" \
                -e "s|%SYNCSTORAGE_INIT_IMAGE%|${SYNCSTORAGE_INIT_IMAGE}|g" \
                -e "s|%SYNCSTORAGE_INIT_IMAGE_TAG%|${SYNCSTORAGE_INIT_IMAGE_TAG}|g" \
                "$file" > "${QUADLET_DIR}/$filename"
            
            echo "    ✓ Installed to ${QUADLET_DIR}/$filename"
        fi
    done
    
    echo ""
    echo "Reloading systemd daemon..."
    systemctl --user daemon-reload
fi

echo ""
echo "=========================================="
echo "Configuration complete!"
echo "=========================================="
echo ""
echo "Container Runtime: ${CONTAINER_RUNTIME}"
echo "Database Backend: ${DATABASE_BACKEND}"
echo "Configuration files created:"
echo "  - .env"
echo "  - config/nginx/syncstorage-rs.conf"
echo "  - config/systemd/syncstorage-rs.service"

if [ "${CONTAINER_RUNTIME}" = "podman" ] && [ "${DEPLOY_METHOD}" = "quadlets" ]; then
    echo "  - Quadlet files in ${QUADLET_DIR}"
fi

echo ""

if [ "${CONTAINER_RUNTIME}" = "podman" ] && [ "${DEPLOY_METHOD}" = "quadlets" ]; then
    echo "Next steps for Quadlet deployment:"
    echo "  1. systemctl --user start firefox-sync-syncstorage.service"
    echo "  2. (Optional) loginctl enable-linger \$USER"
    echo ""
    echo "To check status:"
    echo "  systemctl --user status firefox-sync-syncstorage.service"
    echo ""
    echo "See PODMAN.md for detailed instructions"
elif [ "${CONTAINER_RUNTIME}" = "podman" ]; then
    if [ "${DATABASE_BACKEND}" = "postgres" ]; then
        COMPOSE_FILES="-f docker-compose.postgres.yml"
    else
        COMPOSE_FILES="-f docker-compose.yml -f docker-compose.podman.yml"
    fi
    echo "Next steps for docker compose with the Podman socket:"
    echo "  1. systemctl --user enable --now podman.socket"
    echo "  2. export DOCKER_HOST=unix://\${XDG_RUNTIME_DIR}/podman/podman.sock"
    echo "  3. docker compose ${COMPOSE_FILES} up -d"
    echo ""
    echo "See PODMAN.md for detailed instructions (podman-compose is not supported)"
else
    echo "Next steps:"
    echo "  1. docker compose up -d"
    echo "  2. (Optional) Install systemd service:"
    echo "     sudo cp config/systemd/syncstorage-rs.service /etc/systemd/system/"
    echo "     sudo systemctl enable --now syncstorage-rs.service"
fi

echo "=========================================="
