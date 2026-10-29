#!/usr/bin/env bash
# ROLL-24d.sh (roll 24d, CHAOS-11612 + CHAOS-11614; deploy values + one chart template): TWO stages, each ONE helm upgrade via ./dev-health: `app` (TIP_APP, FIRST) then `ds` (TIP, the data-store step ALONE; D6412). Rollback tree = RB (deploy main R0 = the live release before the roll).
# Run ON prod via: ssh prod 'R=24d bash -s -- <phase> [args]' < ROLL-24d.sh. Prints names/counts only.
# STOP POINTS: ANY step denied by the classifier => STOP at once, report the EXACT step; NO retry, NO other path, NO workaround.
# NO kubectl exec, NO Secret read (D6233), NO pod shell (D6231). The only prod WRITES in this file are the `deploy` and `helm-rollback` phases (helm via ./dev-health).
# ROLLBACK (pm decides): `helm-rollback <rev>` ONLY, where <rev> is LIVEREV (before the app step) or LIVEREV2 (after the app step, before the data-store step). helm rollback runs the pre-/post-rollback hooks of the target revision (river-migrate, a pre-rollback hook of R0); 24d changes no schema, so nothing new is migrated; no psql/exec in any form (D6231). After it: `wait helm-rollback`, then `rollcheck app|ds`.
set -u; export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
NS=dev-health; D=$HOME/lane-prod-k8s; K="kubectl -n $NS"
# D6331 helpers (24d): jsonpath of ONLY the needed fields, never -o json of pods/deploys/ingresses (acp item 8)
pj_lines() { $K get pods ${1:+-l "$1"} -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.phase}{" "}{.metadata.deletionTimestamp}{"|"}{range .status.containerStatuses[*]}{.ready}{"~"}{.restartCount}{"~"}{.imageID}{" "}{end}{"\n"}{end}' 2>/dev/null; }
pj_ing_auth() { $K get ingress -o jsonpath='{range .items[*].spec.rules[*].http.paths[*]}{.backend.service.name}{"\n"}{end}' 2>/dev/null | grep -c 'auth-service'; }
pj_not_ready() { pj_lines "$1" | awk '{split($0,p,"|"); split(p[1],h," "); if (h[2]=="Succeeded" || (EXC!="" && h[2]==EXC)) next; if (NODEL && length(h)>=3) next; n=split(p[2],c," "); for(i=1;i<=n;i++){split(c[i],a,"~"); if(a[1]=="false"){k++; break}}} END{print k+0}' EXC="${2:-}" NODEL="${3:-}"; }
pj_restart_pods() { pj_lines "$1" | awk '{split($0,p,"|"); n=split(p[2],c," "); for(i=1;i<=n;i++){split(c[i],a,"~"); if(a[2]+0>0){k++; break}}} END{print k+0}'; }
pj_restart_sum() { pj_lines "$1" | awk '{split($0,p,"|"); split(p[1],h," "); if (length(h)>=3) next; n=split(p[2],c," "); for(i=1;i<=n;i++){split(c[i],a,"~"); s+=a[2]}} END{print s+0}'; }
pj_digests() { pj_lines "$1" | awk '{split($0,p,"|"); split(p[1],h," "); if (length(h)>=3) next; n=split(p[2],c," "); for(i=1;i<=n;i++){split(c[i],a,"~"); print a[3]}}' | grep -E "${2:-.}" | sed 's/.*@sha256://' | cut -c1-12 | sort -u | paste -sd, -; }
# image steps: the pod selectors to check = the Deployments of the step (IMG_DEPLOYS, derived by g0-vars from IMGROWS-<n>.txt): dev-health-ops-go-<group> -> dev-health.io/worker-group=<group>; dev-health-ops-<name> -> app.kubernetes.io/component=<name>. none or unset = every worker group. Any other name prints nothing and returns 1.
img_groups() { local all="heavy ops sync sync-provider scheduler reconciler stream-ingest stream-external stream-pagerduty" d g w out=""
  case "${IMG_DEPLOYS:-}" in ""|none) for g in $all; do out="$out dev-health.io/worker-group=$g"; done; echo $out; return 0;; esac
  for d in ${IMG_DEPLOYS//,/ }; do g=""; for w in $all; do [ "$d" = "dev-health-ops-go-$w" ] && g=$w; done   # a worker group ONLY when d is dev-health-ops-go-<one of $all> exactly: go-api (and any other dev-health-ops-go-* name) is not a worker group
    if [ -n "$g" ]; then out="$out dev-health.io/worker-group=$g"; continue; fi
    case "$d" in dev-health-ops-[a-z]*) out="$out app.kubernetes.io/component=${d#dev-health-ops-}";;
    [a-z]*) case "$d" in *[!a-z0-9-]*) return 1;; esac; g=$($K get deploy "$d" -o jsonpath='{.spec.selector.matchLabels}' 2>/dev/null | jq -r 'to_entries|sort_by(.key)|map("\(.key)=\(.value)")|join(",")' 2>/dev/null); case "$g" in ""|*[!A-Za-z0-9./_=,-]*) return 1;; esac; out="$out $g";;   # any other Deployment (e.g. a #CMROLL config roll): its LIVE selector matchLabels
    *) return 1;; esac; done; echo $out; }
# v3h (CHAOS-11743, pm ruling A): the per-group digest map of the 9 worker groups, img_groups order: <g>:<12-hex prefixes joined by +> or <g>:- (no pod); Terminating pods skipped (pj_digests)
group_map() { local g d out=""; for g in heavy ops sync sync-provider scheduler reconciler stream-ingest stream-external stream-pagerduty; do d=$(pj_digests "dev-health.io/worker-group=$g" | tr , +); out="$out${out:+,}$g:${d:--}"; done; printf '%s\n' "$out"; }
# CMDELTA = "<ConfigMap/name> <key> <base64 of the exact -/+ lines>" (g0-vars, from #CMDELTA): cmdelta_check new|old reads that ONE live data key; new = every + line present and every - line absent (whole-line match), old = the reverse. Prints counts only, never the content.
cmdelta_check() { local o k b n c l t h want ok=0 bad=0; read -r o k b _ <<< "${CMDELTA:-}"; n=${o#ConfigMap/}
  case "$o|$1" in ConfigMap/?*"|new"|ConfigMap/?*"|old") ;; *) echo "CMDELTA STOP: CMDELTA is not '<ConfigMap/name> <key> <lines>' or the mode is not new|old"; return 2;; esac
  case "$n" in *[!a-z0-9-]*) echo "CMDELTA STOP: bad ConfigMap name"; return 2;; esac; case "$k" in ""|*[!A-Za-z0-9._-]*) echo "CMDELTA STOP: bad key"; return 2;; esac
  c=$($K get cm "$n" -o jsonpath="{.data.${k//./\\.}}") || { echo "CMDELTA STOP: the read of ConfigMap $n failed"; return 1; }; [ -n "$c" ] || { echo "CMDELTA STOP: ConfigMap $n key $k is empty"; return 1; }
  while IFS= read -r l || [ -n "$l" ]; do [ -n "$l" ] || continue; t=${l:1}; case "${l:0:1}$1" in +new|-old) want=1;; -new|+old) want=0;; *) echo "CMDELTA STOP: a line does not start with - or +"; return 2;; esac
    h=$(printf '%s\n' "$c" | grep -cFx -- "$t"); if { [ $want = 1 ] && [ "$h" -ge 1 ]; } || { [ $want = 0 ] && [ "$h" = 0 ]; }; then ok=$((ok+1)); else bad=$((bad+1)); echo "CMDELTA FAIL line $((ok+bad)) (${l:0:1}): $([ $want = 1 ] && echo 'absent, want present' || echo 'present, want absent')"; fi
  done < <(printf '%s' "$b" | base64 -d 2>/dev/null)
  [ $((ok+bad)) -gt 0 ] || { echo "CMDELTA STOP: no delta line decoded"; return 2; }
  echo "CMDELTA $1 $o $k: $ok lines ok, $bad wrong"; [ $bad = 0 ]; }
R=${R:-24d}; C=$D/deploy-roll-$R; RB=$D/deploy-rollback-$R
# LOOPGUARD fork functions (CHAOS-11564): REPORT ONLY, never kills.
lg_alive() { s=$(ps -p "$1" -o stat= 2>/dev/null) && [ -n "$s" ] && case "$s" in Z*) false;; *) true;; esac; }
# fork records (ROLL deploy/rollback): REPORT ONLY, never kills. $1 = pid file, $2 = pid. Identity = pid + process start time.
# NEXT-KIT 2: at a start, rotate an old $LOG.done away and stamp $LOG.start; `wait` accepts a .done only if it is newer than .start.
lg_rotate_done() { [ -e "$1.done" ] && mv -f "$1.done" "$1.done.old-$(date +%s)"; : > "$1.start"; }
lg_fork_rec() { echo "$2 $(ps -p "$2" -o lstart= | tr ' ' '_')" > "$1"; }
lg_fork_report() { [ -e "$1" ] || { echo "fork $1: no record"; return 0; }; read -r p t < "$1"
  if ! lg_alive "$p"; then echo "fork pid $p: gone (ended)"; return 0; fi
  [ "$(ps -p "$p" -o lstart= | tr ' ' '_')" = "$t" ] && echo "fork pid $p: STILL RUNNING (not killed)" || echo "fork pid $p: pid reused by another process (not ours, not killed)"; }
