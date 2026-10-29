#!/usr/bin/env bash
# HEADROOM-24d.sh table | collect <dir> | compute <dir> <render.yaml>   (roll 24d; D6411 / D6412 / acp items 3 and 4; names and numbers only)
# table   : LOCAL arithmetic of the acp table (no cluster): steady / surge / burst / worst case against the 4000m node, two cases: (a) the CHAOS-11613 acr cuts are live, (b) they are NOT (acr 100m x2, mcp 50m, projector 100m), each for the acp pooler cut (30/20/20) and for the pooler requests UNCHANGED at 50m (STOP item 1 until the key decision), plus the NOW (old requests) case that reproduces the S1 Pending of 24c. PASS only if every 24d worst case <= 4000m.
# collect : ON prod, read-only kubectl jsonpath (no -o json/yaml, no Secret, no exec): nodes, pods, deployments, scaledobjects, hpas -> STDOUT as tagged blocks; tee them to a LOCAL file (`ssh prod 'bash -s -- collect' < HEADROOM-24d.sh | tee $KIT/out/g0-collect.txt`), which `compute` and `case` read. Exit 1 on a kubectl failure or an empty block.
# topsnap / topcmp (acp item 5): per-pod `kubectl top` + every HPA row read BEFORE and AFTER the roll; v3j: only the HPAs of ROLLED Deployments are gated (current% within 5 points and below 70% of the target; a web HPA must be readable); a move on sample 1 = RECHECK (exit 3), a move on sample 2 (final) = FAIL = STOP; HPAs not rolled get a NOTE line.
# compute : reads those files + the TIP render (RENDER-GATE-24d.sh render ...) and prints R6 (item N): free = allocatable - all pod CPU requests; need = the data-store request (NEW postgresql request from the render) + ALL surge (each Deployment with maxSurge >= 1 adds one pod at its NEW request; valkey 25% of 1 = 1; poolers surge 0; Recreate 0) + the KEDA/HPA burst ((max - replicas) pods at the NEW request); `HEADROOM FAIL` (exit 1) unless free >= need, else a named planned scale-down first.
set -u

