#!/usr/bin/env bash
# Exercise the vLLM OpenAI server and show what it actually buys you.
#
# The headline vLLM feature is *continuous batching*: concurrent requests are
# fused into one running batch instead of queued back-to-back, so aggregate
# throughput climbs with concurrency while per-request latency barely moves.
# That is the thing this script measures — a single-request tok/s number tells
# you nothing about vLLM.
#
# Usage:
#   vllm-bench.sh              # full run: info, single, concurrency sweep, metrics
#   vllm-bench.sh info         # served model + engine config
#   vllm-bench.sh single       # one completion, latency + tok/s
#   vllm-bench.sh concurrency  # 1/2/4/8/16 parallel, aggregate throughput
#   vllm-bench.sh metrics      # key Prometheus counters
#
# Env: VLLM_HOST (override endpoint), VLLM_TOKENS (default 64)
#
# Endpoint resolution: the vllm stack deliberately publishes NO host port (repo
# rule: only 9000 and 11434 may bypass ufw), so http://localhost:8000 does NOT
# work from the host. We resolve the container's cloud-net IP instead, which the
# host can reach over the bridge. Set VLLM_HOST to override.
set -euo pipefail

TOKENS="${VLLM_TOKENS:-64}"

resolve_host() {
  if [ -n "${VLLM_HOST:-}" ]; then echo "$VLLM_HOST"; return; fi
  local ip
  ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' vllm 2>/dev/null || true)
  if [ -n "$ip" ]; then echo "http://$ip:8000"; return; fi
  echo "http://localhost:8000"
}
HOST="$(resolve_host)"
PROMPT="Explain what continuous batching means for an inference server, briefly."

need() { command -v "$1" >/dev/null || { echo "missing: $1" >&2; exit 1; }; }
need curl; need python3

model_id() {
  curl -sf "$HOST/v1/models" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"][0]["id"])'
}

cmd_info() {
  echo "== served models =="
  curl -sf "$HOST/v1/models" | python3 -m json.tool
}

# One request. Reports wall time and generation rate from vLLM's own usage block.
cmd_single() {
  local m; m=$(model_id)
  echo "== single request ($m, ${TOKENS} tokens) =="
  local t0 t1
  t0=$(date +%s.%N)
  local out
  out=$(curl -sf "$HOST/v1/chat/completions" -H 'Content-Type: application/json' -d "$(
    python3 -c 'import json,sys; print(json.dumps({"model":sys.argv[1],"messages":[{"role":"user","content":sys.argv[2]}],"max_tokens":int(sys.argv[3]),"temperature":0}))' "$m" "$PROMPT" "$TOKENS"
  )")
  t1=$(date +%s.%N)
  echo "$out" | python3 -c "
import json,sys
d=json.load(sys.stdin); u=d.get('usage',{})
el=$t1-$t0
print(f\"  prompt={u.get('prompt_tokens')} completion={u.get('completion_tokens')} elapsed={el:.2f}s  {u.get('completion_tokens',0)/el:.1f} tok/s\")
print('  text:', d['choices'][0]['message']['content'][:110].replace(chr(10),' '))
"
}

# The real demonstration: fire N requests at once, measure aggregate throughput.
# If batching works, total tok/s rises with N well past the single-request rate.
cmd_concurrency() {
  local m; m=$(model_id)
  echo "== concurrency sweep ($m, ${TOKENS} tokens each) =="
  printf "  %-6s %-10s %-14s %-12s\n" "N" "wall(s)" "total tok/s" "per-req tok/s"
  for n in 1 2 4 8 16; do
    local t0 t1 tmp
    tmp=$(mktemp -d)
    t0=$(date +%s.%N)
    for i in $(seq 1 "$n"); do
      # DISTINCT prompt per request. vLLM runs with enable_prefix_caching=True,
      # so firing N copies of one prompt would let requests 2..N hit the prefix
      # cache and report throughput that batching did not actually earn. The
      # unique prefix defeats that and keeps the number honest.
      local body
      body=$(python3 -c 'import json,sys; print(json.dumps({"model":sys.argv[1],"messages":[{"role":"user","content":f"(req {sys.argv[4]}) "+sys.argv[2]}],"max_tokens":int(sys.argv[3]),"temperature":0}))' "$m" "$PROMPT" "$TOKENS" "$RANDOM-$i")
      curl -sf "$HOST/v1/chat/completions" -H 'Content-Type: application/json' -d "$body" > "$tmp/$i.json" &
    done
    wait
    t1=$(date +%s.%N)
    python3 -c "
import json,glob,sys
tot=0
for f in glob.glob('$tmp/*.json'):
    try: tot+=json.load(open(f)).get('usage',{}).get('completion_tokens',0)
    except Exception: pass
el=$t1-$t0
print(f'  {$n:<6} {el:<10.2f} {tot/el:<14.1f} {tot/el/$n:<12.1f}')
"
    rm -rf "$tmp"
  done
  echo "  (total tok/s climbing with N = continuous batching working; per-req tok/s
   falls because one CPU is shared across more concurrent decodes)"
}

cmd_metrics() {
  echo "== key metrics =="
  curl -sf "$HOST/metrics" | grep -E "^vllm:(num_requests_(running|waiting)|prompt_tokens_total|generation_tokens_total|gpu_cache_usage_perc|kv_cache_usage_perc)" || \
    echo "  (no matching counters yet — send traffic first)"
}

case "${1:-all}" in
  info)        cmd_info ;;
  single)      cmd_single ;;
  concurrency) cmd_concurrency ;;
  metrics)     cmd_metrics ;;
  all)         cmd_info; echo; cmd_single; echo; cmd_concurrency; echo; cmd_metrics ;;
  *) echo "usage: $0 [info|single|concurrency|metrics|all]" >&2; exit 1 ;;
esac
