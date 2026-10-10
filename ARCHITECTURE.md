# Architecture — How This Server Works

A map of the AI homelab: hardware, network paths, the Docker stacks, data flow, and
operations. For replication steps see `AI_RACK_SETUP.md`; for the change log and the
private security state see `SERVER_LOG.md` (gitignored).

---

## 1. Hardware & OS

| Layer | Detail |
|---|---|
| CPU | AMD EPYC 7742 (64-core) |
| RAM | 256 GB (8× 32 GB DDR4-3200 ECC RDIMM, 8-channel) |
| GPU | 3× AMD RX 6700 (ROCm; ~10 GB VRAM each, `gfx1031` reported, overridden to `10.3.0`) |
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
`www`→homepage · `arijitroy.com` (apex)→homepage · `claw`→openclaw-gateway

### Caddy-only / not public
`ollama` (Tailscale-only) · `pipes` (pipelines) · `comfy` (ComfyUI image/video gen)

> ⚠️ Docker-published ports **bypass ufw**. Only 9000 (MinIO S3) and 11434 (Ollama)
> are published — kept for raw-IP LAN clients — plus Netdata's 19999 (host network).
> The host must stay behind NAT/the tunnel, not be directly internet-facing.
> See `SERVER_LOG.md` → Service Exposure Review.

---

## 3. Stacks & services

Each subdirectory is one `docker compose` project; all share the external `cloud-net`
bridge. Driven by the root `Makefile` (`make up/down/update/ps`) with `.env` at the root.

| Stack | Service | Image | Host ports | Role |
|---|---|---|---|---|
| `infra/` | caddy | `caddy:2-alpine` | 80, 443 | Reverse proxy, internal TLS |
| | cloudflared | `cloudflare/cloudflared` | — | Public access tunnel |
| | minio | `minio/minio` (pinned) | 9000 | S3 object storage + console |
| | portainer | `portainer-ce` (pinned) | — | Docker web UI (holds docker.sock) |
| `ai/` | ollama | `ollama/ollama:rocm` | 11434 | Local LLM inference (GPU) |
| | comfyui | `yanwk/comfyui-boot:rocm` | — | Image + video generation (GPU). **Opt-in** (`profiles: [comfy]`) — parked on thermals, skipped by `make up` |
| | open-webui | `open-webui` (pinned release) | — | Chat UI |
| | pipelines | `open-webui/pipelines` | — | OpenAI-compat middleware |
| | searxng | `searxng/searxng` | — | Private search for RAG |
| | redis | `redis:8-alpine` | — | SearXNG cache |
| | kokoro | `remsky/kokoro-fastapi-cpu` | — | TTS for Open-WebUI (CPU) |
| | speaches | `speaches-ai/speaches` | — | Whisper STT for Open-WebUI (CPU) |
| | openclaw-gateway | `openclaw/openclaw` | — | AI agent gateway |
| `devops/` | postgres | `postgres:16-alpine` | — (internal) | DB for Open-WebUI |
| | gitea | `gitea/gitea:1` | — | Git repo hosting (SQLite-backed) |
| `compute/` | jupyter-lab | `rocm/pytorch` | — | GPU notebooks |
| `vllm/` | vllm | `vllm/vllm-openai-cpu` (pinned) | — | OpenAI-compatible inference server (**CPU** — see §4) |
| `media/` | jellyfin | `linuxserver/jellyfin` | — | Media server (GPU transcode) |
| `monitoring/` | netdata | `netdata/netdata` | 19999 (host net) | System + container metrics |
| `homepage/` | homepage | `httpd:alpine` | — (internal) | Personal website (arijitroy.com) + `/lab.html` dashboard |

Only two services publish host ports, both for raw-IP LAN clients: **9000** (MinIO S3
API — `auto_ingestor.py`) and **11434** (Ollama — VS Code Continue). Everything else
is reachable solely through Caddy or the tunnel by container name.

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

### vLLM runs on the CPU, and that is deliberate

`vllm/` binds **no** `/dev/kfd` or `/dev/dri`. It is not an oversight and not a
staging step toward GPU — vLLM cannot use these cards.

