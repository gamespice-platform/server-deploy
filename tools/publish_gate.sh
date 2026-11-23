#!/usr/bin/env bash
# The gate every shell publish passes first (publish-native-shell.sh, publish-web-shell.sh
# and the native-shell / web-shell workflows). It refuses, loudly and with no override, when:
#   1. addons.lock is not fully pinned (addons-lock.sh check-pins),
#   2. the build stamp (client/build_stamp.gd) is missing or says -dirty: the shell was
#      built from a tree that is not a commit,
#   3. a pinned addon's CI for its pinned tag is red (addons-lock.sh check-ci, gh API).
# Why: v0.1.150 was tagged over a failing check-pins, and a shell built from an
# uncommitted tree broke the prod solo manifest path (2026-11-22 outage).
#
#   tools/publish_gate.sh            # exit 0 = may publish, 1 = refused
# Env: GS_STAMP (stamp file, default client/build_stamp.gd), GS_GH (gh command, default "gh").
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
STAMP=${GS_STAMP:-$REPO/client/build_stamp.gd}
fail=0
refuse() { echo "PUBLISH REFUSED: $*" >&2; fail=1; }

if ! out=$(cd "$REPO" && bash tools/addons-lock.sh check-pins 2>&1); then
    refuse "addons.lock is not pinned:"; echo "$out" | sed 's/^/    /' >&2
fi

if [ ! -f "$STAMP" ]; then
    refuse "no build stamp at $STAMP: build with ./server so the shell records its commit"
else
    commit=$(sed -n 's/^const COMMIT := "\(.*\)".*/\1/p' "$STAMP" | head -1)
    case "$commit" in
        "") refuse "build stamp $STAMP has no COMMIT" ;;
        *-dirty*) refuse "build stamp says '$commit': the shell was built from an uncommitted tree; commit, then rebuild" ;;
    esac
fi

if ! out=$(cd "$REPO" && bash tools/addons-lock.sh check-ci 2>&1); then
    refuse "a pinned addon's CI is red or unfinished for its pinned tag (fix the addon, re-tag, re-pin):"
    echo "$out" | sed 's/^/    /' >&2
fi

[ "$fail" = 0 ] && echo "publish gate: addons pinned, stamp clean (${commit:-?}), pinned addon CI green"
exit "$fail"