# real-layout parsers (acp N2): kubectl prints a header row; columns are found BY HEADER NAME (and by header offset for HPA, whose TARGETS field holds spaces), never by position. Handles `top pods`, `top pods --containers` (POD NAME CPU MEMORY), `-A` (NAMESPACE first), with or without --no-headers is NOT supported (the header is required).
normtop() { python3 -I -c '
import sys, re
L = [l.rstrip("\n") for l in sys.stdin if l.strip()]
if not L: sys.exit(0)
h = L[0].split()
try: ic, im, inm = h.index("CPU(cores)"), h.index("MEMORY(bytes)"), h.index("NAME")
except ValueError: print("# top header not recognised: %r" % L[0]); sys.exit(3)
for l in L[1:]:
    w = l.split()
    if len(w) != len(h): continue
    pod = w[h.index("POD")] if "POD" in h else w[inm]
    ctr = w[inm] if "POD" in h else "-"
    print("top", pod if ctr == "-" else pod + "/" + ctr, w[ic], w[im])
'; }
normhpa() { python3 -I -c '
import sys, re
L = [l.rstrip("\n") for l in sys.stdin if l.strip()]
if not L: sys.exit(0)
hd = L[0]; cols = ["NAME", "REFERENCE", "TARGETS", "MINPODS", "MAXPODS", "REPLICAS", "AGE"]
pos = {}
for c in cols:
    m = re.search(r"(?<![A-Z])" + c + r"(?![A-Z])", hd)
    if not m: print("# hpa header not recognised: %r" % hd); sys.exit(3)
    pos[c] = m.start()
order = sorted(cols, key=lambda c: pos[c])
for l in L[1:]:
    f = {}
    for i, c in enumerate(order):
        a = pos[c]; b = pos[order[i + 1]] if i + 1 < len(order) else len(l)
        f[c] = l[a:b].strip()
    m = re.search(r"(\d+)%/(\d+)%", f["TARGETS"])
    print("hpa", f["NAME"], (m.group(0) if m else "unknown"), f["MINPODS"], f["MAXPODS"], f["REPLICAS"])
'; }
case "${1:-}" in
case) O=${2:?collect file (the local tee of `ssh prod bash -s -- collect`)}
  python3 -I - "$O" "$0" <<'PY'
import sys, re
def blocks(path):
    d, cur = {}, None
    try: txt = open(path).read()
    except OSError: print("HEADROOM: FAIL (cannot read the collect file %s)" % path); sys.exit(1)
    for l in txt.split("\n"):
        if l.startswith("@@FILE "): cur = l[7:].strip(); d[cur] = []
        elif l.startswith("@@END"): cur = None
        elif cur is not None and l.strip(): d[cur].append(l.split())
    return d
O = sys.argv[1]; B = blocks(O); r = {}
if not B.get("deploy.txt"): print("CASE: FAIL (no deploy.txt block in the collect file: nothing was read)"); sys.exit(1)
for f in B["deploy.txt"]:
    if f[0].startswith("dev-health/") and len(f) >= 4:
        n = f[0].split("/", 1)[1]
        for k in ("acr-api", "acr-mcp", "acr-projector"):
            if re.search(k + "$", n) or (k == "acr-api" and re.search(r"acr(-api)?$", n)): r[k] = (f[1], f[-1].rstrip(","))
print("ACR LIVE (replicas, cpu request):", r)
ok = r.get("acr-api", (0, ""))[1] == "25m" and r.get("acr-mcp", (0, ""))[1] == "25m" and r.get("acr-projector", (0, ""))[1] == "50m"
print("CASE: %s (acr-api 25m AND acr-mcp 25m AND acr-projector 50m = the acr roll for #1749 live -> (a); else (b) = the default, old acr requests, projector 100m). Replicas for the arithmetic: ACR_REPL=%s MCP_REPL=%s" % ("a" if ok else "b", r.get("acr-api", (2,))[0], r.get("acr-mcp", (1,))[0]))
import subprocess, os
env = dict(os.environ, ACR_REPL=str(r.get("acr-api", (2,))[0]), MCP_REPL=str(r.get("acr-mcp", (1,))[0]))
tb = subprocess.run(["bash", sys.argv[2], "table"], env=env, capture_output=True, text=True).stdout.split("\n") if len(sys.argv) > 2 else []
print("\n".join(l for l in tb if "APP STEP FIRST" in l and ("(a)" if ok else "(b)") in l))
PY
  exit $? ;;
table)
python3 -I - <<'PY'
import sys, math
# name: (replicas, now_req, new_req, surge_pods_per_rollout (0 = Recreate/poolers/sts), burst_extra_pods)
def W(acr, mcp, proj, pool):
    return {
     "postgresql sts":(1,100,400,0,0), "valkey":(1,50,50,1,0), "falkordb sts":(1,200,200,0,0),
     "auth-service":(2,250,50,1,0), "query-api":(2,100,25,1,0), "web (HPA 2-4)":(2,50,50,1,2),
     "acr api":(2,100,acr,1,0), "acr-mcp":(1,50,mcp,1,0), "acr-projector (Recreate)":(1,100,proj,0,0),
     "go-api":(1,50,50,1,0), "go-heavy (KEDA 1-3)":(1,100,100,1,2), "go-ops (KEDA 1-2)":(1,100,50,1,1), "go-sync (KEDA 1-2)":(1,100,50,1,1),
     "go-sync-provider":(1,100,75,1,0), "go-reconciler":(1,100,30,1,0), "go-scheduler":(1,100,25,1,0),
     "go-stream-external":(1,50,25,1,0), "go-stream-ingest":(1,50,25,1,0), "go-stream-pagerduty":(1,50,25,1,0),
     "pgbouncer transaction":(1,50,pool[0],0,0), "pgbouncer queue-session":(1,50,pool[1],0,0), "pgbouncer coordinator-session":(1,50,pool[2],0,0),
     "otel-collector (Recreate)":(1,100,50,0,0),
     "system pods (ingress 100, keda 3x100, coredns 100, metrics-server 100)":(1,600,600,0,0)}
