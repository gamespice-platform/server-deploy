#!/usr/bin/env bash
# Prove a map change works on a live Pterodactyl game server, through the game's own admin path.
#
#   tools/map_change_verify.sh <server-id> <host:port> [--map ID] [--via mapmenu|map|rtv] [--secs N]
#
# Joins a headless client, lists the maps (`mapmenu`), then changes to another one:
#   mapmenu  `mapmenu <id>` from the console: an immediate change for the owner's flag, in every game (the default).
#   map      `map <id>` (games with gs_map's console command; answers "Now on <id>.").
#   rtv      `setnextmap <id>` then `forcertv`: only moves a server whose end vote is on (with no time limit
#            setnextmap waits for END_OF_TIME, which never comes, and forcertv is refused while voting is off).
# Then polls `votestatus` until "running <id>" shows and checks the client is still connected. Prints one verdict
# line (CHANGED / TIMEOUT / NOJOIN / NOTARGET) and exits 0 only for CHANGED. No rcon password: commands go through the panel API.
# Run as the work user (the panel key is gamedev's): sudo -u gamedev tools/map_change_verify.sh 5652482b 10.50.0.5:6120
# Env: SEND_SECS (default 8: seconds the console is read per command; a game with a long map list, Zombie Zone's 60 rows, answers `mapmenu` after the first 2 s),
#      PTERO_KEY_FILE (default ~/.config/pterodactyl/client_key), PTERO_PANEL (default https://panel.tmcdev.net),
#      PTERO_CONSOLE (default ptero-console, prints a server's console for N seconds), GODOT.
# Heavy: one headless client. Run it through heavy/hv. Never prints the key.
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ID=${1:?server id}; ADDR=${2:?host:port}; shift 2
TARGET=""; VIA=mapmenu; SECS=100
while [ $# -gt 0 ]; do
    case $1 in
        --map) TARGET=${2:?}; shift 2 ;;
        --via) VIA=${2:?}; shift 2 ;;
        --secs) SECS=${2:?}; shift 2 ;;
        *) echo "unknown argument $1" >&2; exit 2 ;;
    esac
done
export PTERO_KEY=$(cat "${PTERO_KEY_FILE:-$HOME/.config/pterodactyl/client_key}") || exit 2
export PTERO_PANEL=${PTERO_PANEL:-https://panel.tmcdev.net}
GODOT=${GODOT:-$(command -v godot || echo /home/gamedev/.local/bin/godot)}
CON=${PTERO_CONSOLE:-/home/gamedev/bin/ptero-console}
W=$(mktemp -d); trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$W"' EXIT

# send <command...>: send one console command; $W/con holds the console for the next few seconds.
send() {
    "$CON" "$ID" "${SEND_SECS:-8}" > "$W/con" 2>&1 &
    local p=$!; sleep 2
    python3 -c '
import json,os,sys,urllib.request
r=urllib.request.Request(os.environ["PTERO_PANEL"]+"/api/client/servers/"+sys.argv[1]+"/command",
    data=json.dumps({"command":sys.argv[2]}).encode(),method="POST",
    headers={"Authorization":"Bearer "+os.environ["PTERO_KEY"],"Accept":"application/json","Content-Type":"application/json"})
urllib.request.urlopen(r).read()' "$ID" "$*" >/dev/null
    wait $p
}
running() { send votestatus; grep -aoE 'running +[A-Za-z0-9_:.-]+' "$W/con" | tail -1 | awk '{print $2}'; }

[ -x "$GODOT" ] || { echo "no godot: set GODOT" >&2; exit 2; }
timeout "$SECS" "$GODOT" --headless --path "$HERE" res://client/boot.tscn -- --connect "$ADDR" > "$W/join.log" 2>&1 &
JP=$!
for _ in $(seq 1 "$SECS"); do grep -aq "client   connected" "$W/join.log" && break; sleep 1; done
grep -aq "client   connected" "$W/join.log" || { echo "$ID NOJOIN"; exit 1; }
sleep 10
before=$(running)
if [ -z "$TARGET" ]; then
    send mapmenu
    TARGET=$(grep -aE '^ +[^(]+\([A-Za-z0-9_:.-]+\)[[:space:]]*$' "$W/con" | grep -aoE '\([A-Za-z0-9_:.-]+\)' | tr -d '()' | grep -v '^mode:' | grep -vxF "$before" | head -1)
fi
[ -n "$TARGET" ] || { echo "$ID NOTARGET before=$before"; exit 1; }
case $VIA in
    mapmenu) send mapmenu "$TARGET" ;;
    map) send map "$TARGET" ;;
    rtv) send setnextmap "$TARGET"; send forcertv ;;
    *) echo "unknown --via $VIA" >&2; exit 2 ;;
esac
reply=$(grep -aE "Now on|Changing|Next:|rror|nknown" "$W/con" | tail -1 | cut -c1-120)
res=TIMEOUT; now=$before; i=0
for i in $(seq 1 15); do
    sleep 6; now=$(running)
    [ "$now" = "$TARGET" ] && { res=CHANGED; break; }
done
up=$(kill -0 $JP 2>/dev/null && echo yes || echo no)
echo "$ID $res before=$before target=$TARGET running=$now via=$VIA reply=[$reply] client_still_connected=$up polls=$i"
[ "$res" = CHANGED ]
