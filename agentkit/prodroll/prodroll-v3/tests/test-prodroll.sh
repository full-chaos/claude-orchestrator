#!/usr/bin/env bash
# test-prodroll.sh [<dir holding prodroll.sh + prodroll-v3/>]: the prodroll v3h tests (v3h: section G3 + the I1g/GROUPDIG lines; CHAOS-11743); the v3f tests (v3 + acp's v3b fixes in section R + acp's v3c P2 fixes in section R2 + the D6436 peer-check attest in section R3 + the v3e removed/added-docs, SECRET_KEEP/SECRET_KEYS and liverows n/a gates in sections R4 and G2 + the v3f real-output final-line audit, F_POD and the shred rule in section R5). LOCAL ONLY: fake ssh/kubectl/helm/git (D6387) through the
# copy-only PRODROLL_TEST_PATH override, plus REAL git on throw-away local repos for the remote gate text (fetch --no-tags, ls-remote, first-parent,
# clone checks). No real ssh, no docker, no kind. Each case runs a byte-equal copy of prodroll.sh + prodroll-v3/ in a temp dir under
# /var/lib/oci-cache/lane-scratch (an inputs root) with its own ATTEST-INPUTS.txt (the copy override). Prints `ok <n> bad <n>`.
set -uo pipefail
case "$-" in *x*) echo "test REFUSED: xtrace is on"; exit 10;; esac
SRC=${1:-/var/lib/oci-cache/lane-scratch/fcc-11788-v3f}
R11=/home/ubuntu/devhealth/.remember/acr-mcp/lanes/fcc-roll24c/24f-imgfix-r11
T=/var/lib/oci-cache/lane-scratch/prodroll-v3-test-$(date -u +%Y%m%dT%H%M%SZ)-$$
umask 022
mkdir "$T" || exit 1
ok=0; bad=0
chk() { if [ "$2" = "$3" ]; then ok=$((ok+1)); echo "PASS $1"; else bad=$((bad+1)); echo "FAIL $1 (got [$2] want [$3])"; fi; }
mkcopy() { mkdir -p "$1/logs"; cp -- "$SRC/prodroll.sh" "$1/prodroll.sh"; cp -a -- "$SRC/prodroll-v3" "$1/prodroll-v3"; printf '# test attest file: <inputs sha256> <roll> <UTC>\n' > "$1/ATTEST-INPUTS.txt"; }
mkcopy "$T"
mkdir -p "$T/fakebin" "$T/scen" "$T/in" "$T/state" "$T/fx" "$T/usrlocal/bin" "$T/hashspy"
FX=$T/fx; EX=$T/prodroll-v3/examples; K3=$T/prodroll-v3

# ---- fakes ----
for b in kubectl helm git; do printf '#!/usr/bin/env bash\nFAKE_T=$(cd "$(dirname "$0")/.." && pwd)\necho "LOCAL %s $*" >> "$FAKE_T/local-calls.log"; exit 99\n' "$b" > "$T/fakebin/$b"; done
for b in sha256sum readlink; do printf '#!/usr/bin/env bash\necho "USRLOCAL-FAKE %s" >> "%s/usrlocal-calls.log"; exit 0\n' "$b" "$T" > "$T/usrlocal/bin/$b"; done
printf '#!/usr/bin/env bash\necho "$(readlink /proc/self/fd/0 2>/dev/null) $*" >> "%s/hashspy.log"\nexec /usr/bin/sha256sum "$@"\n' "$T" > "$T/hashspy/sha256sum"
cat > "$T/fakebin/ssh" <<'EOF'
#!/usr/bin/env bash
# fake ssh: logs n | sha256(stdin) | the remote command | the argv before it | the env it got; answers by the command text; scenarios in $FAKE_T/scen
FAKE_T=$(cd "$(dirname "$0")/.." && pwd)
c=${!#}; pre=("${@:1:$#-1}")
n=$(( $(cat "$FAKE_T/ssh.count" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FAKE_T/ssh.count"
in=$(sha256sum | cut -c1-64)
printf '%s\t%s\t%s\t%s\t%s\n' "$n" "$in" "$c" "${pre[*]}" "HOME=${HOME:-} LANG=${LANG:-} LC_ALL=${LC_ALL:-} KUBECONFIG=${KUBECONFIG:-} PWD=$PWD EVILVAR=${EVILVAR:-}" >> "$FAKE_T/ssh.log"
sc() { [ -e "$FAKE_T/scen/$1" ]; }
FX=$FAKE_T/fx; KX=$FAKE_T/prodroll-v3/tests/fixtures
SECRET='---
apiVersion: v1
kind: Secret
metadata:
  name: ingress-nginx-test-secret
data:
  token: U0VOVElORUwtU0VDUkVULVZBTFVFLTAxMjM=
stringData:
  plain: SENTINEL-SECRET-VALUE-0123'
hist() { printf 'REVISION\tUPDATED                 \tSTATUS    \tCHART               \tAPP VERSION\tDESCRIPTION     \n'; for r in "$@"; do printf '%s       \tWed Oct 28 06:05:31 2026\t%s  \tingress-nginx-4.14.5\t1.14.5     \tUpgrade complete\n' "${r%%:*}" "${r#*:}"; done; }
dhnew() { if [ -e "$FAKE_T/state/dh-deployed" ]; then echo 426; else cat "$FAKE_T/scen/dh-newest" 2>/dev/null || echo 425; fi; }
gstop() { echo "GATE-REMOTE STOP: $*"; exit 3; }
gates() { # emulates the remote gate text (the real text is tested with real git in section G)
  local ts ss t s e
  [[ $c =~ for\ t\ in\ ([^;]+)\;\ do ]] && ts=${BASH_REMATCH[1]}
  [[ $c =~ for\ s\ in\ ([0-9a-f\ ]+)\;\ do ]] && ss=${BASH_REMATCH[1]}
  for t in $ts; do sc url-insteadof && gstop "$t: 1 url.* key(s) in its git config (insteadOf)"; sc tree-dirty && gstop "$t: git status --porcelain shows 1 line(s)"; echo "CLONE $t origin=pinned url_keys=0 porcelain=0"; done
  sc lsremote-mismatch && gstop "fetched main 0123 != ls-remote refs/heads/main 4567"
  echo "MAIN 0123456789abcdef0123456789abcdef01234567 = ls-remote refs/heads/main"
  for s in $ss; do grep -qx "$s" "$FAKE_T/scen/anc-not" 2>/dev/null && gstop "$s is not an ancestor of main"; grep -qx "$s" "$FAKE_T/scen/fp-not" 2>/dev/null && gstop "$s is not on the first-parent chain of main"; echo "SHA $s ancestor=1 first_parent=1"; done
  if [[ $c =~ P0u\ HEAD ]]; then sc p0-dirty && { echo "P0u HEAD 309dadea15b861903a9eefb9eb6319f8dfad8c40 dirty=1 values_blob=b20d disk=b20d tgz=93ea"; gstop "P0u: the tree, values or tgz differ from the inputs and the pinned tgz"; }; echo "P0u HEAD 309dadea15b861903a9eefb9eb6319f8dfad8c40 dirty=0 values_blob=b20d430f61fbbd5b34a5f0022519f1025bb1565b disk=b20d430f61fbbd5b34a5f0022519f1025bb1565b tgz=93ea7cf2677577a489e14fc94d6026a1194cf2e453dc86bf43da7162109f0d59"; fi
  if [[ $c =~ \[\ \"\$nw\"\ =\ \"([0-9]+)\ deployed\"\ \] ]]; then e=${BASH_REMATCH[1]}
    if [[ $c =~ helm\ history\ dev-health ]]; then l=$(dhnew); else l=3; [ -e "$FAKE_T/state/upgraded" ] && l=4; fi
    [ "$l" = "$e" ] || gstop "live newest revision [$l deployed] is not the pre LIVEREV $e deployed"; echo "NEWEST $l deployed = the pre LIVEREV"; fi
  echo "GATE-REMOTE: PASS"; }
docs() { # emulates the v3e docs gate (the real text is tested with real helm + full-render-diff in section G2)
  local erm= ead= arm ad
  [[ $c =~ \[\ \"\$rm\"\ =\ \"([^\"]*)\"\ \] ]] && erm=${BASH_REMATCH[1]}
  [[ $c =~ \[\ \"\$ad\"\ =\ \"([^\"]*)\"\ \] ]] && ead=${BASH_REMATCH[1]}
  arm=$(cat "$FAKE_T/scen/docs-removed" 2>/dev/null); ad=$(cat "$FAKE_T/scen/docs-added" 2>/dev/null)
  echo "DOCS A 94 B 91; removed [$arm]; added [$ad]"
  [ "$arm" = "$erm" ] || gstop "removed docs [$arm] != REMOVED_DOC [$erm]"; [ "$ad" = "$ead" ] || gstop "added docs [$ad] != ADDED_DOC [$ead]"
  echo "DOCS-GATE: PASS (removed = REMOVED_DOC, added = ADDED_DOC)"; }
secrets() { # emulates the v3e secret text (the real text is tested with a fake kubectl in section G2)
  local ks= kk= s sk k have=RIVER_COORDINATOR_DATABASE_PASSWORD,RIVER_DOMAIN_DATABASE_PASSWORD,RIVER_KEDA_READONLY_PASSWORD,RIVER_QUEUE_DATABASE_PASSWORD
  sc key-missing && have=RIVER_COORDINATOR_DATABASE_PASSWORD,RIVER_DOMAIN_DATABASE_PASSWORD,RIVER_QUEUE_DATABASE_PASSWORD
  [[ $c =~ for\ s\ in\ ([a-z0-9\ -]*)\;\ do\ ty= ]] && ks=${BASH_REMATCH[1]}
  [[ $c =~ for\ sk\ in\ ([A-Za-z0-9:,._\ -]*)\;\ do ]] && kk=${BASH_REMATCH[1]}
  for s in $ks; do if sc secret-gone || { sc secret-gone-post && [ -e "$FAKE_T/state/dh-deployed" ]; }; then gstop "secret $s: the .type read failed (absent?)"; fi; sc keep-absent && gstop "secret $s: helm.sh/resource-policy is [], not keep"; echo "SECRET-KEEP $s type=Opaque keep=yes keys=$have"; done
  for sk in $kk; do s=${sk%%:*}; for k in $(tr , ' ' <<< "${sk#*:}"); do case ",$have," in *",$k,"*) ;; *) gstop "secret $s: key name $k is missing";; esac; done; echo "SECRET-KEYS $s: every named key is present"; done; }
case "$c" in
  *"bash -s -- deploy i"*) gates; if [[ $c == *"for s in"*"do ty="* || $c == *"for sk in"* ]]; then secrets; fi; if [[ $c == *DOCS-GATE* ]]; then docs; fi; touch "$FAKE_T/state/deploy-ran"; echo "ROLL i19 START HEAD f301c67"; echo "pid 4242 log /home/ubuntu/lane-prod-k8s/roll-24d-i19.out" ;;
  *"upgrade ingress-nginx"*"--wait --timeout 5m"*) gates; touch "$FAKE_T/state/upgraded"; echo 'Release "ingress-nginx" has been upgraded. Happy Helming!'; echo "upgrade rc=0" ;;
  *"git ls-remote"*) gates ;;
  *"bash --norc --noprofile -s"*) echo "/home/ubuntu/lane-prod-k8s/11709-logs/F1PIPE-123456Z.log" ;;
  *"cat -- '/home/ubuntu/lane-prod-k8s/11709-logs/F1PIPE-"*)
    echo "== f1pipe-11709 ns=dev-health time=20261028T170000Z"; echo "BEFORE live CLICKHOUSE_NATIVE_URI sha12=0123456789ab; URI built from the file: ABSENT"
    if sc f1-fail; then echo "STOP: the writer refused (nothing written)"; echo "rc=1"; else echo "AFTER live CLICKHOUSE_NATIVE_URI sha12=0123456789ab; URI built from the file: EQUAL"; echo "F1PIPE: PASS"; echo "rc=0"; fi ;;
  *pg-owner-rotation.marker*) if sc marker-present; then echo "PRESENT /home/ubuntu/.config/dev-health/pg-owner-rotation.marker"; else echo "ABSENT /home/ubuntu/.config/dev-health/pg-owner-rotation.marker"; fi ;;
  *"git rev-parse HEAD HEAD:scripts/load-secrets.sh"*) sed -n 's/^ASTEP_LINE=//p' "$FAKE_T/prodroll-v3/examples/INPUTS-11709-f1pipe-v3.txt" | { if sc astep-bad; then sed '1s/^4711/b460/'; else cat; fi; } ;;
  *"-- refresh "*) echo "ROLL-24d REFRESH (the tree's verify-pins script): must not be called" ;;
  *"-- kitrefresh "*) echo "PASS deploy-roll-24d"; echo "verify_pins=passed"; echo "KITREFRESH: PASS (both trees; verify_pins from the kit, nothing run from the trees)" ;;
  *"bash -s -- start"*) echo "stop: no pid file"; echo "loop pid 4141 marker logwatch-24d-4141-1793000000" ;;
  *"EXP_START_REV="*) echo "START-CHECK: newest row = 425 deployed; newest deployed revision = 425; expected = 425"; echo "START-CHECK: PASS (revision 425 is the newest and deployed)" ;;
  *"-- helmrev app"*) r=$(cat "$FAKE_T/scen/livrev" 2>/dev/null || echo 425); echo "rev $r deployed Upgrade complete"; echo "STATE LIVEREV=$r" ;;
  *"-- groupdigests"*) echo "GROUPDIG-ROW heavy:4bdf329325b0"; echo "STATE GROUPDIG=heavy:4bdf329325b0,ops:fa9b7cd250de,sync:fa9b7cd250de,sync-provider:fa9b7cd250de,scheduler:fa9b7cd250de,reconciler:fa9b7cd250de,stream-ingest:fa9b7cd250de,stream-external:fa9b7cd250de,stream-pagerduty:fa9b7cd250de" ;;
  *"-- restarts"*) printf 'RESTART dev-health-ops-web-5d6f7-ddddd 1\nRESTART dev-health-ops-go-api-7c9d8-ccccc 0\nSTATE RESTARTMAP=dev-health-ops-web-5d6f7-ddddd:1,dev-health-ops-go-api-7c9d8-ccccc:0\nSTATE RESTARTS0=1\n' ;;
  *podsnap-i*-before.txt*) if sc podsnap-real; then cat "$FAKE_T/fxreal/s20a-PODSNAP-before.out"; else cat "$FX/podsnap-before.txt"; fi ;;
  *podsnap-i*-after.txt*|*custom-columns=POD*) if sc podsnap-bad; then sed 's/uid-a1/uid-a9/' "$FX/podsnap-after.txt"; elif sc podsnap-same; then cat "$FX/podsnap-before.txt"; else cat "$FX/podsnap-after.txt"; fi ;;
  *"bash -s -- collect"*) cat "$FX/collect.txt" ;;
  *"bash -s -- topsnap"*) q=$FAKE_T/scen/topsnap-queue; f=; if [ -s "$q" ]; then f=$(head -1 "$q"); sed -i 1d "$q"; fi; cat "$FX/${f:-topsnap.txt}" ;;   # v3j: scen/topsnap-queue = the fixture names, one per call
  *"-- guards "*) if sc guards-fail; then echo "GUARDHEADROOM FAIL (stage i19): a cpu value moved: STOP"; exit 9; fi; echo "GUARD4994 PASS: #4994 in cut=1 authService.phase=2"; echo "GUARDVALUES PASS: 3 poolers"; echo "GUARDHEADROOM PASS (stage i19)"; sc guards-nopass || echo "HOOKGUARD PASS: streak-index hook Job renders" ;;
  *"deploy-rollback-24d deploy-roll-24d"*) if [[ $c == *DOCS-GATE* ]]; then docs; fi; echo "RENDER PATHS: 1/1 expected rows, UNEXPECTED 0"; echo "RENDER PATHS: PASS" ;;
  *"helm.sh/resource-policy"*) secrets; echo "SECRETS: PASS" ;;
  *"-- wait helm-rollback"*) echo "deploy_rc=0" ;;
  *"-- wait i"*) if sc wait-always3 || { sc wait3once && [ ! -e "$FAKE_T/state/wait3-done" ]; }; then touch "$FAKE_T/state/wait3-done"; echo "STILL-RUNNING i19"; exit 3; fi; echo "deploy_rc=0" ;;
  *"-- appcheck"*) echo "APPCHECK data-store pods not Ready: none; Pending pods: none"; echo "APPCHECK PASS: no Pending pod, every data-store pod Ready" ;;
  *"-- stagecheck i"*) if sc stage-fail; then echo "STAGECHECK: STOP (1 problem(s) above)"; exit 1; fi; if sc stage-failword; then echo "STAGECHECK i19: FAIL (word only)"; echo "STAGECHECK: PASS"; exit 0; fi; echo "STAGECHECK i19: no failed pod (hook Jobs completed)"; sc stage-nopass || echo "STAGECHECK: PASS" ;;
  *"-- migjoblog read"*) echo "MIGJOBLOG log lines: 12"; echo 'MIGJOBLOG postgres action=noop applied=[] heads=["0066","0162"]'; echo 'MIGJOBLOG clickhouse action=noop applied=[] head=0042' ;;
  *"-- pgver "*) echo "PGVER alembic_version rows={0066,0162} (want {0066,0162})"; echo "PGVER: PASS" ;;
  *"-- liverows"*) echo "LIVEROWS: PASS (1 rows read, 0 mismatched)" ;;
  *"bash -s -- scrape"*) cat "$FX/scrape.out" ;;
  *"helm history dev-health -n dev-health --max 100"*) printf 'REVISION\tUPDATED                 \tSTATUS    \tCHART           \tAPP VERSION\tDESCRIPTION\n'; for r in 421 422 423 424 425 426; do [ "$r" = 425 ] && sc dh-hist-missing && continue; printf '%s     \tWed Oct 28 17:00:00 2026\tsuperseded\tdev-health-0.1.0\t0.1.0      \tUpgrade complete\n' "$r"; done ;;
  *"history ingress-nginx --max 100"*) hist 1:superseded 2:superseded 3:superseded 4:deployed ;;
  *"helm history dev-health -n dev-health --max 1"*) printf 'REVISION\tUPDATED                 \tSTATUS  \tCHART           \tAPP VERSION\tDESCRIPTION\n%s     \tWed Oct 28 17:00:00 2026\tdeployed\tdev-health-0.1.0\t0.1.0      \tUpgrade complete\n' "$(dhnew)" ;;
  *"-- helm-rollback app"*) echo "HELM ROLLBACK START app"; echo "pid 4343 log /home/ubuntu/lane-prod-k8s/roll-24d-helm-rollback.out" ;;
  *"-- rollcheck i"*) echo "ROLLCHECK newest helm revision: 427 deployed Rollback to 425"; echo "ROLLCHECK: PASS (i19 step undone)" ;;
  *"values_blob="*) d=0; sc p0-dirty-pre && d=1; t=93ea7cf2677577a489e14fc94d6026a1194cf2e453dc86bf43da7162109f0d59; sc tgz-bad && t=0000000000000000000000000000000000000000000000000000000000000000
    echo "HEAD 309dadea15b861903a9eefb9eb6319f8dfad8c40 dirty=$d values_blob=b20d430f61fbbd5b34a5f0022519f1025bb1565b disk=b20d430f61fbbd5b34a5f0022519f1025bb1565b"; echo "$t  /home/ubuntu/lane-prod-k8s/11647/chart/ingress-nginx-4.14.5.tgz" ;;
  *"history ingress-nginx --max 3"*) [[ $c =~ git\ show\ ([0-9a-f]{40}): ]] && b=${BASH_REMATCH[1]}; hist 1:superseded 2:superseded 3:deployed; echo "P1 live values == base ${b:-?}: True"; echo "cni0 inet 10.42.0.1/24" ;;
  *"--max 2"*) hist 3:superseded 4:deployed
    echo 'helm Apply keys={"f:compute-full-forwarded-for":{},"f:proxy-real-ip-cidr":{},"f:proxy-set-headers":{},"f:use-forwarded-headers":{}}'
    echo 'kubectl-patch Update keys={"f:compute-full-forwarded-for":{},"f:proxy-real-ip-cidr":{},"f:use-forwarded-headers":{}}'
    echo "R2 use-forwarded-headers=[true]"; echo "R2 proxy-real-ip-cidr=[10.42.0.1/32]"; echo "R2 compute-full-forwarded-for=[false]"
    echo "ingress-nginx-controller-67cf7ccf4b-zfcdh restarts=0 ready=true"; echo "R3 reload-error lines: 0"; echo "R3 reload lines: 0" ;;
  *'echo "P2 $k'*) echo "P2 use-forwarded-headers=[true]"; if sc p2-bad; then echo "P2 proxy-real-ip-cidr=[10.42.0.0/24]"; else echo "P2 proxy-real-ip-cidr=[10.42.0.1/32]"; fi; echo "P2 compute-full-forwarded-for=[false]" ;;
  *"P4 access lines"*) echo "ingress-nginx-controller-67cf7ccf4b-zfcdh restarts=0 ready=true"; echo "P4 access lines 3"; echo "P4 remote_addr 195.64.239.96 2"; echo "P4 remote_addr 34.18.176.95 1" ;;
  *"--show-managed-fields"*) echo 'helm Apply keys={"f:proxy-set-headers":{}}'; echo 'kubectl-patch Update keys={"f:compute-full-forwarded-for":{},"f:proxy-real-ip-cidr":{},"f:use-forwarded-headers":{}}' ;;
  *"--dry-run=server"*) echo "preflight rc=0"; echo "stderr: "; echo "conflict lines: 0"; echo "@@MANIFEST"; sed -n '/^MANIFEST:/,$p' "$KX/ingress-dry.out" | sed 1d | sed '/^NOTES:/,$d'; if sc secret-docs; then printf '%s\n' "$SECRET"; echo dry >> "$FAKE_T/state/secret-emitted"; fi ;;
  *"get manifest ingress-nginx"*) cat "$KX/ingress-live.manifest"; if sc secret-docs; then printf '%s\n' "$SECRET"; echo live >> "$FAKE_T/state/secret-emitted"; fi ;;
  *"history ingress-nginx --max 1"*) if [ -e "$FAKE_T/state/upgraded" ]; then hist 4:deployed; else hist 3:deployed; fi ;;
  *"rollback ingress-nginx"*) echo "Rollback was a success! Happy Helming!"; echo "rollback rc=0" ;;
  *) echo "FAKE-SSH: unknown command" >&2; echo "UNKNOWN $n" >> "$FAKE_T/unknown.log"; exit 97 ;;