def run(label, acr, mcp, proj, pool):
    w = W(acr, mcp, proj, pool)
    steady = sum(r*n for r, o, n, s, b in w.values())
    surge = sum(s*n for r, o, n, s, b in w.values())
    burst = sum(b*n for r, o, n, s, b in w.values())
    worst = steady + surge + burst
    print("%-62s steady %4d  surge %4d  burst %4d  worst %4d  spare %4d (of 4000)  %s" % (label, steady, surge, burst, worst, 4000 - worst, "OK" if worst <= 4000 else "OVER"))
    return worst
now = {k: v for k, v in W(100, 50, 100, (50, 50, 50)).items()}
steady0 = sum(r*o for r, o, n, s, b in now.values()); surge0 = sum(s*o for r, o, n, s, b in now.values()); burst0 = sum(b*o for r, o, n, s, b in now.values())
print("NOW (old requests, no change)                                  steady %4d  surge %4d  burst %4d  worst %4d  spare %4d: %s (the 24c S1 incident: postgresql-0 Pending while surge pods held the CPU)" % (steady0, surge0, burst0, steady0+surge0+burst0, 4000-(steady0+surge0+burst0), "OVER" if steady0+surge0+burst0 > 4000 else "OK"))
ok = True
import os
AR = int(os.environ.get("ACR_REPL", "2")); MR = int(os.environ.get("MCP_REPL", "1"))  # PLAN defaults; Gate 0 reads the LIVE replicas (subcommand `case`); no fixed totals
CUT_ACR, CUT_MCP = 75, 25  # per-pod savings of CHAOS-11613 (acr-api 100->25m, acr-mcp 50->25m)
POOL = (30, 30, 30)  # acp ruling A: one shared key, 30m on all three
def run2(label, acr, mcp, proj):
    w = W(acr, mcp, proj, POOL); w["acr api"] = (AR, 100, acr, 1, 0); w["acr-mcp"] = (MR, 50, mcp, 1, 0)
    steady = sum(r*n for r, o, n, s, b in w.values()); surge = sum(s*n for r, o, n, s, b in w.values()); burst = sum(b*n for r, o, n, s, b in w.values())
    worst = steady + surge + burst
    print("%-74s steady %4d  surge %4d  burst %4d  worst %4d  spare %4d (of 4000)  %s" % (label, steady, surge, burst, worst, 4000 - worst, "OK" if worst <= 4000 else "OVER"))
    return worst
print("poolers 30m x3 = 90m (acp ruling A); NO projector edit in 24d (acp P2: the projector cut rides the acr roll for #1749, CHAOS-11613); acr replicas acr-api %d, acr-mcp %d" % (AR, MR))
ok = run2("24d (b) DEFAULT acr NOT cut (acr-api 100 x%d, acr-mcp 50, projector 100)" % AR, 100, 50, 100) <= 4000 and ok
ok = run2("24d (a) acr roll LIVE (acr-api -%d/pod x%d, acr-mcp -%d/pod x%d, projector -50 x1)" % (CUT_ACR, AR, CUT_MCP, MR), 100-CUT_ACR, 50-CUT_MCP, 50) <= 4000 and ok
# Q1 = ii: the APP step runs FIRST on the OLD steady state. Surge = one pod at the NEW request for each RollingUpdate Deployment whose pod template CHANGES in this step (auth-service, query-api, go-ops, go-sync, go-sync-provider, go-scheduler, go-reconciler, 3 streams = 50+25+50+50+75+25+30+3x25 = 380m; poolers surge 0, the collector is Recreate). The SAFE BOUND counts a surge pod for every RollingUpdate Deployment (780m, 680m with the acr cuts). Informational; a Pending surge pod is tolerated <= 10 min, then STOP.
CHG = 380
for tag, acrcut, projcut, sg in (("(b) acr NOT cut", 0, 0, 780), ("(a) acr roll LIVE", CUT_ACR * AR + CUT_MCP * MR, 50, 680)):
    old = steady0 - acrcut - projcut; w = old + CHG + 400; wsafe = old + sg + 400
    print("24d APP STEP FIRST %-18s old steady %4d + changed-template surge %3d + burst 400 = %4d of 4000: %s | safe bound (every Deployment surges) %4d + %3d + 400 = %4d: %s" % (tag, old, CHG, w, "WITHIN" if w <= 4000 else "OVER by %d" % (w - 4000), old, sg, wsafe, "WITHIN" if wsafe <= 4000 else "OVER by %d (Pending surge pod tolerated <= 10 min, then STOP)" % (wsafe - 4000)))
