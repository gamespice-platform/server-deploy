#!/usr/bin/env bash
# verify-prod-solo: a READ-ONLY end-to-end check that the SHIPPED client shell starts solo against the manifests a content
# origin really serves. It only GETs; it never publishes, uploads, signs in or prints a token.
#
#   tools/verify-prod-solo.sh [--origin URL] [--games a,b,c] [--native] [--web] [--bin PATH] [--xdg DIR]
#                             [--browser] [--secs N] [--keep]
#
#   --origin URL  the content origin: https://content.gamespice.net (default, prod) or https://tmcdevgames.net/content
#                 (dev). The `/content` suffix is optional; the shell pointer (godot/latest.json) is read from the root.
#   --games LIST  comma-separated game ids, with or without the `game-` prefix. Default for --native: fatal-contact,
#                 playlot, zombie-zone, prop-hunt, murder-mystery. The web game is always airdrift (VERIFY_WEB_GAME).
#   --native      run the native shell (--bin, or $VERIFY_SOLO_BIN, a desktop export of THIS client) headless with
#                 `--solo owner/game --content-url <origin>/content` twice per game
#   --web         the web shell: latest.json pointer, entry page answers, the game's manifest verifies; with --browser also
#                 opens embed.html?solo=owner/repo in a real browser (tools/browser_solo_overlay_check.mjs; needs a GPU box)
#   (neither flag = both; --web without --browser reports the browser step as SKIP, never as a pass)
#   --xdg DIR     keep the native shell's user data (its pack cache) in DIR so a rerun skips the downloads; default a temp dir
#                 per game, removed at the end (--keep leaves it and the logs)
#
# What it asserts, per game (the exact game and reason are printed, exit 1):
#   1. latest.json resolves, and the signed manifest parses and verifies with the client's own code, for both the legacy
#      `dot_cloud_signed` and the current `gs_cloud_signed` envelope (tools/check_solo_smoke.sh, reused as is)
#   2. a native solo launch reaches "solo game started" and never logs "Could not download the content manifest"
#   3. a SECOND launch on the same cache downloads no object ("cloud.dl sync starting", or "acquiring content ... need>0");
#      lines about workshop content are excepted
#   4. a game whose manifest still carries the legacy marker reaches the game too (that is check 2, reported as such)
# Exit: 0 all good, 1 a check failed (named), 2 setup (no binary, no origin, bad flag).
#
# Dev run:  GS_SMOKE_EXTRA_KEY=$HOME/.config/gs/pack-dev.pub tools/verify-prod-solo.sh --origin https://tmcdevgames.net/content --bin <dev build>
#           (dev content is signed by the tmc-dev key; the key file is public, the default is used when it exists)
# Prod run: tools/verify-prod-solo.sh --bin <prod build>
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OWNER="${VERIFY_OWNER:-gamemann}"
WEB_GAME="${VERIFY_WEB_GAME:-airdrift}"

# --- pure log analysis (tests/test_verify_prod_solo.sh feeds these canned logs) -------------------------------------------

# Prints one failure reason per line for a launch log; nothing when the launch is good.
#   analyse_launch <logfile> <first|second>
analyse_launch() {
    local log="$1" which="$2"
    if grep -q "Could not download the content manifest" "$log"; then
        echo "logged 'Could not download the content manifest'"
    fi
    if ! grep -q "solo game started" "$log"; then
        echo "never logged 'solo game started'"
    fi
    if [ "$which" = second ]; then
        local dl
        dl="$(grep -E "cloud\.dl sync starting" "$log" | grep -vi workshop | wc -l)"
        [ "$dl" -eq 0 ] || echo "the second launch downloaded objects ($dl 'cloud.dl sync starting' lines): the local cache was not used"
        local need
        need="$(grep -E "acquiring content" "$log" | grep -vi workshop | grep -E "need=[1-9]" | wc -l)"
        [ "$need" -eq 0 ] || echo "the second launch still needed objects ('acquiring content' with need>0, $need lines)"
    fi
}

# The game ids as full `game-x` names, one per line, from a comma list.
normalise_games() {
    local g
    for g in $(printf '%s' "$1" | tr ',' ' '); do
        case "$g" in game-*) echo "$g" ;; *) echo "game-$g" ;; esac
    done
}

# The content root with `/content` and the shell root without it, from any of the spellings of an origin.
split_origin() {
    local o="${1%/}"
    case "$o" in
        */content) echo "$o" "${o%/content}" ;;
        *) echo "$o/content" "$o" ;;
    esac
}

# Sourced by the test: stop here, the functions above are all it wants.
[ "${BASH_SOURCE[0]}" = "$0" ] || return 0

