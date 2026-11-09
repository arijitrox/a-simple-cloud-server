#!/usr/bin/env python3
"""homelab-mcp — the AI rack's local models and read-only status as MCP tools.

Transports:
  homelab_mcp.py                      # stdio, for Claude Code on this host
  homelab_mcp.py --http --port 8765   # streamable HTTP, for the remote connector

No shell, no sudo, no writes outside OUT_DIR: the HTTP transport is meant to sit
behind Cloudflare Access, and a leaked endpoint should cost GPU time, not the box.
"""
import argparse
import json
import os
import shutil
import subprocess
import time
from pathlib import Path

import logging

import httpx
from mcp.server.mcpserver import MCPServer

logging.getLogger("httpx").setLevel(logging.WARNING)

OUT_DIR = Path(os.environ.get("HOMELAB_MCP_OUT", "/tmp/homelab-mcp"))
READ_ROOTS = [Path(p) for p in ("/mnt/data_1", "/mnt/data_2", "/mnt/data_3", "/mnt/data_4",
                                "/mnt/data_5", "/mnt/cloud_storage/media", "/home/arijit", str(OUT_DIR))]
PORTS = {"ollama": 11434, "speaches": 8000, "kokoro": 8880}
OPT_IN = {"comfyui"}  # compose profile `comfy`, stopped on purpose (GPU thermals)

mcp = MCPServer(
    name="homelab",
    log_level="WARNING",
    instructions=(
        "Tools for Arijit's homelab AI rack (EPYC 7742, 3x RX 6700). He wants these used to SAVE "
        "CLAUDE TOKENS: delegate bulk drafting, summarising long text/logs, classification, code "
        "sketches, embeddings, transcription and text-to-speech to these local tools first, then "
        "review the output yourself; say when you delegate. Model routing: code -> qwen3-coder:30b; "
        "general text/summaries -> qwen3.8:27b; reasoning drafts -> gpt-oss:20b; second opinion -> "
        "gemma4:26b-a4b-it-q4_K_M; images -> qwen3-vl:8b; trivial/fast -> qwen3:4b; embeddings -> "
        "bge-m3. Never use qwen3.6-fable or qwen2.5-coder:1.5b-base. 27B models run ~3-12 tok/s, so "
        "keep max_tokens modest. Local output can be wrong: verify before relying on it. Never send "
        "secrets, passwords or .env contents to any model."
    ),
)


# --- helpers -----------------------------------------------------------------

def _container_url(name: str) -> str:
    """Resolve a container's current IP on cloud-net (it changes across restarts)."""
    ip = subprocess.run(
        ["docker", "inspect", name, "--format", "{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}"],
        capture_output=True, text=True, timeout=10,
    ).stdout.split()
    if not ip:
        raise RuntimeError(f"container '{name}' is not running")
    return f"http://{ip[0]}:{PORTS[name]}"


def _readable(path: str) -> Path:
    p = Path(path).expanduser().resolve()
    if not any(p == r or r in p.parents for r in READ_ROOTS):
        raise ValueError(f"path not allowed: {p} (allowed under {', '.join(map(str, READ_ROOTS))})")
    if not p.is_file():
        raise FileNotFoundError(p)
    return p


def _run(cmd: list[str], timeout: int = 20) -> str:
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return (r.stdout or r.stderr).strip()
    except Exception as e:  # status is best-effort; one broken probe shouldn't fail the rest
        return f"<{type(e).__name__}: {e}>"


# --- local models ------------------------------------------------------------

@mcp.tool()
def list_models() -> list[dict]:
    """List the Ollama models installed on the rack, with size in GB."""
    tags = httpx.get(_container_url("ollama") + "/api/tags", timeout=30).json()["models"]
    return [{"name": m["name"], "size_gb": round(m["size"] / 1e9, 1),
             "family": m.get("details", {}).get("family"), "params": m.get("details", {}).get("parameter_size")}
            for m in tags]


