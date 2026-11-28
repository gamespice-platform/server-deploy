#!/usr/bin/env bash
# ONE command that releases a shell from our own boxes: build it, verify it, and only when every
# gate is green upload, pin and tag it. GitHub then only runs CI on the tag (release.yml).
#
#   tools/release-shell.sh web    [--dry-run] [options]
#   tools/release-shell.sh native [--dry-run] [options]
#
# Why: GitHub quota exhaustion stalled releases, and the risk of a release is in build + verify, not in the
# upload. The workflows (web-shell.yml, native-shell.yml) stay as they are; this is the same pipeline run here.
# Run it as the user that owns the checkout (gamedev), from a checkout whose addons are EXACTLY at addons.lock
# (./setup.sh --no-games): publish-web-shell.sh --pin refuses an export from any other tree.
#
# Steps, in order; every one fails loudly, none has an override, a failure stops the release:
#   1 preflight  clean tracked tree, not behind origin/main, addons.lock pinned (check-pins), addons at the lock (check)
#   2 CI         addon CI per locked tag, from the internal Forgejo first (gs-bootstrap tools/ci-red-forgejo.sh);
#                only repos Forgejo has no run for ask GitHub (cached, GS_CHECK_CI_CACHE), after tools/gh-quota.sh
#   3 build      the export, on PH through hv (else this VM through heavy); the inputs it was exported from are recorded
#   4 verify     tools/publish_gate.sh (stamp not -dirty, lock and trust anchor == HEAD, addon CI again, cached);
#                tools/check_solo_smoke.sh against the dev origin; then READ-ONLY against prod: tools/verify-prod-solo.sh
#                when it exists, else check_solo_smoke.sh on the prod origin (several games)
#   5 release    the tree is re-checked unchanged since the build, then upload + pin + tag:
#                web: publish-web-shell.sh --pin (it compares the zip's shell-inputs.txt with the tree, the shell-pin
#                check release.yml runs); native: publish-native-shell.sh (the native shell has no pin and no tag)
# --dry-run runs 1-4 and the publish script's own --dry-run when a publish token is at hand; uploads and tags nothing.
#
# Options (env in brackets):
#   --repo DIR            checkout to release from                       (default: this script's repo)
#   --builder auto|hv|local  where the export runs                        (RELEASE_SHELL_BUILDER, default auto: hv, and
#                         this VM through heavy only when hv is absent or refuses the job, exit 2/3)
#   --api SITE            the site's build API   (WEB_SHELL_API / SHELL_API, default https://moddingcommunity.com)
#   --app NAME            web app segment, native app   (WEB_SHELL_APP / SHELL_APP, default godot)
#   --origin URL          web: read the upload back from it                (WEB_SHELL_ORIGIN)
#   --backbone URL        web: client/auth.json backbone_url               (WEB_SHELL_BACKBONE_URL; else client/auth.json must exist)
#   --dev-origin URL      smoke origin, dev      (RELEASE_SHELL_DEV_ORIGIN, default https://tmcdevgames.net/content)
#   --dev-key FILE        public key PEM the dev content is signed by      (RELEASE_SHELL_DEV_KEY; GS_SMOKE_EXTRA_KEY)
#   --prod-origin URL     smoke origin, prod     (RELEASE_SHELL_PROD_ORIGIN, default https://content.gamespice.net/content)
#   --env FILE            file with SHELL_PUBLISH_TOKEN                    (SHELL_ENV_FILE)
# The prod creator token (SHELL_PUBLISH_TOKEN) comes from the environment or --env and is never printed; the prod
# content key is never read. Exit 0 released (or dry run clean), 1 refused, 2 usage.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/.." && pwd)

