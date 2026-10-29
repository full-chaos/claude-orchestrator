#!/usr/bin/env bash
# POSTROLL-24d.sh <pre|scrape|scrapecheck|sched> — roll 24d reads. READ-ONLY, counts/digests/names only (never a log line; no exec, no Secret).
# run ON prod: ssh prod 'SINCE=6h bash -s -- pre' < POSTROLL-24d.sh
#  pre     before the roll: workloads Ready/restarts/image digest(12).
#  sched   LOCAL verb (no prod): `bash POSTROLL-24d.sh sched <at-T0.txt> <after.txt> [attempt 1|2]` = the POSITIVE scheduler occurrence proof (SCHED-PROOF-24d.sh check): sync_scheduler_occurrences_completed_total (ops loop.go:638) rose after T0, windows (loop.go:630) rose, failures (loop.go:634) did not; the go-scheduler request is cut 100m -> 25m, so this proves the scheduler still completes a scheduled occurrence. Exit 0 PASS, 3 NO-INCREMENT, 1 FAIL.
#  scrape  CHAOS-11614 readback, kubectl half (ON prod; exit 1 on a miss): collector Ready, EXACTLY 2 auth-service pods Running with port 8096 and 2 distinct pod IPs.
#  scrapecheck  LOCAL: compares the SCRAPE-POD lines with the series file the lead fills from SigNoz (2 runtime_info series, distinct instance labels = the pod IPs:8096).
export KUBECONFIG=${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}; NS=dev-health; K="kubectl -n $NS"; M=${1:?pre|scrape|scrapecheck|sched}
# D6331 helpers (24d): jsonpath of ONLY the needed fields, never -o json of pods/deploys/ingresses (acp item 8)
pj_lines() { $K get pods ${1:+-l "$1"} -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.phase}{" "}{.metadata.deletionTimestamp}{"|"}{range .status.containerStatuses[*]}{.ready}{"~"}{.restartCount}{"~"}{.imageID}{" "}{end}{"\n"}{end}' 2>/dev/null; }
pj_ing_auth() { $K get ingress -o jsonpath='{range .items[*].spec.rules[*].http.paths[*]}{.backend.service.name}{"\n"}{end}' 2>/dev/null | grep -c 'auth-service'; }
pj_not_ready() { pj_lines "$1" | awk '{split($0,p,"|"); split(p[1],h," "); if (h[2]=="Succeeded" || (EXC!="" && h[2]==EXC)) next; if (NODEL && length(h)>=3) next; n=split(p[2],c," "); for(i=1;i<=n;i++){split(c[i],a,"~"); if(a[1]=="false"){k++; break}}} END{print k+0}' EXC="${2:-}" NODEL="${3:-}"; }
pj_restart_pods() { pj_lines "$1" | awk '{split($0,p,"|"); n=split(p[2],c," "); for(i=1;i<=n;i++){split(c[i],a,"~"); if(a[2]+0>0){k++; break}}} END{print k+0}'; }
pj_restart_sum() { pj_lines "$1" | awk '{split($0,p,"|"); split(p[1],h," "); if (length(h)>=3) next; n=split(p[2],c," "); for(i=1;i<=n;i++){split(c[i],a,"~"); s+=a[2]}} END{print s+0}'; }
pj_digests() { pj_lines "$1" | awk '{split($0,p,"|"); split(p[1],h," "); if (length(h)>=3) next; n=split(p[2],c," "); for(i=1;i<=n;i++){split(c[i],a,"~"); print a[3]}}' | grep -E "${2:-.}" | sed 's/.*@sha256://' | cut -c1-12 | sort -u | paste -sd, -; }
T0=${STARTUP_T0:-}; SINCE=${SINCE:-6h}; G="heavy ops sync sync-provider scheduler reconciler stream-ingest stream-external stream-pagerduty"
since() { [ -n "$T0" ] && echo "--since-time=$T0" || echo "--since=$SINCE"; }
logs_of() { for q in $($K get pods -l "$1" -o name 2>/dev/null); do $K logs "$q" --all-containers $(since) 2>/dev/null; done; }
digest_of() { pj_digests "$1"; }
rdy() { echo "$($K get deploy "$1" -o jsonpath='{.status.readyReplicas}')/$($K get deploy "$1" -o jsonpath='{.status.updatedReplicas}')/$($K get deploy "$1" -o jsonpath='{.spec.replicas}')"; }
restarts_of() { pj_restart_sum "$1"; }
case $M in
pre)
  echo "pods not Ready: $(pj_not_ready "")  restarts>0 pods: $(pj_restart_pods "")"
  for g in $G; do echo "go-$g ready/updated/spec=$(rdy dev-health-ops-go-$g) img=$(digest_of dev-health.io/worker-group=$g) restarts=$(restarts_of dev-health.io/worker-group=$g)"; done
  for c in go-api query-api auth-service; do echo "$c ready/updated/spec=$(rdy dev-health-ops-$c) img=$(digest_of app.kubernetes.io/component=$c) restarts=$(restarts_of app.kubernetes.io/component=$c)"; done ;;
