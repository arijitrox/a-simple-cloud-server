#!/usr/bin/env bash
# One-shot task delegation to a local Ollama model.
#
# Usage:
#   ollama-agent.sh "review this: $(cat file.py)"
#   echo "prompt" | ollama-agent.sh
#   ollama-agent.sh -m qwen3.5:27b -t 0.7 "brainstorm names for X"
#   ollama-agent.sh -l                      # list available models
#
# Env overrides: OLLAMA_HOST, OLLAMA_MODEL
set -euo pipefail

HOST="${OLLAMA_HOST:-http://192.168.2.84:11434}"
MODEL="${OLLAMA_MODEL:-qwen3-coder:30b}"
TEMP="0.2"
CTX="8192"

while getopts "m:t:c:lh" opt; do
  case "$opt" in
    m) MODEL="$OPTARG" ;;
    t) TEMP="$OPTARG" ;;
    c) CTX="$OPTARG" ;;
    l) curl -s "$HOST/api/tags" | python3 -c \
         "import json,sys; [print(f\"{m['name']:40s} {m['size']/1e9:5.1f} GB\") for m in json.load(sys.stdin)['models']]"
       exit 0 ;;
    h) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) exit 1 ;;
  esac
done
shift $((OPTIND - 1))

if [ $# -gt 0 ]; then
  PROMPT="$*"
else
  PROMPT="$(cat)"
fi

export PROMPT MODEL TEMP CTX HOST
python3 - <<'EOF'
import json, os, sys, urllib.request

req = urllib.request.Request(
    os.environ["HOST"] + "/api/generate",
    data=json.dumps({
        "model": os.environ["MODEL"],
        "prompt": os.environ["PROMPT"],
        "stream": False,
        "options": {
            "temperature": float(os.environ["TEMP"]),
            "num_ctx": int(os.environ["CTX"]),
        },
    }).encode(),
    headers={"Content-Type": "application/json"},
)
resp = json.load(urllib.request.urlopen(req, timeout=600))
print(resp["response"])
ev, ed = resp.get("eval_count", 0), resp.get("eval_duration", 1)
print(f"\n[{os.environ['MODEL']}: {ev} tokens, {ev / (ed / 1e9):.0f} tok/s]", file=sys.stderr)
EOF
