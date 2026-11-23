#!/usr/bin/env bash
# Writes or checks addons.lock: the addon commits a server installs, and the ones the
# published client shell has to be exported from.
#
#   tools/addons-lock.sh write           newest release tag (v*) of every addon
#   tools/addons-lock.sh write v0.1.2    that tag for all of them
#   tools/addons-lock.sh check-pins      content-lists/addons.yml pins equal the lock (offline)
#   tools/addons-lock.sh check           the linked addons are at the lock, and clean
#   tools/addons-lock.sh check-ci        the CI of every locked tag's commit is green (internal Forgejo first, then GitHub API; GH_TOKEN, or GS_GH="sudo -u core gh")
#
# [b]Why a lock at all.[/b] A server's addons used to be whatever each repository's main
# was on the day it was installed, and the shell a player connects with is whatever was
# exported last. Those drift, and a server ahead of the shell refuses the join with "This
# server needs a different build of the game client". setup.sh clones at the locked ref
# and moves its own clones there on --update; `check` is the other half, run before
# `./server export-web` / `export-native`, so the shell that gets published was built
# from the same commits the servers will install.
#
# The list of addons is cfg/content/addons.yml (shipped content-lists/addons.yml), read through
# tools/content_lists.sh rather than repeated -- the rule package_check.sh learned the hard way.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK="$ROOT/addons.lock"

. "$ROOT/tools/content_lists.sh"
mapfile -t REPOS < <(content_addon_repos "$ROOT/cfg" | sort -u)

[ ${#REPOS[@]} -gt 0 ] || { echo "could not read the addon list (cfg/content/addons.yml)" >&2; exit 2; }

# The same owner rule as setup.sh's repo_url: the addons are the organisation's, the one
# pack that is not is its author's.
url_of() {
    case "$1" in
        gs-radio|gs-trail) printf 'https://github.com/zees-games/%s.git\n' "$1" ;;
        gs-*) printf 'https://github.com/gamespice-platform/%s.git\n' "${1#gs-}" ;;
        *)     printf 'https://github.com/zees-games/%s.git\n' "$1" ;;
    esac
}

YML="$ROOT/content-lists/addons.yml"

# repo<TAB>pin of the shipped yml, for the entries that have one. setup.sh prefers these
# pins over the lock, so the two must say the same thing.
yml_pins() {
    awk '/^[[:space:]]*-[[:space:]]*repo:/ { r = $NF; next } /^[[:space:]]*pin:/ && r != "" { print r "\t" $NF; r = "" }' "$YML"
}

export GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/echo

