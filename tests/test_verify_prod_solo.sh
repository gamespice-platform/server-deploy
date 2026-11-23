#!/usr/bin/env bash
# Offline test of tools/verify-prod-solo.sh: its log analysis on canned launch logs, its argument helpers, and (when a
# godot with this project's classes is available) the saved real legacy manifest through the client's own parser.
#   tests/test_verify_prod_solo.sh            GODOT=... to choose the engine; NO_GODOT=1 skips the fixture parse
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../tools/verify-prod-solo.sh
source "$ROOT/tools/verify-prod-solo.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
eq() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok   $1"; else fail=$((fail + 1)); echo "FAIL $1: expected [$3] got [$2]"; fi; }

printf 'inf tmc.shell starting solo\ninf tmc.shell solo game started content=x\n' > "$T/good"
eq "a clean first launch has no reasons" "$(analyse_launch "$T/good" first)" ""
eq "a clean second launch has no reasons" "$(analyse_launch "$T/good" second)" ""

printf 'err cloud Could not download the content manifest.\n' > "$T/nomanifest"
out="$(analyse_launch "$T/nomanifest" first)"
eq "manifest error is named" "$(grep -c "Could not download the content manifest" <<<"$out")" "1"
eq "manifest error also means never started" "$(grep -c "never logged" <<<"$out")" "1"

printf 'inf cloud.dl sync starting bytes="1 KiB" cached=0\ninf tmc.shell solo game started\n' > "$T/dl"
eq "second launch with a download fails" "$(analyse_launch "$T/dl" second | grep -c "downloaded objects")" "1"
eq "the same log is fine as a first launch" "$(analyse_launch "$T/dl" first)" ""

printf 'inf cloud.dl sync starting workshop mod=1\ninf tmc.shell solo game started\n' > "$T/ws"
eq "workshop downloads are excepted" "$(analyse_launch "$T/ws" second)" ""

printf 'inf cloud acquiring content bytes="5 MiB" need=12\ninf tmc.shell solo game started\n' > "$T/need"
eq "need>0 on the second launch fails" "$(analyse_launch "$T/need" second | grep -c "still needed")" "1"
printf 'inf cloud acquiring content bytes="0 B" need=0\ninf tmc.shell solo game started\n' > "$T/need0"
eq "need=0 is the cache working" "$(analyse_launch "$T/need0" second)" ""

eq "games without the prefix are normalised" "$(normalise_games "fatal-contact,game-playlot" | tr '\n' ' ')" "game-fatal-contact game-playlot "
eq "prod origin" "$(split_origin https://content.gamespice.net)" "https://content.gamespice.net/content https://content.gamespice.net"
eq "dev origin with /content" "$(split_origin https://tmcdevgames.net/content/)" "https://tmcdevgames.net/content https://tmcdevgames.net"

if [ "${NO_GODOT:-}" != 1 ]; then
    GODOT="${GODOT:-godot}"
    out="$("$GODOT" --headless --path "$ROOT" -s tests/verify_solo_envelope_test.gd 2>&1)"; rc=$?
    printf '%s\n' "$out" | grep -E '^(ok|FAIL) |verify_solo_envelope_test' | sed 's/^/     /'
    eq "legacy + current envelope fixture test exits 0" "$rc" "0"
fi
echo "test_verify_prod_solo: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
