#!/usr/bin/env bash
# READBACK-IMG.sh (image steps of the standard roll tool). READ-ONLY readbacks of an image roll. Names, versions and counts only; never a DSN, Secret or env value (D6331, D6233).
#   ON prod:  ssh prod 'bash -s -- migjoblog read' < READBACK-IMG.sh      after the step: reads the log LOGWATCH-24d.sh start captured, parses it
#             ssh prod 'bash -s -- migjoblog' < READBACK-IMG.sh | tee $KIT/out/img/migjoblog.out        run BEFORE the step-7 deploy returns: follows job/dev-health-ops-migrate (deleted on success), full log to a 0600 file on prod, prints the applied lists
#             ssh prod 'bash -s -- pgver 0066,0160' < READBACK-IMG.sh                                          Postgres alembic_version rows (in-cluster postgres pod, BEGIN READ ONLY, the standing prod Postgres form); the argument is a head SET rev[,rev...], PASS iff the set of rows equals it (order-free; prod has two heads)
#             ssh prod 'CHCOLS_RULING=<id> bash -s -- chcols status [deployment]' < READBACK-IMG.sh       ClickHouse schema_migrations readback through `dho migrate clickhouse status` run in a running pod that already holds CLICKHOUSE_URI. GATED: refuses without CHCOLS_RULING (fcc/acp ruling id) because a pod exec for ClickHouse is not covered by a standing permission. It does NOT read columns: there is no SQL route (see the lane DRAFT).
#             ssh prod 'IMGROWS=<rows> [CMDELTA=<cm key b64>] bash -s -- liverows' < READBACK-IMG.sh   the live Deployment fields of the step's rows (new values) and, with CMDELTA, the live ConfigMap lines (new state), read-only
#             ssh prod "CMDELTA='<cm key b64>' bash -s -- cmdelta new|old" < READBACK-IMG.sh   the live ConfigMap lines of a #CMDELTA step only: new = every + line present, every - line absent; old = the reverse (after a rollback)
#             ssh prod 'bash -s -- pgobjects <index,...|-> <table.column,...|->' < READBACK-IMG.sh   read-only: the index present with indisvalid AND indisready, the column present (INVALID = STOP)
#             ssh prod 'bash -s -- idxjoblog read <job> <index> [<attempts>]' < READBACK-IMG.sh   the captured build-index Job log: result valid, attempts used <= 1, 0 lock_timeout (55P03) failures, no INVALID index left, no error line
#             ssh prod 'bash -s -- pgxactage <max s>' < READBACK-IMG.sh   read-only PRE-GATE: the oldest open transaction age (exit 3 = WAIT and re-read, do not start)
#   LOCAL:    migparse <log file> | pgparse <psql output file> <expected> | chparse <status.json> [expect-head <version>] [expect-applied <n>]
set -u
K="kubectl -n dev-health"; export KUBECONFIG=${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}
W=${W:-$HOME/lane-prod-k8s/img}
PGPOD=dev-health-ops-postgresql-0
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
migparse() { # prints the applied lists of the migrate Job log; exit 1 on a step error line or when neither result line is present
  python3 -I - "$1" <<'PY'
import sys, json
pg = ch = None; errs = 0
for l in open(sys.argv[1], errors="replace"):
    l = l.strip()
    if not l.startswith("{"): continue
    try: d = json.loads(l)
    except ValueError: continue
    if not isinstance(d, dict): continue
    if isinstance(d.get("partial"), dict): part = d["partial"]; print("MIGJOBLOG clickhouse PARTIAL (a failed run) action=%s applied=%s head=%s" % (part.get("action"), json.dumps(part.get("applied", [])), part.get("head"))); continue
    if isinstance(d.get("error"), dict): errs += 1; print("MIGJOBLOG ERROR code=%s" % str(d["error"].get("code"))[:60]); continue
    if "heads" in d and "action" in d: pg = d
    elif "operational_ordering_contract" in d and "head" in d and "action" in d: ch = d
    elif str(d.get("level", "")).upper() == "ERROR": errs += 1; print("MIGJOBLOG ERROR log line (level ERROR)")
if pg is not None: print("MIGJOBLOG postgres action=%s applied=%s heads=%s" % (pg.get("action"), json.dumps(pg.get("applied", [])), json.dumps(pg.get("heads"))))
if ch is not None: print("MIGJOBLOG clickhouse action=%s applied=%s head=%s" % (ch.get("action"), json.dumps(ch.get("applied", [])), ch.get("head")))
if pg is None or ch is None: print("MIGJOBLOG INCOMPLETE: %s result line missing" % ("postgres" if pg is None else "clickhouse")); sys.exit(1)
sys.exit(1 if errs else 0)
PY
}
pgparse() { # $1 = file with the psql -At output of `SELECT version_num FROM alembic_version`, $2 = the expected head SET `rev[,rev...]` (order-free): PASS iff the set of version_num rows equals it
  case "$2" in ""|*[!0-9a-z_,]*|,*|*,|*,,*) echo "PGVER: usage: expected revisions must be rev[,rev...] ([0-9a-z_]+)"; return 2;; esac
  v=$(grep -E '^[0-9a-z_]+$' "$1" 2>/dev/null | sort -u | paste -sd, -); w=$(printf '%s\n' "$2" | tr ',' '\n' | sort -u | paste -sd, -)
  [ -n "$v" ] || { echo "PGVER FAIL: no alembic_version row read"; return 1; }
  echo "PGVER alembic_version rows={$v} (want {$w})"; [ "$v" = "$w" ] && { echo "PGVER: PASS"; return 0; }
  miss=$(comm -13 <(printf '%s\n' "$v" | tr ',' '\n') <(printf '%s\n' "$w" | tr ',' '\n') | paste -sd, -); extra=$(comm -23 <(printf '%s\n' "$v" | tr ',' '\n') <(printf '%s\n' "$w" | tr ',' '\n') | paste -sd, -)
  echo "PGVER: FAIL (missing {${miss:-}} extra {${extra:-}})"; return 1
}
pgobparse() { # $1 = psql -At output of the pgobjects queries (IDX|name|t|t, COL|table.column|count), $2 = indexes a,b (or -), $3 = columns t.c,... (or -): PASS iff every index exists with indisvalid AND indisready true and every column exists. INVALID = STOP (pm decides drop + rebuild: a later CREATE INDEX IF NOT EXISTS skips an INVALID index silently)
  python3 -I - "$1" "$2" "$3" <<'PY'
import sys
rows = [l.strip().split("|") for l in open(sys.argv[1]) if l.startswith(("IDX|", "COL|"))]
idx = {r[1]: r for r in rows if r[0] == "IDX" and len(r) == 4}; col = {r[1]: r[2] for r in rows if r[0] == "COL" and len(r) == 3}
bad = []
for n in [x for x in sys.argv[2].split(",") if x and x != "-"]:
    r = idx.get(n)
    if not r: print("PGOBJ index %s: ABSENT" % n); bad.append(n); continue
    print("PGOBJ index %s: present indisvalid=%s indisready=%s" % (n, r[2], r[3]))
    if r[2] != "t" or r[3] != "t": print("PGOBJ index %s INVALID or not ready: STOP (pm decides drop + rebuild)" % n); bad.append(n)
for c in [x for x in sys.argv[3].split(",") if x and x != "-"]:
    k = col.get(c, "0"); print("PGOBJ column %s: %s" % (c, "present" if k == "1" else "ABSENT"))
    if k != "1": bad.append(c)
print("PGOBJECTS: " + ("PASS" if not bad else "FAIL (%s)" % ",".join(bad))); sys.exit(0 if not bad else 1)
PY
}
idxparse() { # $1 = a build-index Job log (JSON lines: slog on stderr + the result on stdout), $2 = the index, $3 = the Job's --attempts (optional, for the print): PASS iff a result line names the index with valid=true (action built|rebuilt|present), it used at most 1 attempt, no attempt failed on lock_timeout (SQLSTATE 55P03 = a lock wait over --lock-timeout), no INVALID index was left by a failed attempt, and no error line
  python3 -I - "$1" "$2" "${3:-?}" <<'PY'
import sys, json
res = None; failed = lockto = blockers = waits = errs = invleft = 0
for l in open(sys.argv[1], errors="replace"):
    l = l.strip()
    if not l.startswith("{"): continue
    try: d = json.loads(l)
    except ValueError: continue
    if not isinstance(d, dict): continue
    if isinstance(d.get("error"), dict): errs += 1; print("IDXJOBLOG ERROR code=%s" % str(d["error"].get("code"))[:60]); continue
    if d.get("index") == sys.argv[2] and "valid" in d and "action" in d: res = d; continue
    m = str(d.get("msg", ""))
    if m == "build-index: attempt failed":
        failed += 1
        if d.get("sqlstate") == "55P03": lockto += 1
    elif m == "build-index: blocker": blockers += 1
    elif m == "build-index: waiting": waits += 1
    elif m.startswith("build-index: invalid index left"): invleft += 1
    if str(d.get("level", "")).upper() == "ERROR": errs += 1
if res is None: print("IDXJOBLOG INCOMPLETE: no result line for %s" % sys.argv[2])
else: print("IDXJOBLOG %s action=%s attempts=%s valid=%s" % (res.get("index"), res.get("action"), res.get("attempts"), res.get("valid")))
used = res.get("attempts") if res is not None and isinstance(res.get("attempts"), int) else None
print("IDXJOBLOG attempts used %s of %s (1 expected)" % ("?" if used is None else used, sys.argv[3]))
print("IDXJOBLOG failed attempts %d (lock_timeout 55P03: %d), INVALID index left %d, blocker lines %d, waiting lines %d, error lines %d" % (failed, lockto, invleft, blockers, waits, errs))
if invleft: print("IDXJOBLOG: an INVALID index was left after a failed attempt: STOP (pm decides drop + rebuild)")
ok = res is not None and res.get("valid") is True and res.get("action") in ("built", "rebuilt", "present") and used is not None and used <= 1 and lockto == 0 and invleft == 0 and errs == 0
print("IDXJOBLOG: " + ("PASS" if ok else "FAIL")); sys.exit(0 if ok else 1)
PY
}
xactparse() { # $1 = psql -At output with one `XACT|<age s>|<count>|<backend type>` row, $2 = the max age in s: exit 0 (GO) iff the oldest open transaction is <= $2 s old, exit 3 (WAIT: wait and re-read, not START) when older, exit 1 when no row was read
  r=$(grep -m1 '^XACT|' "$1" 2>/dev/null); IFS='|' read -r _ age cnt bt <<< "$r"
  case "$age|$cnt" in ""|*[!0-9\|]*|"|"*|*"|") echo "PGXACTAGE FAIL: no readable XACT row"; return 1;; esac
  case "$bt" in *[!A-Za-z0-9\ _-]*) bt="?";; esac
  echo "PGXACTAGE oldest open transaction ${age}s (open transactions $cnt, oldest backend type ${bt:--}); max ${2}s"
  if [ "$age" -le "$2" ]; then echo "PGXACTAGE: GO"; return 0; fi
  echo "PGXACTAGE: WAIT (older than ${2}s: wait and re-read this line; do NOT start)"; return 3
}
chparse() { # $1 = status JSON file (one line), then optional `expect-head <v>` / `expect-applied <n>`
  f=$1; shift
  python3 -I - "$f" "$@" <<'PY'
import sys, json
try: d = json.loads(open(sys.argv[1]).read().strip().splitlines()[-1])
except (OSError, ValueError, IndexError): print("CHCOLS FAIL: no status JSON line in %s" % sys.argv[1]); sys.exit(1)
bad = []
print("CHCOLS status state=%s head=%s applied=%s pending=%s missing=%s" % (d.get("state"), d.get("head"), d.get("applied"), json.dumps(d.get("pending", [])), json.dumps(d.get("missing", []))))
if d.get("state") != "at_head": bad.append("state is not at_head")
a = sys.argv[2:]
while a:
    k, v = a[0], a[1] if len(a) > 1 else ""; a = a[2:]
    if k == "expect-head" and d.get("head") != v: bad.append("head %s != %s" % (d.get("head"), v))
    elif k == "expect-applied" and str(d.get("applied")) != v: bad.append("applied %s != %s" % (d.get("applied"), v))
    elif k not in ("expect-head", "expect-applied"): bad.append("unknown option %s" % k)
if d.get("pending"): bad.append("pending is not empty")
print("CHCOLS: " + ("PASS" if not bad else "FAIL (" + "; ".join(bad) + ")")); sys.exit(0 if not bad else 1)
PY
}
case "${1:-}" in
migparse) migparse "${2:?log file}"; exit $? ;;
pgparse) pgparse "${2:?psql output file}" "${3:-}"; exit $? ;;
chparse) f=${2:?status json file}; shift 2; chparse "$f" "$@"; exit $? ;;
migjoblog) if [ "${2:-}" = read ]; then # read the log LOGWATCH-24d.sh start captured (the Job is deleted on success): copy it into $W (0600) and parse it
    umask 077; mkdir -p "$W"; chmod 700 "$W"; src=${LOGWATCH_DIR:-$HOME/lane-prod-k8s/logwatch-24d}/dev-health-ops-migrate.log
    [ -s "$src" ] || { echo "MIGJOBLOG STOP: no captured log $src (LOGWATCH start was not run before the deploy)"; exit 3; }
    cp "$src" "$W/migjob.log"; echo "MIGJOBLOG captured log: $(grep -c . "$W/migjob.log") lines (copy $W/migjob.log, 0600)"; migparse "$W/migjob.log"; exit $?
  fi
  # follow the migrate hook Job log (bounded); the Job is deleted on hook success, so this runs while step 7 deploys. Env MIGLOG_START (s to wait for the Job, default 180), MIGLOG_MAX (s to follow, default 540).
  umask 077; mkdir -p "$W"; chmod 700 "$W"; L=$W/migjob.log; : > "$L"
  end=$(( $(date +%s) + ${MIGLOG_START:-180} )); until $K get job dev-health-ops-migrate -o name >/dev/null 2>&1; do [ "$(date +%s)" -ge "$end" ] && { echo "MIGJOBLOG STOP: job/dev-health-ops-migrate did not appear within ${MIGLOG_START:-180}s (start this verb BEFORE the deploy)"; exit 3; }; sleep ${MIGLOG_STEP:-2}; done
  echo "MIGJOBLOG following job/dev-health-ops-migrate (full log: $L, 0600, on prod)"
  timeout ${MIGLOG_MAX:-540} $K logs -f job/dev-health-ops-migrate --all-containers >> "$L" 2>/dev/null
  echo "MIGJOBLOG log lines: $(grep -c . "$L")"; migparse "$L"; exit $? ;;