VALS="--values values.kiac.yaml --values values.prod.yaml --values $HOME/.config/dev-health/values.prod-secrets.yaml"
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0='*'
okhelm() { helm template dev-health chart --namespace $NS $( [ -e $D/roll-24d-values.yaml ] && echo "-f $D/roll-24d-values.yaml" ) -f values.kiac.yaml -f values.prod.yaml -f $HOME/.config/dev-health/values.prod-secrets.yaml "$@" >/dev/null 2>&1 && echo "PASS helm template rc 0" || { echo "FAIL helm template"; return 1; }; }
P4994=cb0d67a40481ba7eb2f82c4f4a9ed8bbd4fc6939
# guardvalues: the roll trees must still carry the pooler/auth values that R0 (24c) already holds: the 3 poolers rollingUpdate {maxSurge 0, maxUnavailable 1} and ops.authService.database.connectionBudget 97 in $C/values.prod.yaml
# guardheadroom <stage> (roll 24d, D6412, acp Q1=ii): the TWO-STEP split, the APP step FIRST, is enforced on the prod tree: stage `app` (TIP_APP) must carry every app request at its NEW value, the pooler 30m (ruling A), the collector perPod scrape true, and the postgresql request NOT set (old 100m); stage `ds` (TIP, the DS commit on TIP_APP) must carry all of that AND postgresql 400m.
guardheadroom() { python3 -I -c '
import sys, yaml
stage = sys.argv[2]
d = yaml.safe_load(open(sys.argv[1])) or {}
ops = d.get("ops") or {}
def cpu(o): return (((o or {}).get("resources") or {}).get("requests") or {}).get("cpu")
grp = {g["name"]: g for g in (((ops.get("goWorkers") or {}).get("groups")) or [])}
new = {"collector perPod scrape": ("True", str(((d.get("otelCollector") or {}).get("authServiceScrape") or {}).get("perPod"))), "pgbouncer (shared key, ruling A)": ("30m", cpu((ops.get("goWorkers") or {}).get("pgbouncer"))), "postgresql": ("400m", cpu(ops.get("postgresql"))), "authService": ("50m", cpu(ops.get("authService"))), "queryApi": ("25m", cpu(ops.get("queryApi"))), "otelCollector": ("50m", cpu(d.get("otelCollector")))}
old = {"collector perPod scrape": None, "pgbouncer (shared key, ruling A)": None, "authService": None, "queryApi": "100m", "otelCollector": None}
for n, v in (("ops", "50m"), ("sync", "50m"), ("sync-provider", "75m"), ("scheduler", "25m"), ("reconciler", "30m"), ("stream-ingest", "25m"), ("stream-external", "25m"), ("stream-pagerduty", "25m")):
    new["group " + n] = (v, cpu(grp.get(n))); old["group " + n] = {"ops": "100m", "sync": "100m", "sync-provider": "100m", "scheduler": "100m", "reconciler": "100m"}.get(n, "50m")
bad = []
STEP = {"collector perPod scrape": 1, "otelCollector": 1, "queryApi": 2, "authService": 3, "pgbouncer (shared key, ruling A)": 4, "postgresql": 6}
old["postgresql"] = None
import os
DEFER = set(x for x in os.environ.get("DEFER_STEPS", "").split(",") if x)   # deferred steps (acp): their services stay at the OLD value in every stage
import os
N = {"app": 5, "ds": 6}.get(stage) or (int(os.environ.get("GUARD_LIVE_STEP") or "5") if len(stage) >= 2 and stage[0] == "i" and stage[1:].isdigit() else 0) or (int(stage[1:]) if len(stage) == 2 and stage[0] == "s" and stage[1] in "123456" else 0)
if N == 0: print("GUARDHEADROOM FAIL: unknown stage %s (app|ds|s1..s6)" % stage); sys.exit(1)
for k, (want, have) in new.items():
    st = 5 if k.startswith("group ") else STEP[k]
    exp = want if (st <= N and str(st) not in DEFER) else old.get(k)
    if str(have) != str(exp) and not (exp is None and have is None): bad.append("%s: %s (want %s)" % (k, have, exp))
if bad: print("GUARDHEADROOM FAIL (stage %s): %s: STOP (stage %s: the services of steps 1..%d at their NEW value, the rest at the OLD value)" % (stage, "; ".join(bad), stage, N)); sys.exit(1)
print("GUARDHEADROOM PASS (stage %s): the services of steps 1..%d at their NEW value, the others at the OLD value (postgresql %s)" % (stage, N, "400m" if N == 6 else "NOT yet raised"))' "$C/values.prod.yaml" "${1:-ds}"; }
guardvalues() { python3 -I -c '
import sys, yaml
d = yaml.safe_load(open(sys.argv[1])) or {}
ops = d.get("ops") or {}
pg = ((ops.get("goWorkers") or {}).get("pgbouncer")) or {}
want = {"maxSurge": 0, "maxUnavailable": 1}
bad = [n for n in ("transaction", "queueSession", "coordinatorSession") if (pg.get(n) or {}).get("rollingUpdate") != want]
cb = (((ops.get("authService") or {}).get("database")) or {}).get("connectionBudget")
if bad or cb != 97:
    print("GUARDVALUES FAIL: the CHAOS-11546 values are not in TIP (poolers missing/wrong: %s; connectionBudget %s): STOP, the roll TIP is the head AFTER the values commit" % (",".join(bad) or "-", cb)); sys.exit(1)
print("GUARDVALUES PASS: 3 poolers {maxSurge 0, maxUnavailable 1} + connectionBudget 97 in TIP")' "$C/values.prod.yaml"; }
guard4994() { # v0.9 both-ways guard: PASS only if (#4994 merge commit is an ancestor of the vendored CUT AND ops.authService.phase is set in values.prod.yaml) OR (#4994 absent AND phase absent)
  local in=0 ph; git -C "$C/vendor/dev-health-ops" merge-base --is-ancestor "$P4994" HEAD 2>/dev/null && in=1
  ph=$(python3 -I -c 'import sys,yaml; print((((yaml.safe_load(open(sys.argv[1])).get("ops") or {}).get("authService") or {}).get("phase","ABSENT")))' "$C/values.prod.yaml" 2>/dev/null) || ph=ERR
  if [ "$ph" != ERR ] && { { [ $in = 1 ] && [ "$ph" != ABSENT ]; } || { [ $in = 0 ] && [ "$ph" = ABSENT ]; }; }; then echo "GUARD4994 PASS: #4994 in cut=$in authService.phase=$ph"; return 0; fi
  echo "GUARD4994 FAIL: #4994 in cut=$in authService.phase=$ph (need both or neither; ERR = values file unreadable). STOP, report to main."; return 1
}
mkrv() { # roll-time values file from HOOK (A = streak-index hook ON: the configuration live since 24c, kept; unset = no hook, not accepted)
  RV=$D/roll-24d-values.yaml; RVARG=""; rm -f "$RV"
  case "${HOOK:-}" in
    A) ( umask 077; printf '%s\n' "# roll 24d roll-time values (option A: needs the chart fix): streak-index hook ON." "ops:" "  migrations:" "    hook:" "      streakIndex:" "        enabled: true" > "$RV" ) ;;
    "") : ;;
    *) echo "HOOK must be A or unset: STOP"; return 2 ;;
  esac
  [ -e "$RV" ] && RVARG="--values $RV"; return 0
}
hookguard() { # the streak-index hook stays ON (as live since 24c). Refuse unless the roll tree render with the roll-time values file contains the streak-index hook Job.
  if [ -z "$RVARG" ] || ! ( cd "$C" && helm dependency build chart >/dev/null 2>&1; helm template dev-health chart --namespace $NS -f values.kiac.yaml -f values.prod.yaml -f $HOME/.config/dev-health/values.prod-secrets.yaml -f "$RV" 2>/dev/null ) | grep -q 'name: dev-health-ops-streak-index'; then
    echo "REFUSED: the rendered release has no streak-index hook Job (migrations.hook.streakIndex.enabled=true not in effect). A roll with the flag off is NOT the accepted configuration for CHAOS-11427 and needs a new acp ruling. STOP, report to main."; rm -f "$RV"; return 5
  fi
  echo "HOOKGUARD PASS: streak-index hook Job renders"; return 0
}
groups_fn() { # per worker-group deployment: ready/desired, image digest(12), restarts, KEDA ScaledObject present. Names + numbers only.
  for d in $($K get deploy -o name | grep -E 'go-(heavy|ops|sync|sync-provider|scheduler|reconciler|stream-ingest|stream-external|stream-pagerduty)$'); do n=${d#deployment.apps/}
    echo "$n ready=$($K get $d -o jsonpath='{.status.readyReplicas}')/$($K get $d -o jsonpath='{.spec.replicas}') img=$(pj_digests "dev-health.io/worker-group=${n#dev-health-ops-go-}" operator) restarts=$(pj_restart_sum "dev-health.io/worker-group=${n#dev-health-ops-go-}")"; done
  echo "KEDA ScaledObjects: $($K get scaledobject -o name 2>/dev/null | tr '\n' ' ')"
  echo "web ready=$($K get deploy dev-health-ops-web -o jsonpath='{.status.readyReplicas}')/$($K get deploy dev-health-ops-web -o jsonpath='{.spec.replicas}') img=$(pj_digests "app.kubernetes.io/component=web") restarts=$(pj_restart_sum "app.kubernetes.io/component=web")"
}
# ---- DS-step recovery helpers (acp NB-2 ruling): read-only diagnostics + the named query-api scale-down
PGPOD=dev-health-ops-postgresql-0; QAPI=dev-health-ops-query-api
nodefree() { # node FREE (requests): allocatable CPU of the nodes minus the CPU requests of the non-terminal pods, in m (a number); exit 1 on a failed read
  a=$( set -o pipefail; $K get nodes -o jsonpath='{range .items[*]}{.status.allocatable.cpu}{"\n"}{end}' | awk '{v=$1; if (v ~ /m$/) {sub(/m$/,"",v); s+=v} else s+=v*1000} END{print s+0}' ) || return 1
  u=$( set -o pipefail; kubectl get pods -A -o jsonpath='{range .items[*]}{.status.phase}{" "}{range .spec.containers[*]}{.resources.requests.cpu}{","}{end}{"\n"}{end}' | awk '$1!="Succeeded" && $1!="Failed" {n=split($2,a,","); for(i=1;i<=n;i++){v=a[i]; if(v=="") continue; if (v ~ /m$/) {sub(/m$/,"",v); s+=v} else s+=v*1000}} END{print s+0}' ) || return 1
  echo $(( a - u )); }
dsdiag() { # the report at a STOP of the DS watch: pod phase, the events tail of the pod and of the sts, node FREE (requests). Read-only; names, reasons and numbers only.
  echo "DSDIAG pod $PGPOD phase: $($K get pod $PGPOD -o jsonpath='{.status.phase}' 2>/dev/null) ready: $($K get pod $PGPOD -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null)"
  for o in "$PGPOD" dev-health-ops-postgresql; do echo "DSDIAG events tail for $o:"; $K get events --field-selector involvedObject.name=$o -o jsonpath='{range .items[*]}{.lastTimestamp}{" "}{.type}{" "}{.reason}{" "}{.message}{"\n"}{end}' 2>/dev/null | tail -5 | cut -c1-200 | sed 's/^/   /'; done
  echo "DSDIAG node FREE (requests): $(nodefree 2>/dev/null || echo unreadable) m"; }
qapi_ready() { [ "$($K get deploy $QAPI -o jsonpath='{.status.readyReplicas}' 2>/dev/null)" = 2 ]; }
qapi_restore() { # EVERY exit path of the recovery runs this: scale query-api back to 2 and gate on its Ready
  $K scale deploy $QAPI --replicas=2 >/dev/null 2>&1 || { echo "RESTORE FAILED: scale query-api to 2 failed: STOP (the query API is DOWN: report to main at once)"; return 1; }
  end=$(( $(date +%s) + ${QAPI_WAIT:-300} )); while ! qapi_ready && [ "$(date +%s)" -lt "$end" ]; do sleep ${QAPI_STEP:-5}; done
  qapi_ready && { echo "RESTORE OK: query-api back at 2 replicas, Ready"; return 0; }
  echo "RESTORE FAILED: query-api is not Ready (2) after ${QAPI_WAIT:-300}s: STOP (the query API is DOWN: report to main at once)"; return 1; }
case "${1:-}" in
pre) # read-only baseline
  # v1.1: after a FAILED upgrade (the newest revision failed, the previous one still deployed) `helm list` shows the newest revision: report BOTH the live (last deployed) revision and the newest one
  echo "helm live (last deployed) rev: $(helm history dev-health -n $NS -o json | jq -r '[.[]|select(.status=="deployed")]|last|.revision // "none"')  newest rev: $(helm history dev-health -n $NS -o json | jq -r 'last|"\(.revision) status \(.status)"')"
  echo "pods not Ready (Running/Pending only; Succeeded and Failed hook pods are not workloads): $(pj_not_ready "" Failed)"
  echo "kept Failed pods (names, e.g. a failed hook Job's pod): $(pj_lines | awk '$2=="Failed"{printf "%s ",$1}')"
  echo "restarts>0: $(pj_restart_pods "")"
  echo "authService.enabled: $(helm get values dev-health -n $NS -a -o json | jq -c '[.authService.enabled, .ops.authService.enabled]')"
  echo "auth-service image: $($K get deploy dev-health-ops-auth-service -o jsonpath='{.spec.template.spec.containers[0].image}' | sed 's/.*@sha256://' | cut -c1-12)  ingress paths to auth-service: $(pj_ing_auth)"
  groups_fn ;;
groups) groups_fn ;;
groupdigests) # v3h read-only: `STATE GROUPDIG=<map>` (group_map); exit 1 when no worker pod is read at all
  gm=$(group_map); case "$gm" in *[!a-z0-9:,+-]*|"") echo "groupdigests: bad map: STOP"; exit 1;; esac
  [ "$(printf '%s\n' "$gm" | tr , '\n' | grep -vc ':-$')" -gt 0 ] || { echo "groupdigests: no worker pod read: STOP"; exit 1; }
  printf '%s\n' "$gm" | tr , '\n' | sed 's/^/GROUPDIG-ROW /'; echo "STATE GROUPDIG=$gm" ;;
