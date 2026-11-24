#!/usr/bin/env bash
# tools/check_artifact_static.py must pass a clean namespace and FAIL on each shape of the 2026-11-23 prod outage.
# Text only, no Godot: the fixtures are directory trees.   bash tests/test_artifact_static.sh
set -uo pipefail
cd "$(dirname "$0")/.."
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fails=0
expect() {   # name want_rc grep_pattern roots...
    local name=$1 want=$2 pat=$3; shift 3
    out="$(python3 -I tools/check_artifact_static.py "$@" 2>&1)"; rc=$?
    if [ "$rc" = "$want" ] && { [ -z "$pat" ] || grep -q -- "$pat" <<<"$out"; }; then echo "  ok   $name"
    else echo "  FAIL $name (rc $rc, wanted $want, /$pat/)"; echo "$out" | sed 's/^/       /'; fails=$((fails + 1)); fi
}
mk() { mkdir -p "$(dirname "$1")"; printf '%s\n' "$2" > "$1"; }

mk "$T/clean/addons/gs_combat/gs_pellet_tracer.gd" 'class_name GSPelletTracer'
mk "$T/clean/addons/gs_combat/gs_pellet_tracer.gd.uid" 'uid://cbebxr4alar6d'
expect "clean tree passes" 0 "ok" "$T/clean"

mk "$T/dup/addons/gs_combat/gs_pellet_tracer.gd.uid" 'uid://cbebxr4alar6d'
mk "$T/dup/addons/dot_combat/dot_pellet_tracer.gd.uid" 'uid://cbebxr4alar6d'
expect "duplicate uid is named" 1 "duplicate uid uid://cbebxr4alar6d" "$T/dup"
expect "dot_ addon dir is named" 1 "stale addon directory addons/dot_combat" "$T/dup"

mk "$T/shell/addons/gs_combat/a.gd.uid" 'uid://aaaa1111'
mk "$T/pack/gs_cloud/game/b.gd.uid" 'uid://aaaa1111'
expect "a clash BETWEEN shell and pack overlay fails" 1 "duplicate uid uid://aaaa1111" "$T/shell" "$T/pack"
expect "the same trees alone pass" 0 "ok" "$T/shell"

mk "$T/cls/addons/gs_x/x.gd" 'class_name DotThing'
expect "Dot* class fails" 1 "Dot\* class DotThing" "$T/cls"

# an exported pck: foo.gd.remap + foo.gd.uid for ONE script is one resource, not a clash
mk "$T/exp/addons/gs_x/x.gd.remap" 'uid="uid://bbbb2222"'
mk "$T/exp/addons/gs_x/x.gd.uid" 'uid://bbbb2222'
expect "remap + uid of one script is not a clash" 0 "ok" "$T/exp"
mk "$T/exp/addons/gs_y/y.gd.remap" 'uid="uid://bbbb2222"'
expect "two remaps of one uid is a clash" 1 "duplicate uid uid://bbbb2222" "$T/exp"

mkdir -p "$T/empty"
expect "an empty root is not a pass" 2 "" "$T/empty"
exit "$fails"