print("HEADROOM TABLE: %s (every 24d worst case <= 4000m)" % ("PASS" if ok else "FAIL"))
sys.exit(0 if ok else 1)
PY
exit $? ;;
collect) # ON prod, read-only: prints the five reads to STDOUT as tagged blocks (`@@FILE name` ... `@@END`); the caller tees them to a LOCAL file that `compute` and `case` read. Exit 1 on any kubectl failure or an empty nodes/pods/deploy block.
  export KUBECONFIG=${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}; crc=0
  blk() { nm=$1; rq=$2; shift 2; o=$("$@") || crc=1; [ "$rq" = req ] && [ -z "$(printf '%s' "$o" | tr -d '[:space:]')" ] && { echo "@@COLLECT: the $nm read is EMPTY" >&2; crc=1; }; echo "@@FILE $nm"; printf '%s\n' "$o"; echo "@@END"; }
  blk nodes.txt req kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.allocatable.cpu}{"\n"}{end}'
  blk pods.txt req kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{" "}{.status.phase}{" "}{range .spec.containers[*]}{.resources.requests.cpu}{","}{end}{"\n"}{end}'
  blk deploy.txt req kubectl get deploy -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{" "}{.spec.replicas}{" "}{.spec.strategy.type}{" "}{.spec.strategy.rollingUpdate.maxSurge}{" "}{range .spec.template.spec.containers[*]}{.resources.requests.cpu}{","}{end}{"\n"}{end}'
  blk scaledobjects.txt opt kubectl -n dev-health get scaledobject -o jsonpath='{range .items[*]}{.spec.scaleTargetRef.name}{" "}{.spec.maxReplicaCount}{"\n"}{end}'
  blk hpas.txt opt kubectl -n dev-health get hpa -o jsonpath='{range .items[*]}{.spec.scaleTargetRef.name}{" "}{.spec.maxReplicas}{"\n"}{end}'
  [ "$crc" = 0 ] || { echo "@@COLLECT FAIL (a kubectl read failed)"; exit 1; }
  echo "@@COLLECT OK $(date -u +%FT%TZ)"; exit 0 ;;
compute) O=${2:?collect file}; R=${3:?render.yaml}; MODE=${4:?app|ds}
python3 -I - "$O" "$R" "$MODE" <<'PY'
import sys, math, re, yaml
def blocks(path):
    d, cur = {}, None
    try: txt = open(path).read()
    except OSError: print("HEADROOM: FAIL (cannot read the collect file %s)" % path); sys.exit(1)
    for l in txt.split("\n"):
        if l.startswith("@@FILE "): cur = l[7:].strip(); d[cur] = []
        elif l.startswith("@@END"): cur = None
        elif cur is not None and l.strip(): d[cur].append(l.split())
    return d
O, R, MODE = sys.argv[1], sys.argv[2], sys.argv[3]
def cpu(s):
    s = s.strip()
    if not s: return 0
    return int(s[:-1]) if s.endswith("m") else int(float(s) * 1000)
B = blocks(O)
for need_blk in ("nodes.txt", "pods.txt", "deploy.txt"):
    if not B.get(need_blk): print("HEADROOM: FAIL (the %s block is missing or empty in %s: the read failed; STOP, nothing computed)" % (need_blk, O)); sys.exit(1)
