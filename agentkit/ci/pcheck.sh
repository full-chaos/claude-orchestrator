#!/usr/bin/env bash
# usage: pcheck.sh [-b <base sha>] <prompt.md> <owner/repo> [context.md]
# Tip: from a `TIP: <sha>` line 1, else from the ops line. Base: -b, else the "against origin/main <sha>" line.
bopt=""; [ "${1:-}" = "-b" ] && { bopt=$2; shift 2; }
p=$1; repo=$2; ctx=${3:-}
[ -n "$bopt" ] && [ ${#bopt} -lt 40 ] && bopt=$(gh api "repos/$repo/commits/$bopt" --jq .sha)
sha256sum "$p" | cut -c1-16
opsre="^Adversarial review of PR #[0-9]+ at tip [0-9a-f]{40} against origin/main [0-9a-f]{40}\.$"
layerre="^Adversarial review of the ops change at tip [0-9a-f]{40} against layer [0-9a-f]{40}\.$"
l1=$(head -1 "$p")
if printf '%s\n' "$l1" | grep -qE '^TIP: [0-9a-f]{40}$'; then
  tip=${l1#TIP: }
  sed -n 2p "$p" | grep -qE "$opsre" && echo "line1=TIP-ok line2=ops-ok" || { sed -n 2p "$p" | grep -qE "$layerre" && echo "line1=TIP-ok line2=layer-ok" || echo "line1=TIP-ok line2=NOT ops form"; }
elif printf '%s\n' "$l1" | grep -qE "$opsre"; then
  echo "line1=ops-ok"; tip=$(printf '%s\n' "$l1" | grep -oE '[0-9a-f]{40}' | head -1)
else
  echo "line1=NOT TIP: and NOT ops form"; tip=""
fi
opsline=$(grep -m1 -E "$opsre" "$p")
# D6321: a stacked layer is reviewed against the tip of the layer BELOW: line 2 reads "Adversarial review of the ops change at tip <sha> against layer <sha>."
layerline=$(sed -n 2p "$p" | grep -E "$layerre" || true)
layerbase=""; [ -n "$layerline" ] && layerbase=$(printf '%s\n' "$layerline" | grep -oE 'against layer [0-9a-f]{40}' | grep -oE '[0-9a-f]{40}')
[ -n "$layerline" ] && echo "line2=layer-form (stacked base: the layer below)"
base=${bopt:-${layerbase:-$(printf '%s\n' "$opsline" | grep -oE 'against origin/main [0-9a-f]{40}' | grep -oE '[0-9a-f]{40}')}}
[ -n "$layerbase" ] && [ -n "$bopt" ] && [ "$bopt" != "$layerbase" ] && echo "BASE MISMATCH: -b ${bopt:0:8} vs layer line ${layerbase:0:8}"
if [ -n "$opsline" ]; then ot=$(printf '%s\n' "$opsline" | grep -oE '[0-9a-f]{40}' | head -1); [ "$ot" = "$tip" ] || echo "TIP MISMATCH: TIP line ${tip:0:8} vs ops line ${ot:0:8}"; fi
[ -n "$bopt" ] && [ -n "$opsline" ] && { ob=$(printf '%s\n' "$opsline" | grep -oE 'against origin/main [0-9a-f]{40}' | grep -oE '[0-9a-f]{40}'); [ "$ob" = "$bopt" ] || echo "BASE MISMATCH: -b ${bopt:0:8} vs ops line ${ob:0:8}"; }
grep -c 'Nothing reachable is out of scope.' "$p" | sed 's/^/scope-clause=/'
echo "tip=${tip:0:8} base=${base:0:8} main=$(gh api repos/$repo/commits/main --jq .sha | cut -c1-8)"
echo "tip-contains-base: behind=$(gh api "repos/$repo/compare/$base...$tip" --jq .behind_by) (must be 0)"
if [ -n "$layerbase" ]; then
  # stacked: line 2 must name the SAME tip as the TIP line, the tip must descend from the layer below, and the layer line must be a real layer below:
  #  - an open PR exists for the tip: its base must not be main, and the layer line must be the head of that base branch;
  #  - no PR yet (a local tip before its PR): the layer sha must be the head of an open PR (the layer below).
  tip2=$(sed -n 2p "$p" | grep -oE 'at tip [0-9a-f]{40}' | grep -oE '[0-9a-f]{40}')
  [ "$tip2" = "$tip" ] || echo "TIP MISMATCH: line 2 names ${tip2:0:8}, the TIP line names ${tip:0:8}"
  mb=$(gh api "repos/$repo/compare/$layerbase...$tip" --jq .merge_base_commit.sha)
  if [ "$mb" != "$layerbase" ]; then echo "base NOT the layer below: the tip does not descend from ${layerbase:0:8} (merge base ${mb:0:8})"
  else
    ghv() { gh api -H "X-GitHub-Api-Version: 2026-03-10" "$@"; }
    opens=$(gh api "repos/$repo/commits/$tip/pulls" --jq '[.[]|select(.state=="open" and .head.sha=="'"$tip"'")|.number]' 2>/dev/null) || opens=""
    nopen=$(jq 'length' <<<"${opens:-[]}" 2>/dev/null || echo 0)
    if [ "${nopen:-0}" -gt 1 ]; then
      echo "LAYER FORM REFUSED: more than one open PR has this tip ($(jq -c . <<<"$opens")); the layer cannot be told apart"
    elif [ "${nopen:-0}" = 1 ]; then
      prn=$(jq -r '.[0]' <<<"$opens")
      stk=$(ghv "repos/$repo/pulls/$prn" --jq '.stack // empty | "\(.number) \(.position)"' 2>/dev/null) || stk=""
      if [ -z "$stk" ]; then echo "LAYER FORM REFUSED: the open PR #$prn for this tip is not in a stack; use the \"against origin/main\" form"
      else
        snum=${stk% *}; spos=${stk#* }
        if [ "$spos" -lt 2 ] 2>/dev/null; then echo "LAYER FORM REFUSED: PR #$prn is the bottom layer of stack $snum (based on main); use the \"against origin/main\" form"
        else
          bhead=$(ghv "repos/$repo/stacks/$snum" --jq ".pull_requests[$((spos-2))].head.sha" 2>/dev/null) || bhead=""
          [ "$bhead" = "$layerbase" ] && echo "base=layer-below OK (stack $snum member below PR #$prn)" || echo "base NOT the layer below: the member below PR #$prn in stack $snum is at ${bhead:0:8}, the layer line names ${layerbase:0:8}"
        fi
      fi
    else
      # no PR for the tip yet (a local tip): the layer sha must be the head of exactly one open PR that is itself a stack member
      lprs=$(gh api "repos/$repo/commits/$layerbase/pulls" --jq '[.[]|select(.state=="open" and .head.sha=="'"$layerbase"'")|.number]' 2>/dev/null) || lprs=""
      nl=$(jq 'length' <<<"${lprs:-[]}" 2>/dev/null || echo 0)
      if [ "${nl:-0}" = 1 ] && [ -n "$(ghv "repos/$repo/pulls/$(jq -r '.[0]' <<<"$lprs")" --jq '.stack // empty | .number' 2>/dev/null)" ]; then
        echo "base=layer-below OK (no PR for this tip yet; the layer sha is the head of an open PR in a stack)"
      else
        echo "LAYER FORM REFUSED: no open PR exists for this tip, and the layer sha ${layerbase:0:8} is not the head of exactly one open PR that is in a stack"
      fi
    fi
  fi
else
mb=$(gh api "repos/$repo/compare/main...$tip" --jq .merge_base_commit.sha)
[ "$mb" = "$base" ] && echo "base=merge-base OK" || echo "base NOT merge-base: line 1 must name ${mb:0:8} (the main the tip contains). Never take main to change this."
fi
echo "history-terms:"; grep -niE 'round [0-9]|r[12] |previous|prior round|already (fixed|reviewed)|excus|known issue|accepted risk' "$p" | head -5
t=$(mktemp); gh api "repos/$repo/compare/$base...$tip" --jq '.files[].filename' | LC_ALL=C sort > "$t"
echo "compare-files=$(wc -l < "$t")"
grep -xFf "$t" "$p" | LC_ALL=C sort | diff - "$t" >/dev/null && echo "FILES MATCH" || { echo "FILES DIFFER"; grep -xFf "$t" "$p" | LC_ALL=C sort | diff - "$t"; }
grep -c 'Final line, alone' "$p" | sed 's/^/verdict-line=/'
grep -c 'invisible at Info' "$p" | sed 's/^/obs-question=/'
rm -f "$t"
if [ -n "$ctx" ]; then
  echo "ctx-sha=$(sha256sum "$ctx" | cut -c1-16)"
  h=$(grep -niwE 'round|fixed|previous|known|decided|accepted|already|now|instead|by design|by the ruling' "$ctx")
  [ -z "$h" ] && echo "ctx-history-terms=0" || { echo "ctx-history-terms=$(printf '%s\n' "$h" | wc -l) (must be 0)"; printf '%s\n' "$h" | cut -c1-160; }
  r=$(grep -niE 'RISK-NOTES|not reachable|unreachable|low risk|^#+ *risk' "$ctx")
  [ -z "$r" ] && echo "ctx-risk-notes=0" || { echo "ctx-risk-notes=$(printf '%s\n' "$r" | wc -l) (must be 0: no RISK-NOTES or pre-excuses)"; printf '%s\n' "$r" | cut -c1-160; }
fi
