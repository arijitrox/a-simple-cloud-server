# OpenClaw Setup

## Overview

OpenClaw is a self-hosted personal AI assistant gateway, running as a Docker container on this server and accessible at `https://claw.arijitroy.com`.

## Container

- **Image**: `ghcr.io/openclaw/openclaw:latest`
- **Container name**: `openclaw-gateway`
- **Compose file**: `ai/docker-compose.yml`
- **Network**: `cloud-net` (shared with all other AI stack containers)
- **Port**: `18789` (proxied via Caddy)
- **Command**: `node dist/index.js gateway --allow-unconfigured`

## Volumes (config lives on host at)

| Host path | Container path | Purpose |
|---|---|---|
| `/mnt/cloud_storage/openclaw_config` | `/home/node/.openclaw` | Main config, state, logs |
| `/mnt/cloud_storage/openclaw_auth` | `/home/node/.config/openclaw` | Auth profiles / secrets |

## Key Config File

`/mnt/cloud_storage/openclaw_config/openclaw.json` — main config. Edit this to change providers, gateway settings, etc.

## Environment Variables

| Variable | Source |
|---|---|
| `OPENCLAW_GATEWAY_TOKEN` | `.env` at repo root |

## Ollama Integration

Both `openclaw-gateway` and `ollama` are on `cloud-net`, so openclaw reaches Ollama via container hostname:

```
http://ollama:11434
```

**Do NOT use `/v1` suffix** — that switches to OpenAI-compat mode where tool calling is unreliable. Use the native Ollama API endpoint.

Config added to `openclaw.json`:

```json
"models": {
  "providers": {
    "ollama": {
      "baseUrl": "http://ollama:11434",
      "apiKey": "ollama-local",
      "api": "ollama"
    }
  }
}
```

`apiKey: "ollama-local"` is a literal marker (not an env var) for local/LAN Ollama hosts — no real credential needed.

## Ollama Container

- **Image**: `ollama/ollama:rocm` (AMD ROCm GPU)
- **Container name**: `ollama`
- **Port**: `11434`
- **Models stored at**: `/mnt/cloud_storage/ollama_models`
- **GPU env**: `HSA_OVERRIDE_GFX_VERSION=10.3.0`

## Useful CLI Commands (run inside container)

```bash
docker exec openclaw-gateway openclaw models list
docker exec openclaw-gateway openclaw models list --provider ollama
docker exec openclaw-gateway openclaw config get
docker exec openclaw-gateway openclaw devices list
docker exec openclaw-gateway openclaw doctor
```

## Default Agent Model

Set via: `agents.defaults.model.primary`

Current default: `ollama/qwen3.5:27b`

To change:
```bash
docker exec openclaw-gateway openclaw config set agents.defaults.model.primary "ollama/qwen3.5:27b"
docker restart openclaw-gateway
```

**Why this matters:** OpenClaw's built-in fallback default is `openai/gpt-5.5`, which requires an OpenAI API key. Without setting this, agents fail with `401 Unauthorized: Missing bearer or basic authentication, url: https://api.openai.com/v1/responses`.

Available working models (as of 2026-06-14):
- `ollama/qwen3.5:27b` — general purpose (current default)
- `ollama/qwen3-coder:30b` — coding tasks
- `ollama/devstral-small-2:latest` — coding, smaller
- `ollama/gpt-oss:120b` — large, slow
- `claude-cli/claude-sonnet-4-6` — uses local Claude Code CLI session

## Device Pairing

### Problem: devices re-pair after every restart

**Root cause:** The OpenClaw Windows Tray app loses its stored token between sessions, then initiates a new pairing request. Each re-pair creates a *new* duplicate row in the devices table rather than reusing the old entry.

**Windows token storage location:**
```
C:\Users\ariji\AppData\Roaming\OpenClawTray
```
Check this folder isn't being cleared by antivirus, Windows temp cleanup, or roaming profile sync.

**There is no gateway-side auto-approve for re-pairs.** The `autoApproveCidrs` config option only covers first-time `role:node` pairings with no requested scopes:
```json
"gateway": {
  "nodes": {
    "pairing": {
      "autoApproveCidrs": ["76.64.143.141/32"]
    }
  }
}
```

### Approving pending re-pairs

```bash
docker exec openclaw-gateway openclaw devices list
docker exec openclaw-gateway openclaw devices approve <requestId>
```

### Cleaning up stale/duplicate device entries

After pairing is stable, remove the dead entries (revoked tokens, old duplicates):
```bash
docker exec openclaw-gateway openclaw devices list
docker exec openclaw-gateway openclaw devices remove <fingerprint>
```

As of 2026-06-14 there are 9 paired entries including 4 duplicate "OpenClaw Windows Tray" rows — needs cleanup once pairing is stable.

### Rotating revoked tokens

If a paired device shows `(revoked)` tokens but is still connected:
```bash
docker exec openclaw-gateway openclaw devices rotate --device <fingerprint> --role operator
docker exec openclaw-gateway openclaw devices rotate --device <fingerprint> --role node
```

## Security Notes

- **`--allow-unconfigured`** starts the gateway even with no completed config. Combined with public exposure (`claw.arijitroy.com` is proxied by Caddy and reachable through the Cloudflare Tunnel once the hostname is added), make sure `OPENCLAW_GATEWAY_TOKEN` is set to a strong random value (`openssl rand -hex 32`) and never blank — the token is the only thing standing between the open internet and an agent gateway that can drive Ollama and the local Claude CLI session.
- **`autoApproveCidrs` includes a public IP** (`76.64.143.141/32`). Auto-approving a routable address means anyone who can spoof/originate from it gets first-time node pairing without prompt. Prefer Tailscale CIDRs (`100.64.0.0/10`) or LAN ranges; drop the public entry unless you genuinely need it.
- **Consider Cloudflare Access** in front of `claw.*` so the gateway UI requires SSO, not just the pairing token.
- The `openclaw_auth` volume (`/mnt/cloud_storage/openclaw_auth`) holds provider secrets and pairing tokens — it is included in the host backup path but should never be committed or shared.

## Docs

- Main docs: https://docs.openclaw.ai
- Models: https://docs.openclaw.ai/concepts/models
- Ollama provider: https://docs.openclaw.ai/providers/ollama
