#!/usr/bin/env bash
# Offline test of tools/dev-channel.sh: a stub build, a local "remote". It checks that the dev channel builds the first time, skips when
# the shell inputs did not change, rebuilds when they did, fails loudly (exit 1, FAILED file) when the build fails, and never creates a tag.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/.." && pwd)
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
fails=0
ok() { printf '  ok   dev-channel: %s\n' "$1"; }
bad() { printf '  FAIL dev-channel: %s\n' "$1"; fails=$((fails + 1)); }
git init -q -b main "$t/remote" && cd "$t/remote" && git config user.email t@t && git config user.name t
mkdir -p tools web; cp "$REPO/tools/shell-inputs.sh" tools/; cp "$REPO/tools/dev-channel.sh" tools/
for f in $(cd "$REPO" && tools/shell-inputs.sh paths 2>/dev/null); do [ -f "$REPO/$f" ] && { mkdir -p "$(dirname "$f")"; cp "$REPO/$f" "$f"; }; done
git add -A && git commit -qm base
export DEV_CHANNEL_REMOTE="$t/remote" DEV_CHANNEL_DIR="$t/work" DEV_CHANNEL_STATE="$t/state"
export DEV_CHANNEL_BUILD="touch $t/built"
run() { bash "$REPO/tools/dev-channel.sh" "$@" > "$t/out" 2>&1; }
run && [ -f "$t/built" ] && ok "first run builds" || { bad "first run did not build: $(tail -2 "$t/out")"; }
rm -f "$t/built"; run && [ ! -f "$t/built" ] && grep -q "nothing to build" "$t/out" && ok "unchanged inputs: no rebuild" || bad "rebuilt with unchanged inputs"
run --force && [ -f "$t/built" ] && ok "--force rebuilds" || bad "--force did not rebuild"
# a change to a shell input rebuilds
first=$("$REPO/tools/shell-inputs.sh" paths 2>/dev/null | head -1)
if [ -n "$first" ] && [ -f "$first" ]; then
  rm -f "$t/built"; echo "# change" >> "$first"; git commit -qam change
  run && [ -f "$t/built" ] && ok "a changed shell input rebuilds" || bad "changed input did not rebuild"
else bad "no shell input path to change"; fi
# a failing build is loud
export DEV_CHANNEL_BUILD="false"; echo x >> "$first"; git commit -qam again
run; rc=$?
{ [ "$rc" -eq 1 ] && [ -f "$t/state/FAILED" ] && grep -q "DEV CHANNEL FAILED" "$t/out"; } && ok "a failed build exits 1 and leaves FAILED" || bad "failed build was quiet (rc=$rc)"
[ -z "$(git -C "$t/remote" tag)$(git -C "$t/work" tag)" ] && ok "no tag created" || bad "a tag appeared"
[ "$fails" -eq 0 ]
