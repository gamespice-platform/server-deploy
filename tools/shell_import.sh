#!/usr/bin/env bash
# Imports a throwaway Godot project headless and says whether the import really finished.
#   tools/shell_import.sh PROJECT_DIR LOG [ATTEMPTS]      GODOT=... chooses the engine; exit 0 imported, 1 it did not
#
# Godot 4.7.2 can abort (exit 134, SIGABRT, "Program crashed") on a CI runner, sometimes in the first seconds of a first
# import, and the abort is intermittent: the same lock imported fine on the box and on the sibling runner job
# (2026-11-23/24, native shell runs 10ff73c and dfdfb01). Two things were wrong with the old inline check:
#   - its success signal was a stdout line ("loading_editor_layout ... DONE"); stdout redirected to a file is buffered
#     and is lost when the process aborts, so the tolerance could never match;
#   - it printed only the tail of the log, which is the crash backtrace, never the first ERROR that explains it.
# The signal used now is the file the import writes last: .godot/global_script_class_cache.cfg with every addon
# class_name in it. An abort after that exists is a quit-time crash, not a failed import. An abort before it is retried
# (a second import resumes the first one's work), loudly, at most ATTEMPTS times (default 3); every failed attempt's log
# head, first ERROR lines and tail are printed.
set -uo pipefail
P="${1:?project dir}"; LOG="${2:?log file}"; ATTEMPTS="${3:-${SHELL_IMPORT_ATTEMPTS:-3}}"
GODOT="${GODOT:-godot}"
cache="$P/.godot/global_script_class_cache.cfg"
for ((n = 1; n <= ATTEMPTS; n++)); do
    rm -f "$cache"   # a leftover from the previous attempt must not vouch for this one
    timeout 600 "$GODOT" --headless --path "$P" --import > "$LOG" 2>&1; rc=$?
    have=0; [ -s "$cache" ] && grep -aq '"class":' "$cache" 2>/dev/null && have=1
    if [ "$rc" = 0 ] && [ $have = 1 ]; then exit 0; fi
    if [ "$rc" = 134 ] && [ $have = 1 ]; then
        echo "note: --import aborted (134) while quitting, after it wrote its class cache (attempt $n/$ATTEMPTS); the import itself finished"
        exit 0
    fi
    echo "WARN --import attempt $n/$ATTEMPTS failed (exit $rc; 124 = timeout, 134 = SIGABRT, 139 = SIGSEGV; class cache: $([ $have = 1 ] && echo present || echo missing))"
    echo "---- import.log head (the first ERROR is the cause; the tail is only the crash backtrace) ----"; head -60 "$LOG"
    echo "---- first ERROR/WARNING lines ----"; grep -anE 'ERROR|WARNING' "$LOG" | head -15
    echo "---- import.log tail ----"; tail -20 "$LOG"
    [ "$rc" = 124 ] && break   # a hang is not a blip: retrying it only burns 10 minutes per attempt
done
echo "FAIL --import did not finish after $n attempt(s)"
exit 1
