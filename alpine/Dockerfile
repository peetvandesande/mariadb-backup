FROM alpine:3

# Install only client tooling (no postgres server)
# - mariadb-client: mariadb, mariadb-dump, mariadb-import and mysql equivalents
# - coreutils: for date, ls behavior, sha256sum
# - gzip, bzip2, zstd: compression support
# Set MariaDB client behaviour in configuration file
RUN apk add --no-cache \
      mariadb-client \
      coreutils \
      gzip \
      bzip2 \
      zstd \
 && mkdir -p /etc/crontabs \
 && echo '0	2	*	*	*	/usr/local/bin/backup >> /proc/1/fd/1 2>&1' > /etc/crontabs/root \
 && chmod 600 /etc/crontabs/root \
 && echo -e "[mariadb-client]\nssl=OFF"  > /etc/my.cnf.d/mariadb-client.cnf \
 && echo -e "[mariadb-dump]\nssl=OFF"    > /etc/my.cnf.d/mariadb-dump.cnf \

# Copy scripts from repo root 'app/' and make them executable
COPY --chmod=0755 app/entrypoint.sh /entrypoint.sh
COPY --chmod=0755 app/backup.sh     /usr/local/bin/backup
COPY --chmod=0755 app/restore.sh    /usr/local/bin/restore

VOLUME [ "/backups" ]

ENTRYPOINT [ "/entrypoint.sh" ]

