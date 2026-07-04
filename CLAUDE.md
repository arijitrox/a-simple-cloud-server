# CLAUDE.md

AI homelab: one `docker compose` stack per subdir (`infra/ ai/ devops/ compute/
media/ monitoring/ homepage/`), shared external `cloud-net` bridge, `.env` at repo
root. Maps: `ARCHITECTURE.md` (how it works), `AI_RACK_SETUP.md` (replication),
`SERVER_LOG.md` (gitignored,
private security state).

## Commands

- `make up` / `down` / `update` / `ps` — lifecycle (order matters: devops before ai)
- `make check` — validate all compose files + Caddyfile; run before any apply
- `make logs s=<stack>` · `make reload-caddy`
- Single stack: `docker compose --project-name <stack> --env-file .env -f <stack>/docker-compose.yml up -d`

## Rules of the road

- **Delegate bulk text/code-sketch work to local models** (token economy):
  `scripts/ollama-agent.sh "prompt"` (default qwen3-coder:30b; `-l` lists models;
  `-m qwen3.5:27b` etc.). Good for: summarizing long logs, drafting boilerplate,
  first-pass doc text. Always review output before using; never pipe `.env` or
  other secrets into any model, local or not.
- `docs/` is gitignored on purpose — local-model output may embed cleartext creds.
- Passwordless sudo is NOT available. For privileged commands, have the user run
  `! <command>` typed into the Claude Code prompt (not a bash terminal, where
  leading `!` negates the exit status and breaks `&&` chains).
- Images: risky services are tag-pinned (open-webui, gitea:1, minio, portainer).
  Bump deliberately, release notes first; never pin open-webui backward
  (forward-only DB migrations).
- Docker-published ports bypass ufw. Only 9000 (MinIO S3) and 11434 (Ollama) may
  be published; everything else goes through Caddy / the tunnel by container name.
