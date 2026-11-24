#!/usr/bin/env bash
#
# Every tracked script outside addons/ has its tracked .uid file.
#
# Godot writes a missing .gd.uid on the import pass. In CI that pass runs after the
# checkout and before the export, so a script committed without its .uid made the tree
# dirty, the build stamp said "<sha>-dirty", and publish_gate.sh refused the shell
# (2026-11-24: client/tmc_shell_solo_addons.gd).

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

bad=0
while IFS= read -r f; do
    git ls-files --error-unmatch "$f.uid" >/dev/null 2>&1 && continue
    printf 'FAIL tracked script without a tracked .uid (commit the one Godot writes): %s\n' "$f"
    bad=$((bad + 1))
done < <(git ls-files -- '*.gd' ':!addons/**')

[ "$bad" = 0 ] && echo "ok   every tracked script has its .uid"
[ "$bad" = 0 ]
