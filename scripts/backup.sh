#!/bin/bash
set -euo pipefail

source /home/arijit/cloud-infra/minio/.env

LOCAL_REPO=/mnt/data_4/restic-repo
REMOTE_REPO=rclone:gdrive:restic-repo
STAGING=/tmp/backup-staging
export RESTIC_PASSWORD

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

log "=== Backup started ==="
mkdir -p "$STAGING"
trap 'rm -rf "$STAGING"' EXIT

# 1. Postgres logical dump
log "Dumping Postgres..."
docker exec postgres pg_dumpall -U "$POSTGRES_USER" | gzip > "$STAGING/postgres_full.sql.gz"
log "Postgres dump: $(du -sh "$STAGING/postgres_full.sql.gz" | cut -f1)"

# 2. Backup to local repo
log "Backing up to local repo..."
restic -r "$LOCAL_REPO" backup \
  /mnt/cloud_storage/gitea_data \
  /mnt/cloud_storage/webui_data \
  /mnt/cloud_storage/minio_data \
  /mnt/cloud_storage/pipelines_data \
  /mnt/cloud_storage/jupyter_workspace \
  /mnt/cloud_storage/searxng \
  "$STAGING" \
  --exclude /mnt/cloud_storage/ollama_models \
  --tag daily \
  --verbose=0

# 3. Prune local (keep 7 daily, 4 weekly, 6 monthly)
log "Pruning local repo..."
restic -r "$LOCAL_REPO" forget --prune \
  --keep-daily 7 --keep-weekly 4 --keep-monthly 6 \
  --quiet

# 4. Copy latest snapshot to Google Drive
log "Copying to Google Drive..."
restic -r "$LOCAL_REPO" copy \
  --repo2 "$REMOTE_REPO" \
  --password2 "$RESTIC_PASSWORD" \
  --quiet

# 5. Prune remote (keep 4 weekly, 6 monthly — less granular for offsite)
log "Pruning remote repo..."
restic -r "$REMOTE_REPO" forget --prune \
  --keep-weekly 4 --keep-monthly 6 \
  --quiet

log "=== Backup completed successfully ==="
