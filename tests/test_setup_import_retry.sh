#!/usr/bin/env bash
# Offline test of setup.sh's run_import with a fake godot: a crashed import (exit 139) is run again and the second pass counts, a clean one runs once, one that always crashes gives up after TMC_IMPORT_TRIES.
set -uo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/setup.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
eq() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok   $1"; else fail=$((fail + 1)); echo "FAIL $1: expected [$3] got [$2]"; fi; }
cat > "$T/godot" <<'F'
#!/usr/bin/env bash
n="$FAKE_DIR/.attempt"; c=$(( $(cat "$n" 2>/dev/null || echo 0) + 1 )); echo $c > "$n"
case "$FAKE_MODE" in
  clean) exit 0 ;;
  crash_once) [ "$c" = 1 ] && exit 139; exit 0 ;;
  crash_always) exit 139 ;;
esac
F
chmod +x "$T/godot"
# the function, lifted out of setup.sh so the test runs what ships
body="$(sed -n '/^IMPORT_TRIES=/,/^}/p' "$SRC")"
run() {
    rm -rf "$T/p"; mkdir -p "$T/p"
    ( ROOT="$T/p"; GODOT="$T/godot"; IMPORT_LOG="$T/p/log"; FAKE_DIR="$T/p"; FAKE_MODE="$1"; export FAKE_DIR FAKE_MODE
      warn() { :; }; import_missing_output() { :; }
      eval "$body"; run_import ) >/dev/null 2>&1
    echo $?
}
eq "a clean import passes" "$(run clean)" 0
eq "and ran once" "$(cat "$T/p/.attempt")" 1
eq "a crashed import is run again and passes" "$(run crash_once)" 0
eq "and was run twice" "$(cat "$T/p/.attempt")" 2
eq "an import that always crashes fails" "$(run crash_always)" 1
eq "after three attempts" "$(cat "$T/p/.attempt")" 3
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