esac
EOF
printf '#!/usr/bin/env bash\necho "sleep $*" >> "%s/sleep.log"; exit 0\n' "$T" > "$T/fakebin/sleep"   # v3j: the I7 60 s wait (xrun sleep 60) is logged, not slept
chmod 0755 "$T"/fakebin/* "$T"/usrlocal/bin/* "$T"/hashspy/*
export PRODROLL_TEST_PATH="$T/fakebin"   # test-only override (D6387 fake bins): honoured only by a copy outside shared/; prodroll.sh always sets its own PATH

run() { OUT=$("$@" </dev/null 2>&1); RC=$?; }
pr() { run "$T/prodroll.sh" "$@"; }
sshn() { cat "$T/ssh.count" 2>/dev/null || echo 0; }
has() { printf '%s\n' "$OUT" | grep -qF -- "$1" && echo yes || echo no; }
sshafter() { awk -F'\t' -v n="$1" '$1 > n {print $3}' "$T/ssh.log" 2>/dev/null; }
attest() { echo "$(sha256sum < "$2" | cut -c1-64) test-roll $(date -u +%FT%TZ) peer-lead" >> "$1/ATTEST-INPUTS.txt"; }   # D6436: 4 fields, checker != AUTHOR (fcc)
attest_line() { echo "$(sha256sum < "$2" | cut -c1-64) $3" >> "$1/ATTEST-INPUTS.txt"; }   # $3 = the rest of the line, as given
mkin_na() { local name=$1 base=$2; shift 2; sed -e '' "$@" "$base" > "$T/in/$name.txt"; echo "$T/in/$name.txt"; }
mkin() { local f; f=$(mkin_na "$@"); attest "$T" "$f"; echo "$f"; }
refused() { local name=$1 n0; shift; n0=$(sshn); pr "$@"; chk "REFUSED $name: rc 2" "$RC" 2; chk "REFUSED $name: REFUSED line" "$(has 'PRODROLL REFUSED (exit 2)')" yes; chk "REFUSED $name: no ssh" "$(sshn)" "$n0"; }
kitsha() { sha256sum < "$K3/$1" | cut -c1-64; }

echo "== A. kit bytes, self-check pins and source census"
chk "f1pipe-11709.sh sha256 = 8c2e9585 (attested body)" "$(kitsha f1pipe-11709.sh)" 8c2e95853d7e89d4f2ef9d9a3eb83a8182f7630089dc41b62c7fd3ac33c5ebe8
for f in START-CHECK-IMG.sh LOGWATCH-24d.sh READBACK-IMG.sh POSTROLL-24d.sh PODSNAP-CMP-r7.sh; do
  chk "$f byte-equal to r11 (24f-imgfix-r11)" "$(cmp -s "$R11/$f" "$K3/$f" && echo equal)" equal
done
R24D=$(diff "$R11/ROLL-24d.sh" "$K3/ROLL-24d.sh")
chk "v3h: ROLL-24d.sh = r11 except the v3h lines: 1 removed (the norolls line, kept re-indented in the else arm), 15 added (group_map, groupdigests, the GROUPDIG arm), added-block sha12 51b4ba962e85" "$(printf '%s\n' "$R24D" | grep -c '^<') $(printf '%s\n' "$R24D" | grep -c '^>') $(printf '%s\n' "$R24D" | grep '^>' | sha256sum | cut -c1-12) $(printf '%s\n' "$R24D" | grep -cxF -- "> $(printf '%s\n' "$R24D" | sed -n 's/^< /  /p')")" "1 15 51b4ba962e85 1"
RHR=$(diff "$R11/HEADROOM-24d.sh" "$K3/HEADROOM-24d.sh")
chk "v3j: HEADROOM-24d.sh = r11 except the v3j lines (comment line 5, the topcmp block, the usage line): 9 removed (sha12 65d0ed91f40a), 20 added (sha12 bf7da51766b9)" "$(printf '%s\n' "$RHR" | grep -c '^<') $(printf '%s\n' "$RHR" | grep '^<' | sha256sum | cut -c1-12) $(printf '%s\n' "$RHR" | grep -c '^>') $(printf '%s\n' "$RHR" | grep '^>' | sha256sum | cut -c1-12)" "9 65d0ed91f40a 20 bf7da51766b9"
chk "RENDER-PATHS-24d.sh = r11 except line 16, the EXIT trap (v3f pm rule: shred -u the 2 raw renders, then rm -rf)" "$(diff "$R11/RENDER-PATHS-24d.sh" "$K3/RENDER-PATHS-24d.sh" | grep '^[<>]' | paste -sd'|')" "< D=\$(mktemp -d); trap 'rm -rf \$D' EXIT|> D=\$(mktemp -d); trap 'shred -u \$D/a.raw \$D/b.raw 2>/dev/null; rm -rf \$D' EXIT"
chk "full-render-diff.py sha256 = b19f2889 (deploy 309dadea)" "$(kitsha full-render-diff.py)" b19f288907870dd99f553e990b58799082cb857f063ad8d6552f43fd4b067eba
chk "REFRESH-KIT-v2.sh = v2 (d004c43f, kept as in v2)" "$(kitsha REFRESH-KIT-v2.sh)" d004c43f5e44c9ab3078e1afac3c40c8e0b9760009ede4a497b4b8d638a8f992
if git -C /home/ubuntu/devhealth/deploy cat-file -e 309dadea15b861903a9eefb9eb6319f8dfad8c40:scripts/run-verify-pins.sh 2>/dev/null; then
  chk "REFRESH-KIT verify_pins_kit = deploy 309dadea:scripts/run-verify-pins.sh lines 14-62, verbatim" "$(diff <(sed -n '/^# >>> verbatim/,/^# <<< verbatim end/p' "$K3/REFRESH-KIT-v2.sh" | sed '1d;$d') <(git -C /home/ubuntu/devhealth/deploy show 309dadea15b861903a9eefb9eb6319f8dfad8c40:scripts/run-verify-pins.sh | sed -n 14,62p) && echo equal)" equal
fi
chk "kit known_hosts = the 3 prod host keys (fingerprints)" "$(ssh-keygen -l -f "$K3/known_hosts" | awk '{print $2}' | paste -sd' ')" "SHA256:rTu0IBS/oFVb4eBGc9oal9M/d1tgOPqwVj5jex0jipg SHA256:s8qvmlqHrw+pBSGmIpw8EjcFM+xAnSXI+kynRRMgDTY SHA256:kix80BcHWqyZU9Rl2vi6Ehek3CQdHRuXIU9tUna3GBc"
chk "prodroll.sh pins sha256(prodroll-v3/SHA256SUMS)" "$(grep -c "^PINNED_SUMS_SHA256=$(sha256sum < "$K3/SHA256SUMS" | cut -c1-64)\$" "$T/prodroll.sh")" 1
chk "prodroll.sh pins its own sha256 (without the pin line)" "$(grep -c "^PINNED_SELF_SHA256=$(sed '/^PINNED_SELF_SHA256=/d' "$T/prodroll.sh" | sha256sum | cut -c1-64)\$" "$T/prodroll.sh")" 1
chk "prodroll.sh line 1 = #!/bin/bash -p; mode 0755" "$(head -1 "$SRC/prodroll.sh") $(stat -c %a "$SRC/prodroll.sh")" '#!/bin/bash -p 755'
chk "PATH constant = /usr/sbin:/usr/bin:/sbin:/bin" "$(sed -n 's/^PATH=\([^;]*\); export PATH.*/\1/p' "$T/prodroll.sh")" /usr/sbin:/usr/bin:/sbin:/bin
CENSUS=$(grep -nE '(^|[^A-Za-z0-9_-])eval([^A-Za-z0-9_-]|$)|(^|[^A-Za-z0-9_-])source([^A-Za-z0-9_-]|$)|(^|[;&|({[:space:]])\.[[:space:]]+[^[:space:]]|(^|[^A-Za-z0-9_-])(ba)?sh[[:space:]]+(-[A-Za-z]+[[:space:]]+)*-c([^A-Za-z0-9_-]|$)' "$T/prodroll.sh")
printf '%s\n' "${CENSUS:-(no hit)}" | sed 's/^/CENSUS /'
chk "census: 0 hits of eval/source/. file/bash -c/sh -c in prodroll.sh" "$(printf '%s' "$CENSUS" | grep -c .)" 0
chk "every rsh/rtool/rtool2 call line exports KUBECONFIG" "$(grep -E "(rsh|rtool2?) [\"']" "$T/prodroll.sh" | grep -vc 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml')" 0
chk "ssh only through rsh/rtool (one SSH_BASE)" "$(grep -nE '(^|[^A-Za-z_"])ssh +(-[A-Za-z]|prod)' "$T/prodroll.sh" | grep -vE '^[0-9]+:#|SSH_BASE=\(ssh -F' | grep -c .)" 0
chk "no fixed /tmp/. name on prod" "$(grep -c '/tmp/\.' "$T/prodroll.sh")" 0
chk "item 1: the fetch is --no-tags refs/heads/main from the pinned URL, then ls-remote refs/heads/main" "$(grep -c 'git fetch -q --no-tags '"'"'"\$DEPLOY_URL"'"'"' refs/heads/main' "$T/prodroll.sh")$(grep -c 'git ls-remote '"'"'"\$DEPLOY_URL"'"'"' refs/heads/main' "$T/prodroll.sh")" 11

echo "== fixtures"
cp -a -- "${FXR_SRC:-$K3/tests/fixtures/real}" "$T/fxreal"   # the real prod output fixtures (FXR_SRC: the v3f set, for the RED run against an older kit)
printf '%s\n' "dev-health-ops-go-api-7c9d8-ccccc uid-g1 0 ReplicaSet dev-health-ops-go-api-7c9d8" "dev-health-ops-auth-service-6ffd4f75d-aaaaa uid-a1 0 ReplicaSet dev-health-ops-auth-service-6ffd4f75d" "dev-health-ops-postgresql-0 uid-p0 0 StatefulSet dev-health-ops-postgresql" "dev-health-ops-web-5d6f7-ddddd uid-w1 1 ReplicaSet dev-health-ops-web-5d6f7" > "$FX/podsnap-before.txt"
printf '%s\n' "dev-health-ops-go-api-5b6c7-eeeee uid-g2 0 ReplicaSet dev-health-ops-go-api-5b6c7" "dev-health-ops-auth-service-6ffd4f75d-aaaaa uid-a1 0 ReplicaSet dev-health-ops-auth-service-6ffd4f75d" "dev-health-ops-postgresql-0 uid-p0 0 StatefulSet dev-health-ops-postgresql" "dev-health-ops-web-5d6f7-ddddd uid-w1 1 ReplicaSet dev-health-ops-web-5d6f7" > "$FX/podsnap-after.txt"
{ echo "@@FILE nodes.txt"; echo "n1 4000m"; echo "@@END"; echo "@@FILE pods.txt"; echo "dev-health/p1 Running 2500m,"; echo "@@END"; echo "@@FILE deploy.txt"
  for g in heavy ops sync sync-provider scheduler reconciler stream-ingest stream-external stream-pagerduty; do echo "dev-health/dev-health-ops-go-$g 1 RollingUpdate 1 100m,"; done; echo "dev-health/dev-health-ops-go-api 1 RollingUpdate 1 50m,"; echo "@@END"
  echo "@@FILE scaledobjects.txt"; echo "@@END"; echo "@@FILE hpas.txt"; echo "@@END"; echo "@@COLLECT OK 2026-10-28T00:00:00Z"; } > "$FX/collect.txt"
