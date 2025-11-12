#!/bin/sh
# mariadb-backup :: backup.sh
# Controlled environment: hardcoded /usr/bin/mariadb-dump, selectable compression.
# Produces: <BACKUP_PREFIX>-<dbpart>-<DATE>.sql[.zst|.gz|.bz2]
set -eu

# ---------------- Env ----------------
: "${MARIADB_HOST:=db}"
: "${MARIADB_PORT:=3306}"
: "${MARIADB_USER:?MARIADB_USER is required}"
: "${MARIADB_PASSWORD:=}"
: "${MARIADB_DATABASE:=__ALL__}"     # __ALL__ or space/comma list of DBs

: "${BACKUPS_DIR:=/backups}"
: "${BACKUP_PREFIX:=mariadb}"
: "${DATE_FMT:=%Y%m%d}"              # UTC date in filename

# Compression (pg-backup style)
: "${COMPRESSOR:=zst}"               # zst|gz|bz2|none
: "${COMPRESSOR_LEVEL:=19}"          # zstd: 1..22; gzip/bzip2: 1..9
: "${ZSTD_THREADS:=1}"               # 0=auto, else N threads

# Optional behavior
: "${VERIFY_SHA256:=1}"              # 1=write checksum
: "${CHOWN_UID:=}"
: "${CHOWN_GID:=}"
: "${CHMOD_MODE:=}"

log() { printf "%s %s\n" "$(date -Is)" "$*"; }

# ---------------- Prep ----------------
mkdir -p "${BACKUPS_DIR}"

# Build dump arguments
COMMON_ARGS="--host=${MARIADB_HOST} --port=${MARIADB_PORT} --user=${MARIADB_USER} \
  --single-transaction --quick --routines --triggers --events --default-character-set=utf8mb4"

# Avoid password in ps
[ -n "${MARIADB_PASSWORD}" ] && export MYSQL_PWD="${MARIADB_PASSWORD}"

# DB selection
DB_MODE="--all-databases"
FILENAME_DB_PART="all-databases"
DBS="$(printf "%s" "${MARIADB_DATABASE}" | tr ',' ' ')"
if [ -n "${DBS}" ] && [ "${DBS}" != "__ALL__" ] && [ "${DBS}" != "ALL" ]; then
  DB_MODE="--databases ${DBS}"
  FILENAME_DB_PART="$(printf "%s" "${DBS}" | tr ' ' '+' )"
fi

# Filename
TS="$(date -u +"${DATE_FMT}")"
case "${COMPRESSOR}" in
  zst)  EXT=".sql.zst" ;;
  gz)   EXT=".sql.gz"  ;;
  bz2)  EXT=".sql.bz2" ;;
  none) EXT=".sql"     ;;
  *)    echo "Unsupported COMPRESSOR='${COMPRESSOR}' (use zst|gz|bz2|none)" >&2; exit 64 ;;
esac

OUT_BASENAME="${BACKUP_PREFIX}-${FILENAME_DB_PART}-${TS}${EXT}"
OUT_PATH="${BACKUPS_DIR%/}/${OUT_BASENAME}"
SHA="${OUT_PATH}.sha256"

log "Starting MariaDB backup → ${OUT_PATH}"
log "Host=${MARIADB_HOST}:${MARIADB_PORT} DB=${FILENAME_DB_PART} compressor=${COMPRESSOR}"

# ---------------- Dump → compress ----------------
# Show a precise debug line
case "${COMPRESSOR}" in
  zst)
    log "DEBUG: /usr/bin/mariadb-dump ${COMMON_ARGS} ${DB_MODE} --ssl-mode=${MARIADB_SSL_MODE} | zstd -T${ZSTD_THREADS} -q -f -${COMPRESSOR_LEVEL} - > ${OUT_PATH}"
    ;;
  gz)
    log "DEBUG: /usr/bin/mariadb-dump ${COMMON_ARGS} ${DB_MODE} --ssl-mode=${MARIADB_SSL_MODE} | gzip -c -f -${COMPRESSOR_LEVEL} > ${OUT_PATH}"
    ;;
  bz2)
    log "DEBUG: /usr/bin/mariadb-dump ${COMMON_ARGS} ${DB_MODE} --ssl-mode=${MARIADB_SSL_MODE} | bzip2 -c -f -${COMPRESSOR_LEVEL} > ${OUT_PATH}"
    ;;
  none)
    log "DEBUG: /usr/bin/mariadb-dump ${COMMON_ARGS} ${DB_MODE} --ssl-mode=${MARIADB_SSL_MODE} > ${OUT_PATH}"
    ;;
esac

set +e
(
  set -o pipefail 2>/dev/null || true
  case "${COMPRESSOR}" in
    zst)
      /usr/bin/mariadb-dump ${COMMON_ARGS} ${DB_MODE} \
        | zstd -T"${ZSTD_THREADS}" -q -f -"${COMPRESSOR_LEVEL}" - > "${OUT_PATH}"
      ;;
    gz)
      /usr/bin/mariadb-dump ${COMMON_ARGS} ${DB_MODE} \
        | gzip -c -f -"${COMPRESSOR_LEVEL}" > "${OUT_PATH}"
      ;;
    bz2)
      /usr/bin/mariadb-dump ${COMMON_ARGS} ${DB_MODE} \
        | bzip2 -c -f -"${COMPRESSOR_LEVEL}" > "${OUT_PATH}"
      ;;
    none)
      /usr/bin/mariadb-dump ${COMMON_ARGS} ${DB_MODE} \
        > "${OUT_PATH}"
      ;;
  esac
)
rc=$?
set -e

if [ $rc -ne 0 ]; then
  log "Backup FAILED with exit code ${rc}"
  [ -s "${OUT_PATH}" ] || rm -f "${OUT_PATH}" 2>/dev/null || true
  exit $rc
fi

# Sanity: non-empty file
if [ ! -s "${OUT_PATH}" ]; then
  log "Backup FAILED: produced empty file"
  rm -f "${OUT_PATH}" 2>/dev/null || true
  exit 1
fi

SIZE="$(du -h "${OUT_PATH}" | awk '{print $1}')"
log "Dump written: ${OUT_PATH} (${SIZE})"

# ---------------- Checksum & perms ----------------
if [ "${VERIFY_SHA256}" = "1" ]; then
  sha256sum "${OUT_PATH}" > "${SHA}"
  log "Wrote checksum file: ${SHA}"
fi

# Ownership/permissions (best-effort)
if [ -n "${CHOWN_UID}" ] || [ -n "${CHOWN_GID}" ]; then
  target_uid="${CHOWN_UID:-}"
  target_gid="${CHOWN_GID:-}"
  if [ -n "$target_uid" ] && [ -n "$target_gid" ]; then
    chown "$target_uid:$target_gid" "${OUT_PATH}" 2>/dev/null || true
    [ -f "${SHA}" ] && chown "$target_uid:$target_gid" "${SHA}" 2>/dev/null || true
    log "Set ownership to ${target_uid}:${target_gid}"
  fi
fi

if [ -n "${CHMOD_MODE}" ]; then
  chmod "${CHMOD_MODE}" "${OUT_PATH}" 2>/dev/null || true
  [ -f "${SHA}" ] && chmod "${CHMOD_MODE}" "${SHA}" 2>/dev/null || true
  log "Set permissions to ${CHMOD_MODE}"
fi

log "MariaDB backup completed successfully."