drain) # $2 = group name (e.g. heavy). Pods of the group incl. Terminating. Heavy grace = 7260 s: poll with a Monitor until count 0 (D6169), never a foreground wait.
  echo "$2 pods: total $($K get pods -l dev-health.io/worker-group=$2 --no-headers 2>/dev/null | wc -l)  terminating $($K get pods -l dev-health.io/worker-group=$2 --no-headers 2>/dev/null | grep -c Terminating)  deploy spec.replicas $($K get deploy dev-health-ops-go-$2 -o jsonpath='{.spec.replicas}')" ;;
prep) # $2 = the roll tree sha (TIP_APP) for the roll checkout ; $3 = RB = the deploy sha the live release runs (R0) for the rollback checkout. v1.1: prep never moves an existing tree: an existing dir whose HEAD is not the wanted sha = EXISTS-STALE rc 4 (use `refresh $TIP $RB` on a re-attempt)
  for pair in "$C $2" "$RB $3"; do set -- $pair; d=$1; s=$2
    if [ -e $d ]; then h=$(git -C $d rev-parse HEAD 2>/dev/null); if [ "$h" = "$s" ]; then echo "exists $d HEAD=$h (matches)"; else echo "EXISTS-STALE $d HEAD=${h:-none} != wanted $s: prep does not move an existing tree; use the refresh phase (R=$R bash -s -- refresh <TIP> <RB>), then re-run prep for the HEAD check: STOP"; exit 4; fi; continue; fi
    git clone -q https://github.com/full-chaos/dev-health-deploy.git $d && git -C $d checkout -q --detach "$s" && git -C $d submodule update -q --init || { echo FAIL clone $d; exit 1; }
    [ "$(git -C $d rev-parse HEAD)" = "$s" ] && echo "PASS $d @ $s" || { echo "FAIL sha $d"; exit 1; }
    vp=$(cd $d && bash scripts/run-verify-pins.sh values.prod.yaml 2>&1); vrc=$?; echo "$vp" | tail -1; [ "$vrc" = 0 ] || { echo "FAIL verify_pins $d (rc $vrc)"; exit 1; }
    (cd $d && helm dependency build chart >/dev/null 2>&1 && okhelm) || { echo "FAIL helm template $d"; exit 1; }
  done ;;
refresh) # $2 = roll-tree sha ; $3 = rollback-tree sha. Move both fresh checkouts (no deploy) AND run verify_pins + helm template on each (exit 1 on any FAIL; prep does not re-run them on an existing dir). Use for a new pin tip.
  for pair in "$C $2" "$RB $3"; do set -- $pair; d=$1; s=$2
    git -C $d fetch -q origin "+refs/heads/*:refs/remotes/origin/*" && git -C $d checkout -q --detach "$s" && git -C $d submodule update -q --init || { echo FAIL $d; exit 1; }
    [ "$(git -C $d rev-parse HEAD)" = "$s" ] && echo "PASS $d @ $s" || { echo "FAIL sha $d"; exit 1; }
    echo "gitlinks: acr $(git -C $d ls-tree HEAD vendor/dev-health-acr | awk '{print $3}' | cut -c1-8) ops $(git -C $d ls-tree HEAD vendor/dev-health-ops | awk '{print $3}' | cut -c1-8)"
    vp=$(cd $d && bash scripts/run-verify-pins.sh values.prod.yaml 2>&1); vrc=$?; echo "$vp" | tail -1; [ "$vrc" = 0 ] || { echo "FAIL verify_pins $d (rc $vrc)"; exit 1; }
    (cd $d && helm dependency build chart >/dev/null 2>&1 && okhelm) || { echo "FAIL helm template $d"; exit 1; }
  done ;;
