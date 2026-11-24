#!/usr/bin/env bash
#
# The pre-rename addons/dot_* (and clean .repos/dot-* clones) are retired on every setup.sh run.
#
#   tools/check_retired_addons.sh      exit 0 when they are, 1 naming each failure
#
# A dot_ script and its gs_ twin share one .uid; with both in res://, uid:// loads returned the dot_ class and
# prod Fatal Contact failed to start (2026-11-23). Arm it by making retire_renamed_addons return 0 at once.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

RED=$'\033[31m'; GRN=$'\033[32m'; OFF=$'\033[0m'
fails=0
bad() { printf '  %sFAIL%s %s\n' "$RED" "$OFF" "$1"; fails=$((fails + 1)); }
good() { printf '  %sok%s   %s\n' "$GRN" "$OFF" "$1"; }

eval "$(sed -n '/^# retire_renamed_addons_begin/,/^# retire_renamed_addons_end/p' setup.sh)"
warn() { printf 'WARN %s\n' "$1"; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
cd "$T"
mkdir -p addons/.repos/dot-combat/addons/dot_combat addons/.repos/gs-combat/addons/gs_combat addons/.repos/dot-solo \
    addons/.repos/dot-dirty addons/.repos/gs-dirty addons/dot_real addons/.godot_stub .godot
ln -s .repos/dot-combat/addons/dot_combat addons/dot_combat
ln -s .repos/gs-combat/addons/gs_combat addons/gs_combat
echo x > addons/dot_real/a.gd; echo x > .godot/uid_cache.bin
git -C addons/.repos/dot-dirty init -q; echo d > addons/.repos/dot-dirty/f

RETIRED_ADDONS=(); FORCE_IMPORT=0; FORCE_IMPORT_WHY=""
retire_renamed_addons >/dev/null 2>&1
[ ! -e addons/dot_combat ] && [ ! -L addons/dot_combat ] && good "dot_ symlink removed" || bad "dot_combat symlink left"
[ -L addons/gs_combat ] && good "gs_ symlink untouched" || bad "gs_combat touched"
[ ! -e addons/dot_real ] && [ -f addons/.retired/dot_real/a.gd ] && [ -f addons/.retired/.gdignore ] \
    && good "a real dot_ dir moved to the unscanned addons/.retired" || bad "real dot_real not moved to .retired"
[ ! -d addons/.repos/dot-combat ] && good "clean dot- clone with a gs- twin deleted" || bad "dot-combat clone left"
[ -d addons/.repos/dot-solo ] && good "a dot- clone with no gs- twin kept" || bad "dot-solo deleted"
[ -d addons/.repos/dot-dirty ] && good "a dirty dot- clone kept" || bad "dirty clone deleted"
[ ! -e .godot/uid_cache.bin ] && [ "$FORCE_IMPORT" = 1 ] && good "uid cache dropped, re-import forced" || bad "uid cache or FORCE_IMPORT"

RETIRED_ADDONS=(); FORCE_IMPORT=0
rm -rf addons/.repos/dot-dirty
retire_renamed_addons >/dev/null 2>&1
[ "${#RETIRED_ADDONS[@]}" -eq 0 ] && [ "$FORCE_IMPORT" = 0 ] && good "a second run retires nothing" || bad "second run retired: ${RETIRED_ADDONS[*]}"

# zee-dot-weapons (renamed zee-gs-weapons): the stale link and clean clone go, a dirty clone stays.
cd - >/dev/null
eval "$(sed -n '/^# retire_stale_zee_begin/,/^# retire_stale_zee_end/p' setup.sh)"
T2="$(mktemp -d)"; ROOT="$T2"; STALE_ZEE=()
mkdir -p "$T2/addons/.repos/zee-dot-weapons/addons/zee_weapons"
ln -s .repos/zee-dot-weapons/addons/zee_weapons "$T2/addons/zee_weapons"
retire_stale_zee_weapons >/dev/null 2>&1
[ ! -L "$T2/addons/zee_weapons" ] && [ ! -d "$T2/addons/.repos/zee-dot-weapons" ] && good "stale zee-dot-weapons link and clone retired" || bad "zee-dot-weapons left behind"
mkdir -p "$T2/addons/.repos/zee-gs-weapons/addons/zee_weapons"
ln -s .repos/zee-gs-weapons/addons/zee_weapons "$T2/addons/zee_weapons"
STALE_ZEE=(); retire_stale_zee_weapons >/dev/null 2>&1
[ -L "$T2/addons/zee_weapons" ] && [ "${#STALE_ZEE[@]}" -eq 0 ] && good "a zee-gs-weapons link is untouched" || bad "zee-gs-weapons link retired"
rm -rf "$T2"

[ "$fails" -eq 0 ]
