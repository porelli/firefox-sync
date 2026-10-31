FROM docker.io/library/mariadb:lts

COPY db_init.sh /scripts/db_init.sh
COPY db_init.sql /scripts/db_init.sql
# the setup migrations released (a copy of db/setup-manifest), recorded with the stack's database containers
COPY setup-manifest /scripts/setup-manifest
RUN chmod 0755 /scripts/db_init.sh

ENTRYPOINT ["/bin/bash", "/scripts/db_init.sh"]