deploy) # $2 = stage name (app = the APP step FIRST on TIP_APP, then ds = the data-store step ALONE on TIP) ; $3 = that stage's commit sha. ONE helm upgrade; returns at once; end marker = $LOG.done
  git -C $C checkout -q --detach "$3" && git -C $C submodule update -q --init && [ "$(git -C $C rev-parse HEAD)" = "$3" ] || { echo FAIL checkout; exit 1; }
  guard4994 || exit 6
  guardvalues || exit 8
  guardheadroom "$2" || exit 9
  mkrv || exit 2
  hookguard || exit 5
  LOG=$D/roll-$R-$2.out; lg_rotate_done "$LOG"; echo "ROLL $2 START $(date -u +%FT%TZ) HEAD $(git -C $C rev-parse --short HEAD)"
  ( trap '' HUP; cd "$C" && ./dev-health --context default --namespace dev-health --yes --timeout 90m $VALS $RVARG deploy > "$LOG" 2>&1; echo "deploy_rc=$?" >> "$LOG"; touch "$LOG.done" ) </dev/null >/dev/null 2>&1 &
  lg_fork_rec "$LOG.pid" $!; echo "pid $! log $LOG" ;;
mkrv) # v1.0: write the roll-time values file ONLY (HOOK=A), print its sha256 and check it against the pinned content sha (rc 3 + file removed on a mismatch); no checkout, no render
  [ "${HOOK:-}" = A ] || { echo "mkrv needs HOOK=A: STOP (usage error, nothing written)"; exit 2; }
  mkrv || exit 2
  s=$(sha256sum "$RV" | cut -d' ' -f1); echo "MKRV: $RV sha256 $s"
  if [ "$s" = 16d9461148e4cad2a2195f09bcaee39c0035ad5d4a1a5484a0d4c3d4c8161936 ]; then echo "MKRV SHA CHECK: PASS"; else echo "MKRV SHA CHECK: FAIL (expected 16d946114 8c...): file removed"; rm -f "$RV"; exit 3; fi ;;
guards) # $2 = tree sha, $3 = stage (app|ds, default ds): checkout + the render/values guards; NO deploy, no helm upgrade (Gate 0 read)
  git -C $C checkout -q --detach "$2" && git -C $C submodule update -q --init && [ "$(git -C $C rev-parse HEAD)" = "$2" ] || { echo FAIL checkout; exit 1; }
  guard4994 || exit 6
  guardvalues || exit 8
  guardheadroom "${3:-ds}" || exit 9
  mkrv || exit 2
  hookguard; exit $? ;; # v1.0: the flag-only values file is kept (mkrv/L2 use it; hookguard removes it itself on a refusal)
helm-rollback) # $2 = app (undo the app step: target LIVEREV) | ds (undo only the data-store step: target LIVEREV2); LIVEREV / LIVEREV2 come from the env (the kit's state file, sourced by g0-vars) and must be NUMBERS. Refused (exit 6) only while helm itself is locked (the newest helm history status is pending-*) or a helm-rollback fork of this kit is still alive; a still-running deploy fork whose helm upgrade has returned does NOT block it. Returns at once; end marker = $LOG.done
  case "${2:-}" in app) tgt=${LIVEREV:-};; ds) tgt=${LIVEREV2:-};; *) echo "helm-rollback needs app|ds: STOP (usage)"; exit 2;; esac
  case "$tgt" in ""|*[!0-9]*) echo "helm-rollback $2: the target revision ($([ "$2" = app ] && echo LIVEREV || echo LIVEREV2)='${tgt}') is not a number: STOP (the state file has no value: run the read-only verb that writes it first)"; exit 2;; esac
  hs=$(helm history dev-health -n $NS -o json | jq -r 'last|.status') || { echo "helm-rollback REFUSED: helm history failed: STOP"; exit 1; }
  case "$hs" in pending-*) echo "helm-rollback REFUSED: helm is locked (newest revision status $hs): another helm operation is in progress; wait for it (wait app|ds), then retry: STOP"; exit 6;; esac
  if lg_fork_report "$D/roll-$R-helm-rollback.out.pid" 2>/dev/null | grep -q 'STILL RUNNING'; then echo "helm-rollback REFUSED: a helm-rollback fork of this kit is still running (never start a second one): run \`wait helm-rollback\`: STOP"; exit 6; fi
  LOG=$D/roll-$R-helm-rollback.out; lg_rotate_done "$LOG"; echo "HELM ROLLBACK START $(date -u +%FT%TZ) $2 to $tgt"
  ( trap '' HUP; helm rollback dev-health "$tgt" -n $NS --wait --timeout 15m > "$LOG" 2>&1; echo "deploy_rc=$?" >> "$LOG"; touch "$LOG.done" ) </dev/null >/dev/null 2>&1 &
  lg_fork_rec "$LOG.pid" $!; echo "pid $! log $LOG" ;;
