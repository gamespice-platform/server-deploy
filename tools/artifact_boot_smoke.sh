#!/usr/bin/env bash
# Boots a headless dedicated server from a BUILT shell install, through the path prod uses, once per published game, and
# fails on anything prod would have choked on.
#
#   tools/artifact_boot_smoke.sh [--tree DIR] [--origin URL] [--only id,id] [--owner NAME] [--keep DIR] [--ready-wait S]
#     --tree        the install to boot: a directory with ./server, host/ and addons/ as a prod box has it (default: this checkout)
#     --origin      content root (default https://content.gamespice.net/content; the dev one is https://tmcdevgames.net/content)
#     --only        content ids (without the owner) instead of every game-*/mg-* repo in content-lists/games.yml
#     --owner       content owner (default gamemann; CONTENT_OWNER)
#     --keep        keep logs under DIR (default: a temp dir, removed unless something failed)
#     --retries     extra boots of a game whose log shows only a dropped connection to the content origin (default 2,
#                   ARTIFACT_NET_RETRIES; each is printed as RETRY and the failed attempt's log is kept as server.log.N)
#     --ready-wait  seconds to wait for "content ready" and "module loaded" (default 240)
#   Exit 0 all booted clean, 1 a game failed (each listed), 2 setup failure or nothing booted.
#
# The command per game is the one a prod server runs: `./server --port P --game ID --games OWNER/ID --content-url ORIGIN`
# (TMC_AUTO_UPDATE=never: the tree is the artifact under test; re-installing addons would hide what it ships).
# A game FAILS when its log has a line matching ERROR:, SCRIPT ERROR, "would not load", "Cannot convert argument", "must
# extend" or "crashed state"; or never logs "content ready" and "module loaded for the current game"; or an A2S_INFO query
# (tools/a2s_probe.py) on the game port gets no answer. Run it through hv, never bare.
#
# [b]Why.[/b] 2026-11-23: the published shell carried both dot_* and gs_* addons, one uid (cbebxr4alar6d) owned by
# dot_combat/dot_pellet_tracer.gd and gs_combat/gs_pellet_tracer.gd, and prod Fatal Contact servers would not boot. Every
# test ran the repo tree, which never had both. tools/check_artifact_static.py is the cheap half (no server); this is the
# half that proves the thing actually starts.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TREE="$HERE"; ORIGIN="${ARTIFACT_ORIGIN:-https://content.gamespice.net/content}"; ONLY=""; KEEP=""; WAIT=240
OWNER="${CONTENT_OWNER:-gamemann}"; RETRIES="${ARTIFACT_NET_RETRIES:-2}"
# Shell CI boots this sample on every built shell (a boot is ~a minute each); the nightly boots every published game.
CI_GAMES="${ARTIFACT_CI_GAMES:-game-fatal-contact,game-airdrift,game-playlot,game-deathrun,mg-wipeout}"
while [ $# -gt 0 ]; do
    case $1 in
        --tree) TREE="$(cd "${2:?}" && pwd)"; shift 2 ;;
        --origin) ORIGIN="${2:?}"; shift 2 ;;
        --only) ONLY="${2:?}"; shift 2 ;;
        --ci) ONLY="$CI_GAMES"; shift ;;
        --owner) OWNER="${2:?}"; shift 2 ;;
        --retries) RETRIES="${2:?}"; shift 2 ;;
        --keep) KEEP="${2:?}"; shift 2 ;;
        --ready-wait) WAIT="${2:?}"; shift 2 ;;
        *) echo "artifact_boot_smoke: unknown argument $1" >&2; exit 2 ;;
    esac
done
[ -x "$TREE/server" ] || { echo "artifact_boot_smoke: $TREE/server is not built (run setup.sh there)" >&2; exit 2; }
# A prod box is imported by setup.sh; a tree that never was has no class cache and every class_name "cannot be found".
if [ ! -f "$TREE/.godot/global_script_class_cache.cfg" ]; then
    echo "artifact_boot_smoke: importing $TREE (no class cache yet)"
    timeout 600 "${TMC_GODOT:-${GODOT:-godot}}" --headless --path "$TREE" --import >/dev/null 2>&1
fi
if [ -n "$ONLY" ]; then IDS="$(tr ',' ' ' <<<"$ONLY")"; else
    IDS="$(sed -n 's/^ *- repo: *\(\(game\|mg\)-[^ ]*\) *$/\1/p' "$HERE/content-lists/games.yml" | grep -v -- '-maps$' | tr '\n' ' ')"