idxparse) idxparse "${2:?log file}" "${3:?index}" "${4:-}"; exit $? ;;
xactparse) xactparse "${2:?psql output file}" "${3:?max seconds}"; exit $? ;;
pgxactage) mx=${2:-}; case "$mx" in ""|*[!0-9]*) echo "PGXACTAGE: usage: pgxactage <max seconds>"; exit 2;; esac   # read-only PRE-GATE right before a deploy: the age of the oldest open transaction (pg_stat_activity, state != idle, not this session); prints the age, the count and the backend type only, never a query text
  t=$(mktemp); out=$(printf 'BEGIN READ ONLY;\n%s\nROLLBACK;\n' "SELECT 'XACT|' || coalesce(max(extract(epoch FROM (now() - xact_start)))::bigint, 0) || '|' || count(*) || '|' || coalesce((SELECT backend_type FROM pg_stat_activity WHERE state IS DISTINCT FROM 'idle' AND xact_start IS NOT NULL AND pid <> pg_backend_pid() ORDER BY xact_start LIMIT 1), '-') FROM pg_stat_activity WHERE state IS DISTINCT FROM 'idle' AND xact_start IS NOT NULL AND pid <> pg_backend_pid();" | $K exec -i $PGPOD -- sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -X -q -v ON_ERROR_STOP=1 -h 127.0.0.1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -At' 2>/dev/null) || { rm -f "$t"; echo "PGXACTAGE STOP: the read-only query failed"; exit 1; }
  printf '%s\n' "$out" > "$t"; xactparse "$t" "$mx"; rc=$?; rm -f "$t"; exit $rc ;;
pgobparse) pgobparse "${2:?psql output file}" "${3:--}" "${4:--}"; exit $? ;;
idxjoblog) [ "${2:-}" = read ] || { echo "idxjoblog: usage: idxjoblog read <job> <index> [<attempts>]"; exit 2; }; job=${3:-}; ix=${4:-}; case "$job" in ""|*[!a-z0-9-]*) echo "IDXJOBLOG: bad job name"; exit 2;; esac; case "$ix" in ""|*[!a-z0-9_]*) echo "IDXJOBLOG: bad index name"; exit 2;; esac   # the log of a build-index hook Job (deleted on success) captured by LOGWATCH, which must start before the deploy
  umask 077; mkdir -p "$W"; chmod 700 "$W"; src=${LOGWATCH_DIR:-$HOME/lane-prod-k8s/logwatch-24d}/$job.log
  [ -s "$src" ] || { echo "IDXJOBLOG STOP: no captured log $src (LOGWATCH start was not run before the deploy)"; exit 3; }
  na=${5:-}; case "$na" in *[!0-9]*) echo "IDXJOBLOG: bad attempts number"; exit 2;; esac
  cp "$src" "$W/$job.log"; echo "IDXJOBLOG captured log: $(grep -c . "$W/$job.log") lines (copy $W/$job.log, 0600)"; idxparse "$W/$job.log" "$ix" "$na"; exit $? ;;