printf '%s\n' "# kubectl top pods -n dev-health (pod cpu memory) 2026-10-28T17:00:00Z" "top dev-health-ops-web-5d6f7-ddddd 10m 120Mi" "# hpa rows (name targets minpods maxpods replicas)" "hpa dev-health-ops-web 12%/80% 1 3 1" > "$FX/topsnap.txt"
for w in 3 4 20 unknown; do printf '%s\n' "# kubectl top pods -n dev-health (pod cpu memory) 2026-10-29T17:00:00Z" "top dev-health-ops-web-5d6f7-ddddd 10m 120Mi" "# hpa rows (name targets minpods maxpods replicas)" "hpa dev-health-ops-web $([ $w = unknown ] && echo unknown || echo "$w%/70%") 2 4 2" "hpa keda-hpa-dev-health-ops-go-sync unknown 1 2 1" > "$FX/topsnap-w$w.txt"; done   # v3j: the s36-a shape (web 3% -> 20% -> 4%)
printf '%s\n' "SCRAPE collector ready 1/1; auth-service pods selected: 2" "SCRAPE-POD dev-health-ops-auth-service-7aa1b2c3d-eeeee 10.42.0.121" "SCRAPE-POD dev-health-ops-auth-service-7aa1b2c3d-fffff 10.42.0.122" "SCRAPE PASS (kubectl half)" > "$FX/scrape.out"
printf '%s\n' "# SigNoz runtime_info{service.name=auth-service}, test fixture" "instance=10.42.0.121:8096" "instance=10.42.0.122:8096" > "$T/in/series.txt"

DH=$(mkin dh-a "$EX/INPUTS-dev-health-step19-r13-v3.txt" -e 's/^SCRAPE=no$/SCRAPE=yes/' -e "\$a SERIES_FILE=$T/in/series.txt")
ING=$(mkin ing-a "$EX/INPUTS-11699-ingress-v3.txt")
F1=$(mkin f1-a "$EX/INPUTS-11709-f1pipe-v3.txt")
W=$T/logs/PRODROLL-WORK-dev-health-i19-s19-a
ROLLSHA=$(kitsha ROLL-24d.sh)
KITSHAS="$(cd "$K3" && sha256sum *.sh *.py | cut -c1-64 | paste -sd' ') $(cat "$K3/full-render-diff.py" "$K3/RENDER-PATHS-24d.sh" | sha256sum | cut -c1-64) $(cat "$K3/full-render-diff.py" "$K3/ROLL-24d.sh" | sha256sum | cut -c1-64)"   # v3e: the I3p and I3d ssh get full-render-diff.py + the tool on one stdin

echo "== B. happy paths"
n0=$(sshn); export EVILVAR=caller-env; pr roll dev-health "$DH" pre; unset EVILVAR
chk "roll dev-health pre: rc 0" "$RC" 0; chk "pre: PHASE pre: PASS" "$(has 'PHASE pre: PASS')" yes
chk "item 7: SELF and KIT checks printed" "$(has 'SELF: sha256(prodroll.sh without the pin line) = pinned')$(has 'sha256sum -c OK')" yesyes
chk "item 6: the ATTEST line" "$(has 'ATTEST: sha256(inputs)')" yes
chk "pre: GATES first (one ssh: clones, fetch, ls-remote, first-parent), then the r12 DRAFT order" "$(sshafter "$n0" | sed -E 's/.*(git ls-remote|-- kitrefresh|bash -s -- start|EXP_START_REV|helmrev app|-- restarts|-- groupdigests|podsnap-i19-s19-a-before|-- collect|-- topsnap|-- guards|deploy-rollback-24d deploy-roll-24d).*/\1/' | paste -sd'|')" "git ls-remote|-- kitrefresh|bash -s -- start|EXP_START_REV|helmrev app|-- restarts|-- groupdigests|podsnap-i19-s19-a-before|-- collect|-- topsnap|-- guards|deploy-rollback-24d deploy-roll-24d"
chk "item 2: the pre gate checks SVC_SHA and ROLLBACK_SHA, on both trees" "$(sshafter "$n0" | head -1 | grep -c 'for t in /home/ubuntu/lane-prod-k8s/deploy-roll-24d /home/ubuntu/lane-prod-k8s/deploy-rollback-24d; do.*for s in f301c670ab2a70f3e7ab4d4f3758e2e53c5f6111 309dadea15b861903a9eefb9eb6319f8dfad8c40; do')" 1
chk "pre: RP_IMGROWS = the go-api row, one single-quoted literal" "$(sshafter "$n0" | grep -cF "RP_IMGROWS='Deployment/dev-health-ops-go-api .spec.template.spec.containers[0].env[41].value 10.42.0.0/24 10.42.0.0/24,!10.42.0.0,!10.42.0.1;'")" 1
chk "pre: HEADROOM compute on the filtered in-memory render (IMG_DEPLOYS=none)" "$(grep -c 'surge of the rolled Deployments at their current requests 0m' "$W/pre/I2-compute.out")" 1
chk "v3h pre: state GROUPDIG = the per-group map read by I1g" "$(sed -n 's/^GROUPDIG=//p' "$W/state.txt")" "heavy:4bdf329325b0,ops:fa9b7cd250de,sync:fa9b7cd250de,sync-provider:fa9b7cd250de,scheduler:fa9b7cd250de,reconciler:fa9b7cd250de,stream-ingest:fa9b7cd250de,stream-external:fa9b7cd250de,stream-pagerduty:fa9b7cd250de"
chk "pre: state LIVEREV=425 RESTARTS0=1 + PREEND" "$(grep -E '^(LIVEREV|RESTARTS0|PREEND)=' "$W/state.txt" | sed 's/=[0-9]*$//' | paste -sd' ')" "LIVEREV RESTARTS0 PREEND"
chk "pre: ROLLBACK_REV 425 = the LIVEREV read live" "$(has 'GATE ROLLBACK_REV: PASS')" yes
chk "pre: ROLL-24d verbs in pre = guards, helmrev, restarts only (no refresh/prep/deploy)" "$(awk -F'\t' -v n="$n0" -v r="$ROLLSHA" '$1>n && $2==r {print $3}' "$T/ssh.log" | sed -E 's/.*bash -s -- ([a-z-]+).*/\1/' | sort -u | paste -sd' ')" "groupdigests guards helmrev restarts"
chk "item 8: every ssh argv = -F <kit>/ssh_config -o StrictHostKeyChecking=yes -o UserKnownHostsFile=<kit>/known_hosts [-n] prod" "$(awk -F'\t' '{print $4}' "$T/ssh.log" | sort -u | paste -sd'|')" "-F $K3/ssh_config -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$K3/known_hosts -n prod|-F $K3/ssh_config -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$K3/known_hosts prod"
chk "each ssh without -n gets a kit file (or full-render-diff.py + a kit file) on stdin" "$(awk -F'\t' '$4 !~ / -n prod$/ {print $2}' "$T/ssh.log" | sort -u | while read -r s; do case " $KITSHAS " in *" $s "*) ;; *) echo "$s";; esac; done | grep -c .)" 0
chk "children run under env -i + the fixed env (a caller EVILVAR does not reach ssh; cwd /)" "$(awk -F'\t' -v n="$n0" '$1>n {print $5}' "$T/ssh.log" | sort -u)" "HOME=/home/ubuntu LANG=C.UTF-8 LC_ALL=C KUBECONFIG=/etc/rancher/k3s/k3s.yaml PWD=/ EVILVAR="
chk "item 5: the record copy of the inputs = the file bytes (one buffer)" "$(cmp -s "$DH" "$(ls "$T"/logs/PRODROLL-roll-dev-health-*.inputs | head -1)" && echo equal)" equal
n0=$(sshn); pr roll dev-health "$DH" deploy
chk "roll dev-health deploy: rc 0" "$RC" 0; chk "deploy: ONE ssh before the waits" "$(sshafter "$n0" | grep -vc -- '-- wait i19')" 1
chk "item 4: the deploy ssh = clone checks + fetch/ls-remote/first-parent + live newest == pre LIVEREV 425 + the deploy verb, in that order" "$(sshafter "$n0" | head -1 | grep -c 'for t in .*remote.origin.url.*url\\\\\..*status --porcelain.*git fetch -q --no-tags .* refs/heads/main.*git ls-remote .* refs/heads/main.*rev-list --first-parent.*\[ "\$nw" = "425 deployed" \].*bash -s -- deploy i19 f301c670ab2a70f3e7ab4d4f3758e2e53c5f6111$')" 1
chk "deploy: the deploy verb ran" "$([ -e "$T/state/deploy-ran" ] && echo yes)" yes
touch "$T/state/dh-deployed"; n0=$(sshn); pr roll dev-health "$DH" post
chk "roll dev-health post: rc 0" "$RC" 0; chk "post: PODSNAP PASS + TOPCMP PASS" "$(has 'PODSNAP: PASS')$(has 'TOPCMP: PASS')" yesyes
chk "v3h post: the stagecheck ssh carries GROUPDIG='<pre map>' (one single-quoted literal)" "$(sshafter "$n0" | grep -F -- '-- stagecheck i19' | grep -cF "GROUPDIG='heavy:4bdf329325b0,ops:fa9b7cd250de,sync:fa9b7cd250de,sync-provider:fa9b7cd250de,scheduler:fa9b7cd250de,reconciler:fa9b7cd250de,stream-ingest:fa9b7cd250de,stream-external:fa9b7cd250de,stream-pagerduty:fa9b7cd250de'")" 1
chk "v3j post (default path, web not rolled, topsnap unchanged): ONE I7 sample, no wait, no I7-topsnap2/I7-topcmp2" "$(grep -c '^sleep' "$T/sleep.log" 2>/dev/null || echo 0) $(ls "$W/post" | grep -c '^I7-top.*2\.out$') $(grep -c '^TOPCMP: PASS' "$W/post/I7-topcmp.out")" "0 0 1"
chk "post: steps I6 I6m I6p I6l I6s-1 PODSNAP-after I7 in order" "$(sshafter "$n0" | sed -E 's/.*(stagecheck|migjoblog read|-- pgver|liverows|-- scrape|podsnap-i19-s19-a-after|-- topsnap).*/\1/' | paste -sd' ')" "stagecheck migjoblog read -- pgver liverows -- scrape podsnap-i19-s19-a-after -- topsnap"
pr readback scrapecheck "$DH"; chk "readback scrapecheck: rc 0" "$RC" 0
pr readback podsnap "$DH"; chk "readback podsnap: rc 0" "$RC" 0
pr readback dev-health-post "$DH"; chk "readback dev-health-post: rc 0" "$RC" 0
n0=$(sshn); pr rollback dev-health "$DH" s19-a
chk "rollback dev-health <inputs> s19-a: rc 0" "$RC" 0
chk "item 3: rollback target = ROLLBACK_REV 425 = pre LIVEREV, in the history, I9 with it" "$(has 'GATE HISTORY: PASS (rev 425')$(sshafter "$n0" | grep -c 'LIVEREV=425 LIVEREV2= bash -s -- helm-rollback app')$(sshafter "$n0" | grep -c 'LIVEREV=425 LIVEREV2= DEFER_STEPS=4 GUARD_LIVE_STEP=6 IMG_DEPLOYS=none ROLLBACK_IMG_PREFIX= CMDELTA=.. bash -s -- rollcheck i19')" yes11
rm -f "$T/state/dh-deployed" "$T/state/deploy-ran"

DHB=$(mkin dh-b "$DH" -e 's/^RUN_TAG=.*/RUN_TAG=s19-b/')
pr roll dev-health "$DHB" pre; touch "$T/scen/wait3once"; n0=$(sshn); pr roll dev-health "$DHB" deploy; rm -f "$T/scen/wait3once"
chk "deploy, I4 rc 3 once: I3d, I4, I5 once, I4 (rc 0)" "$RC $(sshafter "$n0" | sed -E 's/.*(-- deploy i19|-- wait i19|-- appcheck).*/\1/' | grep -E '^-- (deploy|wait|appcheck)' | paste -sd' ')" "0 -- deploy i19 -- wait i19 -- appcheck -- wait i19"

n0=$(sshn); pr roll ingress-nginx "$ING" pre
WI=$T/logs/PRODROLL-WORK-ingress-nginx-i11699-a
chk "roll ingress-nginx pre: rc 0" "$RC" 0; chk "ingress pre: rows GATE PASS (real full-render-diff.py)" "$(grep -c '^GATE rows.json: PASS$' "$WI/pre/PREFLIGHT-diff.out")" 1
chk "ingress pre: rows.json = rows-11699.json (acc0c437)" "$(sha256sum < "$WI/pre/rows.json" | cut -c1-64)" acc0c4377c3b2eb7616469e7d74a9dc7432a84061923724749ff96a46f9c99a5
chk "item 2: ingress pre gate first: TREE_SHA on the roll tree" "$(sshafter "$n0" | head -1 | grep -c 'for t in /home/ubuntu/lane-prod-k8s/deploy-roll-24d; do.*for s in 309dadea15b861903a9eefb9eb6319f8dfad8c40; do')" 1
chk "P2: no raw manifest on disk" "$(find "$WI" -name '*.manifest' -o -name 'dry.out' | grep -c .)" 0
n0=$(sshn); pr roll ingress-nginx "$ING" upgrade
chk "roll ingress-nginx upgrade: rc 0" "$RC" 0
chk "item 7: the upgrade phase is ONE ssh call" "$(sshafter "$n0" | grep -c .)" 1
chk "item 7: that ssh = gates + P0u (HEAD, values blob, tgz) + newest == 3 + the upgrade line, in that order" "$(sshafter "$n0" | grep -c 'git fetch -q --no-tags.*rev-list --first-parent.*h=$(git rev-parse HEAD.*sha256sum /home/ubuntu/lane-prod-k8s/11647/chart/ingress-nginx-4.14.5.tgz.*\[ "\$nw" = "3 deployed" \].*helm -n ingress-nginx upgrade ingress-nginx /home/ubuntu/lane-prod-k8s/11647/chart/ingress-nginx-4.14.5.tgz --version 4.14.5 -f prod/ingress-nginx.values.yaml --wait --timeout 5m')" 1
pr roll ingress-nginx "$ING" post; chk "roll ingress-nginx post: rc 0" "$RC" 0
pr readback ingress-nginx "$ING"; chk "readback ingress-nginx: R4 PASS" "$(has 'R4: PASS')" yes
n0=$(sshn); pr rollback ingress-nginx "$ING" i11699-a
chk "rollback ingress-nginx: rc 0, helm rollback to ROLLBACK_REV 3" "$RC $(sshafter "$n0" | grep -cF 'helm -n ingress-nginx rollback ingress-nginx 3 --wait --timeout 5m')" "0 1"
n0=$(sshn); pr secret-pipe f1pipe "$F1"
chk "secret-pipe f1pipe: rc 0, 3 GATE PASS, stdin = 8c2e9585" "$RC $(printf '%s\n' "$OUT" | grep -cE '^GATE (M|A-STEP|F1PIPE): PASS') $(awk -F'\t' -v n="$n0" '$1>n && $3 ~ /--norc --noprofile -s/ {print $2}' "$T/ssh.log")" "0 3 8c2e95853d7e89d4f2ef9d9a3eb83a8182f7630089dc41b62c7fd3ac33c5ebe8"

