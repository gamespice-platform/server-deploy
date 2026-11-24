#!/usr/bin/env bash
# Offline test of tools/shell_import.sh with a fake godot: an abort after the class cache is written is a finished import,
# an abort before it is retried then fails with the log head printed, a clean exit without a cache is not an import.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
eq() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok   $1"; else fail=$((fail + 1)); echo "FAIL $1: expected [$3] got [$2]"; fi; }
# fake godot: FAKE_MODE = clean | abort_after | abort_before | abort_once | clean_nocache
cat > "$T/godot" <<'F'
#!/usr/bin/env bash
p=""; while [ $# -gt 0 ]; do [ "$1" = --path ] && p="$2"; shift; done
mkdir -p "$p/.godot"; n="$p/.attempt"; c=$(( $(cat "$n" 2>/dev/null || echo 0) + 1 )); echo $c > "$n"
cache() { printf 'list=[{\n"base": &"Node",\n"class": &"GSCore",\n"path": "res://x.gd"\n}]\n' > "$p/.godot/global_script_class_cache.cfg"; }
case "$FAKE_MODE" in
  clean) cache; exit 0 ;;
  abort_after) cache; echo "handle_crash: Program crashed with signal 6"; exit 134 ;;
  abort_before) echo "ERROR: first problem"; echo "handle_crash: Program crashed with signal 6"; exit 134 ;;
  abort_once) if [ $c = 1 ]; then echo "ERROR: blip"; exit 134; fi; cache; exit 0 ;;
  clean_nocache) exit 0 ;;
esac
F
chmod +x "$T/godot"
run() { rm -rf "$T/p"; mkdir "$T/p"; FAKE_MODE="$1" GODOT="$T/godot" bash "$ROOT/tools/shell_import.sh" "$T/p" "$T/log" "${2:-3}" > "$T/out" 2>&1; echo $?; }
eq "clean import with a cache passes" "$(run clean)" 0
eq "abort after the cache was written passes" "$(run abort_after)" 0
eq "abort_after was not retried" "$(cat "$T/p/.attempt")" 1
eq "abort before the cache fails" "$(run abort_before)" 1
eq "abort before the cache was retried" "$(cat "$T/p/.attempt")" 3
eq "the failure prints the log head (head, ERROR list, tail, per attempt)" "$(grep -c "ERROR: first problem" "$T/out")" 9
eq "a one-off abort is retried and passes" "$(run abort_once)" 0
eq "a clean exit without a class cache fails" "$(run clean_nocache 2)" 1
echo "$pass passed, $fail failed"; [ $fail = 0 ]
