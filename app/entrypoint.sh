#!/bin/sh
set -eu

# Ensure /usr/local/bin is on PATH so 'backup' / 'restore' work as subcommands
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

log() { printf "%s %s\n" "$(date -Is)" "$*"; }

# ---- Boolean envs (1/0) -----------------------------------------------------
RUN_ONCE="${RUN_ONCE:-0}"                   # 1 = run a single backup and exit
RUN_BACKUP_ON_START="${RUN_BACKUP_ON_START:-0}"  # 1 = do one backup, then start cron

# ---- Subcommands -------------------------------------------------------------
CMD="${1:-}"

case "$CMD" in
  restore)
    shift
    exec /usr/local/bin/restore "$@"
    ;;
  backup)
    shift
    exec /usr/local/bin/backup "$@"
    ;;
  "" )
    # fall through to default flow (optional RUN_ONCE / RUN_BACKUP_ON_START / crond)
    ;;
  *)
    # If a real command was passed, execute it verbatim (e.g., /bin/sh)
    exec "$@"
    ;;
esac

# ---- RUN_ONCE: do a single backup and exit ----------------------------------
if [ "$RUN_ONCE" = "1" ]; then
  log "RUN_ONCE=1 → performing single backup then exiting"
  if /usr/local/bin/backup; then
    log "Backup completed"
    exit 0
  else
    log "Backup FAILED"
    exit 1
  fi
fi

# ---- Optional: run a backup before cron starts ------------------------------
if [ "$RUN_BACKUP_ON_START" = "1" ]; then
  log "RUN_BACKUP_ON_START=1 → running initial backup before cron"
  if ! /usr/local/bin/backup; then
    log "Initial backup FAILED (continuing to cron)"
  else
    log "Initial backup completed"
  fi
fi

# ---- Default: start crond in foreground -------------------------------------
CROND_BIN="$(command -v crond)"
log "[entrypoint] Starting crond ($CROND_BIN)…"
exec "$CROND_BIN" -f -l 2 /dev/stdout