@mcp.tool()
def ask_model(prompt: str, model: str = "qwen3.8:27b", system: str | None = None,
              think: bool = False, max_tokens: int = 1024, temperature: float = 0.3,
              num_ctx: int = 16384) -> dict:
    """Run a prompt on a local Ollama model and return its reply.

    think: qwen3.x thinking is on/off only (levels are a no-op on this arch); small qwen3:4b
    tends to reason in the reply even with think=False.
    Big contexts on 27B models spill to CPU and get much slower; raise num_ctx only when needed.
    """
    msgs = ([{"role": "system", "content": system}] if system else []) + [{"role": "user", "content": prompt}]
    t0 = time.time()
    r = httpx.post(_container_url("ollama") + "/api/chat", json={
        "model": model, "messages": msgs, "stream": False, "think": think,
        "options": {"temperature": temperature, "num_predict": max_tokens, "num_ctx": num_ctx},
    }, timeout=1800).json()
    if "error" in r:
        raise RuntimeError(r["error"])
    ev, ed = r.get("eval_count", 0), r.get("eval_duration", 0) or 1
    return {"reply": r["message"]["content"], "thinking": r["message"].get("thinking"),
            "model": model, "tokens": ev, "tok_per_s": round(ev / (ed / 1e9), 1),
            "seconds": round(time.time() - t0, 1)}


@mcp.tool()
def embed(texts: list[str], model: str = "bge-m3") -> dict:
    """Embed texts with a local embedding model (default bge-m3, 1024-dim)."""
    r = httpx.post(_container_url("ollama") + "/api/embed", json={"model": model, "input": texts}, timeout=300).json()
    return {"model": model, "dims": len(r["embeddings"][0]) if r.get("embeddings") else 0, "embeddings": r["embeddings"]}


# --- speech ------------------------------------------------------------------

@mcp.tool()
def transcribe(path: str, language: str | None = None,
               model: str = "deepdml/faster-whisper-large-v3-turbo-ct2") -> dict:
    """Speech-to-text for an audio/video file on the server (faster-whisper via Speaches)."""
    p = _readable(path)
    data = {"model": model, **({"language": language} if language else {})}
    with p.open("rb") as fh:
        r = httpx.post(_container_url("speaches") + "/v1/audio/transcriptions",
                       data=data, files={"file": (p.name, fh)}, timeout=3600)
    r.raise_for_status()
    return {"text": r.json()["text"], "file": str(p), "model": model}


@mcp.tool()
def speak(text: str, voice: str = "af_heart", filename: str | None = None, speed: float = 1.0) -> dict:
    """Text-to-speech with Kokoro; writes an mp3 under /tmp/homelab-mcp and returns its path."""
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    name = Path(filename or f"speech-{int(time.time())}.mp3").name  # basename only: no escaping OUT_DIR
    out = OUT_DIR / (name if name.endswith(".mp3") else name + ".mp3")
    r = httpx.post(_container_url("kokoro") + "/v1/audio/speech", json={
        "model": "kokoro", "input": text, "voice": voice, "response_format": "mp3", "speed": speed,
    }, timeout=600)
    r.raise_for_status()
    out.write_bytes(r.content)
    return {"path": str(out), "bytes": len(r.content), "voice": voice}


@mcp.tool()
def list_voices() -> list[str]:
    """List Kokoro TTS voice ids (prefix: a=American, b=British; f/m = female/male)."""
    return [v["id"] for v in httpx.get(_container_url("kokoro") + "/v1/audio/voices", timeout=30).json()["voices"]]


# --- status (read-only) ------------------------------------------------------

def _gpus() -> list[dict]:
    out = []
    for card in sorted(Path("/sys/class/drm").glob("card[0-9]*")):
        dev = card / "device"
        if not (dev / "gpu_busy_percent").exists():
            continue
        hw = next((dev / "hwmon").glob("hwmon*"), None)
        def rd(f, scale=1):
            try: return round(int((hw / f).read_text()) / scale, 1) if hw else None
            except Exception: return None
        out.append({
            "card": card.name, "pci": dev.resolve().name,
            "busy_pct": int((dev / "gpu_busy_percent").read_text()),
            "vram_used_mib": int((dev / "mem_info_vram_used").read_text()) // 1048576,
            "vram_total_mib": int((dev / "mem_info_vram_total").read_text()) // 1048576,
            "edge_c": rd("temp1_input", 1000), "junction_c": rd("temp2_input", 1000), "mem_c": rd("temp3_input", 1000),
            "fan_rpm": rd("fan1_input"), "power_w": rd("power1_average", 1e6),
        })
    return out


