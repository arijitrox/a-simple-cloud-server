# Architecture — How This Server Works

A map of the AI homelab: hardware, network paths, the Docker stacks, data flow, and
operations. For replication steps see `AI_RACK_SETUP.md`; for the change log and the
private security state see `SERVER_LOG.md` (gitignored).

---

## 1. Hardware & OS

| Layer | Detail |
|---|---|
| CPU | AMD EPYC 7742 (64-core) |
| RAM | 94 GB |
| GPU | 3× AMD RX 6700 XT (ROCm; `gfx1031` reported, overridden to `10.3.0`) |
| Boot/root | ZFS pool `rpool` (472 GB) |
| Fast storage | NVMe at `/mnt/cloud_storage` (3.7 TB) — all Docker volumes |
| Bulk storage | 5× HDD bays `/mnt/data_1…5` — Jellyfin media + local restic repo |
| OS | Ubuntu + Docker |

---

## 2. Network — two ways in

```
                         INTERNET
                            │
                            ▼
                 ┌────────────────────┐
                 │  Cloudflare edge    │  TLS terminates here
                 │  *.arijitroy.com    │
                 └─────────┬──────────┘
                           │  (outbound-only tunnel, no open inbound ports)
                           ▼
                   ┌───────────────┐
                   │  cloudflared  │  container, tunnel "God-Mode-Uplink"
                   │  (infra)      │  ingress maps hostname → service
                   └──────┬────────┘
                          │ routes DIRECTLY to service containers on cloud-net
                          ▼
        ┌───────────────────────────────────────────────┐
        │            cloud-net (Docker bridge)            │
        │  open-webui  gitea  minio  jellyfin  searxng    │
        │  jupyter  portainer  homepage  openclaw …       │
        └───────────────────────────────────────────────┘
                          ▲
                          │  LAN / Tailscale path (separate from the tunnel)
                   ┌──────┴────────┐
                   │     Caddy     │  reverse proxy, `tls internal` certs
                   │   (infra)     │  same hostnames, for local/VPN access
                   └───────────────┘
```

**Two independent entry paths to the same hostnames:**

1. **Public** → Cloudflare → `cloudflared` tunnel → **straight to the service container**
   (e.g. `chat.arijitroy.com → http://open-webui:8080`). Cloudflare does TLS; no inbound
   ports are opened on the host.
2. **Local/VPN** → **Caddy** serves the same subdomains with internal TLS, for LAN and
   Tailscale access. `ollama.arijitroy.com` is **Caddy-only and IP-restricted** to
   LAN/Tailscale ranges — never exposed through the tunnel.

### Public hostnames (in the tunnel)
`chat`→open-webui · `git`→gitea · `media`→jellyfin · `storage`→minio console ·
`search`→searxng · `jupyter`→jupyter-lab · `port`→portainer · `monitor`→netdata ·
`www`→homepage · `claw`→openclaw-gateway

### Caddy-only / not public
`ollama` (Tailscale-only) · `pipes` (pipelines)

> ⚠️ Docker publishes container ports to the host and **bypasses ufw** (11434, 9000/9001,
> 8888, 3000, 9099, 3001/2222, 9443, 18789…). The host must stay behind NAT/the tunnel,
> not be directly internet-facing. See `SERVER_LOG.md` → Service Exposure Review.

---

## 3. Stacks & services

Each subdirectory is one `docker compose` project; all share the external `cloud-net`
bridge. Driven by the root `Makefile` (`make up/down/update/ps`) with `.env` at the root.