echo "== C. REFUSED (rc 2, before any ssh)"
refused "unknown key" roll dev-health "$(mkin r1 "$DH" -e 's/^RUN_TAG=.*/RUN_TAG=r1/' -e '$a FOO=1')" pre
refused "STEP=19;rm" roll dev-health "$(mkin r2 "$DH" -e 's/^RUN_TAG=.*/RUN_TAG=r2/' -e 's/^STEP=19$/STEP=19;rm -rf x/')" pre
refused 'STEP=$(x)' roll dev-health "$(mkin r3 "$DH" -e 's/^RUN_TAG=.*/RUN_TAG=r3/' -e 's/^STEP=19$/STEP=$(touch PWNED)/')" pre
refused "backtick" roll dev-health "$(mkin r4 "$DH" -e 's/^RUN_TAG=.*/RUN_TAG=r4/' -e 's/^STEP=19$/STEP=`id`/')" pre
refused "CR byte" roll dev-health "$(mkin r5 "$DH" -e 's/^RUN_TAG=.*/RUN_TAG=r5/' -e 's/^STEP=19$/STEP=19\r/')" pre
refused "IMGROW with a quote" roll dev-health "$(mkin r7 "$DH" -e 's/^RUN_TAG=.*/RUN_TAG=r7/' -e "s/!10.42.0.1\$/!10.42.0.1'/")" pre
# v3i (s35-a gap): a FIELD row whose path holds a label key with "/" parses; the run is then refused by a LATER unknown key, so the refusal must not name the IMGROW line.
refused "v3i slash path + a later unknown key" roll dev-health "$(mkin r7s "$DH" -e 's/^RUN_TAG=.*/RUN_TAG=r7s/' -e '$a IMGROW=NetworkPolicy/dev-health-ops-auth-service .spec.egress[3].to[1].podSelector.matchLabels.app.kubernetes.io/name <none> otel-collector' -e '$a FOO=1')" pre
chk "v3i: an IMGROW path with a slash is not a bad IMGROW value" "$(has 'bad value for IMGROW')" no
refused "RENDER_FILE=/etc/passwd" roll dev-health "$(mkin r8 "$DH" -e 's/^RUN_TAG=.*/RUN_TAG=r8/' -e 's|^RENDER_FILE=.*|RENDER_FILE=/etc/passwd|')" pre
refused "TREE is not an inputs key" roll ingress-nginx "$(mkin r10 "$ING" -e 's/^RUN_TAG=.*/RUN_TAG=r10/' -e '$a TREE=/home/ubuntu/lane-prod-k8s/x')" pre
refused "TGZ_SHA256 is not an inputs key" roll ingress-nginx "$(mkin r10b "$ING" -e 's/^RUN_TAG=.*/RUN_TAG=r10b/' -e '$a TGZ_SHA256=0000000000000000000000000000000000000000000000000000000000000000')" pre
refused "duplicate key" roll dev-health "$(mkin r11 "$DH" -e 's/^RUN_TAG=.*/RUN_TAG=r11/' -e '$a STEP=19')" pre
refused "TARGET mismatch" roll dev-health "$(mkin r12 "$DH" -e 's/^RUN_TAG=.*/RUN_TAG=r12/' -e 's/^TARGET=.*/TARGET=ingress-nginx/')" pre
refused "PRODROLL_INPUTS=2 (a v2 file)" roll dev-health "$(mkin r12b "$DH" -e 's/^RUN_TAG=.*/RUN_TAG=r12b/' -e 's/^PRODROLL_INPUTS=3$/PRODROLL_INPUTS=2/')" pre
refused "RENDER_SHA256 mismatch" roll dev-health "$(mkin r14 "$DH" -e 's/^RUN_TAG=.*/RUN_TAG=r14/' -e 's/^RENDER_SHA256=3/RENDER_SHA256=4/')" pre
ln -s "$DH" "$T/in/link.txt"; refused "inputs file is a symlink" roll dev-health "$T/in/link.txt" pre
refused "lowercase key" roll dev-health "$(mkin r15 "$DH" -e 's/^RUN_TAG=.*/RUN_TAG=r15/' -e 's/^STEP=19$/step=19/')" pre
refused "non-ASCII byte" roll dev-health "$(mkin r18 "$DH" -e 's/^RUN_TAG=.*/RUN_TAG=r18/' -e 's/^STEP=19$/STEP=19\xc3\xa9/')" pre
refused "13 ASTEP_LINE lines" secret-pipe f1pipe "$(mkin r19 "$F1" -e 's/^RUN_TAG=.*/RUN_TAG=r19/' -e '$d')"
cp -- "$DH" /tmp/prodroll-v3-test-in-$$.txt; refused "inputs path outside the roots (/tmp)" roll dev-health /tmp/prodroll-v3-test-in-$$.txt pre; rm -f -- /tmp/prodroll-v3-test-in-$$.txt
refused "stub: secret-pipe load-secrets" secret-pipe load-secrets "$F1"
refused "pre again on the same RUN_TAG" roll dev-health "$DH" pre
refused "deploy twice" roll dev-health "$DH" deploy
refused "post with a changed inputs file (same RUN_TAG)" roll dev-health "$(mkin r24 "$DHB" -e '$a # a comment changes the sha')" post
chk "no PWNED file anywhere" "$(find "$T" -name PWNED | wc -l)" 0
echo "-- item 5: one buffer"
NUL=$(mkin_na nul "$DH" -e 's/^RUN_TAG=.*/RUN_TAG=nul/' -e 's/^STEP=19$/STEP=19\x00/'); attest "$T" "$NUL"; refused "a NUL byte (the buffer is shorter than the file)" roll dev-health "$NUL" pre
chk "NUL: named" "$(has 'holds a NUL byte')" yes
echo "-- item 6: the attest file"
refused "inputs sha not in ATTEST-INPUTS.txt" roll dev-health "$(mkin_na na1 "$DH" -e 's/^RUN_TAG=.*/RUN_TAG=na1/')" pre
chk "not-attested: the message names ATTEST-INPUTS.txt" "$(has 'ATTEST-INPUTS.txt')" yes
NA2=$(mkin na2 "$DH" -e 's/^RUN_TAG=.*/RUN_TAG=na2/'); printf '# x\n' >> "$NA2"; refused "inputs edited after the attest line" roll dev-health "$NA2" pre
mv "$T/ATTEST-INPUTS.txt" "$T/ATTEST-INPUTS.txt.away"; refused "the attest file is missing" readback dev-health-post "$DH"; mv "$T/ATTEST-INPUTS.txt.away" "$T/ATTEST-INPUTS.txt"
echo "-- item 3: ROLLBACK_REV"
refused "ROLLBACK_REV missing (mandatory)" roll dev-health "$(mkin rr1 "$DH" -e 's/^RUN_TAG=.*/RUN_TAG=rr1/' -e '/^ROLLBACK_REV=/d')" pre
refused "ROLLBACK_REV != EXP_START_REV" roll dev-health "$(mkin rr2 "$DH" -e 's/^RUN_TAG=.*/RUN_TAG=rr2/' -e 's/^ROLLBACK_REV=.*/ROLLBACK_REV=424/')" pre
refused "ingress ROLLBACK_REV missing (mandatory)" roll ingress-nginx "$(mkin rr3 "$ING" -e 's/^RUN_TAG=.*/RUN_TAG=rr3/' -e '/^ROLLBACK_REV=/d')" pre
DHL=$(mkin dh-l "$DH" -e 's/^RUN_TAG=.*/RUN_TAG=s19-l/'); echo 424 > "$T/scen/livrev"; n0=$(sshn); pr roll dev-health "$DHL" pre; rm -f "$T/scen/livrev"
chk "item 3: pre: the LIVEREV read live (424) != ROLLBACK_REV 425: STOP rc 1, nothing after I1" "$RC $(sshafter "$n0" | tail -1 | grep -c 'helmrev app')" "1 1"
refused "rollback: argv RUN_TAG != the inputs RUN_TAG" rollback dev-health "$DH" s19-b
refused "rollback: absent RUN_TAG" rollback dev-health "$(mkin rb1 "$DH" -e 's/^RUN_TAG=.*/RUN_TAG=s19-z/')" s19-z
refused "rollback: a foreign inputs file on an existing RUN_TAG" rollback dev-health "$(mkin rb2 "$DHB" -e '$a # foreign')" s19-b
DHP=$(mkin dh-p "$DH" -e 's/^RUN_TAG=.*/RUN_TAG=s19-p/'); pr roll dev-health "$DHP" pre
refused "rollback: pre.pass but no deploy.started" rollback dev-health "$DHP" s19-p
DHR=$(mkin dh-r "$DH" -e 's/^RUN_TAG=.*/RUN_TAG=s19-r/'); pr roll dev-health "$DHR" pre; pr roll dev-health "$DHR" deploy; rm -f "$T/state/deploy-ran"
WR=$T/logs/PRODROLL-WORK-dev-health-i19-s19-r
sed -i 's/^LIVEREV=425$/LIVEREV=424/' "$WR/state.txt"; refused "rollback: state LIVEREV 424 != the pre-log record 425" rollback dev-health "$DHR" s19-r
sed -i 's/^STATE LIVEREV=425$/STATE LIVEREV=424/' "$WR/pre/I1.out"; refused "rollback: ROLLBACK_REV 425 != state + log LIVEREV 424" rollback dev-health "$DHR" s19-r
chk "rollback: the mismatch names ROLLBACK_REV and LIVEREV" "$(has 'ROLLBACK_REV 425 != the LIVEREV 424')" yes
DHH=$(mkin dh-h "$DH" -e 's/^RUN_TAG=.*/RUN_TAG=s19-h/'); pr roll dev-health "$DHH" pre; pr roll dev-health "$DHH" deploy; rm -f "$T/state/deploy-ran"
touch "$T/scen/dh-hist-missing" "$T/state/dh-deployed"; n0=$(sshn); pr rollback dev-health "$DHH" s19-h; rm -f "$T/scen/dh-hist-missing" "$T/state/dh-deployed"
chk "item 3: rollback rev 425 not in the live helm history: STOP rc 1, no helm-rollback" "$RC $(sshafter "$n0" | grep -c 'helm-rollback')" "1 0"
echo "-- item 4: deploy re-checks live in the I3d ssh; forged state is not trusted"
DHS=$(mkin dh-s "$DH" -e 's/^RUN_TAG=.*/RUN_TAG=s19-s/'); pr roll dev-health "$DHS" pre
WS=$T/logs/PRODROLL-WORK-dev-health-i19-s19-s; old=$(( $(date -u +%s) - 2000 )); sed -i "s/^PREEND=.*/PREEND=$old/" "$WS/state.txt"
refused "deploy: the pre phase is older than 1800 s" roll dev-health "$DHS" deploy
DHF=$(mkin dh-fg "$DH" -e 's/^RUN_TAG=.*/RUN_TAG=s19-fg/'); WF=$T/logs/PRODROLL-WORK-dev-health-i19-s19-fg
mkdir -p "$WF/pre"; sha256sum < "$DHF" | cut -c1-64 > "$WF/inputs.sha256"; printf 'LIVEREV=425\nRESTARTS0=0\nPREEND=%s\n' "$(date -u +%s)" > "$WF/state.txt"; : > "$WF/pre.pass"
echo 424 > "$T/scen/dh-newest"; n0=$(sshn); pr roll dev-health "$DHF" deploy; rm -f "$T/scen/dh-newest"
chk "forged pre.pass/state.txt (no real pre): deploy still re-checks live in the I3d ssh and STOPs (live 424 != 425)" "$RC $(has 'GATE-REMOTE STOP: live newest revision [424 deployed]')" "1 yes"
chk "forged state: the deploy verb did not run" "$([ -e "$T/state/deploy-ran" ] && echo ran || echo no)" no
DHM=$(mkin dh-m "$DH" -e 's/^RUN_TAG=.*/RUN_TAG=s19-m/'); pr roll dev-health "$DHM" pre; echo 9 > "$T/scen/anc-not"; echo f301c670ab2a70f3e7ab4d4f3758e2e53c5f6111 > "$T/scen/fp-not"; n0=$(sshn); pr roll dev-health "$DHM" deploy; rm -f "$T/scen/anc-not" "$T/scen/fp-not"
chk "item 2/4: SVC_SHA off the first-parent chain at deploy time: STOP in the I3d ssh, no deploy verb" "$RC $(has 'is not on the first-parent chain') $([ -e "$T/state/deploy-ran" ] && echo ran || echo no)" "1 yes no"

echo "== D. kit SUMS and the self-check (rc 6, before any ssh)"
sums_case() { local name=$1 d=$T/k-$2; mkcopy "$d"; shift 2; "$@" "$d"; local n0 f; n0=$(sshn); f=$(mkin_na "s$RANDOM" "$DH" -e "s/^RUN_TAG=.*/RUN_TAG=k$RANDOM/"); attest "$d" "$f"; run "$d/prodroll.sh" roll dev-health "$f" pre
  chk "rc 6: $name" "$RC" 6; chk "rc 6 REFUSED line: $name" "$(has 'PRODROLL REFUSED (exit 6)')" yes; chk "rc 6 no ssh: $name" "$(sshn)" "$n0"; }
m_byte() { printf '#' >> "$1/prodroll-v3/ROLL-24d.sh"; }
m_extra() { echo x > "$1/prodroll-v3/extra.sh"; }
m_sums() { sed -i '1s/^./0/' "$1/prodroll-v3/SHA256SUMS"; }
m_f1() { sed -i 's/^set +a$/set -a/' "$1/prodroll-v3/f1pipe-11709.sh"; }
m_known() { printf '10.0.0.151 ssh-ed25519 AAAAattacker\n' >> "$1/prodroll-v3/known_hosts"; }
m_cfglink() { mv "$1/prodroll-v3/ssh_config" "$1/ssh_config.real"; ln -s ../ssh_config.real "$1/prodroll-v3/ssh_config"; }
m_self() { sed -i 's/^# Exit: 0 PASS/# Exit: 0 PASS!/' "$1/prodroll.sh"; }
m_selfpin() { sed -i 's/^PINNED_SELF_SHA256=./PINNED_SELF_SHA256=x/' "$1/prodroll.sh"; }
sums_case "a byte appended to ROLL-24d.sh" 1 m_byte
sums_case "an unlisted extra file" 2 m_extra
sums_case "SHA256SUMS edited" 3 m_sums
sums_case "f1pipe-11709.sh edited" 4 m_f1
sums_case "known_hosts with an added host key" 5 m_known
sums_case "ssh_config is a symlink" 6 m_cfglink
sums_case "item 7: prodroll.sh edited (a comment)" 7 m_self
sums_case "item 7: the PINNED_SELF_SHA256 line edited" 8 m_selfpin

echo "== E. xtrace and PATH"
n0=$(sshn); run bash -x "$T/prodroll.sh" roll dev-health "$DH" pre; chk "bash -x: rc 10, no ssh" "$RC $(sshn)" "10 $n0"
run env SHELLOPTS=xtrace bash "$T/prodroll.sh" roll dev-health "$DH" pre; chk "SHELLOPTS=xtrace bash: rc 10" "$RC" 10
mkdir -p "$T/k-path"; mkcopy "$T/k-path"; f=$(mkin_na pth "$DH" -e 's/^RUN_TAG=.*/RUN_TAG=pth/'); attest "$T/k-path" "$f"
run env PATH="$T/usrlocal/bin:/usr/local/bin:$PATH" "$T/k-path/prodroll.sh" readback dev-health-post "$f"
chk "a fake sha256sum/readlink first on the caller PATH is never used: rc 0, 0 calls" "$RC $(cat "$T/usrlocal-calls.log" 2>/dev/null | wc -l)" "0 0"
run env PRODROLL_TEST_PATH="$T/hashspy" "$T/prodroll.sh" roll dev-health "$DH" now
chk "a usage error: rc 2, line 1 sums=- inputs=-, hashes only the script" "$RC $(printf '%s\n' "$OUT" | head -1 | grep -c ' sums=- inputs=- sha256(inputs)=- cmd=usage-error$') $(cat "$T/hashspy.log" 2>/dev/null | sed 's/ $//' | paste -sd'|')" "2 1 $T/prodroll.sh"

echo "== F. item 6: success = rc 0 AND the tool's final PASS line"
DHN=$(mkin dh-n "$DH" -e 's/^RUN_TAG=.*/RUN_TAG=s19-n/'); touch "$T/scen/guards-nopass"; n0=$(sshn); pr roll dev-health "$DHN" pre; rm -f "$T/scen/guards-nopass"
chk "guards rc 0 without 'HOOKGUARD PASS': STOP, no RENDER-PATHS after" "$RC $(has 'I3g rc=0 but its final line is not the tool') $(sshafter "$n0" | grep -c 'deploy-rollback-24d deploy-roll-24d')" "1 yes 0"
DHO=$(mkin dh-o "$DH" -e 's/^RUN_TAG=.*/RUN_TAG=s19-o/'); pr roll dev-health "$DHO" pre; pr roll dev-health "$DHO" deploy; rm -f "$T/state/deploy-ran"
touch "$T/scen/stage-nopass"; n0=$(sshn); pr roll dev-health "$DHO" post; rm -f "$T/scen/stage-nopass"
chk "stagecheck rc 0 without 'STAGECHECK: PASS': STOP, nothing after I6" "$RC $(sshafter "$n0" | grep -vc stagecheck)" "1 0"
DHW=$(mkin dh-w "$DH" -e 's/^RUN_TAG=.*/RUN_TAG=s19-w/'); pr roll dev-health "$DHW" pre; pr roll dev-health "$DHW" deploy; rm -f "$T/state/deploy-ran"
touch "$T/scen/stage-failword"; pr roll dev-health "$DHW" post; rm -f "$T/scen/stage-failword"
chk "a FAIL word with rc 0 and a PASS line: still STOP" "$RC" 1
DHA=$(mkin dh-an "$DH" -e 's/^RUN_TAG=.*/RUN_TAG=s19-an/'); echo f301c670ab2a70f3e7ab4d4f3758e2e53c5f6111 > "$T/scen/anc-not"; n0=$(sshn); pr roll dev-health "$DHA" pre; rm -f "$T/scen/anc-not"
chk "pre: SVC_SHA not an ancestor: STOP, only the gate ssh ran" "$RC $(sshafter "$n0" | grep -vc 'git ls-remote')" "1 0"
DHU=$(mkin dh-u "$DH" -e 's/^RUN_TAG=.*/RUN_TAG=s19-u/'); touch "$T/scen/url-insteadof"; n0=$(sshn); pr roll dev-health "$DHU" pre; rm -f "$T/scen/url-insteadof"
chk "item 4 (clone): a url.* key: STOP, nothing after the gate" "$RC $(has 'url.* key(s)') $(sshafter "$n0" | grep -vc 'git ls-remote')" "1 yes 0"
DHG=$(mkin dh-g "$DH" -e 's/^RUN_TAG=.*/RUN_TAG=s19-g/'); pr roll dev-health "$DHG" pre; pr roll dev-health "$DHG" deploy; rm -f "$T/state/deploy-ran"; touch "$T/scen/podsnap-bad"; pr roll dev-health "$DHG" post; rm -f "$T/scen/podsnap-bad"
chk "PODSNAP: a non-target pod changed: rc 1" "$RC $(has 'CHANGED dev-health-ops-auth-service')" "1 yes"
INGB=$(mkin ing-b "$ING" -e 's/^RUN_TAG=.*/RUN_TAG=i11699-b/'); rm -f "$T/state/upgraded"; pr roll ingress-nginx "$INGB" pre; touch "$T/scen/p0-dirty"; n0=$(sshn); pr roll ingress-nginx "$INGB" upgrade; rm -f "$T/scen/p0-dirty"
chk "item 7: P0u fails inside the upgrade ssh: STOP, the upgrade did not run" "$RC $(has 'GATE-REMOTE STOP: P0u') $([ -e "$T/state/upgraded" ] && echo ran || echo no)" "1 yes no"
INGP=$(mkin ing-p "$ING" -e 's/^RUN_TAG=.*/RUN_TAG=i11699-p/' -e 's/^EXP_START_REV=3$/EXP_START_REV=2/' -e 's/^ROLLBACK_REV=3$/ROLLBACK_REV=2/' -e 's/^EXPECT_NEWEST_REV=4$/EXPECT_NEWEST_REV=3/'); pr roll ingress-nginx "$INGP" pre
chk "ingress: EXP_START_REV/ROLLBACK_REV 2 != the live P1 rev 3: STOP rc 1" "$RC" 1
INGS=$(mkin ing-s "$ING" -e 's/^RUN_TAG=.*/RUN_TAG=i11699-s/'); touch "$T/scen/secret-docs"; pr roll ingress-nginx "$INGS" pre; rm -f "$T/scen/secret-docs"
chk "P2: Secret docs in both manifests (control: emitted): pre PASS, no sentinel, no kind: Secret on disk" "$(sort "$T/state/secret-emitted" | paste -sd' ') $RC $(grep -rl -e 'SENTINEL-SECRET-VALUE-0123' -e 'U0VOVElORUwtU0VDUkVULVZBTFVFLTAxMjM=' "$T/logs" | wc -l) $(grep -rlx 'kind: Secret' "$T/logs" | wc -l)" "dry live 0 0 0"
F1C=$(mkin f1-c "$F1" -e 's/^RUN_TAG=.*/RUN_TAG=f1-c/'); touch "$T/scen/marker-present"; n0=$(sshn); pr secret-pipe f1pipe "$F1C"; rm -f "$T/scen/marker-present"
chk "gate M PRESENT: rc 1, nothing after gate M" "$RC $(sshafter "$n0" | grep -vc 'pg-owner-rotation.marker')" "1 0"

