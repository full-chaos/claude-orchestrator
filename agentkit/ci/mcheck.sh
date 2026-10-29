#!/bin/bash
# usage: mcheck.sh <repo-suffix> <pr>   (suffix = ops/web/acr -> full-chaos/dev-health-<suffix>; owner/name = that repo, e.g. full-chaos/ask-dev)
#        mcheck.sh --nonpass-file <checkruns.json> <statuses.json> <known-red.tsv> <YYYY-MM-DD>   (offline test mode)
# nonpass = check runs (required or not) whose LATEST run per name has conclusion failure|cancelled|timed_out|action_required,
# plus commit statuses in state failure|error; names with an unexpired row in known-red.tsv are exempt and listed as knownred=[...].
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
unset MCHECK_KNOWN_RED   # an exported value must never exempt a red check: the only exemption is the lead-owned known-red.tsv next to this script
KNOWN_RED=$HERE/known-red.tsv

# nonpass_calc <checkruns.json (slurped-able, may be many paginated docs)> <statuses.json (may be empty file)> <known-red.tsv> <today>
# prints: "<count> <exempt names joined by space>"
nonpass_calc() {
  local active
  active=$(awk -F'\t' -v t="$4" '!/^[[:space:]]*#/ && NF>=3 && $1!="" && $3>=t {print $1}' "$3" 2>/dev/null | jq -R . | jq -s -c .)
  [ -n "$active" ] || active='[]'
  jq -s -r --argjson known "$active" --slurpfile st <(cat "$2" 2>/dev/null) '
    ([.[] | .check_runs? // [] | .[]]
      | group_by(.name) | map(max_by([(.completed_at // ""), .id]))
      | map(select(.conclusion=="failure" or .conclusion=="cancelled" or .conclusion=="timed_out" or .conclusion=="action_required") | .name)) as $cr
    | ([$st[] | .statuses? // [] | .[]]
      | group_by(.context) | map(max_by([(.updated_at // ""), .id]))
      | map(select(.state=="failure" or .state=="error") | .context)) as $ss
    | ($cr + $ss) as $red
    | ($red | map(select(. as $n | $known | index($n) | not))) as $bad
    | ($red | map(select(. as $n | $known | index($n))) | unique) as $ex
    | "\($bad | length) \($ex | join(" "))"' "$1"
}

if [ "${1:-}" = "--nonpass-file" ]; then nonpass_calc "$2" "$3" "$4" "$5"; exit $?; fi

case $1 in */*) R=$1 ;; *) R=full-chaos/dev-health-$1 ;; esac; n=$2
j=$(gh pr view $n -R $R --json headRefOid,body,mergeStateStatus,files,baseRefName); sha=$(jq -r .headRefOid <<<"$j")
h=$(jq -r .body <<<"$j" | grep -cE '^## (TEST-EVIDENCE|RISK-NOTES)$'); c=$(jq -r .body <<<"$j" | grep -vE '^Part of CHAOS-[0-9]+[[:space:]]*$' | grep -c 'CHAOS-')
tmpd=$(mktemp -d); trap 'rm -rf "$tmpd"' EXIT
apiok=1
gh api --paginate "repos/$R/commits/$sha/check-runs?per_page=100" >"$tmpd/cr.json" 2>/dev/null || apiok=0
gh api --paginate "repos/$R/commits/$sha/status?per_page=100" >"$tmpd/st.json" 2>/dev/null || apiok=0
# fail closed: an API error must never read as nonpass=0
if [ $apiok = 1 ]; then np=$(nonpass_calc "$tmpd/cr.json" "$tmpd/st.json" "$KNOWN_RED" "$(date -u +%F)") || np="ERR"; else np="ERR"; fi
case $np in [0-9]*) ;; *) np="ERR";; esac
nf=${np%% *}; kr=${np#"$nf"}; kr=${kr# }
v=$(gh api repos/$R/commits/$sha --jq '.commit.verification.verified')
# D6100 (2026-10-19): overlap is FILE-level: a file this PR changed that main also changed since the merge base.
# D6321: an upper layer of a stack is compared with its BASE branch (the layer below), not with main; a PR on main behaves as before.
baseref=$(jq -r '.baseRefName // "main"' <<<"$j"); [ -n "$baseref" ] && [ "$baseref" != null ] || baseref=main
cmp=$(gh api "repos/$R/compare/$sha...$baseref" --jq '.files[].filename' | sort -u)
mine=$(jq -r '.files[].path' <<<"$j" | sort -u)
behind=$(gh api "repos/$R/compare/$baseref...$sha" --jq '.behind_by')
stale=$([ "$behind" = "0" ] && echo no || echo "YES(behind $behind: merge $baseref, rerun CI)")
extra=""
if [ "$baseref" != main ]; then
  # the layers below, taken from the CURRENT stack member list (never from a branch-name lookup, which can name an old closed PR): "#<pr>:<STATE>", bottom first
  below=""
  pj=$(gh api "repos/$R/pulls/$n" 2>/dev/null) || pj=""
  sn=$(jq -r '.stack.number // empty' <<<"$pj" 2>/dev/null); sp=$(jq -r '.stack.position // empty' <<<"$pj" 2>/dev/null)
  if [ -n "$sn" ] && [ -n "$sp" ]; then
    below=$(gh api "repos/$R/stacks/$sn" --jq "[.pull_requests[0:($sp-1)][]|\"#\\(.number):\\(if .merged_at then \"MERGED\" else (.state|ascii_upcase) end)\"]|join(\" \")" 2>/dev/null) || below="?unreadable"
  else
    below="?no-stack-object"
  fi
  extra=" stack-base=$baseref below=[$below]"
fi
echo "$1#$n $sha stale=$stale state=$(jq -r .mergeStateStatus <<<"$j") headings=$h chaos=$c nonpass=$nf knownred=[$kr] signed=$v overlap=[$(comm -12 <(echo "$cmp") <(echo "$mine")|tr '\n' ' ')]$extra"