fi
[ -n "${IDS// /}" ] || { echo "artifact_boot_smoke: no games listed" >&2; exit 2; }
if [ -n "$KEEP" ]; then W="$KEEP"; mkdir -p "$W"; else W="$(mktemp -d)"; fi
FAILURE_RE='ERROR:|SCRIPT ERROR|would not load|Cannot convert argument|must extend|crashed state'
fails=0; booted=0; port=$((20000 + RANDOM % 20000)); rows=()
# The content origin is a public host and GitHub runners drop connections now and then: Godot logs "Connection to remote host
# failed!" (an ERROR: line) and the game never loads. 2026-11-24 mg-wipeout failed that way on the run after one that passed.
# That alone, with no other failure line, is a blip worth a bounded, loud retry; anything else is a real failure.
NET_RE='Connection to remote host failed|Could not connect to host|Failed to connect to host|Can.t resolve hostname|Connection timed out'
for id in $IDS; do
  for ((attempt = 0; attempt <= RETRIES; attempt++)); do
    d="$W/$id"; rm -rf "$d"; mkdir -p "$d/cfg" "$d/data" "$d/content"; log="$d/server.log"; port=$((port + 3)); why=()
    (cd "$TREE" && TMC_AUTO_UPDATE=never exec timeout $((WAIT + 60)) ./server --port "$port" --game "$id" --games "$OWNER/$id" \
        --content-url "$ORIGIN" --config "$d/cfg" --content "$d/content" --data "$d/data" </dev/null >"$log" 2>&1) &
    pid=$!
    ready=0; mod=0
    for ((t = 0; t < WAIT; t += 2)); do
        grep -q 'content ready' "$log" 2>/dev/null && ready=1
        grep -q 'module loaded for the current game' "$log" 2>/dev/null && mod=1
        [ $ready = 1 ] && [ $mod = 1 ] && break
        kill -0 "$pid" 2>/dev/null || break
        grep -qE "$FAILURE_RE" "$log" 2>/dev/null && { sleep 3; break; }   # let the rest of the failure reach the log
        sleep 2
    done
    probe=""
    if [ $ready = 1 ] && [ $mod = 1 ]; then probe="$(python3 -I "$HERE/tools/a2s_probe.py" "$port" 127.0.0.1 10 2>&1)" || why+=("no client can query: $probe"); fi
    pkill -TERM -P "$pid" 2>/dev/null; kill -TERM "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    [ $ready = 1 ] || why+=('never logged "content ready"')
    [ $mod = 1 ] || why+=('never logged "module loaded for the current game"')
    bad="$(grep -E "$FAILURE_RE" "$log" | head -3 | cut -c1-240)"
    [ -z "$bad" ] || why+=("log: $(paste -sd'|' <<<"$bad")")
    if [ ${#why[@]} -gt 0 ] && [ $attempt -lt "$RETRIES" ] && grep -qE "$NET_RE" "$log" \
        && ! grep -E "$FAILURE_RE" "$log" | grep -qvE "$NET_RE"; then
        cp "$log" "$W/$id.server.log.$((attempt + 1))"
        echo "RETRY $id: only a dropped connection to $ORIGIN in its log (attempt $((attempt + 1)) of $((RETRIES + 1))): $(grep -E "$NET_RE" "$log" | head -1 | cut -c1-200)"
        continue
    fi
    break
  done
    booted=$((booted + 1))
    if [ ${#why[@]} -eq 0 ]; then rows+=("ok    $id ($ORIGIN)")
    else
        fails=$((fails + 1)); rows+=("FAIL  $id: $(IFS=';'; echo "${why[*]}") [$log]")
        echo "---- $id server.log head (the first lines show what it fetched and what broke) ----"; head -40 "$log" | cut -c1-300
        echo "---- $id server.log tail ----"; tail -15 "$log" | cut -c1-300
    fi
done
printf '%s\n' "${rows[@]}"
if [ $fails -gt 0 ]; then echo "artifact_boot_smoke: FAIL ($fails of $booted games; logs kept in $W)"; exit 1; fi
[ -n "$KEEP" ] || rm -rf "$W"
echo "artifact_boot_smoke: ok ($booted games booted clean from $TREE against $ORIGIN)"
