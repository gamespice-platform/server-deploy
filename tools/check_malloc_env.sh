#!/usr/bin/env bash
# ./server bounds glibc's per-thread heap arenas (a threaded nav bake otherwise leaves ~0.5 GB held on a big map) and leaves an operator's own values alone.
#   tools/check_malloc_env.sh   exit 0 when all hold, 1 otherwise
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
fails=0
chk() { if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1"; fails=$((fails + 1)); fi; }

line="$(grep -E '^export MALLOC_ARENA_MAX=' tools/server.in)"
chk "server.in exports MALLOC_ARENA_MAX and MALLOC_TRIM_THRESHOLD_" '[ -n "$line" ] && grep -q "MALLOC_TRIM_THRESHOLD_=" <<<"$line"'
chk "with a default of two arenas" 'env -u MALLOC_ARENA_MAX -u MALLOC_TRIM_THRESHOLD_ bash -c "$line; [ \"\$MALLOC_ARENA_MAX\" = 2 ]"'
chk "an operator's value wins" 'MALLOC_ARENA_MAX=8 bash -c "$line; [ \"\$MALLOC_ARENA_MAX\" = 8 ]"'
chk "tools/check.sh runs this check" 'grep -q "tools/check_malloc_env.sh" tools/check.sh'

[ "$fails" -eq 0 ] && echo "malloc env: all checks passed" || echo "malloc env: $fails failed"
exit $((fails > 0))