pgobjects) ixs=${2:--}; cols=${3:--}   # read-only: `pgobjects <index[,index]|-> <table.column[,...]|->` in the in-cluster postgres pod (BEGIN READ ONLY, the pgver form; no DSN printed)
  case "$ixs" in -) ;; *[!a-z0-9_,]*|,*|*,|*,,*) echo "PGOBJECTS: bad index list"; exit 2;; esac; case "$cols" in -) ;; *[!a-z0-9_.,]*|,*|*,|*,,*) echo "PGOBJECTS: bad column list"; exit 2;; esac
  [ "$ixs$cols" != "--" ] || { echo "PGOBJECTS: nothing to read"; exit 2; }
  q=''; for n in ${ixs//,/ }; do [ "$n" = - ] && continue; q="$q SELECT 'IDX|' || c.relname || '|' || left(i.indisvalid::text, 1) || '|' || left(i.indisready::text, 1) FROM pg_catalog.pg_class c JOIN pg_catalog.pg_index i ON i.indexrelid = c.oid WHERE c.relnamespace = 'public'::regnamespace AND c.relname = '$n';"; done
  for tc in ${cols//,/ }; do [ "$tc" = - ] && continue; case "$tc" in *.*.*|.*|*.) echo "PGOBJECTS: bad column $tc"; exit 2;; *.*) ;; *) echo "PGOBJECTS: bad column $tc"; exit 2;; esac; q="$q SELECT 'COL|$tc|' || count(*) FROM information_schema.columns WHERE table_schema = 'public' AND table_name = '${tc%%.*}' AND column_name = '${tc#*.}';"; done
  t=$(mktemp); out=$(printf 'BEGIN READ ONLY;\n%s\nROLLBACK;\n' "$q" | $K exec -i $PGPOD -- sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -X -q -v ON_ERROR_STOP=1 -h 127.0.0.1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -At' 2>/dev/null) || { rm -f "$t"; echo "PGOBJECTS STOP: the read-only query failed"; exit 1; }
  printf '%s\n' "$out" > "$t"; pgobparse "$t" "$ixs" "$cols"; rc=$?; rm -f "$t"; exit $rc ;;
pgver) exp=${2:?expected alembic head set, e.g. 0066,0160}
  case "$exp" in ""|*[!0-9a-z_,]*|,*|*,|*,,*) echo "PGVER: bad revision argument"; exit 2;; esac
  t=$(mktemp); out=$(printf 'BEGIN READ ONLY;\nSELECT version_num FROM alembic_version;\nROLLBACK;\n' | $K exec -i $PGPOD -- sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -X -q -v ON_ERROR_STOP=1 -h 127.0.0.1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -At' 2>/dev/null) || { rm -f "$t"; echo "PGVER STOP: the read-only query failed"; exit 1; }
  printf '%s\n' "$out" > "$t"; pgparse "$t" "$exp"; rc=$?; rm -f "$t"; exit $rc ;;
liverows) # the live objects against the data: for every Deployment/StatefulSet row of IMGROWS (env IMGROWS, rows joined by ";") read the field from the live object (kubectl jsonpath of that ONE field) and compare it with the row's NEW value (an image field: contains @sha256:<new prefix>; `<none>` = the field must be absent). Read-only; only names, paths and values of the listed fields print. Exit 1 on any mismatch or when the file has no such row.
  [ -n "${IMGROWS:-}${CMDELTA:-}" ] || { echo "LIVEROWS STOP: IMGROWS is empty (source g0-vars for the step)"; exit 2; }
  n=0; bad=0
  while IFS= read -r row; do [ -n "$row" ] || continue; read -r obj path old new _rest <<< "$row"; kind=${obj%%/*}; name=${obj#*/}
    case "$kind" in Deployment) res=deploy;; StatefulSet) res=sts;; *) continue;; esac
    case "$name" in *[!a-z0-9-]*|"") echo "LIVEROWS STOP: bad object name in row '$row'"; exit 2;; esac; case "$path" in .*) ;; *) echo "LIVEROWS STOP: bad path in row '$row'"; exit 2;; esac; case "$path" in *[!A-Za-z0-9_.\[\]]*) echo "LIVEROWS STOP: bad path in row '$row'"; exit 2;; esac
    n=$((n+1)); live=$($K get $res "$name" -o jsonpath="{$path}" 2>/dev/null) || { echo "LIVEROW FAIL $kind/$name $path: the read failed"; bad=$((bad+1)); continue; }
    case "$new" in
      "<none>") [ -z "$live" ] && echo "LIVEROW ok   $kind/$name $path absent" || { echo "LIVEROW FAIL $kind/$name $path: present, want absent"; bad=$((bad+1)); };;
      *) if printf '%s' "$new" | grep -qE '^[0-9a-f]{12,64}$' && printf '%s' "$live" | grep -q '@sha256:'; then
           case "$live" in *@sha256:"$new"*) echo "LIVEROW ok   $kind/$name $path digest ${new:0:12}";; *) echo "LIVEROW FAIL $kind/$name $path: digest is not ${new:0:12}"; bad=$((bad+1));; esac
         else [ "$live" = "$new" ] && echo "LIVEROW ok   $kind/$name $path = $new" || { echo "LIVEROW FAIL $kind/$name $path: live '$live' want '$new'"; bad=$((bad+1)); }; fi;;
    esac
  done < <(printf '%s' "$IMGROWS" | tr ';' '\n')
  if [ -n "${CMDELTA:-}" ]; then n=$((n+1)); cmdelta_check new || { echo "LIVEROW FAIL the CMDELTA ConfigMap lines are not the new state"; bad=$((bad+1)); }; fi   # a #CMDELTA step: the live ConfigMap counts as one row
  [ "$n" -gt 0 ] || { echo "LIVEROWS STOP: no Deployment/StatefulSet row in IMGROWS"; exit 1; }
  echo "LIVEROWS: $([ "$bad" = 0 ] && echo PASS || echo FAIL) ($n rows read, $bad mismatched)"; [ "$bad" = 0 ]; exit $? ;;
