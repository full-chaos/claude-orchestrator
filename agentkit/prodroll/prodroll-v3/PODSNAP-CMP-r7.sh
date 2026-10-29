#!/usr/bin/env bash
# PODSNAP-CMP-r7.sh <before> <after> <targets: deployment[,deployment...]> <scalers: deployment[,...]|none>   LOCAL, read-only (DRAFT-11667B-r7-addendum1.md, I6u-s).
# Input lines (kubectl custom-columns, no header): <pod> <uid> <restarts csv> <ownerKind> <ownerName>. A ReplicaSet owner maps to its Deployment (the name minus the last -<hash>).
# Each pod of <before>: owner Deployment in targets = EXEMPT-TARGET, in scalers = EXEMPT-SCALER; else KEPT (same name, uid, restarts in <after>), MISSING (no such name), CHANGED (uid or restarts differ).
# PASS iff both files hold well-formed lines, KEPT >= 1, MISSING = 0, CHANGED = 0. Exit 0 PASS, 1 FAIL, 2 usage.
case "$-" in *x*) echo "PODSNAP REFUSED: xtrace is on"; exit 10;; esac
set -u
[ $# -eq 4 ] || { echo "usage: PODSNAP-CMP-r7.sh <before> <after> <targets> <scalers|none>"; exit 2; }
for x in "$3" "$4"; do case "$x" in ""|*[!a-z0-9,-]*) echo "PODSNAP usage: bad Deployment list '$x'"; exit 2;; esac; done
for f in "$1" "$2"; do [ -s "$f" ] || { echo "PODSNAP FAIL: $f is missing or empty"; exit 1; }; done
awk -v T="$3" -v S="$4" '
function dep(k, n) { if (k == "ReplicaSet") { sub(/-[a-z0-9]+$/, "", n) } return n }
BEGIN { nt = split(T, t, ","); for (i = 1; i <= nt; i++) tg[t[i]] = 1; ns = split(S, s, ","); for (i = 1; i <= ns; i++) if (s[i] != "none") sc[s[i]] = 1 }
FNR == 1 { fi++ }
NF != 5 { printf "PODSNAP FAIL: malformed line %d of %s (%d fields)\n", FNR, FILENAME, NF; bad = 1; next }
fi == 1 { order[++nb] = $1; uid[$1] = $2; rs[$1] = $3; own[$1] = dep($4, $5); next }
fi == 2 { auid[$1] = $2; ars[$1] = $3; aown[$1] = dep($4, $5); seen[$1] = 1 }
END {
  if (fi != 2) { print "PODSNAP FAIL: need two files"; exit 1 }
  for (i = 1; i <= nb; i++) { p = order[i]; d = own[p]
    if (d in tg) { print "EXEMPT-TARGET " p " (" d ")"; et++; continue }
    if (d in sc) { print "EXEMPT-SCALER " p " (" d ")"; es++; continue }
    if (!(p in seen)) { print "MISSING " p " (" d ")"; mi++; continue }
    if (auid[p] != uid[p] || ars[p] != rs[p]) { print "CHANGED " p " (" d ") uid " (auid[p] == uid[p] ? "same" : "differs") " restarts " rs[p] " -> " ars[p]; ch++; continue }
    print "KEPT " p " (" d ") restarts " rs[p]; kp++ }
  for (p in seen) if (!(p in uid) && !(aown[p] in tg) && !(aown[p] in sc)) { print "INFO new non-target pod " p " (" aown[p] ")" }
  printf "PODSNAP before %d pods: kept %d, missing %d, changed %d, exempt-target %d, exempt-scaler %d\n", nb, kp, mi, ch, et, es
  if (!bad && kp >= 1 && mi == 0 && ch == 0) { print "PODSNAP: PASS"; exit 0 } else { print "PODSNAP: FAIL"; exit 1 }
}' "$1" "$2"