@mcp.tool()
def server_status() -> dict:
    """Read-only health snapshot: GPUs, disks, ZFS, containers, failed units, backup timer, uptime."""
    disks = {}
    for m in ["/", *[f"/mnt/data_{i}" for i in range(1, 6)], "/mnt/cloud_storage"]:
        try:
            u = shutil.disk_usage(m)
            disks[m] = {"used_pct": round(u.used / u.total * 100, 1), "free_gb": round(u.free / 1e9)}
        except Exception as e:
            disks[m] = str(e)
    containers = [dict(zip(("name", "status"), l.split("\t", 1)))
                  for l in _run(["docker", "ps", "-a", "--format", "{{.Names}}\t{{.Status}}"]).splitlines() if "\t" in l]
    return {
        "uptime": _run(["uptime", "-p"]),
        "load": os.getloadavg(),
        "mem": _run(["free", "-g"]).splitlines()[1:2],
        "gpus": _gpus(),
        "disks": disks,
        "zfs": _run(["zpool", "status", "-x"]),
        "containers_unhealthy": [c for c in containers if c["name"] not in OPT_IN
                                 and (not c["status"].startswith("Up") or "unhealthy" in c["status"])],
        "containers_up": sum(1 for c in containers if c["status"].startswith("Up")),
        "failed_units": _run(["systemctl", "--failed", "--no-legend", "--plain"]),
        "backup": _run(["systemctl", "show", "cloud-backup.service", "-p", "Result,ExecMainStatus,ExecMainExitTimestamp"]),
    }


# --- remote transport: Cloudflare Access in front, verified here too ---------------
# Caddy also answers on the LAN, so Access at the edge is not enough on its own: every
# HTTP request must carry a Cf-Access-Jwt-Assertion signed for this app, or it gets 403.

def _access_guard(app):
    import jwt  # pyjwt[crypto]
    team = os.environ.get("CF_ACCESS_TEAM_DOMAIN", "").strip()   # e.g. myteam.cloudflareaccess.com
    aud = os.environ.get("CF_ACCESS_AUD", "").strip()            # Access app "Application Audience (AUD) Tag"
    emails = {e.strip().lower() for e in os.environ.get("CF_ACCESS_EMAILS", "").split(",") if e.strip()}
    jwks = jwt.PyJWKClient(f"https://{team}/cdn-cgi/access/certs", cache_keys=True) if team and aud else None

    async def deny(send, why):
        print(f"homelab-mcp: denied: {why}", flush=True)  # -> journalctl -u homelab-mcp
        body = json.dumps({"error": "forbidden", "reason": why}).encode()
        await send({"type": "http.response.start", "status": 403,
                    "headers": [(b"content-type", b"application/json"), (b"content-length", str(len(body)).encode())]})
        await send({"type": "http.response.body", "body": body})

    async def guarded(scope, receive, send):
        if scope["type"] != "http":
            return await app(scope, receive, send)
        if jwks is None:
            return await deny(send, "Access not configured (CF_ACCESS_TEAM_DOMAIN / CF_ACCESS_AUD unset)")
        token = dict(scope["headers"]).get(b"cf-access-jwt-assertion", b"").decode()
        if not token:
            return await deny(send, "missing Cloudflare Access token")
        try:
            key = jwks.get_signing_key_from_jwt(token).key
            claims = jwt.decode(token, key, algorithms=["RS256"], audience=aud, issuer=f"https://{team}")
        except Exception as e:
            return await deny(send, f"invalid Access token: {type(e).__name__}")
        if emails and claims.get("email", "").lower() not in emails:
            return await deny(send, "identity not allowed")
        # buffer the (small) JSON-RPC body so we can log which method/tool ran, then replay it
        chunks, more = [], True
        while more:
            msg = await receive()
            chunks.append(msg.get("body", b""))
            more = msg.get("more_body", False)
        body = b"".join(chunks)
        what = scope.get("method", "?")
        try:
            rpc = json.loads(body) if body else {}
            for m in (rpc if isinstance(rpc, list) else [rpc]):
                what = m.get("method", what)
                if what == "tools/call":
                    what = f"tools/call {m.get('params', {}).get('name')}"
        except Exception:
            pass
        print(f"homelab-mcp: {claims.get('email', '?')}: {what}", flush=True)
        sent = False
        async def replay():
            nonlocal sent
            if not sent:
                sent = True
                return {"type": "http.request", "body": body, "more_body": False}
            return await receive()
        return await app(scope, replay, send)

    return guarded


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--http", action="store_true", help="serve streamable HTTP (Cloudflare Access required)")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--public-host", default=os.environ.get("HOMELAB_MCP_PUBLIC_HOST", "mcp.arijitroy.com"))
    a = ap.parse_args()
    if a.http:
        import uvicorn
        from mcp.server.transport_security import TransportSecuritySettings
        app = mcp.streamable_http_app(
            stateless_http=True,
            transport_security=TransportSecuritySettings(allowed_hosts=[a.public_host, f"{a.public_host}:*"]),
            host=a.host,
        )
        uvicorn.run(_access_guard(app), host=a.host, port=a.port, log_level="warning", proxy_headers=True)
    else:
        mcp.run("stdio")