if "@@COLLECT OK" not in open(O).read(): print("HEADROOM: FAIL (no @@COLLECT OK line: the collect did not finish)"); sys.exit(1)
lines = lambda f: B.get(f, [])
alloc = sum(cpu(l[1]) for l in lines("nodes.txt"))
used = 0
for l in lines("pods.txt"):
    if len(l) >= 3 and l[1] not in ("Succeeded", "Failed"): used += sum(cpu(x) for x in l[2].split(",") if x)
free = alloc - used
new = {}
for d in yaml.safe_load_all(open(R)):
    if isinstance(d, dict) and d.get("kind") in ("Deployment", "StatefulSet"):
        pod = (((d.get("spec") or {}).get("template") or {}).get("spec")) or {}
        new[(d["kind"], d["metadata"]["name"])] = sum(cpu(((c.get("resources") or {}).get("requests") or {}).get("cpu", "")) for c in pod.get("containers") or [])
# surge: a RollingUpdate Deployment with maxSurge >= 1 adds one pod at its NEW request ONLY when its pod template changes in this step (request changed). The old figure (every Deployment) is printed too as the safe bound.
surge = 0; surge_all = 0; rows = []
for l in lines("deploy.txt"):
    if len(l) < 4: continue
    nm = l[0].split("/", 1)[1]; ns = l[0].split("/", 1)[0]
    repl = int(l[1] or 0); typ = l[2]; ms = l[3] if len(l) >= 5 else ""
    req_old = sum(cpu(x) for x in l[-1].split(",") if x)
    req = new.get(("Deployment", nm), req_old)
    if typ == "Recreate" or repl == 0: n = 0
    elif ms == "": n = math.ceil(repl * 0.25)
    elif ms.endswith("%"): n = math.ceil(repl * int(ms[:-1]) / 100)
    else: n = int(ms)
    changed = ns == "dev-health" and ("Deployment", nm) in new and req != req_old
    if n and ns == "dev-health":
        surge_all += n * req
        if changed: surge += n * req; rows.append("%s +%d x %dm (template changes: %dm -> %dm)" % (nm, n, req, req_old, req))
    elif n: surge_all += n * req_old
burst = 0
reps = {l[0].split("/", 1)[1]: int(l[1] or 0) for l in lines("deploy.txt") if len(l) >= 4}
keda = {l[0] for l in lines("scaledobjects.txt") if len(l) == 2}
for f in ("scaledobjects.txt", "hpas.txt"):
    for l in lines(f):
        if len(l) == 2:
            if f == "hpas.txt" and l[0] in keda: continue
            extra = max(0, int(l[1]) - reps.get(l[0], 1)); req = new.get(("Deployment", l[0]), 0)
            if extra: burst += extra * req; rows.append("burst %s +%d x %dm" % (l[0], extra, req))
ds = new.get(("StatefulSet", "dev-health-ops-postgresql"), 0)
ds_live = None
for l in lines("pods.txt"):
    if len(l) >= 3 and l[0] == "dev-health/dev-health-ops-postgresql-0": ds_live = sum(cpu(x) for x in l[2].split(",") if x)
