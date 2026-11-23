#!/usr/bin/env bash
# Tests for gh-quota.sh and gh-quota-sampler.sh using a stubbed rate_limit (no GitHub calls).
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
q="$here/gh-quota.sh"; s="$here/gh-quota-sampler.sh"
fail=0; pass=0
ok() { if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL $1: got $3 want $2"; fi; }
fut=$(( $(date +%s) + 3 ))

GH_QUOTA_CMD="echo 4000 5000 $fut" "$q" need 10 >/dev/null; ok need-enough 0 $?
GH_QUOTA_CMD="echo 309 5000 $fut" "$q" need 10 >/dev/null; ok need-reserve-edge 75 $?
GH_QUOTA_CMD="echo 310 5000 $fut" "$q" need 10 >/dev/null; ok need-exact 0 $?
GH_QUOTA_RESERVE=0 GH_QUOTA_CMD="echo 10 5000 $fut" "$q" need 10 >/dev/null; ok reserve-env 0 $?
GH_QUOTA_CMD="false" "$q" need 10 >/dev/null 2>&1; ok fetch-fail 2 $?
GH_QUOTA_CMD="echo junk" "$q" need 10 >/dev/null 2>&1; ok bad-output 2 $?
"$q" need abc >/dev/null 2>&1; ok bad-arg 64 $?
GH_QUOTA_CMD="echo 100 5000 $fut" "$q" status | grep -q 'remaining=100 limit=5000'; ok status 0 $?
GH_QUOTA_CMD="echo 100 5000 $(( $(date +%s) - 5 ))" timeout 20 "$q" wait 10 >/dev/null 2>&1; ok wait-bounded 75 $?
GH_QUOTA_CMD="echo 4000 5000 $fut" timeout 20 "$q" wait 10 >/dev/null 2>&1; ok wait-immediate 0 $?

d="$(mktemp -d)"
export GH_QUOTA_LOG="$d/log" GH_QUOTA_STATE="$d/last"
GH_QUOTA_CMD="echo 1000 5000 $fut" "$s"; ok sample1 1 "$(wc -l <"$d/log")"
grep -q 'delta=n/a' "$d/log"; ok sample1-na 0 $?
GH_QUOTA_CMD="echo 900 5000 $fut" "$s"; ok sample-ratelimited 1 "$(wc -l <"$d/log")"
echo "1 1000 $fut" >"$d/last"
GH_QUOTA_CMD="echo 950 5000 $fut" "$s"; ok sample2 2 "$(wc -l <"$d/log")"
tail -1 "$d/log" | grep -q 'delta=-50'; ok sample2-delta 0 $?
echo "1 950 1" >"$d/last"
GH_QUOTA_CMD="echo 5000 5000 $fut" "$s"
tail -1 "$d/log" | grep -q 'delta=reset'; ok sample-reset 0 $?
rm -rf "$d"
echo "gh-quota checks: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
