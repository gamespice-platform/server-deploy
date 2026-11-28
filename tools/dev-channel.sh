#!/usr/bin/env bash
# The DEV channel: builds the shell of origin/main (or any ref, e.g. a dev tag) and publishes it to the LAN dev CDN
# (x-tmc-storez, GS_CDN_URL) through tools/dev-shell.sh -> dev-shell-publish.sh. Pushes to main are free; this is what
# makes them visible to the dev sites. It is NOT the release: it never touches the prod bucket, never creates or pushes a
# tag or a commit, and is not prod-gated (tools/publish_gate.sh --prod is the release's gate, docs/releases.md).
#
#   tools/dev-channel.sh [--ref REF] [--force]      build and publish when the shell-inputs fingerprint changed
#   tools/dev-channel.sh --async [...]              the same, detached (nohup); returns at once, log in the state dir
#   tools/dev-channel.sh --status                   last published fingerprint and the last failure, if any
#
# Run it from cron/a systemd timer on the box that hosts the dev CDN (GitHub-hosted runners cannot reach the LAN), e.g.
#   */5 * * * * sudo -u gamedev /home/gamedev/godot/gs-server-deploy/tools/dev-channel.sh --async
# It works in its own checkout (DEV_CHANNEL_DIR, default ~/.cache/gs-dev-channel/gs-server-deploy; cloned from this repo's
# origin on first use), so a developer's tree is never touched. Rebuilds only when tools/shell-inputs.sh's fingerprint
# differs from the last published one (state file), so a push that changes no shell input costs one fetch.
# Fails loudly: non-zero exit, the reason on stderr and in the log, and a FAILED file in the state dir that stays until
# the next success. One run at a time (flock).
# Env: DEV_CHANNEL_DIR, DEV_CHANNEL_STATE (default ~/.local/state/gs-dev-channel), DEV_CHANNEL_REMOTE (default this
#      repo's origin), DEV_CHANNEL_BUILD (command that builds+publishes in the checkout; default "heavy -- tools/dev-shell.sh").
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
state=${DEV_CHANNEL_STATE:-$HOME/.local/state/gs-dev-channel}
dir=${DEV_CHANNEL_DIR:-$HOME/.cache/gs-dev-channel/gs-server-deploy}
remote=${DEV_CHANNEL_REMOTE:-$(git -C "$REPO" remote get-url origin 2>/dev/null || true)}
build=${DEV_CHANNEL_BUILD:-heavy -- tools/dev-shell.sh}
ref=origin/main force=0 async=0 status=0
while [ $# -gt 0 ]; do
    case $1 in
        --ref) ref=${2:?--ref needs a ref}; shift 2 ;;
        --force) force=1; shift ;;
        --async) async=1; shift ;;
        --status) status=1; shift ;;
        *) echo "usage: dev-channel.sh [--ref REF] [--force] [--async] | --status" >&2; exit 2 ;;
    esac
done
mkdir -p "$state"
if [ "$status" = 1 ]; then
    echo "published: $(cat "$state/published" 2>/dev/null || echo none)"
    [ -f "$state/FAILED" ] && { echo "FAILED: $(cat "$state/FAILED")"; exit 1; }
    exit 0
fi
if [ "$async" = 1 ]; then
    args=(--ref "$ref"); [ "$force" = 1 ] && args+=(--force)
    nohup "$0" "${args[@]}" >> "$state/log" 2>&1 < /dev/null &
    echo "dev channel started in the background (pid $!, log $state/log)"
    exit 0
fi

fail() { echo "DEV CHANNEL FAILED: $*" >&2; printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" > "$state/FAILED"; exit 1; }
exec 9> "$state/lock"
flock -n 9 || { echo "dev channel: another run holds the lock; nothing to do"; exit 0; }
[ -n "$remote" ] || fail "no remote: set DEV_CHANNEL_REMOTE"
if [ ! -d "$dir/.git" ]; then
    mkdir -p "$(dirname "$dir")"
    git clone -q "$remote" "$dir" || fail "cannot clone $remote"
fi
cd "$dir"
git fetch -q --tags origin || fail "git fetch failed"
git rev-parse --verify -q "$ref^{commit}" >/dev/null || fail "ref $ref does not exist"
git checkout -q --detach "$ref" || fail "cannot check out $ref"
git reset -q --hard HEAD && git clean -qfd -e web/build -e addons || true
sha=$(git rev-parse --short HEAD)
fp=$(tools/shell-inputs.sh print | sha256sum | cut -c1-32) || fail "shell-inputs.sh print failed"
if [ "$force" = 0 ] && [ "$(cat "$state/published" 2>/dev/null || true)" = "$fp" ]; then
    echo "dev channel: $sha has the shell inputs already published ($fp); nothing to build"
    exit 0
fi
echo "dev channel: building $sha ($ref), inputs $fp"
# dev-shell.sh refuses the prod backbone and publishes through the dev site API to storez; no tag, no prod bucket.
# shellcheck disable=SC2086
$build || fail "the dev shell build/publish failed for $sha (log: $state/log)"
printf '%s\n' "$fp" > "$state/published"
printf '%s %s\n' "$sha" "$(date -u +%FT%TZ)" > "$state/published.at"
rm -f "$state/FAILED"
echo "dev channel: published $sha to the dev CDN"
