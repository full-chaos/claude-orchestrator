#!/usr/bin/env bash
# Tests the go/py(+web) exec counter of codex-review.sh.v4.8.28-* (CHAOS-10193).
# Usage: test-void-in-form-v4.8.28.sh [wrapper]   (default: the v4.8.28 file beside this script)
# Against v4.8.27 the real round548 web log case FAILS (red); against v4.8.28 all pass.
set -u
D=$(cd "$(dirname "$0")" && pwd)
W=${1:-$(ls "$D"/codex-review.sh.v4.8.28-* | head -1)}
LOG=/home/ubuntu/devhealth/_records/round548-10125b/fcs-acpA-round548-r1-20261019T041658.log
AWKF=$(mktemp); T=$(mktemp); trap 'rm -f "$AWKF" "$T"' EXIT
sed -n "/^EXEC_CLASSIFY_AWK=\$(cat <<'AWK'/,/^AWK\$/p" "$W" | sed '1d;$d' > "$AWKF"
[ -s "$AWKF" ] || { echo "FAIL: cannot extract awk"; exit 1; }
cls() { awk -v BLOCKED_PAT='Operation not permitted|sandbox' -v PATCH_NAME=.codex-review.patch -f "$AWKF" "$1"; }
fail=0
# want: "exec" (go+py > 0) or "none" (go+py == 0)
chk() { local out go py ok=0; out=$(cls "$2"); go=${out%% *}; py=${out#* }; py=${py%% *}
  if [ "$3" = exec ]; then [ $((go + py)) -gt 0 ] && ok=1; else [ $((go + py)) -eq 0 ] && ok=1; fi
  if [ $ok = 1 ]; then echo "PASS $1 (go py hits diff = $out, want $3)"; else echo "FAIL $1 (go py hits diff = $out, want $3)"; fail=1; fi; }
one() { printf 'exec\n/bin/bash -lc %s in /w\n succeeded in 5ms:\nout\ncodex\ndone\n' "$1" > "$T"; }
pos() { one "$2"; chk "$1" "$T" exec; }
neg() { one "$2"; chk "$1" "$T" none; }
[ -r "$LOG" ] && chk real-web-round548-log "$LOG" exec || { echo "FAIL missing $LOG"; fail=1; }
pos vitest-run "'cd web && npx vitest run ci/__tests__/x.test.ts'"
pos pnpm-exec-vitest "'pnpm exec vitest run'"
pos npm-test "'npm test'"
pos pnpm-test "'pnpm test:unit'"
pos pnpm-run-test "'pnpm run test'"
pos node-gate "'node scripts/check-client-bundle.mjs'"
pos tsx-gate "'npx tsx ci/gate_web_auth_profiles.ts --schema s.json'"
pos playwright "'npx playwright test e2e/a.spec.ts'"
pos multiline-later-line "\"set -e
cd web
pnpm exec vitest run\""
neg cat-package-json "'cat package.json'"
neg rg-vitest-dep "'rg -n \"vitest\" package.json pnpm-lock.yaml'"
neg node-version "'node --version'"
neg pnpm-install "'pnpm install --frozen-lockfile'"
neg pnpm-version "'pnpm --version'"
neg sed-test-file "'sed -n 1,80p src/foo.test.ts'"
exit $fail