cmdelta) case "${2:-}" in new|old) cmdelta_check "$2"; rc=$?; echo "CMDELTA: $([ $rc = 0 ] && echo PASS || echo FAIL) ($2 state)"; exit $rc;; *) echo "cmdelta: usage: cmdelta new|old (env CMDELTA)"; exit 2;; esac ;;
owner) # `owner <deployment> <path>`: who owns a field in the LIVE object (server-side managedFields): PASS iff a manager whose name starts with `helm` owns <path> (e.g. spec/strategy = f:spec.f:strategy). Read-only; prints manager names and operations only (the fieldsV1 is parsed, not printed).
  dep=${2:?deployment}; fp=${3:?path like spec/strategy}; case "$dep" in *[!a-z0-9-]*|"") echo "OWNER STOP: bad deployment name"; exit 2;; esac; case "$fp" in *[!A-Za-z0-9/_.]*|"") echo "OWNER STOP: bad path"; exit 2;; esac
  out=$($K get deploy "$dep" --show-managed-fields -o jsonpath='{range .metadata.managedFields[*]}{.manager}{"\t"}{.operation}{"\t"}{.fieldsV1}{"\n"}{end}' 2>/dev/null) || { echo "OWNER STOP: the read failed"; exit 1; }
  printf '%s\n' "$out" | python3 -I -c '
