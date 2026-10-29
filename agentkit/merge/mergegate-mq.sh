#!/bin/bash
# mergegate-mq.sh - DRAFT (CHAOS-11101): the merge-gate variant for a repository with a merge queue. Not live; a copy of mergegate.sh.
#   Differences: final ENQUEUES the PR through the asynchronous merge API (PUT /repos/{o}/{r}/pulls/{n}/merge-async, X-GitHub-Api-Version 2026-03-10,
#   merge_action=merge_queue, sha = the gated sha; the API GitHub documents as required for stacked PRs, where it also takes every open downstack PR) and waits for MERGED or an ejection;
#   it never calls gh pr merge. The squash subject and body come from the repository settings (PR_TITLE, PR_BODY), not from this script.
#   Poll errors after the enqueue (CHAOS-11616): an error on the merge-async poll (HTTP 5xx, 404, 409, a network error, but also a 4xx such as 401/403/429) never ends the gate with rc 3 by itself: a transient error is retried up to 5 times, a non-transient one at once, then the merge request is "unpolled" and the real PR state decides: 0 merged, 5 still queued, 4 MERGEGATE-ALARM (no queue entry, entry unreadable, closed: the merge request may still be pending and enqueue later). rc 3 only when the gate PROVES the PR is not queued, not merged AND the merge request is resolved (status failed, which still ends in the PR state proof of single_verdict: queued 5, merged 0, open without entry 3; or on the stack path a proved dequeue by stack_abort, which prints rc 3 for a clean proved dequeue and rc 4 when the dequeue or the merge request is not proved). A merge request still pending when the 600 s window ends, or an unknown status, is rc 4.
#   Single-PR exit codes (CHAOS-11295): 0 merged (head == gated sha), 3 refused (proved not queued and not merged), 4 MERGEGATE-ALARM, 5 STILL QUEUED (wait deadline, PR left in the queue).
#   Stack exit codes (CHAOS-11344): the same, 5 = every unmerged layer still queued at the wait deadline (the stack is left queued); an ejected or closed layer = the stack_abort refusal. INT/TERM after the ENQUEUED line = no dequeue, "STILL QUEUED (gate interrupted, stack left queued)" with every layer and gated sha, rc 5; before ENQUEUED the abort (dequeue and prove, rc 4) stays. An alarm at the deadline always wins: rc 4.
#   After the enqueue the gate proves the PR's mergeQueueEntry before it prints ENQUEUED (a stack: the top layer's, CHAOS-11345); at the wait deadline (MERGEGATE_QUEUE_WAIT_MIN, default 240) it reads the PR state.
#   red_main is advisory (the queue tests the merged tree before it lands). stale/overlap in mcheck stay informational (parse never reads them).
# mergegate.sh - single merge gate. Only merge path for lanes.
#   mergegate.sh parse "<mcheck output>"   (or stdin)   -> GATE OK | GATE REFUSED: <reason>; exit 0 / 3
#   mergegate.sh final <ops|web|acr> <pr> <sha>         -> wait checks, rerun mcheck, parse, merge
#     merge uses --subject "<PR title> (#<n>)" and the PR body (read via REST at the gated sha), never GitHub's default message.
#   mergegate.sh dryrun <repo> <pr> <sha> (preferred) or MERGEGATE_DRYRUN=1: final does every read + check, PRINTS the gh merge command (+ body) and exits 0; never merges.
#     Dry-run skips: the wait for pending checks (single pass), and the mcheck rerun when MERGEGATE_DRYRUN_MCHECK_LINE is set
#     (that line is fed to parse instead). Test hook (dry-run only): MERGEGATE_DRYRUN_PR_JSON=<file> replaces the pulls/<n> REST reply.
# Any PR-body edit after the final mcheck means rerun this (final reruns mcheck itself).
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
unset GATE_STACK_LAYER   # an exported value must never let the single-PR path accept a stacked PR