| Stack | Service | Image | Host ports | Role |
|---|---|---|---|---|
| `infra/` | caddy | `caddy:2-alpine` | 80, 443 | Reverse proxy, internal TLS |
| | cloudflared | `cloudflare/cloudflared` | — | Public access tunnel |
| | minio | `minio/minio` | 9000, 9001 | S3 object storage + console |
| | portainer | `portainer-ce` | 9443, 9002 | Docker web UI (holds docker.sock) |
| `ai/` | ollama | `ollama/ollama:rocm` | 11434 | Local LLM inference (GPU) |
| | open-webui | `open-webui:main` | 3000 | Chat UI |
| | pipelines | `open-webui/pipelines` | 9099 | OpenAI-compat middleware |
| | searxng | `searxng/searxng` | 8080 | Private search for RAG |
| | redis | `redis:alpine` | — | SearXNG cache |
| | openclaw-gateway | `openclaw/openclaw` | 18789 | AI agent gateway |
| `devops/` | postgres | `postgres:16-alpine` | — (internal) | DB for Open-WebUI |
| | gitea | `gitea/gitea` | 3001, 2222 | Git repo hosting (SQLite-backed) |
| `compute/` | jupyter-lab | `rocm/pytorch` | 8888 | GPU notebooks |
| `media/` | jellyfin | `linuxserver/jellyfin` | 8096 | Media server (GPU transcode) |
| `monitoring/` | netdata | `netdata/netdata` | 19999 (host net) | System + container metrics |
| `homepage/` | homepage | `httpd:alpine` | — (internal) | Dashboard landing page |

> CI note: there is intentionally **no Gitea Actions runner** — Gitea is repo hosting only.

---

## 4. How the AI stack talks to itself

```
        user ──► open-webui ──► ollama            (LLM inference, GPU)
                    │   ├──────► searxng ──► redis (web search / RAG)
                    │   └──────► pipelines         (OpenAI-compatible functions)
                    └─────────► postgres           (users, chats, settings)

   openclaw-gateway ──► ollama                     (agent runs on local models)
```

- **GPU sharing:** `ollama` and `jupyter-lab` both bind `/dev/kfd` + `/dev/dri` (ROCm).
  Optional isolation via `HIP_VISIBLE_DEVICES` per `AI_RACK_SETUP.md` §15.
- **Databases:** Open-WebUI → Postgres; Gitea → its own bundled SQLite (in
  `/mnt/cloud_storage/gitea_data`, *not* Postgres); SearXNG → Redis cache.

---

## 5. Storage layout

```
/mnt/cloud_storage  (NVMe, 3.7TB)   ← every Docker volume
   ├── ollama_models      jellyfin_config   gitea_data
   ├── webui_data         pipelines_data    postgres_data
   ├── searxng            jupyter_workspace  minio_data
   ├── caddy_data/config  portainer_data    netdata_data/config
   └── openclaw_config / openclaw_auth      media/

/mnt/data_1…5  (HDD bays)
   ├── data_1..3, data_5  → Jellyfin media libraries
   └── data_4             → restic LOCAL backup repo
```

---

## 6. Backups

`scripts/backup.sh` (systemd `cloud-backup.timer`, daily 03:00):

1. `pg_dumpall` of Postgres (via local socket — no password needed).
2. `restic` backup of `gitea_data, webui_data, minio_data, pipelines_data,
   jupyter_workspace, searxng` + the dump → **local repo** `/mnt/data_4/restic-repo`.
   Excludes `ollama_models` (large, re-downloadable).
3. `restic copy` → **offsite** `rclone:gdrive:restic-repo` (Google Drive).
4. Prune: local 7d/4w/6m, remote 4w/6m.

Encryption: `RESTIC_PASSWORD` (in `.env`) — irrecoverable if lost.

---

## 7. Secrets & config flow

```
.env  (repo root, gitignored)
   │   CF_TUNNEL_TOKEN, MINIO_*, POSTGRES_*, PIPELINES_API_KEY,
   │   JUPYTER_TOKEN, RESTIC_PASSWORD, OPENCLAW_GATEWAY_TOKEN, MINIO_URL/BUCKET
   ▼
docker compose --env-file .env   →   ${VAR} expansion into each service
```

`.env.example` documents every key. Never commit `.env`. See `SERVER_LOG.md` for the
rotation state and the public-history purge runbook (`scripts/purge-secret-history.sh`).

---

## 8. Lifecycle / operations

| Action | Command |
|---|---|
| Start / stop all | `make up` / `make down` |
| Update images | `make update` |
| Status | `make ps` |
| Single service | `docker compose --project-name <stack> --env-file .env -f <stack>/docker-compose.yml up -d <svc>` |
| Auto-start on boot | `cloud-stack.service` (systemd → `make up`) |

External edges: **Cloudflare Tunnel** (public), **Tailscale** (admin/LAN), **Caddy**
(internal TLS). No inbound ports are exposed publicly by design.