vLLM's ROCm backend supports gfx90a/gfx942/gfx950 (CDNA), gfx1100/1101 (RDNA3)
and gfx1200/1201 (RDNA4). The three RX 6700s are Navi 22, device ID `73df` =
**gfx1031 (RDNA2)**, which appears on none of those lists; AMD's own "ROCm on
Radeon" supported hardware stops at RX 7900 XTX/XT and RX 9000. The
`HSA_OVERRIDE_GFX_VERSION=10.3.0` that makes ollama work only rewrites the arch
*string* — RDNA2 still lacks the MFMA matrix instructions and wave64 behaviour
vLLM's attention kernels are written against. The only demonstrated RDNA2 vLLM
is a Windows-native proof of concept using custom TheRock rocBLAS/Tensile
builds; there is no maintained Linux/Docker path.

Three further reasons GPU vLLM would not help here even if the kernels existed:

- **Context would regress.** vLLM keeps KV in VRAM with no graceful CPU spill.
  Ollama's partial-offload is what makes `qwen3.8:27b-256k` possible at all.
- **Tensor parallelism cannot use 3 GPUs.** Qwen3.8 has 4 KV heads, so TP must
  divide 4 — TP=2 or TP=4, never 3. One card would sit idle.
- **The models here are GGUF.** vLLM's GGUF path is experimental and slow.

So this stack exists to operate and learn the vLLM surface — OpenAI-compatible
server, engine args, continuous batching, Prometheus metrics — not to compete
with ollama on tokens/sec. Exercise it with `scripts/vllm-bench.sh`.

**CPU caveat:** the EPYC 7742 is Zen 2 — AVX2, **no AVX512**. vLLM CPU calls
that "limited features"; in practice oneDNN cannot build an optimised matmul
primitive and logs `Failed to create oneDNN linear, fallback to torch linear`
at startup. That warning is expected here, not a misconfiguration. float16 is
unstable on torch CPU, so `--dtype bfloat16` is required rather than preferred.

**Reaching it.** No host port is published, so `http://localhost:8000` does *not*
work from the host — use `https://vllm.arijitroy.com` (Caddy, LAN/Tailscale-only)
or the container's cloud-net IP. `scripts/vllm-bench.sh` resolves the latter
automatically via `docker inspect`.

**Measured 2026-08-21** — `Qwen/Qwen3-0.6B`, bf16, 64-token completions, OMP
bound to cores 0-31. Engine init (profile + KV cache + warmup) took 110 s; KV
cache 74,880 tokens = 9.14x max concurrency at 8k/request.

| concurrent requests | wall (s) | total tok/s | per-request tok/s |
|---|---|---|---|
| 1 | 1.42 | 45.1 | 45.1 |
| 2 | 1.65 | 77.7 | 38.8 |
| 4 | 2.47 | 103.8 | 25.9 |
| 8 | 4.25 | 120.4 | 15.1 |
| 16 | 7.88 | 129.9 | 8.1 |

Aggregate throughput ~2.9x from N=1 to N=16 while per-request degrades
gracefully — that is continuous batching, and it is the whole reason to run
vLLM. Cold-start is a separate number: the *first* request after boot measured
6.1 tok/s vs 45.8 warm, so never benchmark the first call.

> Benchmark note: the sweep sends a **distinct** prompt per request on purpose.
> vLLM runs `enable_prefix_caching=True`, so N copies of one prompt let requests
> 2..N hit the prefix cache — that inflated N=16 by ~8% (140.6 vs 129.9 tok/s)
> before this was fixed.

### GPU thermals — the cards are the limiting factor, not the silicon