parse() {
  local in line
  if [ $# -gt 0 ]; then in=$1; else in=$(cat); fi
  # result line = last line shaped like "<repo>#<n> <sha> ... signed=..."
  line=$(printf '%s\n' "$in" | grep -E '^[A-Za-z0-9_./-]+#[0-9]+ [0-9a-f]{7,40} .*(chaos|nonpass|signed)=' | tail -n 1)
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
# passed makes the run green). Under the queue this check is advisory. A PR with the LABEL fix-main (never the title: anyone can edit a title, a label shows in the audit log) is reported as exempt.
# Dry-run hooks (tests only): MERGEGATE_DRYRUN_RED_RUN="<id> failure <sha> <iso time>" and MERGEGATE_DRYRUN_RED_JOB=failure simulate a red main; the labels come from MERGEGATE_DRYRUN_PR_JSON.
red_main() {
  local s=$1 n=$2 R=full-chaos/dev-health-ops run id sha at job meta
  [ "$s" = ops ] || return 0
  if [ "${MERGEGATE_DRYRUN:-}" = 1 ] && [ -n "${MERGEGATE_DRYRUN_RED_RUN:-}" ]; then run=$MERGEGATE_DRYRUN_RED_RUN; else
  run=$(gh api "repos/$R/actions/workflows/go.yml/runs?branch=main&event=push&status=completed&per_page=10" \
    --jq "[.workflow_runs[]|select(.conclusion==\"success\" or .conclusion==\"failure\")][0]|if .==null then \"\" else \"\(.id) \(.conclusion) \(.head_sha) \(.updated_at)\" end" 2>/dev/null) || run=""
  fi
  [ -z "$run" ] && return 0
  set -- $run; id=$1; sha=$3; at=$4
  [ "$2" = failure ] || return 0
  if [ "${MERGEGATE_DRYRUN:-}" = 1 ] && [ -n "${MERGEGATE_DRYRUN_RED_JOB:-}" ]; then job=$MERGEGATE_DRYRUN_RED_JOB; else
  job=$(gh api "repos/$R/actions/runs/$id/jobs?filter=latest&per_page=100" --paginate \
    --jq ".jobs[]|select(.name|startswith(\"go-storage-integration\"))|select(.conclusion==\"failure\")|.conclusion" 2>/dev/null | head -1)
  fi
  [ "$job" = failure ] || return 0
  if [ "${MERGEGATE_DRYRUN:-}" = 1 ] && [ -n "${MERGEGATE_DRYRUN_PR_JSON:-}" ]; then
    meta=$(jq -r '[.labels[]?.name] | index("fix-main") != null' "$MERGEGATE_DRYRUN_PR_JSON" 2>/dev/null)
  else
    meta=$(gh pr view "$n" -R "$R" --json labels -q '[.labels[].name] | index("fix-main") != null' 2>/dev/null)
  fi
  [ "$meta" = true ] && { echo "red-main: exempt, PR $n is a fix-main PR (red run $id at $sha)"; return 0; }
  echo "WARN: main integration red at $sha (run $id, since $at, age $(( ($(date +%s) - $(date -d "$at" +%s)) / 60 )) min); advisory under the merge queue, which tests the merged tree"
  return 0
}

# merge_msg <repo-slug> <pr> <sha> <tmpdir>: read title+body via REST at the gated sha; write body to <tmpdir>/body.txt,
# subject to <tmpdir>/subject.txt. Refuse (return 3) on any read failure, sha mismatch, empty title/body, or body chaos != 0.
merge_msg() {
  local R=$1 n=$2 sha=$3 t=$4 pj hs title c
  if [ "${MERGEGATE_DRYRUN:-}" = 1 ] && [ -n "${MERGEGATE_DRYRUN_PR_JSON:-}" ]; then
    pj=$(cat "$MERGEGATE_DRYRUN_PR_JSON" 2>/dev/null) || pj=""
  else
    pj=$(gh api -H "X-GitHub-Api-Version: 2026-03-10" "repos/$R/pulls/$n" 2>/dev/null) || pj=""
  fi
  [ -n "$pj" ] || { echo "GATE REFUSED: cannot read PR title/body via REST"; return 3; }
  hs=$(jq -r '.head.sha // ""' <<<"$pj" 2>/dev/null) || hs=""
  [ -n "$hs" ] || { echo "GATE REFUSED: PR REST reply has no head sha"; return 3; }
  [ "$hs" = "$sha" ] || { echo "GATE REFUSED: PR REST head sha $hs differs from $sha"; return 3; }
  title=$(jq -r '.title // ""' <<<"$pj")
  # D6300: a fix-main PR is recognised by the LABEL fix-main only (never by the title: anyone can edit a title, a label shows in the audit log).
  FIXMAIN=0
  if jq -e '[.labels[]?.name] | index("fix-main") != null' <<<"$pj" >/dev/null 2>&1; then FIXMAIN=1; fi
  # D6300 / acp: a stacked PR is gated by stack_final (every layer gets its own mcheck and body gate, GATE_STACK_LAYER=1 there); reaching this check any other
  # way (the single-PR path) with a stack object is refused. (A fix-main PR is never stacked: a bypass merges only the bottom PR of a stack.)
  if [ "${GATE_STACK_LAYER:-0}" != 1 ] && jq -e '.stack != null' <<<"$pj" >/dev/null 2>&1; then
    echo "GATE REFUSED: this PR is in a stack; stacked PRs are not merged by this gate until the stack tooling ships (D6300)"; return 3
  fi
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

ASYNC_VER=2026-03-10
# poll_transient <gh error text> (CHAOS-11616): 0 = transient (HTTP 5xx, 404/409, or no HTTP code at all = network/timeout/reset: retried), 1 = another 4xx (400 401 403 422 429: not retried).
poll_transient() { case $1 in *"HTTP 404"*|*"HTTP 409"*) return 0 ;; *"HTTP 4"[0-9][0-9]*) return 1 ;; esac; return 0; }
declare -A GATED CUR_SHA CUR_REF
MQ_TOP=""; MQ_UUID=""
JUMP_Q='mutation($id:ID!,$oid:GitObjectID){enqueuePullRequest(input:{pullRequestId:$id,expectedHeadOid:$oid,jump:true}){mergeQueueEntry{id position state jump}}}'
FIXMAIN=0
STATE_Q='query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){pullRequest(number:$number){state mergeCommit{oid} mergeQueueEntry{state position}}}}'

# ---- stack path (D6321) -------------------------------------------------------------------------------------------------------------------------
# REST reads carry the API version header, so the `stack` object is present whatever the account default is.
ghr() { gh api -H "X-GitHub-Api-Version: $ASYNC_VER" "$@"; }
DEQUEUE_Q='mutation($id:ID!){dequeuePullRequest(input:{id:$id}){mergeQueueEntry{id}}}'

# ---- single-PR path verdicts (CHAOS-11295) -------------------------------------------------------------------------------------------------------
# Exit codes of `final` for a single PR: 0 merged (head == gated sha), 3 refused (proved not queued and not merged), 4 MERGEGATE-ALARM
# (merged with another head, or a state that cannot be proved), 5 STILL QUEUED (wait deadline passed, the PR stays in the queue, NOT refused).
# MERGEGATE_QUEUE_WAIT_MIN: minutes the gate waits in the queue (a plain number, default 240).
ONE_JQ='.data.repository.pullRequest|"\(.state) \(.mergeCommit.oid // "-") \(.mergeQueueEntry.state // "NONE") \(.mergeQueueEntry.position // "?")"'
one_state() { gh api graphql -f query="$STATE_Q" -f owner="${1%%/*}" -f name="${1##*/}" -F number="$2" --jq "$ONE_JQ" 2>/dev/null; }

# The merge bot removes a PR from the queue about 1 s before it sets MERGED, so OPEN/NONE may be a merge in flight: re-read; 0 merged, 4 alarm, 99 not merged.; REST without the version header: the 2026-03-10 header returns a null merge_commit_sha.
merged_after_removal() {
  local R=$1 n=$2 sha=$3 k r ma oid head psleep=5
  [ "$R" = full-chaos/scratch-ci ] && psleep=${MERGEGATE_TEST_POLL_SLEEP:-5}
  for k in 1 2 3; do
    r=$(gh api "repos/$R/pulls/$n" --jq '"\(.merged_at // "-") \(.merge_commit_sha // "-") \(.head.sha)"' 2>/dev/null) || r=""
    set -- $r; ma=${1:--}; oid=${2:--}; head=${3:--}
    if [ "$ma" != "-" ]; then
      if [ "$head" = "$sha" ]; then echo "MERGE MERGED $oid"; return 0; fi
      echo "MERGEGATE-ALARM: PR $n is MERGED with head $head, not the gated $sha; read main for commit $oid now"; return 4
    fi
    [ "$k" -lt 3 ] && sleep "$psleep"
  done
  return 99
}

# single_verdict <repo> <pr> <gated sha>: read the PR state (3 tries) and print the verdict line; the return value is the exit code of `final`.
single_verdict() {
  local R=$1 n=$2 sha=$3 st="" k a state oid entry pos psleep=10 mar
  [ "$R" = full-chaos/scratch-ci ] && psleep=${MERGEGATE_TEST_POLL_SLEEP:-10}
  for k in 1 2 3; do
    st=$(one_state "$R" "$n") && [ -n "$st" ] && break
    st=""; [ "$k" -lt 3 ] && sleep "$psleep"
  done
  if [ -z "$st" ]; then echo "MERGEGATE-ALARM: the state of PR $n is unreadable after 3 tries; it may be queued or merged, read it by hand"; return 4; fi
  set -- $st; state=$1; oid=$2; entry=${3:-NONE}; pos=${4:-?}
  case $state in
    MERGED)
      a=$(ghr "repos/$R/pulls/$n" --jq .head.sha 2>/dev/null) || a=unreadable
      if [ "$a" = "$sha" ]; then echo "MERGE MERGED $oid"; return 0; fi
      echo "MERGEGATE-ALARM: PR $n is MERGED with head $a, not the gated $sha; read main for commit $oid now"; return 4 ;;
    CLOSED) echo "GATE REFUSED: PR $n was closed, not merged"; return 3 ;;
    OPEN)
      if [ "$entry" = NONE ]; then mar=0; merged_after_removal "$R" "$n" "$sha" || mar=$?; [ "$mar" = 99 ] || return "$mar"; echo "GATE REFUSED: PR $n is open and not in the merge queue (ejected); read the failing merge_group run, fix, and enqueue again"; return 3; fi
      echo "STILL QUEUED (not refused): position $pos, entry $entry; PR $n stays in the queue, read it again with: gh pr view $n -R $R"; return 5 ;;
  esac
  echo "MERGEGATE-ALARM: PR $n reports an unknown state '$state'; it is not proved final"; return 4
}

