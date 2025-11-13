#!/bin/sh
set -eu
# ------------------------------------------------------------
# mariadb-backup :: backup.sh
# - Creates a timestamped MariaDB dump (.sql[.gz|.bz2|.zst]).
# - Busybox/Alpine/GNU userland friendly.
# - Booleans are 1/0 (VERIFY_SHA256).
# - chown/chmod apply automatically if CHOWN_UID/GID or CHMOD_MODE are provided.
# ------------------------------------------------------------
# Env vars:
#   MARIADB_USER         (required)
#   MARIADB_PASSWORD     (required)
#   MARIADB_DATABASE     (default=__ALL__)
#   MARIADB_HOST         (default=db)
#   MARIADB_PORT         (default=3306)
#
#   BACKUPS_DIR          (default=/backups)
#   BACKUP_NAME_PREFIX   (optional)
#
#   COMPRESS             (default=gz) one of: gz | bz2 | zst | none
#   COMPRESS_LEVEL       (optional) e.g. 1..9 for gz/bz2, 1..22 for zstd
#   VERIFY_SHA256        (default=1)  1=write .sha256 next to dump
#
#   CHOWN_UID            (optional) numeric uid or name
#   CHOWN_GID            (optional) numeric gid or name
#   CHMOD_MODE           (optional) e.g., 0640
#
#   DATE_FMT             (default=%Y%m%d) UTC date for filename
# ------------------------------------------------------------

log() { printf "%s %s\n" "$(date -Is)" "$*"; }

# ---- inputs / defaults ------------------------------------------------------
: "${MARIADB_USER:?MARIADB_USER is required}"
: "${MARIADB_PASSWORD:=}"
: "${MARIADB_DATABASE:=__ALL__}"     # __ALL__ or space/comma list of DBs
: "${MARIADB_HOST:=db}"
: "${MARIADB_PORT:=3306}"

: "${BACKUPS_DIR:=/backups}"
: "${BACKUP_NAME_PREFIX:=}"
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

# ---- filename ---------------------------------------------------------------
TS="$(date -u +"${DATE_FMT}")"
case "${COMPRESSOR}" in
  gz)
    EXT=".sql.gz"
    CMD_COMPRESS="gzip -c -f -\"${COMPRESSOR_LEVEL}\""
    ;;
  bz2)
    EXT=".sql.bz2"
    CMD_COMPRESS="bzip2 -c -f -\"${COMPRESSOR_LEVEL}\""
    ;;
  zst)
    EXT=".sql.zst"
    CMD_COMPRESS="zstd -T\"${ZSTD_THREADS}\" -q -f -\"${COMPRESSOR_LEVEL}\" -"
    ;;
  none)
    EXT=".sql"
    CMD_COMPRESS="cat"
    ;;
  *)    echo "Unsupported COMPRESSOR='${COMPRESSOR}' (use zst|gz|bz2|none)" >&2; exit 64 ;;
esac

OUT_BASENAME="${BACKUP_NAME_PREFIX}${FILENAME_DB_PART}-mariadb-${TS}${EXT}"
OUT="${BACKUPS_DIR%/}/${OUT_BASENAME}"
SHA="${OUT}.sha256"

log "Starting MariaDB backup → ${OUT}"
log "Host=${MARIADB_HOST}:${MARIADB_PORT} DB=${FILENAME_DB_PART} compressor=${COMPRESSOR}"

# ---- dump command -----------------------------------------------------------
# Avoid password in ps
[ -n "${MARIADB_PASSWORD}" ] && export MYSQL_PWD="${MARIADB_PASSWORD}"

# Build dump arguments
COMMON_ARGS="--host=${MARIADB_HOST} --port=${MARIADB_PORT} --user=${MARIADB_USER} \
  --single-transaction --quick --routines --triggers --events --default-character-set=utf8mb4"

# ---------------- Dump → compress --------------------------------------------
set +e
(
  set -o pipefail 2>/dev/null || true
  mariadb-dump ${COMMON_ARGS} ${DB_MODE} \
    | $CMD_COMPRESS > "${OUT}"
#   case "${COMPRESSOR}" in
#     zst)
#       /usr/bin/mariadb-dump ${COMMON_ARGS} ${DB_MODE} \
#         | zstd -T"${ZSTD_THREADS}" -q -f -"${COMPRESSOR_LEVEL}" - > "${OUT}"
#       ;;
#     gz)
#       /usr/bin/mariadb-dump ${COMMON_ARGS} ${DB_MODE} \
#         | gzip -c -f -"${COMPRESSOR_LEVEL}" > "${OUT}"
#       ;;
#     bz2)
#       /usr/bin/mariadb-dump ${COMMON_ARGS} ${DB_MODE} \
#         | bzip2 -c -f -"${COMPRESSOR_LEVEL}" > "${OUT}"
#       ;;
#     none)
#       /usr/bin/mariadb-dump ${COMMON_ARGS} ${DB_MODE} \
#         > "${OUT}"
#       ;;
#   esac
)
rc=$?
set -e

if [ $rc -ne 0 ]; then
  log "Backup FAILED with exit code ${rc}"
  [ -s "${OUT}" ] || rm -f "${OUT}" 2>/dev/null || true
  exit $rc
fi

# Sanity: non-empty file
if [ ! -s "${OUT}" ]; then
  log "Backup FAILED: produced empty file"
  rm -f "${OUT}" 2>/dev/null || true
  exit 1
fi

SIZE="$(du -h "${OUT}" | awk '{print $1}')"
log "Dump written: ${OUT} (${SIZE})"

# ---- checksum ---------------------------------------------------------------
if [ "${VERIFY_SHA256}" = "1" ]; then
  sha256sum "${OUT}" > "${SHA}"
  log "Wrote checksum file: ${SHA}"
fi

# ---- post-processing: chown/chmod -------------------------------------------
if [ -n "${CHOWN_UID}" ] || [ -n "${CHOWN_GID}" ]; then
  target_uid="${CHOWN_UID:-}"
  target_gid="${CHOWN_GID:-}"
  if [ -z "${target_uid}" ] && [ -n "${target_gid}" ]; then
    target_uid="$(id -u)"
  elif [ -n "${target_uid}" ] && [ -z "${target_gid}" ]; then
    target_gid="$(id -g)"
  fi

  if [ -n "${target_uid}" ] && [ -n "${target_gid}" ]; then
    chown "${target_uid}:${target_gid}" "${OUT}" 2>/dev/null || true
    [ -f "${SHA}" ] && chown "${target_uid}:${target_gid}" "${SHA}" 2>/dev/null || true
    log "Set ownership to ${target_uid}:${target_gid}"
  fi
fi

if [ -n "${CHMOD_MODE}" ]; then
  chmod "${CHMOD_MODE}" "${OUT}" 2>/dev/null || true
  [ -f "${SHA}" ] && chmod "${CHMOD_MODE}" "${SHA}" 2>/dev/null || true
  log "Set permissions to ${CHMOD_MODE}"
fi

log "MariaDB backup completed successfully."