ORIGIN="https://content.gamespice.net"; GAMES=""; DO_NATIVE=0; DO_WEB=0; BIN="${VERIFY_SOLO_BIN:-}"; XDG=""; BROWSER=0; SECS=150; KEEP=0
while [ $# -gt 0 ]; do
    case "$1" in
        --origin) ORIGIN="${2:?--origin needs a URL}"; shift 2 ;;
        --games) GAMES="${2:?--games needs a list}"; shift 2 ;;
        --native) DO_NATIVE=1; shift ;;
        --web) DO_WEB=1; shift ;;
        --bin) BIN="${2:?--bin needs a path}"; shift 2 ;;
        --xdg) XDG="${2:?--xdg needs a directory}"; shift 2 ;;
        --browser) BROWSER=1; shift ;;
        --secs) SECS="${2:?--secs needs a number}"; shift 2 ;;
        --keep) KEEP=1; shift ;;
        -h|--help) sed -n 2,32p "$0"; exit 0 ;;
        *) echo "verify-prod-solo: unknown argument $1" >&2; exit 2 ;;
    esac
done
[ "$DO_NATIVE$DO_WEB" = 00 ] && { DO_NATIVE=1; DO_WEB=1; }
read -r CONTENT SHELL_ROOT < <(split_origin "$ORIGIN")
[ -n "$GAMES" ] || GAMES="fatal-contact,playlot,zombie-zone,prop-hunt,murder-mystery"
mapfile -t NATIVE_GAMES < <(normalise_games "$GAMES")
WEB_ID="game-${WEB_GAME#game-}"

fails=(); TMPBASE="${VERIFY_SOLO_TMP:-$HOME/.cache/verify-prod-solo}"; mkdir -p "$TMPBASE"; LOGDIR="$(mktemp -d -p "$TMPBASE")"
note_fail() { fails+=("$1: $2"); echo "  FAIL $1: $2"; }
cleanup() { [ "$KEEP" = 1 ] && echo "verify-prod-solo: logs kept in $LOGDIR" || rm -rf "$LOGDIR"; }
trap cleanup EXIT

# --- 1. manifests, through the existing smoke gate -----------------------------------------------------------------------
want=("${NATIVE_GAMES[@]}"); [ "$DO_WEB" = 1 ] && want+=("$WEB_ID")
all="$(printf '%s\n' "${want[@]}" | sort -u | tr '\n' ' ')"; count="$(printf '%s\n' $all | wc -l)"
key="${GS_SMOKE_EXTRA_KEY:-}"
if [ -z "$key" ] && [ "$CONTENT" != "https://content.gamespice.net/content" ]; then
    # The public tmc-dev pack key; a box whose config dir predates the dot -> gs rename keeps it in ~/.config/dot (as dev-shell.sh).
    for k in "$HOME/.config/gs/pack-dev.pub" "$HOME/.config/dot/pack-dev.pub"; do [ -f "$k" ] && { key="$k"; break; }; done
fi
echo "verify-prod-solo: origin $CONTENT, games: $all"
echo "== manifests (tools/check_solo_smoke.sh)"
GS_CONTENT_ORIGIN="$CONTENT" GS_SMOKE_OWNER="$OWNER" GS_SMOKE_GAMES="$all" GS_SMOKE_MIN="$count" GS_SMOKE_EXTRA_KEY="$key" \
    "$ROOT/tools/check_solo_smoke.sh" >"$LOGDIR/smoke.log" 2>&1
smoke_rc=$?
grep -E '^  (ok|--)  |^\[solo-smoke\]|^check_solo_smoke' "$LOGDIR/smoke.log" | cut -c1-240
if [ "$smoke_rc" -ne 0 ]; then
    # Name each game the smoke refused: a probe FAIL line carries the manifest URL, a missing latest.json the id.
    named=0
    for g in $all; do
        reason="$(grep -E "^\[solo-smoke\] FAIL .*/$g/|^  --   $g:" "$LOGDIR/smoke.log" | head -1 | cut -c1-300)"
        [ -n "$reason" ] && { note_fail "$g" "manifest: $reason"; named=1; }
    done
    [ "$named" = 1 ] || note_fail "manifests" "check_solo_smoke exited $smoke_rc: $(grep -E 'ERROR|FAIL' "$LOGDIR/smoke.log" | head -2 | tr '\n' ' ' | cut -c1-300)"
