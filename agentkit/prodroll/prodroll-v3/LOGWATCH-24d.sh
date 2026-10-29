#!/usr/bin/env bash
# LOGWATCH-24d.sh start | stop | clean (roll 24d): captures the helm hook Job logs of the two steps (the Jobs are deleted on success). There is NO report verb in 24d (it carried 24c auth/pgmigrate/hook-v2 log keys; no migration in 24d).
# ssh prod 'bash -s -- start' < LOGWATCH-24d.sh        before `ROLL-24d.sh deploy app`: background pid captures the auth-migrate / auth-grants / river-migrate / provision-roles Job logs (hook Jobs are deleted on success) into ~/lane-prod-k8s/logwatch-24d/
# ssh prod 'bash -s -- stop <pid>' < LOGWATCH-24d.sh
# ssh prod 'bash -s -- clean' < LOGWATCH-24d.sh        at DONE: deletes ~/lane-prod-k8s/logwatch-24d (files are 0600 in a 0700 dir)
# NEXT-KIT 4: a captured hook log is only replaced by an equal or longer read, so the streak-index hook log survives until (and after) the Job ends and is deleted on hook success.
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; K="kubectl -n dev-health"; W=$HOME/lane-prod-k8s/logwatch-24d
# D6331 helpers (24d): jsonpath of ONLY the needed fields, never -o json of pods/deploys/ingresses (acp item 8)
pj_lines() { $K get pods ${1:+-l "$1"} -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.phase}{" "}{.metadata.deletionTimestamp}{"|"}{range .status.containerStatuses[*]}{.ready}{"~"}{.restartCount}{"~"}{.imageID}{" "}{end}{"\n"}{end}' 2>/dev/null; }
pj_ing_auth() { $K get ingress -o jsonpath='{range .items[*].spec.rules[*].http.paths[*]}{.backend.service.name}{"\n"}{end}' 2>/dev/null | grep -c 'auth-service'; }
pj_not_ready() { pj_lines "$1" | awk '{split($0,p,"|"); split(p[1],h," "); if (h[2]=="Succeeded" || (EXC!="" && h[2]==EXC)) next; if (NODEL && length(h)>=3) next; n=split(p[2],c," "); for(i=1;i<=n;i++){split(c[i],a,"~"); if(a[1]=="false"){k++; break}}} END{print k+0}' EXC="${2:-}" NODEL="${3:-}"; }
pj_restart_pods() { pj_lines "$1" | awk '{split($0,p,"|"); n=split(p[2],c," "); for(i=1;i<=n;i++){split(c[i],a,"~"); if(a[2]+0>0){k++; break}}} END{print k+0}'; }
pj_restart_sum() { pj_lines "$1" | awk '{split($0,p,"|"); split(p[1],h," "); if (length(h)>=3) next; n=split(p[2],c," "); for(i=1;i<=n;i++){split(c[i],a,"~"); s+=a[2]}} END{print s+0}'; }
pj_digests() { pj_lines "$1" | awk '{split($0,p,"|"); split(p[1],h," "); if (length(h)>=3) next; n=split(p[2],c," "); for(i=1;i<=n;i++){split(c[i],a,"~"); print a[3]}}' | grep -E "${2:-.}" | sed 's/.*@sha256://' | cut -c1-12 | sort -u | paste -sd, -; }
# LOOPGUARD block v2 (CHAOS-11564). Needs W (0700 kit dir). State = $W/loop.pid "<pid> <marker>". Kills ONLY the confirmed pid, TERM only; never a group, never KILL.
lg_alive() { s=$(ps -p "$1" -o stat= 2>/dev/null) && [ -n "$s" ] && case "$s" in Z*) false;; *) true;; esac; }
lg_start() { # $1 = tag, $2 = loop body; every command in it must end by itself (no -f / --follow)
  if printf '%s' "$2" | grep -qE -- ' -f([^A-Za-z]|$)|--follow'; then echo "start: REFUSE loop body has a streaming child (-f/--follow)"; return 5; fi
  umask 077; mkdir -p "$W"; chmod 700 "$W"; lg_stop || return $?
  m="logwatch-$1-$$-$(date +%s)"
  bash -c "trap '' HUP; $2" "$m" </dev/null >/dev/null 2>&1 &
  echo "$! $m" > "$W/loop.pid"; echo "loop pid $! marker $m"; }
lg_stop() {
  pf=$W/loop.pid; [ -e "$pf" ] || { echo "stop: no pid file"; return 0; }
  read -r p m < "$pf"
  lg_alive "$p" || { echo "stop: stale pid file (pid $p gone); removed"; rm -f "$pf"; return 0; }
  a=$(ps -p "$p" -o args= 2>/dev/null); case "$a" in *" $m") ;; *) echo "stop: REFUSE pid $p is not our loop (marker mismatch); nothing killed; pid file kept"; return 3;; esac
  kill -TERM "$p"; for i in 1 2 3 4 5; do lg_alive "$p" || break; sleep 1; done
  lg_alive "$p" && { echo "stop: pid $p STILL ALIVE after TERM; no KILL sent"; return 4; }
  rm -f "$pf"; echo "stop: stopped pid $p"; }
lg_clean() { lg_stop || { echo "clean: REFUSED (loop not stopped)"; return 1; }; rm -rf "$W" && echo cleaned; }
# fork records (ROLL deploy/rollback): REPORT ONLY, never kills. $1 = pid file, $2 = pid. Identity = pid + process start time.
lg_fork_rec() { echo "$2 $(ps -p "$2" -o lstart= | tr ' ' '_')" > "$1"; }
lg_fork_report() { [ -e "$1" ] || { echo "fork $1: no record"; return 0; }; read -r p t < "$1"
  if ! lg_alive "$p"; then echo "fork pid $p: gone (ended)"; return 0; fi
  [ "$(ps -p "$p" -o lstart= | tr ' ' '_')" = "$t" ] && echo "fork pid $p: STILL RUNNING (not killed)" || echo "fork pid $p: pid reused by another process (not ours, not killed)"; }
case "$1" in
start) export K W; rm -f $W/*.log; LOOP=$(cat <<'EOS'
while true; do for j in $($K get job -o name 2>/dev/null | grep -E 'auth-migrate|auth-grants|river-migrate|provision-roles|route-activate|ops-migrate$|streak-index|open-units-index'); do n=${j#job.batch/}; $K logs job/$n --tail=-1 --all-containers 2>/dev/null > $W/$n.tmp && [ -s $W/$n.tmp ] && [ $(stat -c %s $W/$n.tmp) -ge $(stat -c %s $W/$n.log 2>/dev/null || echo 0) ] && mv $W/$n.tmp $W/$n.log; done; sleep 1; done
EOS
)
  lg_start 24d "$LOOP" ;;
stop) lg_stop ;; # the pid argument is ignored: the pid file rules
clean) lg_clean ;;
*) echo usage ;;
esac
