#!/usr/bin/env bash
#
# An operator's cfg/server/addon/dot_<x>/ files move to gs_<x>/ on boot (the addons were renamed).
#
#   tools/check_dot_cfg_migrate.sh      exit 0 when they do, 1 naming each failure
#
# The addons read only gs_<x>/: before this, a server's dot_auth/auth.yml (its backbone) was ignored and the
# shipped default (the prod backbone) answered instead. Arm it by making migrate_dot_addon_cfg return 0 at once.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

RED=$'\033[31m'; GRN=$'\033[32m'; OFF=$'\033[0m'
fails=0
bad() { printf '  %sFAIL%s %s\n' "$RED" "$OFF" "$1"; fails=$((fails + 1)); }
good() { printf '  %sok%s   %s\n' "$GRN" "$OFF" "$1"; }

eval "$(sed -n '/^# dot_cfg_migrate_begin/,/^# dot_cfg_migrate_end/p' tools/server.in)"
note() { :; }
warn() { printf 'WARN %s\n' "$1"; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PROJECT="$T/p"; CONFIG_DIR="$T/cfg"; A="$CONFIG_DIR/server/addon"
mkdir -p "$PROJECT/cfg.example/server/addon/gs_map" "$A/dot_auth" "$A/dot_map" "$A/dot_console" "$A/gs_map" "$A/gs_console"
echo 'maps: [template]' > "$PROJECT/cfg.example/server/addon/gs_map/maps.yml"
echo 'backbone_url: "https://games.example"' > "$A/dot_auth/auth.yml"
echo 'maps: [operator]' > "$A/dot_map/maps.yml"
cp "$PROJECT/cfg.example/server/addon/gs_map/maps.yml" "$A/gs_map/maps.yml"   # an unedited template copy
echo 'password: old' > "$A/dot_console/rcon.yml"
echo 'password: edited' > "$A/gs_console/rcon.yml"                          # an operator's own edit

# a console/rcon.yml boot seeded with a generated password: the dot_ file (the password in use) takes its place
mkdir -p "$PROJECT/cfg.example/server/addon/gs_console" "$A/dot_console2"
printf 'port: 1\nrcon_password: ""\n' > "$PROJECT/cfg.example/server/addon/gs_console/rcon2.yml"
printf 'port: 1\nrcon_password: "generated"\n' > "$A/gs_console/rcon2.yml"
printf 'port: 1\nrcon_password: "inuse"\n' > "$A/dot_console/rcon2.yml"

out="$(migrate_dot_addon_cfg 2>&1)"
grep -q 'inuse' "$A/gs_console/rcon2.yml" && [ ! -e "$A/dot_console/rcon2.yml" ] && good "a boot-generated rcon_password gives way to the dot_ file's" || bad "the generated rcon_password kept over the dot_ file's"
grep -q 'games.example' "$A/gs_auth/auth.yml" 2>/dev/null && good "dot_auth moves to gs_auth" || bad "dot_auth/auth.yml not moved"
grep -q 'operator' "$A/gs_map/maps.yml" && good "an unedited template copy gives way" || bad "the template copy in gs_map kept"
grep -q 'edited' "$A/gs_console/rcon.yml" && good "an edited gs_ file wins" || bad "an edited gs_console/rcon.yml was overwritten"
[ -f "$A/dot_console/rcon.yml" ] && [[ "$out" == *"WARN cfg/server/addon/dot_console/rcon.yml"* ]] \
    && good "the differing dot_ file stays, named in a warning" || bad "the differing dot_console file: no warning or deleted"
[ ! -d "$A/dot_auth" ] && [ ! -d "$A/dot_map" ] && good "emptied dot_ dirs removed" || bad "empty dot_ dirs left"

cp "$A/gs_console/rcon.yml" "$A/dot_console/rcon.yml"
migrate_dot_addon_cfg >/dev/null 2>&1
[ ! -e "$A/dot_console" ] && good "an identical dot_ file is dropped" || bad "an identical dot_ file kept"

out="$(migrate_dot_addon_cfg 2>&1)"
[ -z "$out" ] && good "a second boot is silent" || bad "a second boot printed: $out"

# setup.sh: a native library still listed in .godot/extension_list.cfg after its addon was renamed
# (dot_sim -> gs_sim) is dropped, so a boot does not print three ERROR lines for it.
ROOT="$T/proj"; mkdir -p "$ROOT/.godot" "$ROOT/addons/gs_sim"; : > "$ROOT/addons/gs_sim/gs_sim.gdextension"
printf 'res://addons/dot_sim/dot_sim.gdextension\nres://addons/gs_sim/gs_sim.gdextension\n' > "$ROOT/.godot/extension_list.cfg"
eval "$(sed -n '/^# A listed library whose file is gone/,/^fi$/p' setup.sh)"
[ "$(cat "$ROOT/.godot/extension_list.cfg")" = "res://addons/gs_sim/gs_sim.gdextension" ] \
    && good "a stale native library is dropped from the extension list" || bad "extension list: $(tr '\n' ' ' < "$ROOT/.godot/extension_list.cfg")"

[ "$fails" -eq 0 ]