die() { echo "RELEASE REFUSED: $*" >&2; exit 1; }
step() { printf '\n== %s\n' "$*"; }
usage() { sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

KIND=${1:-}; [ $# -gt 0 ] && shift
case "$KIND" in web|native) ;; -h|--help|"") usage ;; *) echo "release-shell: unknown kind '$KIND' (web|native)" >&2; usage ;; esac
DRY=0
BUILDER=${RELEASE_SHELL_BUILDER:-auto}
API=${WEB_SHELL_API:-${SHELL_API:-https://moddingcommunity.com}}
APP=${WEB_SHELL_APP:-${SHELL_APP:-godot}}
ORIGIN=${WEB_SHELL_ORIGIN:-}
BACKBONE=${WEB_SHELL_BACKBONE_URL:-}
DEV_ORIGIN=${RELEASE_SHELL_DEV_ORIGIN:-https://tmcdevgames.net/content}
DEV_KEY=${RELEASE_SHELL_DEV_KEY:-}
PROD_ORIGIN=${RELEASE_SHELL_PROD_ORIGIN:-https://content.gamespice.net/content}
ENV_FILE=${SHELL_ENV_FILE:-}
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY=1; shift ;;
        --repo) REPO=${2:?--repo needs a dir}; shift 2 ;;
        --builder) BUILDER=${2:?}; shift 2 ;;
        --api) API=${2:?}; shift 2 ;;
        --app) APP=${2:?}; shift 2 ;;
        --origin) ORIGIN=${2:?}; shift 2 ;;
        --backbone) BACKBONE=${2:?}; shift 2 ;;
        --dev-origin) DEV_ORIGIN=${2:?}; shift 2 ;;
        --dev-key) DEV_KEY=${2:?}; shift 2 ;;
        --prod-origin) PROD_ORIGIN=${2:?}; shift 2 ;;
        --env) ENV_FILE=${2:?}; shift 2 ;;
        -h|--help) usage ;;
        *) echo "release-shell: unknown option $1" >&2; usage ;;
    esac
done
case "$BUILDER" in auto|hv|local) ;; *) echo "release-shell: --builder is auto|hv|local" >&2; exit 2 ;; esac
cd "$REPO" || die "no such repo $REPO"
T="$REPO/tools"
# Overridable only so tools/check_release_shell.sh can run the whole order against stubs.
HV=${RELEASE_SHELL_HV:-/home/gamedev/bin/hv}
FORGEJO_CI=${RELEASE_SHELL_FORGEJO_CI:-/home/gamedev/godot/gs-bootstrap/tools/ci-red-forgejo.sh}

# ---- 1 preflight -------------------------------------------------------------------------------------------------
step "1 preflight"
git rev-parse --git-dir >/dev/null 2>&1 || die "$REPO is not a git checkout"
[ -z "$(git status --porcelain --untracked-files=no)" ] || die "the tree has uncommitted changes (git status): a release is built from a commit"
if ! git fetch -q --tags origin main 2>/dev/null; then die "cannot fetch origin main, so the pin could not be pushed either"; fi
git merge-base --is-ancestor origin/main HEAD || die "HEAD is behind or diverged from origin/main: git pull --ff-only first (publishing would move the tree under the build)"
[ "$(git symbolic-ref --short HEAD 2>/dev/null)" = main ] || die "not on main"
out=$(bash "$T/addons-lock.sh" check-pins 2>&1) || { echo "$out" | sed 's/^/    /' >&2; die "check-pins failed: a yml pin disagrees with addons.lock"; }
echo "  $out"
out=$(bash "$T/addons-lock.sh" check 2>&1) || { echo "$out" | sed 's/^/    /' >&2; die "addons are not at addons.lock: export from a lock-exact clone (./setup.sh --no-games)"; }
echo "  $out" | tail -1

# ---- 2 addon CI, Forgejo first -----------------------------------------------------------------------------------
step "2 addon CI (Forgejo first, GitHub only where Forgejo has no run)"
# The shared url_of (addons-lock.sh) turns a lock row into its GitHub slug; Forgejo mirrors the same owner/repo.
eval "$(sed -n '/^url_of() {/,/^}/p' "$T/addons-lock.sh")"
slug_of() { url_of "$1" | sed -E 's#^https://github.com/##; s#\.git$##'; }
CACHE_REAL=${GS_CHECK_CI_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/gs-check-ci}
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
# A private copy of the finished-green cache: Forgejo-green repos are entered into it so addons-lock.sh check-ci
# (called, not edited) does not ask GitHub about them; the real cache never gets a branch-level result.
export GS_CHECK_CI_CACHE="$WORK/ci-cache"
mkdir -p "$GS_CHECK_CI_CACHE"; cp -a "$CACHE_REAL/." "$GS_CHECK_CI_CACHE/" 2>/dev/null || true
slugs=$(mktemp -p "$WORK"); : > "$slugs"
while IFS=$'\t' read -r repo ref; do
    case "$repo" in ''|'#'*) continue ;; esac
    printf '%s\t%s\t%s\n' "$(slug_of "$repo")" "$repo" "$ref" >> "$slugs"
