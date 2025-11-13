#!/bin/sh
set -eu
# ------------------------------------------------------------
# mariadb-backup :: restore.sh
# - Restores a MariaDB dump (.sql[.gz|.bz2|.zst]).
# - Busybox/Alpine/GNU userland friendly.
# - Booleans are 1/0 (VERIFY_SHA256).
# ------------------------------------------------------------
# Env vars:
#   MARIADB_USER         (required)
#   MARIADB_PASSWORD     (required)
#   MARIADB_DATABASE     (optional target DB)
#   MARIADB_HOST         (default=db)
#   MARIADB_PORT         (default=3306)
#
#   BACKUPS_DIR          (default=/backups)
#   BACKUP_NAME_PREFIX   (optional)
#
#   VERIFY_SHA256        (default=1)  1=verify against .sha256 next to dump
#
#   DATE_FMT             (default=%Y%m%d) UTC date for filename
# ------------------------------------------------------------

log() { printf "%s %s\n" "$(date -Is)" "$*"; }

# ---- inputs / defaults ------------------------------------------------------
: "${MARIADB_USER:?MARIADB_USER is required}"
: "${MARIADB_PASSWORD:=}"
: "${MARIADB_DATABASE:=}"
: "${MARIADB_HOST:=db}"
: "${MARIADB_PORT:=3306}"

: "${BACKUPS_DIR:=/backups}"
: "${BACKUP_NAME_PREFIX:=}"
: "${DATE_FMT:=%Y%m%d}"

# Optional behavior
: "${VERIFY_SHA256:=1}"

# ---------------- Pick input ----------------
INPUT="${1:-}"
if [ -z "${INPUT}" ]; then
  log "Scanning for newest archive in: ${BACKUPS_DIR}"
  # Look for newest matching real dump files, ignore .sha256
  CANDIDATE="$( (ls -1t "${BACKUPS_DIR%/}/${BACKUP_NAME_PREFIX}"*.sql      2>/dev/null; \
                  ls -1t "${BACKUPS_DIR%/}/${BACKUP_NAME_PREFIX}"*.sql.zst 2>/dev/null; \
                  ls -1t "${BACKUPS_DIR%/}/${BACKUP_NAME_PREFIX}"*.sql.gz  2>/dev/null; \
                  ls -1t "${BACKUPS_DIR%/}/${BACKUP_NAME_PREFIX}"*.sql.bz2 2>/dev/null) | head -n1 )"
  if [ -z "${CANDIDATE}" ]; then
    echo "No dump found in ${BACKUPS_DIR} with BACKUP_NAME_PREFIX='${BACKUP_NAME_PREFIX}'" >&2
    exit 64
  fi
  INPUT="${CANDIDATE}"
fi

if [ ! -f "${INPUT}" ]; then
  echo "Input file not found: ${INPUT}" >&2
  exit 66
fi

log "Selected dump: ${INPUT}"

# Optional 2nd arg overrides target DB
if [ -n "${2:-}" ]; then
  MARIADB_DATABASE="$2"
fi

# ---------------- Verify checksum (optional) --------------
if [ "${VERIFY_SHA256}" = "1" ] && [ -f "${INPUT}.sha256" ]; then
  log "Verifying checksum: ${INPUT}.sha256"
  ( sha256sum -c "${INPUT}.sha256" )
fi

# ---------------- Decide decompressor ---------------------
EXT="${INPUT##*.}"
DECOMP=""
case "${INPUT}" in
  *.sql)     DECOMP="cat" ;;
  *.sql.zst) DECOMP="zstd -d -q -c" ;;
  *.sql.gz)  DECOMP="gzip -dc" ;;
  *.sql.bz2) DECOMP="bzip2 -dc" ;;
  *)
    echo "Unsupported file extension for ${INPUT}; expected .sql[.zst|.gz|.bz2]" >&2
    exit 65
    ;;
esac

# Avoid password in ps
[ -n "${MARIADB_PASSWORD}" ] && export MYSQL_PWD="${MARIADB_PASSWORD}"

# ---------------- Ensure DB exists (optional) -------------
DB_ARGS=""
if [ -n "${MARIADB_DATABASE}" ]; then
  log "Ensuring database '${MARIADB_DATABASE}' exists"
  /usr/bin/mariadb --host="${MARIADB_HOST}" --port="${MARIADB_PORT}" \
    --user="${MARIADB_USER}" \
    -e "CREATE DATABASE IF NOT EXISTS \`${MARIADB_DATABASE}\` /*!40100 DEFAULT CHARACTER SET utf8mb4 */;"
  DB_ARGS="${MARIADB_DATABASE}"
fi

log "Restoring ${INPUT} → ${MARIADB_HOST}:${MARIADB_PORT}/${MARIADB_DATABASE:-(as in dump)}"

# ---------------- Run restore with pipefail ---------------
TMP_LOG="/tmp/mariadb-restore.log"
set +e
(
  set -o pipefail 2>/dev/null || true
#   case "${DECOMP}" in
#     cat)             cat "${INPUT}" ;;
#     "zstd -d -q -c") zstd -d -q -c "${INPUT}" ;;
#     "gzip -dc")      gzip -dc "${INPUT}" ;;
#     "bzip2 -dc")     bzip2 -dc "${INPUT}" ;;
#     *) echo "Internal error: bad DECOMP '${DECOMP}'" >&2; exit 70 ;;
#   esac | /usr/bin/mariadb --host="${MARIADB_HOST}" --port="${MARIADB_PORT}" \
  ${DECOMP} "${INPUT}" \
  | /usr/bin/mariadb --host="${MARIADB_HOST}" --port="${MARIADB_PORT}" \
         --user="${MARIADB_USER}" ${DB_ARGS:+${DB_ARGS}}
) > "${TMP_LOG}" 2>&1
rc=$?
set -e

if [ $rc -ne 0 ]; then
  log "mariadb reported errors during restore:"
  sed 's/^/mysql: /' "$TMP_LOG" >&2 || true
  log "Restore FAILED with exit code ${rc}"
  rm -f "$TMP_LOG"
  exit $rc
fi

rm -f "$TMP_LOG"
log "MariaDB restore completed successfully."
