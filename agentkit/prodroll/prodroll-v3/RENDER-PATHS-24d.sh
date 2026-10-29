#!/usr/bin/env bash
# RENDER-PATHS-24d.sh <treeA=R0 (rollback tree)> <treeB=roll tree> <app|full|s1..s6> [extra helm args for B, e.g. -f <roll-values>] — Gate 0 (roll 24d). READ-ONLY. Both trees rendered with the prod layers; Secret docs dropped IN MEMORY (D6233), hooks KEPT.
# BOTH trees are rendered with the SAME extra helm args (the roll-time values file turns the streak-index hook on in A and B alike, so no hook Job shows as a change). Every HOLD exits 1; PASS exits 0.
# Prints `Kind/name <path> CHANGED|ADDED|REMOVED` (paths + the two cpu values, never other values), then classifies each change against the HEADROOM class = EXACTLY the rows of the 24d table (workload, path, old -> new cpu REQUEST). Limits must be unchanged.
#   mode app  (treeB = TIP_APP): the app rows + the collector scrape swap (ConfigMap otel-collector config.yaml: EXACTLY the 2 removed static_configs lines and the 17 added kubernetes_sd lines, compared line by line, so a changed regex or relabel value is a HOLD; its Deployment checksum/config annotation).
#   mode i<N> (image steps, a class img row of SVC-STEPS + IMGROWS-<N>.txt): treeA = the base tree, treeB = the roll tree; PASS only if every changed field is a row of RP_IMGROWS (an #ADDDOC doc, RP_ADDDOCS, may be ADDED: its rows are checked on tree B) (an image field: old digest prefix -> new digest prefix, same repository; any other field: its exact old value -> new value, `<none>` = absent), plus RP_CMDELTA (a ConfigMap key changes by EXACTLY the listed -/+ lines) and RP_CMROLL (that Deployment's pod-template annotation changes; it must mount the ConfigMap), and nothing else differs.
#   mode s1..s6 (per-service rolls, D6415): treeA = R0, treeB = the roll tree at step N: the rows of steps 1..N only (step 1 = the collector swap + its request, 2 = query-api, 3 = auth-service, 4 = the 3 poolers, 5 = the 8 go workers, 6 = the postgresql row).
#   mode full (treeB = TIP): the app rows + the collector rows + the data-store row (StatefulSet dev-health-ops-postgresql 100m -> 400m).
# Every expected row must be present exactly once (a missing row = HOLD); anything else = UNEXPECTED => HOLD. Verdict line: RENDER PATHS: PASS | HOLD.
# ON prod: ssh prod 'bash -s -- deploy-rollback-24d deploy-roll-24d app -f /path/roll-24d-values.yaml' < RENDER-PATHS-24d.sh    LOCAL: HOME=<fakehome> bash RENDER-PATHS-24d.sh <A> <B> app|full [args]
set -u; umask 077
export KUBECONFIG=${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}; export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0='*'
A=${1:?treeA}; B=${2:?treeB}; MODE=${3:?app|full}; shift 3
tp() { case "$1" in /*) echo "$1";; *) echo "$HOME/lane-prod-k8s/$1";; esac; }
V="-f values.kiac.yaml -f values.prod.yaml -f $HOME/.config/dev-health/values.prod-secrets.yaml"
D=$(mktemp -d); trap 'shred -u $D/a.raw $D/b.raw 2>/dev/null; rm -rf $D' EXIT
(cd "$(tp $A)" && helm dependency build chart >/dev/null 2>&1; helm template dev-health chart --namespace dev-health $V "$@" 2>/dev/null) > $D/a.raw; r1=$?
(cd "$(tp $B)" && helm dependency build chart >/dev/null 2>&1; helm template dev-health chart --namespace dev-health $V "$@" 2>/dev/null) > $D/b.raw; r2=$?
[ "$r1" = 0 ] && [ "$r2" = 0 ] && [ -s $D/a.raw ] && [ -s $D/b.raw ] || { echo "RENDER PATHS: HOLD (helm template failed rc=$r1,$r2)"; exit 1; }
python3 -I - $D/a.raw $D/b.raw "$MODE" <<'PY' 2>/dev/null || { echo "(RENDER-PATHS exits 1: HOLD or parse failure)"; exit 1; }
import sys, os, re, yaml, difflib
mode = sys.argv[3]
def load(p):
    out = {}
    for d in yaml.safe_load_all(open(p)):
        if isinstance(d, dict) and d.get("kind") != "Secret": out["%s/%s" % (d.get("kind"), (d.get("metadata") or {}).get("name"))] = d
    return out
def flat(o, pre=""):
    if isinstance(o, dict):
        for k in sorted(o, key=str): yield from flat(o[k], pre + "." + str(k))
    elif isinstance(o, list):
        for i, v in enumerate(o): yield from flat(v, "%s[%d]" % (pre, i))
    else: yield pre, o
P = r"^\.spec\.template\.spec\.containers\[0\]\.resources\.requests\.cpu$"
# the HEADROOM table: object -> (old cpu request, new cpu request)
APP = {"Deployment/dev-health-ops-auth-service": ("250m", "50m"), "Deployment/dev-health-ops-query-api": ("100m", "25m"),
       "Deployment/dev-health-ops-go-ops": ("100m", "50m"), "Deployment/dev-health-ops-go-sync": ("100m", "50m"), "Deployment/dev-health-ops-go-sync-provider": ("100m", "75m"),
       "Deployment/dev-health-ops-go-scheduler": ("100m", "25m"), "Deployment/dev-health-ops-go-reconciler": ("100m", "30m"),
       "Deployment/dev-health-ops-go-stream-ingest": ("50m", "25m"), "Deployment/dev-health-ops-go-stream-external": ("50m", "25m"), "Deployment/dev-health-ops-go-stream-pagerduty": ("50m", "25m"),
       "Deployment/dev-health-ops-go-pgbouncer-transaction": ("50m", "30m"), "Deployment/dev-health-ops-go-pgbouncer-queue-session": ("50m", "30m"), "Deployment/dev-health-ops-go-pgbouncer-coordinator-session": ("50m", "30m"),
       "Deployment/dev-health-otel-collector": ("100m", "50m")}
DS = {"StatefulSet/dev-health-ops-postgresql": ("100m", "400m")}
STEPOF = {"Deployment/dev-health-otel-collector": 1, "Deployment/dev-health-ops-query-api": 2, "Deployment/dev-health-ops-auth-service": 3,
          "Deployment/dev-health-ops-go-pgbouncer-transaction": 4, "Deployment/dev-health-ops-go-pgbouncer-queue-session": 4, "Deployment/dev-health-ops-go-pgbouncer-coordinator-session": 4}
if re.fullmatch(r"i[0-9]+", mode):   # image steps (data driven, IMGROWS-<n>.txt): ONLY the listed image fields may differ, each exactly old digest prefix -> new digest prefix (RP_IMGROWS = the rows of IMGROWS-<n>.txt joined by ";": `Kind/name field-path old-prefix new-prefix`)
    spec = {}
    for r in [x.split() for x in os.environ.get("RP_IMGROWS", "").split(";") if x.strip()]:
        if len(r) != 4 or r[2] == r[3] or (r[0], r[1]) in spec: print("RENDER PATHS: HOLD (bad or duplicate row %r)" % (r,)); sys.exit(1)
        spec[(r[0], r[1])] = (r[2], r[3])
    # RP_CMDELTA = "<ConfigMap/name> <key> <base64 of the exact -/+ lines>" (g0-vars, from #CMDELTA): that data key may change by EXACTLY those diff lines (difflib n=0, compared line by line, indentation included); RP_CMROLL = "<Deployment/name> <annotation>" (from #CMROLL): that pod-template annotation must change, and the Deployment must mount the ConfigMap in both trees
    import base64
    cmd = os.environ.get("RP_CMDELTA", "").split(); cmr = os.environ.get("RP_CMROLL", "").split()
    if (cmd and (len(cmd) != 3 or not cmd[0].startswith("ConfigMap/"))) or (cmr and (len(cmr) != 2 or not cmr[0].startswith("Deployment/") or not cmd)): print("RENDER PATHS: HOLD (bad RP_CMDELTA / RP_CMROLL; a CMROLL needs a CMDELTA)"); sys.exit(1)
    cmexp = base64.b64decode(cmd[2]).decode().split("\n") if cmd else []
    cmexp = [l for l in cmexp if l != ""]
    if cmd and (not cmexp or any(l[:1] not in "-+" for l in cmexp)): print("RENDER PATHS: HOLD (RP_CMDELTA: no lines, or a line that does not start with - or +)"); sys.exit(1)
    if cmd: spec[(cmd[0], ".data." + cmd[1])] = ("<cmdelta>", "%d lines" % len(cmexp))
    if cmr: spec[(cmr[0], ".spec.template.metadata.annotations." + cmr[1])] = ("<cmroll>", "changed")
    if not spec: print("RENDER PATHS: HOLD (mode %s needs RP_IMGROWS: no expected image rows)" % mode); sys.exit(1)
    a = load(sys.argv[1]); b = load(sys.argv[2]); seen = {}; unexp = []
    # RP_ADDDOCS = "<Kind/name>[,<Kind/name>...]" (g0-vars, from #ADDDOC): that doc must be ABSENT in tree A and PRESENT in tree B; the rows naming it are checked on B only (old `<none>`; an image row = the new digest prefix, a field row = the exact new value)
    add = set(x for x in os.environ.get("RP_ADDDOCS", "").split(",") if x); seendoc = set()
    print("docs (non-Secret): A %d, B %d; mode %s; expected image rows %d; added docs expected %d" % (len(a), len(b), mode, len(spec), len(add)))
    if cmr:
        cmn = cmd[0].split("/", 1)[1]
        for t, docs in (("A", a), ("B", b)):
            vols = (((docs.get(cmr[0]) or {}).get("spec") or {}).get("template") or {}).get("spec", {}).get("volumes") or []
            if not any(((v or {}).get("configMap") or {}).get("name") == cmn for v in vols): print("RENDER PATHS: HOLD (%s in tree %s does not mount ConfigMap %s)" % (cmr[0], t, cmn)); sys.exit(1)
    def digest(v):
        m = re.fullmatch(r"([^@\s]+)@sha256:([0-9a-f]{64})", str(v)); return (m.group(1), m.group(2)) if m else None
    def nz(v): return "<none>" if v == "<none>" else ("true" if v is True else "false" if v is False else str(v))   # a non-image row names ANY field with its exact old and new value (`<none>` = the field is absent)
    for k in sorted(set(a) | set(b)):
        if k in add:
            if k in a or k not in b: print("%s (doc) [UNEXPECTED: an #ADDDOC doc must be absent in A and present in B]" % k); unexp.append(k); continue
            fb = dict(flat(b[k])); seendoc.add(k); print("%s ADDED (doc, %d fields) [ADDDOC]" % (k, len(fb)))
            for (ko, p), want in sorted(spec.items()):
                if ko != k: continue
                new = fb.get(p, "<none>"); dn = digest(new)
                if want[0] == "<none>" and dn and re.fullmatch(r"[0-9a-f]{12,64}", want[1]) and dn[1].startswith(want[1]): seen[(k, p)] = seen.get((k, p), 0) + 1; print("%s %s %s [ADDDOC IMAGE row]" % (k, p, want[1])); continue
                if want[0] == "<none>" and not dn and nz(new) == want[1]: seen[(k, p)] = seen.get((k, p), 0) + 1; print("%s %s = %s [ADDDOC FIELD row]" % (k, p, want[1])); continue
                print("%s %s [UNEXPECTED: the added doc does not hold the row's value]" % (k, p)); unexp.append("%s %s" % (k, p))
            continue
        if k not in a or k not in b: print("%s %s (doc) [UNEXPECTED]" % (k, "ADDED" if k in b else "REMOVED")); unexp.append(k); continue
        fa = dict(flat(a[k])); fb = dict(flat(b[k]))
        for p in sorted(set(fa) | set(fb)):
            old, new = fa.get(p, "<none>"), fb.get(p, "<none>")
            if old == new: continue
            want = spec.get((k, p)); do, dn = digest(old), digest(new)
            if want and want[0] == "<cmdelta>":
                dl = [l for l in difflib.unified_diff(str(old).split("\n"), str(new).split("\n"), lineterm="", n=0) if not l.startswith(("---", "+++", "@@"))]
                if old != "<none>" and new != "<none>" and dl == cmexp:
                    seen[(k, p)] = seen.get((k, p), 0) + 1; print("%s %s CHANGED [CMDELTA row: exactly the %d listed -/+ lines]" % (k, p, len(cmexp))); continue
                print("%s %s CHANGED [UNEXPECTED: the line delta is not the CMDELTA lines (%d diff lines, %d listed)]" % (k, p, len(dl), len(cmexp))); unexp.append("%s %s" % (k, p)); continue
            if want and want[0] == "<cmroll>":
                if old != "<none>" and new != "<none>":
                    seen[(k, p)] = seen.get((k, p), 0) + 1; print("%s %s CHANGED [CMROLL row: the pod-template annotation changed, the Deployment rolls]" % (k, p)); continue
                print("%s %s %s [UNEXPECTED: the CMROLL annotation must be present in both trees]" % (k, p, "ADDED" if old == "<none>" else "REMOVED")); unexp.append("%s %s" % (k, p)); continue
            if want and do and dn and do[0] == dn[0] and re.fullmatch(r"[0-9a-f]{12,64}", want[0]) and re.fullmatch(r"[0-9a-f]{12,64}", want[1]) and do[1].startswith(want[0]) and dn[1].startswith(want[1]):
                seen[(k, p)] = seen.get((k, p), 0) + 1; print("%s %s CHANGED %s -> %s [IMAGE row]" % (k, p, want[0], want[1])); continue
            if want and not do and not dn and nz(old) == want[0] and nz(new) == want[1]:
                seen[(k, p)] = seen.get((k, p), 0) + 1; print("%s %s CHANGED %s -> %s [FIELD row]" % (k, p, want[0], want[1])); continue
            print("%s %s CHANGED [UNEXPECTED]" % (k, p)); unexp.append("%s %s" % (k, p))
    miss = sorted("%s %s" % kp for kp in set(spec) - set(seen)) + sorted("%s (doc)" % d for d in add - seendoc); dup = sorted("%s %s" % kp for kp, v in seen.items() if v != 1)
    print("expected image rows seen %d of %d; missing %s; duplicated %s; UNEXPECTED: %d" % (len(seen), len(spec), miss, dup, len(unexp)))
    ok = not unexp and not miss and not dup
    print("RENDER PATHS: " + ("PASS" if ok else "HOLD")); sys.exit(0 if ok else 1)
rows = dict(APP)
if re.fullmatch(r"s[1-6]", mode):   # per-service roll (D6415): R0 tree vs the roll tree at step N = the rows of steps 1..N (the collector swap is step 1)
    N = int(mode[1:]); B0 = int(os.environ.get("RP_BASE_STEP", "1") or 1)   # RP_BASE_STEP=2: the base tree already holds step 1 (per-service rolls on main 7696a9f7), so only steps 2..N are expected, and the collector swap is NOT
    DEF = set(int(x) for x in os.environ.get("DEFER_STEPS", "").split(",") if x.strip())   # deferred steps: their rows are NOT expected
    rows = {k: v for k, v in APP.items() if B0 <= STEPOF.get(k, 5) <= N and STEPOF.get(k, 5) not in DEF}
    if N == 6: rows.update(DS)
elif mode == "full": rows.update(DS)
elif mode != "app": print("RENDER PATHS: HOLD (mode must be app|full|s1..s6|i<img step>)"); sys.exit(1)
seen = {}; unexp = []
try:
    a = load(sys.argv[1]); b = load(sys.argv[2])
    print("docs (non-Secret): A %d, B %d; mode %s" % (len(a), len(b), mode))
    for k in sorted(set(a) | set(b)):
        if k not in a or k not in b: print("%s %s (doc) [UNEXPECTED]" % (k, "ADDED" if k in b else "REMOVED")); unexp.append(k); continue
        fa = dict(flat(a[k])); fb = dict(flat(b[k]))
        for p in sorted(set(fa) | set(fb)):
            if fa.get(p, "<none>") == fb.get(p, "<none>"): continue
            old, new = fa.get(p, "<none>"), fb.get(p, "<none>")
            if re.match(P, p) and k in rows and (old, new) == rows[k]:
                seen[k] = seen.get(k, 0) + 1; print("%s %s CHANGED %s -> %s [HEADROOM row]" % (k, p, old, new)); continue
            if k == "Deployment/dev-health-otel-collector" and p == ".spec.template.metadata.annotations.checksum/config": print("%s %s CHANGED [HEADROOM row: collector config checksum]" % (k, p)); continue
            if k == "ConfigMap/dev-health-otel-collector" and p == ".data.config.yaml":
                rm = [l[1:].strip() for l in difflib.unified_diff(str(old).split("\n"), str(new).split("\n"), lineterm="", n=0) if l.startswith("-") and not l.startswith("---")]
                ad = [l[1:].strip() for l in difflib.unified_diff(str(old).split("\n"), str(new).split("\n"), lineterm="", n=0) if l.startswith("+") and not l.startswith("+++")]
                EXP_RM = ["static_configs:", "- targets: [\"dev-health-ops-auth-service.dev-health.svc:8096\"]"]
                EXP_AD = ["kubernetes_sd_configs:", "- role: pod", "namespaces:", "names: [\"dev-health\"]", "relabel_configs:",
                          "- source_labels: [__meta_kubernetes_pod_label_app_kubernetes_io_component]", "action: keep", "regex: auth-service",
                          "- source_labels: [__meta_kubernetes_pod_label_app_kubernetes_io_instance]", "action: keep", "regex: \"dev-health\"",
                          "- source_labels: [__meta_kubernetes_pod_container_port_number]", "action: keep", "regex: \"8096\"",
                          "- source_labels: [__meta_kubernetes_pod_phase]", "action: keep", "regex: Running"]
                okrm = rm == EXP_RM
                okad = ad == EXP_AD
                if okrm and okad: seen["collector-scrape"] = 1; print("%s %s CHANGED [HEADROOM row: auth-service scrape static_configs -> kubernetes_sd pod role]" % (k, p)); continue
            print("%s %s CHANGED %s -> %s [UNEXPECTED]" % (k, p, old if re.search(r"cpu$", p) else "<value>", new if re.search(r"cpu$", p) else "<value>")); unexp.append("%s %s" % (k, p))
    miss = sorted(set(rows) - set(seen)) + ([] if ("collector-scrape" in seen or (re.fullmatch(r"s[1-6]", mode) and int(os.environ.get("RP_BASE_STEP", "1") or 1) >= 2)) else ["collector-scrape"])
    dup = sorted(k for k, v in seen.items() if v != 1)
    print("expected rows seen %d of %d; missing %s; duplicated %s; UNEXPECTED: %d" % (len(seen), len(rows) + (0 if (re.fullmatch(r"s[1-6]", mode) and int(os.environ.get("RP_BASE_STEP", "1") or 1) >= 2) else 1), miss, dup, len(unexp)))
    ok = not unexp and not miss and not dup
    print("RENDER PATHS: " + ("PASS" if ok else "HOLD"))
    sys.exit(0 if ok else 1)
except SystemExit:
    raise
except Exception as x:
    print("RENDER PATHS: HOLD (" + type(x).__name__ + ")")
    sys.exit(1)
PY
