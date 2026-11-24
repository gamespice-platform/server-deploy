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

# A native zip: the pck is beside the binary, or (embed_pck) inside it, where the largest member is the binary.
# GODOT is a stub that records which file it was asked to unpack and "unpacks" it to one script, so only the zip handling is judged.
cat > "$T/fakegodot" <<'STUB'
#!/usr/bin/env bash
pck="${@: -2:1}"; out="${@: -1}"
basename "$pck" >> "$UNPACKED"
mkdir -p "$out/addons/gs_x"; echo "$pck" > "$out/_paths.txt"
echo 'class_name GSX' > "$out/addons/gs_x/x.gd"
STUB
chmod +x "$T/fakegodot"
zipcheck() {   # name want_rc pattern unpacked_names zipfile
    : > "$T/unpacked.log"
    out="$(GODOT="$T/fakegodot" UNPACKED="$T/unpacked.log" bash tools/check_artifact_static.sh "$5" 2>&1)"; rc=$?
    got="$(paste -sd, "$T/unpacked.log")"
    if [ "$rc" = "$2" ] && [ "$got" = "$4" ] && { [ -z "$3" ] || grep -q -- "$3" <<<"$out"; }; then echo "  ok   $1"
    else echo "  FAIL $1 (rc $rc, wanted $2, unpacked '$got', wanted '$4')"; echo "$out" | sed 's/^/       /'; fails=$((fails + 1)); fi
}
python3 -I - "$T" <<'PY'
import sys, zipfile
t = sys.argv[1]
with zipfile.ZipFile(t + "/beside.zip", "w") as z:
    z.writestr("tmc.pck", "x" * 10); z.writestr("tmc.x86_64", "y" * 5000)
with zipfile.ZipFile(t + "/embedded.zip", "w") as z:
    z.writestr("tmc.x86_64", "y" * 5000); z.writestr("libfoo.so", "z" * 10); z.writestr("README", "r")
with zipfile.ZipFile(t + "/empty.zip", "w") as z:
    z.writestr("dir/", "")
PY
zipcheck "zip with a pck beside the binary unpacks only the pck" 0 "ok" "tmc.pck" "$T/beside.zip"
zipcheck "zip with an embedded pck unpacks the largest member (the binary)" 0 "ok" "tmc.x86_64" "$T/embedded.zip"
zipcheck "a zip with nothing in it is rc 2" 2 "nothing to check" "" "$T/empty.zip"

mkdir -p "$T/empty"
expect "an empty root is not a pass" 2 "" "$T/empty"
exit "$fails"
