# AI Rack — Replication Guide

How to stand up a self-hosted AI server from a bare Ubuntu install.
Derived from the God-Mode server: AMD EPYC 7742, 94GB RAM, 3× RX 6700 XT, NVMe + HDD array.

---

## Stack Overview

| Service | Purpose | Port |
|---|---|---|
| Ollama | Local LLM inference engine | 11434 |
| Open-WebUI | Chat UI (ChatGPT-like) | 3000 |
| OpenClaw | Self-hosted AI agent gateway (Ollama backend) | 18789 |
| Pipelines | Custom middleware / function calling | 9099 |
| SearXNG | Private web search for RAG | 8080 |
| Redis | Cache for SearXNG | — |
| Postgres | Persistent DB for Open-WebUI | — |
| Caddy | Reverse proxy + TLS | 80/443 |
| Cloudflared | Cloudflare Tunnel (public access) | — |
| Gitea | Self-hosted Git | 3001/2222 |
| Jupyter Lab | GPU notebooks | 8888 |
| MinIO | S3-compatible object storage | 9000/9001 |
| Netdata | System + container monitoring | 19999 |
| Jellyfin | Media server (optional) | 8096 |
| Portainer | Docker web UI (optional) | 9443 |

---

## 1 — Ubuntu Server Install

Download Ubuntu Server 24.04 LTS. During install:
- Create user: `arijit` (or your username — update paths below accordingly)
- Enable OpenSSH
- Skip extra snaps

Post-install basics:

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y curl git make htop nvme-cli smartmontools unzip
```

---

## 2 — GPU Drivers

### AMD (ROCm) — RX 6700 XT / RX 7000 series

```bash
# Add ROCm repo
wget https://repo.radeon.com/amdgpu-install/6.3.3/ubuntu/noble/amdgpu-install_6.3.60303-1_all.deb
sudo dpkg -i amdgpu-install_6.3.60303-1_all.deb
sudo amdgpu-install --usecase=rocm,graphics --no-32 -y

# Add your user to required groups
sudo usermod -aG render,video $USER

# Reboot and verify
sudo reboot
rocminfo | grep -E "Name|gfx"
```

> **RX 6700 XT note:** The GPU reports as `gfx1031` but ROCm targets `gfx1030`.
> Set `HSA_OVERRIDE_GFX_VERSION=10.3.0` in containers that use ROCm (already in the compose files).

### NVIDIA — RTX series

```bash
# Install CUDA drivers
sudo apt install -y nvidia-driver-560
sudo reboot

# Install NVIDIA Container Toolkit
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
  sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
  sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
sudo apt update && sudo apt install -y nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker

# Verify
nvidia-smi
```

> **NVIDIA users:** Change `ollama/ollama:rocm` → `ollama/ollama` and `rocm/pytorch:latest` → `pytorch/pytorch:latest` in the compose files.
> Replace the `devices` + `group_add` + `security_opt` blocks with `deploy.resources.reservations.devices` (NVIDIA runtime).

---

## 3 — Docker

```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
newgrp docker

# Verify
docker run --rm hello-world
```

---

## 4 — Storage Layout

The stack uses two mount points:

| Path | Purpose |
|---|---|
| `/mnt/cloud_storage` | Primary NVMe — all Docker volumes live here |
| `/mnt/data_1` … `/mnt/data_5` | HDD bays — media files for Jellyfin |

### Format and mount your NVMe

```bash
# Find your NVMe device
lsblk

# Create filesystem (adjust /dev/nvme0n1 to match)
sudo mkfs.ext4 /dev/nvme0n1

# Create mount point and mount
sudo mkdir -p /mnt/cloud_storage
sudo mount /dev/nvme0n1 /mnt/cloud_storage

