#!/usr/bin/env bash
# Tests the DIFF_SEEN (VOID IN FORM) parser of codex-review.sh.v4.8.27-* (CHAOS-10147).
set -u
D=$(cd "$(dirname "$0")" && pwd)
W=${1:-$(ls "$D"/codex-review.sh.v4.8.27-* | head -1)}
R=/home/ubuntu/devhealth/_records
AWKF=$(mktemp); trap 'rm -f "$AWKF" "$NEG" "$NEG2" "$NEG3" "$POS"' EXIT
sed -n "/^EXEC_CLASSIFY_AWK=\$(cat <<'AWK'/,/^AWK\$/p" "$W" | sed '1d;$d' > "$AWKF"
[ -s "$AWKF" ] || { echo "FAIL: cannot extract awk"; exit 1; }
seen() { awk -v BLOCKED_PAT='Operation not permitted|sandbox' -v PATCH_NAME=.codex-review.patch -f "$AWKF" "$1" | awk '{print $4}'; }
fail=0
chk() { # name log want(0=void,1=seen)
  local d; d=$(seen "$2"); local ok=0
  if [ "$3" = void ]; then [ "$d" = 0 ] && ok=1; else [ "$d" -gt 0 ] 2>/dev/null && ok=1; fi
  if [ $ok = 1 ]; then echo "PASS $1 (diff_seen=$d, want $3)"; else echo "FAIL $1 (diff_seen=$d, want $3)"; fail=1; fi
}
chk fp-round502 "$R/round502-10094/fcs10094-round502-r1-20261018T171529.log" seen
chk fp-round514 "$(ls $R/round514-chaos-8801b/*.log | head -1)" seen
# real-log batch cases from other rounds (also read the diff)
chk fp-round247 "$R/round247-9799/gwc-round247-r2-20261015T164733.log" seen
chk fp-round463 "$R/round463-chaos-9964/gwcb-ops3-round463-r1-20261018T044221.log" seen
# synthetic negatives: no diff exec at all / diff exec failed (batched)
NEG=$(mktemp); NEG2=$(mktemp); NEG3=$(mktemp); POS=$(mktemp)
cat > "$NEG" <<'L'
exec
/bin/bash -lc 'git status --short' in /w
exec
/bin/bash -lc 'ls -la' in /w
2026-10-18T18:40:20.612964Z ERROR rmcp::transport::worker: worker quit
 succeeded in 10ms:
 M a.go
 succeeded in 12ms:
total 0
codex
Looks fine.
L
cat > "$NEG2" <<'L'
exec
/bin/bash -lc 'git diff --stat a...b' in /w
exec
/bin/bash -lc "sed -n '1,260p' .codex-review.patch" in /w
 failed in 5ms:
fatal: Operation not permitted
 exited 1 in 6ms:
sed: can't read .codex-review.patch
L
cat > "$NEG3" <<'L'
exec
/bin/bash -lc 'git diff --stat a...b' in /w
exec
/bin/bash -lc 'git status --short' in /w
 failed in 5ms:
fatal: Operation not permitted
 succeeded in 6ms:
 M a.go
L
cat > "$POS" <<'L'
exec
/bin/bash -lc 'git diff --stat a...b' in /w
exec
/bin/bash -lc 'git status --short' in /w
 succeeded in 5ms:
 M a.go
 succeeded in 6ms:
 a.go | 1 +
L
chk synthetic-diff-failed-status-ok "$NEG3" void
chk synthetic-diff-ok-status-ok "$POS" seen
chk synthetic-no-diff-exec "$NEG" void
chk synthetic-all-diff-execs-failed "$NEG2" void
exit $fail
