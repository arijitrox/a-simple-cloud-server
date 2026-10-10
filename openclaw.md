# OpenClaw Setup

## Overview

OpenClaw is a self-hosted personal AI assistant gateway, running as a Docker container on this server and accessible at `https://claw.arijitroy.com`.

## Container

- **Version**: `2026.7.1` (updated 2026-08-04 from `2026.6.34`). **Deliberately
  pinned off `:latest`.** `:latest` still tracks the **stable** channel
  (`2026.6.34`); `2026.7.1` is the beta line and, as of 2026-08-04, the only
  `2026.7.x` tag published to ghcr. We moved because the official SearXNG
  web-search plugin requires `pluginApi >=2026.7.1` — see [Web search](#web-search).
  The 6.34 → 7.1 state migration ran clean (config-health + Memory Core index
  moved to per-agent SQLite, legacy files archived as `*.migrated`).
  **Un-pin back to `:latest` once the 7.x line ships stable.**
  **Update 2026-10-09:** that condition is met — stable is now `2026.9.x`
  (`v2026.8.35` 2026-10-02, `v2026.9.8` 2026-10-03, `v2026.9.9` 2026-10-08), so
  the pin no longer protects web search. Bump to a **pinned stable tag** (e.g.
  `2026.9.8`) rather than `:latest`, following [Updating](#updating), then match
  the native root node's npm version.
- **Image**: `ghcr.io/openclaw/openclaw:2026.7.1`
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

## Web search

Backed by the **self-hosted SearXNG** on `cloud-net` — no third-party API key,
no query leaving the box except to the upstream engines SearXNG itself scrapes.

**Wired 2026-08-04.** Before this, every `web_search` call failed with
`web_search is disabled or no provider is available.` and the three daily cron
digests were inventing content.

### Why it was broken

`tools.web.search.provider` was unset, and OpenClaw's auto-detection is
**credential-gated by design**:

```js
function hasImplicitProviderSelectionSignal(provider, config, search, agentDir) {
  if (!providerRequiresCredential(provider)) return false;   // keyless never auto-selects
  return hasEntryCredential(provider, config, search, agentDir);
}
```

So key-based providers (gemini/grok/minimax) were skipped for having no key, and
keyless ones (duckduckgo/codex/ollama) were skipped on the first line. Nothing
was ever selected. `tools.web.search.enabled` was **not** the problem — it
defaults to `true` when unset.

**A provider must be named explicitly. There is no working zero-config path.**

### Setup (as applied)

`searxng` is **not** bundled in the image — it is a ClawHub install, and it is
what forced the 7.1 bump.

```bash
docker exec openclaw-gateway openclaw plugins install clawhub:@openclaw/searxng-plugin
docker exec openclaw-gateway openclaw plugins enable searxng
docker exec openclaw-gateway openclaw config set \
  plugins.entries.searxng.config.webSearch.baseUrl "http://searxng:8080"
docker exec openclaw-gateway openclaw config set tools.web.search.provider "searxng"
docker restart openclaw-gateway
```

### SearXNG had to be fixed too

Wiring the plugin still returned `count: 0`. SearXNG's stock general-category
engines are google / duckduckgo / startpage / brave, and from this IP:

| engine | state |
|---|---|
| google | `Suspended: access denied` |
| startpage | `Suspended: CAPTCHA` |
| brave | `Suspended: too many requests` |
| duckduckgo | works, but CAPTCHAs under load |
| **bing** | **works reliably — was disabled** |
| mojeek, qwant, yep, presearch, mwmbl, seznam, yahoo | all fail from here |

Two changes in `/mnt/cloud_storage/searxng/settings.yml` (**not in git** — it
holds `secret_key`):

- enabled `bing`, which now carries the result set
- raised `outgoing.request_timeout` 2.0 → 5.0 and `max_request_timeout` 3.0 →
  8.0. The old budget was cutting off engines mid-response — bing and
  duckduckgo both answer in ~2–4s from here.

Blocked engines stay enabled: SearXNG skips suspended ones and they recover.

### Verify

```bash
# provider selected?  expect searxng "selected": true
docker exec openclaw-gateway openclaw infer web providers

# does it return results?  count must be > 0
docker exec openclaw-gateway openclaw infer web search --query "ROCm release notes" --limit 5

# raw engine health — check "unresponsive_engines"
docker exec openclaw-gateway sh -c 'curl -s "http://searxng:8080/search?q=test&format=json"'

# end-to-end through an agent turn (the path cron digests use)
docker exec openclaw-gateway openclaw agent --agent main --session-key searchtest \
  --message "Search the web for the latest ROCm release version and give me the URL." --timeout 240
```

If the agent answers without a real URL, the digests are still fiction.

### Plugin allowlist (7.1)

7.1 warns that non-bundled plugins auto-load when `plugins.allow` is empty. Set:

```json
"plugins": { "allow": ["device-pair","ollama","discord","whatsapp","searxng"],
             "bundledDiscovery": "compat" }
```

**`bundledDiscovery: "compat"` is required.** A bare `plugins.allow` also gates
*bundled* provider discovery, which silently disables anything omitted — it
knocked out `device-pair` on the first attempt. Any plugin added later must be
appended to this list or it will not load.

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

Current default: **`ollama/qwen3.8:27b-256k`** with `thinkingDefault: max`
(set 2026-08-21). Chosen for context headroom over speed: 262144 ctx, only
**~60% on GPU**, ~3.4 tok/s, `PONG` in ~2m9s cold. Both
`agents.defaults.timeoutSeconds` and `models.providers.ollama.timeoutSeconds`
are `10800` to match.

Previous defaults: `ollama/qwen3.6-fable:27b-128k` (2026-08-08 — 27 GB resident
at 131072 ctx, 100% GPU, ~48s cold with `thinkingDefault: max`), before that
`ollama/gemma4:26b-a4b-it-q4_K_M`, before that `ollama/qwen3.5:27b`.

Cron jobs inherit this default **unless they set `payload.model`** — see
[Cron jobs and the stuck-session watchdog](#cron-jobs-and-the-stuck-session-watchdog).

The `-128k` variant is chosen deliberately for the agent; the plain
`qwen3.6-fable:27b` tag stays at 64k for every other client. See "Context window
on `qwen3.6-fable:27b`" below for the sizing math and the OOM tradeoff.

**All 12 Ollama models are available to the agent** — `openclaw models list
--provider ollama` shows every one with `Auth: yes`. There is no allowlist to
maintain; new `ollama pull`s appear automatically.

Note this model needs ollama **>= 0.32.x**, which is why `ai/docker-compose.yml`
pins `ollama/ollama:0.32.6-rocm`. Do not roll ollama back below that.

To change:
```bash
docker exec openclaw-gateway openclaw config set agents.defaults.model.primary "ollama/qwen3.6-fable:27b"
# no restart needed — the CLI reports "Change will apply without restarting"
```

**Watch for session pins overriding config.** A session pinned with `/model`
keeps its own model regardless of `agents.defaults.model.primary`.

Two hard-won specifics (2026-08-08):

- **`/reset` does NOT clear a model pin.** It wipes the transcript but leaves
  `modelOverride` / `modelOverrideSource: "user"` in the session store. Cron
  sessions (no override) *do* pick up the new default after `/reset`; a session
  a human pinned by hand does not.
- **`/model` is not handled by the CLI agent path.** `openclaw agent
  --session-key … --message "/model <id>"` silently no-ops and returns nothing —
  tried bare id, `ollama/`-prefixed, and `/model default` (the form `openclaw
  status` itself recommends). `/reset` on that same path works and prints
  `✅ Session reset.`

**The reliable way to clear a stuck pin** (used 2026-08-08 on `agent:main:main`,
which survived every `/model` and `/reset` attempt): patch the store, then
force-recreate so the gateway reloads it.

```bash
docker exec openclaw-gateway node -e "
const fs=require('fs');
const p='/home/node/.openclaw/agents/main/sessions/sessions.json';
fs.copyFileSync(p,p+'.pre-pinfix');
const d=JSON.parse(fs.readFileSync(p,'utf8'));
let rows=Array.isArray(d)?d:(d.sessions||d);
const fix=s=>{ if(s&&s.key==='agent:main:main'){ delete s.modelOverride; delete s.modelOverrideSource; delete s.thinkingLevel; } };
if(Array.isArray(rows)) rows.forEach(fix); else Object.entries(rows).forEach(([k,v])=>{ if(v&&typeof v==='object'){ v.key=v.key||k; fix(v);} });
fs.writeFileSync(p,JSON.stringify(d,null,2));"
docker compose --project-name ai --env-file .env -f ai/docker-compose.yml up -d --force-recreate openclaw-gateway
```

Deleting the keys (rather than setting them) lets the session fall through to
`agents.defaults.*`, which is what you almost always want. **Check
`thinkingLevel` too** — a session pinned to `"off"` silently overrides
`thinkingDefault: max`, and it is easy to fix the model and miss the thinking.
Confirm with `openclaw status`: the "Model selection" block only prints when an
override exists, so its *absence* is the success signal.

Session store: `/home/node/.openclaw/agents/main/sessions/sessions.json`.
Inspect pins without dumping transcripts (there is no `python3` in the
container — use `node`):

```bash
docker exec openclaw-gateway node -e "
const fs=require('fs');const d=JSON.parse(fs.readFileSync('/home/node/.openclaw/agents/main/sessions/sessions.json','utf8'));
let r=Array.isArray(d)?d:(d.sessions||d); if(!Array.isArray(r)) r=Object.entries(r).map(([k,v])=>({key:k,...v}));
for(const s of r) if(s.modelOverride) console.log(s.key, s.modelOverride, s.modelOverrideSource);"
```

**Why this matters:** OpenClaw's built-in fallback default is `openai/gpt-5.5`, which requires an OpenAI API key. Without setting this, agents fail with `401 Unauthorized: Missing bearer or basic authentication, url: https://api.openai.com/v1/responses`.

Available working models (verified 2026-08-08):
- `ollama/qwen3.6-fable:27b` — **current default**, 262k ctx, 100% GPU
- `ollama/gemma4:26b-a4b-it-q4_K_M` — MoE, vision-capable, fast to first token
- `ollama/qwen3-coder:30b` — coding tasks
- `ollama/devstral-small-2:latest` — coding, smaller
- `ollama/gpt-oss:120b` — large, slow
- `claude-cli/claude-sonnet-4-6` — uses local Claude Code CLI session

## Reasoning models & the "LLM idle timeout (120s)" error

### Symptom

Every chat message fails. The Control UI shows what looks like a save/write or
"can't reach the agent" error. The gateway logs show, on each run:

```
[agent/embedded] rawError=LLM idle timeout (120s): no response from model
[llm-idle-timeout] ollama/qwen3.5:27b produced no reply before the idle watchdog; retrying same model
```

This is **not** a file/permissions/disk problem — config and state write fine.

### Root cause

`qwen3.5:27b` is a **reasoning ("thinking") model**. OpenClaw resolves the
thinking level per `docs/tools/thinking.md`; when **no `thinkingDefault` is set**,
reasoning-capable models fall back to `medium`. The model then spends its whole
budget in the hidden `thinking` channel and emits **no visible assistant token**
before OpenClaw's 120s idle watchdog fires → the run is killed and surfaced as an
error.

Proof (same model, direct Ollama `/api/generate`):
- `think: true`  → ~98s and an **empty** `response` (all output went to `thinking`)
- `think: false` → **~0.8s** and a correct `response`

### Fix (historical — superseded 2026-08-08)

The original fix was to disable thinking globally:

```bash
docker exec openclaw-gateway openclaw config set agents.defaults.thinkingDefault off
```

**This is no longer the setting.** As of 2026-08-08 `thinkingDefault` is **`max`**
and the watchdog is handled by raising the *provider* timeout instead — see
"Raising the idle timeout properly" below. Kept because the failure mode above is
still real if the timeout is ever mis-set.

Verify end-to-end without touching the web UI:

```bash
docker exec openclaw-gateway openclaw agent --agent main --session-key smoketest \
  --message "Reply with exactly: pong" --timeout 550
```

### Raising the idle timeout properly (the counterintuitive part)

The resolver is `resolveLlmIdleTimeoutMs` in `dist/selection-*.js`. Order matters:

```js
if (modelRequestTimeoutMs > 0) return clamp(Math.min(modelRequestTimeoutMs, ...bounds));  // provider timeout
if (agentTimeoutMs !== undefined) return clampImplicit(agentTimeoutMs);  // clampImplicit = min(v, 120_000)
if (isLocalRuntimeModel) return 0;                                       // 0 = no watchdog
return DEFAULT_LLM_IDLE_TIMEOUT_MS;                                      // 120s
```

Two traps:

1. **`agents.defaults.timeoutSeconds` is clamped to 120s** for this purpose —
   raising it alone does nothing. Only `models.providers.<id>.timeoutSeconds`
   passes through unclamped, because it is checked first.
2. **`http://ollama:11434` does not count as "local".**
   `isLocalProviderBaseUrl()` accepts `localhost`, `*.local`, and RFC1918 /
   CGNAT **IP literals** only — a bare container hostname fails, so the
   `return 0` (unlimited) path is never reached. `isSelfHostedHostnameRuntimeModel`
   *is* true here (thanks to the `apiKey: "ollama-local"` marker) but is only
   consulted on the **cron** branch.

Current settings: `models.providers.ollama.timeoutSeconds: 1800` and
`agents.defaults.timeoutSeconds: 1800` → effective idle watchdog **1800s**.

### Thinking controls (when you *do* want reasoning)

Full level enum: `off, minimal, low, medium, high, xhigh, adaptive, max, ultra`.

- `/think off | low | medium | high | xhigh | max | ultra`
- `/think` with no arg shows the current level; `/think default` clears a session override

**`max` is the effective ceiling on Ollama, not `ultra`.** The mapping collapses
`max → xhigh → "high"` (`supportsNativeXhighEffort()` is false for Ollama), and
Ollama's native `think` tops out at `"high"`. `ultra` is gated on the
Codex/OpenAI family (`codexSupportsUltra`) and its distinct effect here is
flipping on `proactiveSubagentOrchestration` — that is agent behaviour, **not
deeper reasoning**. Set `max` unless you specifically want subagent orchestration.

One-shot CLI override: `openclaw agent ... --thinking off`.
Resolution order (highest first): inline directive → session override →
`agents.list[].thinkingDefault` → `agents.defaults.thinkingDefault` → provider fallback.

One-shot CLI override: `openclaw agent ... --thinking off`.
Resolution order (highest first): inline directive → session override →
`agents.list[].thinkingDefault` → `agents.defaults.thinkingDefault` → provider fallback.

### Related gotchas

- **Bloated sessions are slow to first token.** A heavy session (e.g. tens of
  thousands of tokens from prior failed retries) can spend 60s+ in
  `session-resource-loader` *before* the model runs, which alone can approach the
  120s watchdog. Start a fresh session / reset the affected one if first replies
  are borderline. Check session weight with `openclaw sessions list` (Tokens column).
- **First-reply latency (~30–80s) on `qwen3.5:27b`** comes from the 27B being
  split across both RX 6700s (10 GB each) over PCIe. It works but is slow; a model
  that fits a single GPU is much faster to first token.
- **`qwen3.6-fable:27b` loads 100% GPU** (~19 GB resident) and answered a trivial
  prompt in ~48s cold *with `thinking: max`*, so the split-across-cards penalty
  above does not apply to it.
- **A Modelfile `PARAMETER num_ctx` overrides `OLLAMA_CONTEXT_LENGTH`** — see
  "Context window on qwen3.6-fable" below. This bit once: the model shipped
  pinned to 16384 while the env said 131072.

## Context window on `qwen3.6-fable:27b`

**A Modelfile `PARAMETER num_ctx` beats `OLLAMA_CONTEXT_LENGTH`.** The model
shipped with `PARAMETER num_ctx 16384` baked in, so it loaded at 16k even though
`ai/docker-compose.yml` sets `OLLAMA_CONTEXT_LENGTH=131072` and OpenClaw
advertises 262k for it. Diagnosed 2026-08-08 from a real chat that failed:

```
task.n_tokens = 19758     ← the conversation
num_ctx       = 16384     ← the window it had
```

Same daemon, same env — gemma4 loaded at 131072 while fable loaded at 16384.
Always check `ollama show <model> --parameters`, not just the env var.

### Sizing: KV is the constraint, and dense models pay full price

Measured from the load logs, **f16 KV = 64 KiB/token** for this model:

```
llama_kv_cache: size = 1024.00 MiB (16384 cells, 16 layers)
llama_context:  n_ctx_seq (16384) < n_ctx_train (262144)
```

Against 32.2 GB of VRAM (3 × 10.72 GB RX 6700), with ~17 GB of weights:

| num_ctx | KV | Total | Verdict |
|---|---|---|---|
| 65,536 | 4 GB | ~22 GB | **chosen** — 10 GB headroom |
| 131,072 | 8 GB | ~27 GB | fits, but only ~5 GB headroom |
| 262,144 (`n_ctx_train`) | 16 GB | ~34 GB | does not fit |
| 1,000,000 | 61 GB | ~78 GB | 2.4× total VRAM, and past `n_ctx_train` anyway |

**Why gemma4 gets 128k cheaply and fable cannot:** gemma4 uses interleaved
sliding-window attention — only 5 of 30 layers hold full-context KV (2560 MiB),
the other 25 use a 2048-cell window (400 MiB), so its whole 128k cache is
~2.9 GB. Fable is dense; every layer pays.

**System RAM does not rescue this.** Ollama will spill to the 251 GiB of DDR4,
but generation is bandwidth-bound: ~200 GB/s theoretical on 8-channel DDR4-3200
vs ~320 GB/s per GPU, and you lose that layer's GPU compute too. And no amount
of RAM raises `n_ctx_train`.

### Benchmark (2026-08-08)

| | VRAM | Processor | Gen | Load |
|---|---|---|---|---|
| 64k | 22 GB | 100% GPU | 14.44 tok/s | **7.4s** |
| 128k | 27 GB | 100% GPU | 14.45 tok/s | **72.9s** |

Identical throughput — 128k only buys a 10× slower load (allocating 8 GB of KV)
and eats the headroom. **64k wins.**

### Tags

`ollama create` over a `FROM <parent>` Modelfile reuses the weight blob — no
re-download, the new tag is just a manifest.

- **`qwen3.6-fable:27b` — num_ctx 65536.** The base tag, so anything that does
  not name a variant (Open WebUI, ad-hoc `/api/generate`) gets 64k with no
  client config.
- `qwen3.6-fable:27b-64k` — same thing under an explicit name
- **`qwen3.6-fable:27b-128k` — num_ctx 131072. This is OpenClaw's default**
  (`agents.defaults.model.primary`), set 2026-08-08 by preference for maximum
  context on the agent. 27 GB resident, ~5 GB headroom — accept the switch-time
  OOM described below as the cost. The benchmark says 64k is the better default
  in the abstract; this is a deliberate override for Claw specifically.

### `OLLAMA_MAX_LOADED_MODELS=1` helps but is not a complete fix

Set in `ai/docker-compose.yml`. Before it, gemma4 (21 GB) and fable (19 GB) both
tried to sit in 32.2 GB under the 60m keep-alive, producing
`cudaMalloc failed: out of memory` + `llama-server terminated (core dumped)`,
recovered ~25s later by retrying with the projector on CPU — which to a chat
client looks like a hang.

**It does not eliminate OOM on its own.** Eviction is asynchronous: `ollama ps`
shows `Stopping...` while the incoming model already begins allocating. With the
27 GB `-128k` variant resident (~5 GB spare) that overlap still OOMs — observed
twice, at 15:37 and 15:48 on 2026-08-08, both
`allocating 2428.16 MiB on device 1`. At 22 GB (the 64k tag) there is ~10 GB of
slack and the overlap survives. **Staying on the 64k tag is the actual fix.**

## Cron jobs and the stuck-session watchdog

Three cron jobs run on agent `main`, all `isolated` sessions announcing to a
Discord DM: a daily tech digest (09:00), a driver check (11:00), and the
**Daily Watchlist Price Check** (09:00 ET, weekdays — 18 stocks, 2 metals,
3 coins).

### Symptom (2026-09 → 2026-10-09)

The watchlist job failed **35 runs in a row** with `AbortError: agent run
aborted`, preceded in the gateway log by:

```
[diagnostic] stuck session recovery: ... age=758s action=abort_embedded_run ... stopped="watchlist_price_check"
```

Its configured failure alert never arrived, so the only sign was the streak in
`openclaw cron list` (`error (35x)`) and a `doctor` warning.

### Root cause — a second watchdog the timeouts don't cover

This is **not** the LLM idle timeout from the section above. OpenClaw also runs
a stuck-session watchdog: `diagnostics.stuckSessionWarnMs` (default 120000) and
`diagnostics.stuckSessionAbortMs`, which falls back to a stalled-run value with
a **5-minute floor** (`MIN_STALLED_EMBEDDED_RUN_ABORT_MS`). Any single model turn
that makes no progress for 5 minutes is aborted, regardless of
`models.providers.ollama.timeoutSeconds = 10800`.

The job pinned its own model (`payload.model = ollama/qwen3.6-fable:27b-128k`,
which does not inherit the default) on partial CPU offload. Each turn
re-prefills the whole growing context, so as search results piled up, turn 1
took 70s, turn 2 took 5m, and turn 3 crossed the floor and was killed. With
`OLLAMA_MAX_LOADED_MODELS=1` the job also evicted the resident default model on
every run.

### Fix (applied 2026-10-09)

```bash
J=ef88a2aa-5a71-4afb-a93e-afb0473b6b46
docker exec openclaw-gateway openclaw cron edit $J \
  --model ollama/gemma4:26b-a4b-it-q4_K_M --thinking off
```

gemma4 is an MoE that loads 100% on GPU, so turns take seconds. The prompt also
gained a final line telling the agent to **do the work itself and not spawn
subagents or yield**: on the first test run gemma4 delegated to a subagent, the
run finished `ok` in 3.2 min, but the subagent's announce hit the retry limit
and the report was `not-delivered`. With the instruction, a run took **71s and
was delivered**.

Preferred over raising `diagnostics.stuckSessionAbortMs`: that knob is global
and would also delay detection of genuinely hung sessions.

**Known residual risk:** gemma4 at 128k leaves only ~0.8 GiB free on GPU0
(6.2 GiB weights + 1.2 GiB KV + 1.3 GiB compute of 9.5 GiB available, before the
vision projector). A run with a very large search payload hit
`ROCm error: out of memory` once (2026-10-10 00:45 UTC); the retry with a smaller
payload passed. Candidate fix: `OLLAMA_GPU_OVERHEAD` on the ollama service so it
reserves headroom and spills a layer to CPU instead of OOMing.

### Diagnosing a failing cron job

```bash
docker exec openclaw-gateway openclaw cron list                     # Status column: error (Nx)
docker exec openclaw-gateway openclaw cron runs --id <job> --limit 3 # status, durationMs, deliveryStatus
docker logs --since 72h openclaw-gateway 2>&1 | grep -E 'stuck session|channel=cron.*outcome='
docker exec openclaw-gateway openclaw cron run <job>                 # manual trigger (enqueues)
```

A `stuck session recovery` line means a slow turn (fix the model or the prompt
size); `deliveryStatus: not-delivered` on an `ok` run usually means the agent
delegated to a subagent whose announce failed.

## Memory search (disabled)

`agents.defaults.memorySearch` defaulted to the **`openai`** embedding provider
with no key, so semantic recall never worked: every watch sync logged
`No API key found for provider "openai"` and `doctor` flagged it. Disabled
2026-10-09:

```bash
docker exec openclaw-gateway openclaw config set agents.defaults.memorySearch.enabled false
docker restart openclaw-gateway
```

Local alternatives considered: the `local` provider needs `node-llama-cpp`
(not shipped in the image); the openai provider pointed at Ollama's
`/v1` with `bge-m3` (already pulled) would work, but with
`OLLAMA_MAX_LOADED_MODELS=1` every memory lookup would evict the chat model.
Revisit if `OLLAMA_MAX_LOADED_MODELS` is raised.

## Updating

The image is now **pinned to `2026.7.1`** in `ai/docker-compose.yml`, so a pull
alone is a no-op — bump the tag in the compose file first, then pull + recreate
just this service:

```bash
# back up config first — updates migrate state (6.6 -> 6.34 moved config health
# to SQLite; 6.34 -> 7.1 moved the Memory Core index to per-agent SQLite)
docker exec openclaw-gateway sh -c 'cp /home/node/.openclaw/openclaw.json /home/node/.openclaw/openclaw.json.pre-update-$(date +%Y%m%d-%H%M%S)'
docker compose --project-name ai --env-file .env -f ai/docker-compose.yml pull openclaw-gateway
docker compose --project-name ai --env-file .env -f ai/docker-compose.yml up -d openclaw-gateway
```

**npm-installed plugins do not update with the image.** They live in the config
volume and will drift behind core. `openclaw doctor` reports this under "Plugin
version drift":

```bash
docker exec openclaw-gateway openclaw plugins update discord
docker exec openclaw-gateway openclaw plugins update whatsapp
docker restart openclaw-gateway
```

After updating, verify with `openclaw doctor` and re-probe channels:
`openclaw channels status --probe` (expect `bot:@Claw … works`).

**`gateway.mode` must be set.** Doctor: "gateway.mode is unset; gateway start
will be blocked." Only `--allow-unconfigured` in the compose command masks this.
Set 2026-07-31: `openclaw config set gateway.mode local`.

## TLS certificate for `claw.arijitroy.com`

The OpenClaw phone/node apps pin the gateway's TLS cert SHA-256
(`gatewayTlsSha256`) when the cert isn't publicly trusted. Caddy's `tls internal`
default is a **12-hour** leaf, which breaks a pinned fingerprint twice a day, so
`infra/Caddyfile` sets a 90-day leaf:

```
claw.arijitroy.com {
    tls {
        issuer internal {
            lifetime 2160h
        }
    }
    reverse_proxy openclaw-gateway:18789
}
```

plus a global `pki { ca local { intermediate_lifetime 8760h } }` — the
intermediate must outlive the leaf and defaults to only 7 days.

**Gotchas, both hit on 2026-07-31:**

- `lifetime` belongs to the **issuer**, not the `tls` directive. `tls internal {
  lifetime … }` passes `caddy reload` but hard-fails on restart with
  `unknown subdirective: lifetime`, crash-looping Caddy.
- Changing lifetimes reissues nothing. Delete
  `/data/caddy/pki/authorities/local/intermediate.{crt,key}` and the host's dir
  under `/data/caddy/certificates/local/`, then restart Caddy. Other vhosts are
  unaffected — each `.crt` bundles the intermediate it was signed with, and the
  root is untouched.
- **`make check` / `make reload-caddy` can validate stale content.** Both run
  inside the container against the bind-mounted Caddyfile; an editor that
  replaces the file's inode leaves the container on the old inode. Validate
  against the host path instead:
  ```bash
  docker run --rm -v "$PWD/infra/Caddyfile:/etc/caddy/Caddyfile:ro" \
    caddy:2-alpine caddy validate --config /etc/caddy/Caddyfile
  ```

Current leaf valid to **2026-10-30**.

## Connecting a phone app over the web (not LAN)

`claw.arijitroy.com` resolves to Cloudflare and is served through the tunnel, so
the phone sees a **publicly trusted cert** (Google Trust Services) — it is never
asked for a SHA-256 fingerprint on this path. The fingerprint prompt only
appears when connecting direct to Caddy by LAN IP.

1. Generate the pairing QR + setup code **in a normal terminal** — the payload
   embeds `OPENCLAW_GATEWAY_TOKEN`, so never run it anywhere the output is
   captured or piped to a model:
   ```bash
   docker exec -it openclaw-gateway openclaw qr --public-url https://claw.arijitroy.com
   ```
2. In the app: **Connect** tab → Setup Code → scan.
3. Approve the pairing request on the gateway:
   ```bash
   docker exec openclaw-gateway openclaw devices list
   docker exec openclaw-gateway openclaw devices approve --latest
   ```
4. Confirm: `openclaw nodes status` should show the phone `paired · connected`.

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

- **CONFIRMED 2026-07-31 — `claw.arijitroy.com` is publicly reachable with no
  Cloudflare Access in front.** An unauthenticated `curl` from the internet
  returns the OpenClaw Control UI with `HTTP 200`; there is no Access redirect.
  Doctor concurs: gateway bound to `0.0.0.0` ("lan"), and `openclaw security
  audit` reports no `gateway.auth.rateLimit`. `OPENCLAW_GATEWAY_TOKEN` is
  currently the *only* control on an agent gateway with elevated exec and
  browser tools. Knowingly deferred; tracked as Tier 4 in `OPENCLAW_PLAN.md`.
  Preferred fix is Tailscale (server is `NeedsLogin`, and OpenClaw's own
  "Tailscale exposure" is off) rather than Access, which complicates the app's
  WebSocket.
- **`--allow-unconfigured`** starts the gateway even with no completed config. Combined with public exposure (`claw.arijitroy.com` is proxied by Caddy and reachable through the Cloudflare Tunnel once the hostname is added), make sure `OPENCLAW_GATEWAY_TOKEN` is set to a strong random value (`openssl rand -hex 32`) and never blank — the token is the only thing standing between the open internet and an agent gateway that can drive Ollama and the local Claude CLI session.
- **`autoApproveCidrs` includes a public IP** (`76.64.143.141/32`). Auto-approving a routable address means anyone who can spoof/originate from it gets first-time node pairing without prompt. Prefer Tailscale CIDRs (`100.64.0.0/10`) or LAN ranges; drop the public entry unless you genuinely need it.
- **Consider Cloudflare Access** in front of `claw.*` so the gateway UI requires SSO, not just the pairing token.
- The `openclaw_auth` volume (`/mnt/cloud_storage/openclaw_auth`) holds provider secrets and pairing tokens — it is included in the host backup path but should never be committed or shared.

## Docs

- Main docs: https://docs.openclaw.ai
- Models: https://docs.openclaw.ai/concepts/models
- Ollama provider: https://docs.openclaw.ai/providers/ollama