# stack_check <repo> <stack number> <member numbers...>: every member open, in this stack at its position, same repository (no fork), linked
# base -> head ref up from main. Fills CUR_SHA[<pr>] and CUR_REF[<pr>]. Used at the gates and again right before the enqueue.
stack_check() {
  local R=$1 num=$2 k=0 l lj lbase=main; shift 2
  local size=$#
  CUR_SHA=(); CUR_REF=()
  for l in "$@"; do
    k=$((k+1))
    lj=$(ghr "repos/$R/pulls/$l" 2>/dev/null) || { echo "GATE REFUSED: cannot read layer PR $l"; return 3; }
    jq -e --arg R "$R" --argjson k "$k" --argjson size "$size" --arg num "$num" --arg base "$lbase" '
        .state == "open" and (.stack.number|tostring) == $num and .stack.position == $k and .stack.size == $size
        and .head.repo.full_name == $R and .base.repo.full_name == $R and .base.ref == $base' <<<"$lj" >/dev/null 2>&1 \
      || { echo "GATE REFUSED: layer PR $l does not match stack $num (closed, other position or size, a fork, another repository, or its base is not '$lbase')"; return 3; }
    CUR_SHA[$l]=$(jq -r .head.sha <<<"$lj"); CUR_REF[$l]=$(jq -r .head.ref <<<"$lj"); lbase=${CUR_REF[$l]}
  done
}

# ghr_retry <repo> <ghr args>: ghr with up to 3 tries (a pause between) on a transient error (poll_transient); a real 4xx fails at once. Prints the value on success.
ghr_retry() {
  local R=$1 k out ef ps=10; shift
  [ "$R" = full-chaos/scratch-ci ] && ps=${MERGEGATE_TEST_POLL_SLEEP:-10}
  ef=$(mktemp ${tmpd:+-p "$tmpd"}) || return 1
  for k in 1 2 3; do
    out=$(ghr "$@" 2>"$ef") && { rm -f "$ef"; printf '%s\n' "$out"; return 0; }
    poll_transient "$(cat "$ef")" || break
    [ "$k" -lt 3 ] && { sleep "$ps" & wait $!; }
  done
  rm -f "$ef"; return 1
}

# stack_heads_ok <repo> <members...>: every layer's PR head AND branch tip equal the sha that was gated (GATED[<pr>]); the PR head can lag a fresh push, the branch ref does not.
stack_heads_ok() {
  local R=$1 l a b; shift
  for l in "$@"; do
    a=$(ghr_retry "$R" "repos/$R/pulls/$l" --jq .head.sha) || { echo "cannot re-read layer PR $l"; return 3; }
    [ "$a" = "${GATED[$l]}" ] || { echo "layer PR $l moved after its gate (gated ${GATED[$l]:0:8}, PR head now ${a:0:8})"; return 3; }
    b=$(ghr_retry "$R" "repos/$R/branches/${CUR_REF[$l]}" --jq .commit.sha) || { echo "cannot re-read the branch ${CUR_REF[$l]} of layer PR $l"; return 3; }
    [ "$b" = "${GATED[$l]}" ] || { echo "the branch ${CUR_REF[$l]} of layer PR $l moved after its gate (gated ${GATED[$l]:0:8}, branch now ${b:0:8})"; return 3; }
  done
}

