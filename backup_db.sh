#!/usr/bin/env bash
# Automatic daily MySQL backup -> www/backup_chimera.sql, commit and push
# Reads DATABASE_URL from www/.env (Prisma format: mysql://user:pass@host:port/db)

set -Eeuo pipefail

# --- utils ---
log() { printf "[%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
err() { printf "[%s] ERROR: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }

# URL decode function (pure bash)
urldecode() {
  local data="$1"
  data="${data//+/ }"
  printf '%b' "${data//%/\\x}"
}

# Determine repo root based on this script's location (with overrides)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# If BACKUP_REPO_DIR is set, prefer it; otherwise try to find a git root upwards; fallback to parent of scripts
if [[ -n "${BACKUP_REPO_DIR:-}" ]]; then
  REPO_ROOT="$BACKUP_REPO_DIR"
else
  CANDIDATE="$(cd "$SCRIPT_DIR/.." && pwd)"
  if git -C "$CANDIDATE" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    REPO_ROOT="$(cd "$CANDIDATE" && git rev-parse --show-toplevel 2>/dev/null || echo "$CANDIDATE")"
  else
    # walk up until we find a git repo or hit root
    SEARCH_DIR="$CANDIDATE"
    FOUND=""
    while [[ "$SEARCH_DIR" != "/" ]]; do
      if git -C "$SEARCH_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        FOUND="$(cd "$SEARCH_DIR" && git rev-parse --show-toplevel 2>/dev/null || echo "$SEARCH_DIR")"
        break
      fi
      SEARCH_DIR="$(dirname "$SEARCH_DIR")"
    done
    REPO_ROOT="${FOUND:-$CANDIDATE}"
  fi
fi

# Determine where the web app root is (where .env lives)
if [[ -f "$REPO_ROOT/.env" && -d "$REPO_ROOT/prisma" ]]; then
  WWW_DIR="$REPO_ROOT"
else
  WWW_DIR="$REPO_ROOT/www"
fi

ENV_FILE="$WWW_DIR/.env"
BACKUP_FILE="$WWW_DIR/backup_chimera.sql"
LOG_FILE="$WWW_DIR/backup_cron.log"

# Support flags
DRY_RUN="false"
PRINT_CONFIG="false"
while [[ ${1:-} ]]; do
  case "$1" in
    --dry-run) DRY_RUN="true" ;;
    --print-config) PRINT_CONFIG="true" ;;
    *) err "Unknown arg: $1"; exit 2 ;;
  esac
  shift
done

# Ensure prerequisites
if ! command -v mysqldump >/dev/null 2>&1; then
  err "mysqldump not found. Install mysql-client (e.g., apt-get install mysql-client)."
  exit 1
fi
if ! command -v git >/dev/null 2>&1; then
  err "git not found. Install git."
  exit 1
fi

# Read DATABASE_URL from .env
if [[ ! -f "$ENV_FILE" ]]; then
  err "Env file not found at $ENV_FILE"
  exit 1
fi
DB_URL_LINE="$(grep -E '^DATABASE_URL=' "$ENV_FILE" | tail -n1 || true)"
if [[ -z "$DB_URL_LINE" ]]; then
  err "DATABASE_URL not found in $ENV_FILE"
  exit 1
fi
DB_URL="${DB_URL_LINE#DATABASE_URL=}"
# Strip surrounding quotes if present
DB_URL="${DB_URL%\"}"
DB_URL="${DB_URL#\"}"

