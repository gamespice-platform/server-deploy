#!/usr/bin/env bash
# Proves tools/publish_gate.sh refuses what it must and passes the good path, offline: a scratch copy of the
# gate and its lock, a stub `gh` standing in for the GitHub check-runs API. Run by tools/check.sh.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fails=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fails=$((fails + 1)); }

mkdir -p "$T/tools" "$T/content-lists" "$T/client" "$T/bin"
cp "$ROOT"/tools/{publish_gate.sh,addons-lock.sh,content_lists.sh} "$T/tools/"
cp "$ROOT/addons.lock" "$T/"; cp "$ROOT/content-lists/addons.yml" "$T/content-lists/"
# gh stub: answers a green check run unless GH_RED names the repo.
cat > "$T/bin/gh" <<'GH'
#!/usr/bin/env bash
case "$2" in *"${GH_RED:-@none@}"*) echo "completed:failure completed:success" ;; *) echo "completed:success" ;; esac
GH
chmod +x "$T/bin/gh"
stamp() { printf 'const COMMIT := "%s"\n' "$1" > "$T/client/build_stamp.gd"; }
gate() { GS_GH="$T/bin/gh" "$@" bash "$T/tools/publish_gate.sh" 2>&1; }

stamp abc1234
out="$(gate env)"; rc=$?
[ "$rc" = 0 ] && ok "clean stamp, pinned lock, green CI: publishes" || { bad "good path refused: $out"; }

stamp abc1234-dirty
out="$(gate env)"; rc=$?
[ "$rc" != 0 ] && grep -q "uncommitted tree" <<<"$out" && ok "-dirty stamp is refused" || bad "-dirty stamp passed: $out"

rm -f "$T/client/build_stamp.gd"
out="$(gate env)"; rc=$?
[ "$rc" != 0 ] && grep -q "no build stamp" <<<"$out" && ok "missing stamp is refused" || bad "missing stamp passed: $out"

stamp abc1234
red="$(awk -F'\t' '!/^#/ && NF {print $1; exit}' "$T/addons.lock")"
out="$(gate env GH_RED="$red")"; rc=$?
[ "$rc" != 0 ] && grep -q "RED" <<<"$out" && ok "red addon CI ($red) is refused" || bad "red CI passed: $out"

# A trusted key left in client/content.json after the stamp was written: the stamp is clean, the tree is not.
git -C "$T" init -q && cp "$ROOT/client/content.json" "$T/client/content.json" \
    && git -C "$T" add client/content.json addons.lock \
    && git -C "$T" -c user.email=t@t -c user.name=t commit -qm base
stamp abc1234
out="$(gate env)"; rc=$?
[ "$rc" = 0 ] && ok "committed client/content.json and addons.lock publish" || bad "committed tree refused: $out"
printf '{"trusted_keys":{"smoke-extra":"x"}}' > "$T/client/content.json"
out="$(gate env)"; rc=$?
[ "$rc" != 0 ] && grep -q "differs from HEAD" <<<"$out" && ok "modified client/content.json is refused" || bad "modified content.json passed: $out"
git -C "$T" checkout -q client/content.json

# An unpinned lock: a yml pin that disagrees with addons.lock.
pin_repo="$(awk '/^[[:space:]]*-[[:space:]]*repo:/ { r = $NF; next } /^[[:space:]]*pin:/ && r != "" { print r; exit }' "$T/content-lists/addons.yml")"
if [ -n "$pin_repo" ]; then
    sed -i -E "/repo:[[:space:]]*$pin_repo\$/,/pin:/ s/(pin:[[:space:]]*).*/\1v9.9.9/" "$T/content-lists/addons.yml"
    out="$(gate env)"; rc=$?
    [ "$rc" != 0 ] && grep -q "not pinned" <<<"$out" && ok "unpinned lock ($pin_repo) is refused" || bad "unpinned lock passed: $out"
else
    ok "no yml pins to disagree with (unpinned-lock case skipped)"
fi
[ "$fails" -eq 0 ]
