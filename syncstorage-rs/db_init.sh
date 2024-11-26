#!/bin/bash

IS_DONE=10;
# adding service info
while [ ${IS_DONE} -gt 0 ]; do
  echo "INSERT IGNORE INTO services (id, service, pattern) VALUES ('1', 'sync-1.5', '{node}/1.5/{uid}');
        INSERT INTO nodes (id, service, node, available, current_load, capacity, downed, backoff)
        VALUES ('1', '1', '${DOMAIN}', '1', '0', '5', '0', '0') ON DUPLICATE KEY UPDATE node='${DOMAIN}';" | mariadb --host=tokenserver_db --user=${MARIADB_USER} --password=${MARIADB_PASSWORD} ${MARIADB_DATABASE};
  RC=${?};
  if [ $RC == 0 ] ; then
    IS_DONE=0;
    # setting users limit
    echo "DELIMITER //
          DROP PROCEDURE IF EXISTS tokenserver.CheckUserLimit;
          CREATE PROCEDURE tokenserver.CheckUserLimit()
          BEGIN
              DECLARE user_count INT;
              DECLARE max_users INT DEFAULT 0;
              SELECT COUNT(*) INTO user_count FROM tokenserver.users;
              SET max_users = ${MAX_USERS};
              IF user_count >= max_users THEN
                  SIGNAL SQLSTATE '45000'
                  SET MESSAGE_TEXT = 'User limit exceeded';
              END IF;
          END //
          DELIMITER ;
          DELIMITER //
          DROP TRIGGER IF EXISTS tokenserver.BeforeInsertUser;
          CREATE TRIGGER tokenserver.BeforeInsertUser
          BEFORE INSERT ON tokenserver.users
          FOR EACH ROW
          BEGIN
              CALL tokenserver.CheckUserLimit();
          END //
          DELIMITER ;" | mariadb --host=tokenserver_db --user=${MARIADB_USER} --password=${MARIADB_PASSWORD} ${MARIADB_DATABASE};
    echo 'Database is correctly intialized!';
    current_users=`mariadb --host=tokenserver_db --user=${MARIADB_USER} --password=${MARIADB_PASSWORD} ${MARIADB_DATABASE} -sN -e 'SELECT COUNT(*) FROM users;'`
    echo "-----"
    echo "Current users: ${current_users}"
    echo "Max users: ${MAX_USERS}"
    echo "-----"
    exit 0;
  else
    echo 'Waiting for tables...';
    sleep 5;
    ((IS_DONE--));
  fi;
done;
echo 'Giving up, sorry';
exit 42;