fi
legacy=" $(grep -E '^\[solo-smoke\] ok' "$LOGDIR/smoke.log" | grep -F "marker dot_cloud_signed" | sed -E 's#.* -> ([^@]*)@.*#\1#' | sed 's#.*/##' | tr '\n' ' ')"
[ "$legacy" != " " ] && echo "  legacy dot_cloud_signed manifests (parsed OK): $legacy"

# --- 2-4. native solo, twice per game ------------------------------------------------------------------------------------
run_native() {
    local g="$1" n="$2" xdg="$3" log="$LOGDIR/$1-$2.log" pid i
    # script gives the shell a pty: without one its log is block-buffered and "started" shows late.
    XDG_DATA_HOME="$xdg" script -qfec "timeout -s INT $SECS '$BIN' --headless --verbose -- --solo $OWNER/$g --content-url $CONTENT" /dev/null >"$log" 2>&1 &
    pid=$!
    for ((i = 0; i < SECS; i++)); do
        grep -q "solo game started\|Could not download the content manifest" "$log" 2>/dev/null && break
        kill -0 "$pid" 2>/dev/null || break
        sleep 1
    done
    # Past the start line a second run keeps its objects check honest: let late downloads land before judging.
    [ "$n" = second ] && sleep 3
    pkill -INT -P "$pid" 2>/dev/null; sleep 1; kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    return 0
}

if [ "$DO_NATIVE" = 1 ]; then
    echo "== native solo (headless, twice per game)"
    if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
        echo "verify-prod-solo: --native needs --bin <desktop export> (or \$VERIFY_SOLO_BIN); got '${BIN:-}'" >&2; exit 2
    fi
    for g in "${NATIVE_GAMES[@]}"; do
        if printf '%s' "${fails[*]:-}" | grep -q "$g: manifest"; then echo "  skip $g (manifest already failed)"; continue; fi
        xdg="${XDG:-$(mktemp -d -p "$TMPBASE")}"; [ -n "$XDG" ] && mkdir -p "$XDG"
        run_native "$g" first "$xdg"
        run_native "$g" second "$xdg"
        [ -z "$XDG" ] && [ "$KEEP" != 1 ] && rm -rf "$xdg"
        bad=0
        for which in first second; do
            while IFS= read -r why; do
                [ -n "$why" ] || continue
                note_fail "$g" "native $which launch $why (log: $LOGDIR/$g-$which.log)"; bad=1
            done < <(analyse_launch "$LOGDIR/$g-$which.log" "$which")
        done
        if [ "$bad" = 0 ]; then
            tag=""; case "$legacy" in *" ${g#game-} "*|*" $g "*) tag=" (legacy dot_cloud_signed manifest: Play solo reached the game)" ;; esac
            echo "  ok   $g: started, and the second launch downloaded nothing$tag"
        fi
    done
fi

# --- web shell ----------------------------------------------------------------------------------------------------------
if [ "$DO_WEB" = 1 ]; then
    echo "== web shell ($WEB_ID)"
    ptr="$(curl -sS -m 30 "$SHELL_ROOT/godot/latest.json" 2>/dev/null | python3 -I -c 'import json,sys; d=json.load(sys.stdin); print(d["build"], d.get("entry","embed.html"))' 2>/dev/null)"
    if [ -z "$ptr" ]; then
        note_fail "web-shell" "$SHELL_ROOT/godot/latest.json has no build pointer"
    else
        read -r build entry <<<"$ptr"
        url="$SHELL_ROOT/godot/$build/$entry"
        code="$(curl -sS -m 30 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null)"
        if [ "$code" = 200 ]; then echo "  ok   shell $build: $entry answers 200"; else note_fail "web-shell" "$url answered HTTP $code"; fi
        if [ "$BROWSER" = 1 ]; then
            if node "$ROOT/tools/browser_solo_overlay_check.mjs" --url "$url?solo=$OWNER/$WEB_ID" --state fresh --expect started --secs "$SECS" \
                >"$LOGDIR/web.log" 2>&1; then
                echo "  ok   $WEB_ID in the browser: solo game started ($url?solo=$OWNER/$WEB_ID)"
            else
                note_fail "$WEB_ID" "web: the browser did not reach 'solo game started': $(tail -3 "$LOGDIR/web.log" | tr '\n' ' ' | cut -c1-300)"
            fi
        else
            echo "  SKIP browser start of $url?solo=$OWNER/$WEB_ID (needs --browser, a GPU box)"
        fi
    fi
fi

echo "== verdict"
if [ "${#fails[@]}" -gt 0 ]; then
    printf 'verify-prod-solo: FAIL %s\n' "${fails[@]}" >&2
    exit 1
fi
echo "verify-prod-solo: OK on $CONTENT"