import sys, json
fp = sys.argv[1].split("/"); owners = []; seen = []
for l in sys.stdin:
    p = l.rstrip("\n").split("\t", 2)
    if len(p) < 3 or not p[0]: continue
    seen.append("%s(%s)" % (p[0], p[1]))
    try: d = json.loads(p[2])
    except ValueError: continue
    for k in fp:
        d = d.get("f:" + k) if isinstance(d, dict) else None
        if d is None: break
    if d is not None: owners.append("%s(%s)" % (p[0], p[1]))
print("OWNER %s: owned by %s; all managers: %s" % (sys.argv[1], ",".join(owners) or "nobody", ",".join(seen)))
ok = any(o.startswith("helm") for o in owners)
print("OWNER: " + ("PASS (helm owns it)" if ok else "FAIL (helm does not own it)")); sys.exit(0 if ok else 1)' "$fp"; exit $? ;;
poduids) # `poduids save <file>` records the pods of the release (name + uid, not Succeeded/Failed); `poduids check <file> [<deployment>[,<deployment>...]|none]` proves ZERO pod rollouts outside the listed Deployments: the set of (name, uid) of the OTHER pods now equals the saved set, every pod is Ready, their restart sum is unchanged; the pods of each listed Deployment (name <deployment>-<hash>-<id>) were ALL replaced (no saved name+uid left, same count, restarts 0). Read-only; names, uids and counts only. Before = save, after = check (norolls: no list; a rolls step: its IMG_DEPLOYS).
  umask 077; f=${3:?file}; now() { $K get pods -l app.kubernetes.io/instance=dev-health --field-selector=status.phase!=Succeeded,status.phase!=Failed -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.uid}{" "}{.status.containerStatuses[0].ready}{" "}{range .status.containerStatuses[*]}{.restartCount}{","}{end}{"\n"}{end}'; }
  case "${2:-}" in
    save) now > "$f.tmp" || { rm -f "$f.tmp"; echo "PODUIDS STOP: the read failed"; exit 1; }; [ -s "$f.tmp" ] || { rm -f "$f.tmp"; echo "PODUIDS STOP: no pod read"; exit 1; }; mv "$f.tmp" "$f"; echo "PODUIDS saved: $(grep -c . "$f") pods"; exit 0 ;;
    check) [ -s "$f" ] || { echo "PODUIDS STOP: no saved file $f (run save before the step)"; exit 2; }; t=$(mktemp); now > "$t" || { rm -f "$t"; echo "PODUIDS STOP: the read failed"; exit 1; }
      rl=${4:-none}; [ "$rl" = none ] && rl=""; case "$rl" in *[!a-z0-9,-]*) rm -f "$t"; echo "PODUIDS STOP: bad Deployment list"; exit 2;; esac
      if [ -n "$rl" ]; then re="^($(printf '%s' "$rl" | sed 's/,/|/g'))-[a-z0-9]+-[a-z0-9]+ "; rf=$(mktemp); rt=$(mktemp)
        grep -E "$re" "$f" > "$rf.r"; grep -vE "$re" "$f" > "$rf"; grep -E "$re" "$t" > "$rt.r"; grep -vE "$re" "$t" > "$rt"
        ra=$(awk '{print $1, $2}' "$rf.r" | sort); rb=$(awk '{print $1, $2}' "$rt.r" | sort); kept=$(comm -12 <(printf '%s\n' "$ra") <(printf '%s\n' "$rb") | grep -c .); nb=$(printf '%s\n' "$ra" | grep -c .); nn=$(printf '%s\n' "$rb" | grep -c .)
        rnr=$(awk '$3!="true"{k++} END{print k+0}' "$rt.r"); rrs=$(awk '{n=split($4,c,","); for(i=1;i<=n;i++) s+=c[i]} END{print s+0}' "$rt.r")
        echo "PODUIDS rolled Deployments $rl: pods before $nb, now $nn, kept (not replaced) $kept, not Ready $rnr, restarts $rrs"
        if [ "$nb" -gt 0 ] && [ "$nn" = "$nb" ] && [ "$kept" = 0 ] && [ "$rnr" = 0 ] && [ "$rrs" = 0 ]; then echo "PODUIDS rolled: ok (every pod replaced, Ready, restarts 0)"; else echo "PODUIDS: FAIL (the pods of $rl did not all roll cleanly)"; rm -f "$t" "$rf" "$rf.r" "$rt" "$rt.r"; exit 1; fi
        trap 'rm -f "$rf"' EXIT; f=$rf; mv "$rt" "$t"; rm -f "$rf.r" "$rt.r"   # the checks below judge the OTHER pods only
      fi
      a=$(awk '{print $1, $2}' "$f" | sort); b=$(awk '{print $1, $2}' "$t" | sort); nr=$(awk '$3!="true"{k++} END{print k+0}' "$t"); rs=$(awk '{n=split($4,c,","); for(i=1;i<=n;i++) s+=c[i]} END{print s+0}' "$t"); rs0=$(awk '{n=split($4,c,","); for(i=1;i<=n;i++) s+=c[i]} END{print s+0}' "$f")
      echo "PODUIDS before $(printf '%s\n' "$a" | grep -c .) pods, now $(printf '%s\n' "$b" | grep -c .) pods; not Ready now: $nr; restart sum before $rs0 now $rs"
      if [ "$a" = "$b" ] && [ "$nr" = 0 ] && [ "$rs" = "$rs0" ]; then echo "PODUIDS: PASS (no pod replaced, all Ready, restart sum unchanged)"; rm -f "$t"; exit 0; fi
      echo "PODUIDS: FAIL (replaced or new pods: $(comm -3 <(printf '%s\n' "$a") <(printf '%s\n' "$b") | awk '{print $1}' | sort -u | paste -sd, - | cut -c1-300))"; rm -f "$t"; exit 1 ;;
    *) echo "poduids: usage: poduids save|check <file>"; exit 2 ;;
  esac ;;
