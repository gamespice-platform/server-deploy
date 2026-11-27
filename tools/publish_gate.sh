#!/usr/bin/env bash
# The gate every shell publish passes first (publish-native-shell.sh, publish-web-shell.sh
# and the native-shell / web-shell workflows). It refuses, loudly and with no override, when:
#   1. addons.lock is not fully pinned (addons-lock.sh check-pins),
#   2. the build stamp (client/build_stamp.gd) is missing or says -dirty: the shell was
#      built from a tree that is not a commit,
#   3. client/content.json (trusted keys) or addons.lock differs from HEAD,
#   4. a pinned addon's CI for its pinned tag is red (addons-lock.sh check-ci, gh API).
# Why: v0.1.150 was tagged over a failing check-pins, and a shell built from an
# uncommitted tree broke the prod solo manifest path (2026-11-22 outage).
#
#   tools/publish_gate.sh                    # exit 0 = may publish, 1 = refused
#   tools/publish_gate.sh --prod [SHA]       # the PROD release gate: the above, plus
#   tools/publish_gate.sh --prod-tag [SHA]   # the same without the stamp checks (release.yml: no build there)
# --prod also refuses when, for the candidate commit SHA (default HEAD; a tag's pin commit walks back over
# commits that touch only web/shell-build*): this repository's CI or Release run is red or unfinished, gs-cloud's
# CI is red, or tools/release_smoke.sh has not recorded a PASS for exactly that SHA (git note on
# refs/notes/release-smoke). There is no flag that skips a check.
# Env: GS_STAMP (stamp file, default client/build_stamp.gd), GS_GH (gh command, default "gh"),
#      GS_REPO (owner/name of this repo for the CI lookup, default $GITHUB_REPOSITORY or gamespice-platform/gs-server-deploy),
#      GS_CLOUD_REPO (default gamespice-platform/gs-cloud).
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
STAMP=${GS_STAMP:-$REPO/client/build_stamp.gd}
fail=0
refuse() { echo "PUBLISH REFUSED: $*" >&2; fail=1; }
prod=0 stamp_checks=1 cand=
while [ $# -gt 0 ]; do
    case $1 in
        --prod) prod=1; shift ;;
        --prod-tag) prod=1; stamp_checks=0; shift ;;
        -*) echo "usage: publish_gate.sh [--prod|--prod-tag] [SHA]" >&2; exit 2 ;;
        *) cand=$1; shift ;;
    esac
done

if ! out=$(cd "$REPO" && bash tools/addons-lock.sh check-pins 2>&1); then
    refuse "addons.lock is not pinned:"; echo "$out" | sed 's/^/    /' >&2
fi

if [ "$stamp_checks" = 0 ]; then
    commit=-
elif [ ! -f "$STAMP" ]; then
    refuse "no build stamp at $STAMP: build with ./server so the shell records its commit"
else
    commit=$(sed -n 's/^const COMMIT := "\(.*\)".*/\1/p' "$STAMP" | head -1)
    case "$commit" in
        "") refuse "build stamp $STAMP has no COMMIT" ;;
        *-dirty*) refuse "build stamp says '$commit': the shell was built from an uncommitted tree; commit, then rebuild" ;;
    esac
fi

# The stamp is written at export; a trust anchor edited after it (a dev or smoke key left in
# client/content.json, which the shell would then TRUST) is invisible to it. Checked on the tree itself.
if git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 && ! git -C "$REPO" diff --quiet HEAD -- client/content.json addons.lock 2>/dev/null; then
    refuse "client/content.json or addons.lock differs from HEAD: a trusted key or pin that is not committed would ship in the shell (git diff HEAD -- client/content.json addons.lock)"
fi

if ! out=$(cd "$REPO" && bash tools/addons-lock.sh check-ci 2>&1); then
    refuse "a pinned addon's CI is red or unfinished for its pinned tag (fix the addon, re-tag, re-pin):"
    echo "$out" | sed 's/^/    /' >&2
fi

if [ "$prod" = 1 ]; then
    read -ra gh <<<"${GS_GH:-gh}"
    slug=${GS_REPO:-${GITHUB_REPOSITORY:-gamespice-platform/gs-server-deploy}}
    sha=$(git -C "$REPO" rev-parse "${cand:-HEAD}^{commit}" 2>/dev/null) || { refuse "candidate ${cand:-HEAD} is not a commit here"; sha=; }
    # A pin commit only moves web/shell-build*: the candidate is the newest commit below it that does more.
    while [ -n "$sha" ] && [ -n "$(git -C "$REPO" diff-tree --no-commit-id --name-only -r "$sha" 2>/dev/null)" ] \
        && ! git -C "$REPO" diff-tree --no-commit-id --name-only -r "$sha" | grep -qv '^web/shell-build'; do
        sha=$(git -C "$REPO" rev-parse "$sha^" 2>/dev/null) || break
    done
    if [ -n "$sha" ]; then
        # 1. this repository: the newest ci.yml run for the candidate must be green; a Release run, when there is one, too.
        runs=$("${gh[@]}" api "repos/$slug/actions/runs?head_sha=$sha&per_page=100" \
            --jq '.workflow_runs[] | ((.path // .name) + " " + .status + ":" + (.conclusion // "none"))' 2>&1) \
            || { refuse "could not read this repository's CI for ${sha:0:12}: $(printf '%s' "$runs" | head -c 200)"; runs=; }
        if [ -n "$runs" ]; then
            ci=$(grep -E '(^|/)ci\.yml ' <<<"$runs" | head -1 | cut -d' ' -f2)
            rel=$(grep -E '(^|/)release\.yml ' <<<"$runs" | head -1 | cut -d' ' -f2)
            [ "$ci" = completed:success ] || refuse "repo CI (ci.yml) for ${sha:0:12} is not green (${ci:-no run}): push it to main and let it finish"
            case "${rel:-completed:success}" in completed:success) ;; *) refuse "Release (release.yml) for ${sha:0:12} is $rel" ;; esac
        elif [ "$fail" = 0 ]; then
            refuse "no CI run at all for ${sha:0:12}"
        fi
        # 2. the smoke result for exactly this commit.
        note=$(git -C "$REPO" notes --ref=release-smoke show "$sha" 2>/dev/null || true)
        case "$note" in
            PASS\ *) ;;
            "") refuse "no candidate smoke result for ${sha:0:12}: run tools/release.sh (tools/release_smoke.sh records the verdict)" ;;
            *) refuse "candidate smoke for ${sha:0:12} did not pass: $(head -1 <<<"$note")" ;;
        esac
    fi
    # 3. gs-cloud: its newest main CI must be green (it signs and serves every manifest the shell verifies).
    cloud=${GS_CLOUD_REPO:-gamespice-platform/gs-cloud}
    cout=$("${gh[@]}" api "repos/$cloud/actions/runs?branch=main&per_page=20" \
        --jq '[.workflow_runs[] | select(.path | endswith("ci.yml"))][0] | (.status + ":" + (.conclusion // "none"))' 2>&1) \
        || { refuse "could not read $cloud's CI: $(printf '%s' "$cout" | head -c 200)"; cout=error; }
    case "$cout" in completed:success|error) ;; *) refuse "$cloud CI on main is not green ($cout)" ;; esac
fi

[ "$fail" = 0 ] && echo "publish gate$([ "$prod" = 1 ] && echo " (prod, ${sha:0:12})"): addons pinned, stamp clean (${commit:-?}), pinned addon CI green"
exit "$fail"
