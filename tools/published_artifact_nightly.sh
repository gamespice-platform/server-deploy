#!/usr/bin/env bash
# Nightly drift check: the CURRENTLY PUBLISHED prod shell and packs, judged the way a release is (tools/check_artifact_static.sh
# on the published web shell's pck, tools/artifact_boot_smoke.sh on every published game). Catches what no release check can:
# a shell or pack that was fine when published and is not now (a lock bump, a re-installed addon, a stale dir on a server).
#
#   heavy -- tools/published_artifact_nightly.sh [--origin URL] [--only id,id] [--tree DIR] [--from-tag TAG] [--no-report]
#   --from-tag TAG also boots every game on a tree installed at TAG and then upgraded in place to this checkout the way a
#   Pterodactyl reinstall does (git reset, setup.sh --no-games --update): the prod 2026-11-24 outage was a stale zee-dot-weapons
#   link that only an upgraded tree has, which a fresh install never shows.
#   Exit 0 clean, 1 a finding, 2 could not run. Reports a finding to the nightly board (`nightly add`) unless --no-report.
#
# Scheduled by .github/workflows/published-artifact-nightly.yml, and by the fleet watchdog on the dev box (hv fleet-watchdog
# runs this line in its nightly list; the exit code is its signal).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ORIGIN="https://content.gamespice.net/content"; PASS=(); REPORT=1; TREE="$HERE"; FROM_TAG=""
while [ $# -gt 0 ]; do
    case $1 in
        --origin) ORIGIN="${2:?}"; PASS+=(--origin "$2"); shift 2 ;;
        --only) PASS+=(--only "${2:?}"); shift 2 ;;
        --tree) TREE="${2:?}"; shift 2 ;;
        --from-tag) FROM_TAG="${2:?}"; shift 2 ;;
        --no-report) REPORT=0; shift ;;
        *) echo "published_artifact_nightly: unknown argument $1" >&2; exit 2 ;;
    esac
done
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
root="${ORIGIN%/content}"
# The shell pointer, then the engine pck it names, found the way the browser finds it: through embed.html.
latest="$(curl -fsS --max-time 30 "$root/godot/latest.json")" || { echo "published_artifact_nightly: no $root/godot/latest.json" >&2; exit 2; }
build="$(python3 -I -c 'import json,sys; print(json.load(sys.stdin)["build"])' <<<"$latest")" || exit 2
embed="$(curl -fsS --max-time 30 "$root/godot/$build/embed.html")" || { echo "published_artifact_nightly: no embed.html for build $build" >&2; exit 2; }
pck="$(grep -oE '\.\./engine/[0-9a-f]+/index\.pck|engine/[0-9a-f]+/index\.pck' <<<"$embed" | head -1)"
[ -n "$pck" ] || { echo "published_artifact_nightly: embed.html of $build names no engine pck" >&2; exit 2; }
curl -fsS --max-time 600 -o "$W/index.pck" "$root/godot/${pck#../}" || { echo "published_artifact_nightly: cannot fetch $pck" >&2; exit 2; }
rc=0; out="$W/out.txt"
echo "== published shell $build ($pck)" | tee "$out"
"$HERE/tools/check_artifact_static.sh" "$W/index.pck" 2>&1 | tee -a "$out"; [ "${PIPESTATUS[0]}" = 0 ] || rc=1
echo "== published games on $ORIGIN" | tee -a "$out"
"$HERE/tools/artifact_boot_smoke.sh" --tree "$TREE" "${PASS[@]}" --origin "$ORIGIN" --keep "$W/boot" 2>&1 | tee -a "$out"; [ "${PIPESTATUS[0]}" = 0 ] || rc=1
if [ -n "$FROM_TAG" ]; then
    echo "== published games on a tree upgraded in place from $FROM_TAG" | tee -a "$out"
    OLD="$W/upgraded"
    if git clone -q --depth 1 --branch "$FROM_TAG" "$(git -C "$HERE" remote get-url origin)" "$OLD" >>"$out" 2>&1 \
        && git -C "$OLD" fetch -q --depth 1 "$HERE" HEAD && git -C "$OLD" reset -q --hard FETCH_HEAD \
        && (cd "$OLD" && ./setup.sh --no-games --update ${GODOT:+--godot "$GODOT"}) >>"$out" 2>&1; then
        "$HERE/tools/artifact_boot_smoke.sh" --tree "$OLD" "${PASS[@]}" --origin "$ORIGIN" --keep "$W/boot-upgraded" 2>&1 | tee -a "$out"; [ "${PIPESTATUS[0]}" = 0 ] || rc=1
    else
        echo "published_artifact_nightly: could not build the tree upgraded from $FROM_TAG" | tee -a "$out"; rc=1
    fi
fi
# One standing board item collects the findings: a note per red night, so the history is the item's.
if [ "$rc" != 0 ] && [ "$REPORT" = 1 ] && command -v nightly >/dev/null 2>&1; then
    KEY=published-artifact-drift
    nightly show "$KEY" >/dev/null 2>&1 || nightly add --key "$KEY" --kind issue --top --by nightly \
        --title "Published shell or pack fails the artifact gate" --repos gs-server-deploy \
        --body "tools/published_artifact_nightly.sh found the published prod shell or a published game broken. Fix, republish, close." >/dev/null 2>&1
    nightly note "$KEY" --by nightly "$(date -u +%F): $(head -c 3000 "$out")" >/dev/null 2>&1 \
        || echo "published_artifact_nightly: could not report to nightly" >&2
fi
exit "$rc"
