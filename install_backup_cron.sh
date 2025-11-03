#!/usr/bin/env bash
# Install (or update) a cron entry to run the DB backup script daily at 03:00
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BACKUP_SCRIPT="$SCRIPT_DIR/backup_db.sh"

if [[ ! -x "$BACKUP_SCRIPT" ]]; then
  echo "Making script executable: $BACKUP_SCRIPT"
  chmod +x "$BACKUP_SCRIPT"
fi

# Optional first arg: repo dir to export as BACKUP_REPO_DIR
REPO_ARG="${1:-}"

# Determine a stable absolute path for cron
ABS_PATH="$BACKUP_SCRIPT"

# Choose log path: if repo arg is provided, log inside it; else default near /home/www
if [[ -n "$REPO_ARG" ]]; then
  LOG_FILE="$REPO_ARG/backup_cron.log"
else
  # fallback: assume repo one level up at /home and log under /home/www
  REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
  LOG_FILE="$REPO_ROOT/www/backup_cron.log"
fi

# Build cron line with optional BACKUP_REPO_DIR env
if [[ -n "$REPO_ARG" ]]; then
  CRON_LINE="0 3 * * * BACKUP_REPO_DIR=\"$REPO_ARG\" /bin/bash \"$ABS_PATH\" >> \"$LOG_FILE\" 2>&1"
else
  CRON_LINE="0 3 * * * /bin/bash \"$ABS_PATH\" >> \"$LOG_FILE\" 2>&1"
fi

# Install or update crontab entry idempotently (remove previous entries for this script path)
( crontab -l 2>/dev/null | grep -v "$ABS_PATH" || true; echo "$CRON_LINE" ) | crontab -

echo "Cron installed. Current crontab:"
crontab -l
