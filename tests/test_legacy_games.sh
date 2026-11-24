#!/usr/bin/env bash
# Offline test of migrate_legacy_games (tools/game_source.sh): a legacy games/ of links is moved out of res://, relative links stay valid, real content is moved and never deleted, an empty games/ with .gdignore is left.
set -uo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tools/game_source.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
eq() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok   $1"; else fail=$((fail + 1)); echo "FAIL $1: expected [$3] got [$2]"; fi; }
R="$T/p/srv"; H="$T/home"
mkdir -p "$R/tools" "$R/games" "$T/p/game-a/game" "$T/p/game-b/game" "$H"
cp "$SRC" "$R/tools/game_source.sh"
echo a > "$T/p/game-a/game/f"
ln -s ../../game-a "$R/games/game-a"            # relative, as link_sibling_game makes it
ln -s "$T/p/game-b" "$R/games/game-b"           # absolute
mkdir -p "$R/games/game-real/game"; echo keep > "$R/games/game-real/game/f"
mkdir -p "$R/games/game-clash"; echo legacy > "$R/games/game-clash/f"
: > "$R/games/.gdignore"
run() { ( export TMC_GAMES_REPOS="$H/games"; . "$R/tools/game_source.sh"; migrate_legacy_games ); }
out="$(run)"
eq "relative link relinked" "$(readlink "$H/games/game-a")" "$T/p/game-a"
eq "and it resolves" "$(cat "$H/games/game-a/game/f")" a
eq "absolute link relinked" "$(readlink "$H/games/game-b")" "$T/p/game-b"
eq "old links removed" "$(ls -A "$R/games" | grep -c 'game-[ab]$')" 0
eq "real dir moved with its content" "$(cat "$H/games/game-real/game/f")" keep
eq "home has a .gdignore" "$([ -f "$H/games/.gdignore" ] && echo y)" y
eq "legacy games/ kept with .gdignore" "$([ -f "$R/games/.gdignore" ] && echo y)" y
eq "legacy games/ holds nothing else" "$(ls -A "$R/games" | tr '\n' ' ')" ".gdignore "
# second run: nothing to do; a real dir clashing with an existing destination is left, not deleted
mkdir -p "$R/games/game-real"; echo second > "$R/games/game-real/g"
out="$(run)"
eq "clash is reported" "$(echo "$out" | grep -c 'left in place')" 1
eq "clash content not deleted" "$(cat "$R/games/game-real/g")" second
eq "existing destination not overwritten" "$(cat "$H/games/game-real/game/f")" keep
# a tree with no games/ is untouched
rm -rf "$R/games"; run >/dev/null
eq "no games/ is not created" "$([ -e "$R/games" ] && echo y || echo n)" n
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