rollcheck) # $2 = app (the app step was undone: target = LIVEREV) | ds (only the data-store step was undone: target = LIVEREV2); the target number comes from the env (state file). Run after `wait helm-rollback` printed deploy_rc=0. Read-only, every read fails CLOSED. Exit 0 only when: the newest helm revision is a deployed "Rollback to <target>", every Deployment of release dev-health is Ready, postgresql-0 is Ready, the collector ConfigMap is back to the static scrape (app) / still per-pod (ds), and the CPU requests are back at the OLD values (ds: postgresql 100m only; app: ALL the app requests and postgresql at the old values).
  kind=${2:-}; case "$kind" in app|s[1-5]|i[0-9]|i[0-9][0-9]) tgt=${LIVEREV:-};; ds|s6) tgt=${LIVEREV2:-};; *) echo "rollcheck needs app|ds|s1..s6|i<img step>: STOP (usage)"; exit 2;; esac; case "$tgt" in ""|*[!0-9]*) echo "rollcheck $kind: the target revision ('$tgt') is not a number: STOP (usage)"; exit 2;; esac
  stopn=0; stp() { echo "$1"; stopn=$((stopn+1)); }
  nw=$(helm history dev-health -n $NS -o json | jq -r 'last|"\(.revision) \(.status) \(.description)"') || { echo "ROLLCHECK STOP: helm history failed"; exit 1; }; echo "ROLLCHECK newest helm revision: $nw"
  case "$nw" in *" deployed Rollback to $tgt") ;; *) stp "ROLLCHECK: the newest revision is not a deployed \"Rollback to $tgt\"";; esac
  cmt=$($K get cm dev-health-otel-collector -o jsonpath='{.data.config\.yaml}') || { echo "ROLLCHECK STOP: the collector ConfigMap read failed"; exit 1; }; [ -n "$cmt" ] || { echo "ROLLCHECK STOP: the collector ConfigMap is empty"; exit 1; }
  cm=$(printf '%s\n' "$cmt" | grep -c kubernetes_sd_configs)
  if [ "$kind" = app ] || [ "$kind" = s1 ]; then [ "$cm" = 0 ] || stp "ROLLCHECK: the collector ConfigMap still has the per-pod scrape (kubernetes_sd_configs); the app step is not undone"; else [ "$cm" -ge 1 ] || stp "ROLLCHECK: the collector ConfigMap lost the per-pod scrape (the app step must stay)"; fi
  dl=$($K get deploy -l app.kubernetes.io/instance=dev-health -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.replicas}{" "}{.status.readyReplicas}{"\n"}{end}') || { echo "ROLLCHECK STOP: the Deployment read failed"; exit 1; }; [ -n "$dl" ] || { echo "ROLLCHECK STOP: no Deployment of release dev-health read"; exit 1; }
  bad=$(printf '%s\n' "$dl" | awk '$2>0 && $2!=$3 {k=k" "$1} END{print k}'); [ -z "$bad" ] || stp "ROLLCHECK: Deployments not Ready:$bad"
  pgr=$($K get pod dev-health-ops-postgresql-0 -o jsonpath='{.status.containerStatuses[0].ready}') || { echo "ROLLCHECK STOP: the postgresql-0 read failed"; exit 1; }; [ "$pgr" = true ] || stp "ROLLCHECK: postgresql-0 not Ready"
  chkreq() { v=$($K get $1 $2 -o jsonpath='{.spec.template.spec.containers[0].resources.requests.cpu}') || { echo "ROLLCHECK STOP: read of $1/$2 failed"; exit 1; }; [ "$v" = "$3" ] && echo "ROLLCHECK $2 request $v (ok)" || stp "ROLLCHECK: $1/$2 request '$v' want $3"; }
  case "$kind" in i[0-9]|i[0-9][0-9]) [ "${GUARD_LIVE_STEP:-5}" -ge 6 ] 2>/dev/null && pgw=400m || pgw=100m;; *) pgw=100m;; esac; chkreq sts dev-health-ops-postgresql $pgw   # image steps on a live state with the data-store step (6) rolled (GUARD_LIVE_STEP >= 6): postgresql stays at its NEW 400m
  # per-service rolls (D6415): after undoing step N the services of steps >= N are back at the OLD value and the services of earlier steps stay at the NEW value; app = all of steps 1-5 undone, ds = only step 6 undone
  case "$kind" in app) N=1;; ds) N=7;; i[0-9]|i[0-9][0-9]) N=$(( ${GUARD_LIVE_STEP:-5} + 1 ));; s[1-6]) N=${kind#s};; esac   # image steps: every 24d value at its live value (steps 1..GUARD_LIVE_STEP new except the deferred step, later steps old)
  for w in "otel-collector dev-health-otel-collector 100m 50m 1" "query-api dev-health-ops-query-api 100m 25m 2" "auth-service dev-health-ops-auth-service 250m 50m 3" "pgbouncer-transaction dev-health-ops-go-pgbouncer-transaction 50m 30m 4" "pgbouncer-queue-session dev-health-ops-go-pgbouncer-queue-session 50m 30m 4" "pgbouncer-coordinator-session dev-health-ops-go-pgbouncer-coordinator-session 50m 30m 4" "go-ops dev-health-ops-go-ops 100m 50m 5" "go-sync dev-health-ops-go-sync 100m 50m 5" "go-sync-provider dev-health-ops-go-sync-provider 100m 75m 5" "go-scheduler dev-health-ops-go-scheduler 100m 25m 5" "go-reconciler dev-health-ops-go-reconciler 100m 30m 5" "go-stream-ingest dev-health-ops-go-stream-ingest 50m 25m 5" "go-stream-external dev-health-ops-go-stream-external 50m 25m 5" "go-stream-pagerduty dev-health-ops-go-stream-pagerduty 50m 25m 5"; do set -- $w; dfr=no; case ",${DEFER_STEPS:-}," in *",$5,"*) dfr=yes;; esac; if [ "$5" -ge "$N" ] || [ "$dfr" = yes ]; then chkreq deploy $2 $3; else chkreq deploy $2 $4; fi; done
  # image steps: ROLLBACK_IMG_PREFIX = the digest prefix the worker pods must run again after the rollback (IMG_MODE=rolls: the OLD prefix; a norolls step has no pod image change: skipped when unset)
  if [ -n "${ROLLBACK_IMG_PREFIX:-}" ]; then case "$ROLLBACK_IMG_PREFIX" in *[!0-9a-f]*|"") stp "ROLLCHECK: ROLLBACK_IMG_PREFIX is not a hex prefix";; *) wd=$(for g in $(img_groups); do pj_digests "$g"; done | sort -u | paste -sd, -); [ "$wd" = "$ROLLBACK_IMG_PREFIX" ] && echo "ROLLCHECK worker image digests $wd (ok)" || stp "ROLLCHECK: worker image digests '$wd' want '$ROLLBACK_IMG_PREFIX'";; esac; fi
  if [ -n "${CMDELTA:-}" ]; then cmdelta_check old || stp "ROLLCHECK: the CMDELTA ConfigMap lines are not back at the old state"; fi   # a #CMDELTA step: the live ConfigMap holds the - lines again and none of the + lines
  if [ "$stopn" != 0 ]; then echo "ROLLCHECK: STOP ($stopn problem(s))"; exit 1; fi; echo "ROLLCHECK: PASS ($kind step undone: requests back at the old values, everything Ready)" ;;
hookscheck) # BEFORE the DS step (after the app step: LIVEREV2 exists), read-only: record the hook NAMES, kinds and events of helm revision LIVEREV2 (no manifests, no values) and prove that every hook a `helm rollback --no-hooks` would skip is the river-migrate migration Job (24d changes no schema, so skipping it is harmless); any OTHER hook with a pre-/post-rollback event = STOP (exit 1). Env: LIVEREV2 (a number).
  case "${LIVEREV2:-}" in ""|*[!0-9]*) echo "hookscheck needs LIVEREV2 (a number, from the state file): STOP, usage error"; exit 2;; esac
  hk=$( set -o pipefail; helm get hooks dev-health --revision "$LIVEREV2" -n $NS ) || { echo "HOOKSCHECK STOP: helm get hooks failed"; exit 1; }
  printf '%s\n' "$hk" | python3 -I -c '
import sys, yaml
rows = []
for d in yaml.safe_load_all(sys.stdin):
    if not isinstance(d, dict): continue
    ann = (d.get("metadata") or {}).get("annotations") or {}
    ev = ann.get("helm.sh/hook", "")
    if ev: rows.append((d.get("kind"), (d.get("metadata") or {}).get("name"), ev))
bad = []
for k, n, ev in sorted(rows, key=lambda r: str(r[1])):
    skipped = any(e.strip().endswith("rollback") for e in ev.split(","))
    print("HOOK %s %s [%s]%s" % (k, n, ev, "  <- skipped by --no-hooks" if skipped else ""))
    if skipped and "river-migrate" not in str(n): bad.append(n)
if not rows: print("HOOKSCHECK STOP: no hook listed (helm get hooks returned nothing)"); sys.exit(1)
if bad: print("HOOKSCHECK STOP: --no-hooks would skip a hook that is not the river-migrate migration: %s" % ", ".join(map(str, bad))); sys.exit(1)
print("HOOKSCHECK: PASS (%d hooks listed; every hook a --no-hooks rollback skips is river-migrate, no schema change in 24d)" % len(rows))
' ;;
dsrecover) # DS-step RECOVERY (acp NB-2 ruling; pm decides when to run it): (b) the named scale-down: query-api 2 -> 0 ONLY, re-read FREE and watch postgresql-0; (c) if it is still not Ready: `helm rollback dev-health $LIVEREV2 --no-hooks --wait` (STOP if it fails), then ONLY if postgresql-0 is Pending or not Ready: delete the POD postgresql-0 (nothing else is touched: no PVC, no StatefulSet object, no forced or zero-grace delete). USER EFFECT: the query API is DOWN from the scale-down until the restore. EVERY exit path (after (b), after (c), on any STOP) scales query-api back to 2 and gates on its Ready. After (b)/(c): postgresql-0 Ready gate, its cpu request read back (400m after (b); the LIVEREV2 value 100m after (c)), a read-only row count in BEGIN READ ONLY (the standing prod Postgres FORM: chris via pm 10-26, acp used it for the 11597 count), then app readiness (data store first, then the apps). Env: LIVEREV2 (a number). Exit 0 = recovered, 1 = STOP.
  case "${LIVEREV2:-}" in ""|*[!0-9]*) echo "dsrecover needs LIVEREV2 (a number, from the state file): STOP, usage error"; exit 2;; esac
  RC=0; trap 'qapi_restore || RC=1; exit $RC' EXIT
  stopr() { echo "DSRECOVER STOP: $1 (report to main: one report per stop)"; RC=1; exit 1; }
  pgstate() { $K get pod $PGPOD -o jsonpath='{.status.phase}{" "}{.status.containerStatuses[0].ready}' 2>/dev/null; }
  pgready() { [ "$($K get pod $PGPOD -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null)" = true ]; }
  waitpg() { end=$(( $(date +%s) + $1 )); while ! pgready && [ "$(date +%s)" -lt "$end" ]; do sleep ${RECOVER_STEP:-5}; done; pgready; }
  afterchecks() { # $1 = the cpu request postgresql-0 must carry
    waitpg ${RECOVER_PG_WAIT:-300} || stopr "postgresql-0 is not Ready after the recovery step"
    rq=$($K get pod $PGPOD -o jsonpath='{.spec.containers[0].resources.requests.cpu}' 2>/dev/null); echo "DSRECOVER postgresql-0 Ready; cpu request $rq (want $1)"; [ "$rq" = "$1" ] || stopr "postgresql-0 cpu request '$rq' is not $1"
    cnt=$(printf 'BEGIN READ ONLY;\nSELECT count(*) FROM pg_catalog.pg_class;\nROLLBACK;\n' | $K exec -i $PGPOD -- sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -X -q -v ON_ERROR_STOP=1 -h 127.0.0.1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -At' 2>/dev/null | tr -d '[:space:]') || stopr "the read-only row count failed"
    case "$cnt" in ""|*[!0-9]*) stopr "the read-only row count returned '$cnt'";; esac; echo "DSRECOVER read-only count (pg_class rows) = $cnt: the database answers"
    end=$(( $(date +%s) + ${RECOVER_APP_WAIT:-300} )); while :; do nr=$($K get deploy -l app.kubernetes.io/instance=dev-health -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.replicas}{" "}{.status.readyReplicas}{"\n"}{end}' | awk -v q=$QAPI '$1!=q && $2>0 && $2!=$3 {k=k" "$1} END{print (k==""?"none":k)}'); [ "$nr" = none ] && break; [ "$(date +%s)" -ge "$end" ] && stopr "apps not Ready after the data store: $nr"; sleep ${RECOVER_STEP:-5}; done
    echo "DSRECOVER apps Ready (data store first, then the apps; query-api is restored last by the exit path)"; }
  echo "DSRECOVER start: node FREE (requests) $(nodefree) m; postgresql-0 state: $(pgstate)"
  echo "DSRECOVER (b) USER EFFECT: the query API is DOWN until the restore at the end of this verb; scaling query-api 2 -> 0 (ONLY query-api)"
  $K scale deploy $QAPI --replicas=0 >/dev/null || stopr "scale of query-api to 0 failed"
  end=$(( $(date +%s) + ${RECOVER_QAPI_DOWN_WAIT:-120} )); while [ "$($K get deploy $QAPI -o jsonpath='{.status.replicas}' 2>/dev/null)" != "" ] && [ "$($K get deploy $QAPI -o jsonpath='{.status.replicas}' 2>/dev/null)" != 0 ] && [ "$(date +%s)" -lt "$end" ]; do sleep ${RECOVER_STEP:-5}; done
  echo "DSRECOVER (b) node FREE (requests) after the scale-down: $(nodefree) m"
  if waitpg ${RECOVER_B_WAIT:-180}; then echo "DSRECOVER (b) OK: postgresql-0 became Ready after the named scale-down"; afterchecks 400m; echo "DSRECOVER: PASS via (b)"; exit 0; fi
  echo "DSRECOVER (b) did not help (postgresql-0: $(pgstate)): going to (c)"
  helm rollback dev-health "$LIVEREV2" -n $NS --no-hooks --wait --timeout 15m || stopr "helm rollback $LIVEREV2 --no-hooks --wait failed"
  echo "DSRECOVER (c) helm rollback to $LIVEREV2 done (--no-hooks)"
  if ! pgready || [ "$($K get pod $PGPOD -o jsonpath='{.status.phase}' 2>/dev/null)" = Pending ]; then echo "DSRECOVER (c) postgresql-0 is Pending or not Ready: deleting the POD $PGPOD (nothing else)"; $K delete pod $PGPOD || stopr "delete of pod $PGPOD failed"; fi
  afterchecks 100m; echo "DSRECOVER: PASS via (c)"; exit 0 ;;
