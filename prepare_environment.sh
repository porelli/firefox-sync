#!/bin/bash

# Set the locale to UTF-8
export LC_CTYPE=C

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

# docker user
DEFAULT_DOCKER_USER=${USER}
read -e -p "Docker user [${DEFAULT_DOCKER_USER}]: " DOCKER_USER
DOCKER_USER=${DOCKER_USER:-${DEFAULT_DOCKER_USER}}

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

# prepare systemd example
cp ${SCRIPT_DIR}/config/systemd/syncstorage-rs-example.service ${SCRIPT_DIR}/config/systemd/syncstorage-rs.service
apply_sed ${SCRIPT_DIR}/config/systemd/syncstorage-rs.service "s|<DOCKER_USER>|${DOCKER_USER}|"
apply_sed ${SCRIPT_DIR}/config/systemd/syncstorage-rs.service "s|<COMPOSE_DIR>|${SCRIPT_DIR}|"
