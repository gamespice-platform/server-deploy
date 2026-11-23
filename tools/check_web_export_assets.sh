#!/usr/bin/env bash
# A web export must carry every local script its pages load, under the names the pages use.
#
#   tools/check_web_export_assets.sh [web/build]
#
# 2026-11-23 (hungario solo on dev): a web/build exported before the dot -> gs rename held dot_web.js and
# dot_audio_ceiling.js beside an embed.html that loads gs_web.js and gs_audio_ceiling.js. Both 404ed, the shell never
# got past the engine banner and a solo check timed out with no content request. Run after `./server export-web`
# (dev-shell.sh does); exit 1 names each missing file or leftover dot_ file. Needs no browser, no engine.
set -euo pipefail
cd "$(dirname "$0")/.."
build=${1:-web/build}
[ -d "$build" ] || { echo "error: $build is not a directory (run ./server export-web)" >&2; exit 2; }
fail=0
for page in embed.html index.html; do
    [ -f "$build/$page" ] || continue
    while read -r src; do
        case $src in http:*|https:*|//*|data:*) continue ;; esac
        [ -f "$build/${src%%[?#]*}" ] || { echo "FAIL $build/$page loads $src, not in the export" >&2; fail=1; }
    done < <(grep -o '<script[^>]*src="[^"]*"' "$build/$page" | sed 's/.*src="//; s/"$//')
done
for f in "$build"/dot_*; do
    [ -e "$f" ] || continue
    echo "FAIL $f is a pre-rename leftover (stale export): re-export into a clean web/build" >&2; fail=1
done
[ "$fail" = 0 ] && echo "web export assets ok: $build"
exit "$fail"