done < addons.lock
[ -s "$slugs" ] || die "addons.lock lists no addons"
[ -f "$FORGEJO_CI" ] || die "no Forgejo CI reader at $FORGEJO_CI: it lives in gs-bootstrap (tools/ci-red-forgejo.sh); clone gs-bootstrap beside the other repos or set RELEASE_SHELL_FORGEJO_CI"
fj=$(cut -f1 "$slugs" | bash "$FORGEJO_CI" 2>"$WORK/fj.err") || { cat "$WORK/fj.err" >&2; die "the Forgejo CI reader failed (token file? docs/forgejo-ci.md in gs-bootstrap)"; }
fallback=0; red=0
while IFS=$'\t' read -r slug repo ref; do
    state=$(awk -F'\t' -v s="$slug" '$1 == s { print $2; exit }' <<<"$fj")
    case "$state" in
        green) k="$GS_CHECK_CI_CACHE/$(printf '%s@%s' "$slug" "$ref" | tr '/ ' '__')"; echo "forgejo: green" > "$k" ;;
        none|absent|"") fallback=$((fallback + 1)); echo "  github-fallback  $slug ($ref): Forgejo has ${state:-no answer}" ;;
        *) echo "  !!    $slug: Forgejo CI is $state ($(awk -F'\t' -v s="$slug" '$1 == s { print $3, $4; exit }' <<<"$fj"))" >&2; red=1 ;;
    esac
done < "$slugs"
[ "$red" = 0 ] || die "a locked addon's CI is red, cancelled or still running on Forgejo (fix the addon, re-tag, re-lock)"
echo "  Forgejo green for $(( $(wc -l < "$slugs") - fallback )) of $(wc -l < "$slugs") addons; $fallback fall back to GitHub (minus the cached green ones)"
if [ "$fallback" -gt 0 ]; then
    if [ -x "$T/gh-quota.sh" ]; then
        bash "$T/gh-quota.sh" need "$((fallback * 2 + 5))" || { rc=$?; [ "$rc" = 75 ] && die "GitHub API quota too low for the fallback CI reads (gh-quota.sh need, exit 75): wait for the reset"; die "gh-quota.sh failed (exit $rc)"; }
    else
        echo "  note: tools/gh-quota.sh is not on this checkout yet; the GitHub fallback goes unguarded"
    fi
fi
out=$(bash "$T/addons-lock.sh" check-ci 2>&1) || { echo "$out" | sed 's/^/    /' >&2; die "addon CI is red, unfinished or unreadable for a locked tag"; }
echo "  $out" | tail -1

# ---- 3 build -----------------------------------------------------------------------------------------------------
step "3 build ($KIND, builder $BUILDER)"
run_build() { # command... ; PH through hv, this VM through heavy as the fallback
    local rc
    if [ "$BUILDER" != local ] && [ -x "$HV" ]; then
        "$HV" "$REPO" local "$@"; rc=$?
        if [ "$rc" != 2 ] && [ "$rc" != 3 ]; then return "$rc"; fi
        [ "$BUILDER" = hv ] && return "$rc"
        echo "  hv refused the job (exit $rc); building on this VM through heavy"
    elif [ "$BUILDER" = hv ]; then
        echo "  --builder hv but $HV is not executable" >&2; return 2
    fi
    if command -v heavy >/dev/null 2>&1; then heavy -- "$@"; else "$@"; fi
}
if [ "$KIND" = web ]; then
    if [ -n "$BACKBONE" ]; then bash "$T/shell-auth-json.sh" "$BACKBONE" > client/auth.json || die "cannot write client/auth.json"
    else [ -s client/auth.json ] || die "no client/auth.json and no --backbone / WEB_SHELL_BACKBONE_URL (the web shell's sign-in config)"; fi
    rm -f web/build.zip
    run_build ./server export-web --zip || die "export-web failed"
    [ -s web/build.zip ] || die "export-web wrote no web/build.zip"
    [ -f web/build/shell-inputs.txt ] || die "the build carries no shell-inputs.txt (a ./server older than tools/shell-inputs.sh: re-run ./setup.sh --no-games)"
    cp web/build/shell-inputs.txt "$WORK/exported-inputs.txt"
    ! grep -q '^addons	off-lock' "$WORK/exported-inputs.txt" || die "the build was exported with addons that are not at addons.lock"
    bash "$T/shell-inputs.sh" compare "$WORK/exported-inputs.txt" || die "the export's recorded inputs differ from this tree"
    echo "  recorded inputs: $(grep '^inputs' "$WORK/exported-inputs.txt")"
else
    VERSION="1.$(date -u +%Y%m%d).$(date -u +%H%M)"
    rm -f build/tmc-linux-x64.zip build/tmc-windows-x64.zip build/tmc-macos.zip
    run_build ./server export-native --platform all --build-version "$VERSION" || die "export-native failed"
    for f in build/tmc-linux-x64.zip build/tmc-windows-x64.zip build/tmc-macos.zip; do [ -s "$f" ] || die "export-native wrote no $f"; done
    bash "$T/shell-inputs.sh" print > "$WORK/exported-inputs.txt" || die "cannot fingerprint the tree"
    echo "  native version $VERSION; recorded inputs: $(grep '^inputs' "$WORK/exported-inputs.txt")"
