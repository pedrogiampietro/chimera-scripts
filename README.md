# Backup automation

This folder contains a simple daily backup system for the MySQL database used by the web app (Prisma).

What it does:
- Reads `DATABASE_URL` from `www/.env` (format: `mysql://user:pass@host:port/db`).
- Dumps the database with `mysqldump` into `www/backup_chimera.sql`.
- Commits and pushes the updated backup file to the current git branch (if it changed).
- Logs to `www/backup_cron.log`.

## Files
- `backup_db.sh` — main backup script. Safe to run manually or via cron.
- `install_backup_cron.sh` — installs a cron entry to run the backup daily at 03:00.

## Requirements
- `mysql-client` (provides `mysqldump`)
- `git` with credentials set up (SSH or PAT) so `git push` works non-interactively
- Valid `DATABASE_URL` in `www/.env`

## Usage

Manual test (no DB access, no git push):

```bash
bash scripts/backup_db.sh --print-config
bash scripts/backup_db.sh --dry-run
```

Run a real backup once:

```bash
bash scripts/backup_db.sh
```

Install cron for daily backups at 03:00:

```bash
bash scripts/install_backup_cron.sh
```

Notes:
- If the backup file content didn't change, no commit/push is made.
- Passwords in `DATABASE_URL` may be URL-encoded; the script decodes them automatically.
- If your default branch is not `master`, the script pushes to whatever branch is currently checked out.

### Repo location override

By default the script assumes the repo root is the parent of `scripts/`. If your backup runs from a different path, set:

```bash
export BACKUP_REPO_DIR=/path/to/your/git/repo
bash scripts/backup_db.sh
```

The script will also attempt to auto-detect the nearest git repository by walking up the directory tree.
