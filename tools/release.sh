#!/usr/bin/env bash
# The batched prod release as one command: candidate = origin/main's head, smoke it on a GPU box, publish the verdict, run the
# prod gate on it, and stop with the exact tag step. It never tags and never pushes a tag (the release owner does that).
#   tools/release.sh [--candidate SHA] [--shell-origin URL] [--skip-smoke] [--dry-run]
#   --skip-smoke   reuse the note already recorded for the candidate (the gate still refuses without a PASS)
#   --dry-run      run the smoke and the gate, push nothing
# Steps: 1 fetch + candidate  2 release_smoke.sh (records a note)  3 push refs/notes/release-smoke  4 publish_gate.sh --prod <sha>
#        5 print: gh workflow run web-shell.yml / native-shell.yml -f candidate=<sha>, then the v* tag for release.yml.
# Exit: 0 all gates green (the next step is printed), 1 smoke or gate refused (named), 2 setup.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; cd "$HERE/.."
cand="" skip=0 dry=0 smoke=()
while [ $# -gt 0 ]; do
  case "$1" in
    --candidate) cand="$2"; shift 2 ;;
    --shell-origin) smoke+=(--shell-origin "$2"); shift 2 ;;
    --skip-smoke) skip=1; shift ;;
    --dry-run) dry=1; shift ;;
    -h|--help) sed -n 2,9p "$0"; exit 0 ;;
    *) echo "release: unknown argument $1" >&2; exit 2 ;;
  esac
done
git fetch -q origin main "+refs/notes/release-smoke:refs/notes/release-smoke" 2>/dev/null || git fetch -q origin main || { echo "release: cannot fetch origin" >&2; exit 2; }
sha="$(git rev-parse "${cand:-origin/main}^{commit}")" || exit 2
[ -z "$cand" ] || [ "$sha" = "$(git rev-parse origin/main)" ] || echo "release: note, $cand is not origin/main's head (web-shell.yml will refuse it)" >&2
echo "release: candidate ${sha:0:12}"
if [ "$skip" = 0 ]; then
  tools/release_smoke.sh --candidate "$sha" "${smoke[@]}" || { echo "release: REFUSED, the candidate smoke did not pass" >&2; exit 1; }
fi
if [ "$dry" = 0 ]; then
  git push -q origin "refs/notes/release-smoke:refs/notes/release-smoke" || { echo "release: cannot push refs/notes/release-smoke" >&2; exit 2; }
fi
tools/publish_gate.sh --prod "$sha" || { echo "release: REFUSED by the prod gate" >&2; exit 1; }
cat <<EOT
release: ${sha:0:12} is clear. Next (the release owner):
  gh workflow run web-shell.yml -f candidate=$sha      # builds, gates, publishes the shell and pins web/shell-build
  gh workflow run native-shell.yml -f candidate=$sha   # native clients
  then tag the pin commit v0.1.N (release.yml re-runs the gate with --prod-tag)
EOT
