#!/usr/bin/env bash
# Every script the client shell carries must compile against the shell's own addons, and nothing else.
#   tools/check_shell_parse.sh        builds the shell's addons from the addons.lock tags it exports
#                                     (tools/shell_lock.sh lock), imports them alone, and parses them
#   TMC_SIBLINGS=DIR                  where the addon clones are (default ..; CI: addons/.repos)
#
# Packs carry no addons, so an addon the shell's addons need and the shell does not carry is a parse
# error on every player's machine. 2026-11-21: native shell 1.20261121.2113 carried gs-player-char
# v0.1.76 (GSPlayerAnimState extends gs-animation's GSAnimationLocomotion) and gs-spectate v0.1.13
# (gs-camera's GSCameraFreeLook) without gs-animation or gs-camera. Fatal Contact and Hungario
# failed to compile and the client crashed on join. check_pinned_parse.sh did not see it: it fills a
# game's extra linked addons in from their newest tags, which a shell never does.
# Arm it by deleting the gs-camera line from addons.lock and tools/shell-addons.list.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-godot}"
SIB="${TMC_SIBLINGS:-$ROOT/..}"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
p="$W/shell"; mkdir -p "$p/addons"

bash "$ROOT/tools/shell_lock.sh" lock "$ROOT/addons.lock" > "$W/shell.lock" || { echo "FAIL tools/shell_lock.sh could not cut the shell's lock"; exit 1; }
PINNED_LOCK="$W/shell.lock" bash "$ROOT/tools/check-pinned.sh" "$p/addons" || { echo "FAIL the shell's pinned addons did not build"; exit 1; }

# The native library is a git-ignored download, in no tag: take the one setup.sh installed, else the sibling's.
for b in "$ROOT/addons/gs_sim/bin" "$SIB/gs-sim/addons/gs_sim/bin"; do
    [ -d "$b" ] && [ -d "$p/addons/gs_sim" ] && { cp -a "$b" "$p/addons/gs_sim/bin"; break; }
done
[ -d "$p/addons/gs_sim/bin" ] || echo "WARN no gs_sim native library found; the GDScript fallbacks are what get parsed"

printf 'config_version=5\n\n[application]\n\nconfig/name="shell parse check"\n' > "$p/project.godot"
tool="$p/addons/gs_core/tools/gs_parse_all.gd"
[ -f "$tool" ] || { echo "FAIL no gs_parse_all in the shell's gs-core"; exit 1; }

timeout 600 "$GODOT" --headless --path "$p" --import > "$W/import.log" 2>&1; irc=$?
# Godot 4 can abort (134) while quitting the editor after the import has finished; that is not a failed import.
done_ok=0; grep -aq 'loading_editor_layout.*DONE\|DONE.*loading_editor_layout' "$W/import.log" && done_ok=1
[ "$irc" = 134 ] && [ "$done_ok" = 1 ] && irc=0
if [ "$irc" -ge 124 ] || grep -aqE 'handle_crash|Program crashed|Segmentation fault' "$W/import.log"; then
    echo "FAIL --import died (exit $irc; 124 = timeout, 139 = SIGSEGV)"; tail -20 "$W/import.log"; exit 1
fi

# Runtime scripts only: an addon's examples and tests are not exported and may use what the shell lacks.
(cd "$p" && find addons -name '*.gd' -not -path '*/examples/*' -not -path '*/tests/*' -not -path '*/test/*' \
    -not -path '*/tools/*' -not -path '*/editor/*' | sort > "$W/list")
PARSE_LIST="$W/list" timeout 900 "$GODOT" --headless --path "$p" --script res://addons/gs_core/tools/gs_parse_all.gd > "$W/parse.log" 2>&1
bad="$(grep -aE 'PARSE_FAIL|SCRIPT ERROR|Parse Error|not declared|Could not (find|resolve)' "$W/parse.log" | head -12)"
grep -aq '^PARSED ' "$W/parse.log" || bad="${bad:-the parse tool did not finish}"
if [ -n "$bad" ]; then
    echo "FAIL the shell's addons do not compile on their own ($(wc -l < "$W/list") scripts):"
    echo "$bad"
    echo "     an addon above needs another the shell does not carry: add it to addons.lock, content-lists/addons.yml and tools/shell-addons.list"
    exit 1
fi
echo "ok   the shell's addons compile on their own: $(grep -a '^PARSED ' "$W/parse.log")"
