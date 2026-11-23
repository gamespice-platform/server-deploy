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
gate() { GS_CHECK_CI_CACHE="$(mktemp -d "$T/cache.XXXXXX")" GS_FORGEJO_ENV=/nonexistent GS_GH="$T/bin/gh" "$@" bash "$T/tools/publish_gate.sh" 2>&1; }

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
# ---- check-ci reads the internal Forgejo first (a fake Forgejo on a local port, a stub `git ls-remote`) ----
cat > "$T/bin/lsremote" <<'LS'
#!/usr/bin/env bash
# GS_LS_REMOTE URL refs/tags/TAG ...: the commit is "c-<slug>"; gamespice-platform/bot is an annotated tag (peeled line)
slug="${1#https://github.com/}"; slug="${slug%.git}"
case "$slug" in
    gamespice-platform/bot) printf 'tagobj\t%s\nc-%s\t%s^{}\n' "$2" "$slug" "$2" ;;
    *) printf 'c-%s\t%s\n' "$slug" "$2" ;;
esac
LS
chmod +x "$T/bin/lsremote"
cat > "$T/bin/gh" <<'GH'
#!/usr/bin/env bash
echo "$2" >> "${GH_LOG:-/dev/null}"
case "$2" in *"${GH_RED:-@none@}"*) echo "completed:failure completed:success" ;; *) echo "completed:success" ;; esac
GH
cat > "$T/fake_forgejo.py" <<'PY'
import http.server, json
# repo -> runs; run = (head_sha, status, run_number, title)
RUNS = {
    "gamespice-platform/audio": [("c-gamespice-platform/audio", "success", 3, "x")],
    "gamespice-platform/bot": [("c-gamespice-platform/bot", "failure", 1, "x"), ("c-gamespice-platform/bot", "success", 2, "x")],
    "gamespice-platform/camera": [("inj-camera", "success", 1, "internal CI: flattened validate.yml (Forgejo copy only)")],
    "gamespice-platform/console": [("c-gamespice-platform/console", "failure", 1, "x")],
    "gamespice-platform/core": [("c-gamespice-platform/core", "running", 1, "x")],
    "gamespice-platform/game": [("some-other-commit", "success", 1, "x")],
    "gamespice-platform/leaderboard": [],
}
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        p = self.path.split("?")[0]
        if self.headers.get("Authorization") != "token tok":
            body, code = {"message": "auth"}, 401
        elif p == "/api/v1/repos/gamespice-platform/camera/git/commits/inj-camera":
            body, code = {"parents": [{"sha": "c-gamespice-platform/camera"}]}, 200
        elif p.endswith("/actions/tasks") and p[len("/api/v1/repos/"):-len("/actions/tasks")] in RUNS:
            slug = p[len("/api/v1/repos/"):-len("/actions/tasks")]
            body, code = {"total_count": 0, "workflow_runs": [
                {"head_sha": s, "status": st, "run_number": n, "display_title": t, "name": "validate", "workflow_id": "ci.yml"}
                for (s, st, n, t) in RUNS[slug]]}, 200
        else:
            body, code = {"message": "nope"}, 404
        b = json.dumps(body).encode()
        self.send_response(code); self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
s = http.server.HTTPServer(("127.0.0.1", 0), H)
print(s.server_address[1], flush=True)
s.serve_forever()
PY
if command -v python3 >/dev/null; then
    python3 -I "$T/fake_forgejo.py" > "$T/port" & FJ_PID=$!
    trap 'kill $FJ_PID 2>/dev/null; rm -rf "$T"' EXIT
    for _ in $(seq 50); do [ -s "$T/port" ] && break; sleep 0.1; done
    printf 'FORGEJO_URL=http://127.0.0.1:%s\nFORGEJO_TOKEN=tok\n' "$(cat "$T/port")" > "$T/forgejo.env"
    cfg() { GS_FORGEJO_ENV="$T/forgejo.env" GS_LS_REMOTE="$T/bin/lsremote" GS_GH="$T/bin/gh" GH_LOG="$T/gh.log" GS_CHECK_CI_CACHE="$T/cache.$1" bash "$T/tools/addons-lock.sh" check-ci 2>&1; }
    # audio: green run on the tag's commit; camera: green run on the injected child commit; bot: annotated tag, newest run
    # green over an older red; browser: no such repo on the fake Forgejo (GitHub answers)
    printf 'gs-audio\tv1\ngs-camera\tv1\ngs-bot\tv1\ngs-browser\tv1\n' > "$T/addons.lock"
    : > "$T/gh.log"
    out="$(cfg 1)"; rc=$?
    [ "$rc" = 0 ] && grep -q "CI is green for all 4" <<<"$out" && ok "check-ci: forgejo green (direct, injected-parent, newest-run-wins) passes" || bad "forgejo green refused: $out"
    grep -q "forgejo 3, github 1" <<<"$out" && ok "check-ci: three tags answered by Forgejo, one by GitHub" || bad "source split wrong: $out"
    [ "$(wc -l < "$T/gh.log")" = 1 ] && grep -q "/browser/" "$T/gh.log" && ok "check-ci: zero GitHub calls for the Forgejo-answered tags" || bad "gh called for: $(cat "$T/gh.log")"
    : > "$T/gh.log"; out="$(cfg 1)"
    [ ! -s "$T/gh.log" ] && ok "check-ci: a second run answers everything from the cache" || bad "second run still calls gh"
    printf 'gs-console\tv1\n' > "$T/addons.lock"
    out="$(cfg 2)"; rc=$?
    [ "$rc" != 0 ] && grep -q "RED.*forgejo" <<<"$out" && ok "check-ci: red on Forgejo is refused" || bad "forgejo red passed: $out"
    printf 'gs-core\tv1\n' > "$T/addons.lock"
    out="$(cfg 3)"; rc=$?
    [ "$rc" != 0 ] && grep -q "has not finished.*forgejo" <<<"$out" && ok "check-ci: a running Forgejo run is refused" || bad "forgejo running passed: $out"
    printf 'gs-game\tv1\ngs-leaderboard\tv1\ngs-menu\tv1\n' > "$T/addons.lock"
    : > "$T/gh.log"; out="$(cfg 4)"; rc=$?
    [ "$rc" = 0 ] && [ "$(wc -l < "$T/gh.log")" = 3 ] && ok "check-ci: other-commit run, no run, not mirrored all fall back to GitHub" || bad "fallback wrong ($rc, $(wc -l < "$T/gh.log") gh calls): $out"
    out="$(GH_RED=menu cfg 5)"; rc=$?
    [ "$rc" != 0 ] && grep -q "RED" <<<"$out" && ok "check-ci: red from the GitHub fallback is still red" || bad "github red passed: $out"
fi

[ "$fails" -eq 0 ]
