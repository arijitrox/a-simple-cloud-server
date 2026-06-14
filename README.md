# AI Homelab Cloud

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
| `ai/` | Ollama, Open-WebUI, Pipelines, SearXNG, Redis, OpenClaw |
| `devops/` | Gitea, Postgres |
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
```

> The Makefile drives every stack at once (there is no per-stack target). To act on a
> single stack, call docker compose directly, e.g.
> `docker compose --project-name ai --env-file .env -f ai/docker-compose.yml up -d`.

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
- `calculate_pi.py` / `gpu_pi.py` / `pytorch_test.py` — CPU/GPU sanity checks.
- `share_drives.sh` — one-shot Samba setup that exports `/mnt/cloud_storage` and all HDD bays as SMB shares to the LAN. Review before running (see Security notes).

### Deprecated / cleanup candidates

- `update_stack.sh` — **broken.** It runs `docker compose pull/up` from the repo root, but the monolith compose file was split into per-stack files, so there is no root `docker-compose.yml`. Use `make update` instead.
- `calculatte_pi_gpu` — junk file: a misnamed, untracked-history copy of `calculate_pi.py` (CPU Monte-Carlo, not GPU). Safe to delete.

## Service exposure & security

External access is via Cloudflare Tunnel; only the hostnames you register in the tunnel are reachable. Be deliberate about which of these you expose:

- **Portainer** (`port.*`) holds the Docker socket — equivalent to root on the host. Keep it Tailscale-only or behind Cloudflare Access, never an open public hostname.
- **MinIO console** (`storage.*`) ships with default user `admin`; set a strong `MINIO_ROOT_PASSWORD` and consider a non-default user.
- **Jupyter** (`jupyter.*`) runs `--allow-root` with the token passed on the command line (visible in `docker inspect`). Gate it behind Access.
- **Ollama** (`ollama.*`) is already IP-restricted to LAN/Tailscale in the Caddyfile — keep it that way.
- Docker publishes container ports directly to the host and **bypasses ufw**, so `11434`, `9000/9001`, `8888`, `3000`, etc. are open on all interfaces regardless of the firewall. Ensure the host is not directly internet-facing, or restrict with explicit iptables `DOCKER-USER` rules.

See `SERVER_LOG.md` for the live exposure review and the outstanding credential-rotation task.
