#!/bin/bash
# mergegate.sh - single merge gate. Only merge path for lanes.
#   mergegate.sh parse "<mcheck output>"   (or stdin)   -> GATE OK | GATE REFUSED: <reason>; exit 0 / 3
#   mergegate.sh final <ops|web|acr> <pr> <sha>         -> wait checks, rerun mcheck, parse, merge
#     merge uses --subject "<PR title> (#<n>)" and the PR body (read via REST at the gated sha), never GitHub's default message.
#   mergegate.sh dryrun <repo> <pr> <sha> (preferred) or MERGEGATE_DRYRUN=1: final does every read + check, PRINTS the gh merge command (+ body) and exits 0; never merges.
#     Dry-run skips: the wait for pending checks (single pass), and the mcheck rerun when MERGEGATE_DRYRUN_MCHECK_LINE is set
#     (that line is fed to parse instead). Test hook (dry-run only): MERGEGATE_DRYRUN_PR_JSON=<file> replaces the pulls/<n> REST reply.
# Any PR-body edit after the final mcheck means rerun this (final reruns mcheck itself).
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

parse() {
  local in line
  if [ $# -gt 0 ]; then in=$1; else in=$(cat); fi
  # result line = last line shaped like "<repo>#<n> <sha> ... signed=..."
  line=$(printf '%s\n' "$in" | grep -E '^[A-Za-z0-9_-]+#[0-9]+ [0-9a-f]{7,40} .*(chaos|nonpass|signed)=' | tail -n 1)
  [ -z "$line" ] && { echo "GATE REFUSED: no mcheck result line"; return 3; }
  printf '%s\n' "$line" | awk '
    { sub(/overlap=\[.*\]/, "") ; n=split($0, f, /[ \t]+/)
      for (i=1;i<=n;i++) {
        if (f[i] ~ /^nonpass=/) { np++; if (f[i]=="nonpass=0") npok++ }
        if (f[i] ~ /^chaos=/)   { ch++; if (f[i]=="chaos=0") chok++ }
        if (f[i] ~ /^signed=/)  { sg++; if (f[i]=="signed=true") sgok++ }
      } }
    END {
      if (np!=1)   { print "GATE REFUSED: nonpass token count=" np+0; exit 3 }
      if (ch!=1)   { print "GATE REFUSED: chaos token count=" ch+0; exit 3 }
      if (sg!=1)   { print "GATE REFUSED: signed token count=" sg+0; exit 3 }
      if (!npok)   { print "GATE REFUSED: nonpass is not 0"; exit 3 }
      if (!chok)   { print "GATE REFUSED: chaos is not 0"; exit 3 }
      if (!sgok)   { print "GATE REFUSED: signed is not true"; exit 3 }
      print "GATE OK"; exit 0 }'
}

# red_main <repo> <pr>: ops only. Red = the newest COMPLETED go.yml push run on main (cancelled/skipped runs are passed over) whose
# go-storage-integration* job (aggregate or any shard) failed. In-progress runs and reruns in flight never block (they are not completed; a rerun that
# passed makes the run green). A PR labelled fix-main, or titled with [fix-main], is exempt so any lead can land the fix/revert.
red_main() {
  local s=$1 n=$2 R=full-chaos/dev-health-ops run id sha at job meta
  [ "$s" = ops ] || return 0
  run=$(gh api "repos/$R/actions/workflows/go.yml/runs?branch=main&event=push&status=completed&per_page=10" \
    --jq "[.workflow_runs[]|select(.conclusion==\"success\" or .conclusion==\"failure\")][0]|if .==null then \"\" else \"\(.id) \(.conclusion) \(.head_sha) \(.updated_at)\" end" 2>/dev/null) || run=""
  [ -z "$run" ] && return 0
  set -- $run; id=$1; sha=$3; at=$4
  [ "$2" = failure ] || return 0
  job=$(gh api "repos/$R/actions/runs/$id/jobs?filter=latest&per_page=100" --paginate \
    --jq ".jobs[]|select(.name|startswith(\"go-storage-integration\"))|select(.conclusion==\"failure\")|.conclusion" 2>/dev/null | head -1)
  [ "$job" = failure ] || return 0
  meta=$(gh pr view "$n" -R "$R" --json title,labels -q "(.title|test(\"\\\\[fix-main\\\\]\"))or([.labels[].name]|index(\"fix-main\")!=null)" 2>/dev/null)
  [ "$meta" = true ] && { echo "red-main: exempt, PR $n is a fix-main PR (red run $id at $sha)"; return 0; }
  echo "GATE REFUSED: main integration red at $sha (run $id, since $at, age $(( ($(date +%s) - $(date -d "$at" +%s)) / 60 )) min); only a PR labelled fix-main or titled [fix-main] may merge"
  return 3
}

# merge_msg <repo-slug> <pr> <sha> <tmpdir>: read title+body via REST at the gated sha; write body to <tmpdir>/body.txt,
# subject to <tmpdir>/subject.txt. Refuse (return 3) on any read failure, sha mismatch, empty title/body, or body chaos != 0.
merge_msg() {
  local R=$1 n=$2 sha=$3 t=$4 pj hs title c
  if [ "${MERGEGATE_DRYRUN:-}" = 1 ] && [ -n "${MERGEGATE_DRYRUN_PR_JSON:-}" ]; then
    pj=$(cat "$MERGEGATE_DRYRUN_PR_JSON" 2>/dev/null) || pj=""
  else
    pj=$(gh api "repos/$R/pulls/$n" 2>/dev/null) || pj=""
  fi
  [ -n "$pj" ] || { echo "GATE REFUSED: cannot read PR title/body via REST"; return 3; }
  hs=$(jq -r '.head.sha // ""' <<<"$pj" 2>/dev/null) || hs=""
  [ -n "$hs" ] || { echo "GATE REFUSED: PR REST reply has no head sha"; return 3; }
  [ "$hs" = "$sha" ] || { echo "GATE REFUSED: PR REST head sha $hs differs from $sha"; return 3; }
  title=$(jq -r '.title // ""' <<<"$pj")
  jq -j '.body // ""' <<<"$pj" >"$t/body.txt" || { echo "GATE REFUSED: cannot read PR body"; return 3; }
  [ -n "$title" ] || { echo "GATE REFUSED: PR title is empty"; return 3; }
  grep -q '[^[:space:]]' "$t/body.txt" || { echo "GATE REFUSED: PR body is empty"; return 3; }
  c=$(grep -vE '^Part of CHAOS-[0-9]+[[:space:]]*$' "$t/body.txt" | grep -c 'CHAOS-')
  [ "$c" = 0 ] || { echo "GATE REFUSED: PR body has $c line(s) with CHAOS ids other than the Part of CHAOS-n line"; return 3; }
  # D6237: "Part of" is a non-closing Linear word; naming the title's leaf there blocks the auto-close.
  c=$(comm -12 <(grep -oE 'CHAOS-[0-9]+' <<<"$title" | sort -u) \
    <(grep -E '^Part of CHAOS-[0-9]+[[:space:]]*$' "$t/body.txt" | grep -oE 'CHAOS-[0-9]+' | sort -u) | head -1)
  [ -z "$c" ] || { echo "GATE REFUSED: the Part of line names $c, the id in the title; name the parent there (D6237)"; return 3; }
  # A stay-open leaf (Part of <leaf>, no title id) is still closed by Linear when the branch name carries the id.
  for c in $(grep -E '^Part of CHAOS-[0-9]+[[:space:]]*$' "$t/body.txt" | grep -oE '[0-9]+'); do
    jq -r '.head.ref // ""' <<<"$pj" | grep -qiE "chaos-$c([^0-9]|\$)" && \
      echo "WARN: branch name carries CHAOS-$c from the Part of line; Linear may close it on merge (D6237: reopen it at FINAL)"
  done
  printf '%s (#%s)' "$title" "$n" >"$t/subject.txt"
}

final() {
  local s=$1 n=$2 sha=$3 R head o m r end tmpd subj dry=${MERGEGATE_DRYRUN:-}
  [ $# -eq 3 ] || { echo "usage: mergegate.sh final <ops|web|acr> <pr> <sha>"; return 2; }
  case $s in ops|web|acr) ;; *) echo "bad repo $s"; return 2;; esac
  R=full-chaos/dev-health-$s; end=$((SECONDS+7200))
  red_main "$s" "$n" || return 3
  tmpd=$(umask 077; mktemp -d) || { echo "GATE REFUSED: cannot make temp dir"; return 3; }
  trap "rm -rf '$tmpd'" EXIT
  while [ $SECONDS -lt $end ]; do
    head=$(gh pr view "$n" -R "$R" --json headRefOid -q .headRefOid)
    [ "$head" != "$sha" ] && { echo "GATE REFUSED: HEAD MOVED to $head"; return 3; }
    o=$(gh pr checks "$n" -R "$R" 2>&1)
    if [ -n "$o" ] && [ -z "$(printf '%s\n' "$o" | awk -F'\t' '$2=="pending"')" ]; then
      if [ "$dry" = 1 ] && [ -n "${MERGEGATE_DRYRUN_MCHECK_LINE:-}" ]; then m=$MERGEGATE_DRYRUN_MCHECK_LINE
      else m=$("$HERE/mcheck.sh" "$s" "$n"); fi
      echo "$m"
      r=$(parse "$m"); echo "$r"
      case $r in "GATE OK") ;; *) return 3;; esac
      case $m in *" $sha "*) ;; *) echo "GATE REFUSED: mcheck sha differs from $sha"; return 3;; esac
      red_main "$s" "$n" || return 3
      merge_msg "$R" "$n" "$sha" "$tmpd" || return 3
      subj=$(cat "$tmpd/subject.txt")
      if [ "$dry" = 1 ]; then
        echo "DRYRUN: would run (not run):"
        printf 'gh pr merge %q -R %q --squash --match-head-commit %q --subject %q --body-file %q\n' "$n" "$R" "$sha" "$subj" "$tmpd/body.txt"
        echo "DRYRUN: body-file content follows between the markers"
        echo "-----BODY BEGIN-----"; cat "$tmpd/body.txt"; echo; echo "-----BODY END-----"
        return 0
      fi
      gh pr merge "$n" -R "$R" --squash --match-head-commit "$sha" --subject "$subj" --body-file "$tmpd/body.txt" 2>&1 | tail -2
      gh pr view "$n" -R "$R" --json state,mergeCommit -q '"MERGE "+.state+" "+.mergeCommit.oid'
      return 0
    fi
    [ "$dry" = 1 ] && { echo "GATE REFUSED: dry-run does not wait; checks still pending"; return 3; }
    sleep 45
  done
  echo "GATE REFUSED: timeout waiting for checks"; return 3
}

case ${1:-} in
  parse) shift; parse "$@"; exit $? ;;
  final) shift
    # A misspelt dry-run variable must not fall through to a real merge.
    if [ "${MERGEGATE_DRYRUN:-}" != 1 ] && compgen -e | grep -qiE '^[A-Z_]*DRY_?RUN[A-Z_]*$'; then
      echo "GATE REFUSED: a DRYRUN-like variable is set but MERGEGATE_DRYRUN is not 1; use: mergegate.sh dryrun <ops|web|acr> <pr> <sha>"; exit 3
    fi
    final "$@"; exit $? ;;
  dryrun) shift; MERGEGATE_DRYRUN=1 final "$@"; exit $? ;;
  *) echo "usage: mergegate.sh parse [\"<mcheck output>\"] | final <ops|web|acr> <pr> <sha> | dryrun <ops|web|acr> <pr> <sha>"; exit 2 ;;
esac