# Parse mysql://user:pass@host:port/db
if [[ "$DB_URL" != mysql://* ]]; then
  err "Only MySQL URLs are supported. Got: $DB_URL"
  exit 1
fi

# Remove scheme
URL_NO_SCHEME="${DB_URL#mysql://}"
# Split userinfo and host/db
USERINFO="${URL_NO_SCHEME%@*}"
HOSTDB="${URL_NO_SCHEME#*@}"
USER="${USERINFO%%:*}"
PASS_ENC="${USERINFO#*:}"
HOSTPORT="${HOSTDB%%/*}"
DB_NAME="${HOSTDB#*/}"
HOST="${HOSTPORT%%:*}"
PORT="${HOSTPORT#*:}"
if [[ "$HOSTPORT" == "$HOST" ]]; then PORT="3306"; fi

# URL-decode password
PASS="$(urldecode "$PASS_ENC")"

if [[ "$PRINT_CONFIG" == "true" ]]; then
  echo "REPO_ROOT=$REPO_ROOT"
  echo "ENV_FILE=$ENV_FILE"
  echo "DB_USER=$USER"
  echo "DB_PASS=(hidden ${#PASS} chars)"
  echo "DB_HOST=$HOST"
  echo "DB_PORT=$PORT"
  echo "DB_NAME=$DB_NAME"
  echo "BACKUP_FILE=$BACKUP_FILE"
  exit 0
fi

# Ensure www dir exists
mkdir -p "$WWW_DIR"
# Start logging
{
  log "Starting database backup"
  log "Repo root: $REPO_ROOT"
  log "Writing backup to: $BACKUP_FILE"

  # Create a temporary file to write dump first
  TMP_DUMP="$(mktemp "$WWW_DIR/.backup_chimera.sql.XXXXXX")"
  trap 'rm -f "$TMP_DUMP"' EXIT

  # Perform dump (non-locking snapshot for InnoDB)
  log "Running mysqldump..."
  if [[ "$DRY_RUN" == "true" ]]; then
    log "DRY RUN: Skipping mysqldump"
    echo "-- dry-run backup for $DB_NAME at $(date -u +%FT%TZ)" > "$TMP_DUMP"
  else
    MYSQL_PWD="$PASS" mysqldump \
      --host="$HOST" --port="$PORT" --user="$USER" \
      --single-transaction --quick --hex-blob \
      --routines --triggers --events \
      "$DB_NAME" > "$TMP_DUMP"
  fi
  log "mysqldump finished"

  # Replace the target file atomically
  mv -f "$TMP_DUMP" "$BACKUP_FILE"
  sync
  log "Backup file updated"

  # Git commit and push if changed
  cd "$REPO_ROOT"
  # Make sure remote is reachable and branch known; optional pull to avoid diverge
  if [[ "$DRY_RUN" == "true" ]]; then
    log "DRY RUN: Skipping git pull/commit/push"
  else
    if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      # Optional: update from remote if configured
      if git remote get-url origin >/dev/null 2>&1; then
        log "Fetching latest changes"
        git fetch origin || log "Warning: git fetch failed (continuing)"
        CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
        if [[ -n "$CURRENT_BRANCH" ]]; then
          git pull --rebase origin "$CURRENT_BRANCH" || log "Warning: git pull --rebase failed (continuing)"
        fi
      fi

      # Stage only the backup file
      git add "$BACKUP_FILE"
      if git diff --cached --quiet -- "$BACKUP_FILE"; then
        log "No changes to commit"
      else
        COMMIT_MSG="chore(backup): update daily DB backup $(date '+%Y-%m-%d %H:%M:%S %Z')"
        # Commit with fallback identity so it doesn't fail on fresh servers
        if ! git -c user.name="Backup Bot" -c user.email="backup@localhost" commit -m "$COMMIT_MSG"; then
          log "git commit failed (missing identity or other issue); skipping push"
          exit 0
        fi
        # Push to the same branch
        if git remote get-url origin >/dev/null 2>&1; then
          log "Pushing commit to origin"
          git push origin "$(git rev-parse --abbrev-ref HEAD)" || log "Warning: git push failed (will retry on next run)"
        else
          log "No git remote 'origin' configured; skipping push"
        fi
      fi
    else
      log "Not a git repository at $REPO_ROOT; skipping commit/push"
    fi
  fi

  log "Backup routine completed"
} >>"$LOG_FILE" 2>&1