# stack_abort <repo> <reason> <members...>: leave nothing queued, and PROVE it.
#  1. a merge request that is still `pending` can enqueue the stack later: poll its uuid to a final state first (MQ_TOP, MQ_UUID are set by stack_final);
#  2. each member's state is read (3 tries; unreadable = alarm); a MERGED member's head is compared with its gated sha (mismatch = alarm);
#  3. each member that is queued is dequeued (the exit code AND .errors of the mutation are checked), then its queue entry is read again until it is gone (3 tries).
# RULE: every `MERGEGATE-ALARM` line means exit 4. Exit 3 only when every member is proved not queued and not merged (a clean refusal). A member not proved out of the queue,
# an unreadable state, a layer merged during an abort (partial landing), an unpolled or unknown-status merge request all exit 4.
# A script cannot send a push notification: the lane reports every MERGEGATE-ALARM line to main at once.
stack_abort() {
  local R=$1 why=$2 l st state entry nid a out k t ms rc=3 psleep=10 nsleep=5; shift 2
  [ "$R" = full-chaos/scratch-ci ] && { psleep=${MERGEGATE_TEST_POLL_SLEEP:-10}; nsleep=${MERGEGATE_TEST_POLL_SLEEP:-5}; }
  if [ -n "${MQ_UUID:-}" ]; then
    t=$((SECONDS+600)); ms=pending; k=0
    [ "$R" = full-chaos/scratch-ci ] && t=$((SECONDS+${MERGEGATE_TEST_PEND_SEC:-600}))
    while [ "$ms" = pending ] && [ $SECONDS -lt $t ]; do
      if ms=$(ghr "repos/$R/pulls/$MQ_TOP/merge-async/$MQ_UUID" --jq .status 2>/dev/null); then k=0; else ms=pending; k=$((k+1)); fi
      [ "$k" -ge 3 ] && break
      [ "$ms" = pending ] && sleep "$psleep"
    done
    case $ms in
      merged|enqueued|failed) ;;
      pending) if [ "$k" -ge 3 ]; then echo "MERGEGATE-ALARM: the merge request $MQ_UUID cannot be read (3 failed reads); it may still enqueue the stack, nobody is watching"
               else echo "MERGEGATE-ALARM: the merge request $MQ_UUID is still pending after 600 s; it may enqueue the stack later, nobody is watching"; fi; rc=4 ;;
      *) echo "MERGEGATE-ALARM: the merge request $MQ_UUID reports an unknown status '$ms'; it is not proved final"; rc=4 ;;
    esac
  fi
  for l in "$@"; do
    st=""
    for k in 1 2 3; do
      st=$(gh api graphql -f query="$STATE_Q" -f owner="${R%%/*}" -f name="${R##*/}" -F number="$l" \
        --jq '.data.repository.pullRequest|"\(.state) \(.mergeCommit.oid // "-") \(.mergeQueueEntry.state // "NONE")"' 2>/dev/null) && [ -n "$st" ] && break
      st=""; sleep "$psleep"
    done
    if [ -z "$st" ]; then echo "MERGEGATE-ALARM: the state of layer PR $l is unreadable after 3 tries: its head and its queue entry are NOT verified"; rc=4; continue; fi
    set -- $st; state=$1; entry=${3:-NONE}
    if [ "$state" = MERGED ]; then
      a=$(ghr "repos/$R/pulls/$l" --jq .head.sha 2>/dev/null) || a=unreadable
      if [ "$a" = "${GATED[$l]}" ]; then echo "MERGEGATE-ALARM: layer PR $l is MERGED (its gated head) but the stack did not complete: a partial landing; read main now"; rc=4
      else echo "MERGEGATE-ALARM: layer PR $l is MERGED with head $a, not the gated ${GATED[$l]}; read main for that commit now"; rc=4; fi
      continue
    fi
    if [ "$entry" = NONE ]; then
      # an entry that is not visible yet reads NONE right after the enqueue: look once more after about 5 s before counting the layer as not queued
      sleep "$nsleep" & wait $!
      st=$(gh api graphql -f query="$STATE_Q" -f owner="${R%%/*}" -f name="${R##*/}" -F number="$l" \
        --jq '.data.repository.pullRequest|"\(.state) \(.mergeCommit.oid // "-") \(.mergeQueueEntry.state // "NONE")"' 2>/dev/null) || st=""
      if [ -n "$st" ]; then set -- $st; state=$1; entry=${3:-NONE}; fi
      if [ "$state" = MERGED ]; then
        a=$(ghr "repos/$R/pulls/$l" --jq .head.sha 2>/dev/null) || a=unreadable
        if [ "$a" = "${GATED[$l]}" ]; then echo "MERGEGATE-ALARM: layer PR $l is MERGED (its gated head) but the stack did not complete: a partial landing; read main now"
        else echo "MERGEGATE-ALARM: layer PR $l is MERGED with head $a, not the gated ${GATED[$l]}; read main for that commit now"; fi
        rc=4; continue
      fi
      if [ "$entry" = NONE ]; then echo "layer PR $l is not queued (state $state)"; continue; fi
    fi
    nid=$(ghr "repos/$R/pulls/$l" --jq .node_id 2>/dev/null) || nid=""
    state=queued
    for k in 1 2 3; do
      if [ -n "$nid" ]; then
        out=$(gh api graphql -f query="$DEQUEUE_Q" -f id="$nid" 2>&1) && { jq -e '.errors == null' <<<"$out" >/dev/null 2>&1 || false; } || out=failed
      else out=failed; fi
      st=$(gh api graphql -f query="$STATE_Q" -f owner="${R%%/*}" -f name="${R##*/}" -F number="$l" \
        --jq '.data.repository.pullRequest|"\(.state) \(.mergeCommit.oid // "-") \(.mergeQueueEntry.state // "NONE")"' 2>/dev/null) || st=""
      set -- $st; state=${1:-unreadable}; entry=${3:-unreadable}
      [ "$state" = MERGED ] && break
      [ "$entry" = NONE ] && break
      sleep "$psleep"
    done
    if [ "$state" = MERGED ]; then
      # the layer merged while it was being dequeued: its head must be the gated one
      a=$(ghr "repos/$R/pulls/$l" --jq .head.sha 2>/dev/null) || a=unreadable
      if [ "$a" = "${GATED[$l]}" ]; then echo "MERGEGATE-ALARM: layer PR $l MERGED while it was being dequeued (its gated head) and the stack did not complete: a partial landing; read main now"; rc=4
      else echo "MERGEGATE-ALARM: layer PR $l is MERGED with head $a, not the gated ${GATED[$l]} (it merged during the dequeue); read main for that commit now"; rc=4; fi
    elif [ "$entry" = NONE ]; then echo "dequeued layer PR $l (proved: no queue entry)"
    else echo "MERGEGATE-ALARM: dequeue failed for layer PR $l (queue entry state: $entry); the layer may still merge, remove it from the queue by hand NOW"; rc=4; fi
  done
  echo "GATE REFUSED: $why"
  return $rc
}

# stack_final <repo> <top pr> <comma list: sha of EVERY layer, bottom to top> <tmpdir>
# The PR given is the TOP. The lane names the head sha of every layer; each must equal the layer's current head, and each layer must contain the one below.
# Layers come from the REST stack member list and are cross-checked (stack_check). Every layer is gated on its own; one failing layer refuses the whole stack.
# Right before the enqueue the member list and every layer head (PR head and branch tip) are checked again. After the enqueue every layer that is not merged
# is checked on each poll; any change dequeues every member and refuses. Any other exit (closed, ejected, timeout) also dequeues the rest and checks the merged ones.
stack_verdict() {
  local R=$1 n=$2 l k st state oid entry pos a psleep=10 alarm=0 abort=0 line r
  local queued="" merged=()
  local -A S=()
  shift 2
  [ "$R" = full-chaos/scratch-ci ] && psleep=${MERGEGATE_TEST_POLL_SLEEP:-10}
  for l in "$@"; do
    st=""
    for k in 1 2 3; do
      st=$(one_state "$R" "$l") && [ -n "$st" ] && break
      st=""; [ "$k" -lt 3 ] && sleep "$psleep"
    done
    if [ -z "$st" ]; then echo "MERGEGATE-ALARM: the state of layer PR $l is unreadable after 3 tries; it may be queued or merged, read it by hand"; alarm=1; continue; fi
    S[$l]=$st
  done
  for l in "$@"; do
    [ -n "${S[$l]:-}" ] || continue
    read -r state oid entry pos <<<"${S[$l]}"; entry=${entry:-NONE}; pos=${pos:-?}
    case $state in
      MERGED)
        a=$(ghr "repos/$R/pulls/$l" --jq .head.sha 2>/dev/null) || a=unreadable
        if [ "$a" = "${GATED[$l]}" ]; then merged+=("$l:$oid")
        else echo "MERGEGATE-ALARM: layer PR $l is MERGED with head $a, not the gated ${GATED[$l]}; read main for commit $oid now"; alarm=1; fi ;;
      CLOSED) abort=1 ;;
      OPEN)
        if [ "$entry" = NONE ]; then abort=1; else queued="$queued #$l position $pos entry $entry;"; fi ;;
      *) echo "MERGEGATE-ALARM: layer PR $l reports an unknown state '$state'; it is not proved final"; alarm=1 ;;
    esac
  done
  if [ "$abort" = 1 ]; then
    stack_abort "$R" "a layer is closed or left the merge queue at the wait deadline (an ejection takes every PR above it out); read the failing merge_group run, fix the lowest red layer, enqueue the top again" "$@"; r=$?; [ "$alarm" = 1 ] && return 4; return $r
  fi
  [ "$alarm" = 1 ] && return 4
  if [ -n "$queued" ]; then
    echo "STILL QUEUED (not refused):$queued the stack of $# layer(s) stays in the queue, read it again with: gh pr view $n -R $R"; return 5
  fi
  for line in "${merged[@]}"; do echo "MERGE MERGED ${line#*:} (layer PR ${line%%:*})"; done
  echo "MERGE MERGED all $# layer(s) of the stack, top PR $n, every layer head equals its gated sha"; return 0
}

