#!/usr/bin/env bash
# Append one line per run to ~/.fleet/gh-quota.log (at most one per minute):
#   <iso time> remaining=<n> delta=<n since last sample> reset=<epoch> procs=[user:pid:cmd; ...]
# procs lists every user's processes matching gh, curl to github, check-ci,
# addons-lock, ls-remote, git fetch/ls-remote/clone. rate_limit is free; no
# other GitHub call is made. Env: GH_QUOTA_LOG, GH_QUOTA_STATE, GH_QUOTA_CMD.
set -u
LOG="${GH_QUOTA_LOG:-$HOME/.fleet/gh-quota.log}"
STATE="${GH_QUOTA_STATE:-$HOME/.fleet/gh-quota.last}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$(dirname "$LOG")"

now=$(date +%s)
last_t=0; last_r=""; last_reset=""
[ -f "$STATE" ] && read -r last_t last_r last_reset <"$STATE"
[ $((now - ${last_t:-0})) -lt 55 ] && exit 0

out="$("$here/gh-quota.sh" status 2>/dev/null)" || { echo "$(date -Is) sample-failed" >>"$LOG"; exit 0; }
remaining="${out#*remaining=}"; remaining="${remaining%% *}"
reset="${out#*reset=}"; reset="${reset%% *}"

# Delta is only meaningful inside one window; across a reset it is marked.
if [ -z "$last_r" ]; then delta="n/a"
elif [ "$reset" != "$last_reset" ]; then delta="reset"
else delta=$((remaining - last_r)); fi

re='(^|[ /])gh( |$)|curl.*github|check-ci|addons-lock|ls-remote|git (fetch|ls-remote|clone)|git-remote-http'
procs="$(ps -eo user:12,pid,args --no-headers | grep -E "$re" | grep -vE "grep -E|gh-quota" \
  | awk '{u=$1;p=$2;$1="";$2="";sub(/^ +/,"");printf "%s:%s:%s; ", u,p,substr($0,1,120)}')"

echo "$(date -Is) remaining=$remaining delta=$delta reset=$reset procs=[${procs%; }]" >>"$LOG"
echo "$now $remaining $reset" >"$STATE"
