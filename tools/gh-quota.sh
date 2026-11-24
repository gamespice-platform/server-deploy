#!/usr/bin/env bash
# GitHub REST quota guard. The rate_limit endpoint itself costs no quota.
#   gh-quota.sh status    print remaining/limit/reset
#   gh-quota.sh need N    exit 0 if remaining >= N + reserve, else print reset, exit 75
#   gh-quota.sh wait N    sleep (never past the reset time) until the quota covers N
# Env: GH_QUOTA_RESERVE (default 300), GH_QUOTA_CMD (command printing
# "remaining limit reset", default reads `sudo -u core gh api rate_limit`).
set -u
RESERVE="${GH_QUOTA_RESERVE:-300}"

fetch() {
  if [ -n "${GH_QUOTA_CMD:-}" ]; then
    $GH_QUOTA_CMD
  else
    local gh=(gh)
    [ "$(id -un)" = core ] || gh=(sudo -n -u core gh)
    "${gh[@]}" api rate_limit --jq '.resources.core | "\(.remaining) \(.limit) \(.reset)"'
  fi
}

read_quota() {
  local out
  out="$(fetch 2>/dev/null)" || { echo "gh-quota: rate_limit call failed" >&2; return 2; }
  read -r REMAINING LIMIT RESET <<<"$out"
  case "$REMAINING$LIMIT$RESET" in *[!0-9]*|"") echo "gh-quota: bad rate_limit output: $out" >&2; return 2;; esac
}

reset_str() { date -d "@$RESET" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || echo "$RESET"; }

cmd="${1:-}"
n="${2:-}"
case "$cmd" in
  status)
    read_quota || exit 2
    echo "remaining=$REMAINING limit=$LIMIT reset=$RESET reset_at=\"$(reset_str)\" in=$((RESET - $(date +%s)))s"
    ;;
  need)
    case "$n" in ''|*[!0-9]*) echo "usage: gh-quota.sh need N" >&2; exit 64;; esac
    read_quota || exit 2
    if [ "$REMAINING" -ge $((n + RESERVE)) ]; then exit 0; fi
    echo "gh-quota: need $n + $RESERVE reserve, have $REMAINING; resets at $(reset_str) (in $((RESET - $(date +%s)))s)"
    exit 75
    ;;
  wait)
    case "$n" in ''|*[!0-9]*) echo "usage: gh-quota.sh wait N" >&2; exit 64;; esac
    read_quota || exit 2
    while [ "$REMAINING" -lt $((n + RESERVE)) ]; do
      left=$((RESET - $(date +%s)))
      # Past the reset the quota is renewed: re-read once, then give up if still short.
      if [ "$left" -le 0 ]; then
        sleep 2
        read_quota || exit 2
        [ "$REMAINING" -ge $((n + RESERVE)) ] && exit 0
        echo "gh-quota: still $REMAINING after reset; need $((n + RESERVE)) (request exceeds the limit?)" >&2
        exit 75
      fi
      echo "gh-quota: have $REMAINING, need $((n + RESERVE)); waiting ${left}s for reset at $(reset_str)" >&2
      s=$left; [ "$s" -gt 60 ] && s=60
      sleep "$s"
      read_quota || exit 2
    done
    ;;
  *)
    echo "usage: gh-quota.sh status | need N | wait N" >&2
    exit 64
    ;;
esac