forks) # REPORT ONLY (CHAOS-11564): is a deploy/rollback fork still running? Never kills.
  for s in app ds helm-rollback; do echo "$s: $(lg_fork_report $D/roll-$R-$s.out.pid)"; done ;;
wait) # $2 = stage log name (app|ds|helm-rollback). D6217: ONE bounded foreground wait (<= 540 s) on the end marker; prints the rc line or STILL-RUNNING (then run `wait` again, never a loop of your own).
  f=$D/roll-$R-$2.out; [ -e "$f.start" ] || { echo "NO-START-MARKER $2 (no deploy/rollback was started by this kit: STOP)"; exit 2; }
  end=$(( $(date +%s) + ${WAITMAX:-540} )); until [ "$f.done" -nt "$f.start" ] || [ "$(date +%s)" -ge "$end" ]; do sleep ${WAITSTEP:-15}; done
  # exit codes (acp delta read 2): 0 = `deploy_rc=0` printed (the ONLY value that lets a && chain go on to stagecheck); 3 = STILL-RUNNING (run `wait` again); 4 = any other deploy_rc (or a missing rc line) = STOP, tell the lead; 2 = no start marker
  if [ "$f.done" -nt "$f.start" ]; then l=$(grep -E '^deploy_rc=' "$f" | tail -1); echo "${l:-deploy_rc=MISSING}"; [ "$l" = deploy_rc=0 ] && exit 0 || exit 4; else echo "STILL-RUNNING $2"; exit 3; fi ;;
appcheck) # APP-step watch (acp Q1=ii), read-only kubectl jsonpath, run again while it prints WAIT: a Pending surge pod is NOT a STOP for up to 10 min; it IS a STOP after 10 min (exit 5), or at once if any data-store pod is not Ready (exit 5). Exit 0 = no Pending pod and every data-store pod Ready; 3 = Pending pod(s) younger than 10 min (WAIT, run again).
  ds_bad=""
  # data stores of release dev-health: postgresql = StatefulSet, valkey = Deployment (hashed pod names): pods are selected by the workload's own matchLabels; no pod found = STOP
  for w in "sts dev-health-ops-postgresql" "deploy dev-health-ops-valkey"; do set -- $w
    sel=$($K get $1 $2 -o jsonpath='{.spec.selector.matchLabels}' 2>/dev/null | python3 -I -c 'import sys,json; d=json.load(sys.stdin); print(",".join("%s=%s" % kv for kv in sorted(d.items())))' 2>/dev/null)
    if [ -z "$sel" ]; then ds_bad="$ds_bad $1/$2(no selector)"; continue; fi
    pods=$($K get pods -l "$sel" -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.containerStatuses[0].ready}{"\n"}{end}' 2>/dev/null | awk 'NF>=1')
    if [ -z "$pods" ]; then ds_bad="$ds_bad $1/$2(no pod)"; continue; fi
    while read -r pn pr_; do [ "$pr_" = true ] || ds_bad="$ds_bad $pn"; done <<< "$pods"
  done
  for sts in $($K get sts -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.replicas}{" "}{.status.readyReplicas}{"\n"}{end}' | awk 'NF>=2 && $2>0 && $3!=$2 {print $1}'); do ds_bad="$ds_bad sts/$sts"; done
  now=$(date +%s); oldest=0; pend=""; while read -r n t; do [ -n "$n" ] || continue; a=$(( now - $(date -d "$t" +%s) )); pend="$pend $n(${a}s)"; [ $a -gt $oldest ] && oldest=$a; done < <($K get pods --field-selector=status.phase=Pending -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.creationTimestamp}{"\n"}{end}')
  echo "APPCHECK data-store pods not Ready: ${ds_bad:-none}; Pending pods:${pend:- none}; oldest Pending ${oldest}s"
  if [ -n "$ds_bad" ]; then echo "APPCHECK STOP: a data-store pod is not Ready (stop at once, report to main)"; exit 5; fi
  if [ $oldest -gt 600 ]; then echo "APPCHECK STOP: a pod has been Pending > 10 min (report to main)"; exit 5; fi
  if [ -n "$pend" ]; then echo "APPCHECK WAIT: Pending < 10 min is tolerated in the app step; run appcheck again"; exit 3; fi
  echo "APPCHECK PASS: no Pending pod, every data-store pod Ready" ;;