Three triple-slot cards sit adjacent with no directed intake, so they recirculate
each other's exhaust. The stock amdgpu curve handles this badly: it is effectively
**inverted** under load — the hottest card spins the *slowest*, and it has twice
reached the 110 °C junction SW CTF threshold that force-powers-off the box (once
under sustained ollama load, once from a single SDXL VAE decode). That is doubly
expensive here: until 2026-10-09 the machine did not come back on its own,
because every boot landed in emergency mode (see [Boot: bpool import](#boot-bpool-import)).

`gpu-fan-curve.service` (→ `scripts/gpu-fan-curve.sh`) replaces that curve:

- Navi 22 is SMU11, so there is **no `gpu_od/fan_ctrl/fan_curve` sysfs node**
  (that is RDNA3/SMU13 only). The only override is taking `pwm1_enable` from `2`
  (auto + zero-RPM) to `1` and driving `pwm1` from userspace.
- Curve is `30:35 45:50 55:65 65:80 72:92 80:100` (tempC:duty%), sized to reach
  **100% at 80 °C** — far below the 110 °C junction CTF kill — so the fans are
  already maxed on the way up instead of catching up after the spike. Instant
  ramp-up, 4 °C ramp-down hysteresis, 85 °C panic override that ignores
  hysteresis too.
- **Zero-RPM is off**, by two mechanisms: `pwm1_enable=1` takes the SMU's
  zero-RPM logic out of the loop entirely, and a 35% duty floor (~1155 RPM
  measured) means the fans never stop even on a cold card.
- Control input is the **hottest of edge/junction/mem**, not edge alone — junction
  is what trips CTF, and it runs well ahead of edge.
- `systemctl stop` restores automatic control via `ExecStopPost`.
- `scripts/gpu-fan-curve.sh --dump-curve` prints the resolved table; needs neither
  root nor hardware.

This buys headroom; it does not create airflow. Cards idling in the mid-70s °C at
5 W is a chassis problem, and case intake is still the real fix. If CTF recurs,
the next lever is lowering `power1_cap` on the hottest card (all three are pinned
at the 138 W max).

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
   jupyter_workspace, searxng, jellyfin_config, openclaw_config, openclaw_auth,
   caddy_data` + the dump → **local repo** `/mnt/data_4/restic-repo`.
   `ollama_models` is intentionally not included (large, re-downloadable).
3. `restic copy` → **offsite** `rclone:gdrive:restic-repo` (Google Drive).
4. Prune: local 7d/4w/6m, remote 4w/6m.
5. Sundays: `restic check --read-data-subset=5%` on the local repo.

Encryption: `RESTIC_PASSWORD` (in `.env`) — irrecoverable if lost.
Alerting: script pings `HEALTHCHECK_URL` (`.env`, optional) on success, `/fail` on
error — a dead-man's-switch that also catches the timer never firing.

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
| GPU fan curve | `gpu-fan-curve.service` (systemd, root; see §4) |

External edges: **Cloudflare Tunnel** (public), **Tailscale** (admin/LAN), **Caddy**
(internal TLS). No inbound ports are exposed publicly by design.

### Boot: bpool import

Root-on-ZFS layout: `rpool` (`nvme1n1p4`) holds `/`, and the small `bpool`
(`nvme1n1p3`) holds `/boot` with a GRUB-compatible feature set. `/boot/efi` is
`nvme1n1p1`, and `/boot/grub` is a bind mount of `/boot/efi/grub`.

**Fixed 2026-10-09.** `/etc/zfs/zpool.cache` had been 0 bytes since 2026-03-17,
so `zfs-import-cache` was skipped, `zfs-import-scan` was disabled, and bpool was
never imported. `boot.mount` failed, `local-fs.target` failed, and every boot
landed in emergency mode (one unattended reboot meant a 36h outage). Kernel
updates had meanwhile been landing in rpool's shadowed `/boot`, which GRUB never
reads, so the box kept booting the March kernel.

The fix, applied live:

```bash
sudo zpool import -N bpool
sudo zpool set cachefile=/etc/zfs/zpool.cache bpool
sudo zpool set cachefile=/etc/zfs/zpool.cache rpool
sudo systemctl enable zfs-import-scan.service   # fallback; runs only if the cache is empty
sudo systemctl start boot.mount boot-efi.mount boot-grub.mount
KVER=6.8.0-146-generic   # the kernel that was stranded in the shadowed /boot
sudo apt install --reinstall linux-image-$KVER linux-modules-$KVER   # lands on bpool now
sudo update-initramfs -u -k all && sudo update-grub
```

First reboot afterwards: clean, multi-user, new kernel, docker up ~100 s after
boot, all stacks started by `cloud-stack.service`.

Regression check:

```bash
stat -c %s /etc/zfs/zpool.cache                              # must be non-zero
lsinitramfs /boot/initrd.img-$(uname -r) | grep zpool.cache   # must be present
findmnt /boot                                                 # source bpool/BOOT/...
```

**Never `zpool upgrade` bpool.** Its "features not enabled" notice is
deliberate: enabling them makes the pool unreadable to GRUB.
