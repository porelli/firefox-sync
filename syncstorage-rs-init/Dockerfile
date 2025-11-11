FROM mariadb:lts

COPY db_init.sh /scripts/db_init.sh
COPY db_init.sql /scripts/db_init.sql
RUN chmod 0755 /scripts/db_init.sh

ENTRYPOINT ["/bin/bash", "/scripts/db_init.sh"]