echo "== G. items 1, 2, 4 with REAL git: the exact remote gate text of the pre ssh, on throw-away local repos"
GT=$(awk -F'\t' '$3 ~ /git ls-remote/ && $3 ~ /deploy-rollback-24d; do/ {print $3; exit}' "$T/ssh.log")
G=$T/git; mkdir -p "$G/home" "$G/wrap"
gx() { env -i PATH=/usr/bin:/bin HOME="$G/home" GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t "$@"; }
gx git init -q --bare -b main "$G/origin.git"; gx git init -q -b main "$G/src"
cm() { echo "$1" > "$G/src/$1"; gx git -C "$G/src" add "$1"; gx git -C "$G/src" commit -q -m "$1"; gx git -C "$G/src" rev-parse HEAD; }
C1=$(cm c1); C2=$(cm c2); gx git -C "$G/src" checkout -q -b side "$C1"; C3=$(cm c3); gx git -C "$G/src" checkout -q main; gx git -C "$G/src" merge -q --no-ff side -m merge; C4=$(gx git -C "$G/src" rev-parse HEAD)
gx git -C "$G/src" checkout -q --orphan other; gx git -C "$G/src" rm -q -rf . ; C5=$(cm c5); gx git -C "$G/src" tag main "$C5"
gx git -C "$G/src" push -q "$G/origin.git" refs/heads/main:refs/heads/main refs/tags/main:refs/tags/main 2>/dev/null
gx git clone -q "$G/origin.git" "$G/roll" 2>/dev/null; gx git clone -q "$G/origin.git" "$G/rb" 2>/dev/null
gcmd() { printf '%s' "$GT" | sed -e "s|/home/ubuntu/lane-prod-k8s/deploy-roll-24d|$G/roll|g" -e "s|/home/ubuntu/lane-prod-k8s/deploy-rollback-24d|$G/rb|g" -e "s|https://github.com/full-chaos/dev-health-deploy.git|$G/origin.git|g" -e "s|f301c670ab2a70f3e7ab4d4f3758e2e53c5f6111|$1|g" -e "s|309dadea15b861903a9eefb9eb6319f8dfad8c40|$2|g"; }
grun() { local p=$1; shift; OUT=$(env -i PATH="$p" HOME="$G/home" GIT_CONFIG_NOSYSTEM=1 bash -c "$(gcmd "$@")" 2>&1); RC=$?; }   # the real-git harness runs the extracted remote text
chk "the extracted pre gate text is the one-ssh form" "$(printf '%s' "$GT" | grep -c "git fetch -q --no-tags https://github.com/full-chaos/dev-health-deploy.git refs/heads/main")" 1
chk "control: origin has BOTH a branch main and a tag main (the tag on a commit off main)" "$(gx git ls-remote "$G/origin.git" main | awk '{print $2}' | sort | paste -sd' ')" "refs/heads/main refs/tags/main"
grun /usr/bin:/bin "$C2" "$C1"; chk "happy: c2 + c1 (first-parent commits of main): GATE-REMOTE: PASS" "$RC $(printf '%s\n' "$OUT" | tail -1)" "0 GATE-REMOTE: PASS"
chk "item 1: MAIN = the branch tip c4, not the tag main (c5)" "$(printf '%s\n' "$OUT" | grep -c "^MAIN $C4 = ls-remote refs/heads/main$")" 1
grun /usr/bin:/bin "$C5" "$C1"; chk "item 1: the commit of the tag named main: STOP (not an ancestor of refs/heads/main), rc 3" "$RC $(printf '%s\n' "$OUT" | grep -c "GATE-REMOTE STOP: $C5 is not an ancestor")" "3 1"
grun /usr/bin:/bin "$C3" "$C1"; chk "item 2: c3 (merged, an ancestor, NOT first-parent): STOP rc 3" "$RC $(printf '%s\n' "$OUT" | grep -c "GATE-REMOTE STOP: $C3 is not on the first-parent chain")" "3 1"
grun /usr/bin:/bin "$C2" "$C3"; chk "item 2: ROLLBACK_SHA off the first-parent chain: STOP rc 3" "$RC" 3
printf '#!/bin/bash\nif [ "$1" = ls-remote ]; then printf "1111111111111111111111111111111111111111\\trefs/heads/main\\n"; exit 0; fi\nexec /usr/bin/git "$@"\n' > "$G/wrap/git"; chmod 0755 "$G/wrap/git"
grun "$G/wrap:/usr/bin:/bin" "$C2" "$C1"; chk "item 1: fetched sha != ls-remote refs/heads/main: STOP rc 3" "$RC $(printf '%s\n' "$OUT" | grep -c 'GATE-REMOTE STOP: fetched main')" "3 1"
gx git -C "$G/roll" config url."$G/evil.git".insteadOf "$G/origin.git"; grun /usr/bin:/bin "$C2" "$C1"; gx git -C "$G/roll" config --unset url."$G/evil.git".insteadOf
chk "item 4: url.<x>.insteadOf in the roll tree config: STOP rc 3" "$RC $(printf '%s\n' "$OUT" | grep -c 'url.\* key(s) in its git config')" "3 1"
gx git -C "$G/rb" remote set-url origin "$G/other.git"; grun /usr/bin:/bin "$C2" "$C1"; gx git -C "$G/rb" remote set-url origin "$G/origin.git"
chk "item 4: remote.origin.url != the pinned URL (rollback tree): STOP rc 3" "$RC $(printf '%s\n' "$OUT" | grep -c 'remote.origin.url is not the pinned URL')" "3 1"
echo x > "$G/roll/untracked.txt"; grun /usr/bin:/bin "$C2" "$C1"; rm -f "$G/roll/untracked.txt"
chk "item 4: an untracked file (git status --porcelain not empty): STOP rc 3" "$RC $(printf '%s\n' "$OUT" | grep -c 'git status --porcelain shows 1 line')" "3 1"
grun /usr/bin:/bin "$C2" "$C1"; chk "after the cases: happy again (the harness restored the repos)" "$RC" 0

echo "== R. acp v3 refusal: P1-1, P1-2, P3(a), P3(b) (written RED against v3 82cee47d first, then GREEN on v3b)"
NOIN=/var/lib/oci-cache/lane-scratch/prodroll-v3b-no-such-inputs.txt   # never exists: a run that gets past the gates stops at the inputs (rc 2), never at an ssh
[ ! -e "$NOIN" ] || { echo "FAIL setup: $NOIN exists"; exit 1; }
repin() { local f=$1 n h; n=$(grep -n '^PINNED_SELF_SHA256' "$f" | head -1 | cut -d: -f1); h=$(sed "${n}d" "$f" | sha256sum | cut -c1-64); sed -i "${n}s/.*/PINNED_SELF_SHA256=$h/" "$f"; }
pin_of() { sed -n 's/^PINNED_SELF_SHA256=\([0-9a-f]\{64\}\).*/\1/p' "$1" | head -1; }
echo "-- P1-1: the self-check bypass"
d=$T/r-troj; mkcopy "$d"; p=$(pin_of "$d/prodroll.sh"); sed -i "s/^PINNED_SELF_SHA256=.*/PINNED_SELF_SHA256=$p; echo TROJAN-RAN/" "$d/prodroll.sh"
n0=$(sshn); run "$d/prodroll.sh" roll dev-health "$NOIN" pre
chk "P1-1: a trojan on the pin line (PINNED_SELF_SHA256=<pin>; echo TROJAN-RAN): rc 6" "$RC" 6
chk "P1-1: the trojan never ran (TROJAN-RAN printed 0 times)" "$(printf '%s\n' "$OUT" | grep -c TROJAN-RAN)" 0
chk "P1-1: no ssh" "$(sshn)" "$n0"
d=$T/r-dup; mkcopy "$d"; n=$(grep -n '^PINNED_SELF_SHA256' "$d/prodroll.sh" | head -1 | cut -d: -f1); sed -i "${n}p" "$d/prodroll.sh"
run "$d/prodroll.sh" roll dev-health "$NOIN" pre; chk "P1-1: a second PINNED_SELF_SHA256= line (a byte-equal duplicate): rc 6" "$RC" 6
d=$T/r-dup2; mkcopy "$d"; n=$(grep -n '^PINNED_SELF_SHA256' "$d/prodroll.sh" | head -1 | cut -d: -f1); sed -i "${n}a PINNED_SELF_SHA256X=1" "$d/prodroll.sh"
run "$d/prodroll.sh" roll dev-health "$NOIN" pre; chk "P1-1: a second line with the PINNED_SELF_SHA256 prefix: rc 6" "$RC" 6
d=$T/r-up; mkcopy "$d"; sed -i 's/^# Exit: 0 PASS/# Exit: 0 PASS (an edited comment)/' "$d/prodroll.sh"; repin "$d/prodroll.sh"
run "$d/prodroll.sh" roll dev-health "$NOIN" pre; chk "P1-1 control: an edited copy, re-pinned on its one exact pin line, passes the self-check (rc 2 at the inputs)" "$RC $(has 'mode=copy')" "2 yes"
echo "-- P1-2: a symlinked install must not become copy mode"
prodlike() { # $1 = the real dir; $2 = the PROD_SELF this copy names. Points the prod-only constants into $T and re-pins (a test copy only)
  mkdir -p "$1/logs"; cp -- "$SRC/prodroll.sh" "$1/prodroll.sh"; cp -a -- "$SRC/prodroll-v3" "$1/prodroll-v3"
  sed -i -e "s|^PROD_SELF=.*|PROD_SELF=$2|" -e "s|LOGDIR=/home/ubuntu/devhealth/.remember/acr-mcp/lanes/fcc-window-1028|LOGDIR=$T/pl-logs|" -e "s|ATTEST=/home/ubuntu/devhealth/.remember/acr-mcp/lanes/fcc-11788/ATTEST-INPUTS.txt|ATTEST=$T/pl-attest.txt|" "$1/prodroll.sh"; repin "$1/prodroll.sh"; }
mkdir -p "$T/pl-logs"; : > "$T/pl-attest.txt"
prodlike "$T/pl1/shared" "$T/pl1/shared/prodroll.sh"; n0=$(sshn); run "$T/pl1/shared/prodroll.sh" roll dev-health "$NOIN" pre
chk "P1-2 control: the genuine prod layout (no link): mode=prod, rc 2 at the inputs, no ssh" "$RC $(has 'mode=prod') $(sshn)" "2 yes $n0"
prodlike "$T/pl2/real" "$T/pl2/shared/prodroll.sh"; mkdir -p "$T/pl2/shared"; ln -s ../real/prodroll.sh "$T/pl2/shared/prodroll.sh"
n0=$(sshn); run "$T/pl2/shared/prodroll.sh" roll dev-health "$NOIN" pre
chk "P1-2: the prod path is a symlink to a byte-equal copy: rc 6" "$RC" 6; chk "P1-2: symlinked file: never mode=copy" "$(has 'mode=copy')" no; chk "P1-2: symlinked file: no ssh" "$(sshn)" "$n0"
prodlike "$T/pl3/realdir" "$T/pl3/shared/prodroll.sh"; ln -s realdir "$T/pl3/shared"
n0=$(sshn); run "$T/pl3/shared/prodroll.sh" roll dev-health "$NOIN" pre
chk "P1-2: a parent dir of the prod path is a symlink: rc 6" "$RC" 6; chk "P1-2: symlinked parent: never mode=copy" "$(has 'mode=copy')" no
n0=$(sshn); run env -u PRODROLL_TEST_PATH "$T/prodroll.sh" roll dev-health "$NOIN" pre
chk "P1-2: copy mode WITHOUT PRODROLL_TEST_PATH: refused rc 6 before any ssh" "$RC $(has 'copy mode') $(sshn)" "6 yes $n0"
run env PRODROLL_TEST_PATH="$T/hashspy" "$T/prodroll.sh" roll dev-health "$NOIN" pre
chk "P1-2: copy mode with a test path that has no ssh: refused rc 6 (a copy can never reach the real ssh)" "$RC" 6
run env PRODROLL_TEST_PATH='relative/path' "$T/prodroll.sh" roll dev-health "$NOIN" pre
chk "P1-2: copy mode with an invalid test path: refused rc 6" "$RC" 6
echo "-- P3(a): helm upgrade/rollback with long output and rc 0 (the exact remote text from this run's ssh log)"
mkdir -p "$T/longhelm" "$T/fake-tree"; printf '#!/bin/bash\nfor i in $(seq 1 200000); do echo "helm output line $i"; done\nexit 0\n' > "$T/longhelm/helm"; chmod 0755 "$T/longhelm/helm"
RBC=$(awk -F'\t' '$3 ~ /helm -n ingress-nginx rollback ingress-nginx 3 --wait/ {print $3; exit}' "$T/ssh.log")
UPC=$(awk -F'\t' '$3 ~ /helm -n ingress-nginx upgrade ingress-nginx .*--wait --timeout 5m/ {print $3; exit}' "$T/ssh.log" | sed -e "s/.*echo 'GATE-REMOTE: PASS'; //" -e "s|/home/ubuntu/lane-prod-k8s/deploy-roll-24d|$T/fake-tree|g")
chk "P3(a): the rollback and upgrade texts were found in the ssh log" "$([ -n "$RBC" ] && [ -n "$UPC" ] && echo yes)" yes
OUT=$(env -i PATH="$T/longhelm:/usr/bin:/bin" bash -c "$RBC" 2>&1); chk "P3(a): helm rollback rc 0 + 200000 output lines: 'rollback rc=0' (not 141)" "$(printf '%s\n' "$OUT" | grep -E '^rollback rc=' )" "rollback rc=0"
OUT=$(env -i PATH="$T/longhelm:/usr/bin:/bin" bash -c "$UPC" 2>&1); chk "P3(a): helm upgrade rc 0 + 200000 output lines: 'upgrade rc=0' (not 141)" "$(printf '%s\n' "$OUT" | grep -E '^upgrade rc=' )" "upgrade rc=0"
chk "P3(a): the first lines of the helm output still print (12 at most)" "$(printf '%s\n' "$OUT" | grep -c '^helm output line ')" 12
echo "-- P3(b): EXPECT_NEWEST_REV must be EXP_START_REV + 1"
refused "P3(b): dev-health EXPECT_NEWEST_REV 427 = EXP_START_REV 425 + 2" roll dev-health "$(mkin rx1 "$DH" -e 's/^RUN_TAG=.*/RUN_TAG=rx1/' -e 's/^EXPECT_NEWEST_REV=.*/EXPECT_NEWEST_REV=427/')" pre
refused "P3(b): ingress EXPECT_NEWEST_REV 5 = EXP_START_REV 3 + 2" roll ingress-nginx "$(mkin rx2 "$ING" -e 's/^RUN_TAG=.*/RUN_TAG=rx2/' -e 's/^EXPECT_NEWEST_REV=.*/EXPECT_NEWEST_REV=5/')" pre

