#!/usr/bin/env bash
# tools/check_solo_smoke.sh must say which godot binary is missing (exit 2), not die with a bare 127.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
eq() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok   $1"; else fail=$((fail + 1)); echo "FAIL $1: expected [$3] got [$2]"; fi; }
run() { env "$@" GS_CONTENT_ORIGIN=http://127.0.0.1:9 bash "$ROOT/tools/check_solo_smoke.sh" 2>&1; }
out="$(run GODOT=/nonexistent/godot-x)"; rc=$?
eq "missing GODOT exits 2" "$rc" 2
eq "message names the binary" "$(grep -c '/nonexistent/godot-x' <<<"$out")" 1
out="$(run -u GODOT TMC_GODOT=/nonexistent/tmc-godot)"
eq "TMC_GODOT is honoured and named" "$(grep -c '/nonexistent/tmc-godot' <<<"$out")" 1
echo "$pass passed, $fail failed"; [ $fail = 0 ]