print("R6 HEADROOM (D6411/D6412, Q1=ii; mode %s): node allocatable %dm; pod CPU requests now %dm; FREE %dm" % (MODE, alloc, used, free))
for r in rows: print("   " + r)
if MODE == "img":   # image step (D6411): no request changes; each RollingUpdate Deployment named in IMG_DEPLOYS (default: the nine go worker groups; g0-vars derives it from the Deployment rows of IMGROWS-<n>.txt; "none" = a hook-only step) adds ONE surge pod at its CURRENT request while its template rolls, plus the KEDA/HPA burst. Prints FREE and the need; like `app` it exits 0 (a Pending surge pod is judged by ROLL appcheck, STOP after 10 min).
    import os
    names = set((os.environ.get("IMG_DEPLOYS") or ",".join("dev-health-ops-go-" + g for g in ("heavy", "ops", "sync", "sync-provider", "scheduler", "reconciler", "stream-ingest", "stream-external", "stream-pagerduty"))).split(","))
    if names == {"none"}: names = set()
    isurge = 0; seen_names = set()
    for l in lines("deploy.txt"):
        if len(l) < 4 or not l[0].startswith("dev-health/"): continue
        nm = l[0].split("/", 1)[1]
        if nm not in names: continue
        seen_names.add(nm); repl = int(l[1] or 0); typ = l[2]; ms = l[3] if len(l) >= 5 else ""
        req = new.get(("Deployment", nm), sum(cpu(x) for x in l[-1].split(",") if x))
        if typ == "Recreate" or repl == 0: n = 0
        elif ms == "": n = math.ceil(repl * 0.25)
        elif ms.endswith("%"): n = math.ceil(repl * int(ms[:-1]) / 100)
        else: n = int(ms)
        if n: isurge += n * req; print("   %s surge +%d x %dm" % (nm, n, req))
    if names - seen_names: print("HEADROOM: FAIL (Deployment(s) named in IMG_DEPLOYS are not in the deploy block: %s; STOP, nothing computed)" % sorted(names - seen_names)); sys.exit(1)
    need = isurge + burst
    print("IMG-STEP ARITHMETIC (mode img): FREE %dm; need = surge of the rolled Deployments at their current requests %dm + KEDA/HPA burst %dm = %dm" % (free, isurge, burst, need))
    print("IMG-STEP %s: %s" % ("WITHIN" if free >= need else "OVER (short %dm)" % (need - free), "no Pending surge pod expected" if free >= need else "a Pending surge pod is NOT a STOP for up to 10 min; STOP after 10 min, or at once if any data-store pod is not Ready (ROLL appcheck)"))
    sys.exit(0)
if MODE == "app":
    worst = used + surge + burst; safe = used + surge_all + burst
    print("APP-STEP ARITHMETIC: old steady %dm + surge of the Deployments whose pod template changes, at NEW requests %dm + KEDA/HPA burst %dm = worst %dm of %dm" % (used, surge, burst, worst, alloc))
    print("APP-STEP SAFE BOUND (a surge pod for EVERY RollingUpdate Deployment): old steady %dm + %dm + %dm = %dm of %dm" % (used, surge_all, burst, safe, alloc))
    print("APP-STEP %s: %s" % ("WITHIN" if worst <= alloc else "OVER", "no Pending surge pod expected" if worst <= alloc else "a Pending surge pod is NOT a STOP for up to 10 min; STOP after 10 min, or at once if any data-store pod is not Ready (ROLL appcheck)"))
    sys.exit(0)
if ds_live is None: print("HEADROOM: FAIL (dev-health/dev-health-ops-postgresql-0 is not in the pods block: the live postgresql request is unknown; STOP)"); sys.exit(1)
net = ds - ds_live
need = net + burst
print("DS-STEP GATE: FREE now %dm; need = postgresql net %dm (NEW %dm - live %dm) + KEDA/HPA burst %dm = %dm" % (free, net, ds, ds_live, burst, need))
if free >= need: print("HEADROOM PASS: free %dm >= need %dm (spare %dm)" % (free, need, free - need)); sys.exit(0)
print("HEADROOM FAIL: free %dm < need %dm (short %dm): STOP, the data-store step does not start (report to main)" % (free, need, need - free)); sys.exit(1)
PY
exit $? ;;
topsnap) # ON prod, read-only (metrics-server + HPA list; names and numbers only): per-pod CPU/memory use and every HPA row (TARGETS = current%/target%). Run BEFORE the data-store step and AFTER the app step (POSTROLL readback, acp item 5). Exit 1 if either read is empty or its header is not recognised.
  export KUBECONFIG=${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}; echo "# kubectl top pods -n dev-health (pod cpu memory) $(date -u +%FT%TZ)"
  t=$(kubectl -n dev-health top pods 2>&1 | normtop); echo "$t"; echo "# hpa rows (name targets minpods maxpods replicas)"; h=$(kubectl -n dev-health get hpa 2>&1 | normhpa); echo "$h"
  [ "$(printf '%s\n' "$t" | grep -c '^top ')" -gt 0 ] && [ "$(printf '%s\n' "$h" | grep -c '^hpa ')" -gt 0 ] || { echo "TOPSNAP: FAIL (no top rows or no hpa rows parsed)"; exit 1; }
  exit 0 ;;