# Make permanent via /etc/fstab
echo "UUID=$(sudo blkid -s UUID -o value /dev/nvme0n1) /mnt/cloud_storage ext4 defaults 0 2" | sudo tee -a /etc/fstab
```

### Create volume directories

```bash
sudo mkdir -p /mnt/cloud_storage/{ollama_models,webui_data,pipelines_data,searxng,postgres_data,gitea_data,gitea_runner,jupyter_workspace,minio_data,caddy_data,caddy_config,portainer_data,netdata_data,netdata_config,openclaw_config,openclaw_auth,jellyfin_config,media}
sudo chown -R $USER:$USER /mnt/cloud_storage
```

### HDD bays (optional — only needed for Jellyfin)

```bash
# Repeat for each drive, adjusting device and mount point
sudo mkdir -p /mnt/data_1
echo "UUID=$(sudo blkid -s UUID -o value /dev/sda) /mnt/data_1 ext4 defaults 0 2" | sudo tee -a /etc/fstab
sudo mount -a
```

---

## 5 — Clone the Repo

```bash
git clone https://git.arijitroy.com/Arijit/ai-god-cloud.git ~/cloud-infra/minio
cd ~/cloud-infra/minio
```

> If cloning onto a different username, update paths in `cloud-stack.service` and `scripts/backup.sh`.

---

## 6 — Configure Secrets

```bash
cp .env.example .env
nano .env
```

Fill in every value:

| Variable | How to get it |
|---|---|
| `CF_TUNNEL_TOKEN` | Cloudflare Zero Trust → Tunnels → Create tunnel → copy token |
| `MINIO_ROOT_PASSWORD` | Choose a strong password |
| `POSTGRES_USER` / `POSTGRES_PASSWORD` | Choose credentials |
| `POSTGRES_DB` | Set to `warehouse` or any name |
| `PIPELINES_API_KEY` | `openssl rand -hex 32` |
| `GITEA_RUNNER_REGISTRATION_TOKEN` | Set after Gitea first-run (see step 10) |
| `JUPYTER_TOKEN` | Choose a passphrase |
| `RESTIC_PASSWORD` | Choose a passphrase — **do not lose this** |
| `OPENCLAW_GATEWAY_TOKEN` | `openssl rand -hex 32` |

---

## 7 — Caddy Configuration

Edit `infra/Caddyfile` and replace all `arijitroy.com` subdomains with your own domain:

```bash
sed -i 's/arijitroy\.com/yourdomain.com/g' infra/Caddyfile
```

Also update the `email` line at the top of the Caddyfile to your email.

---

## 8 — Cloudflare Tunnel Setup

1. Go to [dash.cloudflare.com](https://dash.cloudflare.com) → Zero Trust → Networks → Tunnels
2. Create tunnel → name it (e.g. `ai-rack-1`)
3. Copy the token into `.env` as `CF_TUNNEL_TOKEN`
4. Add public hostnames pointing to the internal services:

| Subdomain | Service | URL |
|---|---|---|
| chat | open-webui | `http://open-webui:8080` |
| git | gitea | `http://gitea:3000` |
| media | jellyfin | `http://jellyfin:8096` |
| storage | minio | `http://minio:9001` |
| port | portainer | `http://portainer:9000` |
| jupyter | jupyter-lab | `http://jupyter-lab:8888` |
| search | searxng | `http://searxng:8080` |
| claw | openclaw-gateway | `http://openclaw-gateway:18789` |

> Cloudflare handles TLS termination at their edge. Caddy issues `tls internal` certs for container-to-container traffic.

> **Security:** Anything you add here becomes reachable from the public internet. `portainer` (full Docker socket = root on host), `minio` console, and `jupyter-lab` (token in process args, runs `--allow-root`) are high-value targets — put them behind Cloudflare Access (Zero Trust → Access → Applications) or keep them Tailscale-only rather than publishing them as open hostnames. See `SERVER_LOG.md` for the current exposure review.

---

## 9 — Start the Stack

```bash
cd ~/cloud-infra/minio

# Create the shared Docker network and bring everything up
make up

# Check all containers are running
make ps
```

Expected output: all containers in `Up` state. First startup downloads images — allow 5–10 minutes depending on bandwidth.

---

## 10 — First-Run Configuration

### Open-WebUI

1. Navigate to `https://chat.yourdomain.com`
2. Create the admin account on first visit
3. Settings → Connections → verify Ollama URL is `http://ollama:11434`

### Pull your first model

```bash
docker exec -it ollama ollama pull qwen2.5:7b
# For a bigger model:
docker exec -it ollama ollama pull qwen2.5:32b
```

### Gitea

1. Navigate to `https://git.yourdomain.com`
2. Complete the install wizard (DB: Postgres, host: `postgres:5432`)
3. Create admin account
4. Go to Admin → Runners → Create runner → copy token → update `GITEA_RUNNER_REGISTRATION_TOKEN` in `.env`
5. `make restart` to apply the new token

### MinIO

1. Navigate to `https://storage.yourdomain.com`
2. Log in with `MINIO_ROOT_USER` / `MINIO_ROOT_PASSWORD` from `.env`
3. Create your first bucket

### Jupyter Lab

Navigate to `https://jupyter.yourdomain.com?token=<JUPYTER_TOKEN>`

---

## 11 — Auto-Start on Boot (Systemd)

```bash
# Update the service file if your username or repo path differs
nano ~/cloud-infra/minio/cloud-stack.service

# Install and enable
sudo cp ~/cloud-infra/minio/cloud-stack.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable cloud-stack.service
sudo systemctl start cloud-stack.service

# Verify
sudo systemctl status cloud-stack.service
```

---

## 12 — Backups

### Install restic and rclone

```bash
# restic
sudo apt install -y restic

# rclone
curl https://rclone.org/install.sh | sudo bash
```

### Configure rclone for Google Drive

```bash
rclone config
# Follow prompts: new remote → name "gdrive" → Google Drive → authorize in browser
```

### Initialize restic repos

