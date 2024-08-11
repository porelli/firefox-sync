ARG SYNCSTORAGE_IMAGE

# Temporary stage to extract the original user and group
FROM ${SYNCSTORAGE_IMAGE} AS temp

# Create a directory to store the user and group info
RUN mkdir -p /tmp/userinfo

# Get the original user and group using id command
RUN original_uid=$(id -u) && \
    original_gid=$(id -g) && \
    echo $original_uid > /tmp/userinfo/original_uid && \
    echo $original_gid > /tmp/userinfo/original_gid

# Final stage
FROM ${SYNCSTORAGE_IMAGE}

# Copy the original user, UID, and GID from the temporary stage
COPY --from=temp /tmp/userinfo/original_uid /tmp/userinfo/original_uid
COPY --from=temp /tmp/userinfo/original_gid /tmp/userinfo/original_gid

# Temporarily switch to root to restore apt, install default-mysql-client and copy the script
USER root

# Read the original user, UID, and GID from files and create the user and group if necessary
RUN mkdir -p -m 0700 /var/lib/apt/lists/partial && \
    mkdir -p -m 0755 /var/lib/apt/lists/auxfiles && \
    chown _apt:root /var/lib/apt/lists/auxfiles && \
    chown _apt:root /var/lib/apt/lists/partial && \
    apt-get -q update && \
    apt-get install -y default-mysql-client && \
    rm -rf /var/lib/apt/lists/*

COPY --chmod=0755 db_init.sh /db_init.sh

# Switch back to the original user and group
RUN export ORIGINAL_USER=$(cat /tmp/userinfo/original_uid) && \
    export ORIGINAL_GROUP=$(cat /tmp/userinfo/original_gid)

USER ${ORIGINAL_USER}:${ORIGINAL_GROUP}