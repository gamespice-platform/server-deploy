#!/usr/bin/env bash
# Proves tools/release-shell.sh runs build -> verify -> release in order and stops at every red gate, offline:
# a scratch repo with a bare origin, stub Forgejo reader, hv, ./server, gate, smoke and publish scripts that log
# their calls. Nothing is uploaded or tagged for real. Run by tools/check.sh.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fails=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fails=$((fails + 1)); }
git init -q --bare -b main "$T/origin.git"
R="$T/repo"; mkdir -p "$R/tools" "$R/web" "$R/client" "$T/bin"
cd "$R" || exit 1; git init -q -b main
cp "$ROOT/tools/release-shell.sh" tools/
{ sed -n '/^url_of() {/,/^}/p' "$ROOT/tools/addons-lock.sh"
  cat <<'S'
echo "addons-lock $1" >> "$LOG"
case "$1" in
    check-ci) echo "cache: $(ls "$GS_CHECK_CI_CACHE" | tr '\n' ' ')" >> "$LOG"; [ -z "${CI_FAIL:-}" ] || { echo red; exit 1; } ;;
esac
echo "addons ok"
S
} > tools/addons-lock.sh
cat > tools/shell-inputs.sh <<'S'
#!/usr/bin/env bash
case "$1" in print) printf 'lock\tL1\ninputs\tI1\n' ;; compare) grep -q 'inputs.I1' "$2" ;; esac
S
cat > tools/publish_gate.sh <<'S'
#!/usr/bin/env bash
echo "gate" >> "$LOG"; [ -z "${GATE_FAIL:-}" ] || { echo "uncommitted tree"; exit 1; }
S
cat > tools/check_solo_smoke.sh <<'S'
#!/usr/bin/env bash
echo "smoke $GS_CONTENT_ORIGIN" >> "$LOG"; case "$GS_CONTENT_ORIGIN" in *"${SMOKE_FAIL:-@none@}"*) exit 1 ;; esac
S
cat > tools/shell-auth-json.sh <<'S'
#!/usr/bin/env bash
echo '{}'
S
cat > tools/publish-web-shell.sh <<'S'
#!/usr/bin/env bash
echo "publish-web $*" >> "$LOG"; case " $* " in *" --dry-run "*) ;; *) git tag -f shell-test >/dev/null ;; esac
S
cat > tools/publish-native-shell.sh <<'S'
#!/usr/bin/env bash
echo "publish-native $*" >> "$LOG"
S
cat > server <<'S'
#!/usr/bin/env bash
echo "build $*" >> "$LOG"
case "$1" in
    export-web) mkdir -p web/build; echo zip > web/build.zip; printf 'lock\tL1\ninputs\tI1\n' > web/build/shell-inputs.txt ;;
    export-native) mkdir -p build; for p in linux-x64 windows-x64 macos; do echo z > "build/tmc-$p.zip"; done ;;
esac
S
cat > "$T/bin/hv" <<'S'
#!/usr/bin/env bash
shift 2; exec "$@"
S
cat > "$T/bin/forgejo" <<'S'
#!/usr/bin/env bash
while read -r s; do
    case "$s" in "${FJ_RED:-@none@}") st=red ;; "${FJ_NONE:-@none@}") st=none ;; *) st=green ;; esac
    printf '%s\t%s\t-\t-\n' "$s" "$st"