echo "== R2. acp v3b P2s: the pin line position + line 1; the copy gate (written RED against v3b cca8ddf9 first, then GREEN on v3c)"
d=$T/r2-pinpos; mkcopy "$d"; sed -i '1G' "$d/prodroll.sh"; repin "$d/prodroll.sh"
chk "control: the moved pin is re-pinned on its one exact line (now line $(grep -n '^PINNED_SELF_SHA256' "$d/prodroll.sh" | cut -d: -f1))" "$(grep -n '^PINNED_SELF_SHA256' "$d/prodroll.sh" | cut -d: -f1)" 35
n0=$(sshn); run "$d/prodroll.sh" roll dev-health "$NOIN" pre
chk "P2-1: the pin line moved to line 35 (a line added above it, re-pinned): rc 6" "$RC $(has 'not line 34')" "6 yes"
d=$T/r2-shebang; mkcopy "$d"; sed -i '1s|.*|#!/bin/bash|' "$d/prodroll.sh"; repin "$d/prodroll.sh"
run "$d/prodroll.sh" roll dev-health "$NOIN" pre
chk "P2-1: line 1 = #!/bin/bash (no -p), re-pinned: rc 6" "$RC $(has 'line 1 is not #!/bin/bash -p')" "6 yes"
chk "P2-1: no ssh" "$(sshn)" "$n0"
run env PRODROLL_TEST_PATH=/usr/bin "$T/prodroll.sh" roll dev-health "$NOIN" pre
chk "P2-2: PRODROLL_TEST_PATH=/usr/bin (the real ssh): rc 6" "$RC $(has 'copy mode')" "6 yes"
run env PRODROLL_TEST_PATH=/bin "$T/prodroll.sh" roll dev-health "$NOIN" pre
chk "P2-2: PRODROLL_TEST_PATH=/bin (/bin/ssh -ef /usr/bin/ssh): rc 6" "$RC" 6
mkdir -p "$T/realssh"; ln -s /usr/bin/ssh "$T/realssh/ssh"
run env PRODROLL_TEST_PATH="$T/realssh" "$T/prodroll.sh" roll dev-health "$NOIN" pre
chk "P2-2: a test path under lane-scratch whose ssh is a link to the real /usr/bin/ssh (-ef): rc 6" "$RC" 6
TMPF=/tmp/prodroll-v3c-fake-$$; mkdir -p "$TMPF"; cp -- "$T/fakebin/ssh" "$TMPF/ssh"
run env PRODROLL_TEST_PATH="$TMPF" "$T/prodroll.sh" roll dev-health "$NOIN" pre; rm -rf -- "${TMPF:?}"
chk "P2-2: a fake ssh outside /var/lib/oci-cache/lane-scratch/ (/tmp): rc 6" "$RC" 6
run env PRODROLL_TEST_PATH="$T/fakebin/../fakebin" "$T/prodroll.sh" roll dev-health "$NOIN" pre
chk "P2-2: a test path with a .. component: rc 6" "$RC" 6
chk "P2-2: no ssh in any of the cases above" "$(sshn)" "$n0"
run "$T/prodroll.sh" roll dev-health "$NOIN" pre
chk "P2-2 control: the real test path (fake ssh under lane-scratch) passes the gate (rc 2 at the inputs, mode=copy)" "$RC $(has 'mode=copy')" "2 yes"

echo "== R3. D6436: ATTEST lines <sha256> <roll> <UTC> <checker>; inputs AUTHOR; checker != AUTHOR (written RED against v3c ffe34628 first, then GREEN on v3d)"
a3() { mkin_na "$1" "$DH" -e "s/^RUN_TAG=.*/RUN_TAG=$1/"; }
f=$(a3 att3); attest_line "$T" "$f" "test-roll 2026-10-28T19:00:00Z"; n0=$(sshn); pr roll dev-health "$f" pre
chk "R3: only a 3-field line (no checker): REFUSED rc 2, named" "$RC $(has 'fields (want exactly 4)')" "2 yes"
f=$(a3 attself); attest_line "$T" "$f" "test-roll 2026-10-28T19:00:00Z fcc"; pr roll dev-health "$f" pre
chk "R3: checker == AUTHOR (fcc checked its own inputs): REFUSED rc 2, named" "$RC $(has 'checker fcc == AUTHOR fcc')" "2 yes"
f=$(a3 attbad); attest_line "$T" "$f" "test-roll 2026-10-28T19:00:00Z Peer_Lead!"; pr roll dev-health "$f" pre
chk "R3: a bad checker token (Peer_Lead!): REFUSED rc 2, named" "$RC $(has 'is not ^[a-z][a-z0-9-]{1,31}$')" "2 yes"
f=$(a3 att5); attest_line "$T" "$f" "test-roll 2026-10-28T19:00:00Z peer-lead extra"; pr roll dev-health "$f" pre
chk "R3: a 5-field line: REFUSED rc 2" "$RC $(has 'fields (want exactly 4)')" "2 yes"
chk "R3: none of the refused cases ran an ssh" "$(sshn)" "$n0"
f=$(a3 attnoauth); sed -i '/^AUTHOR=/d' "$f"; attest_line "$T" "$f" "test-roll 2026-10-28T19:00:00Z peer-lead"; pr roll dev-health "$f" pre
chk "R3: a missing AUTHOR key: REFUSED rc 2 (missing key AUTHOR)" "$RC $(has 'missing key AUTHOR')" "2 yes"
f=$(a3 attbadauth); sed -i 's/^AUTHOR=.*/AUTHOR=Fcc!/' "$f"; attest_line "$T" "$f" "test-roll 2026-10-28T19:00:00Z peer-lead"; pr roll dev-health "$f" pre
chk "R3: a bad AUTHOR value: REFUSED rc 2" "$RC $(has 'bad value for AUTHOR')" "2 yes"
f=$(a3 attpeer); attest_line "$T" "$f" "test-roll 2026-10-28T19:00:00Z peer-lead"; pr roll dev-health "$f" pre
chk "R3: checker != AUTHOR (peer-lead checked fcc's inputs): pre PASS rc 0, the ATTEST line names the checker" "$RC $(has 'peer check by peer-lead (AUTHOR fcc)')" "0 yes"
f=$(a3 attmix); attest_line "$T" "$f" "test-roll 2026-10-28T19:00:00Z fcc"; attest_line "$T" "$f" "test-roll 2026-10-28T19:00:00Z"; attest_line "$T" "$f" "test-roll 2026-10-28T19:01:00Z fcs"; pr roll dev-health "$f" pre
chk "R3: several lines for one sha (self, 3-field, peer fcs): pre PASS (at least one peer checker)" "$RC $(has 'peer check by fcs (AUTHOR fcc)')" "0 yes"
f=$(a3 attallself); attest_line "$T" "$f" "test-roll 2026-10-28T19:00:00Z fcc"; attest_line "$T" "$f" "test-roll 2026-10-28T19:05:00Z fcc"; pr roll dev-health "$f" pre
chk "R3: several lines, all checker == AUTHOR: REFUSED rc 2" "$RC $(has 'checker fcc == AUTHOR fcc')" "2 yes"
pr roll dev-health "$(a3 attnone)" pre
chk "R3: not listed at all: the refusal text says a peer lead appends the 4 fields (no 'acp appends')" "$RC $(has 'a peer lead appends') $(has 'acp appends')" "2 yes no"

echo "== R4. v3e: REMOVED_DOC/ADDED_DOC (names gate in the I3p + I3d ssh), SECRET_KEEP/HOOK_SECRET/SECRET_KEYS, liverows n/a (written RED against v3d 36f1112d first, then GREEN on v3e)"
EX3E=${EX3E:-$K3/examples}
# the fake helm world is rev 425 live, 426 after the deploy: the step-20 revs (426 -> 427) shift by -1 here; the docs/secret inputs are the example's bytes
REVMAP=(-e 's/^EXP_START_REV=426$/EXP_START_REV=425/' -e 's/^ROLLBACK_REV=426$/ROLLBACK_REV=425/' -e 's/^EXPECT_NEWEST_REV=427$/EXPECT_NEWEST_REV=426/')
D20=$(mkin d20-a "$EX3E/INPUTS-11712-step20-v3e.txt" -e 's/^RUN_TAG=.*/RUN_TAG=s20-a/' "${REVMAP[@]}")
W20=$T/logs/PRODROLL-WORK-dev-health-i20-s20-a
RM3='Secret/dev-health-ops-go-pgbouncer Secret/dev-health-ops-provision-roles-secrets Secret/dev-health-ops-route-activate-secrets'
printf '%s' "$RM3" > "$T/scen/docs-removed"; n0=$(sshn); pr roll dev-health "$D20" pre
chk "R4: step 20 pre (3 removed Secret docs named, keep + keys): rc 0" "$RC" 0
chk "R4: the I3p ssh runs the names gate first, with the exact REMOVED_DOC set, then RENDER-PATHS (one ssh)" "$(sshafter "$n0" | grep -c "DOCS-GATE.*deploy-rollback-24d deploy-roll-24d i20")$(sshafter "$n0" | grep -cF "[ \"\$rm\" = \"$RM3\" ]")" 11
chk "R4: the I3p stdin = full-render-diff.py + RENDER-PATHS-24d.sh" "$(awk -F'\t' -v n="$n0" '$1>n && $3 ~ /DOCS-GATE/ {print $2}' "$T/ssh.log")" "$(cat "$K3/full-render-diff.py" "$K3/RENDER-PATHS-24d.sh" | sha256sum | cut -c1-64)"
chk "R4: pre reads SECRET_KEEP + SECRET_KEYS (names only) and PASSes" "$(grep -c '^SECRET-KEEP dev-health-ops-go-pgbouncer type=Opaque keep=yes keys=RIVER_COORDINATOR_DATABASE_PASSWORD,RIVER_DOMAIN_DATABASE_PASSWORD,RIVER_KEDA_READONLY_PASSWORD,RIVER_QUEUE_DATABASE_PASSWORD$' "$W20/pre/SECRETS.out" 2>/dev/null)$(grep -c '^SECRET-KEYS dev-health-ops-go-pgbouncer: every named key is present$' "$W20/pre/SECRETS.out" 2>/dev/null)" 11
n0=$(sshn); pr roll dev-health "$D20" deploy
chk "R4: step 20 deploy: rc 0" "$RC" 0
chk "R4: the I3d ssh = gates + newest + secrets + names gate + the deploy verb (one ssh)" "$(sshafter "$n0" | head -1 | grep -c 'git ls-remote.*\[ "\$nw" = "425 deployed" \].*helm.sh/resource-policy.*DOCS-GATE.*bash -s -- deploy i20 d4c9131bfee56349ea4db6cf29768297316e534a$')" 1
chk "R4: the I3d stdin = full-render-diff.py + ROLL-24d.sh" "$(awk -F'\t' -v n="$n0" '$1>n && $3 ~ /bash -s -- deploy i20/ {print $2}' "$T/ssh.log")" "$(cat "$K3/full-render-diff.py" "$K3/ROLL-24d.sh" | sha256sum | cut -c1-64)"
rm -f "$T/state/deploy-ran"; touch "$T/state/dh-deployed" "$T/scen/podsnap-same"; pr roll dev-health "$D20" post; rm -f "$T/scen/podsnap-same"
chk "R4: step 20 post: rc 0" "$RC" 0
chk "R4: post: liverows = n/a (0 workload rows), not a vacuous PASS; no liverows ssh" "$(has 'LIVEROWS: n/a (0 workload rows)') $(has 'LIVEROWS: PASS')" "yes no"
chk "R4: post: the kept Secret still exists with the same key-name set as pre" "$(has 'GATE SECRETS-SAME: PASS')" yes
rm -f "$T/state/dh-deployed" "$T/scen/docs-removed"
echo "-- R4 HOLD/STOP cases"
r4() { mkin "$1" "$EX3E/INPUTS-11712-step20-v3e.txt" -e "s/^RUN_TAG=.*/RUN_TAG=$1/" "${REVMAP[@]}" "${@:2}"; }
f=$(r4 s20-b); printf '%s' "ConfigMap/dev-health-ops-x $RM3" > "$T/scen/docs-removed"; n0=$(sshn); pr roll dev-health "$f" pre
chk "R4: a removed doc not listed (ConfigMap/dev-health-ops-x): HOLD in the I3p ssh, rc 1, RENDER-PATHS not reached" "$RC $(has 'GATE-REMOTE STOP: removed docs') $(has 'RENDER PATHS: PASS')" "1 yes no"
f=$(r4 s20-c); printf '%s' "Secret/dev-health-ops-go-pgbouncer Secret/dev-health-ops-provision-roles-secrets" > "$T/scen/docs-removed"; pr roll dev-health "$f" pre
chk "R4: a listed doc not removed (route-activate-secrets stays): HOLD rc 1" "$RC $(has 'GATE-REMOTE STOP: removed docs')" "1 yes"
f=$(r4 s20-d); printf '%s' "$RM3" > "$T/scen/docs-removed"; printf '%s' "Secret/dev-health-ops-extra" > "$T/scen/docs-added"; pr roll dev-health "$f" pre; rm -f "$T/scen/docs-added"
chk "R4: an added doc not listed (Secret/dev-health-ops-extra): HOLD rc 1" "$RC $(has 'GATE-REMOTE STOP: added docs')" "1 yes"
f=$(r4 s20-e); touch "$T/scen/keep-absent"; n0=$(sshn); pr roll dev-health "$f" pre; rm -f "$T/scen/keep-absent"
chk "R4: the keep annotation absent: STOP in pre, before any deploy" "$RC $(has 'helm.sh/resource-policy is [], not keep') $(sshafter "$n0" | grep -c 'bash -s -- deploy i')" "1 yes 0"
f=$(r4 s20-f); pr roll dev-health "$f" pre; touch "$T/scen/keep-absent"; pr roll dev-health "$f" deploy; rm -f "$T/scen/keep-absent"
chk "R4: the keep annotation gone between pre and deploy: STOP inside the I3d ssh, the deploy verb does not run" "$RC $(has 'not keep') $([ -e "$T/state/deploy-ran" ] && echo ran || echo no)" "1 yes no"
f=$(r4 s20-g); pr roll dev-health "$f" pre; pr roll dev-health "$f" deploy; rm -f "$T/state/deploy-ran"; touch "$T/scen/secret-gone-post" "$T/state/dh-deployed"; pr roll dev-health "$f" post; rm -f "$T/scen/secret-gone-post" "$T/state/dh-deployed"
chk "R4: the kept Secret gone in post: STOP rc 1" "$RC $(has 'the .type read failed')" "1 yes"
f=$(r4 s20-h); touch "$T/scen/key-missing"; pr roll dev-health "$f" pre; rm -f "$T/scen/key-missing"
chk "R4: a SECRET_KEYS key name missing live: STOP rc 1" "$RC $(has 'key name RIVER_KEDA_READONLY_PASSWORD is missing')" "1 yes"
rm -f "$T/scen/docs-removed"
echo "-- R4 REFUSED cases (parse time, no ssh)"
refused "R4: a REMOVED_DOC Secret without SECRET_KEEP or HOOK_SECRET" roll dev-health "$(r4 s20-r1 -e '/^HOOK_SECRET=dev-health-ops-route-activate-secrets$/d')" pre
chk "R4: the refusal names the Secret" "$(has 'REMOVED_DOC Secret/dev-health-ops-route-activate-secrets has no SECRET_KEEP or HOOK_SECRET')" yes
refused "R4: a HOOK_SECRET that is not a REMOVED_DOC" roll dev-health "$(r4 s20-r2 -e '$a HOOK_SECRET=dev-health-ops-other')" pre
refused "R4: a non-Secret REMOVED_DOC (RENDER-PATHS r11 HOLDs on any removed non-Secret doc)" roll dev-health "$(r4 s20-r3 -e '$a REMOVED_DOC=ConfigMap/dev-health-ops-x')" pre
refused "R4: a bad REMOVED_DOC value (lowercase kind)" roll dev-health "$(r4 s20-r4 -e '$a REMOVED_DOC=secret/x')" pre
refused "R4: a bad SECRET_KEYS value" roll dev-health "$(r4 s20-r5 -e 's/^SECRET_KEYS=.*/SECRET_KEYS=dev-health-ops-go-pgbouncer:A;B/')" pre
refused "R4: a duplicate REMOVED_DOC" roll dev-health "$(r4 s20-r6 -e '$a REMOVED_DOC=Secret/dev-health-ops-go-pgbouncer')" pre
refused "R4: an ADDDOC that is not an ADDED_DOC" roll dev-health "$(r4 s20-r7 -e '$a ADDDOC=Job/dev-health-ops-new')" pre

