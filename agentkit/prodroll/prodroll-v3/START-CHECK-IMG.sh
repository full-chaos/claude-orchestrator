#!/usr/bin/env bash
# START-CHECK-IMG.sh -- the image-step START check (acp S2; the rb-v3 B1 form). Run ON the prod host at the START of a step, before I1:
#   ssh prod "EXP_START_REV=<n> bash -s" < START-CHECK-IMG.sh      (GATE0-IMG line I0s; <n> = EXP_START_REV from the step's `#EXPSTART <n>`)
# Reads the helm history of release dev-health with plain `helm history` (KUBECONFIG exported) and REFUSES with a named exit unless the newest revision is EXP_START_REV and deployed:
#   0 PASS | 2 USAGE | 3 START-REV-MISMATCH | 4 NEWEST-REV-NOT-DEPLOYED (a roll in flight or failed) | 5 HELM-HISTORY-UNREADABLE | 10 xtrace on
case "$-" in *x*) echo "START-CHECK: REFUSED (exit 10): xtrace is on"; exit 10;; esac
case ":${SHELLOPTS:-}:" in *:xtrace:*) echo "START-CHECK: REFUSED (exit 10): SHELLOPTS has xtrace"; exit 10;; esac
set -uo pipefail
export KUBECONFIG=${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}
[[ "${EXP_START_REV:-}" =~ ^[0-9]+$ ]] || { echo "START-CHECK: REFUSED (USAGE) EXP_START_REV must be a number"; exit 2; }
h=$(helm history dev-health -n dev-health -o json 2>/dev/null) && [ -n "$h" ] && printf '%s' "$h" | jq -e 'type == "array" and length > 0' > /dev/null 2>&1 || { echo "START-CHECK: REFUSED (HELM-HISTORY-UNREADABLE)"; exit 5; }
newest=$(printf '%s' "$h" | jq -r 'last|"\(.revision) \(.status)"' 2>/dev/null) && [ -n "$newest" ] || { echo "START-CHECK: REFUSED (HELM-HISTORY-UNREADABLE) not json"; exit 5; }
dep=$(printf '%s' "$h" | jq -r '[.[]|select(.status=="deployed")]|last|.revision // "none"' 2>/dev/null)
echo "START-CHECK: newest row = $newest; newest deployed revision = $dep; expected = $EXP_START_REV"
[ "${newest#* }" = deployed ] || { echo "START-CHECK: REFUSED (NEWEST-REV-NOT-DEPLOYED) newest row '$newest'"; exit 4; }
[ "${newest%% *}" = "$EXP_START_REV" ] && [ "$dep" = "$EXP_START_REV" ] || { echo "START-CHECK: REFUSED (START-REV-MISMATCH) deployed $dep, newest ${newest%% *}, expected $EXP_START_REV"; exit 3; }
echo "START-CHECK: PASS (revision $EXP_START_REV is the newest and deployed)"