```bash
source ~/cloud-infra/minio/.env

# Local repo (on an HDD, not the main NVMe)
restic -r /mnt/data_4/restic-repo init

# Remote repo (Google Drive)
restic -r rclone:gdrive:restic-repo init
```

### Install the backup timer

```bash
sudo cp ~/cloud-infra/minio/cloud-backup.service /etc/systemd/system/
sudo cp ~/cloud-infra/minio/cloud-backup.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now cloud-backup.timer

# Verify timer
systemctl status cloud-backup.timer
```

### Manual backup run

```bash
bash ~/cloud-infra/minio/scripts/backup.sh
```

---

## 13 — SSH Hardening

```bash
sudo tee /etc/ssh/sshd_config.d/hardening.conf <<EOF
PasswordAuthentication no
PermitRootLogin no
MaxAuthTries 3
AllowUsers arijit
EOF
sudo systemctl restart ssh
```

> Make sure your SSH public key is in `~/.ssh/authorized_keys` **before** disabling password auth.

---

## 14 — Firewall

Docker bypasses ufw by writing iptables rules directly, but ufw still protects non-Docker ports:

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 2222/tcp    # Gitea SSH
sudo ufw allow in on tailscale0    # if using Tailscale
sudo ufw enable
```

---

## 15 — GPU Isolation (multi-GPU)

If you have multiple GPUs, dedicate cards per workload to avoid contention.

In `ai/docker-compose.yml` under `ollama`:
```yaml
environment:
  - HSA_OVERRIDE_GFX_VERSION=10.3.0
  - HIP_VISIBLE_DEVICES=0,1      # AMD — GPUs 0 and 1 for Ollama
  # CUDA_VISIBLE_DEVICES=0,1     # NVIDIA equivalent
```

In `compute/docker-compose.yml` under `jupyter`:
```yaml
environment:
  - HIP_VISIBLE_DEVICES=2        # AMD — GPU 2 for Jupyter
  # CUDA_VISIBLE_DEVICES=2       # NVIDIA equivalent
```

---

## Daily Operations

```bash
# Status
make ps

# Bring everything up / down
make up
make down

# Pull latest images and restart
make update

# Tail logs (all stacks)
make logs

# Logs for one container
docker logs -f open-webui

# Shell into a container
docker exec -it ollama bash

# List downloaded models
docker exec ollama ollama list

# Pull a new model
docker exec ollama ollama pull <model-name>
```

---

## Minimal Install (Ollama + Open-WebUI only)

If you just want the core AI stack without the rest:

```bash
# 1. Create the network
docker network create cloud-net

# 2. Start Ollama
docker run -d \
  --name ollama \
  --restart unless-stopped \
  --network cloud-net \
  -p 11434:11434 \
  -v /mnt/cloud_storage/ollama_models:/root/.ollama \
  ollama/ollama           # use :rocm for AMD

# 3. Start Open-WebUI
docker run -d \
  --name open-webui \
  --restart unless-stopped \
  --network cloud-net \
  -p 3000:8080 \
  -e OLLAMA_BASE_URL=http://ollama:11434 \
  -v /mnt/cloud_storage/webui_data:/app/backend/data \
  ghcr.io/open-webui/open-webui:main

# 4. Pull a model
docker exec ollama ollama pull qwen2.5:7b

# 5. Open http://<server-ip>:3000
```

---

## Useful Model Recommendations

| Model | Size | Best for |
|---|---|---|
| `qwen2.5:7b` | ~5GB | Fast general use, low VRAM |
| `qwen2.5:32b` | ~20GB | High quality general use |
| `qwen2.5-coder:32b` | ~20GB | Code generation |
| `llama3.3:70b` | ~40GB | Most capable open model |
| `mistral:7b` | ~4GB | Fast, instruction-following |
| `nomic-embed-text` | ~300MB | Embeddings for RAG |

Pull with: `docker exec ollama ollama pull <model>`

---

## Troubleshooting

**GPU not detected in Ollama**
```bash
docker exec ollama ollama run llama3 "hello"
# If slow/CPU: check device passthrough
ls /dev/kfd /dev/dri    # AMD — must exist on host
groups                   # must include 'video' and 'render'
```

**AMD GPU gfx version mismatch**
```bash
rocminfo | grep "gfx"
# Set HSA_OVERRIDE_GFX_VERSION to match your card:
# RX 6000 series → 10.3.0
# RX 7000 series → 11.0.0
```

**Open-WebUI can't reach Ollama**
```bash
docker exec open-webui curl http://ollama:11434/api/tags
# Should return JSON. If connection refused, both must be on cloud-net.
docker network inspect cloud-net | grep -A2 Name
```

**Container exits on startup**
```bash
docker logs <container-name>
# Check .env has all required variables set
docker compose --env-file .env config    # validates variable expansion
```

**NVMe volume permissions**
```bash
ls -la /mnt/cloud_storage/
# If root-owned: sudo chown -R $USER:$USER /mnt/cloud_storage
```
