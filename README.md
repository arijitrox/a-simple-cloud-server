# AI God Cloud

Self-hosted homelab stack running on an AMD EPYC 7742 server with 3x RX 6700 XT GPUs (ROCm). Docker-based, split into focused stacks with a shared Caddy reverse proxy and Cloudflare Tunnel for public access.

## Hardware

- CPU: AMD EPYC 7742 (64-core)
- RAM: 94 GB
- GPU: 3× AMD RX 6700 XT (ROCm)
- Storage: ZFS root (472 GB) + NVMe /mnt/cloud_storage (3.7 TB) + 5× HDD bays
- OS: Ubuntu + Docker

## Stacks

| Directory | Services |
|-----------|----------|
| `infra/` | Cloudflared tunnel, Caddy reverse proxy, MinIO, Portainer |
| `ai/` | Ollama, Open-WebUI, Pipelines, SearXNG, Redis |
| `devops/` | Gitea, Gitea runner, Postgres |
| `compute/` | Jupyter Lab (ROCm) |
| `media/` | Jellyfin |
| `monitoring/` | Netdata |
| `homepage/` | Dashboard landing page |

## Setup

```bash
# 1. Copy and fill in secrets
cp .env.example .env
$EDITOR .env

# 2. Bring up all stacks
make up

# 3. Or bring up a single stack
make up STACK=ai
```

## Makefile targets

| Target | Description |
|--------|-------------|
| `make up` | Start all stacks |
| `make down` | Stop all stacks |
| `make restart` | Restart all stacks |
| `make update` | Pull latest images and restart |
| `make ps` | Show running containers |

## Networking

All stacks share an external Docker bridge network `cloud-net`. Caddy issues internal TLS certificates and routes by subdomain. External access is via Cloudflare Tunnel (no open inbound ports required).

## Backups

`scripts/backup.sh` uses restic to back up all named Docker volumes (excluding re-downloadable model data) to a local repo and an offsite rclone/Google Drive target. See `cloud-backup.service` + `cloud-backup.timer` for systemd scheduling.

## Utilities

- `auto_ingestor.py` — watches a directory and uploads new files to a MinIO bucket. Configure via `MINIO_URL`, `MINIO_ROOT_USER`, `MINIO_ROOT_PASSWORD`, and `MINIO_BUCKET` env vars.
- `calculate_pi.py` / `gpu_pi.py` / `pytorch_test.py` — GPU sanity checks.
