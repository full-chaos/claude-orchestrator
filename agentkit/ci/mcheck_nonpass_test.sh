#!/bin/bash
# offline tests of mcheck.sh nonpass calculation (fixture JSON, no network)
MC=$(dirname "$0")/mcheck.sh; pass=0; fail=0
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
TODAY=2026-10-20
run() { # name expect_count expect_exempt runs-json statuses-json known-tsv-content
  printf '%s' "$4" >"$D/cr.json"; printf '%s' "$5" >"$D/st.json"; printf '%b' "$6" >"$D/kr.tsv"
  out=$("$MC" --nonpass-file "$D/cr.json" "$D/st.json" "$D/kr.tsv" $TODAY)
  if [ "$out" = "$2${3:+ $3}" ] || { [ -z "$3" ] && [ "$out" = "$2 " ]; }; then pass=$((pass+1)); echo "ok   $1 -> $out"; else fail=$((fail+1)); echo "FAIL $1 got '$out' want '$2 $3'"; fi; }
cr() { echo "{\"total_count\":1,\"check_runs\":[$1]}"; }
r() { echo "{\"id\":$1,\"name\":\"$2\",\"conclusion\":\"$3\",\"completed_at\":\"$4\"}"; }
none='{"state":"success","statuses":[]}'
run nonrequired-failure 1 "" "$(cr "$(r 1 auth-corpus-external\ \(acp\) failure 2026-10-20T01:00:00Z)")" "$none" ""
run all-success 0 "" "$(cr "$(r 1 a success 2026-10-20T01:00:00Z),$(r 2 b success 2026-10-20T01:00:00Z)")" "$none" ""
run cancelled-then-success 0 "" "$(cr "$(r 1 a cancelled 2026-10-20T01:00:00Z),$(r 2 a success 2026-10-20T02:00:00Z)")" "$none" ""
run success-then-failure 1 "" "$(cr "$(r 1 a success 2026-10-20T01:00:00Z),$(r 2 a failure 2026-10-20T02:00:00Z)")" "$none" ""
run id-fallback 0 "" "$(cr "{\"id\":1,\"name\":\"a\",\"conclusion\":\"failure\",\"completed_at\":null},{\"id\":2,\"name\":\"a\",\"conclusion\":\"success\",\"completed_at\":null}")" "$none" ""
run timed_out 1 "" "$(cr "$(r 1 a timed_out 2026-10-20T01:00:00Z)")" "$none" ""
run action_required 1 "" "$(cr "$(r 1 a action_required 2026-10-20T01:00:00Z)")" "$none" ""
run skipped-neutral 0 "" "$(cr "$(r 1 a skipped 2026-10-20T01:00:00Z),$(r 2 b neutral 2026-10-20T01:00:00Z)")" "$none" ""
run knownred-active 0 "kj" "$(cr "$(r 1 kj failure 2026-10-20T01:00:00Z)")" "$none" "# c\nkj\tCHAOS-1\t2026-10-20\n"
run knownred-expired 1 "" "$(cr "$(r 1 kj failure 2026-10-20T01:00:00Z)")" "$none" "kj\tCHAOS-1\t2026-10-19\n"
run knownred-other-still-counts 1 "kj" "$(cr "$(r 1 kj failure 2026-10-20T01:00:00Z),$(r 2 z failure 2026-10-20T01:00:00Z)")" "$none" "kj\tT\t2027-01-01\n"
run status-failure 1 "" "$(cr "$(r 1 a success 2026-10-20T01:00:00Z)")" '{"state":"failure","statuses":[{"id":9,"context":"ext/ci","state":"failure","updated_at":"2026-10-20T01:00:00Z"}]}' ""
run status-error 1 "" "$(cr "")" '{"statuses":[{"id":9,"context":"ext/ci","state":"error","updated_at":"2026-10-20T01:00:00Z"}]}' ""
run status-success 0 "" "$(cr "")" '{"statuses":[{"id":9,"context":"ext/ci","state":"success","updated_at":"2026-10-20T01:00:00Z"}]}' ""
# pagination: two docs
two="$(cr "$(r 1 a failure 2026-10-20T01:00:00Z)")
$(cr "$(r 2 b failure 2026-10-20T01:00:00Z)")"
run paginated-two-docs 2 "" "$two" "$none" ""
echo "$pass/$((pass+fail)) pass"; [ $fail -eq 0 ]
