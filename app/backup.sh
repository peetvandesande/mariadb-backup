#!/bin/sh
# mariadb-backup: simple backups using mariadb-dump + selectable compression
set -eu
# ------------------------------------------------------------
# mariadb-backup :: backup.sh
# - Creates a datestamped MariaDB dump (.sql[.gz|.bz2|.zst]).
# - Busybox/Alpine/GNU userland friendly.
# - Booleans are 1/0 (VERIFY_SHA256, INCLUDE_GLOBALS).
# - chown/chmod apply automatically if CHOWN_UID/GID or CHMOD_MODE are provided.
# ------------------------------------------------------------
# Env vars:
#   MARIADB_USER        (required)
#   MARIADB_PASSWORD    (required)
#   MARIADB_DATABSE     (default=__ALL__)
#   MARIADB_HOST        (default=db)
#   MARIADB_PORT        (default=3306)
#
#   BACKUPS_DIR          (default=/backups)
#   BACKUP_NAME_PREFIX   (default: mariadb)
#
#   COMPRESSOR           (default=zst) one of: gz | bz2 | zst | none
#   COMPRESSOR_LEVEL     (optional) e.g. 1..9 for gz/bz2, 1..22 for zstd
#   ZSTD_THREADS	 (default=1)
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
: "${MARIADB_HOST:=db}"
: "${MARIADB_PORT:=3306}"
: "${MARIADB_USER:?MARIADB_USER is required}"
: "${MARIADB_PASSWORD:=}"
: "${MARIADB_DATABASE:=__ALL__}"   # __ALL__ = all databases; or space/comma-separated list

: "${BACKUPS_DIR:=/backups}"
: "${BACKUP_PREFIX:=mariadb}"
: "${VERIFY_SHA256:=1}"   # 1/0

# Optional ownership/permissions for new files:
: "${CHOWN_UID:=}"
: "${CHOWN_GID:=}"
: "${CHMOD_MODE:=}"

: "${DATE_FMT:=%Y%m%d}"

: "${COMPRESSOR:=zst}"            # zst|gz|bz2|none

# ---- validate ---------------------------------------------------------------
mkdir -p "$BACKUPS_DIR"

COMMON_ARGS="--host=${MARIADB_HOST} --port=${MARIADB_PORT} --user=${MARIADB_USER} \
  --single-transaction --quick --routines --triggers --events --default-character-set=utf8mb4"

# Prefer passing password via env to avoid showing it in process list
if [ -n "${MARIADB_PASSWORD}" ]; then
  export MYSQL_PWD="${MARIADB_PASSWORD}"
fi

# ---- filename ---------------------------------------------------------------
TS="$(date -u +"$DATE_FMT")"
case "${COMPRESSOR}" in
  zst)
    EXT=".sql.zst"
    : "${COMPRESSOR_LEVEL:=19}"
    : "${ZSTD_THREADS:=1}"
    COMP_CMD="zstd -T${ZSTD_THREADS} -q -f -${COMPRESSOR_LEVEL} -"
    ;;
  gz)
    EXT=".sql.gz"
    : "${COMPRESSOR_LEVEL:=9}"
    COMP_CMD="gzip -c -f -${COMPRESSOR_LEVEL}"
    ;;
  bz2)
    EXT=".sql.bz2"
    : "${COMPRESSOR_LEVEL:=9}"
    COMP_CMD="bzip2 -c -f -${COMPRESSOR_LEVEL}"
    ;;
  none)
    EXT=".sql"
    COMP_CMD="cat"
    ;;
  *)
    echo "Unsupported COMPRESSOR='${COMPRESSOR}'. Use: zstd|gzip|bzip2|none" >&2
    exit 64
    ;;
esac


