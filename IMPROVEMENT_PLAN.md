# Improvement Plan

Findings from a full review of the repo on 2026-07-02: every compose file, the
Makefile, `scripts/backup.sh`, the Caddyfile, the systemd units, and the docs.
Ordered by what actually protects you: P0 = data loss, P1 = who can reach root on
this host, P2 = day-2 operations, P3 = hygiene. Each item names the file to touch.

## Status (2026-07-03, evening)

- **Done:** 0.1–0.6, 1.2, 2.1 (pins + manifest/prune; diun deferred until an alert
  channel exists), 2.2 (healthchecks; `depends_on` deliberately left
  `service_started` — soft deps must not block the chat UI), 2.3, 2.4, P3.
  Systemd units installed + enabled; `HEALTHCHECK_URL` set; first local snapshot
  `0588bbe1` (19.8 GiB, includes jellyfin/openclaw/caddy_data + staging dumps).
- **0.7 (found during 0.6's first run) — two backup.sh bugs, both fixed:**
  - Gitea dump streamed through `docker exec` stdout arrived truncated (1.0K zip,
    no DB). Now dumps to a file in-container, `docker cp`s it out, and aborts the
    run if the zip is <64K.
  - The Google Drive copy used pre-restic-0.14 flags (`--repo2`/`--password2`,
    unknown in restic 0.17) — every offsite copy would have failed. Now
    `copy --from-repo` + `RESTIC_FROM_PASSWORD`. The failure did ping the
    healthcheck `/fail` URL, so the dead-man's-switch is proven live.
- **Open — owner actions only:**
  1. Re-run to verify the fixes end-to-end (first gdrive upload is ~7 GiB):
     `sudo systemctl start --no-block cloud-backup.service`
  2. 1.1: remove `port`/`jupyter`/`monitor` hostnames from the tunnel
     (dash.cloudflare.com → Zero Trust → Tunnels), or gate with Access — all
     four probes still answer publicly as of tonight.
  3. After the first fully green run: delete
     `/mnt/cloud_storage/webui-db-pre-v0.10.2.sql.gz`.

### 0.6 (found during execution) — systemd units were never installed
`cloud-backup.timer` and `cloud-stack.service` existed only in the repo, not in
`/etc/systemd/system` — the restic repo held a single snapshot from May 1, meaning
**no backups ran for two months** and boot survival relied solely on Docker restart
policies. Fix: install + enable both units, run an immediate backup. The
dead-man's-switch (0.2) exists to make this class of failure loud; `HEALTHCHECK_URL`
still needs to be set for it to work.

---

## P0 — Data safety

### 0.1 Backup misses stateful volumes — `scripts/backup.sh`
The restic run covers gitea/webui/minio/pipelines/jupyter/searxng but **not**:

- `/mnt/cloud_storage/jellyfin_config` — metadata, users, watch state; days to rebuild.
- `/mnt/cloud_storage/openclaw_config` + `openclaw_auth` — hand-built agent config
  and auth profiles.
- `/mnt/cloud_storage/caddy_data` — the internal CA; losing it means re-trusting
  certs on every LAN/Tailscale client.

Also: `--exclude /mnt/cloud_storage/ollama_models` is a no-op (that path was never in
the include list) — remove it so the script doesn't imply protection it isn't giving.

### 0.2 Backups fail silently — `scripts/backup.sh` + `cloud-backup.service`
The timer fires at 03:00, output goes to the journal, and nothing alerts on failure
(`cloud-backup.service` has no `OnFailure=`). The repo's integrity is also never
verified — a backup first tested at restore time is not a backup.

- Ping a dead-man's-switch at script end: `curl -fsS https://hc-ping.com/<uuid>` on
  success, `…/fail` in an `ERR` trap (healthchecks.io free tier, or self-hosted ntfy).
  This catches both "script failed" and "timer never fired".
- Add a weekly `restic -r "$LOCAL_REPO" check --read-data-subset=5%`.

### 0.3 Gitea's SQLite is snapshotted while live — `scripts/backup.sh`
`gitea_data` is copied while Gitea runs; a write mid-snapshot can leave a corrupt DB
(issues, users, PRs — the repos themselves are plain git and usually survive). Given
Gitea now holds the *only* full history of this repo post-purge, this matters.
Dump consistently into `$STAGING` before the restic run:

```
docker exec -u 1000 gitea gitea dump -c /data/gitea/conf/app.ini -f - > "$STAGING/gitea-dump.zip"
```

(or minimally `sqlite3 …/gitea.db ".backup …"`.)

### 0.4 Cold boot starts Open WebUI before its database — `Makefile`
`up` order is `infra → homepage → media → ai → devops → …`, but `ai/open-webui` has
`DATABASE_URL` pointing at `postgres` in the **devops** stack. `cloud-stack.service`
boots via `make up`, so every reboot open-webui crash-loops until devops arrives.
The restart policy eventually heals it, but it's noise and delay for no reason.
**Fix:** move `devops` above `ai` in `up` (mirror in `down` and `update`).

### 0.5 Stale pre-rotation secrets on disk — `.env.bak.20260614-165906`
Gitignored, but it holds the credentials from before the June rotation. The rotation
is complete; delete it (`shred -u` if you're feeling thorough).

---

## P1 — Attack surface

### 1.1 Remote-code-execution surfaces are publicly tunneled — Cloudflare dashboard
Three public hostnames are effectively root-on-host behind a single login page:

- `port.arijitroy.com` — Portainer holds `docker.sock`; a compromised session is root.
- `jupyter.arijitroy.com` — arbitrary code execution with GPU devices and
  `seccomp:unconfined`, guarded only by a static token.
- `monitor.arijitroy.com` — Netdata with `SYS_ADMIN` and read-only `docker.sock`.

**Fix:** either remove these three from the tunnel and reach them Tailscale-only via
Caddy (the `ollama.arijitroy.com` pattern already in the Caddyfile), or put
Cloudflare Access (free, email OTP) in front of them. `storage.arijitroy.com`
(MinIO console) is a lesser but similar case — Access is cheap insurance there too.

### 1.2 Host-published ports bypass ufw — every `docker-compose.yml`
Already flagged in ARCHITECTURE.md §2: Docker publishes 3000, 8080, 8880, 8000,
9099, 3001/2222, 9000/9001, 8888, 9443/9002, 18789, 8096, 11434 straight past the
firewall. Both entry paths (cloudflared and Caddy) reach services over `cloud-net`
by container name, so most of these mappings serve nothing.

**Fix, one stack at a time, verifying the Caddy hostname after each:**
- Keep and pin to the LAN IP: `192.168.2.84:11434:11434` (VS Code Continue talks to
  Ollama directly) and `2222` if you use Gitea SSH remotes.
- Delete the `ports:` block everywhere else (open-webui, searxng, kokoro, speaches,
  pipelines, gitea 3001, minio, jupyter, portainer, openclaw, jellyfin — all have a
  Caddy route or are internal-only).

---

## P2 — Day-2 robustness

### 2.1 `make update` is a fleet-wide gamble — `Makefile` + compose files
Everything runs `:latest`; one command pulls new majors for ~15 services with no
record of what was running before, so there is no rollback path. Pragmatic homelab
fix, not full pinning:

- Pin the services where a surprise major hurts: `gitea:1`, a known-good
  `open-webui` tag (its breaking changes are frequent), `portainer-ce:2` —
  `postgres:16-alpine` and `caddy:2-alpine` are already right.
- Run **diun** (or watchtower in notify-only mode) so image updates become a
  decision, not a side effect.
- Have `update` log `docker images --digests` to a file first — a poor man's
  rollback reference — and end with `docker image prune -f` (unpruned pulls will
  eat the NVMe over time).

### 2.2 No healthchecks anywhere — compose files
`depends_on` without conditions only orders container *creation*. Add
`healthcheck:` to postgres (`pg_isready`), open-webui (`curl /health`), ollama
(`ollama ls`), kokoro/speaches (HTTP 200), then upgrade intra-stack `depends_on` to
`condition: service_healthy`. (Cross-stack ordering is 0.4 — a Makefile problem.)

### 2.3 No memory limits — compose files
One leaking container (a runaway notebook, an Open WebUI RAG job, 8 speaches
workers) can OOM the host and take Ollama down with it. Add `mem_limit` to the
usual suspects: jupyter 16g, open-webui 8g, speaches 8g, searxng/redis 1g. Leave
ollama unlimited — it's the workload the box exists for.

### 2.4 Broken and missing Makefile plumbing — `Makefile`
- `make logs` is **broken today** (`no configuration file provided` — there's no
  compose file at the root). Replace with a parameterized target:
  `make logs s=ai` → `$(call compose,$(s)) logs -f --tail=50`.
- Add `make check`: `docker compose … config -q` for every stack plus
  `docker exec caddy caddy validate --config /etc/caddy/Caddyfile` — catches YAML
  and `${VAR}` interpolation errors *before* they hit the live stack.
- Add `make reload-caddy` (`docker exec caddy caddy reload …`) — the Caddyfile is
  mounted read-only and edits currently require remembering the exec incantation.
- `logs` is also missing from `.PHONY`.

---

## P3 — Hygiene

- **Jupyter reproducibility** — `compute/docker-compose.yml` runs
  `pip install jupyterlab` on every start: slow boots, unpinned, breaks offline.
  Replace with a two-line Dockerfile (`FROM rocm/pytorch:latest` +
  `RUN pip install jupyterlab`) built locally.
- **Speaches tuning** — `WHISPER__CPU_THREADS=4` with `NUM_WORKERS=8` optimizes for
  8 concurrent transcriptions that a single-user homelab never sees. Invert it:
  1–2 workers × 16 threads for lower per-request latency on the EPYC.
- **Root clutter** — `calculate_pi.py`, `gpu_pi.py`, `pytorch_test.py` (GPU smoke
  tests → `scripts/` or delete), `get-docker.sh` (vendored installer → delete,
  document the curl in AI_RACK_SETUP.md), and an empty root-owned `Caddyfile/`
  *directory* at the repo root (artifact of an old bind-mount typo → `sudo rmdir`).
- **Uncommitted work** — the speaches STT addition in `ai/docker-compose.yml` is
  live but not committed; commit it (with the uid-1000 chown + model-pull gotchas
  in the message) before it gets tangled up with the changes above.

---

## Suggested sessions

| # | Items | Risk | Touches running services? |
|---|---|---|---|
| 1 | commit speaches; 0.1, 0.2, 0.4, 0.5 | none | no — script/Makefile/cleanup only |
| 2 | 0.3, 2.4 | low | no |
| 3 | 1.1, then 1.2 stack-by-stack | medium | yes — verify each hostname after |
| 4 | 2.1, 2.2, 2.3 | low | yes — rolling restarts |
| 5 | P3 | none | jupyter + speaches only |