# stack_prove_entries <repo> <members...> (CHAOS-11345, acp variant A): after merge-async says enqueued or merged, prove the mergeQueueEntry of the TOP layer (the one
# PR the gate enqueues) as the single path does: 3 reads with a pause between (an entry can be slow to appear). MERGED = proved. OPEN with no entry after 3 reads, or
# CLOSED = not proved: nothing is claimed queued, stack_abort dequeues the stack and proves it (GATE REFUSED, rc 3). A top whose state cannot be read in 3 tries gets the
# single path's MERGEGATE-ALARM (it may be queued, nobody is watching), the same abort, rc 4. INT/TERM during the proof keeps the pre-switch handler (stack_abort, rc 4):
# never STILL QUEUED. Each LOWER unmerged layer gets ONE read of isInMergeQueue and mergeQueueEntry.state, printed as a line and never acted on (whether GitHub shows an
# entry on a lower layer is not yet proved).
LOWER_Q='query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){pullRequest(number:$number){state isInMergeQueue mergeQueueEntry{state}}}}'
stack_prove_entries() {
  local R=$1 top l k st qst qst2 inq ent entry psleep=10 layers; shift
  layers=("$@"); top=${layers[${#layers[@]}-1]}
  [ "$R" = full-chaos/scratch-ci ] && psleep=${MERGEGATE_TEST_POLL_SLEEP:-10}
  qst=""; entry=NONE
  for k in 1 2 3; do
    qst=""; entry=NONE
    st=$(gh api graphql -f query="$STATE_Q" -f owner="${R%%/*}" -f name="${R##*/}" -F number="$top" \
      --jq '.data.repository.pullRequest|"\(.state) \(.mergeCommit.oid // "-") \(.mergeQueueEntry.state // "NONE")"' 2>/dev/null) || st=""
    if [ -n "$st" ]; then
      read -r qst _ entry <<<"$st"; entry=${entry:-NONE}
      case $qst in MERGED|CLOSED) break ;; OPEN) [ "$entry" != NONE ] && break ;; esac
    fi
    [ "$k" -lt 3 ] && { sleep "$psleep" & wait $!; }
  done
  for l in "${layers[@]}"; do
    [ "$l" = "$top" ] && continue
    st=$(gh api graphql -f query="$LOWER_Q" -f owner="${R%%/*}" -f name="${R##*/}" -F number="$l" \
      --jq '.data.repository.pullRequest|"\(.state) \(.isInMergeQueue) \(.mergeQueueEntry.state // "NONE")"' 2>/dev/null) || st=""
    if [ -z "$st" ]; then echo "layer #$l: isInMergeQueue=unreadable entry=unreadable (logged only)"; continue; fi
    read -r qst2 inq ent <<<"$st"
    [ "$qst2" = MERGED ] || echo "layer #$l: isInMergeQueue=$inq entry=${ent:-NONE} (logged only)"
  done
  case $qst in
    "") echo "MERGEGATE-ALARM: the queue entry of the top layer PR $top cannot be read after the enqueue (3 failed reads): it may be queued, nobody is watching; read it by hand"
        stack_abort "$R" "enqueue not proved (unreadable top entry)" "${layers[@]}"; return 4 ;;
    MERGED) return 0 ;;
    CLOSED) stack_abort "$R" "the top layer PR $top was closed right after the enqueue" "${layers[@]}"; return $? ;;
    *) [ "$entry" != NONE ] && return 0
       stack_abort "$R" "not in the queue after enqueue: the top layer PR $top has no merge queue entry (the entry may only be slow to appear: read gh pr view $top -R $R before you enqueue again)" "${layers[@]}"; return $? ;;
  esac
}

stack_left_queued() {
  local R=$1 l out=""; shift
  for l in "$@"; do out="$out #$l ${GATED[$l]};"; done
  echo "STILL QUEUED (gate interrupted, stack left queued, top entry proved at the enqueue; lower layers logged):$out the queue entry was NOT dequeued; read the stack state (gh pr view <top> -R $R) before any second enqueue"
}

