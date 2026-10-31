# the client only (psql, newer than or as new as any server it reaches): the newest major
FROM docker.io/library/postgres:latest

COPY db_init.sh /scripts/db_init.sh
COPY db_init.sql /scripts/db_init.sql
COPY admin_grants.sql /scripts/admin_grants.sql
COPY sync_owner.sql /scripts/sync_owner.sql
# the setup migrations released (a copy of db/setup-manifest), recorded with the stack's database containers
COPY setup-manifest /scripts/setup-manifest
RUN chmod 0755 /scripts/db_init.sh

ENTRYPOINT ["/bin/bash", "/scripts/db_init.sh"]
