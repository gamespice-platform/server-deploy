#!/usr/bin/env bash
# Solo smoke: for several games, resolve latest.json on a content origin, then have the shipped gs-cloud
# client parse and verify the signed manifest it names (tools/solo_manifest_probe.gd). A publish gate.
#
#   GS_CONTENT_ORIGIN=https://tmcdevgames.net/content tools/check_solo_smoke.sh     dev first
#   GS_CONTENT_ORIGIN=https://content.gamespice.net/content tools/check_solo_smoke.sh   prod second
#
#   GS_CONTENT_ORIGIN   content root (required: a gate that guesses its origin checks the wrong one)
#   GS_SMOKE_OWNER      default gamemann
#   GS_SMOKE_GAMES      space-separated ids, default "game-fatal-contact game-airdrift game-playlot game-hungario"
#   GS_SMOKE_MIN        how many must pass, default 3 (every listed game must still parse; this is the floor of
#                       games that must exist on the origin, so an origin that 404s all of them cannot pass)
#   GS_SMOKE_STRICT_MARKER=1   also refuse a manifest still carrying the legacy `dot_cloud_signed` marker
#   GS_SMOKE_EXTRA_KEY  a PUBLIC key PEM file to trust in addition to client/content.json's, as a dev shell does
#                       (the tmc-dev pack key, tools/dev-shell.sh): dev content is signed by it, prod's by the shipped key
#   GODOT               the engine (default godot)
#
# [b]Why.[/b] 2026-11-22: a rename changed the envelope marker, every manifest already published kept the old one,
# and prod solo failed with "Could not download the content manifest". Nothing parsed a REAL published manifest
# with the client being shipped. Exit 0 all good; 1 a manifest was refused or too few games answered; 2 setup.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ORIGIN="${GS_CONTENT_ORIGIN:-}"
[ -n "$ORIGIN" ] || { echo "check_solo_smoke: GS_CONTENT_ORIGIN is not set (the content root the shell will use, e.g. https://content.gamespice.net/content)" >&2; exit 2; }
ORIGIN="${ORIGIN%/}"
OWNER="${GS_SMOKE_OWNER:-gamemann}"
GAMES="${GS_SMOKE_GAMES:-game-fatal-contact game-airdrift game-playlot game-hungario}"
MIN="${GS_SMOKE_MIN:-3}"
GODOT="${GODOT:-godot}"

urls=(); bad=0; n=0
for id in $GAMES; do
    code="$(curl -sS --max-time 30 -o /tmp/.solo_smoke_latest.$$ -w '%{http_code}' "$ORIGIN/$OWNER/$id/latest.json" 2>/dev/null)" || code=000
    v=""
    [ "$code" = 200 ] && v="$(python3 -I -c 'import json,sys; print(json.load(sys.stdin)["version"])' < /tmp/.solo_smoke_latest.$$ 2>/dev/null)"
    rm -f /tmp/.solo_smoke_latest.$$
    if [ -z "$v" ]; then
        echo "  --   $id: latest.json at $ORIGIN/$OWNER/$id answered HTTP $code, no version"
        bad=$((bad + 1)); continue
    fi
    echo "  ok   $id latest.json -> $v"
    urls+=("$ORIGIN/$OWNER/$id/$v/manifest.json"); n=$((n + 1))
done

if [ "$n" -lt "$MIN" ]; then
    echo "check_solo_smoke: FAIL only $n game(s) resolved on $ORIGIN, need $MIN" >&2
    exit 1
fi

cfg=""
if [ -n "${GS_SMOKE_EXTRA_KEY:-}" ]; then
    [ -f "$GS_SMOKE_EXTRA_KEY" ] || { echo "check_solo_smoke: GS_SMOKE_EXTRA_KEY $GS_SMOKE_EXTRA_KEY is not a file" >&2; exit 2; }
    cfg="$(mktemp --suffix=.json)"; trap 'rm -f "$cfg"' EXIT
    python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); d["trusted_keys"]["smoke-extra"]=open(sys.argv[2]).read().strip(); json.dump(d,open(sys.argv[3],"w"))' \
        "$ROOT/client/content.json" "$GS_SMOKE_EXTRA_KEY" "$cfg"
fi

# The class cache (GSCloudClient and friends) only exists after an import; a fresh checkout has none.
timeout 600 "$GODOT" --headless --path "$ROOT" --import >/dev/null 2>&1 || true

out="$(GS_SMOKE_CONTENT_CONFIG="$cfg" "$GODOT" --headless --path "$ROOT" -s tools/solo_manifest_probe.gd -- "${urls[@]}" 2>&1)"; rc=$?
printf '%s\n' "$out" | grep -E '^\[solo-smoke\]|ERROR|SCRIPT ERROR|Parse Error' | head -40
if [ "$rc" -ne 0 ]; then
    echo "check_solo_smoke: FAIL the client did not accept every manifest on $ORIGIN (probe exit $rc)" >&2
    exit 1
fi
[ "$bad" -eq 0 ] || echo "check_solo_smoke: note $bad listed game(s) not on this origin (floor of $MIN met)"
echo "check_solo_smoke: OK $n game(s) parsed and verified from $ORIGIN"