stack_final() {
  local rc R=$1 n=$2 shalist=$3 t=$4 lj stknum members=() given=() i l lsha m r o msg fail=0 dry=${MERGEGATE_DRYRUN:-} end=$((SECONDS+7200)) wait_min qwait
  local -A seen=()
  wait_min=${MERGEGATE_QUEUE_WAIT_MIN:-240}
  case $wait_min in ''|*[!0-9]*|0*) echo "GATE REFUSED: MERGEGATE_QUEUE_WAIT_MIN must be a whole number of minutes, 1 or more (got '$wait_min')"; return 3 ;; esac
  qwait=$((wait_min*60))
  [ "$R" = full-chaos/scratch-ci ] && qwait=${MERGEGATE_TEST_QUEUE_WAIT_SEC:-$qwait}
  GATED=(); CUR_SHA=(); CUR_REF=()
  lj=$(ghr "repos/$R/pulls/$n" 2>/dev/null) || { echo "GATE REFUSED: cannot read PR $n"; return 3; }
  stknum=$(jq -r '.stack.number // empty' <<<"$lj"); [ -n "$stknum" ] || { echo "GATE REFUSED: PR $n has no stack number"; return 3; }
  mapfile -t members < <(ghr "repos/$R/stacks/$stknum" --jq '.pull_requests[].number' 2>/dev/null) || members=()
  [ "${#members[@]}" -ge 2 ] && [ "${#members[@]}" -le 10 ] || { echo "GATE REFUSED: cannot read the member list of stack $stknum (or it has fewer than 2 or more than 10 layers)"; return 3; }
  [ "${members[${#members[@]}-1]}" = "$n" ] || { echo "GATE REFUSED: PR $n is not the top of stack $stknum (the top is PR ${members[${#members[@]}-1]}); enqueue the top PR"; return 3; }
  IFS=, read -r -a given <<<"$shalist"
  [ "${#given[@]}" = "${#members[@]}" ] || { echo "GATE REFUSED: a stack of ${#members[@]} layers needs the sha of EVERY layer, bottom to top, comma separated (got ${#given[@]})"; return 3; }
  stack_check "$R" "$stknum" "${members[@]}" || return 3
  for ((i=0; i<${#members[@]}; i++)); do
    l=${members[$i]}
    [ "${CUR_SHA[$l]}" = "${given[$i]}" ] || { echo "GATE REFUSED: layer PR $l has head ${CUR_SHA[$l]} but you gave ${given[$i]}"; return 3; }
    if [ "$i" -ge 1 ]; then
      msg=$(ghr "repos/$R/compare/${given[$((i-1))]}...${given[$i]}" --jq .status 2>/dev/null) || msg=unreadable
      case $msg in ahead|identical) ;; *) echo "GATE REFUSED: layer PR $l (${given[$i]:0:8}) does not contain the layer below (${given[$((i-1))]:0:8}): compare status $msg"; return 3 ;; esac
    fi
    GATED[$l]=${given[$i]}
  done
  echo "STACK: ${#members[@]} layer(s), top PR $n, bottom PR ${members[0]}, stack $stknum"
  for ((i=0; i<${#members[@]}; i++)); do
    l=${members[$i]}; lsha=${GATED[$l]}
    while [ $SECONDS -lt $end ]; do
      o=$(gh pr checks "$l" -R "$R" 2>&1)
      [ -n "$o" ] && [ -z "$(printf '%s\n' "$o" | awk -F'\t' '$2=="pending"')" ] && break
      [ "$dry" = 1 ] && { echo "LAYER #$l: REFUSED: checks still pending (a dry run does not wait)"; fail=1; break; }
      sleep 45
    done
    [ $SECONDS -lt $end ] || { echo "LAYER #$l: REFUSED: timeout waiting for checks"; fail=1; continue; }
    m=$("$HERE/mcheck.sh" "$s_repo_arg" "$l"); echo "$m"
    r=$(parse "$m"); case $r in "GATE OK") ;; *) echo "LAYER #$l: $r"; fail=1; continue ;; esac
    case $m in *" $lsha "*) ;; *) echo "LAYER #$l: REFUSED: mcheck sha differs from $lsha"; fail=1; continue ;; esac
    if ! GATE_STACK_LAYER=1 merge_msg "$R" "$l" "$lsha" "$t" >"$t/layer-$l.txt" 2>&1; then echo "LAYER #$l: $(head -1 "$t/layer-$l.txt")"; fail=1; continue; fi
    [ "$FIXMAIN" = 1 ] && { echo "LAYER #$l: REFUSED: label fix-main, a fix-main PR is never stacked"; fail=1; continue; }
    echo "LAYER #$l: GATE OK at $lsha"
  done
  [ $fail = 0 ] || { echo "GATE REFUSED: at least one layer of the stack failed its gate; nothing was enqueued"; return 3; }
  # test knob (scratch-ci only): a command that runs between the gates and the enqueue, to plant a drift
  if [ "$R" = full-chaos/scratch-ci ] && [ -n "${MERGEGATE_TEST_BEFORE_PUT:-}" ]; then bash -c "$MERGEGATE_TEST_BEFORE_PUT"; fi
  # right before the enqueue: the member list, the full member cross-check (closed, retargeted, fork ...) and every head again
  local again=()
  mapfile -t again < <(ghr "repos/$R/stacks/$stknum" --jq '.pull_requests[].number' 2>/dev/null) || again=()
  [ "${again[*]}" = "${members[*]}" ] || { echo "GATE REFUSED: the stack members changed while the layers were gated (was ${members[*]}, now ${again[*]:-unreadable})"; return 3; }
  stack_check "$R" "$stknum" "${members[@]}" || return 3
  msg=$(stack_heads_ok "$R" "${members[@]}") || { echo "GATE REFUSED: $msg; nothing was enqueued"; return 3; }
  if [ "$dry" = 1 ]; then
    echo "DRYRUN: would enqueue the TOP PR $n (not run):"
    printf 'gh api -X PUT repos/%s/pulls/%s/merge-async -H %q -H %q -f merge_action=merge_queue -f sha=%q\n' "$R" "$n" "X-GitHub-Api-Version: $ASYNC_VER" "Accept: application/vnd.github+json" "${GATED[$n]}"
    echo "DRYRUN: jump=no; stack=${#members[@]} layers"
    return 0
  fi
  # a gate killed from here on must not leave the stack queued unseen: INT and TERM abort (dequeue and prove) and exit 4
  trap 'stack_abort "$R" "gate interrupted" "${members[@]}"; exit 4' INT TERM
  eq=$(gh api -X PUT "repos/$R/pulls/$n/merge-async" -H "X-GitHub-Api-Version: $ASYNC_VER" -H "Accept: application/vnd.github+json" -f merge_action=merge_queue -f sha="${GATED[$n]}" 2>&1) \
    || case $eq in
         *"already pending"*|*409*) echo "MERGEGATE-ALARM: an earlier merge request for PR $n is already pending (409): this gate cannot poll it and cannot say whether it will enqueue the stack"
                                    stack_abort "$R" "an earlier merge request for PR $n is still pending" "${members[@]}"; return 4 ;;
         *"HTTP 400"*|*"HTTP 401"*|*"HTTP 403"*|*"HTTP 404"*|*"HTTP 422"*|*"HTTP 429"*) echo "GATE REFUSED: enqueue rejected: $eq"; return 3 ;;
         *) # a 5xx, a timeout or an unknown failure: the server may have accepted the request
            echo "MERGEGATE-ALARM: the enqueue call failed without a definite rejection ($eq); the server may have accepted it"
            stack_abort "$R" "enqueue call failed without a definite rejection" "${members[@]}"; return 4 ;;
       esac
  # test knob (scratch-ci only): a command that runs right after the enqueue, to push to a queued layer
  if [ "$R" = full-chaos/scratch-ci ] && [ -n "${MERGEGATE_TEST_AFTER_PUT:-}" ]; then bash -c "$MERGEGATE_TEST_AFTER_PUT"; fi
  uuid=$(jq -r '.details.uuid // .uuid // empty' <<<"$eq" 2>/dev/null) || uuid=""
  MQ_TOP=$n; MQ_UUID=$uuid
  mst=$(jq -r '.status // empty' <<<"$eq" 2>/dev/null) || mst=""
  local pend=$((SECONDS+600)) psleep=10 pfail=0
  [ "$R" = full-chaos/scratch-ci ] && pend=$((SECONDS+${MERGEGATE_TEST_PEND_SEC:-600}))
  [ "$R" = full-chaos/scratch-ci ] && psleep=${MERGEGATE_TEST_POLL_SLEEP:-10}
  while [ "$mst" = pending ] && [ -n "$uuid" ] && [ $SECONDS -lt $pend ]; do
    msg=$(stack_heads_ok "$R" "${members[@]}") || { stack_abort "$R" "$msg (while the merge request was pending)" "${members[@]}"; return $?; }
    sleep "$psleep" & wait $!
    if eq=$(gh api "repos/$R/pulls/$n/merge-async/$uuid" -H "X-GitHub-Api-Version: $ASYNC_VER" 2>&1); then pfail=0; else
      pfail=$((pfail+1))
      if poll_transient "$eq"; then echo "WARN: transient error polling the merge request $uuid (try $pfail of 5): $eq"; [ "$pfail" -ge 5 ] || continue
      else echo "WARN: error polling the merge request $uuid (not retried): $eq"; fi
      mst=unpolled; break
    fi
    mst=$(jq -r '.status // empty' <<<"$eq")
  done
  [ "$mst" = pending ] && [ "$pfail" -gt 0 ] && mst=unpolled
  case $mst in
    failed) stack_abort "$R" "the merge request failed: $(jq -r '.details.message // .message // ""' <<<"$eq")" "${members[@]}"; return $? ;;
    merged|enqueued|unpolled) stack_prove_entries "$R" "${members[@]}"; rc=$?
                     [ $rc = 0 ] || return $rc
                     echo "ENQUEUED stack of ${#members[@]} layer(s) through top PR $n at ${GATED[$n]} (status $mst; top entry proved; lower layers logged)"
                     trap 'stack_left_queued "$R" "${members[@]}"; exit 5' INT TERM ;;
    pending) echo "MERGEGATE-ALARM: the merge request $uuid is still pending after 600 s"; stack_abort "$R" "the merge request is still pending" "${members[@]}"; return 4 ;;
    *) echo "MERGEGATE-ALARM: the merge request reports an unknown status '${mst:-none}' ($eq); it is not proved final"; stack_abort "$R" "unknown merge request status '${mst:-none}'" "${members[@]}"; return 4 ;;
  esac
  local qend=$((SECONDS+qwait)) done_n st rest=() qsleep=60
  [ "$R" = full-chaos/scratch-ci ] && qsleep=${MERGEGATE_TEST_QUEUE_SLEEP:-60}
  while [ $SECONDS -lt $qend ]; do
    done_n=0; rest=()
    for l in "${members[@]}"; do
      st=$(gh api graphql -f query="$STATE_Q" -f owner="${R%%/*}" -f name="${R##*/}" -F number="$l" \
        --jq '.data.repository.pullRequest|"\(.state) \(.mergeCommit.oid // "-") \(.mergeQueueEntry.state // "NONE")"' 2>/dev/null) || st=""
      set -- $st
      case ${1:-} in
        "") rest+=("$l") ;;
        MERGED) done_n=$((done_n+1)) ;;
        CLOSED) stack_abort "$R" "PR $l closed while queued; the rest dequeued" "${members[@]}"; return $? ;;
        OPEN) rest+=("$l")
              if [ "${3:-NONE}" = NONE ]; then
                [ "${seen[$l]:-0}" = 1 ] && { stack_abort "$R" "PR $l left the merge queue (an ejection takes every PR above it out); read the failing merge_group run, fix the lowest red layer, enqueue the top again" "${members[@]}"; return $?; }
              else seen[$l]=1; fi ;;
      esac
    done
    if [ "$done_n" = "${#members[@]}" ]; then
      for l in "${members[@]}"; do
        lsha=$(ghr "repos/$R/pulls/$l" --jq .head.sha 2>/dev/null) || lsha=unreadable
        [ "$lsha" = "${GATED[$l]}" ] || { echo "MERGEGATE-ALARM: layer PR $l MERGED with head $lsha, not the gated ${GATED[$l]}; read main for that commit now"; echo "GATE REFUSED: a merged layer differs from its gate"; return 4; }
      done
      echo "MERGE MERGED all ${#members[@]} layer(s) of the stack, top PR $n, every layer head equals its gated sha"; return 0
    fi
    if [ "${#rest[@]}" -gt 0 ]; then
      msg=$(stack_heads_ok "$R" "${rest[@]}") || { stack_abort "$R" "$msg (while queued)" "${members[@]}"; return $?; }
    fi
    sleep "$qsleep" & wait $!
  done
  stack_verdict "$R" "$n" "${members[@]}"; return $?
}