dscheck) # Ready gate of the DATA-STORE step (acp item 2 / D6412): run ONLY after `wait ds` printed deploy_rc=0 (the data-store step is the LAST step). Read-only, every read fails CLOSED. Needs RESTARTMAP in the env (the per-pod restart counts written by the `restarts` verb at S2app into the state file). It FIRST sleeps the settle time (SETTLE, default 150 s: the workers' readiness gives up after 60 s and liveness after 90 s without the database), THEN requires: postgresql-0 Ready on the 400m request, the sts fully rolled (updated == ready == replicas, current revision == update revision), EVERY Deployment of release dev-health Ready (readyReplicas == replicas; polled up to SETTLE_EXTRA = 60 s more), and no pod of the release restarted since S2app (a pod present at S2app: restartCount <= its baseline; a new pod, and postgresql-0 which is recreated: restartCount 0).
  case "${RESTARTMAP:-}" in ""|*[!A-Za-z0-9.:,_-]*) echo "dscheck needs RESTARTMAP (the per-pod restart baseline written by the restarts verb at S2app): STOP, usage error"; exit 2;; esac
  sts=dev-health-ops-postgresql
  notready() { ( set -o pipefail; $K get deploy -l app.kubernetes.io/instance=dev-health -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.replicas}{" "}{.status.readyReplicas}{"\n"}{end}' | awk '{n++} $2>0 && $2!=$3 {k=k" "$1} END{if(n==0) exit 7; print (k==""?"none":k)}' ); }
  podrs() { ( set -o pipefail; $K get pods -l app.kubernetes.io/instance=dev-health --field-selector=status.phase!=Succeeded,status.phase!=Failed -o jsonpath='{range .items[*]}{.metadata.name}{" "}{range .status.containerStatuses[*]}{.restartCount}{","}{end}{"\n"}{end}' | awk 'NF>=1 {s=0; n=split($2,a,","); for(i=1;i<=n;i++) s+=a[i]; print $1, s}' ); }
  sleep ${SETTLE:-150}
  nr=$(notready) || { echo "DSCHECK STOP: the Deployment read failed or returned nothing"; exit 1; }
  end=$(( $(date +%s) + ${SETTLE_EXTRA:-60} )); while [ "$nr" != none ] && [ "$(date +%s)" -lt "$end" ]; do sleep ${SETTLE_STEP:-5}; nr=$(notready) || { echo "DSCHECK STOP: the Deployment read failed"; exit 1; }; done
  r=$($K get sts $sts -o jsonpath='{.spec.replicas}') && rd=$($K get sts $sts -o jsonpath='{.status.readyReplicas}') && up=$($K get sts $sts -o jsonpath='{.status.updatedReplicas}') && cr=$($K get sts $sts -o jsonpath='{.status.currentRevision}') && ur=$($K get sts $sts -o jsonpath='{.status.updateRevision}') || { echo "DSCHECK STOP: the sts read failed"; exit 1; }
  pr=$($K get pod $sts-0 -o jsonpath='{.status.containerStatuses[0].ready}') && rq=$($K get pod $sts-0 -o jsonpath='{.spec.containers[0].resources.requests.cpu}') && ph=$($K get pod $sts-0 -o jsonpath='{.status.phase}') || { echo "DSCHECK STOP: the postgresql-0 read failed"; exit 1; }
  echo "DSCHECK sts $sts replicas=$r ready=${rd:-0} updated=${up:-0} currentRevision==updateRevision: $([ "$cr" = "$ur" ] && echo yes || echo NO); pod $sts-0 phase=$ph ready=$pr cpu request=$rq"
  cur=$(podrs) || { echo "DSCHECK STOP: the pod restart read failed"; exit 1; }
  rbad=$(printf '%s\n' "$cur" | awk -v map="$RESTARTMAP" 'BEGIN{n=split(map,m,","); for(i=1;i<=n;i++){split(m[i],kv,":"); base[kv[1]]=kv[2]}} {b=($1 in base)?base[$1]:0; if($1=="'$sts'-0") b=0; if($2>b) k=k" "$1"("$2">"b")"} END{print k}')
  echo "DSCHECK Deployments NOT Ready after the settle time: $nr; pods whose restart count rose since S2app: ${rbad:-none}"
  if [ "$r" = 1 ] && [ "${rd:-0}" = 1 ] && [ "${up:-0}" = 1 ] && [ "$cr" = "$ur" ] && [ "$pr" = true ] && [ "$rq" = 400m ] && [ "$ph" = Running ] && [ "$nr" = none ] && [ -z "$rbad" ]; then echo "DSCHECK PASS: postgresql-0 Ready on the 400m request, every Deployment Ready again, no restart rise; the data-store step is complete"; else echo "DSCHECK FAIL: STOP (report to main; postgresql-0 not Ready / not on the new request / a Deployment is not Ready / restarts rose)"; exit 1; fi ;;
dswatch) # DS-step watch (acp NB-2a), read-only, run between the `wait ds` reads: postgresql-0 Pending for more than DSWATCH_PEND seconds (default 60) or not Ready for more than DSWATCH_NR seconds (default 300) since its creation = STOP (exit 5); Ready = exit 0; otherwise (young, or the pod is being recreated) = WAIT, exit 3. Fail-closed on a read error.
  pn=dev-health-ops-postgresql-0
  pj=$($K get pods -l app.kubernetes.io/component=postgresql,app.kubernetes.io/instance=dev-health -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.phase}{" "}{.status.containerStatuses[0].ready}{" "}{.metadata.creationTimestamp}{"\n"}{end}') || { echo "DSWATCH STOP: the postgresql pod read failed"; exit 1; }
  if [ -z "$(printf '%s' "$pj" | tr -d '[:space:]')" ]; then echo "DSWATCH WAIT: no postgresql pod yet (being recreated?); run again"; exit 3; fi
  read -r n ph rdy ts <<< "$(printf '%s\n' "$pj" | head -1)"; age=$(( $(date +%s) - $(date -d "$ts" +%s) ))
  echo "DSWATCH $n phase=$ph ready=${rdy:-false} age=${age}s"
  if [ "$rdy" = true ]; then echo "DSWATCH PASS: $n Ready"; exit 0; fi
  if [ "$ph" = Pending ] && [ "$age" -gt "${DSWATCH_PEND:-60}" ]; then echo "DSWATCH STOP: $n has been Pending for ${age}s (> ${DSWATCH_PEND:-60}s): the database is DOWN (report to main at once; see the recovery rule)"; dsdiag; exit 5; fi
  if [ "$age" -gt "${DSWATCH_NR:-300}" ]; then echo "DSWATCH STOP: $n not Ready for ${age}s (> ${DSWATCH_NR:-300}s): the database is DOWN (report to main at once; see the recovery rule)"; dsdiag; exit 5; fi
  echo "DSWATCH WAIT: $n not Ready yet (${age}s); run again"; exit 3 ;;
restarts) # read-only: the per-pod container restart counts of release dev-health (non-hook pods) and the state lines. Fails closed (exit 1) on a kubectl error or an empty list. Output: `RESTART <pod> <n>` lines, `STATE RESTARTMAP=<pod:n,pod:n,...>` and `STATE RESTARTS0=<sum>`; STATE-24d.sh writes them into the state file.
  rl=$( set -o pipefail; $K get pods -l app.kubernetes.io/instance=dev-health --field-selector=status.phase!=Succeeded,status.phase!=Failed -o jsonpath='{range .items[*]}{.metadata.name}{" "}{range .status.containerStatuses[*]}{.restartCount}{","}{end}{"\n"}{end}' | awk 'NF>=1 {s=0; n=split($2,a,","); for(i=1;i<=n;i++) s+=a[i]; print $1, s}' ) || { echo "restarts: the kubectl read failed: STOP"; exit 1; }
  [ -n "$rl" ] || { echo "restarts: no pod of release dev-health read: STOP"; exit 1; }
  printf '%s\n' "$rl" | sed 's/^/RESTART /'; echo "STATE RESTARTMAP=$(printf '%s\n' "$rl" | awk '{printf "%s%s:%s", (NR>1?",":""), $1, $2}')"; echo "STATE RESTARTS0=$(printf '%s\n' "$rl" | awk '{s+=$2} END{print s+0}')" ;;
helmrev) # read-only: the last 5 helm history rows and `STATE LIVEREV=<n>` (app, the default) or `STATE LIVEREV2=<n>` (ds): the last DEPLOYED revision NUMBER = the revision BEFORE the next step (per-service rolls: read it at the START of each step). Exit 1 when helm fails or no revision is deployed.
  hj=$( set -o pipefail; helm history dev-health -n $NS -o json | jq -c . ) || { echo "helmrev: helm history failed: STOP"; exit 1; }
  printf '%s\n' "$hj" | jq -r '.[-5:][]|"rev \(.revision) \(.status) \(.description)"' || exit 1
  n=$(printf '%s\n' "$hj" | jq -r '[.[]|select(.status=="deployed")]|last|.revision // empty'); case "$n" in ""|*[!0-9]*) echo "helmrev: no deployed revision: STOP"; exit 1;; esac; if [ "${2:-app}" = ds ]; then echo "STATE LIVEREV2=$n"; else echo "STATE LIVEREV=$n"; fi ;;