# Determine database list
DB_MODE="--all-databases"
FILENAME_DB_PART="all-databases"
# Convert commas to spaces for convenience
DBS="$(printf "%s" "${MARIADB_DATABASE}" | tr ',' ' ')"
if [ -n "${DBS}" ] && [ "${DBS}" != "__ALL__" ] && [ "${DBS}" != "ALL" ]; then
  DB_MODE="--databases ${DBS}"
  # For filename, replace spaces with '+' to keep it readable
  FILENAME_DB_PART="$(printf "%s" "${DBS}" | tr ' ' '+' )"
fi

OUT_BASENAME="${BACKUP_PREFIX}-${FILENAME_DB_PART}-${TS}${EXT}"
OUT_PATH="${BACKUPS_DIR%/}/${OUT_BASENAME}"
SHA="${OUT_PATH}.sha256"

log "Starting MariaDB backup → ${OUT_PATH}"
log "Host=${MARIADB_HOST}:${MARIADB_PORT} DB=${FILENAME_DB_PART} compressor=${COMPRESSOR}"

# -------- Perform dump → compressor ------------------------------------------
# Dump to stdout, compress with chosen compressor streaming to file
set +e
log "DEBUG: Command = '/usr/bin/mariadb-dump ${COMMON_ARGS} ${DB_MODE} | ${COMPRESSOR}'"

# Run pipeline with proper variable expansion and pipefail where available
set +e
(
  set -o pipefail 2>/dev/null || true
  case "${COMPRESSOR}" in
    zst)
      /usr/bin/mariadb-dump ${COMMON_ARGS} ${DB_MODE} | zstd -T"${ZSTD_THREADS}" -q -f -"${COMPRESSOR_LEVEL}" - > "${OUT_PATH}"
      ;;
    gz)
      /usr/bin/mariadb-dump ${COMMON_ARGS} ${DB_MODE} | gzip -c -f -"${COMPRESSOR_LEVEL}" > "${OUT_PATH}"
      ;;
    bz2)
      /usr/bin/mariadb-dump ${COMMON_ARGS} ${DB_MODE} | bzip2 -c -f -"${COMPRESSOR_LEVEL}" > "${OUT_PATH}"
      ;;
    none)
      /usr/bin/mariadb-dump ${COMMON_ARGS} ${DB_MODE} > "${OUT_PATH}"
      ;;
    *)
      echo "Unsupported COMPRESSOR='${COMPRESSOR}'" >&2; exit 64;;
  esac
)
rc=$?
set -e


if [ $rc -ne 0 ]; then
  log "Backup FAILED with exit code ${rc}"
  exit $rc
fi

SIZE="$(du -h "$OUT_PATH" | awk '{print $1}')"
log "Dump written: $OUT_PATH ($SIZE)"

# ---- checksum ---------------------------------------------------------------
if [ "$VERIFY_SHA256" = "1" ]; then
  sha256sum "$OUT_PATH" > "$SHA"
  log "Wrote checksum file: $SHA"
fi

# ---- post-processing: chown/chmod -------------------------------------------
if [ -n "$CHOWN_UID" ] || [ -n "$CHOWN_GID" ]; then
  target_uid="${CHOWN_UID:-}"
  target_gid="${CHOWN_GID:-}"
  if [ -z "$target_uid" ] && [ -n "$target_gid" ]; then
    target_uid="$(id -u)"
  elif [ -n "$target_uid" ] && [ -z "$target_gid" ]; then
    target_gid="$(id -g)"
  fi

  if [ -n "$target_uid" ] && [ -n "$target_gid" ]; then
    chown "$target_uid:$target_gid" "$OUT_PATH" 2>/dev/null || true
    [ -f "$SHA" ] && chown "$target_uid:$target_gid" "$SHA" 2>/dev/null || true
    log "Set ownership to ${target_uid}:${target_gid}"
  fi
fi

if [ -n "${CHMOD_MODE:-}" ]; then
  chmod "$CHMOD_MODE" "$OUT_PATH" 2>/dev/null || true
  [ -f "$SHA" ] && chmod "$CHMOD_MODE" "$SHA" 2>/dev/null || true
  log "Set permissions to ${CHMOD_MODE}"
fi

log "MariaDB backup completed successfully."