normtop) normtop; exit $? ;;
normhpa) normhpa; exit $? ;;
topcmp) B=${2:?before file}; A=${3:?after file}; ROLLED=${4:?rolled Deployments (comma list) or none}; MODE=${5:?first|final}
  case "$MODE" in first|final) ;; *) echo "usage: topcmp <before> <after> <rolled Deployments,...|none> first|final"; exit 2;; esac
  # v3j (pm ruling): gate ONLY the HPAs whose target Deployment was rolled (HPA name minus a leading keda-hpa-); first = a move exits 3 (RECHECK), final = a move is FAIL
  python3 -I - "$B" "$A" "$ROLLED" "$MODE" <<'PY'
import sys, re
def rd(f):
    top, hpa = {}, {}
    for l in open(f):
        w = l.split()
        if w[:1] == ["top"] and len(w) == 4: top[w[1]] = (w[2], w[3])
        if w[:1] == ["hpa"] and len(w) >= 3: hpa[w[1]] = w[2]
    return top, hpa
tb, hb = rd(sys.argv[1]); ta, ha = rd(sys.argv[2]); bad = []; moved = []; notes = []
rolled = set() if sys.argv[3] == "none" else set(x for x in sys.argv[3].split(",") if x); mode = sys.argv[4]
def pct(t):
    m = re.match(r"(\d+)%/(\d+)%", t or ""); return (int(m.group(1)), int(m.group(2))) if m else None
if not any("web" in n for n in hb) or not any("web" in n for n in ha): bad.append("no web HPA row in the before/after file")
for n in sorted(set(hb) | set(ha)):
    b, a = pct(hb.get(n)), pct(ha.get(n)); print("HPA %s TARGETS before %s after %s" % (n, hb.get(n), ha.get(n)))
    d = n[len("keda-hpa-"):] if n.startswith("keda-hpa-") else n
    if d not in rolled:
        notes.append("%s not rolled: %s (no gate)" % (n, "current%% %d%% -> %d%%" % (b[0], a[0]) if b and a else "TARGETS %s -> %s" % (hb.get(n), ha.get(n))))
    elif not b or not a:
        if "web" in n: bad.append("%s: HPA TARGETS unreadable (before %s, after %s)" % (n, hb.get(n), ha.get(n)))
        else: notes.append("%s rolled: TARGETS %s -> %s unreadable (KEDA row, no gate)" % (n, hb.get(n), ha.get(n)))
    elif abs(a[0] - b[0]) > 5 or a[0] >= a[1] * 0.7: moved.append("%s: HPA current%% moved %d%% -> %d%% (limit: unchanged within 5 points and below 70%% of the %d%% target)" % (n, b[0], a[0], a[1]))
for p in sorted(set(tb) | set(ta)): print("TOP %-48s before %-12s after %s" % (p, " ".join(tb.get(p, ("-", "-"))), " ".join(ta.get(p, ("-", "-")))))
[print("  NOTE: " + x) for x in notes]
if mode == "final": bad += moved
if bad: print("TOPCMP: FAIL (sample %s)" % ("2" if mode == "final" else "1")); [print("  FAIL: " + x) for x in bad]; sys.exit(1)
if moved: [print("  MOVED: " + x) for x in moved]; print("TOPCMP: RECHECK (%d rolled HPA(s) moved on sample 1; sample 2 decides)" % len(moved)); sys.exit(3)
print("TOPCMP: PASS (rolled HPA current%% unchanged%s; %d HPA(s) not rolled, not gated)" % (" on sample 2" if mode == "final" else "", sum(1 for x in notes if " not rolled: " in x))); sys.exit(0)
PY
  exit $? ;;
*) echo "usage: table | case <collect file> | collect | compute <collect file> <render.yaml> app|ds|img | topsnap | topcmp <before> <after> <rolled Deployments,...|none> first|final | normtop | normhpa (stdin)"; exit 2;;
esac