stagecheck) # $2 = stage (app|ds|rollback), $3 = helm revision BEFORE the stage (LIVEREV, or LIVEREV2 for the ds stage). Run right after the stage. NO retry on a denial.
  case "${3:-}" in ""|*[!0-9]*) echo "stagecheck needs the live-before helm revision (a NUMBER) as the 3rd argument, e.g. ssh prod \"R=24d bash -s -- stagecheck app \$LIVEREV\" with LIVEREV set locally to the helm revision number (got '${3:-}'): STOP, usage error (nothing was read or changed)"; exit 2;; esac
  stopn=0; stp() { echo "$1"; stopn=$((stopn+1)); }
  LOG=$D/roll-$R-$2.out
  # v1.1: the LIVE revision is the last one with status "deployed"; after a FAILED upgrade (the newest revision failed) `helm list` shows the newest, not the live one: the newest and its status go on their own line
  cur=$(helm history dev-health -n $NS -o json | jq -r '[.[]|select(.status=="deployed")]|last|.revision // "none"'); st=deployed
  echo "helm live (last deployed) rev now $cur ($st); before the stage $3"
  echo "helm newest rev: $(helm history dev-health -n $NS -o json | jq -r 'last|"\(.revision) status \(.status)"')"
  if [ ! -s "$LOG" ]; then echo "STAGE $2 NOT STARTED (no log): if the deploy/ssh call was DENIED by the classifier => STOP, report the exact step, NO retry, NO other path"; exit 4; fi
  echo "stage log: $(grep -c . "$LOG") lines, done marker: $([ -e "$LOG.done" ] && echo yes || echo no), $(grep -E '^deploy_rc=' "$LOG" | tail -1)"
  case "$cur" in ""|none|*[!0-9]*) stp "helm live revision unreadable ('$cur') => STOP and report";; esac
  [ "$cur" = "$3" ] && stp "helm rev did NOT advance: stage not applied => STOP and report (no retry)"
  [ -e "$LOG.done" ] && [ "$(grep -E '^deploy_rc=' "$LOG" | tail -1)" = deploy_rc=0 ] || stp "stage $2: no done marker with deploy_rc=0 => STOP and report"
  r=$($K get sts dev-health-ops-clickhouse -o jsonpath='{.spec.replicas}'); y=$($K get sts dev-health-ops-clickhouse -o jsonpath='{.status.readyReplicas}'); p=$($K get pvc clickhouse-data-dev-health-ops-clickhouse-0 -o jsonpath='{.status.phase}')
  if [ "$r" = 0 ] && [ "${y:-0}" = 0 ] && [ "$p" = Bound ]; then echo "CH STS 0/0 + PVC Bound: OK"; else stp "CH STS NOT 0/0 OR PVC NOT Bound => STOP, report to main"; fi
  echo "'start refused' lines, all 9 worker groups, every pod (count): $(for g in heavy ops sync sync-provider scheduler reconciler stream-ingest stream-external stream-pagerduty; do for q in $($K get pods -l dev-health.io/worker-group=$g -o name); do $K logs $q --all-containers 2>/dev/null; done; done | grep -c 'start refused')"
  echo "readiness refusal lines in the CURRENT pods, last 10 min (count; posture_manifest_lockstep | domain_postgres | coordinator_postgres): $(for g in heavy ops sync sync-provider scheduler reconciler stream-ingest stream-external stream-pagerduty; do for q in $($K get pods -l dev-health.io/worker-group=$g -o name); do $K logs $q --all-containers --since=10m 2>/dev/null; done; done | grep -cE '"check":"(posture_manifest_lockstep|domain_postgres|coordinator_postgres)"')"
  echo "go-api ready $($K get deploy dev-health-ops-go-api -o jsonpath='{.status.readyReplicas}')/$($K get deploy dev-health-ops-go-api -o jsonpath='{.spec.replicas}')  query-api ready $($K get deploy dev-health-ops-query-api -o jsonpath='{.status.readyReplicas}')/$($K get deploy dev-health-ops-query-api -o jsonpath='{.spec.replicas}')  auth-service ready $($K get deploy dev-health-ops-auth-service -o jsonpath='{.status.readyReplicas}')/$($K get deploy dev-health-ops-auth-service -o jsonpath='{.spec.replicas}')"
  case "$2" in i[0-9]|i[0-9][0-9]) # image steps (data driven, IMGROWS-<n>.txt): no failed hook pod; IMG_MODE=norolls = ZERO pod rollouts (every worker pod still on IMG_OLD, restart sum of the release == RESTARTS0); IMG_MODE=rolls = every worker pod on IMG_NEW, restarts 0 in the nine groups; a config roll (CMROLL set, no digest pair) = each IMG_DEPLOYS Deployment fully rolled out and Ready, restarts 0. Env: IMG_MODE, IMG_OLD, IMG_NEW (digest prefixes), RESTARTS0 (a number, from state.env), CMROLL.
    case "${IMG_OLD:-}${IMG_NEW:-}" in "") [ "${IMG_MODE:-}" = rolls ] && [ -n "${CMROLL:-}" ] || stp "STAGECHECK $2: IMG_OLD / IMG_NEW are not set (g0-vars sets them for an img step): STOP"; esac   # a #CMROLL config roll (CMROLL set, rolls) has no digest pair
    case "${IMG_MODE:-}" in rolls|norolls) ;; *) stp "STAGECHECK $2: IMG_MODE is not rolls|norolls: STOP";; esac
    fp=$(pj_lines | awk '$2=="Failed"{printf "%s ",$1}'); [ -z "$fp" ] && echo "STAGECHECK $2: no failed pod (hook Jobs completed)" || stp "STAGECHECK $2: failed pod(s): $fp"
    gl=$(img_groups) || { stp "STAGECHECK $2: IMG_DEPLOYS has a name that is not a dev-health-ops-<name> Deployment: STOP"; gl=""; }
    wd=$(for g in $gl; do pj_digests "$g"; done | sort -u | paste -sd, -)
    wr=$(for g in $gl; do pj_restart_sum "$g"; done | awk '{s+=$1} END{print s+0}')
    if [ "${IMG_MODE:-}" = norolls ]; then
      if [ -n "${GROUPDIG:-}" ]; then   # v3h: each group against its OWN pre digest set (the pre map, prodroll state GROUPDIG); IMG_OLD is not used here
        case "$GROUPDIG" in *[!a-z0-9:,+-]*) stp "STAGECHECK $2: GROUPDIG has a bad character: STOP";; esac
        gnow=$(group_map)
        for e in ${GROUPDIG//,/ }; do g=${e%%:*}; x=${e#*:}; y=$(printf '%s\n' "$gnow" | tr , '\n' | sed -n "s/^$g://p")
          [ -n "$y" ] && [ "$x" = "$y" ] && echo "STAGECHECK $2: group $g pre $x now $y (ok)" || stp "STAGECHECK $2: group $g pre $x now ${y:-?} (MOVED)"; done
        [ "$gnow" = "$GROUPDIG" ] && echo "STAGECHECK $2: worker group digest map == pre map (0 pod rollouts: ok)" || stp "STAGECHECK $2: worker group digest map '$gnow' != pre map '$GROUPDIG' (a pod rolled in a hook-only step)"
      else
        [ "$wd" = "$IMG_OLD" ] && echo "STAGECHECK $2: worker image digests $wd = old (0 pod rollouts: ok)" || stp "STAGECHECK $2: worker image digests '$wd' want '$IMG_OLD' (a pod rolled in a hook-only step)"
      fi
      case "${RESTARTS0:-}" in ""|*[!0-9]*) stp "STAGECHECK $2: RESTARTS0 is not set (a number): run the restarts verb first";; *) rs=$(pj_restart_sum "app.kubernetes.io/instance=dev-health"); [ "$rs" = "$RESTARTS0" ] && echo "STAGECHECK $2: restart sum $rs == baseline $RESTARTS0 (ok)" || stp "STAGECHECK $2: restart sum $rs != baseline $RESTARTS0";; esac
    elif [ -n "${CMROLL:-}" ] && [ -z "${IMG_NEW:-}" ]; then   # a config roll (#CMROLL): no image moves (RENDER-PATHS proved it); every Deployment of IMG_DEPLOYS fully rolled out and Ready, its pods Ready with restarts 0 (that no OTHER pod was replaced is I6u poduids)
      for d in ${IMG_DEPLOYS//,/ }; do case "$d" in *[!a-z0-9-]*|"") stp "STAGECHECK $2: bad Deployment name in IMG_DEPLOYS"; continue;; esac
        rr=$($K get deploy "$d" -o jsonpath='{.spec.replicas} {.status.readyReplicas} {.status.updatedReplicas} {.status.replicas}' 2>/dev/null) || rr=""; read -r s1 s2 s3 s4 <<< "$rr"
        [ -n "${s1:-}" ] && [ "${s1:-0}" -gt 0 ] && [ "$s1" = "${s2:-}" ] && [ "$s1" = "${s3:-}" ] && [ "$s1" = "${s4:-}" ] && echo "STAGECHECK $2: $d ready ${s2}/${s1}, updated ${s3}, replicas ${s4} (ok)" || stp "STAGECHECK $2: $d not fully rolled out (spec/ready/updated/replicas '$rr')"; done
      nr=$(for g in $gl; do pj_not_ready "$g"; done | awk '{s+=$1} END{print s+0}'); np=$(for g in $gl; do pj_lines "$g"; done | grep -c .)
      [ "$np" -gt 0 ] && [ "$nr" = 0 ] && echo "STAGECHECK $2: config roll pods $np, not Ready 0, image digests $wd (unchanged by the render)" || stp "STAGECHECK $2: config roll pods $np, not Ready $nr"
      [ "$wr" = 0 ] && echo "STAGECHECK $2: config roll restarts 0 (ok)" || stp "STAGECHECK $2: config roll restart sum $wr, want 0"
    else
      [ "$wd" = "$IMG_NEW" ] && echo "STAGECHECK $2: worker image digests $wd = new (ok)" || stp "STAGECHECK $2: worker image digests '$wd' want '$IMG_NEW'"
      [ "$wr" = 0 ] && echo "STAGECHECK $2: worker restarts 0 (ok)" || stp "STAGECHECK $2: worker restart sum $wr, want 0"
    fi ;;
  esac
  groups_fn | head -12
  if [ "$stopn" != 0 ]; then echo "STAGECHECK: STOP ($stopn problem(s) above)"; exit 1; fi; echo "STAGECHECK: PASS"; [ "$2" = app ] && echo "STATE LIVEREV2=$cur"; exit 0 ;;
*) echo usage; exit 2;;
esac
