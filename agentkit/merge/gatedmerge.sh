#!/bin/bash
# D6122/D6124 gated merge. usage: gatedmerge.sh <ops|web|acr> <pr> <sha> <clone-with-origin>
# gate = mergegate.sh parse; merge = mergegate.sh final (reruns mcheck). Merges only when: head==sha, no pending checks, mcheck nonpass=0 chaos=0 signed=true, and
# overlap is [] OR only ci/go_race_weights.tsv and/or .github/workflows/go.yml with the merged-tree checks green.
MG=/var/lib/oci-cache/lane-scratch/shared/mergegate.sh; s=$1; n=$2; sha=$3; clone=$4; R=full-chaos/dev-health-$s; end=$((SECONDS+7200)); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
while [ $SECONDS -lt $end ]; do
  head=$(gh pr view $n --repo $R --json headRefOid -q .headRefOid)
  [ "$head" != "$sha" ] && { echo "HEAD MOVED to $head: not merging"; exit 2; }
  o=$(gh pr checks $n --repo $R 2>&1)
  if [ -n "$o" ] && [ -z "$(echo "$o" | awk -F'\t' '$2=="pending"')" ]; then
    m=$(/var/lib/oci-cache/lane-scratch/shared/mcheck.sh $s $n); echo "$m"
    $MG parse "$m" || exit 3
    ov=$(echo "$m" | sed -n 's/.*overlap=\[\(.*\)\].*/\1/p' | tr -s ' ' '\n' | grep -v '^$')
    other=$(echo "$ov" | grep -vE '^(ci/go_race_weights\.tsv|\.github/workflows/go\.yml|ci/venue_oracle_closure\.d/.+|ci/check_go\.sh|.+\.md)$' | grep -v '^$')
    [ -n "$other" ] && { echo "GATE NOT MET: overlap needs a signed main merge: $other"; exit 3; }
    if [ -n "$ov" ]; then
      cd $clone || exit 4; git fetch -q origin main; git checkout -q --detach $sha
      tree=$(git merge-tree --write-tree origin/main $sha) || { echo "GATE NOT MET: merge-tree conflict"; exit 3; }
      mc=$(git commit-tree $tree -p $sha -p origin/main -m "trial merge")
      git checkout -q --detach $mc || exit 4
      res=""
      ci/check_go.sh race-weights-rows >$T/rwr 2>&1 && res="$res race-weights-rows=ok" || { echo "GATE NOT MET: race-weights-rows"; tail -3 $T/rwr; exit 3; }
      grep -v '^\(#\|[[:space:]]*$\)' ci/go_race_weights.tsv | LC_ALL=C sort -c >/dev/null 2>&1 && res="$res sort-c=ok" || { echo "GATE NOT MET: sort -c"; exit 3; }
      bash -n ci/check_go.sh && res="$res bash-n=ok" || { echo "GATE NOT MET: bash -n ci/check_go.sh"; exit 3; }
      ci/check_go.sh auth fuzz-registry >$T/fz 2>&1 && res="$res fuzz-registry=ok" || { echo "GATE NOT MET: fuzz-registry"; tail -3 $T/fz; exit 3; }
      go test -count=1 ./internal/testsupport/venuechanged -run TestClosureFilesMatchTheTestBinaryDependencies >$T/cl 2>&1 && res="$res closure-test=ok" || { echo "GATE NOT MET: closure test"; tail -5 $T/cl; exit 3; }
      go vet ./... >$T/vet 2>&1 && res="$res go-vet=ok" || { echo "GATE NOT MET: go vet"; tail -5 $T/vet; exit 3; }
      go test -count=1 ./internal/cigates/workflows >$T/wf 2>&1 && res="$res workflows-tests=ok" || { echo "GATE NOT MET: workflows tests"; tail -5 $T/wf; exit 3; }
      python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/go.yml'))" 2>/dev/null && res="$res go.yml-parse=ok" || { command -v actionlint >/dev/null && actionlint .github/workflows/go.yml && res="$res actionlint=ok" || { echo "GATE NOT MET: go.yml parse"; exit 3; }; }
      note="D6124 merge without a main merge: merge-tree ${tree} exits 0; on the merged tree:${res}."
      body=$(gh pr view $n --repo $R --json body -q .body)
      printf '%s\n\n%s\n' "$body" "$note" > $T/body; gh pr edit $n --repo $R --body-file $T/body >/dev/null
      echo "$note"
      git checkout -q --detach $sha
    fi
    if [ -n "$ov" ]; then
      # body edited: let the spawned checks appear and finish, then final reruns mcheck + parse
      sleep 60
      while [ $SECONDS -lt $end ]; do
        o=$(gh pr checks $n --repo $R 2>&1)
        [ -n "$o" ] && [ -z "$(echo "$o" | awk -F'\t' '$2=="pending"')" ] && break
        sleep 45
      done
    fi
    $MG final $s $n $sha
    exit $?
  fi
  sleep 45
done; echo timeout