echo "== G2. v3e real text: the names gate with REAL helm + the kit full-render-diff.py on throw-away charts; the secret text with a fake kubectl"
G2=$T/g2; mkdir -p "$G2/home/.config/dev-health" "$G2/home/lane-prod-k8s" "$G2/kbin"; : > "$G2/home/.config/dev-health/values.prod-secrets.yaml"; : > "$G2/home/lane-prod-k8s/roll-24d-values.yaml"
mkchart() { # $1 = tree dir, $2.. = doc names Kind/name to render
  local d=$1 x; shift; mkdir -p "$d/chart/templates"; printf 'apiVersion: v2\nname: dev-health\nversion: 0.1.0\n' > "$d/chart/Chart.yaml"; : > "$d/values.kiac.yaml"; : > "$d/values.prod.yaml"
  for x in "$@"; do if [ "${x%%/*}" = Secret ]; then printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: %s\nstringData:\n  K: SENTINEL-G2-VALUE\n' "${x#*/}"; else printf 'apiVersion: v1\nkind: %s\nmetadata:\n  name: %s\n' "${x%%/*}" "${x#*/}"; fi > "$d/chart/templates/$(tr '/' '-' <<< "$x").yaml"; done; }
I3PC=$(awk -F'\t' '$3 ~ /DOCS-GATE/ && $3 ~ /deploy-rollback-24d deploy-roll-24d i20/ {print $3; exit}' "$T/ssh.log" | sed -e 's/\(echo "DOCS-GATE: PASS[^;]*;\).*/\1/')
chk "G2: the extracted I3p names text ends at DOCS-GATE" "$(printf '%s' "$I3PC" | grep -c 'DOCS-GATE: PASS (removed = REMOVED_DOC, added = ADDED_DOC)";$')" 1
g2run() { local c; c=$(printf '%s' "$I3PC" | sed -e "s|/home/ubuntu/lane-prod-k8s/deploy-roll-24d|$G2/b|g" -e "s|/home/ubuntu/lane-prod-k8s/deploy-rollback-24d|$G2/a|g"); OUT=$(env -i PATH=/usr/local/bin:/usr/bin:/bin HOME="$G2/home" bash -c "$c" < "$K3/full-render-diff.py" 2>&1); RC=$?; }
ALL="ConfigMap/dev-health-ops-keep Job/dev-health-ops-provision-roles $(tr ' ' '\n' <<< "$RM3" | paste -sd' ')"
rm -rf "$G2/a" "$G2/b"; mkchart "$G2/a" $ALL; mkchart "$G2/b" ConfigMap/dev-health-ops-keep Job/dev-health-ops-provision-roles; g2run
chk "G2: real helm + frd names: exactly the 3 named Secrets removed: DOCS-GATE: PASS, rc 0" "$RC $(printf '%s\n' "$OUT" | tail -1)" "0 DOCS-GATE: PASS (removed = REMOVED_DOC, added = ADDED_DOC)"
chk "G2: no Secret value in the output (sentinel 0)" "$(printf '%s\n' "$OUT" | grep -c SENTINEL-G2-VALUE)" 0
rm -rf "$G2/b"; mkchart "$G2/b" Job/dev-health-ops-provision-roles; g2run
chk "G2: a 4th doc removed (ConfigMap): rc 3, STOP names it" "$RC $(printf '%s\n' "$OUT" | grep -c 'GATE-REMOTE STOP: removed docs \[ConfigMap/dev-health-ops-keep ')" "3 1"
rm -rf "$G2/b"; mkchart "$G2/b" ConfigMap/dev-health-ops-keep Job/dev-health-ops-provision-roles Secret/dev-health-ops-route-activate-secrets; g2run
chk "G2: a listed doc not removed: rc 3" "$RC" 3
rm -rf "$G2/b"; mkchart "$G2/b" ConfigMap/dev-health-ops-keep Job/dev-health-ops-provision-roles Secret/dev-health-ops-new; g2run
chk "G2: an added doc not listed: rc 3, STOP names it" "$RC $(printf '%s\n' "$OUT" | grep -c 'GATE-REMOTE STOP: added docs \[Secret/dev-health-ops-new\]')" "3 1"
OUT=$(env -i PATH=/usr/local/bin:/usr/bin:/bin HOME="$G2/home" bash -c "$(printf '%s' "$I3PC" | sed -e "s|/home/ubuntu/lane-prod-k8s/deploy-roll-24d|$G2/b|g" -e "s|/home/ubuntu/lane-prod-k8s/deploy-rollback-24d|$G2/a|g")" < <(head -c 21000 "$K3/full-render-diff.py") 2>&1); RC=$?
chk "G2: a short or wrong full-render-diff.py on stdin: rc 3 (sha check)" "$RC" 3
printf '#!/bin/bash\nG2=%s\necho "$*" >> "$G2/kubectl.args"\ncase "$*" in\n  *"{.type}"*) [ -e "$G2/gone" ] && exit 1; echo Opaque ;;\n  *resource-policy*) [ -e "$G2/nokeep" ] || echo keep ;;\n  *go-template*) printf "RIVER_QUEUE_DATABASE_PASSWORD\\nRIVER_DOMAIN_DATABASE_PASSWORD\\nRIVER_COORDINATOR_DATABASE_PASSWORD\\n"; [ -e "$G2/nokey" ] || echo RIVER_KEDA_READONLY_PASSWORD ;;\n  *) exit 97 ;;\nesac\n' "$G2" > "$G2/kbin/kubectl"; chmod 0755 "$G2/kbin/kubectl"
SCC=$(awk -F'\t' '$3 ~ /helm.sh\/resource-policy/ && $3 !~ /bash -s -- deploy/ {print $3; exit}' "$T/ssh.log")
g2s() { OUT=$(env -i PATH="$G2/kbin:/usr/bin:/bin" bash -c "$SCC" </dev/null 2>&1); RC=$?; }
g2s; chk "G2: the real secret text with a fake kubectl: SECRETS: PASS, the key NAMES sorted" "$RC $(printf '%s\n' "$OUT" | grep -c '^SECRET-KEEP dev-health-ops-go-pgbouncer type=Opaque keep=yes keys=RIVER_COORDINATOR_DATABASE_PASSWORD,RIVER_DOMAIN_DATABASE_PASSWORD,RIVER_KEDA_READONLY_PASSWORD,RIVER_QUEUE_DATABASE_PASSWORD$') $(printf '%s\n' "$OUT" | tail -1)" "0 1 SECRETS: PASS"
chk "G2: kubectl got the D6429/D6423 forms exactly (.type; the keep annotation by jsonpath; key names by go-template)" "$(grep -cxF -e 'get secret dev-health-ops-go-pgbouncer -o jsonpath={.type} -n dev-health' -e '-n dev-health get secret dev-health-ops-go-pgbouncer -o jsonpath={.type}' "$G2/kubectl.args" | awk '{s+=$1} END {print (s>0)}')$(grep -cF -- '-o jsonpath={.metadata.annotations.helm\.sh/resource-policy}' "$G2/kubectl.args" | awk '{print ($1>0)}')$(grep -cF -- '-o go-template={{range $k, $v := .data}}{{$k}}{{"\n"}}{{end}}' "$G2/kubectl.args" | awk '{print ($1>0)}')" 111
touch "$G2/nokeep"; g2s; rm -f "$G2/nokeep"; chk "G2: the keep annotation absent: rc 3" "$RC $(printf '%s\n' "$OUT" | grep -c 'not keep')" "3 1"
touch "$G2/nokey"; g2s; rm -f "$G2/nokey"; chk "G2: a key name missing: rc 3" "$RC $(printf '%s\n' "$OUT" | grep -c 'key name RIVER_KEDA_READONLY_PASSWORD is missing')" "3 1"
touch "$G2/gone"; g2s; rm -f "$G2/gone"; chk "G2: the Secret absent: rc 3" "$RC" 3

echo "== R5. v3f: every final-line regex against REAL prod output (tests/fixtures/real + MANIFEST.tsv); F_POD on padded kubectl columns; raw renders shredded (pm rule) (written RED against v3e d41977b3 first, then GREEN on v3f)"
FXR=$T/fxreal
# the step -> final-line regex map, read from the prodroll.sh under test (its step / step_rc lines; $F_* resolved)
RXMAP=$(python3 -I - "$T/prodroll.sh" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
F = dict(re.findall(r"^(F_[A-Z]+)='([^']*)'", s, re.M))
seen = {}
for m in re.finditer(r"""\bstep(?:_rc)? "?([A-Za-z0-9_-]+?)(?:-\$i)?"? (?:"[0-9 ]+" )?('([^']*)'|"\$(F_[A-Z]+)")""", s):
    seen.setdefault(m.group(1), m.group(3) if m.group(3) is not None else F[m.group(4)])
for k, v in seen.items(): print("%s\t%s" % (k, v))
PY
)
echo "AUDIT step | final-line regex (from the prodroll.sh under test) | the real final line | match"
nf=0
while IFS=$'\t' read -r st fx src lr sh note; do
  case "$st" in '#'*|'') continue;; esac; nf=$((nf+1))
  rx=$(awk -F'\t' -v s="$st" '$1==s {print $2; exit}' <<< "$RXMAP")
  last=$(grep -v '^[[:space:]]*$' "$FXR/$fx" | tail -1)
  m=n; [ -n "$rx" ] && [[ $last =~ $rx ]] && m=y
  w=$(grep -cwE 'FAIL|REFUSED|HOLD' "$FXR/$fx")
  echo "AUDIT $st | $rx | $(printf '%s' "$last" | tr '\t' ' ' | cut -c1-110) | $m"
  chk "R5 real: $st ($fx; $src $lr): the final line matches the step regex; no FAIL/REFUSED/HOLD word" "$m $w" "y 0"
done < "$FXR/MANIFEST.tsv"
chk "R5: 40 real fixtures in MANIFEST.tsv; every fixture file is listed once" "$nf $(ls "$FXR" | grep -vc '^MANIFEST.tsv$') $(comm -3 <(ls "$FXR" | grep -v '^MANIFEST.tsv$' | sort) <(awk -F'\t' '!/^#/ {print $2}' "$FXR/MANIFEST.tsv" | sort) | grep -c .)" "40 40 0"
chk "R5: the fixtures are secret-free (no URI with userinfo, no token/key marker, no public IPv4)" "$(cat "$FXR"/* | grep -cE '[a-zA-Z][a-zA-Z0-9+.-]*://[^/ @]*@') $(cat "$FXR"/* | grep -ciE 'eyJ[A-Za-z0-9_-]{8,}|ghp_|gho_|ghs_|github_pat_|xox[abp]-|AKIA[0-9A-Z]{12}|-----BEGIN|password[=:]|token[=:]|secret[=:]|api_?key|bearer ') $(cat "$FXR"/* | grep -oE '\b[0-9]{1,3}(\.[0-9]{1,3}){3}\b' | grep -vcE '^(10\.|203\.0\.113\.)')" "0 0 0"
DHR5=$(mkin dh-r5p "$DH" -e 's/^RUN_TAG=.*/RUN_TAG=s19-r5/'); touch "$T/scen/podsnap-real"; pr roll dev-health "$DHR5" pre; rm -f "$T/scen/podsnap-real"
chk "R5: pre with the REAL padded kubectl PODSNAP rows (s20-a): PODSNAP-before passes, PHASE pre: PASS" "$RC $(has 'PHASE pre: PASS')" "0 yes"
chk "R5: the ingress dry-run file (prod values) is shredded at the end of every dry-run ssh, never only removed" "$(awk -F'\t' '$3 ~ /--dry-run=server/ {print $3}' "$T/ssh.log" | grep -cF 'shred -u "$o" "$e"' | awk '{print ($1>0) ? "yes" : "no"}') $(awk -F'\t' '$3 ~ /--dry-run=server/ {print $3}' "$T/ssh.log" | grep -cF 'rm -f "$o" "$e"')" "yes 0"
mkdir -p "$T/shbin" "$T/rptmp"; printf '#!/bin/bash\necho "$*" >> %s/shred.log\nexec /usr/bin/shred "$@"\n' "$T" > "$T/shbin/shred"; chmod 0755 "$T/shbin/shred"
mkchart "$G2/sa" ConfigMap/dev-health-ops-keep Secret/dev-health-ops-x; mkchart "$G2/sb" ConfigMap/dev-health-ops-keep Secret/dev-health-ops-x
env -i PATH="$T/shbin:/usr/local/bin:/usr/bin:/bin" HOME="$G2/home" TMPDIR="$T/rptmp" RP_IMGROWS= RP_CMDELTA= RP_CMROLL= RP_ADDDOCS= bash "$K3/RENDER-PATHS-24d.sh" "$G2/sa" "$G2/sb" i1 >/dev/null 2>&1
chk "R5: RENDER-PATHS shreds its 2 raw renders (prod values; Secret docs included) at exit, and its mktemp dir is gone" "$(grep -cE '^-u .*/a\.raw .*/b\.raw$' "$T/shred.log" 2>/dev/null) $(ls -A "$T/rptmp" | grep -c .)" "1 0"

echo "== G3. v3h real ROLL-24d.sh text: groupdigests + the per-group norolls STAGECHECK, fake kubectl/helm (CHAOS-11743, pm ruling A)"
G3=$T/g3; mkdir -p "$G3/kbin" "$G3/pods" "$G3/home/lane-prod-k8s"
MIX=heavy:4bdf329325b0,ops:fa9b7cd250de,sync:fa9b7cd250de,sync-provider:fa9b7cd250de,scheduler:fa9b7cd250de,reconciler:fa9b7cd250de,stream-ingest:fa9b7cd250de,stream-external:fa9b7cd250de,stream-pagerduty:fa9b7cd250de
UNI=$(printf '%s\n' "$MIX" | sed 's/4bdf329325b0/fa9b7cd250de/')
MUT=$(printf '%s\n' "$MIX" | sed 's/ops:fa9b7cd250de/ops:2c87c3613bca/')
MID=$(printf '%s\n' "$MIX" | sed 's/ops:fa9b7cd250de/ops:2c87c3613bca+fa9b7cd250de/')
g3pods() { rm -f "$G3/pods/"*; local e g x d; for e in ${1//,/ }; do g=${e%%:*}; x=${e#*:}; [ "$x" = - ] && continue; for d in ${x//+/ }; do printf 'dev-health-ops-go-%s-%s-aaaaa Running |true~0~ghcr.io/full-chaos/dev-health-go-operator@sha256:%s0000000000000000000000000000000000000000000000000000 \n' "$g" "$d" "$d" >> "$G3/pods/$g"; done; done; }
printf '#!/bin/bash\nG3=%s\n' "$G3" > "$G3/kbin/kubectl"
cat >> "$G3/kbin/kubectl" <<'KEOF'
a="$*"; echo "$a" >> "$G3/kubectl.args"
case "$a" in
  *"get pods -l dev-health.io/worker-group="*"-o name"*) g=${a#*worker-group=}; g=${g%% *}; [ -f "$G3/pods/$g" ] && awk '{print "pod/"$1}' "$G3/pods/$g" ;;
  *"get pods -l dev-health.io/worker-group="*) g=${a#*worker-group=}; g=${g%% *}; [ -f "$G3/pods/$g" ] && cat "$G3/pods/$g" ;;
  *"get pods -l app.kubernetes.io/component="*) : ;;
  *"get pods"*) cat "$G3/pods/"* 2>/dev/null ;;
  *"get sts dev-health-ops-clickhouse"*"spec.replicas"*) echo 0 ;;
  *"get pvc"*) echo Bound ;;
  *"get deploy -o name"*) for g in heavy ops sync sync-provider scheduler reconciler stream-ingest stream-external stream-pagerduty; do echo "deployment.apps/dev-health-ops-go-$g"; done ;;
  *"get deploy"*) echo 1 ;;
  *) : ;;
