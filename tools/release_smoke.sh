#!/usr/bin/env bash
# The candidate smoke, run on a GPU box (staging02 via gpu.sh cdp-run; never a browser on this machine), and its verdict
# recorded against the commit SHA for tools/publish_gate.sh --prod to read.
#   tools/release_smoke.sh [--candidate SHA] [--shell-origin URL | --shell DIR] [--build ID] [--only a,b] [--no-record]
#   --candidate SHA   the commit the verdict is recorded against (default HEAD; the gate walks a shell-pin commit back to it)
#   --shell-origin    take the candidate shell from this origin (the dev CDN site the dev channel publishes to) instead of --shell DIR
#   --no-record       print the verdict only (no git note)
# The verdict is the git note `refs/notes/release-smoke` on the SHA: "PASS <n> games ..." or "FAIL ...". The note is local; tools/release.sh
# pushes it. What the smoke asserts is in tools/release_smoke.mjs. Exit: 0 pass, 1 fail, 2 setup, 75 no GPU box free.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
cand="" record=1 pass=()
while [ $# -gt 0 ]; do
  case "$1" in
    --candidate) cand="$2"; shift 2 ;;
    --no-record) record=0; shift ;;
    --shell-origin|--shell|--build|--only|--secs|--content|--games) pass+=("$1" "$2"); shift 2 ;;
    -h|--help) sed -n 2,9p "$0"; exit 0 ;;
    *) echo "release_smoke: unknown argument $1" >&2; exit 2 ;;
  esac
done
sha="$(git -C "$HERE/.." rev-parse "${cand:-HEAD}^{commit}" 2>/dev/null)" || { echo "release_smoke: $cand is not a commit" >&2; exit 2; }
GPU=${GPU_SH:-$HERE/../../gs-bootstrap/tools/gpu.sh}
[ -x "$GPU" ] || GPU=/home/gamedev/godot/gs-bootstrap/tools/gpu.sh
[ -x "$GPU" ] || { echo "release_smoke: gpu.sh not found (set GPU_SH)" >&2; exit 2; }
port=${RELEASE_SMOKE_PORT:-8099}
log="$(mktemp /tmp/release_smoke.XXXXXX.log)"
export GPU_CDP_WAIT=${GPU_CDP_WAIT:-1800}
echo "release_smoke: ${sha:0:12}: waiting for a GPU box with no suite running (staging02, then staging; up to ${GPU_CDP_WAIT} s; log $log)"
timeout "${RELEASE_SMOKE_TIMEOUT:-7200}" "$GPU" cdp-run --serve "$port" -- node "$HERE/release_smoke.mjs" --host-port "$port" "${pass[@]}" 2>&1 | tee "$log" | grep -E "^(PASS|FAIL|   |release_smoke|gpu\.sh)"
rc=${PIPESTATUS[0]}
summary="$(grep -E '^release_smoke: [0-9]+/[0-9]+ games pass' "$log" | tail -1)"
if [ "$rc" -eq 0 ] && [ -n "$summary" ]; then verdict="PASS ${summary#release_smoke: }"; rc=0
elif [ "$rc" -eq 75 ]; then echo "release_smoke: no GPU box free; nothing recorded" >&2; exit 75
elif [ "$rc" -eq 2 ]; then echo "release_smoke: setup problem (see $log); nothing recorded" >&2; exit 2
else verdict="FAIL ${summary#release_smoke: } (exit $rc)"; rc=1; fi
echo "$verdict"
if [ "$record" = 1 ]; then
  git -C "$HERE/.." notes --ref=release-smoke add -f -m "$verdict $(date -u +%FT%TZ)" "$sha" 2>/dev/null \
    && echo "recorded against ${sha:0:12} (refs/notes/release-smoke)"
fi
exit $rc