chcols) # status readback only; gated
  [ "${2:-}" = status ] || { echo "chcols: usage: chcols status [deployment]"; exit 2; }
  case "${CHCOLS_RULING:-}" in "") echo "CHCOLS REFUSED: no CHCOLS_RULING (an fcc/acp ruling id). A pod exec for ClickHouse is not covered by a standing permission; nothing was run."; exit 2;; *[!A-Za-z0-9._-]*) echo "CHCOLS REFUSED: CHCOLS_RULING has a bad character"; exit 2;; esac
  dep=${3:-dev-health-ops-query-api}; case "$dep" in dev-health-ops-query-api|dev-health-ops-go-ops|dev-health-ops-go-sync|dev-health-ops-go-heavy) ;; *) echo "CHCOLS REFUSED: deployment '$dep' is not on the allowlist (query-api, go-ops, go-sync, go-heavy: they hold CLICKHOUSE_URI)"; exit 2;; esac
  t=$(mktemp); $K exec deploy/$dep -- /usr/local/bin/dho migrate clickhouse status > "$t" 2>/dev/null || { rm -f "$t"; echo "CHCOLS STOP: dho migrate clickhouse status failed in $dep (stderr dropped: it may name a DSN)"; exit 1; }
  chparse "$t" "${@:4}"; rc=$?; rm -f "$t"; exit $rc ;;
*) echo "usage: pgxactage <max s> | pgobjects <index,..|-> <table.column,..|-> | idxjoblog read <job> <index> [<attempts>] | idxparse <file> <index> [<attempts>] | xactparse <file> <max s> | pgobparse <file> <indexes> <columns> | owner <deployment> <path> | poduids save|check <file> | liverows | migjoblog | pgver <revision> | chcols status [deployment] | migparse <file> | pgparse <file> <rev> | chparse <file> [expect-head v] [expect-applied n]"; exit 2 ;;
esac