done
S
printf 'gs-foo\tv1\nzed-bar\tv2\n' > addons.lock
echo 1 > web/shell-build; echo '{}' > client/auth.json; echo 'web/build*' > .gitignore; echo 'build/' >> .gitignore
chmod +x tools/*.sh server "$T/bin/"*
git add -A; git -c user.email=t@t -c user.name=t commit -qm base
git remote add origin "$T/origin.git"; git push -q origin main 2>/dev/null
export LOG="$T/log" HOME="$T/home" XDG_CACHE_HOME="$T/cache" SHELL_PUBLISH_TOKEN=tok
export RELEASE_SHELL_HV="$T/bin/hv" RELEASE_SHELL_FORGEJO_CI="$T/bin/forgejo" RELEASE_SHELL_BUILDER=hv
mkdir -p "$HOME"
run() { : > "$LOG"; git tag -d shell-test >/dev/null 2>&1; bash tools/release-shell.sh "$@" 2>&1; }

out=$(run web --dry-run); rc=$?
[ $rc = 0 ] && grep -q '^build export-web' "$LOG" && grep -q '^smoke .*tmcdevgames' "$LOG" && grep -q '^smoke .*content.gamespice' "$LOG" \
    && grep -q '^publish-web .*--dry-run' "$LOG" && ! git tag | grep -q shell-test && ok "web --dry-run: build, both smokes, publish dry run, no tag" || bad "dry run: rc=$rc $out"
out=$(run web); rc=$?
[ $rc = 0 ] && grep -q '^publish-web .*--pin' "$LOG" && git tag | grep -q shell-test && ok "web: uploads with --pin and tags" || bad "web release: rc=$rc $out"
order=$(grep -nE '^(build|gate|smoke|publish)' "$LOG" | cut -d: -f2 | cut -d' ' -f1 | tr '\n' ' ')
[ "$order" = "build gate smoke smoke publish-web " ] && ok "order is build, gate, dev smoke, prod smoke, publish" || bad "order: $order"
out=$(run native); rc=$?
[ $rc = 0 ] && grep -q '^build export-native' "$LOG" && grep -q '^publish-native .*--version 1\.' "$LOG" && ok "native: build then upload" || bad "native: rc=$rc $out"

echo dirty >> tools/shell-auth-json.sh
out=$(run web); rc=$?
[ $rc != 0 ] && ! grep -q '^build' "$LOG" && ok "dirty tree refused before any build" || bad "dirty tree: rc=$rc"
git checkout -q tools/shell-auth-json.sh

out=$(FJ_RED=gamespice-platform/foo run web); rc=$?
[ $rc != 0 ] && ! grep -q '^build' "$LOG" && grep -q 'CI is red' <<<"$out" && ok "red Forgejo CI refused before the build" || bad "red forgejo: rc=$rc $out"

out=$(FJ_NONE=zees-games/zed-bar run web --dry-run); rc=$?
grep -q 'github-fallback  zees-games/zed-bar' <<<"$out" && grep -q 'cache: .*gamespice-platform_foo' "$LOG" && ! grep -q 'cache: .*zed-bar' "$LOG" \
    && ok "GitHub fallback only for the repo Forgejo has no run for" || bad "fallback: $(grep cache "$LOG")"

out=$(CI_FAIL=1 run web); rc=$?
[ $rc != 0 ] && ! grep -q '^build' "$LOG" && ok "red check-ci stops before the build" || bad "check-ci red: rc=$rc"
out=$(GATE_FAIL=1 run web); rc=$?
[ $rc != 0 ] && grep -q '^build' "$LOG" && ! grep -q '^smoke\|^publish' "$LOG" && ok "-dirty/red gate after the build stops before smoke and upload" || bad "gate fail: rc=$rc"
out=$(SMOKE_FAIL=tmcdevgames run web); rc=$?
[ $rc != 0 ] && ! grep -q '^publish' "$LOG" && ok "failed dev smoke blocks the upload" || bad "dev smoke: rc=$rc"
out=$(SMOKE_FAIL=gamespice run web); rc=$?
[ $rc != 0 ] && ! grep -q '^publish' "$LOG" && ok "failed prod check blocks the upload" || bad "prod smoke: rc=$rc"
out=$(SHELL_PUBLISH_TOKEN="" run web); rc=$?
[ $rc != 0 ] && ! grep -q '^publish' "$LOG" && ok "no publish token: refused, nothing uploaded" || bad "no token: rc=$rc"
cp tools/release-shell.sh "$T/rs.bak"; echo >> tools/shell-inputs.sh
out=$(run web); rc=$?
[ $rc != 0 ] || bad "unexpected pass with dirty inputs"; git checkout -q tools/shell-inputs.sh
[ "$fails" -eq 0 ]