esac
KEOF
printf '#!/bin/bash\ncase "$*" in *"history dev-health -n dev-health -o json"*) echo %s ;; *) exit 0 ;; esac\n' "'[{\"revision\":435,\"status\":\"superseded\",\"description\":\"Upgrade complete\"},{\"revision\":436,\"status\":\"deployed\",\"description\":\"Upgrade complete\"}]'" > "$G3/kbin/helm"
chmod 755 "$G3/kbin/kubectl" "$G3/kbin/helm"
printf 'deploy_rc=0\n' > "$G3/home/lane-prod-k8s/roll-24d-i29.out"; : > "$G3/home/lane-prod-k8s/roll-24d-i29.out.done"
g3run() { OUT=$(env -i PATH="$G3/kbin:/usr/bin:/bin" HOME="$G3/home" R=24d "$@" bash "$K3/ROLL-24d.sh" ${G3ARGS} </dev/null 2>&1); RC=$?; }
g3pods "$MIX"; G3ARGS=groupdigests; g3run
chk "G3 (a): groupdigests on mixed groups (heavy 4bdf3293 + 8 at fa9b7cd2): rc 0, STATE GROUPDIG = the map in img_groups order" "$RC $(printf '%s\n' "$OUT" | sed -n 's/^STATE GROUPDIG=//p')" "0 $MIX"
G3ARGS="stagecheck i29 435"
g3pods "$MIX"; g3run IMG_MODE=norolls IMG_DEPLOYS=none IMG_OLD=fa9b7cd250de IMG_NEW= RESTARTS0=0 GROUPDIG="$MIX" CMROLL=
chk "G3 (b): norolls with GROUPDIG = the mixed pre map, pods unchanged: rc 0, 9 group (ok) lines, map line ok, STAGECHECK: PASS" "$RC $(printf '%s\n' "$OUT" | grep -c '^STAGECHECK i29: group .* (ok)$') $(printf '%s\n' "$OUT" | grep -c 'digest map == pre map') $(printf '%s\n' "$OUT" | tail -1)" "0 9 1 STAGECHECK: PASS"
g3pods "$MUT"; g3run IMG_MODE=norolls IMG_DEPLOYS=none IMG_OLD=fa9b7cd250de IMG_NEW= RESTARTS0=0 GROUPDIG="$MIX" CMROLL=
G3MUT_OUT=$OUT; G3MUT_RC=$RC
chk "G3 (c) MUTANT: one group (ops) moved to 2c87c3613bca: rc 1, the group named MOVED, 8 groups ok, STAGECHECK: STOP" "$RC $(printf '%s\n' "$OUT" | grep -c '^STAGECHECK i29: group ops pre fa9b7cd250de now 2c87c3613bca (MOVED)$') $(printf '%s\n' "$OUT" | grep -c '^STAGECHECK i29: group .* (ok)$') $(printf '%s\n' "$OUT" | grep -c '^STAGECHECK: STOP')" "1 1 8 1"
g3pods "$MID"; g3run IMG_MODE=norolls IMG_DEPLOYS=none IMG_OLD=fa9b7cd250de IMG_NEW= RESTARTS0=0 GROUPDIG="$MIX" CMROLL=
chk "G3 (c2) MUTANT: ops mid-roll (2 digests): rc 1, ops MOVED with both prefixes" "$RC $(printf '%s\n' "$OUT" | grep -c '^STAGECHECK i29: group ops pre fa9b7cd250de now 2c87c3613bca+fa9b7cd250de (MOVED)$')" "1 1"
g3pods "$MIX"; g3run IMG_MODE=norolls IMG_DEPLOYS=none IMG_OLD=fa9b7cd250de IMG_NEW= RESTARTS0=0 GROUPDIG="$UNI" CMROLL=
chk "G3 (c3) MUTANT: pre map uniform, live heavy on 4bdf3293: rc 1, heavy MOVED" "$RC $(printf '%s\n' "$OUT" | grep -c '^STAGECHECK i29: group heavy pre fa9b7cd250de now 4bdf329325b0 (MOVED)$')" "1 1"
g3pods "$UNI"; g3run IMG_MODE=norolls IMG_DEPLOYS=none IMG_OLD=fa9b7cd250de IMG_NEW= RESTARTS0=0 CMROLL=
chk "G3 (d) back-compat: GROUPDIG unset, uniform fa9b7cd2 = IMG_OLD: rc 0, the old single-digest line, STAGECHECK: PASS" "$RC $(printf '%s\n' "$OUT" | grep -c '^STAGECHECK i29: worker image digests fa9b7cd250de = old (0 pod rollouts: ok)$') $(printf '%s\n' "$OUT" | tail -1)" "0 1 STAGECHECK: PASS"
g3pods "$MIX"; g3run IMG_MODE=norolls IMG_DEPLOYS=none IMG_OLD=fa9b7cd250de IMG_NEW= RESTARTS0=0 CMROLL=
chk "G3 (d2) back-compat: GROUPDIG unset, mixed groups: rc 1, the v3f STOP (the case v3h fixes)" "$RC $(printf '%s\n' "$OUT" | grep -c "worker image digests '4bdf329325b0,fa9b7cd250de' want 'fa9b7cd250de'")" "1 1"
g3pods "$MIX"; g3run IMG_MODE=norolls IMG_DEPLOYS=none IMG_OLD=fa9b7cd250de IMG_NEW= RESTARTS0=0 GROUPDIG="heavy:4bdf329325b0;ops" CMROLL=
chk "G3 (f): GROUPDIG with a bad character: rc 1" "$RC $(printf '%s\n' "$OUT" | grep -c 'GROUPDIG has a bad character')" "1 1"
rm -f "$G3/pods/"*; G3ARGS=groupdigests; g3run
chk "G3 (e): groupdigests with no worker pod read: rc 1, no STATE line" "$RC $(printf '%s\n' "$OUT" | grep -c 'no worker pod read') $(printf '%s\n' "$OUT" | grep -c '^STATE GROUPDIG=')" "1 1 0"
chk "G3: the fake kubectl got only get/logs reads (no write verb)" "$(grep -cE '(^| )(apply|delete|patch|scale|create|edit|annotate|label|rollout) ' "$G3/kubectl.args")" 0
if [ -n "${G3MUTLOG:-}" ]; then { echo "# v3h mutant run (G3 c): pods = MIX with ops moved to 2c87c3613bca, GROUPDIG = MIX; rc $G3MUT_RC"; printf '%s\n' "$G3MUT_OUT"; } > "$G3MUTLOG"; fi

echo "== J. v3j TOPCMP: only the HPAs of rolled Deployments (PODSNAP_TARGETS) are gated; a move on sample 1 = RECHECK, wait 60 s, sample 2 decides (pm ruling after s30-a/s36-a)"
jcase() { # <RUN_TAG> <PODSNAP_TARGETS> <pre topsnap fixture> <post topsnap fixtures...>: pre, deploy, post of one RUN_TAG; JW = its work dir; JLEFT = post fixtures not served
  local tag=$1 tg=$2 pre=$3 f; shift 2
  f=$(mkin "dh-$tag" "$DH" -e "s/^RUN_TAG=.*/RUN_TAG=$tag/" -e "s/^PODSNAP_TARGETS=.*/PODSNAP_TARGETS=$tg/"); JW=$T/logs/PRODROLL-WORK-dev-health-i19-$tag
  printf '%s\n' "$1" > "$T/scen/topsnap-queue"; shift; pr roll dev-health "$f" pre; JPRE=$RC; rm -f "$T/scen/topsnap-queue"
  pr roll dev-health "$f" deploy; JDEP=$RC
  printf '%s\n' "$@" > "$T/scen/topsnap-queue"; rm -f "$T/sleep.log"; touch "$T/state/dh-deployed"; n0=$(sshn)
  pr roll dev-health "$f" post; rm -f "$T/state/dh-deployed" "$T/state/deploy-ran"
  JLEFT=$(grep -c . "$T/scen/topsnap-queue"); rm -f "$T/scen/topsnap-queue"
  chk "J $tag: pre rc 0, deploy rc 0; I3t = $pre (web row $(grep '^hpa dev-health-ops-web ' "$JW/pre/I3t.out" | awk '{print $3}'))" "$JPRE $JDEP" "0 0"; }
jsleep() { grep -c '^sleep 60$' "$T/sleep.log" 2>/dev/null || echo 0; }
jcase j-a dev-health-ops-go-api topsnap-w3.txt topsnap-w20.txt topsnap-w20.txt
chk "J (a) web NOT rolled, web 3% -> 20% on sample 1: post rc 0, PHASE post: PASS, TOPCMP: PASS" "$RC $(has 'PHASE post: PASS') $(tail -1 "$JW/post/I7-topcmp.out" | cut -c1-12)" "0 yes TOPCMP: PASS"
chk "J (a): the NOTE line names web, not rolled, 3% -> 20%, no gate" "$(grep -cxF '  NOTE: dev-health-ops-web not rolled: current% 3% -> 20% (no gate)' "$JW/post/I7-topcmp.out")" 1
chk "J (a): no FAIL/REFUSED/HOLD word in I7-topcmp.out, no TOPCMP: FAIL in the run" "$(grep -cwE 'FAIL|REFUSED|HOLD' "$JW/post/I7-topcmp.out") $(has 'TOPCMP: FAIL')" "0 no"
chk "J (a): one sample only (no wait, no I7-topsnap2; 1 post fixture left unserved)" "$(jsleep) $(ls "$JW/post" | grep -c '^I7-top.*2\.out$') $JLEFT" "0 0 1"
jcase j-b dev-health-ops-go-api,dev-health-ops-web topsnap-w3.txt topsnap-w20.txt topsnap-w4.txt
chk "J (b) web rolled, 3% -> 20% on sample 1, 4% on sample 2: post rc 0, PHASE post: PASS" "$RC $(has 'PHASE post: PASS') $([ -e "$JW/post.pass" ] && echo yes)" "0 yes yes"
chk "J (b): I7-topcmp = RECHECK (rc 3) with the MOVED web row, no FAIL word" "$(grep -c '^== I7-topcmp rc=3$' <<< "$OUT") $(tail -1 "$JW/post/I7-topcmp.out" | cut -c1-15) $(grep -c '^  MOVED: dev-health-ops-web: HPA current% moved 3% -> 20% ' "$JW/post/I7-topcmp.out") $(grep -cwE 'FAIL|REFUSED|HOLD' "$JW/post/I7-topcmp.out")" "1 TOPCMP: RECHECK 1 0"
chk "J (b): sleep 60 once, then I7-topsnap2 + I7-topcmp2 ran; I7-topcmp2 = TOPCMP: PASS on sample 2" "$(jsleep) $([ -s "$JW/post/I7-topsnap2.out" ] && echo yes) $(tail -1 "$JW/post/I7-topcmp2.out" | cut -c1-12) $(grep -c 'on sample 2' "$JW/post/I7-topcmp2.out") $JLEFT" "1 yes TOPCMP: PASS 1 0"
chk "J (b): step order in the run log: I7-topsnap, I7-topcmp, the wait line, I7-topsnap2, I7-topcmp2" "$(grep -oE '^== I7-top[a-z0-9]+ [0-9]|^I7: a rolled HPA moved on sample 1; sample 2 in 60 s$' <<< "$OUT" | sed 's/ [0-9]$//' | paste -sd'|')" "== I7-topsnap|== I7-topcmp|I7: a rolled HPA moved on sample 1; sample 2 in 60 s|== I7-topsnap2|== I7-topcmp2"
chk "J (b): post ssh order ends -- topsnap, -- topsnap" "$(sshafter "$n0" | sed -E 's/.*(podsnap-i19-j-b-after|-- topsnap).*/\1/' | tail -3 | paste -sd' ')" "podsnap-i19-j-b-after -- topsnap -- topsnap"
jcase j-c dev-health-ops-go-api,dev-health-ops-web topsnap-w3.txt topsnap-w20.txt topsnap-w20.txt
chk "J (c) web rolled, moved on BOTH samples: post rc 1 STOP at I7-topcmp2, TOPCMP: FAIL, no post.pass" "$RC $(has 'PRODROLL STOP (exit 1): I7-topcmp2 rc=1') $(grep -c '^TOPCMP: FAIL (sample 2)$' "$JW/post/I7-topcmp2.out") $(grep -c '^  FAIL: dev-health-ops-web: HPA current% moved 3% -> 20% ' "$JW/post/I7-topcmp2.out") $([ -e "$JW/post.pass" ] && echo yes || echo no)" "1 yes 1 1 no"
chk "J (c): sample 1 was RECHECK, one 60 s wait" "$(tail -1 "$JW/post/I7-topcmp.out" | cut -c1-15) $(jsleep)" "TOPCMP: RECHECK 1"
jcase j-d dev-health-ops-go-api,dev-health-ops-web topsnap-w3.txt topsnap-w4.txt topsnap-w20.txt
chk "J (d) web rolled, unchanged (3% -> 4%): post rc 0, TOPCMP: PASS on sample 1, no wait, no second sample" "$RC $(tail -1 "$JW/post/I7-topcmp.out" | cut -c1-12) $(jsleep) $(ls "$JW/post" | grep -c '^I7-top.*2\.out$') $JLEFT" "0 TOPCMP: PASS 0 0 1"
jcase j-f dev-health-ops-go-api,dev-health-ops-web topsnap-w3.txt topsnap-wunknown.txt topsnap-w3.txt
chk "J (f) web rolled, TARGETS unreadable on sample 1: rc 1 at once (as v3i), no RECHECK, no wait" "$RC $(has 'PRODROLL STOP (exit 1): I7-topcmp rc=1') $(grep -c 'HPA TARGETS unreadable' "$JW/post/I7-topcmp.out") $(jsleep)" "1 yes 1 0"
JH=$T/jh; mkdir -p "$JH"; jt() { OUT=$(env -i PATH=/usr/bin:/bin bash "$K3/HEADROOM-24d.sh" topcmp "$@" </dev/null 2>&1); RC=$?; }
jt "$FX/topsnap-w3.txt" "$FX/topsnap-w20.txt" dev-health-ops-go-sync first
chk "J unit: rolled KEDA group (go-sync) with unknown TARGETS: NOTE, not gated; web not rolled: NOTE; rc 0" "$RC $(printf '%s\n' "$OUT" | grep -c '^  NOTE: keda-hpa-dev-health-ops-go-sync rolled: TARGETS unknown -> unknown unreadable (KEDA row, no gate)$') $(printf '%s\n' "$OUT" | grep -c '^  NOTE: dev-health-ops-web not rolled: ') $(printf '%s\n' "$OUT" | tail -1 | cut -c1-12)" "0 1 1 TOPCMP: PASS"
jt "$FX/topsnap-w3.txt" "$FX/topsnap-w20.txt" none final
chk "J unit: rolled list none, web moved, final: rc 0 (no gate)" "$RC" 0
jt "$FX/topsnap-w3.txt" "$FX/topsnap-w20.txt" dev-health-ops-web first
chk "J unit: web rolled, moved, first: rc 3, last line TOPCMP: RECHECK, MOVED line before it" "$RC $(printf '%s\n' "$OUT" | tail -1 | cut -c1-15) $(printf '%s\n' "$OUT" | tail -2 | head -1 | cut -c1-8)" "3 TOPCMP: RECHECK   MOVED:"
jt "$FX/topsnap-w3.txt" "$FX/topsnap-w20.txt" dev-health-ops-web final
chk "J unit: web rolled, moved, final: rc 1, TOPCMP: FAIL" "$RC $(printf '%s\n' "$OUT" | grep -c '^TOPCMP: FAIL')" "1 1"
grep -v 'dev-health-ops-web' "$FX/topsnap-w3.txt" > "$JH/noweb.txt"; jt "$FX/topsnap-w3.txt" "$JH/noweb.txt" none first
chk "J unit: no web HPA row in the after file (parse guard, rolled list none): rc 1" "$RC $(printf '%s\n' "$OUT" | grep -c 'no web HPA row in the before/after file')" "1 1"
jt "$FX/topsnap-w3.txt" "$FX/topsnap-w20.txt" none second
chk "J unit: a bad mode word: rc 2 usage" "$RC $(printf '%s\n' "$OUT" | grep -c '^usage: topcmp ')" "2 1"
jt "$FX/topsnap-w3.txt" "$FX/topsnap-w20.txt"
chk "J unit: no rolled list / mode (the v3i call form): rc != 0, no TOPCMP line" "$([ "$RC" != 0 ] && echo nz) $(printf '%s\n' "$OUT" | grep -c '^TOPCMP')" "nz 0"
chk "J: the real r13 I3t/I7 pair, rolled go-api: rc 0, TOPCMP: PASS, 4 not-rolled NOTE lines" "$(env -i PATH=/usr/bin:/bin bash "$K3/HEADROOM-24d.sh" topcmp "$FXR/r13-I3t-topsnap.out" "$FXR/r13-I7-topsnap.out" dev-health-ops-go-api first > "$JH/r13.out" 2>&1; echo $?) $(tail -1 "$JH/r13.out" | cut -c1-12) $(grep -c '^  NOTE: .* not rolled: ' "$JH/r13.out")" "0 TOPCMP: PASS 4"

echo "== H. line 1 and the last line of every run log; no local kubectl/helm/git"
L1RE='^PRODROLL v3j sha256\(prodroll\.sh\)=[0-9a-f]{64} sums=([0-9a-f]{64}|missing) inputs=(/[A-Za-z0-9._/-]+|<not-a-plain-path>) sha256\(inputs\)=([0-9a-f]{64}|-) cmd=(roll|secret-pipe|readback|rollback) [a-z0-9-]+( [a-z0-9-]+)?$'
nl=0; badl1=0; badend=0
for d in "$T/logs" "$T"/k-*/logs; do for f in "$d"/PRODROLL-*.log; do [ -e "$f" ] || continue; nl=$((nl+1)); head -1 "$f" | grep -qE "$L1RE" || { badl1=$((badl1+1)); echo "  line 1 bad: $f: $(head -1 "$f")"; }; tail -1 "$f" | grep -qE '^PRODROLL END rc=[0-9]+ ' || badend=$((badend+1)); done; done
echo "run logs checked: $nl"
chk "every run log: line 1 = PRODROLL v3j sha256(prodroll.sh)=<64> sums=<64> inputs=<path> sha256(inputs)=<64> cmd=<sub args>" "$badl1" 0
chk "every run log: the last line = PRODROLL END rc=<n>" "$badend" 0
chk "no local kubectl/helm/git call" "$(cat "$T/local-calls.log" 2>/dev/null | wc -l)" 0
chk "fake ssh: no unknown command" "$(cat "$T/unknown.log" 2>/dev/null | wc -l)" 0

echo "ok $ok bad $bad"
if [ -n "${KEEP:-}" ]; then echo "kept $T"; else case "$T" in /var/lib/oci-cache/lane-scratch/prodroll-v3-test-*) rm -rf -- "${T:?}"; echo "removed $T";; esac; fi
[ "$bad" = 0 ]