final() {
  local s=$1 n=$2 sha=$3 R head o m r end tmpd subj dry=${MERGEGATE_DRYRUN:-} s_repo_arg stk rc wait_min psleep qsleep qwait qend qk seen qst qmsg mar pfail unp
  [ $# -eq 3 ] || { echo "usage: mergegate-mq.sh final ops <pr> <sha>   (a stack: final ops <top pr> <sha1>,<sha2>,... bottom to top, the head of EVERY layer)"; return 2; }
  case $s in ops) ;; web|acr) echo "mergegate-mq.sh is for ops only (only ops has a merge queue); use mergegate.sh for $s"; return 2 ;; *) echo "bad repo $s; usage: mergegate-mq.sh final ops <pr> <sha>"; return 2 ;; esac
  R=full-chaos/dev-health-$s; end=$((SECONDS+7200)); s_repo_arg=$s
  # test knob: the throwaway proof repository, nothing else (checked against an exact name)
  if [ "${MERGEGATE_TEST_REPO:-}" = full-chaos/scratch-ci ]; then R=full-chaos/scratch-ci; s_repo_arg=full-chaos/scratch-ci; fi
  [ "$R" = full-chaos/scratch-ci ] || red_main "$s" "$n" || return 3
  tmpd=$(umask 077; mktemp -d) || { echo "GATE REFUSED: cannot make temp dir"; return 3; }
  trap "rm -rf '$tmpd'" EXIT
  stk=$(ghr "repos/$R/pulls/$n" --jq '"\(.stack != null) \(.base.ref)"' 2>/dev/null) || stk=unreadable
  case $stk in "true "*|"false "*) ;; *) echo "GATE REFUSED: cannot read whether PR $n is in a stack (REST read failed)"; return 3 ;; esac
  if [ "${stk%% *}" = true ]; then stack_final "$R" "$n" "$sha" "$tmpd"; rc=$?; trap - INT TERM; return $rc; fi
  # a single PR is on main; a PR on another base is an upper layer whose stack object could not be seen: merge-async would take the layers below it ungated
  [ "${stk#* }" = main ] || { echo "GATE REFUSED: PR $n is based on '${stk#* }', not main: it is an upper layer (or a stack whose stack object is missing); enqueue the TOP PR of the stack with the sha of every layer"; return 3; }
  case $sha in *,*) echo "GATE REFUSED: a single PR takes one sha (a comma list is for the top PR of a stack)"; return 3 ;; esac
  wait_min=${MERGEGATE_QUEUE_WAIT_MIN:-240}
  case $wait_min in ''|*[!0-9]*|0*) echo "GATE REFUSED: MERGEGATE_QUEUE_WAIT_MIN must be a whole number of minutes, 1 or more (got '$wait_min')"; return 3 ;; esac
  psleep=10; qsleep=60; qwait=$((wait_min*60))
  if [ "$R" = full-chaos/scratch-ci ]; then psleep=${MERGEGATE_TEST_POLL_SLEEP:-10}; qsleep=${MERGEGATE_TEST_QUEUE_SLEEP:-60}; qwait=${MERGEGATE_TEST_QUEUE_WAIT_SEC:-$qwait}; fi
  while [ $SECONDS -lt $end ]; do
    head=$(gh pr view "$n" -R "$R" --json headRefOid -q .headRefOid)
    [ "$head" != "$sha" ] && { echo "GATE REFUSED: HEAD MOVED to $head"; return 3; }
    o=$(gh pr checks "$n" -R "$R" 2>&1)
    if [ -n "$o" ] && [ -z "$(printf '%s\n' "$o" | awk -F'\t' '$2=="pending"')" ]; then
      if [ "$dry" = 1 ] && [ -n "${MERGEGATE_DRYRUN_MCHECK_LINE:-}" ]; then m=$MERGEGATE_DRYRUN_MCHECK_LINE
      else m=$("$HERE/mcheck.sh" "$s_repo_arg" "$n"); fi
      echo "$m"
      r=$(parse "$m"); echo "$r"
      case $r in "GATE OK") ;; *) return 3;; esac
      case $m in *" $sha "*) ;; *) echo "GATE REFUSED: mcheck sha differs from $sha"; return 3;; esac
      red_main "$s" "$n" || return 3
      merge_msg "$R" "$n" "$sha" "$tmpd" || return 3
      subj=$(cat "$tmpd/subject.txt")
      if [ "$dry" = 1 ]; then
        if [ "$FIXMAIN" = 1 ]; then
          echo "DRYRUN: would enqueue at the FRONT of the queue (not run): the PR has the label fix-main, jump:true"
          printf 'gh api graphql -f query=%q -f id=%q -f oid=%q\n' "$JUMP_Q" "<node id of PR $n>" "$sha"
          echo "DRYRUN: jump=yes"
        else
          echo "DRYRUN: would enqueue (not run):"
          printf 'gh api -X PUT repos/%s/pulls/%s/merge-async -H %q -H %q -f merge_action=merge_queue -f sha=%q\n' "$R" "$n" "X-GitHub-Api-Version: $ASYNC_VER" "Accept: application/vnd.github+json" "$sha"
          echo "DRYRUN: jump=no"
        fi
        echo "DRYRUN: the squash subject would be the PR title + (#$n) and the body the PR body, from the repository settings; checked content:"
        echo "-----BODY BEGIN-----"; cat "$tmpd/body.txt"; echo; echo "-----BODY END-----"
        return 0
      fi
      if [ "$FIXMAIN" = 1 ]; then
        nid=$(gh pr view "$n" -R "$R" --json id -q .id) || { echo "GATE REFUSED: cannot read the PR node id"; return 3; }
        eq=$(gh api graphql -f query="$JUMP_Q" -f id="$nid" -f oid="$sha" 2>&1) || { echo "GATE REFUSED: enqueue (jump) failed: $eq"; return 3; }
        if jq -e '.errors != null' <<<"$eq" >/dev/null 2>&1; then echo "GATE REFUSED: enqueue (jump) failed: $eq"; return 3; fi
        qmsg="ENQUEUED $n at $sha (fix-main: jump, front of the queue)"
      else
        eq=$(gh api -X PUT "repos/$R/pulls/$n/merge-async" -H "X-GitHub-Api-Version: $ASYNC_VER" -H "Accept: application/vnd.github+json" -f merge_action=merge_queue -f sha="$sha" 2>&1) \
          || case $eq in *"already pending"*|*409*) ;; *) echo "GATE REFUSED: enqueue failed: $eq"; return 3 ;; esac
        uuid=$(jq -r '.details.uuid // .uuid // empty' <<<"$eq" 2>/dev/null) || uuid=""
        mst=$(jq -r '.status // empty' <<<"$eq" 2>/dev/null) || mst=""
        pend=$((SECONDS+600)); pfail=0; unp=0
        [ "$R" = full-chaos/scratch-ci ] && pend=$((SECONDS+${MERGEGATE_TEST_PEND_SEC:-600}))
        while [ "$mst" = pending ] && [ -n "$uuid" ] && [ $SECONDS -lt $pend ]; do
          sleep "$psleep"
          if eq=$(gh api "repos/$R/pulls/$n/merge-async/$uuid" -H "X-GitHub-Api-Version: $ASYNC_VER" 2>&1); then pfail=0; else
            pfail=$((pfail+1))
            if poll_transient "$eq"; then echo "WARN: transient error polling the merge request $uuid (try $pfail of 5): $eq"; [ "$pfail" -ge 5 ] || continue
            else echo "WARN: error polling the merge request $uuid (not retried): $eq"; fi
            mst=unpolled; break
          fi
          mst=$(jq -r '.status // empty' <<<"$eq")
        done
        [ "$mst" = pending ] && [ "$pfail" -gt 0 ] && mst=unpolled
        case $mst in
          failed) # "failed" resolves only THIS request: an earlier or parallel enqueue can still have the PR queued, so the PR state decides (CHAOS-11616 B4)
                  echo "WARN: the merge request failed: $(jq -r '.details.message // .message // ""' <<<"$eq"); the PR state decides"; single_verdict "$R" "$n" "$sha"; return $? ;;
          merged|enqueued) qmsg="ENQUEUED $n at $sha (status $mst)" ;;
          unpolled) unp=1; qmsg="ENQUEUED? $n at $sha (the merge request poll failed; the PR state is read next, rc from the real state)" ;;
          pending) echo "MERGEGATE-ALARM: the merge request $uuid is still pending after 600 s; it may enqueue PR $n later, nobody is watching; read it by hand: gh pr view $n -R $R"; return 4 ;;
          *) echo "MERGEGATE-ALARM: unexpected merge request status '${mst:-none}': $eq; PR $n may be queued, read it by hand"; return 4 ;;
        esac
      fi
      # prove the queue entry before reporting ENQUEUED (CHAOS-11295): a reply "enqueued" with no mergeQueueEntry is not a queued PR.
      # An entry that is not visible yet reads NONE right after the enqueue: up to 3 reads, with a pause between.
      seen=0; qst=""
      for qk in 1 2 3; do
        qst=""; st=$(one_state "$R" "$n") || st=""
        if [ -n "$st" ]; then
          set -- $st; qst=$1
          case $1 in MERGED|CLOSED) break ;; OPEN) [ "${3:-NONE}" != NONE ] && { seen=1; break; } ;; esac
        fi
        [ "$qk" -lt 3 ] && sleep "$psleep"
      done
      if [ "$seen" = 0 ] && [ "$qst" != MERGED ]; then
        case $qst in
          "") echo "MERGEGATE-ALARM: the queue entry of PR $n cannot be read after the enqueue (3 failed reads): it may be queued, nobody is watching; read it by hand"; return 4 ;;
          CLOSED) [ "$unp" = 1 ] && { echo "MERGEGATE-ALARM: PR $n is closed after an enqueue whose merge request was never polled; it is not proved resolved, read it by hand"; return 4; }
                  echo "GATE REFUSED: PR $n was closed right after the enqueue"; return 3 ;;
          *) [ "$unp" = 1 ] && { echo "MERGEGATE-ALARM: PR $n has no queue entry (state $qst) and the merge request $uuid was never polled to a final state: it may still enqueue the PR later, nobody is watching; read it by hand: gh pr view $n -R $R"; return 4; }
             echo "GATE REFUSED: not in the queue after enqueue: PR $n has no merge queue entry (state $qst); the entry may only be slow to appear: read gh pr view $n -R $R before you enqueue again"; return 3 ;;
        esac
      fi
      echo "$qmsg"
      qend=$((SECONDS+qwait))
      while [ $SECONDS -lt $qend ]; do
        st=$(one_state "$R" "$n") || st=""
        set -- $st
        case ${1:-} in
          MERGED) single_verdict "$R" "$n" "$sha"; return $? ;;
          CLOSED) echo "GATE REFUSED: PR closed while queued"; return 3 ;;
          OPEN) if [ "${3:-NONE}" = NONE ]; then
                  [ $seen = 1 ] && { mar=0; merged_after_removal "$R" "$n" "$sha" || mar=$?; [ "$mar" = 99 ] || return "$mar"; echo "GATE REFUSED: ejected from the merge queue; read the failing merge_group run, fix, and enqueue again"; return 3; }
                else seen=1; fi ;;
        esac
        sleep "$qsleep"
      done
      # the wait deadline: say what the queue really did; a PR still queued is not a refusal and stays in the queue
      single_verdict "$R" "$n" "$sha"; return $?
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
  *) echo "usage: mergegate-mq.sh parse [\"<mcheck output>\"] | final ops <pr> <sha> | dryrun ops <pr> <sha>   (ops only; web and acr use mergegate.sh)"; exit 2 ;;
esac
