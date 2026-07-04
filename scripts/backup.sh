#!/bin/bash
set -euo pipefail

source /home/arijit/cloud-infra/minio/.env

LOCAL_REPO=/mnt/data_4/restic-repo
REMOTE_REPO=rclone:gdrive:restic-repo
STAGING=/tmp/backup-staging
export RESTIC_PASSWORD

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# Dead-man's-switch: ping HEALTHCHECK_URL (from .env, e.g. https://hc-ping.com/<uuid>)
# on success, <url>/fail on failure. Unset = skip. Catches both script failures and
# the timer never firing.
finish() {
  status=$?
  rm -rf "$STAGING"
  if [ -n "${HEALTHCHECK_URL:-}" ]; then
    if [ "$status" -eq 0 ]; then
      curl -fsS -m 10 --retry 3 "$HEALTHCHECK_URL" >/dev/null || true
    else
      curl -fsS -m 10 --retry 3 "$HEALTHCHECK_URL/fail" >/dev/null || true
    fi
  fi
}
trap finish EXIT

log "=== Backup started ==="
mkdir -p "$STAGING"

# 1. Postgres logical dump
log "Dumping Postgres..."
docker exec postgres pg_dumpall -U "$POSTGRES_USER" | gzip > "$STAGING/postgres_full.sql.gz"
log "Postgres dump: $(du -sh --apparent-size "$STAGING/postgres_full.sql.gz" | cut -f1)"

# 2. Gitea consistent dump — the live SQLite copy inside gitea_data can be torn
# mid-write; this captures DB + config safely. Repos are skipped (bare git dirs
# snapshot fine and are already in the restic set below). Dump to a file and
# size-check it: a truncated zip here would only be noticed at restore time.
# (Size via stat/--apparent-size — plain du under-reports fresh files before
# ext4 writeback and once printed "1.0K" for a healthy 103K zip.)
log "Dumping Gitea..."
docker exec -u 1000 gitea sh -c \
  'rm -f /tmp/gitea-dump.zip && gitea dump --skip-repository --skip-log -c /data/gitea/conf/app.ini -f /tmp/gitea-dump.zip'
docker cp gitea:/tmp/gitea-dump.zip "$STAGING/gitea-dump.zip"
docker exec -u 1000 gitea rm -f /tmp/gitea-dump.zip
gitea_dump_bytes=$(stat -c%s "$STAGING/gitea-dump.zip")
if [ "$gitea_dump_bytes" -lt 65536 ]; then
  log "Gitea dump truncated (${gitea_dump_bytes} bytes) — a real dump holds the DB and is >64K"
  exit 1
fi
log "Gitea dump: $(du -sh --apparent-size "$STAGING/gitea-dump.zip" | cut -f1)"

# 3. Backup to local repo
log "Backing up to local repo..."
restic -r "$LOCAL_REPO" backup \
  /mnt/cloud_storage/gitea_data \
  /mnt/cloud_storage/webui_data \
  /mnt/cloud_storage/minio_data \
  /mnt/cloud_storage/pipelines_data \
  /mnt/cloud_storage/jupyter_workspace \
  /mnt/cloud_storage/searxng \
  /mnt/cloud_storage/jellyfin_config \
  /mnt/cloud_storage/openclaw_config \
  /mnt/cloud_storage/openclaw_auth \
  /mnt/cloud_storage/caddy_data \
  "$STAGING" \
  --tag daily \
  --verbose=0

# 4. Prune local (keep 7 daily, 4 weekly, 6 monthly)
log "Pruning local repo..."
restic -r "$LOCAL_REPO" forget --prune \
  --keep-daily 7 --keep-weekly 4 --keep-monthly 6 \
  --quiet

# 5. Copy latest snapshot to Google Drive
log "Copying to Google Drive..."
RESTIC_FROM_PASSWORD="$RESTIC_PASSWORD" restic -r "$REMOTE_REPO" copy \
  --from-repo "$LOCAL_REPO" \
  --quiet

# 6. Prune remote (keep 4 weekly, 6 monthly — less granular for offsite)
log "Pruning remote repo..."
restic -r "$REMOTE_REPO" forget --prune \
  --keep-weekly 4 --keep-monthly 6 \
  --quiet

# 7. Weekly integrity check (Sundays) — reads 5% of pack data
if [ "$(date +%u)" -eq 7 ]; then
  log "Weekly integrity check of local repo..."
  restic -r "$LOCAL_REPO" check --read-data-subset=5%
fi

log "=== Backup completed successfully ==="