sched) exec bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/SCHED-PROOF-24d.sh" check "${2:?at-T0 file}" "${3:?after file}" "${4:-1}" ;;
scrape)
  # CHAOS-11614 readback, kubectl half (scripted, exit non-zero on a miss): the collector is Ready; EXACTLY 2 auth-service pods selected by the collector's own keep rules (component=auth-service, instance=dev-health, Running, container port 8096 declared); both have a pod IP and the 2 IPs differ. Prints SCRAPE-POD lines (name ip) for `scrapecheck`.
  cr=$($K get deploy dev-health-otel-collector -o jsonpath='{.status.readyReplicas}'); cs=$($K get deploy dev-health-otel-collector -o jsonpath='{.spec.replicas}')
  pods=$($K get pods -l app.kubernetes.io/component=auth-service,app.kubernetes.io/instance=dev-health -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.podIP}{" "}{.status.phase}{" "}{range .spec.containers[*].ports[*]}{.containerPort}{","}{end}{"\n"}{end}' | awk 'NF>=1')
  np=$(printf '%s\n' "$pods" | awk 'NF>=1' | wc -l); bad=""
  echo "SCRAPE collector ready ${cr:-0}/${cs:-?}; auth-service pods selected: $np"
  while read -r n ip ph ports; do [ -n "$n" ] || continue; echo "SCRAPE-POD $n ${ip:-none}"; [ "$ph" = Running ] || bad="$bad $n(phase $ph)"; [ -n "$ip" ] || bad="$bad $n(no ip)"; case ",$ports" in *,8096,*) ;; *) bad="$bad $n(no port 8096)";; esac; done <<< "$pods"
  nip=$(printf '%s\n' "$pods" | awk 'NF>=2 {print $2}' | sort -u | wc -l)
  [ "${cr:-0}" = "${cs:-x}" ] || bad="$bad collector-not-Ready"
  [ "$np" = 2 ] || bad="$bad pod-count-$np-not-2"
  [ "$nip" = 2 ] || bad="$bad distinct-IPs-$nip-not-2"
  if [ -n "$bad" ]; then echo "SCRAPE STOP:$bad"; exit 1; fi
  echo "SCRAPE PASS (kubectl half): collector Ready, 2 auth-service pods Running with port 8096 and 2 distinct IPs; next: scrapecheck against the SigNoz series file" ;;
scrapecheck)
  # LOCAL (no prod): bash POSTROLL-24d.sh scrapecheck <scrape.out> <signoz-series.txt>. The lead fills the series file from SigNoz: one line per runtime_info{service.name=auth-service} series, `instance=<ip:port>` (any other text on the line is ignored), read for the window = the last 10 min starting AFTER S3h PASS (a window that holds the roll gives old-pod IPs and the old Service-address series = FAIL). PASS only if exactly 2 series, distinct instance labels, each equal to <pod ip>:8096 of a SCRAPE-POD line of scrape.out. Exit 0 PASS, 1 FAIL.
  po=${2:?scrape.out}; sf=${3:?series file}
  want=$(awk '$1=="SCRAPE-POD" && $3!="none" {print $3":8096"}' "$po" | sort -u); got=$(grep -ohE 'instance=[0-9.]+:[0-9]+' "$sf" | sed 's/^instance=//' | sort); nser=$(grep -c 'instance=' "$sf"); ngot=$(printf '%s\n' "$got" | awk 'NF' | sort -u | wc -l)
  nonip=$(grep "instance=" "$sf" | grep -vcE "instance=[0-9.]+:[0-9]+"); if [ "$nonip" != 0 ]; then echo "SCRAPECHECK FAIL: $nonip series with a non-IP instance label (e.g. the old Service-address series dev-health-ops-auth-service...:8096, or a window that still holds the pre-roll data): use the SigNoz window = the last 10 min starting AFTER S3h PASS; every line must be IP form"; exit 1; fi
  echo "SCRAPECHECK pods (ip:8096): $(echo $want | tr '\n' ' '); series: $nser, distinct instance labels: $ngot"
  if [ "$nser" = 2 ] && [ "$ngot" = 2 ] && [ "$(printf '%s\n' "$got")" = "$(printf '%s\n' "$want")" ]; then echo "SCRAPECHECK PASS"; exit 0; fi
  echo "SCRAPECHECK FAIL: want exactly 2 runtime_info series with distinct instance labels equal to the 2 pod IPs:8096"; exit 1 ;;
*) echo usage; exit 2;;
esac
