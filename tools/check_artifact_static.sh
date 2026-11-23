#!/usr/bin/env bash
# Static gate on a BUILT shell artifact: no dot_* addons, classes or scripts, and no uid:// claimed twice across the shell
# and any pack overlay (the 2026-11-23 prod outage; tools/artifact_boot_smoke.sh has the story).
#
#   heavy -- tools/check_artifact_static.sh INPUT [INPUT...]
#     INPUT  a shell .pck (web index.pck, or the native pck), a native shell .zip (its pck is taken out), or a directory
#            (an install tree, or an unpacked game pack: tools/pack_fetch.py in gs-cloud writes those). All inputs are ONE
#            res:// namespace, so list the shell first and a pack after it to catch a clash between the two.
#   Exit 0 clean, 1 a finding (ERROR: lines say which), 2 could not read an input. GODOT picks the engine.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
G="${GODOT:-godot}"
[ $# -gt 0 ] || { sed -n '2,10p' "${BASH_SOURCE[0]}"; exit 2; }
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
roots=(); n=0
# An empty project: with --path at a checkout, res:// would list that checkout beside the pck.
mkdir -p "$W/empty" && printf 'config_version=5\n' > "$W/empty/project.godot"
unpack() {   # pck -> a directory under $W
    local out="$W/r$n"; n=$((n + 1)); mkdir -p "$out"
    timeout 300 "$G" --headless --path "$W/empty" --script "$HERE/tools/artifact_unpack.gd" -- "$1" "$out" >"$W/unpack.log" 2>&1 \
        && [ -s "$out/_paths.txt" ] || { echo "check_artifact_static: could not unpack $1" >&2; tail -5 "$W/unpack.log" >&2; exit 2; }
    roots+=("$out")
}
for in in "$@"; do
    [ -e "$in" ] || { echo "check_artifact_static: $in does not exist" >&2; exit 2; }
    case "$in" in
        *.zip) python3 -I -c 'import sys,zipfile; z=zipfile.ZipFile(sys.argv[1]); p=[i for i in z.namelist() if i.endswith(".pck")]
assert p, "no pck in the zip"; [z.extract(i, sys.argv[2]) for i in p]' "$in" "$W/zip$n" || { echo "check_artifact_static: no pck in $in" >&2; exit 2; }
               for p in "$W"/zip$n/*.pck; do unpack "$p"; done ;;
        *.pck) unpack "$in" ;;
        *) [ -d "$in" ] && roots+=("$in") || { echo "check_artifact_static: $in is not a pck, zip or directory" >&2; exit 2; } ;;
    esac
done
python3 -I "$HERE/tools/check_artifact_static.py" "${roots[@]}"
