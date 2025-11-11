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
    echo "  1) podman-compose (similar to docker-compose)"
    echo "  2) Quadlets (systemd integration, recommended for production)"
    read -e -p "Deployment method [1]: " DEPLOY_METHOD
    DEPLOY_METHOD=${DEPLOY_METHOD:-1}
fi

# docker/podman user (for systemd service)
DEFAULT_CONTAINER_USER=${USER}
read -e -p "Container user [${DEFAULT_CONTAINER_USER}]: " CONTAINER_USER
CONTAINER_USER=${CONTAINER_USER:-${DEFAULT_CONTAINER_USER}}

# random passwords
MARIADB_TOKENSERVER_PASSWORD=$(generate_random_string 24)
MARIADB_SYNCSTORAGE_PASSWORD=$(generate_random_string 24)
SYNC_MASTER_SECRET=$(generate_random_string 24)
METRICS_HASH_SECRET=$(generate_random_string 24)

# prepare .env file
cp ${SCRIPT_DIR}/.env-example ${SCRIPT_DIR}/.env
apply_sed ${SCRIPT_DIR}/.env "s|MARIADB_TOKENSERVER_PASSWORD=.*|MARIADB_TOKENSERVER_PASSWORD=${MARIADB_TOKENSERVER_PASSWORD}|"
apply_sed ${SCRIPT_DIR}/.env "s|MARIADB_SYNCSTORAGE_PASSWORD=.*|MARIADB_SYNCSTORAGE_PASSWORD=${MARIADB_SYNCSTORAGE_PASSWORD}|"
apply_sed ${SCRIPT_DIR}/.env "s|SYNC_MASTER_SECRET=.*|SYNC_MASTER_SECRET=${SYNC_MASTER_SECRET}|"
apply_sed ${SCRIPT_DIR}/.env "s|METRICS_HASH_SECRET=.*|METRICS_HASH_SECRET=${METRICS_HASH_SECRET}|"
apply_sed ${SCRIPT_DIR}/.env "s|SYNCSTORAGE_DOMAIN=.*|SYNCSTORAGE_DOMAIN=https://${SYNCSTORAGE_DOMAIN}|"
apply_sed ${SCRIPT_DIR}/.env "s|CONTAINER_EXPORT_PORT=.*|CONTAINER_EXPORT_PORT=${CONTAINER_EXPORT_PORT}|"
apply_sed ${SCRIPT_DIR}/.env "s|MAX_USERS=.*|MAX_USERS=${MAX_USERS}|"

# prepare nginx example
cp ${SCRIPT_DIR}/config/nginx/syncstorage-rs-example.conf ${SCRIPT_DIR}/config/nginx/syncstorage-rs.conf
apply_sed ${SCRIPT_DIR}/config/nginx/syncstorage-rs.conf "s/firefox-sync.example.com/${SYNCSTORAGE_DOMAIN}/g"
apply_sed ${SCRIPT_DIR}/config/nginx/syncstorage-rs.conf "s|<CONTAINER_EXPORT_PORT>|${CONTAINER_EXPORT_PORT}|"

# prepare systemd example (for docker-compose/podman-compose)
cp ${SCRIPT_DIR}/config/systemd/syncstorage-rs-example.service ${SCRIPT_DIR}/config/systemd/syncstorage-rs.service
apply_sed ${SCRIPT_DIR}/config/systemd/syncstorage-rs.service "s|<DOCKER_USER>|${CONTAINER_USER}|"
apply_sed ${SCRIPT_DIR}/config/systemd/syncstorage-rs.service "s|<COMPOSE_DIR>|${SCRIPT_DIR}|"

# Update systemd service for podman if needed
if [ "${CONTAINER_RUNTIME}" = "podman" ]; then
    apply_sed ${SCRIPT_DIR}/config/systemd/syncstorage-rs.service "s|docker.service|podman.service|g"
    apply_sed ${SCRIPT_DIR}/config/systemd/syncstorage-rs.service "s|/usr/bin/docker|/usr/bin/podman|g"
    apply_sed ${SCRIPT_DIR}/config/systemd/syncstorage-rs.service "s|Group=docker|Group=${CONTAINER_USER}|"
fi

# Setup Quadlets if requested
if [ "${CONTAINER_RUNTIME}" = "podman" ] && [ "${DEPLOY_METHOD}" = "2" ]; then
    echo ""
    echo "Setting up Podman Quadlets..."
    
    QUADLET_DIR="${HOME}/.config/containers/systemd"
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
echo "Configuration files created:"
echo "  - .env"
echo "  - config/nginx/syncstorage-rs.conf"
echo "  - config/systemd/syncstorage-rs.service"

if [ "${CONTAINER_RUNTIME}" = "podman" ] && [ "${DEPLOY_METHOD}" = "2" ]; then
    echo "  - Quadlet files in ${QUADLET_DIR}"
fi

echo ""

if [ "${CONTAINER_RUNTIME}" = "podman" ] && [ "${DEPLOY_METHOD}" = "2" ]; then
    echo "Next steps for Quadlet deployment:"
    echo "  1. systemctl --user start firefox-sync-tokenserver-db-init.service"
    echo "  2. systemctl --user enable firefox-sync-syncstorage.service"
    echo "  3. (Optional) loginctl enable-linger \$USER"
    echo ""
    echo "To check status:"
    echo "  systemctl --user status firefox-sync-syncstorage.service"
    echo ""
    echo "See PODMAN.md for detailed instructions"
elif [ "${CONTAINER_RUNTIME}" = "podman" ]; then
    echo "Next steps for podman-compose:"
    echo "  1. podman-compose -f docker-compose.yml -f docker-compose.podman.yml up -d"
    echo ""
    echo "See PODMAN.md for detailed instructions"
else
    echo "Next steps:"
    echo "  1. docker compose up -d"
    echo "  2. (Optional) Install systemd service:"
    echo "     sudo cp config/systemd/syncstorage-rs.service /etc/systemd/system/"
    echo "     sudo systemctl enable --now syncstorage-rs.service"
fi

echo "=========================================="
