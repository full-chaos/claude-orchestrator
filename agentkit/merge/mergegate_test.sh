#!/bin/bash
# planted-line tests of mergegate.sh parse
MG=$(dirname "$0")/mergegate.sh; pass=0; fail=0
SHA=0123456789abcdef0123456789abcdef01234567
L() { echo "ops#4514 $SHA stale=no state=CLEAN headings=2 $1 overlap=[ci/go_race_weights.tsv ]"; }
t() { # name expect(0|3) input
  out=$("$MG" parse "$3"); rc=$?
  if [ $rc -eq $2 ]; then pass=$((pass+1)); echo "ok   $1 -> $out"; else fail=$((fail+1)); echo "FAIL $1 rc=$rc -> $out"; fi; }
t allpass 0 "$(L 'chaos=0 nonpass=0 signed=true')"
t allpass-with-noise 0 "$(printf 'warn x\n%s\n' "$(L 'chaos=0 nonpass=0 signed=true')")"
t chaos1 3 "$(L 'chaos=1 nonpass=0 signed=true')"
t chaos10 3 "$(L 'chaos=10 nonpass=0 signed=true')"
t chaos01 3 "$(L 'chaos=01 nonpass=0 signed=true')"
t xchaos0 3 "$(L 'xchaos=0 nonpass=0 signed=true')"
t nonpass1 3 "$(L 'chaos=0 nonpass=1 signed=true')"
t chaos-missing 3 "$(L 'nonpass=0 signed=true')"
t signed-false 3 "$(L 'chaos=0 nonpass=0 signed=false')"
t signed-null 3 "$(L 'chaos=0 nonpass=0 signed=')"
t dup-conflict 3 "$(L 'chaos=0 chaos=1 nonpass=0 signed=true')"
t dup-same 3 "$(L 'chaos=0 chaos=0 nonpass=0 signed=true')"
t xnonpass0 3 "$(L 'chaos=0 xnonpass=0 signed=true')"
t nonpass0x 3 "$(L 'chaos=0 nonpass=0x signed=true')"
t token-in-overlap-only 3 "ops#1 $SHA stale=no state=CLEAN headings=2 chaos=1 nonpass=0 signed=true overlap=[chaos=0 ]"
t empty 3 ""
t garbage 3 "chaos=0 nonpass=0 signed=true"
t nonpass-err 3 "$(L 'chaos=0 nonpass=ERR knownred=[] signed=true')"
t knownred-token-ok 0 "$(L 'chaos=0 nonpass=0 knownred=[auth-corpus-external (acp)] signed=true')"
t knownred-cannot-hide-nonpass 3 "$(L 'chaos=0 nonpass=2 knownred=[x] signed=true')"
echo "$pass/$((pass+fail)) pass"; [ $fail -eq 0 ]
