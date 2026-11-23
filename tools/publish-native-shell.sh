#!/usr/bin/env bash
# Publishes the archives ./server export-native wrote into build/ through the site's
# native build API (POST {SITE}/api/app/v1/native/build: begin, PUT, finalize), the
# native twin of publish-web-shell.sh --api. Needs only SHELL_PUBLISH_TOKEN.
#
#   tools/publish-native-shell.sh --site https://moddingcommunity.com --version 1.20261121.0300
#
# The native-shell workflow runs this when the shell's inputs change; by hand it is the
# fallback to copying the commands export-native prints. The token comes from the
# environment (SHELL_PUBLISH_TOKEN) and goes through a header file, never an argument.
set -euo pipefail

SITE=${SHELL_API:-}; VERSION=""; APP=${SHELL_APP:-godot}; NOTES=""; DIR="build"
ARGS="--,--connect,{host}:{port},--udp,{host}:{udpPort}"
while [ $# -gt 0 ]; do
    case "$1" in
        --site) SITE="$2"; shift 2 ;;
        --version) VERSION="$2"; shift 2 ;;
        --app) APP="$2"; shift 2 ;;
        --notes) NOTES="$2"; shift 2 ;;
        --dir) DIR="$2"; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done
[ -n "$SITE" ] && [ -n "$VERSION" ] || { echo "need --site and --version" >&2; exit 2; }
# Refuses (no override) over an unpinned lock, a -dirty or missing build stamp, or red addon CI.
"$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/publish_gate.sh" || exit 1
# The EXACT artifacts about to ship, not the repo: no dot_* addons, no uid:// claimed twice (tools/check_artifact_static.sh).
# The Linux zip is the one a dedicated server's shell is cut from; the others hold the same pck. A red check refuses.
if [ -f "$DIR/tmc-linux-x64.zip" ]; then
    "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/check_artifact_static.sh" "$DIR/tmc-linux-x64.zip" \
        || { echo "PUBLISH REFUSED: the native shell artifact failed tools/check_artifact_static.sh" >&2; exit 1; }
fi
[ -n "${SHELL_PUBLISH_TOKEN:-}" ] || { echo "SHELL_PUBLISH_TOKEN is not set" >&2; exit 2; }
SITE=${SITE%/}
hdr=$(mktemp); resp=$(mktemp); trap 'rm -f "$hdr" "$resp"' EXIT
printf 'Authorization: Bearer %s\n' "$SHELL_PUBLISH_TOKEN" > "$hdr"

# platform|archive|entry, the same rows export-native prints.
rows=(
    "LINUX_X64|$DIR/tmc-linux-x64.zip|tmc.x86_64"
    "WINDOWS_X64|$DIR/tmc-windows-x64.zip|tmc.exe"
    "MACOS_UNIVERSAL|$DIR/tmc-macos.zip|TMC.app/Contents/MacOS/TMC"
)
post() { # JSON body -> response body on stdout; fails on a non-2xx
    local code
    code=$(curl -sS -o "$resp" -w '%{http_code}' --max-time 300 -X POST -H @"$hdr" \
        -H 'Content-Type: application/json' --data "$1" "$SITE/api/app/v1/native/build") || code=000
    case "$code" in 2??) cat "$resp" ;; *) echo "HTTP $code: $(cat "$resp" 2>/dev/null)" >&2; return 1 ;; esac
}
for row in "${rows[@]}"; do
    IFS='|' read -r platform file entry <<<"$row"
    [ -f "$file" ] || { echo "missing $file" >&2; exit 1; }
    size=$(stat -c %s "$file"); sha=$(sha256sum "$file" | cut -d' ' -f1)
    base=$(jq -n --arg app "$APP" --arg p "$platform" --arg v "$VERSION" --arg e "$entry" \
        --arg n "$NOTES" --arg a "$ARGS" --arg name "$(basename "$file")" --argjson size "$size" --arg sha "$sha" \
        '{app:$app,platform:$p,version:$v,format:"ZIP",entry:$e,args:($a|split(",")),minClientVersion:null,
          notes:(if $n=="" then null else $n end),enabled:true,file:{name:$name,size:$size,sha256:$sha}}')
    echo "$platform $VERSION  $(basename "$file") $size bytes"
    begun=$(post "$(jq -c '.action="begin"' <<<"$base")")
    if [ "$(jq -r .status <<<"$begun")" = upload ]; then
        url=$(jq -r .put.url <<<"$begun")
        hh=()
        while IFS= read -r line; do hh+=(-H "$line"); done < <(jq -r '.put.headers|to_entries[]|"\(.key): \(.value)"' <<<"$begun")
        curl -sS -f --max-time 1800 -X PUT "${hh[@]}" --upload-file "$file" -o /dev/null "$url" || {
            # Cloudflare caps one upload near 100 MB and the macOS zip is bigger; the other platforms are already out.
            [ "$platform" = MACOS_UNIVERSAL ] && { echo "::warning::macOS upload failed (size cap?); linux and windows were published" >&2; continue; }
            exit 1
        }
    else
        echo "  already in storage, skipping the upload"
    fi
    fin=$(post "$(jq -c '.action="finalize"' <<<"$base")")
    echo "  $(jq -r '"\(.status) \(.url)"' <<<"$fin")"
done