fi

# ---- 4 verify ----------------------------------------------------------------------------------------------------
step "4 verify"
bash "$T/publish_gate.sh" || die "publish gate (stamp, pins, trust anchor, addon CI)"
GODOT_BIN=${GODOT:-$(sed -n 's/^GODOT="${TMC_GODOT:-\(.*\)}"$/\1/p' server | head -1)}
smoke() { GODOT=${GODOT_BIN:-godot} "$@"; }
echo "-- solo smoke, dev origin $DEV_ORIGIN"
if [ -n "$DEV_KEY" ]; then
    [ -f "$DEV_KEY" ] || die "--dev-key $DEV_KEY is not a file"
    GS_SMOKE_EXTRA_KEY="$DEV_KEY" GS_CONTENT_ORIGIN="$DEV_ORIGIN" smoke bash "$T/check_solo_smoke.sh" || die "solo smoke failed on the dev origin"
else
    GS_CONTENT_ORIGIN="$DEV_ORIGIN" smoke bash "$T/check_solo_smoke.sh" || die "solo smoke failed on the dev origin (dev content is signed by the tmc-dev key: pass --dev-key)"
fi
echo "-- prod, read-only ($PROD_ORIGIN)"
if [ -x "$T/verify-prod-solo.sh" ]; then
    GS_CONTENT_ORIGIN="$PROD_ORIGIN" bash "$T/verify-prod-solo.sh" || die "verify-prod-solo.sh failed against prod (read-only check)"
else
    echo "  tools/verify-prod-solo.sh is not on this checkout; check_solo_smoke.sh against the prod manifests instead"
    echo "  (it does not measure the second-launch download count; that stays unproven until verify-prod-solo.sh lands)"
    GS_SMOKE_MIN=${GS_SMOKE_MIN:-3} GS_CONTENT_ORIGIN="$PROD_ORIGIN" smoke bash "$T/check_solo_smoke.sh" || die "solo smoke failed against prod manifests"
fi

# ---- 5 release ---------------------------------------------------------------------------------------------------
step "5 release"
[ "$DRY" = 0 ] || echo "  dry run: nothing is uploaded or tagged"
[ -z "$(git status --porcelain --untracked-files=no)" ] || die "the tree changed while it was built and verified"
now=$(bash "$T/shell-inputs.sh" print) || die "cannot fingerprint the tree"
[ "$now" = "$(grep -E '^(lock|inputs)	' "$WORK/exported-inputs.txt")" ] || die "the tree's inputs changed since the export: what was verified is not what would be pinned"
if [ -n "$ENV_FILE" ]; then
    [ -f "$ENV_FILE" ] || die "no such env file $ENV_FILE"
    set -a
    # shellcheck disable=SC1090
    . "$ENV_FILE"
    set +a
fi
have_token=0; [ -n "${SHELL_PUBLISH_TOKEN:-}" ] && have_token=1
[ "$DRY" = 1 ] || [ "$have_token" = 1 ] || die "SHELL_PUBLISH_TOKEN is not set (environment or --env FILE)"
origin=(); [ -z "$ORIGIN" ] || origin=(--origin "$ORIGIN")
notes="Released by tools/release-shell.sh from $(git rev-parse --short HEAD)"
if [ "$KIND" = web ]; then
    pub=(bash "$T/publish-web-shell.sh" --zip web/build.zip --pin --api "$API" --app "$APP" "${origin[@]}" --notes "$notes")
else
    pub=(bash "$T/publish-native-shell.sh" --site "$API" --app "$APP" --version "$VERSION" --notes "$notes")
fi
if [ "$DRY" = 1 ]; then
    if [ "$have_token" = 1 ] && [ "$KIND" = web ]; then "${pub[@]}" --dry-run || die "publish dry run failed"
    else echo "  would run: ${pub[*]}"; fi
    echo; echo "release-shell: DRY RUN OK ($KIND): every gate passed; nothing uploaded, pinned or tagged"
    exit 0
fi
"${pub[@]}" || die "the upload/pin step failed (see above); nothing is retried"
if [ "$KIND" = web ]; then
    tag=$(git describe --tags --exact-match HEAD 2>/dev/null) || die "published, but HEAD carries no tag"
    echo; echo "release-shell: released web shell $(cat web/shell-build) as $tag; GitHub runs release.yml CI on the tag"
else
    echo; echo "release-shell: published native shell $VERSION (the native shell has no pin and no tag)"
fi
