#!/usr/bin/env bash
# Offline test of tools/artifact_boot_smoke.sh's failure handling with a fake ./server: a dropped connection to the content
# origin is retried (bounded, printed as RETRY), any other failure is not, and a failed game's log head is printed.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
eq() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok   $1"; else fail=$((fail + 1)); echo "FAIL $1: expected [$3] got [$2]"; fi; }
mkdir -p "$T/tree/.godot"; : > "$T/tree/.godot/global_script_class_cache.cfg"
cat > "$T/tree/server" <<'F'
#!/usr/bin/env bash
echo x >> "$FAKE_COUNT"
echo "inf cloud fetching manifest from the origin"
case "$FAKE_MODE" in
  net) echo "ERROR: Connection to remote host failed!" ;;
  real) echo "SCRIPT ERROR: Parse Error: boom"; echo "ERROR: Connection to remote host failed!" ;;
esac
sleep 30
F
chmod +x "$T/tree/server"
run() { : > "$T/count"; FAKE_MODE="$1" FAKE_COUNT="$T/count" bash "$ROOT/tools/artifact_boot_smoke.sh" --tree "$T/tree" --only mg-fake --retries "$2" --ready-wait 20 > "$T/out" 2>&1; echo $?; }
eq "a dropped connection fails after the bounded retries" "$(run net 2)" 1
eq "it booted 3 times (1 + 2 retries)" "$(wc -l < "$T/count" | tr -d ' ')" 3
eq "each retry is printed" "$(grep -c '^RETRY mg-fake' "$T/out")" 2
eq "the failing game's log head is printed" "$(grep -c 'fetching manifest from the origin' "$T/out")" 2   # head and tail sections
eq "a real failure beside the network line is not retried" "$(run real 2)" 1
eq "it booted once" "$(wc -l < "$T/count" | tr -d ' ')" 1
eq "--retries 0 never retries" "$(run net 0)" 1
eq "it booted once with --retries 0" "$(wc -l < "$T/count" | tr -d ' ')" 1
echo "$pass passed, $fail failed"; [ $fail = 0 ]
