#!/bin/sh
set -eu
# ------------------------------------------------------------
# mariadb-backup :: restore
# - Restores a MariaDB dump (.sql[.gz|.bz2|.zst]) into a target DB.
# ------------------------------------------------------------
# Usage:
#   restore [<dump_file_or_dir>] [<dbname>]
#     - If <dump_file_or_dir> is a directory or empty, selects newest .sql*
#       by BACKUP_NAME_PREFIX.
#
# Env vars:
#   MARIADB_USER        (required)
#   MARIADB_PASSWORD    (default: $MYSQLPW)
#   MARIADB_DB          (default: same as provided arg or env)
#   MARIADB_HOST        (default=db)
#   MARIADB_PORT        (default=3306)
#
#   BACKUPS_DIR          (default=/backups)
#   BACKUP_NAME_PREFIX   (optional, default=$MARIADB_DB-mariadb)
#
# ------------------------------------------------------------

log() { printf "%s %s\n" "$(date -Is)" "$*"; }

: "${MARIADB_HOST:=db}"
: "${MARIADB_PORT:=3306}"
: "${MARIADB_USER:?MARIADB_USER is required}"
: "${MARIADB_PASSWORD:=}"
: "${MARIADB_DATABASE:=}"  # Optional: if the dump did not include CREATE DATABASE, you can set one here
: "${BACKUP_DIR:=/backups}"
: "${BACKUP_PREFIX:=mariadb}"

# ---- locate dump ------------------------------------------------------------
DUMP_PATH="${1:-}"           # optional: file or directory

if [ -z "$DUMP_PATH" ] || [ -d "$DUMP_PATH" ]; then
  search_dir="${DUMP_PATH:-$BACKUP_DIR}"
  log "Scanning for newest archive in: $search_dir"
  if [ -n "$PREFIX" ]; then
    newest="$(ls -1t "$search_dir"/"$PREFIX-"*.sql* 2>/dev/null | head -n1 || true)"
  else
    newest="$(ls -1t "$search_dir"/*.sql* 2>/dev/null | head -n1 || true)"
  fi
  DUMP_FILE="${newest:-}"
else
  DUMP_FILE="$DUMP_PATH"
fi

[ -n "${DUMP_FILE:-}" ] || { log "ERROR: No dump file found. Provide a path or ensure backups exist."; exit 1; }
[ -f "$DUMP_FILE" ] || { log "ERROR: Dump file does not exist: $DUMP_FILE"; exit 1; }

log "Selected dump: $DUMP_FILE"

# Password via env to avoid ps leaks
if [ -n "${MARIADB_PASSWORD}" ]; then
  export MYSQL_PWD="${MARIADB_PASSWORD}"
fi

# ---- checksum ---------------------------------------------------------------
SHA="${DUMP_FILE}.sha256"
if [ -f "$SHA" ]; then
  log "Verifying checksum: $SHA"
  sha256sum -c "$SHA" >/dev/null
fi

# ---- decompressor -----------------------------------------------------------
case "${DUMP_FILE}" in
  *.sql.gz)  DECOMPRESSOR="zcat" ;;
  *.sql.bz2) DECOMPRESSOR="bzcat" ;;
  *.sql.zst) DECOMPRESSOR="zstd -d -q -c" ;;
  *.sql)     DECOMPRESSOR="cat" ;;
  *)
    log "ERROR: Unknown dump file extension: $DUMP_FILE"
    exit 65
    ;;
esac

# ---- restore ---------------------------------------------------------------
# If MARIADB_DATABASE is provided, create it and set default db for the session.
DB_ARGS=""
if [ -n "${MARIADB_DATABASE}" ]; then
  log "Ensuring database '${MARIADB_DATABASE}' exists"
  /usr/bin/mariadb --host="${MARIADB_HOST}" --port="${MARIADB_PORT}" --user="${MARIADB_USER}" \
    -e "CREATE DATABASE IF NOT EXISTS \`${MARIADB_DATABASE}\` /*!40100 DEFAULT CHARACTER SET utf8mb4 */;"
  DB_ARGS="${MARIADB_DATABASE}"
fi

log "Restoring ${DUMP_FILE} → ${MARIADB_HOST}:${MARIADB_PORT}/${MARIADB_DATABASE:-(as in dump)}"

TMP_LOG="$(mktemp /tmp/mariadb-restore-XXXXXX.log)"

set +e
sh -c '${DECOMPRESSOR} "${DUMP_FILE}"' | /usr/bin/mariadb --host="${MARIADB_HOST}" --port="${MARIADB_PORT}" --user="${MARIADB_USER}" ${DB_ARGS:+"${DB_ARGS}"} >/tmp/mariadb-restore.log 2>&1
rc=$?
set -e

if [ $rc -ne 0 ]; then
  log "mariadb reported errors during restore:"
  sed 's/^/mysql: /' "$TMP_LOG" >&2 || true
  log "Restore FAILED with exit code ${rc}"
fi

rm -f "$TMP_LOG"

if [ $rc -ne 0 ]; then
  exit $rc
fi

log "Restore completed successfully."
