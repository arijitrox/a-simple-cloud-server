#!/bin/bash
#
# purge-secret-history.sh — scrub SERVER_LOG.md (and its leaked credentials)
# out of the entire git history on a fresh mirror, then force-push.
#
# Background: commit c4ed173 committed SERVER_LOG.md with plaintext secrets.
# Untracking the file did NOT remove it from history, and that commit is on the
# public GitHub remote. This rewrites history to remove the blob everywhere.
#
# !!! ROTATE EVERY LEAKED CREDENTIAL FIRST. History rewriting does not un-leak a
#     secret that is already public — clones, forks, and caches keep the old data.
#     See the "CRITICAL" section in SERVER_LOG.md for the rotation checklist.
#
# Usage:
#   scripts/purge-secret-history.sh            # dry run: clone + filter, show result, push NOTHING
#   scripts/purge-secret-history.sh --push     # also force-push rewritten history to all remotes
#
# Requires: git-filter-repo  (pip install git-filter-repo  OR  apt install git-filter-repo)

set -euo pipefail

PATHS_TO_PURGE=("SERVER_LOG.md")
REMOTES=("origin" "github")
WORKDIR="/tmp/secret-purge-$(date +%s)"
DO_PUSH=0
[[ "${1:-}" == "--push" ]] && DO_PUSH=1

log() { echo "[purge] $*"; }
die() { echo "[purge] ERROR: $*" >&2; exit 1; }

command -v git-filter-repo >/dev/null 2>&1 \
  || die "git-filter-repo not found. Install: pip install git-filter-repo"

# Run from the repo root regardless of where the script is called from.
REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
log "Repo: $REPO_ROOT"

# Resolve remote URLs from the working repo so the mirror pushes to the same places.
declare -A REMOTE_URL
for r in "${REMOTES[@]}"; do
  url="$(git -C "$REPO_ROOT" remote get-url "$r" 2>/dev/null || true)"
  [[ -n "$url" ]] || die "remote '$r' not configured in $REPO_ROOT"
  REMOTE_URL[$r]="$url"
  log "remote $r -> $url"
done

# filter-repo wants a fresh clone. Use a bare mirror so ALL refs are rewritten.
log "Mirror-cloning into $WORKDIR ..."
git clone --mirror "$REPO_ROOT" "$WORKDIR" >/dev/null
cd "$WORKDIR"

log "Commits touching the target path(s) BEFORE:"
for p in "${PATHS_TO_PURGE[@]}"; do git log --oneline --all -- "$p" || true; done

FILTER_ARGS=()
for p in "${PATHS_TO_PURGE[@]}"; do FILTER_ARGS+=(--path "$p"); done
log "Running git filter-repo ${FILTER_ARGS[*]} --invert-paths ..."
git filter-repo "${FILTER_ARGS[@]}" --invert-paths --force

log "Commits touching the target path(s) AFTER (should be empty):"
for p in "${PATHS_TO_PURGE[@]}"; do git log --oneline --all -- "$p" || true; done
echo
log "Verify a known leaked string is gone, e.g.:"
log "  git -C $WORKDIR grep -i REDACTED \$(git -C $WORKDIR rev-list --all) || echo CLEAN"

if [[ "$DO_PUSH" -eq 0 ]]; then
  echo
  log "DRY RUN complete. Nothing pushed. Rewritten mirror is at: $WORKDIR"
  log "When satisfied (and AFTER rotating every secret), re-run with --push,"
  log "or push manually:"
  for r in "${REMOTES[@]}"; do
    log "  git -C $WORKDIR push --force '${REMOTE_URL[$r]}' --all && git -C $WORKDIR push --force '${REMOTE_URL[$r]}' --tags"
  done
  exit 0
fi

echo
read -r -p "[purge] Force-push rewritten history to ${REMOTES[*]}? This is irreversible. Type YES: " ans
[[ "$ans" == "YES" ]] || die "aborted by user"

for r in "${REMOTES[@]}"; do
  log "Force-pushing all branches + tags to $r (${REMOTE_URL[$r]}) ..."
  git push --force "${REMOTE_URL[$r]}" --all
  git push --force "${REMOTE_URL[$r]}" --tags
done

echo
log "Done. Next steps:"
log "  - Tell every collaborator to re-clone (old clones still carry the secret)."
log "  - Consider deleting + recreating the public GitHub repo to drop cached views/forks."
log "  - Rotate the Netdata claim key and re-claim the node."
log "  - Re-clone $REPO_ROOT or run 'git filter-repo' there too so your working copy matches."
log "Mirror left at $WORKDIR — delete it once verified: rm -rf $WORKDIR"