cmd_write() {
    local pin="${1:-}" repo tag failed=() tmp
    tmp="$(mktemp "$ROOT/.addons.lock.XXXXXX")"

    {
        echo "# The addon commits servers install and the client shell is exported from."
        echo "# Written by tools/addons-lock.sh write; read by setup.sh. repo<TAB>ref."
    } > "$tmp"

    for repo in "${REPOS[@]}"; do
        if [ -n "$pin" ]; then
            tag="$(git ls-remote --tags --refs "$(url_of "$repo")" "refs/tags/$pin" 2>/dev/null \
                | awk '{ sub("refs/tags/", "", $2); print $2 }')"
        else
            # Highest version, not most recent: sort -V puts v0.10.0 after v0.9.0.
            tag="$(git ls-remote --tags --refs "$(url_of "$repo")" 'v*' 2>/dev/null \
                | awk '{ sub("refs/tags/", "", $2); print $2 }' | sort -V | tail -1)"
        fi

        if [ -z "$tag" ]; then
            failed+=("$repo")
            continue
        fi

        printf '%s\t%s\n' "$repo" "$tag" >> "$tmp"
    done

    if [ ${#failed[@]} -gt 0 ]; then
        rm -f "$tmp"
        echo "no ${pin:-release} tag for: ${failed[*]}" >&2
        echo "addons.lock left as it was; a lock with holes would install those at main" >&2
        exit 1
    fi

    mv "$tmp" "$LOCK"

    # The shipped yml's pins win over the lock in setup.sh, so they move with it.
    if [ -f "$YML" ]; then
        local ytmp
        ytmp="$(mktemp "$ROOT/.addons.yml.XXXXXX")"
        awk -v lock="$LOCK" '
            BEGIN { while ((getline l < lock) > 0) if (l !~ /^#/) { split(l, f, "\t"); want[f[1]] = f[2] } }
            /^[[:space:]]*-[[:space:]]*repo:/ { r = $NF }
            /^[[:space:]]*pin:/ && (r in want) { sub(/pin:.*/, "pin: " want[r]); r = "" }
            { print }' "$YML" > "$ytmp" && cat "$ytmp" > "$YML"
        rm -f "$ytmp"
    fi
    echo "addons.lock: ${#REPOS[@]} repositories"
    awk '!/^#/ { print $2 }' "$LOCK" | sort | uniq -c | sed 's/^/  /'
}

# Offline: every pin in content-lists/addons.yml equals addons.lock. Hand-edited lock bumps
# left the pins stale once and the web-shell CI failed; setup.sh prefers the pin.
pins_agree() {
    [ -f "$LOCK" ] || { echo "no addons.lock; run: tools/addons-lock.sh write" >&2; return 2; }
    [ -f "$YML" ] || return 0
    local repo ypin ref ok=0
    while IFS=$'\t' read -r repo ypin; do
        ref="$(awk -v r="$repo" '$1 == r { print $2 }' "$LOCK")"
        if [ "$ref" != "$ypin" ]; then
            echo "  !!    $repo: content-lists/addons.yml pins $ypin, addons.lock says ${ref:-nothing}; run: tools/addons-lock.sh write"
            ok=1
        fi
    done < <(yml_pins)
    return "$ok"
}

cmd_check() {
    [ -f "$LOCK" ] || { echo "no addons.lock; run: tools/addons-lock.sh write" >&2; exit 2; }

    local repo name ref dir root want have bad=0 ypin

    pins_agree || bad=1

    for repo in "${REPOS[@]}"; do
        ref="$(awk -v r="$repo" '$1 == r { print $2 }' "$LOCK")"
        name="${repo//-/_}"
        [ "$repo" = "zee-gs-weapons" ] && name="zee_weapons"
        # fc-weapons moved addons/arena_weapons to addons/fc_weapons: whichever setup.sh linked
        # (it follows the checkout's ref) is checked; the legacy one is deprecated and said so.
        if [ "$repo" = "fc-weapons" ]; then
            if [ -e "$ROOT/addons/fc_weapons" ] && [ -e "$ROOT/addons/arena_weapons" ]; then
                echo "  !!    $repo: both addons/fc_weapons and the legacy addons/arena_weapons are here; remove the one $ref does not hold"
                bad=1
                continue
            fi
            [ -e "$ROOT/addons/arena_weapons" ] && name="arena_weapons" \
                && echo "  WRN   $repo: addons/arena_weapons is a legacy directory (deprecated; $repo $ref still holds it, a newer tag holds addons/fc_weapons)"
        fi
        dir="$ROOT/addons/$name"

        if [ -z "$ref" ]; then
            echo "  --    $repo is not in the lock"
            bad=1
            continue
        fi

        if [ ! -e "$dir" ]; then
            echo "  --    $repo: addons/$name is not here"
            bad=1
            continue
        fi

        root="$(git -C "$(cd -P "$dir" && pwd)" rev-parse --show-toplevel 2>/dev/null)" || {
            # A vendored copy has no history to compare; say so rather than guess.
            echo "  ??    $repo: addons/$name is not a checkout (vendored?)"
            continue
        }

        have="$(git -C "$root" rev-parse HEAD)"
        # The COMMIT a tag names. An annotated tag lists twice -- the tag object, then
        # `^{}` for the commit it peels to -- and the tag object's hash is never what a
        # checkout's HEAD is, so taking the first line reported every clone as wrong.
        want="$(git -C "$root" rev-parse -q --verify "refs/tags/$ref^{commit}" 2>/dev/null \
            || git ls-remote "$(url_of "$repo")" "refs/tags/$ref" "refs/tags/$ref^{}" 2>/dev/null \
                | awk '/\^\{\}$/ { peeled = $1 } !first { first = $1 } END { print (peeled != "" ? peeled : first) }')"

        if [ -z "$want" ]; then
            echo "  !!    $repo: $ref does not exist"
            bad=1
        elif [ "$have" != "$want" ]; then
            echo "  !!    $repo is at ${have:0:9}, the lock says $ref (${want:0:9})"
            bad=1
        # --import writes .uid files and re-extracts textures embedded in models (the tag may ship older copies); only source edits count.
        elif [ -n "$(git -C "$root" status --porcelain 2>/dev/null | grep -v -E '\.(uid|import|jpg|jpeg|png|webp)$')" ]; then
            echo "  !!    $repo is at $ref with uncommitted changes"
            bad=1
        fi
    done

    if [ "$bad" -eq 0 ]; then
        echo "every addon is at its locked ref"
    else
        echo
        echo "a shell exported from this tree would not match what servers install."
        echo "check out the locked refs, or re-lock with: tools/addons-lock.sh write"
    fi

    exit "$bad"
}

# Reads the internal Forgejo (docs/forgejo-ci.md in gs-bootstrap) for "slug<TAB>sha" lines on stdin and prints
# "slug<TAB>sha<TAB>green|red|running|none|absent<TAB>detail". Zero GitHub calls. Forgejo mirrors branches (never
# tags), and for repos that call the private reusable workflow it adds one "internal CI:" commit on top of the
# default branch, so a run belongs to a tag's commit when its head sha IS that commit or that injected commit's
# parent is. Per workflow the newest run of that commit counts; any failure or cancel is red.
# env: GS_FORGEJO_ENV (default ~/.config/forgejo/readonly.env: FORGEJO_URL, FORGEJO_TOKEN; never printed).
FORGEJO_PY='
import json, os, sys, urllib.request, urllib.error
cfg = dict(l.rstrip("\n").split("=", 1) for l in open(os.environ["FORGEJO_ENV_FILE"]) if "=" in l)
base, tok = cfg["FORGEJO_URL"].rstrip("/"), cfg["FORGEJO_TOKEN"]
def get(path):
    r = urllib.request.Request(base + "/api/v1" + path, headers={"Authorization": "token " + tok})
    with urllib.request.urlopen(r, timeout=15) as f:
        return json.load(f)
repos, parents = {}, {}
def runs_of(slug):
    if slug not in repos:
        out = []
        try:
            for page in (1, 2, 3):
                got = get("/repos/%s/actions/tasks?limit=50&page=%d" % (slug, page)).get("workflow_runs") or []
                out += got
                if len(got) < 50: break
            repos[slug] = out
        except urllib.error.HTTPError:
            repos[slug] = None
    return repos[slug]
def parents_of(slug, sha):
    k = (slug, sha)
    if k not in parents:
        try:
            parents[k] = [p["sha"] for p in get("/repos/%s/git/commits/%s" % (slug, sha)).get("parents") or []]
        except Exception:
            parents[k] = []
    return parents[k]
for line in sys.stdin:
    f = line.rstrip("\n").split("\t")
    if len(f) < 2: continue
    slug, sha = f[0], f[1]
    try:
        tasks = runs_of(slug)
    except Exception as e:
        print(slug, sha, "absent", "forgejo unreachable", sep="\t"); continue
    if tasks is None:
        print(slug, sha, "absent", "not mirrored", sep="\t"); continue
    mine = [t for t in tasks if t.get("head_sha") == sha]
    for h in {t.get("head_sha") for t in tasks if t.get("head_sha") != sha and str(t.get("display_title", "")).startswith("internal CI:")}:
        if sha in parents_of(slug, h):
            mine += [t for t in tasks if t.get("head_sha") == h]
    if not mine:
        print(slug, sha, "none", "no run for this commit", sep="\t"); continue
    newest = {}
    for t in mine:
        w = t.get("workflow_id")
        if w not in newest or t.get("run_number", 0) > newest[w]: newest[w] = t.get("run_number", 0)
    cur = [t for t in mine if t.get("run_number", 0) == newest[t.get("workflow_id")]]
    st = {t["status"] for t in cur}
    bad = sorted({"%s:%s" % (t["name"], t["status"]) for t in cur if t["status"] in ("failure", "cancelled")})
    if bad:
        print(slug, sha, "red", " ".join(bad)[:120], sep="\t")
    elif st & {"running", "waiting", "blocked"}:
        print(slug, sha, "running", " ".join(sorted(st)), sep="\t")
    else:
        print(slug, sha, "green", " ".join(sorted(st)), sep="\t")
'

# The commit a tag points at, over the git protocol (no REST call): the peeled one for an annotated tag.
tag_commit() {
    local url="$1" tag="$2" lines
    lines="$(${GS_LS_REMOTE:-git ls-remote} "$url" "refs/tags/$tag" "refs/tags/$tag^{}" 2>/dev/null)" || return 1
    { grep -F "refs/tags/$tag^{}" <<<"$lines" || grep -F "refs/tags/$tag" <<<"$lines"; } | head -1 | cut -f1
}

# [b]A shell is never published from addons whose own CI is red.[/b] 2026-11-22: gs-cloud CI had been red
# since the rename commit, tags were cut and consumed anyway, and the red was read as noise until prod solo
# broke. For every locked tag this reads the CI of the tag's commit: first from the internal Forgejo (zero
# GitHub calls; the tag's commit is read with git ls-remote and matched to a run by head sha), and only when
# Forgejo has no run for that commit from GitHub's check runs. Any failed, cancelled or timed-out run, any run
# still going, or no run at all, refuses. There is no override: fix the addon's CI (or re-tag a green commit)
# and re-lock. Finished-green results are cached on disk (tags are never rewritten).
cmd_check_ci() {
    local repo ref slug out bad=0 gh n=0 nf=0 ng=0 nc=0 sha url state detail
    read -ra gh <<<"${GS_GH:-gh}"
    [ -f "$LOCK" ] || { echo "no addons.lock; run: tools/addons-lock.sh write" >&2; exit 2; }
    local CI_CACHE="${GS_CHECK_CI_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/gs-check-ci}"
    mkdir -p "$CI_CACHE" 2>/dev/null || CI_CACHE="$(mktemp -d)"
    local fenv="${GS_FORGEJO_ENV:-$HOME/.config/forgejo/readonly.env}" fj; fj="$(mktemp)"
    trap 'rm -f "$fj"' EXIT
    local -A SHA=() FJ=()
    # Pass 1: the uncached entries' commits, and one Forgejo question for all of them.
    if [ -r "$fenv" ] && command -v python3 >/dev/null; then
        local q="" ckey0
        while IFS=$'\t' read -r repo ref; do
            case "$repo" in ''|'#'*) continue ;; esac
            slug="$(url_of "$repo" | sed -E 's#^https://github.com/##; s#\.git$##')"
            ckey0="$CI_CACHE/$(printf '%s@%s' "$slug" "$ref" | tr '/ ' '__')"
            [ -s "$ckey0" ] && continue
            sha="$(tag_commit "$(url_of "$repo")" "$ref")" || sha=""
            [ -n "$sha" ] || continue
            SHA["$slug@$ref"]="$sha"
            q+="$slug"$'\t'"$sha"$'\n'
        done < "$LOCK"
        if [ -n "$q" ]; then
            printf '%s' "$q" | FORGEJO_ENV_FILE="$fenv" python3 -I -c "$FORGEJO_PY" > "$fj" 2>/dev/null || true
            while IFS=$'\t' read -r slug sha state detail; do
                FJ["$slug $sha"]="$state"$'\t'"$detail"
            done < "$fj"
        fi
    fi
    while IFS=$'\t' read -r repo ref; do
        case "$repo" in ''|'#'*) continue ;; esac
        slug="$(url_of "$repo" | sed -E 's#^https://github.com/##; s#\.git$##')"
        # A finished green result for a tag is kept on disk and never asked again (tags are never rewritten):
        # every gate and agent re-running this was ~78 API calls each and exhausted the shared 5000/hr quota.
        # Red, unfinished or unreadable results are never cached.
        ckey="$CI_CACHE/$(printf '%s@%s' "$slug" "$ref" | tr '/ ' '__')"
        if [ -s "$ckey" ]; then
            n=$((n + 1)); nc=$((nc + 1)); continue
        fi
        sha="${SHA["$slug@$ref"]:-}"
        if [ -n "$sha" ] && [ -n "${FJ["$slug $sha"]:-}" ]; then
            state="${FJ["$slug $sha"]%%$'\t'*}"; detail="${FJ["$slug $sha"]#*$'\t'}"
            case "$state" in
                green)
                    n=$((n + 1)); nf=$((nf + 1))
                    printf 'forgejo: %s\n' "$detail" > "$ckey" 2>/dev/null || true
                    continue ;;
                red)
                    echo "  !!    $repo $ref: CI is RED on this tag's commit ($slug, forgejo): $detail"; bad=1; continue ;;
                running)
                    echo "  !!    $repo $ref: CI has not finished on this tag's commit ($slug, forgejo): $detail"; bad=1; continue ;;
            esac
            # none / absent: Forgejo has nothing for this commit; GitHub answers.
        fi
        command -v "${gh[0]}" >/dev/null || { echo "check-ci: no gh (GitHub CLI) to ask about the addons' CI" >&2; exit 2; }
        out="$("${gh[@]}" api "repos/$slug/commits/$ref/check-runs?per_page=100" \
            --jq '[.check_runs[] | (.status + ":" + (.conclusion // "none"))] | join(" ")' 2>&1)" || {
            echo "  !!    $repo $ref: could not read its CI ($slug): $(printf '%s' "$out" | head -c 200)"
            bad=1; continue
        }
        n=$((n + 1)); ng=$((ng + 1))
        if [ -z "$out" ]; then
            echo "  !!    $repo $ref: no CI ran on this tag's commit ($slug)"; bad=1
        elif grep -qE 'completed:(failure|cancelled|timed_out|action_required|startup_failure|stale)' <<<"$out"; then
            echo "  !!    $repo $ref: CI is RED on this tag's commit ($slug): $out"; bad=1
        elif grep -qE '(queued|in_progress|waiting|pending|requested):' <<<"$out"; then
            echo "  !!    $repo $ref: CI has not finished on this tag's commit ($slug): $out"; bad=1
        else
            printf '%s\n' "$out" > "$ckey" 2>/dev/null || true
        fi
    done < "$LOCK"
    echo "check-ci: answered by cache $nc, forgejo $nf, github $ng" >&2
    if [ "$bad" -eq 0 ]; then
        echo "CI is green for all $n locked tags"
    else
        echo
        echo "a shell must not be published from addons whose own CI is red. Fix the addon, tag a green commit, re-lock."
    fi
    exit "$bad"
}

case "${1:-}" in
    check-ci) cmd_check_ci ;;
    write) shift; cmd_write "${1:-}" ;;
    check) cmd_check ;;
    check-pins) pins_agree; rc=$?; [ "$rc" -eq 0 ] && echo "every yml pin matches addons.lock"; exit "$rc" ;;
    *) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
