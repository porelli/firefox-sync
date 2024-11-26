#!/bin/bash

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
MARIADB_TOKENSERVER_PASSWORD=$(cat /dev/urandom | tr -dc '[:alnum:]' | head -c 24)
MARIADB_SYNCSTORAGE_PASSWORD=$(cat /dev/urandom | tr -dc '[:alnum:]' | head -c 24)
SYNC_MASTER_SECRET=$(cat /dev/urandom | tr -dc '[:alnum:]' | head -c 24)
METRICS_HASH_SECRET=$(cat /dev/urandom | tr -dc '[:alnum:]' | head -c 24)

# prepare .env file
cp ${SCRIPT_DIR}/.env-example ${SCRIPT_DIR}/.env
sed -i "s|MARIADB_TOKENSERVER_PASSWORD=.*|MARIADB_TOKENSERVER_PASSWORD=${MARIADB_TOKENSERVER_PASSWORD}|" ${SCRIPT_DIR}/.env
sed -i "s|MARIADB_SYNCSTORAGE_PASSWORD=.*|MARIADB_SYNCSTORAGE_PASSWORD=${MARIADB_SYNCSTORAGE_PASSWORD}|" ${SCRIPT_DIR}/.env
sed -i "s|SYNC_MASTER_SECRET=.*|SYNC_MASTER_SECRET=${SYNC_MASTER_SECRET}|" ${SCRIPT_DIR}/.env
sed -i "s|METRICS_HASH_SECRET=.*|METRICS_HASH_SECRET=${METRICS_HASH_SECRET}|" ${SCRIPT_DIR}/.env
sed -i "s|SYNCSTORAGE_DOMAIN=.*|SYNCSTORAGE_DOMAIN=https://${SYNCSTORAGE_DOMAIN}|" ${SCRIPT_DIR}/.env
sed -i "s|CONTAINER_EXPORT_PORT=.*|CONTAINER_EXPORT_PORT=${CONTAINER_EXPORT_PORT}|" ${SCRIPT_DIR}/.env
sed -i "s|MAX_USERS=.*|MAX_USERS=${MAX_USERS}|" ${SCRIPT_DIR}/.env

# prepare nginx example
cp ${SCRIPT_DIR}/config/nginx/syncstorage-rs-example.conf   ${SCRIPT_DIR}/config/nginx/syncstorage-rs.conf
sed -i "s/firefox-sync.example.com/${SYNCSTORAGE_DOMAIN}/g" ${SCRIPT_DIR}/config/nginx/syncstorage-rs.conf

# prepare systemd example
cp ${SCRIPT_DIR}/config/systemd/syncstorage-rs-example.service ${SCRIPT_DIR}/config/systemd/syncstorage-rs.service
sed -i "s|<DOCKER_USER>|${DOCKER_USER}|" ${SCRIPT_DIR}/config/systemd/syncstorage-rs.service
sed -i "s|<COMPOSE_DIR>|${SCRIPT_DIR}|"  ${SCRIPT_DIR}/config/systemd/syncstorage-rs.service
