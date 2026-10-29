#!/bin/bash -p
# prodroll.sh v3h (CHAOS-11788; v3h = CHAOS-11743 per-group norolls STAGECHECK): ONE stable entry point for the prod rolls + correctness gates. NOT a sandbox (pm scope ruling: the agent uid
# has docker, sudo and direct ssh; same-uid TOCTOU is out of scope). The inputs file is DATA: a strict KEY=VALUE reader (a key whitelist per
# target, one regex per key), read ONCE into memory, hashed and parsed from that one buffer, and its sha256 must be peer-checked in the attest
# file (D6436: <sha256> <roll> <UTC> <checker>, checker != the inputs AUTHOR). Every prod command is a fixed literal here or in the kit files of prodroll-v3/ (SHA256SUMS pinned below; this file self-checks).
# Call form (rule Bash(/var/lib/oci-cache/lane-scratch/shared/prodroll.sh:*)): run it directly, no `bash` prefix, no cd, no pipe, no redirect:
#   /var/lib/oci-cache/lane-scratch/shared/prodroll.sh <sub> <arg> <inputs> [<phase>|<RUN_TAG>]
# Exit: 0 PASS | 1 STOP (a step rc != 0, no final PASS line, a FAIL/REFUSED/HOLD word, or a gate mismatch; no auto-rollback) | 2 REFUSED
# (usage, inputs, attest, order, age; before any ssh) | 3 HOLD (still running: run the `wait` phase) | 6 REFUSED (self-check or kit SUMS) | 10 xtrace.
set -uo pipefail
case "$-" in *x*) echo "PRODROLL REFUSED (exit 10): xtrace is on"; exit 10;; esac
case ":${SHELLOPTS:-}:" in *:xtrace:*) echo "PRODROLL REFUSED (exit 10): SHELLOPTS has xtrace"; exit 10;; esac
PATH=/usr/sbin:/usr/bin:/sbin:/bin; export PATH   # fixed, before any external command; never the caller's PATH
builtin unset -f $(builtin compgen -A function) 2>/dev/null
builtin unset BASH_ENV ENV CDPATH GLOBIGNORE
set +a
set -o noclobber
umask 077

KIT_VERSION=3j
# ---- self-check FIRST (acp P1-1, P2-1), before the pin line runs: line 1 is exactly `#!/bin/bash -p`; exactly ONE line starts with PINNED_SELF_SHA256, it is LINE 34,
#      and it is exactly `PINNED_SELF_SHA256=<64 hex>`; sha256 of this file with line 34 deleted BY NUMBER equals the pin. Any miss: rc 6, nothing after runs. (It proves the file; code placed ABOVE this block runs before it; same-uid edits are out of scope.)
SELF=$(readlink -f -- "$0")
selfrefuse() { echo "PRODROLL v$KIT_VERSION sha256(prodroll.sh)=$(sha256sum < "$SELF" | cut -c1-64) sums=- inputs=- sha256(inputs)=- cmd=self-check"; echo "PRODROLL REFUSED (exit 6): self-check: $*"; exit 6; }
[ "$(sed -n 1p -- "$SELF")" = '#!/bin/bash -p' ] || selfrefuse "line 1 is not #!/bin/bash -p"
SELF_PINS=$(grep -c '^PINNED_SELF_SHA256' -- "$SELF") || true
[ "$SELF_PINS" = 1 ] || selfrefuse "$SELF_PINS lines start with PINNED_SELF_SHA256 (want exactly 1)"
SELF_PIN_N=$(grep -n '^PINNED_SELF_SHA256' -- "$SELF" | cut -d: -f1); [ "$SELF_PIN_N" = 34 ] || selfrefuse "the pin line is line $SELF_PIN_N, not line 34"
SELF_PIN_LINE=$(sed -n "${SELF_PIN_N}p" -- "$SELF")
[[ $SELF_PIN_LINE =~ ^PINNED_SELF_SHA256=([0-9a-f]{64})$ ]] || selfrefuse "line $SELF_PIN_N is not exactly PINNED_SELF_SHA256=<64 hex>"
SELF_PIN=${BASH_REMATCH[1]}
SELF_HASH=$(sed "${SELF_PIN_N}d" -- "$SELF" | sha256sum | cut -c1-64)
[ "$SELF_HASH" = "$SELF_PIN" ] || selfrefuse "sha256(prodroll.sh without line $SELF_PIN_N)=$SELF_HASH, pinned $SELF_PIN"
PINNED_SELF_SHA256=c0077863b702f16ff8614912d8693611c07426a69767cc534f309c05d1a9e274
PINNED_SUMS_SHA256=a846d33cdaa101d56a175b510c462ef10c1c609c171a10f90220e418340a6f95
PROD_SELF=/var/lib/oci-cache/lane-scratch/shared/prodroll.sh
DEPLOY_URL=https://github.com/full-chaos/dev-health-deploy.git     # = ROLL-24d.sh prep clone URL (:145) = the deploy repo origin
DEPLOY_TREE=/home/ubuntu/lane-prod-k8s/deploy-roll-24d             # the prod roll tree (ROLL-24d C; the ingress tree)
ROLLBACK_TREE=/home/ubuntu/lane-prod-k8s/deploy-rollback-24d       # the prod rollback tree (ROLL-24d RB)
F1_TREE=/home/ubuntu/lane-prod-k8s/deploy-11709                    # the 11709 run worktree (PREP-11709-rev420.md s2)
ING_TGZ=/home/ubuntu/lane-prod-k8s/11647/chart/ingress-nginx-4.14.5.tgz
ING_TGZ_SHA256=93ea7cf2677577a489e14fc94d6026a1194cf2e453dc86bf43da7162109f0d59
ING_CHART_VERSION=4.14.5
ING_VALUES=prod/ingress-nginx.values.yaml
PRE_MAX_AGE=1800
KIT=${SELF%/*}/prodroll-v3
# ---- mode (acp P1-2): the prod path must be the real file with no symlink in its path; anything else is a copy, and a copy runs only with the
#      test fakes (checked after the argv grammar, before any read of the inputs and before any ssh) ----
installrefuse() { echo "PRODROLL v$KIT_VERSION sha256(prodroll.sh)=$(sha256sum < "$SELF" | cut -c1-64) sums=- inputs=- sha256(inputs)=- cmd=install-check"; echo "PRODROLL REFUSED (exit 6): install: $*"; exit 6; }
TESTPATH=
if [ "$0" = "$PROD_SELF" ] || [ "$SELF" = "$PROD_SELF" ]; then
  MODE=prod; LOGDIR=/home/ubuntu/devhealth/.remember/acr-mcp/lanes/fcc-window-1028; ATTEST=/home/ubuntu/devhealth/.remember/acr-mcp/lanes/fcc-11788/ATTEST-INPUTS.txt
  [ "$SELF" = "$PROD_SELF" ] || installrefuse "called as $PROD_SELF but it resolves to $SELF (a symlink in the install path)"
  ipath=; for icomp in $(tr / ' ' <<< "${PROD_SELF#/}"); do ipath=$ipath/$icomp; [ ! -L "$ipath" ] || installrefuse "$ipath is a symlink"; done
  [ ! -L "$KIT" ] || installrefuse "$KIT is a symlink"
else
  MODE=copy; LOGDIR=${SELF%/*}/logs; ATTEST=${SELF%/*}/ATTEST-INPUTS.txt   # a copy at another path (the tests); the rule names only PROD_SELF
  case "$SELF" in
    /var/lib/oci-cache/lane-scratch/shared/*) ;;
    *) if [[ ${PRODROLL_TEST_PATH:-} =~ ^/var/lib/oci-cache/lane-scratch(/[A-Za-z0-9_][A-Za-z0-9._-]*)+$ ]]; then TESTPATH=$PRODROLL_TEST_PATH; PATH=$TESTPATH:$PATH; fi ;;   # test-only: the fake bins (D6387), under lane-scratch only
  esac
fi
builtin unset PRODROLL_TEST_PATH
HOME=/home/ubuntu; LANG=C.UTF-8; LC_ALL=C; KUBECONFIG=/etc/rancher/k3s/k3s.yaml
export HOME LANG LC_ALL KUBECONFIG
cd / || exit 2
CHILD_ENV=("PATH=$PATH" "HOME=$HOME" "LANG=$LANG" "LC_ALL=$LC_ALL" "KUBECONFIG=$KUBECONFIG")
SSH_BASE=(ssh -F "$KIT/ssh_config" -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$KIT/known_hosts")   # kit-pinned config + host keys (correctness pins)
xrun() { env -i "${CHILD_ENV[@]}" "$@"; }                                  # every child: env -i + the fixed env
rsh() { env -i "${CHILD_ENV[@]}" "${SSH_BASE[@]}" -n prod "$1"; }          # a remote command, no stdin
rtool() { env -i "${CHILD_ENV[@]}" "${SSH_BASE[@]}" prod "$1" < "$KIT/$2"; } # a remote command, stdin = a SUMS-checked kit file
rtool2() { env -i "${CHILD_ENV[@]}" "${SSH_BASE[@]}" prod "$1" < <(cat -- "$KIT/$2" "$KIT/$3"); } # stdin = 2 SUMS-checked kit files, one after the other (v3e: full-render-diff.py + the tool)

# ---- value regexes (one per key) ----
R_SHA40='^[0-9a-f]{40}$'
R_SHA256='^[0-9a-f]{64}$'
R_REV='^[1-9][0-9]{0,5}$'
R_STEP='^[1-9][0-9]?$'
R_TAG='^[a-z0-9][a-z0-9-]{0,31}$'
R_HEX='^[0-9a-f]{12,64}$'
R_PGVER='^[0-9a-z_]{1,32}(,[0-9a-z_]{1,32}){0,7}$'
R_K8S='[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?'
R_K8SLIST="^$R_K8S(,$R_K8S){0,31}\$"
R_SCALERS="^(none|$R_K8S(,$R_K8S){0,31})\$"
R_YESNO='^(yes|no)$'
R_BOOL='^(true|false)$'
R_OCT='(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])'
R_CIDR="^$R_OCT(\\.$R_OCT){3}/([0-9]|[12][0-9]|3[0-2])\$"
R_FKEYS='^[a-z0-9][a-z0-9-]{0,62}(,[a-z0-9][a-z0-9-]{0,62}){0,15}$'
R_DOCS='^[1-9][0-9]{0,3}$'
R_GUARD='^[56]$'
R_KN="[A-Z][A-Za-z]{1,40}/$R_K8S"
R_FPATH='\.[A-Za-z0-9_][A-Za-z0-9_./-]{0,200}(\[[0-9]{1,3}\][A-Za-z0-9_./-]{0,200}){0,8}'   # v3i: '/' allowed (label keys such as app.kubernetes.io/name)
R_FVAL='(<none>|[A-Za-z0-9./:,!_=@+-]{1,200})'
R_IMGROW="^$R_KN $R_FPATH $R_FVAL $R_FVAL\$"
R_LIVEABSENT="^$R_KN $R_FPATH\$"
R_ADDDOC="^$R_KN\$"
R_ALINE='^([0-9a-f]{40}|[0-9]{1,3})$'
R_LEAD='^[a-z][a-z0-9-]{1,31}$'   # a lead name: the inputs AUTHOR and the ATTEST checker (D6436)
R_NAME="^$R_K8S\$"
R_SECKEYS='^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?:[A-Za-z0-9_.-]{1,64}(,[A-Za-z0-9_.-]{1,64}){0,31}$'   # <secret>:<key>[,<key>...] (key NAMES)
R_LPATH='^(/home/ubuntu/devhealth/\.remember/acr-mcp/lanes|/var/lib/oci-cache/lane-scratch)(/[A-Za-z0-9_][A-Za-z0-9._-]{0,127}){1,12}$'

# ---- the final line each step must print (with rc 0 or its allowed rc) ----
F_GATE='^GATE [A-Za-z0-9_-]+: PASS'
F_REMOTE='^GATE-REMOTE: PASS$'
F_POD='^[a-z0-9.-]+ +[^ ]+ +[0-9,]+ +[A-Za-z]+ +[a-z0-9.-]+$'   # v3f: kubectl custom-columns pads with runs of spaces (s20-a STOP)
F_HIST='^[0-9]+ '

usage() { echo "usage: prodroll.sh roll dev-health <inputs> pre|deploy|wait|post | roll ingress-nginx <inputs> pre|upgrade|post | secret-pipe f1pipe <inputs> | readback dev-health-post|scrapecheck|podsnap|ingress-nginx <inputs> | rollback dev-health|ingress-nginx <inputs> <RUN_TAG>"; }
sha_of() { local s; s=$(sha256sum < "$1" 2>/dev/null) || { echo -; return 0; }; echo "${s%% *}"; }

# ---- argv: a fixed grammar (enums only) ----
SUB=${1:-}; ARG=${2:-}; INP=${3:-}; PH=${4:-}; TGT=; WANT=x; RB_TAG=
case "$SUB:$ARG" in
  roll:dev-health) TGT=dev-health; case "$PH" in pre|deploy|wait|post) WANT=4;; esac ;;
  roll:ingress-nginx) TGT=ingress-nginx; case "$PH" in pre|upgrade|post) WANT=4;; esac ;;
  secret-pipe:f1pipe) TGT=f1pipe; WANT=3 ;;
  secret-pipe:load-secrets|secret-pipe:pgbouncer-secret) TGT=stub; WANT=3 ;;
  readback:dev-health-post|readback:scrapecheck|readback:podsnap) TGT=dev-health; WANT=3 ;;
  readback:ingress-nginx) TGT=ingress-nginx; WANT=3 ;;
  rollback:dev-health|rollback:ingress-nginx) TGT=$ARG; [[ $PH =~ $R_TAG ]] && { WANT=4; RB_TAG=$PH; } ;;
esac
SELF_SHA=$(sha_of "$SELF")
if [ "$WANT" != "$#" ]; then echo "PRODROLL v$KIT_VERSION sha256(prodroll.sh)=$SELF_SHA sums=- inputs=- sha256(inputs)=- cmd=usage-error"; usage; echo "PRODROLL REFUSED (exit 2): usage (nothing else read, no run log, no ssh)"; exit 2; fi
CMD="$SUB $ARG $PH"; CMD=${CMD% }
if [ "$MODE" = copy ] && { [ -z "$TESTPATH" ] || [ "$(command -v ssh)" != "$TESTPATH/ssh" ] || [ "$TESTPATH/ssh" -ef /usr/bin/ssh ]; }; then
  echo "PRODROLL v$KIT_VERSION sha256(prodroll.sh)=$SELF_SHA sums=- inputs=- sha256(inputs)=- cmd=$CMD"
  echo "PRODROLL REFUSED (exit 6): copy mode ($SELF is not $PROD_SELF) runs only with PRODROLL_TEST_PATH under /var/lib/oci-cache/lane-scratch/ (no .. component) whose ssh is the one PATH resolves and is not the real /usr/bin/ssh (-ef)"; exit 6
fi

# ---- the inputs: read ONCE into memory; the hash and the parse use this one buffer ----
SUMS_SHA=missing; [ -f "$KIT/SHA256SUMS" ] && SUMS_SHA=$(sha_of "$KIT/SHA256SUMS")
if [[ $INP =~ ^/[A-Za-z0-9._/-]{1,300}$ ]]; then INP_SHOW=$INP; else INP_SHOW='<not-a-plain-path>'; fi
INP_SHA=-; INBUF=; INP_STATE=bad-path
if [ "$INP_SHOW" = "$INP" ] && [[ $INP =~ $R_LPATH ]] && [ -f "$INP" ] && [ ! -L "$INP" ] && [ "$(readlink -f -- "$INP")" = "$INP" ]; then
  INP_STATE=too-big; insz=$(stat -c %s -- "$INP")
  if [ "$insz" -le 65536 ]; then
    IFS= read -r -d '' INBUF < "$INP"
    if [ "${#INBUF}" = "$insz" ]; then INP_SHA=$(printf '%s' "$INBUF" | sha256sum | cut -c1-64); INP_STATE=ok; else INP_STATE=nul; fi
  fi
fi
LINE1="PRODROLL v$KIT_VERSION sha256(prodroll.sh)=$SELF_SHA sums=$SUMS_SHA inputs=$INP_SHOW sha256(inputs)=$INP_SHA cmd=$CMD"

HMS=$(date -u +%H%M%S)
LOG=$LOGDIR/PRODROLL-$SUB-$ARG-${HMS}Z.log; n=1
until { : > "$LOG"; } 2>/dev/null; do
  n=$((n+1)); [ "$n" -le 9 ] || { echo "$LINE1"; echo "PRODROLL REFUSED (exit 2): cannot create a new run log in $LOGDIR"; exit 2; }
  LOG=$LOGDIR/PRODROLL-$SUB-$ARG-${HMS}Z-$n.log
done

refuse() { echo "PRODROLL REFUSED (exit 2): $*"; exit 2; }
stop() { echo "PRODROLL STOP (exit 1): $* -- no further step, no auto-rollback"; exit 1; }
mark() { { : > "$1"; } 2>/dev/null || stop "marker $1 exists"; }

# ---- self-check and kit check (rc 6) ----
self_check() { echo "SELF: sha256(prodroll.sh without the pin line) = pinned $SELF_HASH (checked at the top, before the pin line ran: exactly 1 pin line, line $SELF_PIN_N, deleted by number)"; }
kit_check() {
  local s o listed present
  s=$(sha_of "$KIT/SHA256SUMS")
  [ "$s" = "$PINNED_SUMS_SHA256" ] || { echo "PRODROLL REFUSED (exit 6): sha256(prodroll-v3/SHA256SUMS)=$s, pinned $PINNED_SUMS_SHA256"; exit 6; }
  o=$(cd -- "$KIT" && sha256sum -c --strict --quiet SHA256SUMS 2>&1) || { printf '%s\n' "$o" | head -20; echo "PRODROLL REFUSED (exit 6): sha256sum -c of the kit failed"; exit 6; }
  listed=$(sed -E 's/^[0-9a-f]{64} [ *]//' "$KIT/SHA256SUMS" | sort)
  present=$(find "$KIT" -type f ! -path "$KIT/SHA256SUMS" | sed "s|^$KIT/||" | sort)
  [ "$listed" = "$present" ] || { echo "PRODROLL REFUSED (exit 6): the kit holds a file that SHA256SUMS does not list (or the reverse)"; exit 6; }
  [ -z "$(find "$KIT" ! -type f ! -type d)" ] || { echo "PRODROLL REFUSED (exit 6): the kit holds a link or a special file"; exit 6; }
  echo "KIT v$KIT_VERSION: $KIT; SHA256SUMS = pinned $s; sha256sum -c OK ($(grep -vc '^$' "$KIT/SHA256SUMS") files); no unlisted file, no link"
}

# ---- inputs reader: DATA only, from the one buffer, attested by sha ----
declare -A V=()
IMGROW=(); LIVEABSENT=(); ADDDOC=(); ASTEP_LINE=(); REMOVED_DOC=(); ADDED_DOC=(); SECRET_KEEP=(); HOOK_SECRET=(); SECRET_KEYS=()
lpath_ok() { [[ $1 =~ $R_LPATH ]] && [ -f "$1" ] && [ ! -L "$1" ] && [ "$(readlink -f -- "$1")" = "$1" ]; }
keyre() { # the regex of key $1 for target $TGT; rc 1 = not a key of this target
  case "$1" in PRODROLL_INPUTS) echo '^3$'; return 0;; TARGET) echo '^(dev-health|ingress-nginx|f1pipe)$'; return 0;; RUN_TAG) echo "$R_TAG"; return 0;; AUTHOR) echo "$R_LEAD"; return 0;; esac
  case "$TGT:$1" in
    dev-health:STEP) echo "$R_STEP";;
    dev-health:SVC_SHA|dev-health:ROLLBACK_SHA) echo "$R_SHA40";;
    dev-health:EXP_START_REV|dev-health:ROLLBACK_REV|dev-health:EXPECT_NEWEST_REV|ingress-nginx:EXP_START_REV|ingress-nginx:ROLLBACK_REV|ingress-nginx:EXPECT_NEWEST_REV) echo "$R_REV";;
    dev-health:GUARD_LIVE_STEP) echo "$R_GUARD";;
    dev-health:PGVER) echo "$R_PGVER";;
    dev-health:IMG_OLD|dev-health:IMG_NEW) echo "$R_HEX";;
    dev-health:IMGROW) echo "$R_IMGROW";;
    dev-health:LIVEABSENT) echo "$R_LIVEABSENT";;
    dev-health:ADDDOC|dev-health:REMOVED_DOC|dev-health:ADDED_DOC) echo "$R_ADDDOC";;
    dev-health:SECRET_KEEP|dev-health:HOOK_SECRET) echo "$R_NAME";;
    dev-health:SECRET_KEYS) echo "$R_SECKEYS";;
    dev-health:RENDER_FILE|dev-health:SERIES_FILE) echo "$R_LPATH";;
    dev-health:RENDER_SHA256) echo "$R_SHA256";;
    dev-health:PODSNAP_TARGETS) echo "$R_K8SLIST";;
    dev-health:PODSNAP_SCALERS) echo "$R_SCALERS";;
    dev-health:SCRAPE|dev-health:MIGJOBLOG) echo "$R_YESNO";;
    ingress-nginx:TREE_SHA|ingress-nginx:VALUES_BLOB|ingress-nginx:BASE_SHA) echo "$R_SHA40";;
    ingress-nginx:EXPECT_USE_FORWARDED_HEADERS|ingress-nginx:EXPECT_COMPUTE_FULL_FORWARDED_FOR) echo "$R_BOOL";;
    ingress-nginx:EXPECT_PROXY_REAL_IP_CIDR|ingress-nginx:CNI_ADDR) echo "$R_CIDR";;
    ingress-nginx:P3_HELM_KEYS|ingress-nginx:P3_PATCH_KEYS) echo "$R_FKEYS";;
    ingress-nginx:MIN_DOCS) echo "$R_DOCS";;
    f1pipe:ASTEP_LINE) echo "$R_ALINE";;
    *) return 1;;
  esac
}
att_check() { # D6436 peer check: of the ATTEST lines whose field 1 is the inputs sha, at least one must have exactly 4 fields, a checker (field 4) that matches R_LEAD, and checker != AUTHOR
  local nr nf ck line why= ok=
  while IFS=$'\t' read -r nr nf ck line; do
    if [ "$nf" != 4 ]; then why+="${why:+; }line $nr: $nf fields (want exactly 4)"
    elif ! [[ $ck =~ $R_LEAD ]]; then why+="${why:+; }line $nr: checker '${ck:0:40}' is not $R_LEAD"
    elif [ "$ck" = "$AUTHOR" ]; then why+="${why:+; }line $nr: checker $ck == AUTHOR $AUTHOR (the author cannot check their own inputs)"
    else ok=$ck; ATTEST_LINE=$line; break; fi
  done < <(awk -v s="$INP_SHA" '$1 == s {printf "%d\t%d\t%s\t%s\n", NR, NF, $4, $0}' "$ATTEST")
  [ -n "$ok" ] || refuse "inputs: no line of $ATTEST for sha256 $INP_SHA is a peer check: $why. A peer lead (any lead except AUTHOR $AUTHOR) appends \"<sha256> <roll> <UTC> <checker>\""
  echo "ATTEST: sha256(inputs) $INP_SHA is listed in $ATTEST: peer check by $ok (AUTHOR $AUTHOR): ${ATTEST_LINE:0:160}"
}
need() { local k; for k in "$@"; do [ -n "${V[$k]+x}" ] || refuse "inputs: missing key $k"; done; }
parse_inputs() {
  local n=0 l k v re bad
  case "$INP_STATE" in ok) ;; nul) refuse "inputs: the file holds a NUL byte";; too-big) refuse "inputs: larger than 64 KiB";; *) refuse "inputs path: not a regular, non-link file (realpath = path) under /home/ubuntu/devhealth/.remember/acr-mcp/lanes/ or /var/lib/oci-cache/lane-scratch/";; esac
  [ -f "$ATTEST" ] && [ ! -L "$ATTEST" ] || refuse "attest file $ATTEST is missing or a link"
  awk -v s="$INP_SHA" '$1 == s {k=1} END {exit !k}' "$ATTEST" || refuse "inputs: sha256 $INP_SHA is not listed in $ATTEST (a peer lead appends \"<sha256> <roll> <UTC> <checker>\" after its inputs check; the checker is any lead except the inputs AUTHOR)"
  INCOPY=${LOG%.log}.inputs
  printf '%s' "$INBUF" > "$INCOPY" || refuse "inputs: cannot write the record copy $INCOPY"
  echo "INPUTS record copy (the buffer this run hashed and parses): $INCOPY"
  bad=$(printf '%s' "$INBUF" | tr -d '\040-\176\n' | wc -c)
  [ "$bad" = 0 ] || refuse "inputs: $bad byte(s) outside printable ASCII + LF (TAB, CR, non-ASCII)"
  while IFS= read -r l || [ -n "$l" ]; do
    n=$((n+1)); [ "$n" -le 300 ] || refuse "inputs: more than 300 lines"
    case "$l" in ""|"#"*) continue;; esac
    [[ $l =~ ^([A-Z][A-Z0-9_]{0,47})=(.*)$ ]] || refuse "inputs line $n: not KEY=VALUE (KEY = [A-Z][A-Z0-9_]*, no space)"
    k=${BASH_REMATCH[1]}; v=${BASH_REMATCH[2]}
    re=$(keyre "$k") || refuse "inputs line $n: unknown key $k for target $TGT"
    [[ $v =~ $re ]] || refuse "inputs line $n: bad value for $k (regex $re)"
    case "$k" in
      IMGROW) IMGROW+=("$v");; LIVEABSENT) LIVEABSENT+=("$v");; ADDDOC) ADDDOC+=("$v");; ASTEP_LINE) ASTEP_LINE+=("$v");;
      REMOVED_DOC) REMOVED_DOC+=("$v");; ADDED_DOC) ADDED_DOC+=("$v");; SECRET_KEEP) SECRET_KEEP+=("$v");; HOOK_SECRET) HOOK_SECRET+=("$v");; SECRET_KEYS) SECRET_KEYS+=("$v");;
      *) [ -z "${V[$k]+x}" ] || refuse "inputs line $n: duplicate key $k"; V[$k]=$v;;
    esac
  done <<< "$INBUF"
  need PRODROLL_INPUTS TARGET RUN_TAG AUTHOR
  AUTHOR=${V[AUTHOR]}; att_check
  [ "${V[TARGET]}" = "$TGT" ] || refuse "inputs: TARGET=${V[TARGET]}, the subcommand needs TARGET=$TGT"
  RUN_TAG=${V[RUN_TAG]}
  [ -z "$RB_TAG" ] || [ "$RB_TAG" = "$RUN_TAG" ] || refuse "rollback RUN_TAG $RB_TAG is not the RUN_TAG of these inputs ($RUN_TAG)"
  case "$TGT" in dev-health) parse_dh;; ingress-nginx) parse_ing;; f1pipe) parse_f1;; esac
  echo "INPUTS: PASS ($n lines, target $TGT, run tag $RUN_TAG)"
}

# ---- dev-health: the g0-vars-24d.sh derivations, ported (data in, values out; nothing sourced) ----
parse_dh() {
  local r kn path old new np pairs rsz
  need STEP SVC_SHA ROLLBACK_SHA EXP_START_REV GUARD_LIVE_STEP PGVER RENDER_FILE RENDER_SHA256 PODSNAP_TARGETS PODSNAP_SCALERS SCRAPE MIGJOBLOG ROLLBACK_REV EXPECT_NEWEST_REV
  [ "${#IMGROW[@]}" -ge 1 ] && [ "${#IMGROW[@]}" -le 64 ] || refuse "inputs: need 1..64 IMGROW lines (got ${#IMGROW[@]})"
  STEP=${V[STEP]}; SVC_SHA=${V[SVC_SHA]}; PS_R0=${V[ROLLBACK_SHA]}; EXP_START_REV=${V[EXP_START_REV]}; GUARD_LIVE_STEP=${V[GUARD_LIVE_STEP]}
  PG_EXPECT=${V[PGVER]}; DEFER_STEPS=4; EXPECT_NEWEST_REV=${V[EXPECT_NEWEST_REV]}; ROLLBACK_REV=${V[ROLLBACK_REV]}
  PODSNAP_TARGETS=${V[PODSNAP_TARGETS]}; PODSNAP_SCALERS=${V[PODSNAP_SCALERS]}
  [ "$ROLLBACK_REV" = "$EXP_START_REV" ] || refuse "inputs: ROLLBACK_REV ($ROLLBACK_REV) must equal EXP_START_REV ($EXP_START_REV): the rollback target is the revision before the step"
  [ "$EXPECT_NEWEST_REV" = "$((EXP_START_REV + 1))" ] || refuse "inputs: EXPECT_NEWEST_REV ($EXPECT_NEWEST_REV) must be EXP_START_REV + 1 ($((EXP_START_REV + 1))): the roll makes exactly one revision"
  [ "$SVC_SHA" != "$PS_R0" ] || refuse "inputs: SVC_SHA equals ROLLBACK_SHA"
  lpath_ok "${V[RENDER_FILE]}" || refuse "inputs: RENDER_FILE is not a regular, non-link file under the fixed roots"
  rsz=$(stat -c %s -- "${V[RENDER_FILE]}"); [ "$rsz" -le 16777216 ] || refuse "inputs: RENDER_FILE is larger than 16 MiB"
  RENDERBUF=; IFS= read -r -d '' RENDERBUF < "${V[RENDER_FILE]}"   # read ONCE: the sha check and the use (I2) take this buffer
  [ "${#RENDERBUF}" = "$rsz" ] && [ "$(printf '%s' "$RENDERBUF" | sha256sum | cut -c1-64)" = "${V[RENDER_SHA256]}" ] || refuse "inputs: sha256(RENDER_FILE) != RENDER_SHA256 (or a NUL byte)"
  IMGROWS=; for r in "${IMGROW[@]}"; do IMGROWS+="$r;"; done
  LIVEROWS=$IMGROWS; for r in "${LIVEABSENT[@]}"; do LIVEROWS+="$r <none> <none>;"; done
  ADDDOCS=$(IFS=,; printf '%s' "${ADDDOC[*]}")
  IMG_DEPLOYS=$(for r in "${IMGROW[@]}"; do read -r kn path old new <<< "$r"; case "$kn:$path" in Deployment/*:.spec.template.*) printf '%s\n' "${kn#Deployment/}";; esac; done | sort -u | paste -sd, -)
  pairs=$(for r in "${IMGROW[@]}"; do read -r kn path old new <<< "$r"; case "$kn:$path" in Deployment/*:*.image) [[ $old =~ $R_HEX && $new =~ $R_HEX ]] && printf '%s %s\n' "$old" "$new";; esac; done | sort -u)
  np=$(printf '%s\n' "$pairs" | grep -vc '^$')
  IMG_OLD=; IMG_NEW=; ROLLBACK_IMG_PREFIX=
  if [ "$np" -gt 1 ]; then refuse "inputs: the Deployment .image rows disagree on the digest pair"
  elif [ "$np" = 1 ]; then
    IMG_OLD=${pairs%% *}; IMG_NEW=${pairs##* }; IMG_MODE=rolls; ROLLBACK_IMG_PREFIX=$IMG_OLD
    { [ -z "${V[IMG_OLD]+x}" ] || [ "${V[IMG_OLD]}" = "$IMG_OLD" ]; } && { [ -z "${V[IMG_NEW]+x}" ] || [ "${V[IMG_NEW]}" = "$IMG_NEW" ]; } || refuse "inputs: IMG_OLD/IMG_NEW differ from the Deployment .image rows"
  else
    need IMG_OLD; IMG_OLD=${V[IMG_OLD]}; IMG_NEW=${V[IMG_NEW]:-}; IMG_MODE=norolls; IMG_DEPLOYS=none
  fi
  if [ "${#IMG_OLD}" -lt 12 ] || { [ -n "$IMG_NEW" ] && [ "$IMG_OLD" = "$IMG_NEW" ]; } || { [ "$IMG_MODE" = rolls ] && [ -z "$IMG_NEW" ]; }; then refuse "inputs: the old/new digest prefixes are not two different hex prefixes of 12+ characters"; fi
  docs_rules
  ANC_SHAS="$SVC_SHA $PS_R0"; TREES="$DEPLOY_TREE $ROLLBACK_TREE"; REL_ARGS='dev-health -n dev-health'
  WORK=$LOGDIR/PRODROLL-WORK-dev-health-i$STEP-$RUN_TAG
}
parse_ing() {
  need TREE_SHA VALUES_BLOB BASE_SHA EXPECT_USE_FORWARDED_HEADERS EXPECT_PROXY_REAL_IP_CIDR EXPECT_COMPUTE_FULL_FORWARDED_FOR P3_HELM_KEYS P3_PATCH_KEYS CNI_ADDR MIN_DOCS EXP_START_REV ROLLBACK_REV EXPECT_NEWEST_REV
  BASE_SHA=${V[BASE_SHA]}; CNI_ADDR=${V[CNI_ADDR]}; EXP_START_REV=${V[EXP_START_REV]}; EXPECT_NEWEST_REV=${V[EXPECT_NEWEST_REV]}; ROLLBACK_REV=${V[ROLLBACK_REV]}
  TREE_SHA=${V[TREE_SHA]}; VALUES_BLOB=${V[VALUES_BLOB]}
  [ "$ROLLBACK_REV" = "$EXP_START_REV" ] || refuse "inputs: ROLLBACK_REV ($ROLLBACK_REV) must equal EXP_START_REV ($EXP_START_REV)"
  [ "$EXPECT_NEWEST_REV" = "$((EXP_START_REV + 1))" ] || refuse "inputs: EXPECT_NEWEST_REV ($EXPECT_NEWEST_REV) must be EXP_START_REV + 1 ($((EXP_START_REV + 1))): the roll makes exactly one revision"
  P3_HELM_JSON=$(fjson "${V[P3_HELM_KEYS]}"); P3_PATCH_JSON=$(fjson "${V[P3_PATCH_KEYS]}"); R1_HELM_JSON=$(fjson "${V[P3_HELM_KEYS]},${V[P3_PATCH_KEYS]}")
  ANC_SHAS=$TREE_SHA; TREES=$DEPLOY_TREE; REL_ARGS='-n ingress-nginx ingress-nginx'
  WORK=$LOGDIR/PRODROLL-WORK-ingress-nginx-$RUN_TAG
}
parse_f1() {
  [ "${#ASTEP_LINE[@]}" = 14 ] || refuse "inputs: need exactly 14 ASTEP_LINE lines (PREP-11709-rev420.md:78), got ${#ASTEP_LINE[@]}"
  WORK=$LOGDIR/PRODROLL-WORK-f1pipe-$RUN_TAG
}
# ---- v3e: the docs that leave/enter the render and the Secrets that must stay live, named exactly in the inputs (pm rule) ----
inlist() { local x=$1 y; shift; for y in "$@"; do [ "$x" = "$y" ] && return 0; done; return 1; }
docs_rules() {
  local a x n
  for a in REMOVED_DOC ADDED_DOC SECRET_KEEP HOOK_SECRET SECRET_KEYS ADDDOC; do
    case "$a" in REMOVED_DOC) n=${#REMOVED_DOC[@]}; x=$(printf '%s\n' "${REMOVED_DOC[@]}" | sort | uniq -d);; ADDED_DOC) n=${#ADDED_DOC[@]}; x=$(printf '%s\n' "${ADDED_DOC[@]}" | sort | uniq -d);;
      SECRET_KEEP) n=${#SECRET_KEEP[@]}; x=$(printf '%s\n' "${SECRET_KEEP[@]}" | sort | uniq -d);; HOOK_SECRET) n=${#HOOK_SECRET[@]}; x=$(printf '%s\n' "${HOOK_SECRET[@]}" | sort | uniq -d);;
      SECRET_KEYS) n=${#SECRET_KEYS[@]}; x=$(printf '%s\n' "${SECRET_KEYS[@]%%:*}" | sort | uniq -d);; ADDDOC) n=${#ADDDOC[@]}; x=$(printf '%s\n' "${ADDDOC[@]}" | sort | uniq -d);; esac
    [ "$n" -le 32 ] || refuse "inputs: more than 32 $a lines"; [ -z "$x" ] || refuse "inputs: duplicate $a: $x"
  done
  for x in "${REMOVED_DOC[@]}"; do
    [[ $x == Secret/* ]] || refuse "inputs: REMOVED_DOC $x: v3e names removed Secret docs only (the attested RENDER-PATHS r11 HOLDs on any removed non-Secret doc)"
    inlist "${x#Secret/}" "${SECRET_KEEP[@]}" "${HOOK_SECRET[@]}" || refuse "inputs: REMOVED_DOC $x has no SECRET_KEEP or HOOK_SECRET (a Secret that leaves the release must stay live by its keep annotation, or be a hook Secret)"
  done
  for x in "${HOOK_SECRET[@]}"; do inlist "Secret/$x" "${REMOVED_DOC[@]}" || refuse "inputs: HOOK_SECRET $x is not a REMOVED_DOC Secret/$x"; done
  for x in "${ADDDOC[@]}"; do inlist "$x" "${ADDED_DOC[@]}" || refuse "inputs: ADDDOC $x is not an ADDED_DOC (the names gate must expect it too)"; done
  for x in "${ADDED_DOC[@]}"; do [[ $x == Secret/* ]] || inlist "$x" "${ADDDOC[@]}" || refuse "inputs: ADDED_DOC $x (not a Secret) needs ADDDOC=$x (RENDER-PATHS checks its fields)"; done
  REMOVED_SORTED=$( [ ${#REMOVED_DOC[@]} = 0 ] || printf '%s\n' "${REMOVED_DOC[@]}" | sort | paste -sd' ' -)
  ADDED_SORTED=$( [ ${#ADDED_DOC[@]} = 0 ] || printf '%s\n' "${ADDED_DOC[@]}" | sort | paste -sd' ' -)
  KEEP_LIST="${SECRET_KEEP[*]}"; KEYS_LIST="${SECRET_KEYS[*]}"
  FRD_LEN=$(stat -c %s -- "$KIT/full-render-diff.py"); FRD_SHA=$(sha_of "$KIT/full-render-diff.py")
}
fjson() { local k out=; while IFS= read -r k; do [ -n "$k" ] && out+="${out:+,}\"f:$k\":{}"; done < <(tr , '\n' <<< "$1" | sort -u); printf '{%s}' "$out"; }

# ---- step runner: stdout -> the run log and OUTD/<label>.out. Success = an allowed rc AND the step's own final line (regex) AND no FAIL/REFUSED/HOLD word ----
OUTD=; SRC=
step_rc() {
  local lb=$1 ok=$2 fre=$3 f rc last; shift 3; f=$OUTD/$lb.out
  [ ! -e "$f" ] || stop "$lb: $f exists (records are append-only)"
  echo "== $lb $(date -u +%FT%TZ)"
  "$@" | tee -- "$f"; rc=${PIPESTATUS[0]}
  echo "== $lb rc=$rc"
  case " $ok " in *" $rc "*) ;; *) stop "$lb rc=$rc";; esac
  last=$(grep -v '^[[:space:]]*$' -- "$f" | tail -1)
  [[ $last =~ $fre ]] || stop "$lb rc=$rc but its final line is not the tool's PASS line (want /$fre/, got: ${last:0:120})"
  if grep -qwE 'FAIL|REFUSED|HOLD' -- "$f"; then stop "$lb printed FAIL, REFUSED or HOLD"; fi
  SRC=$rc
}
step() { step_rc "$1" 0 "$2" "${@:3}"; }
newout() { OUTD=$WORK/$1; mkdir -p -- "$WORK" && mkdir -- "$OUTD" || stop "cannot create $OUTD"; echo "STEP OUTPUTS: $OUTD"; }
inputs_same() { [ -f "$WORK/inputs.sha256" ] && [ "$(cat -- "$WORK/inputs.sha256")" = "$INP_SHA" ] || refuse "the inputs file differs from the one the pre phase of RUN_TAG $RUN_TAG ran with ($WORK/inputs.sha256)"; }
begin_pre() { [ ! -e "$WORK" ] || refuse "$WORK exists: a new pre phase needs a new RUN_TAG"; mkdir -p -- "${WORK%/*}" && mkdir -- "$WORK" || refuse "cannot create $WORK"; printf '%s\n' "$INP_SHA" > "$WORK/inputs.sha256"; newout pre; }
helm_newest() { awk '$1 ~ /^[0-9]+$/ {r=$1; s=$7} END {print r, s}' "$1"; }
pre_fresh() { local t now; t=$(st_get PREEND) || refuse "state PREEND missing in $WORK/state.txt"; now=$(date -u +%s)
  [ $((now - t)) -le "$PRE_MAX_AGE" ] || refuse "the pre phase ended $((now - t)) s ago (> $PRE_MAX_AGE s): run a new pre phase (new RUN_TAG)"; echo "PRE AGE: $((now - t)) s (<= $PRE_MAX_AGE s)"; }

# ---- run state per RUN_TAG (append-only, noclobber markers; the STATE-24d.sh `from` rules); never sourced ----
state_put() { local k=$1 v=$2
  case "$k" in LIVEREV|RESTARTS0|PREEND) [[ $v =~ ^[0-9]+$ ]] || stop "STATE $k='$v' is not a number";; RESTARTMAP) [[ $v =~ ^[A-Za-z0-9.:,_-]+$ ]] || stop "STATE RESTARTMAP has a bad character";; GROUPDIG) [[ $v =~ ^[a-z0-9:,+-]+$ ]] || stop "STATE GROUPDIG has a bad character";; *) stop "STATE: unknown key $k";; esac
  grep -q "^$k=" "$WORK/state.txt" 2>/dev/null && stop "STATE $k is already set in $WORK/state.txt"
  printf '%s=%s\n' "$k" "$v" >> "$WORK/state.txt"; echo "STATE $k=${v:0:60}"; }
state_from() { local f=$1 k; shift; for k in "$@"; do state_put "$k" "$(sed -n "s/^STATE $k=//p" "$f" | tail -1)"; done; }
st_get() { local v; v=$(sed -n "s/^$1=//p" "$WORK/state.txt" 2>/dev/null | tail -1); [[ $v =~ ^[0-9]+$ ]] || return 1; printf '%s' "$v"; }
st_getmap() { local v; v=$(sed -n "s/^GROUPDIG=//p" "$WORK/state.txt" 2>/dev/null | tail -1); [[ $v =~ ^[a-z0-9:,+-]+$ ]] || return 1; printf '%s' "$v"; }   # v3h

# ---- the remote correctness gates (one text, used in pre and in the SAME ssh as the deploy/upgrade):
#      clone checks (origin == DEPLOY_URL, no url.* key in any git config scope, `git status --porcelain` empty) on every tree;
#      fetch --no-tags refs/heads/main from the pinned URL; the fetched sha == ls-remote refs/heads/main; every code-selecting sha is an
#      ancestor of it AND on its first-parent chain. Any miss: `GATE-REMOTE STOP: ...` and exit 3 before anything else runs. ----
gate_snippet() { printf '%s' 'gfail() { echo "GATE-REMOTE STOP: $*"; exit 3; }; for t in '"$TREES"'; do u=$(git -C "$t" config --get remote.origin.url </dev/null) || gfail "$t: no remote.origin.url"; [ "$u" = "'"$DEPLOY_URL"'" ] || gfail "$t: remote.origin.url is not the pinned URL"; k=$(git -C "$t" config --get-regexp "^url\\." </dev/null | wc -l); [ "$k" = 0 ] || gfail "$t: $k url.* key(s) in its git config (insteadOf)"; s=$(git -C "$t" status --porcelain </dev/null | wc -l); [ "$s" = 0 ] || gfail "$t: git status --porcelain shows $s line(s)"; echo "CLONE $t origin=pinned url_keys=0 porcelain=0"; done; cd '"$DEPLOY_TREE"' || gfail "cd '"$DEPLOY_TREE"'"; git fetch -q --no-tags '"$DEPLOY_URL"' refs/heads/main </dev/null || gfail "git fetch --no-tags refs/heads/main failed"; f=$(git rev-parse FETCH_HEAD </dev/null); l=$(git ls-remote '"$DEPLOY_URL"' refs/heads/main </dev/null | awk "{print \$1}"); [ -n "$f" ] && [ "$f" = "$l" ] || gfail "fetched main $f != ls-remote refs/heads/main $l"; echo "MAIN $f = ls-remote refs/heads/main"; fp=$(git rev-list --first-parent FETCH_HEAD </dev/null) || gfail "rev-list --first-parent failed"; for s in '"$ANC_SHAS"'; do git merge-base --is-ancestor "$s" FETCH_HEAD </dev/null 2>/dev/null || gfail "$s is not an ancestor of main $f"; printf "%s\n" "$fp" | grep -qx "$s" || gfail "$s is not on the first-parent chain of main $f"; echo "SHA $s ancestor=1 first_parent=1"; done; '; }
newest_snippet() { printf '%s' 'nw=$(helm history '"$REL_ARGS"' --max 1 </dev/null | awk "\$1 ~ /^[0-9]+\$/ {r=\$1; s=\$7} END {print r, s}"); [ "$nw" = "'"$1"' deployed" ] || gfail "live newest revision [$nw] is not the pre LIVEREV '"$1"' deployed"; echo "NEWEST $nw = the pre LIVEREV"; '; }
p0_snippet() { printf '%s' 'cd '"$DEPLOY_TREE"' || gfail cd; h=$(git rev-parse HEAD </dev/null); d=$(git status --porcelain --untracked-files=no </dev/null | wc -l); vb=$(git rev-parse HEAD:'"$ING_VALUES"' </dev/null); vd=$(git hash-object '"$ING_VALUES"' </dev/null); t=$(sha256sum '"$ING_TGZ"' </dev/null | awk "{print \$1}"); echo "P0u HEAD $h dirty=$d values_blob=$vb disk=$vd tgz=$t"; [ "$h" = "'"$TREE_SHA"'" ] && [ "$d" = 0 ] && [ "$vb" = "'"$VALUES_BLOB"'" ] && [ "$vd" = "'"$VALUES_BLOB"'" ] && [ "$t" = "'"$ING_TGZ_SHA256"'" ] || gfail "P0u: the tree, values or tgz differ from the inputs and the pinned tgz"; '; }
gates() { rsh "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; $(gate_snippet)echo 'GATE-REMOTE: PASS'"; }
GFAIL='gfail() { echo "GATE-REMOTE STOP: $*"; exit 3; }; '
# v3e names gate: full-render-diff.py (SUMS-checked) comes first on stdin, read with `read -N <its length>` (bytes; LC_ALL=C) and sha-checked; the rest of
# stdin stays for the `bash -s` tool after it. Both trees are rendered with RENDER-PATHS' exact helm args, in memory; only Kind/name lines are kept.
docs_snippet() { printf '%s' 'IFS= read -r -d "" -N '"$FRD_LEN"' FRD; f=$(mktemp) || gfail "mktemp"; trap '"'"'rm -f "$f"'"'"' EXIT; printf "%s" "$FRD" > "$f"; [ "$(sha256sum < "$f" | cut -c1-64)" = "'"$FRD_SHA"'" ] || gfail "the full-render-diff.py on stdin is not '"$FRD_SHA"'"; dn() ( set -o pipefail; cd "$1" || exit 1; helm dependency build chart >/dev/null 2>&1; helm template dev-health chart --namespace dev-health -f values.kiac.yaml -f values.prod.yaml -f "$HOME/.config/dev-health/values.prod-secrets.yaml" -f "$HOME/lane-prod-k8s/roll-24d-values.yaml" </dev/null 2>/dev/null | python3 -I "$f" names ); na=$(dn '"$ROLLBACK_TREE"') || gfail "render + names of the rollback tree failed"; nb=$(dn '"$DEPLOY_TREE"') || gfail "render + names of the roll tree failed"; [ -n "$na" ] && [ -n "$nb" ] || gfail "an empty names list"; rm=$(comm -23 <(printf "%s\n" "$na") <(printf "%s\n" "$nb") | paste -sd" " -); ad=$(comm -13 <(printf "%s\n" "$na") <(printf "%s\n" "$nb") | paste -sd" " -); echo "DOCS A $(printf "%s\n" "$na" | wc -l) B $(printf "%s\n" "$nb" | wc -l); removed [$rm]; added [$ad]"; [ "$rm" = "'"$REMOVED_SORTED"'" ] || gfail "removed docs [$rm] != REMOVED_DOC ['"$REMOVED_SORTED"']"; [ "$ad" = "'"$ADDED_SORTED"'" ] || gfail "added docs [$ad] != ADDED_DOC ['"$ADDED_SORTED"']"; echo "DOCS-GATE: PASS (removed = REMOVED_DOC, added = ADDED_DOC)"; '; }
# v3e Secret reads, read-only, D6429/D6423 forms: .type first, the keep annotation by jsonpath, key NAMES by go-template (no value is read or printed)
secret_snippet() { printf '%s' 'for s in '"$KEEP_LIST"'; do ty=$(kubectl -n dev-health get secret "$s" -o jsonpath="{.type}" </dev/null) || gfail "secret $s: the .type read failed (absent?)"; an=$(kubectl -n dev-health get secret "$s" -o jsonpath="{.metadata.annotations.helm\.sh/resource-policy}" </dev/null) || gfail "secret $s: the annotation read failed"; [ "$an" = keep ] || gfail "secret $s: helm.sh/resource-policy is [$an], not keep"; kn=$(kubectl -n dev-health get secret "$s" -o go-template="{{range \$k, \$v := .data}}{{\$k}}{{\"\\n\"}}{{end}}" </dev/null | sort | paste -sd, -) || gfail "secret $s: the key-name read failed"; echo "SECRET-KEEP $s type=$ty keep=yes keys=$kn"; done; for sk in '"$KEYS_LIST"'; do s=${sk%%:*}; ty=$(kubectl -n dev-health get secret "$s" -o jsonpath="{.type}" </dev/null) || gfail "secret $s: the .type read failed (absent?)"; have=$(kubectl -n dev-health get secret "$s" -o go-template="{{range \$k, \$v := .data}}{{\$k}}{{\"\\n\"}}{{end}}" </dev/null | sort | paste -sd, -) || gfail "secret $s: the key-name read failed"; for k in $(tr , " " <<< "${sk#*:}"); do case ",$have," in *",$k,"*) ;; *) gfail "secret $s: key name $k is missing";; esac; done; echo "SECRET-KEYS $s: every named key is present"; done; '; }
secrets() { rsh "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml LC_ALL=C; set -o pipefail; $GFAIL$(secret_snippet)echo 'SECRETS: PASS'"; }
g_secsame() { local a b; a=$(grep '^SECRET-KEEP ' "$WORK/pre/SECRETS.out" | sed 's/ type=[^ ]*//'); b=$(grep '^SECRET-KEEP ' "$OUTD/SECRETS-post.out" | sed 's/ type=[^ ]*//')
  [ -n "$a" ] && [ "$a" = "$b" ] || { echo "GATE SECRETS-SAME: the kept Secrets or their key-name sets differ from pre"; return 1; }; echo "GATE SECRETS-SAME: PASS ($(printf '%s\n' "$a" | wc -l) kept Secret(s): present, keep, the same key-name set as pre)"; }

# ==== roll dev-health: the r11 kit lines (GATE0-IMG.txt v0.8) in the r12 DRAFT order, as fixed code ====
dh_I0() { echo "I0 STEP=$STEP (from the inputs) SVC_SHA=$SVC_SHA PS_R0=$PS_R0 IMG_MODE=$IMG_MODE IMG_OLD=$IMG_OLD IMG_NEW=${IMG_NEW:--} IMG_DEPLOYS=$IMG_DEPLOYS ROLLBACK_IMG_PREFIX=${ROLLBACK_IMG_PREFIX:--} PG_EXPECT=$PG_EXPECT GUARD_LIVE_STEP=$GUARD_LIVE_STEP EXP_START_REV=$EXP_START_REV ROLLBACK_REV=$ROLLBACK_REV DEFER_STEPS=$DEFER_STEPS rows=${#IMGROW[@]} liveabsent=${#LIVEABSENT[@]} adddocs=${ADDDOCS:--}"; }
dh_render() { printf '%s' "$RENDERBUF" | xrun python3 -I "$KIT/full-render-diff.py" filter > "$OUTD/render.yaml" && echo "RENDER_FILE (the buffer read once; sha ${V[RENDER_SHA256]:0:12}) -> full-render-diff filter (Secret docs dropped) -> $OUTD/render.yaml, docs $(grep -c '^kind:' "$OUTD/render.yaml")"; }
dh_V2r() { rtool "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; bash -s -- kitrefresh $SVC_SHA $PS_R0" REFRESH-KIT-v2.sh; }   # pm v2 (a): the kit-owned refresh; ROLL-24d.sh refresh (:150-157) is never called
dh_S0() { rtool 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; bash -s -- start' LOGWATCH-24d.sh; }
dh_I0s() { rtool "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; EXP_START_REV=$EXP_START_REV bash -s" START-CHECK-IMG.sh; }
dh_I1() { rtool "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; R=24d bash -s -- helmrev app" ROLL-24d.sh; }
dh_I1r() { rtool "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; R=24d bash -s -- restarts" ROLL-24d.sh; }
dh_I1g() { rtool "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; R=24d bash -s -- groupdigests" ROLL-24d.sh; }   # v3h: the per-group worker digest map at pre
dh_podsnap_save() { rsh "set -o noclobber; export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; kubectl -n dev-health get pods -l app.kubernetes.io/instance=dev-health --field-selector=status.phase!=Succeeded,status.phase!=Failed --no-headers -o 'custom-columns=POD:.metadata.name,UID:.metadata.uid,RESTARTS:.status.containerStatuses[*].restartCount,OWNERKIND:.metadata.ownerReferences[0].kind,OWNER:.metadata.ownerReferences[0].name' > \$HOME/lane-prod-k8s/podsnap-i$STEP-$RUN_TAG-$1.txt && cat \$HOME/lane-prod-k8s/podsnap-i$STEP-$RUN_TAG-$1.txt"; }
dh_podsnap_read() { rsh "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; kubectl -n dev-health get pods -l app.kubernetes.io/instance=dev-health --field-selector=status.phase!=Succeeded,status.phase!=Failed --no-headers -o 'custom-columns=POD:.metadata.name,UID:.metadata.uid,RESTARTS:.status.containerStatuses[*].restartCount,OWNERKIND:.metadata.ownerReferences[0].kind,OWNER:.metadata.ownerReferences[0].name'"; }
dh_podsnap_cmp() { xrun bash "$KIT/PODSNAP-CMP-r7.sh" "$WORK/pre/PODSNAP-before.out" "$1" "$PODSNAP_TARGETS" "$PODSNAP_SCALERS"; }
dh_I2c() { rtool 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; bash -s -- collect' HEADROOM-24d.sh; }
dh_I2h() { xrun "IMG_DEPLOYS=$IMG_DEPLOYS" bash "$KIT/HEADROOM-24d.sh" compute "$OUTD/I2-collect.out" "$OUTD/render.yaml" img; }
dh_topsnap() { rtool 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; bash -s -- topsnap' HEADROOM-24d.sh; }
dh_topcmp() { xrun bash "$KIT/HEADROOM-24d.sh" topcmp "$WORK/pre/I3t.out" "$OUTD/$1.out" "$PODSNAP_TARGETS" "$2"; }   # v3j: <after snapshot step> first|final; only the HPAs of PODSNAP_TARGETS are gated
dh_I3g() { rtool "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; R=24d HOOK=A DEFER_STEPS=$DEFER_STEPS GUARD_LIVE_STEP=$GUARD_LIVE_STEP bash -s -- guards $SVC_SHA i$STEP" ROLL-24d.sh; }
dh_I3p() { rtool2 "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml LC_ALL=C; set -o pipefail; $GFAIL$(docs_snippet)RP_IMGROWS='$IMGROWS' RP_CMDELTA='' RP_CMROLL='' RP_ADDDOCS='$ADDDOCS' bash -s -- deploy-rollback-24d deploy-roll-24d i$STEP -f \$HOME/lane-prod-k8s/roll-24d-values.yaml" full-render-diff.py RENDER-PATHS-24d.sh; }   # ONE ssh: the names gate, then RENDER-PATHS
dh_I3d() { rtool2 "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml LC_ALL=C; set -o pipefail; $(gate_snippet)$(newest_snippet "$LIVEREV")$(secret_snippet)$(docs_snippet)echo 'GATE-REMOTE: PASS'; R=24d HOOK=A DEFER_STEPS=$DEFER_STEPS GUARD_LIVE_STEP=$GUARD_LIVE_STEP bash -s -- deploy i$STEP $SVC_SHA" full-render-diff.py ROLL-24d.sh; }   # ONE ssh: the gates, the live newest rev, then the deploy verb
dh_I4() { rtool "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; R=24d bash -s -- wait i$STEP" ROLL-24d.sh; }
dh_I5() { rtool "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; R=24d bash -s -- appcheck" ROLL-24d.sh; }
dh_I6() { rtool "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; R=24d IMG_MODE=$IMG_MODE IMG_DEPLOYS=$IMG_DEPLOYS IMG_OLD=$IMG_OLD IMG_NEW=$IMG_NEW RESTARTS0=$RESTARTS0 GROUPDIG='$GROUPDIG' CMROLL='' bash -s -- stagecheck i$STEP $LIVEREV" ROLL-24d.sh; }
dh_I6m() { rtool 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; bash -s -- migjoblog read' READBACK-IMG.sh; }
dh_I6p() { rtool "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; bash -s -- pgver $PG_EXPECT" READBACK-IMG.sh; }
dh_I6l() { if ! grep -qE '(^|;)(Deployment|StatefulSet)/' <<< "$LIVEROWS"; then echo "LIVEROWS: n/a (0 workload rows)"; return 0; fi; rtool "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; IMGROWS='$LIVEROWS' CMDELTA='' bash -s -- liverows" READBACK-IMG.sh; }
dh_I6s1() { rtool 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; bash -s -- scrape' POSTROLL-24d.sh; }
dh_scrapecheck() { xrun bash "$KIT/POSTROLL-24d.sh" scrapecheck "$WORK/post/I6s-1.out" "${V[SERIES_FILE]}"; }
dh_newest() { rsh 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; helm history dev-health -n dev-health --max 1'; }
dh_hist() { rsh 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; helm history dev-health -n dev-health --max 100'; }
dh_X1() { rtool "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; R=24d LIVEREV=$LIVEREV LIVEREV2= bash -s -- helm-rollback app" ROLL-24d.sh; }
dh_X2() { rtool 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; R=24d bash -s -- wait helm-rollback' ROLL-24d.sh; }
dh_I9() { rtool "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; R=24d LIVEREV=$LIVEREV LIVEREV2= DEFER_STEPS=$DEFER_STEPS GUARD_LIVE_STEP=$GUARD_LIVE_STEP IMG_DEPLOYS=$IMG_DEPLOYS ROLLBACK_IMG_PREFIX=$ROLLBACK_IMG_PREFIX CMDELTA='' bash -s -- rollcheck i$STEP" ROLL-24d.sh; }
g_rbx() { [ "$ROLLBACK_REV" = "$LIVEREV" ] || { echo "GATE ROLLBACK_REV: inputs ROLLBACK_REV $ROLLBACK_REV != the LIVEREV $LIVEREV read live"; return 1; }; echo "GATE ROLLBACK_REV: PASS (ROLLBACK_REV = the LIVEREV $LIVEREV read live by this pre)"; }
g_HAS() { awk -v r="$LIVEREV" '$1==r {k=1} END {exit !k}' "$OUTD/HISTORY.out" || { echo "GATE HISTORY: rollback rev $LIVEREV is not in the helm history"; return 1; }; echo "GATE HISTORY: PASS (rev $LIVEREV is in the helm history: $(awk -v r="$LIVEREV" '$1==r {print $1, $7}' "$OUTD/HISTORY.out"))"; }

dh_waitloop() {
  local i
  for i in 1 2 3 4 5 6 7 8 9 10 11; do
    step_rc "I4-$i" "0 3" '^(deploy_rc=0|STILL-RUNNING .+)$' dh_I4
    if [ "$SRC" = 0 ]; then mark "$WORK/deploy.pass"; echo "PHASE deploy: PASS (I4 rc=0 = deploy_rc=0); next: roll dev-health <inputs> post"; return 0; fi
    step_rc "I5-$i" "0 3" '^APPCHECK (PASS|WAIT)' dh_I5
  done
  echo "PRODROLL HOLD (exit 3): I4 still running after 11 bounded waits; run: prodroll.sh roll dev-health <inputs> wait"; exit 3
}
roll_dh() {
  case "$PH" in
  pre)
    begin_pre
    step I0 '^I0 STEP=' dh_I0; step RENDER '^RENDER_FILE ' dh_render
    step GATES "$F_REMOTE" gates
    step V2r-kit '^KITREFRESH: PASS' dh_V2r; step S0 '^loop pid [0-9]+ marker ' dh_S0; step I0s '^START-CHECK: PASS' dh_I0s
    step I1 '^STATE LIVEREV=[0-9]+$' dh_I1; state_from "$OUTD/I1.out" LIVEREV; LIVEREV=$(st_get LIVEREV)
    step ROLLBACK_REV-gate "$F_GATE" g_rbx
    step I1r '^STATE RESTARTS0=[0-9]+$' dh_I1r; state_from "$OUTD/I1r.out" RESTARTMAP RESTARTS0
    step I1g '^STATE GROUPDIG=[a-z0-9:,+-]+$' dh_I1g; state_from "$OUTD/I1g.out" GROUPDIG
    step PODSNAP-before "$F_POD" dh_podsnap_save before
    step I2-collect '^@@COLLECT OK ' dh_I2c; step I2-compute '^IMG-STEP (WITHIN|OVER)' dh_I2h; step I3t '^hpa ' dh_topsnap
    step I3g '^HOOKGUARD PASS' dh_I3g; step I3p '^RENDER PATHS: PASS$' dh_I3p
    if [ -n "$KEEP_LIST$KEYS_LIST" ]; then step SECRETS '^SECRETS: PASS$' secrets; fi
    state_put PREEND "$(date -u +%s)"; mark "$WORK/pre.pass"; echo "PHASE pre: PASS; next: roll dev-health <inputs> deploy within $PRE_MAX_AGE s (after the lead's word)" ;;
  deploy)
    [ -e "$WORK/pre.pass" ] || refuse "no pre.pass in $WORK: run the pre phase first"; inputs_same
    [ ! -e "$WORK/deploy.started" ] || refuse "$WORK/deploy.started exists: the deploy runs once per RUN_TAG (use the wait phase)"
    pre_fresh; LIVEREV=$(st_get LIVEREV) || refuse "state LIVEREV missing in $WORK/state.txt"
    [ "$LIVEREV" = "$ROLLBACK_REV" ] || refuse "state LIVEREV $LIVEREV != inputs ROLLBACK_REV $ROLLBACK_REV"
    newout deploy; mark "$WORK/deploy.started"
    step I3d '^pid [0-9]+ log ' dh_I3d; dh_waitloop ;;
  wait)
    [ -e "$WORK/deploy.started" ] || refuse "no deploy.started in $WORK"; [ ! -e "$WORK/deploy.pass" ] || refuse "deploy.pass exists: run the post phase"; inputs_same
    newout "wait-$(date -u +%H%M%S)"; dh_waitloop ;;
  post)
    [ -e "$WORK/deploy.pass" ] || refuse "no deploy.pass in $WORK"; [ ! -e "$WORK/post.pass" ] || refuse "post.pass exists in $WORK"; inputs_same
    LIVEREV=$(st_get LIVEREV) || refuse "state LIVEREV missing in $WORK/state.txt"; RESTARTS0=$(st_get RESTARTS0) || refuse "state RESTARTS0 missing in $WORK/state.txt"; GROUPDIG=$(st_getmap) || refuse "state GROUPDIG missing in $WORK/state.txt (v3h: run a v3h pre)"
    newout post
    step I6 '^STAGECHECK: PASS$' dh_I6
    if [ "${V[MIGJOBLOG]}" = yes ]; then step I6m '^MIGJOBLOG clickhouse action=' dh_I6m; fi
    step I6p '^PGVER: PASS$' dh_I6p; step I6l '^LIVEROWS: (PASS|n/a)' dh_I6l
    if [ -n "$KEEP_LIST$KEYS_LIST" ]; then step SECRETS-post '^SECRETS: PASS$' secrets; [ -z "$KEEP_LIST" ] || step SECRETS-SAME "$F_GATE" g_secsame; fi
    if [ "${V[SCRAPE]}" = yes ]; then step I6s-1 '^SCRAPE PASS' dh_I6s1; fi
    step PODSNAP-after "$F_POD" dh_podsnap_save after; step PODSNAP-cmp '^PODSNAP: PASS$' dh_podsnap_cmp "$OUTD/PODSNAP-after.out"
    # v3j (pm ruling, s30-a/s36-a false STOPs): rolled HPAs only + 2 samples: a move on sample 1 = RECHECK (rc 3); wait 60 s, sample 2 decides (a move = FAIL)
    step I7-topsnap '^hpa ' dh_topsnap; step_rc I7-topcmp "0 3" '^TOPCMP: (PASS|RECHECK)' dh_topcmp I7-topsnap first
    if [ "$SRC" = 3 ]; then echo "I7: a rolled HPA moved on sample 1; sample 2 in 60 s"; xrun sleep 60; step I7-topsnap2 '^hpa ' dh_topsnap; step I7-topcmp2 '^TOPCMP: PASS' dh_topcmp I7-topsnap2 final; fi
    mark "$WORK/post.pass"
    echo "PHASE post: PASS. Lead steps outside the kit: I6s-2 (SigNoz series -> SERIES_FILE), then readback scrapecheck; I6e (SigNoz 5xx window)." ;;
  esac
}

# ==== roll ingress-nginx: the ROLL-INPUTS-11699-v1 form; tree, chart, values path and rows shape are constants ====
ing_P0() { rsh 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; cd '"$DEPLOY_TREE"' && echo "HEAD $(git rev-parse HEAD) dirty=$(git status --porcelain --untracked-files=no | wc -l) values_blob=$(git rev-parse HEAD:'"$ING_VALUES"') disk=$(git hash-object '"$ING_VALUES"')"; sha256sum '"$ING_TGZ"; }
ing_P1() { rsh 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; helm -n ingress-nginx history ingress-nginx --max 3; l=$(mktemp) && b=$(mktemp) || exit 1; helm -n ingress-nginx get values ingress-nginx -o yaml > "$l"; cd '"$DEPLOY_TREE"' && git show '"$BASE_SHA"':'"$ING_VALUES"' > "$b" && python3 -I -c "import sys,yaml; a=yaml.safe_load(open(sys.argv[1])); b=yaml.safe_load(open(sys.argv[2])); print(\"P1 live values == base '"$BASE_SHA"':\", a==b)" "$l" "$b"; rm -f "$l" "$b"; ip -4 -o addr show cni0 | awk "{print \$2, \$3, \$4}"'; }
ing_P2() { rsh 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; for k in use-forwarded-headers proxy-real-ip-cidr compute-full-forwarded-for; do echo "'"$1"' $k=[$(kubectl -n ingress-nginx get cm ingress-nginx-controller -o jsonpath="{.data.$k}")]"; done'; }
ing_P3() { rsh 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; kubectl -n ingress-nginx get cm ingress-nginx-controller --show-managed-fields -o jsonpath="{range .metadata.managedFields[*]}{.manager}{\" \"}{.operation}{\" keys=\"}{.fieldsV1.f:data}{\"\n\"}{end}"'; }
ing_P4() { rsh 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; kubectl -n ingress-nginx get pods -l app.kubernetes.io/component=controller -o jsonpath="{range .items[*]}{.metadata.name}{\" restarts=\"}{.status.containerStatuses[0].restartCount}{\" ready=\"}{.status.containerStatuses[0].ready}{\"\n\"}{end}"; kubectl -n ingress-nginx logs deploy/ingress-nginx-controller --since=10m 2>/dev/null | awk "/^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+ /{n++; c[\$1]++} END{print \"P4 access lines\", n+0; for (a in c) print \"P4 remote_addr\", a, c[a]}" | sort -k4 -nr | head -12'; }
ing_PF() { # one ssh: the dry run to a 0600 mktemp file (shred -u at the end, pm rule); only its header lines reach stdout/disk; the manifest goes through filter first
  local out rc
  out=$(rsh 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; o=$(mktemp) && e=$(mktemp) || exit 1; cd '"$DEPLOY_TREE"' && helm -n ingress-nginx upgrade ingress-nginx '"$ING_TGZ"' --version '"$ING_CHART_VERSION"' -f '"$ING_VALUES"' --dry-run=server --hide-secret > "$o" 2> "$e"; echo "preflight rc=$?"; echo "stderr: $(grep -v setlocale "$e" | head -5)"; echo "conflict lines: $(grep -ci conflict "$o")"; echo "@@MANIFEST"; sed -n "/^MANIFEST:/,\$p" "$o" | sed 1d | sed "/^NOTES:/,\$d"; shred -u "$o" "$e"'); rc=$?
  [ "$rc" = 0 ] || { echo "preflight ssh rc=$rc"; return 1; }
  printf '%s\n' "$out" | sed '/^@@MANIFEST$/,$d'
  printf '%s\n' "$out" | sed '1,/^@@MANIFEST$/d' | xrun python3 -I "$KIT/full-render-diff.py" filter > "$OUTD/dry.f.yaml" || { echo "filter of the dry-run manifest rc != 0"; return 1; }
  echo "dry-run manifest: filtered in memory (Secret docs dropped) -> dry.f.yaml, docs $(grep -c '^kind:' "$OUTD/dry.f.yaml")"
}
ing_live() {
  rsh 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; helm -n ingress-nginx get manifest ingress-nginx' | xrun python3 -I "$KIT/full-render-diff.py" filter > "$OUTD/live.f.yaml"
  local a=("${PIPESTATUS[@]}"); [ "${a[0]}" = 0 ] && [ "${a[1]}" = 0 ] || { echo "live manifest read/filter rc ${a[*]}"; return 1; }
  echo "live manifest: piped through full-render-diff filter (Secret docs dropped) -> live.f.yaml, docs $(grep -c '^kind:' "$OUTD/live.f.yaml")"
}
ing_rows() { # the expect-rows file of the 11699 form, built from the 3 attested EXPECT values (fixed shape; = rows-11699.json for the 11699 values)
  printf '{"added": [], "removed": [], "rows": [\n {"doc": "ConfigMap/ingress-nginx-controller", "path": ".data.compute-full-forwarded-for", "verb": "CHANGED", "after": "%s", "show": true},\n {"doc": "ConfigMap/ingress-nginx-controller", "path": ".data.proxy-real-ip-cidr", "verb": "CHANGED", "after": "%s", "show": true},\n {"doc": "ConfigMap/ingress-nginx-controller", "path": ".data.use-forwarded-headers", "verb": "CHANGED", "after": "%s", "show": true}\n]}\n' \
    "${V[EXPECT_COMPUTE_FULL_FORWARDED_FOR]}" "${V[EXPECT_PROXY_REAL_IP_CIDR]}" "${V[EXPECT_USE_FORWARDED_HEADERS]}" > "$OUTD/rows.json"
  echo "rows.json sha256 $(sha_of "$OUTD/rows.json") (3 ConfigMap rows from the inputs EXPECT values)"; }
ing_diff() { xrun python3 -I "$KIT/full-render-diff.py" "$OUTD/live.f.yaml" "$OUTD/dry.f.yaml" --live --rc-a 0 --rc-b 0 --min-docs "${V[MIN_DOCS]}" --expect-rows "$OUTD/rows.json"; }
ing_UP() { rsh "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; $(gate_snippet)$(p0_snippet)$(newest_snippet "$LIVEREV")echo 'GATE-REMOTE: PASS'; cd $DEPLOY_TREE || exit 3; o=\$(helm -n ingress-nginx upgrade ingress-nginx $ING_TGZ --version $ING_CHART_VERSION -f $ING_VALUES --wait --timeout 5m 2>&1); r=\$?; printf '%s\\n' \"\$o\" | grep -v setlocale | head -12; echo \"upgrade rc=\$r\""; }   # ONE ssh: gates, P0u, the live newest rev, then the upgrade
ing_R() { rsh 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; helm -n ingress-nginx history ingress-nginx --max 2; kubectl -n ingress-nginx get cm ingress-nginx-controller --show-managed-fields -o jsonpath="{range .metadata.managedFields[*]}{.manager}{\" \"}{.operation}{\" keys=\"}{.fieldsV1.f:data}{\"\n\"}{end}"; for k in use-forwarded-headers proxy-real-ip-cidr compute-full-forwarded-for; do echo "R2 $k=[$(kubectl -n ingress-nginx get cm ingress-nginx-controller -o jsonpath="{.data.$k}")]"; done; kubectl -n ingress-nginx get pods -l app.kubernetes.io/component=controller -o jsonpath="{range .items[*]}{.metadata.name}{\" restarts=\"}{.status.containerStatuses[0].restartCount}{\" ready=\"}{.status.containerStatuses[0].ready}{\"\n\"}{end}"; kubectl -n ingress-nginx logs deploy/ingress-nginx-controller --since=3m 2>/dev/null | grep -ciE "reload.*(error|fail)|error reloading" | sed "s/^/R3 reload-error lines: /"; kubectl -n ingress-nginx logs deploy/ingress-nginx-controller --since=3m 2>/dev/null | grep -ciE "Backend successfully reloaded|configuration changes detected" | sed "s/^/R3 reload lines: /"'; }
ing_newest() { rsh 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; helm -n ingress-nginx history ingress-nginx --max 1'; }
ing_hist() { rsh 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; helm -n ingress-nginx history ingress-nginx --max 100'; }
ing_RB() { rsh 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; o=$(helm -n ingress-nginx rollback ingress-nginx '"$LIVEREV"' --wait --timeout 5m 2>&1); r=$?; printf "%s\n" "$o" | grep -v setlocale | head -12; echo "rollback rc=$r"'; }

g_P0() { local f=$OUTD/$1.out
  grep -qxF "HEAD $TREE_SHA dirty=0 values_blob=$VALUES_BLOB disk=$VALUES_BLOB" "$f" || { echo "GATE P0: tree HEAD/dirty/values blob != inputs"; return 1; }
  grep -qxF "$ING_TGZ_SHA256  $ING_TGZ" "$f" || { echo "GATE P0: chart tgz sha256 != the pinned $ING_TGZ_SHA256"; return 1; }
  echo "GATE P0: PASS (tree ${TREE_SHA:0:12} clean, values blob ${VALUES_BLOB:0:12}, tgz pinned ${ING_TGZ_SHA256:0:12})"; }
g_P1() { local f=$OUTD/P1.out nw
  nw=$(helm_newest "$f"); [ "$nw" = "$EXP_START_REV deployed" ] || { echo "GATE P1: newest history row '$nw', want '$EXP_START_REV deployed'"; return 1; }
  awk -v r="$EXP_START_REV" -v c="ingress-nginx-$ING_CHART_VERSION" '$1==r && $8==c {k=1} END {exit !k}' "$f" || { echo "GATE P1: rev $EXP_START_REV chart is not ingress-nginx-$ING_CHART_VERSION"; return 1; }
  grep -qxF "P1 live values == base $BASE_SHA: True" "$f" || { echo "GATE P1: live values != base $BASE_SHA"; return 1; }
  grep -qxF "cni0 inet $CNI_ADDR" "$f" || { echo "GATE P1: cni0 address != $CNI_ADDR"; return 1; }
  echo "GATE P1: PASS (rev $EXP_START_REV deployed, live values == base, cni0 $CNI_ADDR)"; }
g_P2() { local f=$OUTD/$1.out p=$2
  [ "$(grep -vc '^$' "$f")" = 3 ] && grep -qxF "$p use-forwarded-headers=[${V[EXPECT_USE_FORWARDED_HEADERS]}]" "$f" && grep -qxF "$p proxy-real-ip-cidr=[${V[EXPECT_PROXY_REAL_IP_CIDR]}]" "$f" && grep -qxF "$p compute-full-forwarded-for=[${V[EXPECT_COMPUTE_FULL_FORWARDED_FOR]}]" "$f" || { echo "GATE $p: a value != the inputs"; return 1; }
  echo "GATE $p: PASS (3 values == inputs)"; }
g_P3() { local f=$OUTD/P3.out
  [ "$(grep -vc '^$' "$f")" = 2 ] && grep -qxF "helm Apply keys=$P3_HELM_JSON" "$f" && grep -qxF "kubectl-patch Update keys=$P3_PATCH_JSON" "$f" || { echo "GATE P3: owners != helm Apply $P3_HELM_JSON + kubectl-patch Update $P3_PATCH_JSON"; return 1; }
  echo "GATE P3: PASS (owners as the inputs)"; }
g_P4() { local f=$OUTD/P4.out
  [ "$(grep -cE '^[a-z0-9-]+ restarts=[0-9]+ ready=true$' "$f")" -ge 1 ] && ! grep -qE '^[a-z0-9-]+ restarts=[0-9]+ ready=false$' "$f" || { echo "GATE P4: no Ready controller pod"; return 1; }
  grep -qE '^P4 access lines [0-9]+$' "$f" || { echo "GATE P4: no access line count"; return 1; }
  echo "GATE P4: PASS (baseline saved: $f)"; }
g_PF() { local f=$OUTD/PREFLIGHT.out
  grep -qxF "preflight rc=0" "$f" && grep -qxE "stderr: ?" "$f" && grep -qxF "conflict lines: 0" "$f" || { echo "GATE PREFLIGHT: rc != 0, stderr not empty, or a conflict line"; return 1; }
  echo "GATE PREFLIGHT: PASS (rc 0, empty stderr, 0 conflict lines)"; }
g_NEW() { local nw want; nw=$(helm_newest "$OUTD/$1.out"); case "$2" in any) want="$3 (any status)"; [ "${nw%% *}" = "$3" ];; *) want="$3 $2"; [ "$nw" = "$want" ];; esac || { echo "GATE $1: newest helm revision '$nw', want '$want'"; return 1; }; echo "GATE $1: PASS (newest revision $nw)"; }
g_R() { local f=$OUTD/$1.out p4=$WORK/pre/P4.out nw pod
  nw=$(helm_newest "$f"); [ "$nw" = "$EXPECT_NEWEST_REV deployed" ] || { echo "GATE R1: newest '$nw', want '$EXPECT_NEWEST_REV deployed'"; return 1; }
  grep -qxF "helm Apply keys=$R1_HELM_JSON" "$f" || { echo "GATE R1: helm Apply keys != $R1_HELM_JSON"; return 1; }
  grep -qxF "R2 use-forwarded-headers=[${V[EXPECT_USE_FORWARDED_HEADERS]}]" "$f" && grep -qxF "R2 proxy-real-ip-cidr=[${V[EXPECT_PROXY_REAL_IP_CIDR]}]" "$f" && grep -qxF "R2 compute-full-forwarded-for=[${V[EXPECT_COMPUTE_FULL_FORWARDED_FOR]}]" "$f" || { echo "GATE R2: a value changed"; return 1; }
  pod=$(grep -E '^[a-z0-9-]+ restarts=[0-9]+ ready=(true|false)$' "$p4"); [ -n "$pod" ] && [ "$(grep -E '^[a-z0-9-]+ restarts=[0-9]+ ready=(true|false)$' "$f")" = "$pod" ] && [ "${pod##* }" = ready=true ] || { echo "GATE R3: controller pod/restarts/ready differ from P4 ($pod)"; return 1; }
  grep -qxF "R3 reload-error lines: 0" "$f" || { echo "GATE R3: reload error lines"; return 1; }
  echo "GATE R1-R3: PASS (rev $EXPECT_NEWEST_REV deployed; helm owns the keys; values unchanged; same pod, restarts unchanged, Ready; 0 reload errors)"; }
g_R4() { awk -v ip="${CNI_ADDR%/*}" 'FNR==1 {fi++} $1=="P4" && $2=="access" {n[fi]=$4+0} $1=="P4" && $2=="remote_addr" {c[fi, $3]=$4+0; if ($4+0 > top[fi]) {top[fi]=$4+0; ta[fi]=$3}}
    END { printf "R4 access lines now %d (P4 %d); top remote_addr now %s; %s share now %d/%d (P4 %d/%d)\n", n[2], n[1], (ta[2]==""?"-":ta[2]), ip, c[2,ip], n[2], c[1,ip], n[1]
      if (ta[2] != ip || c[2,ip] * n[1] <= c[1,ip] * n[2]) { print "R4: PASS (" (ta[2] != ip ? "the CNI address is not the top remote_addr" : "no regression vs P4: the CNI share is not higher") ")"; exit 0 }
      print "R4: regression: the CNI address is the top remote_addr and its share rose"; exit 1 }' "$WORK/pre/P4.out" "$OUTD/R4.out"; }
g_ingrev() { state_put LIVEREV "$(helm_newest "$OUTD/P1.out" | cut -d' ' -f1)" && LIVEREV=$(st_get LIVEREV) && { [ "$ROLLBACK_REV" = "$LIVEREV" ] || { echo "GATE ROLLBACK_REV: inputs ROLLBACK_REV $ROLLBACK_REV != the P1 rev $LIVEREV read live"; return 1; }; } && echo "GATE ROLLBACK_REV: PASS (ROLLBACK_REV = the P1 rev $LIVEREV, read live)"; }

roll_ing() {
  case "$PH" in
  pre)
    begin_pre
    step GATES "$F_REMOTE" gates
    step P0 '^[0-9a-f]{64}  /home/ubuntu/lane-prod-k8s/11647/chart/ingress-nginx-4\.14\.5\.tgz$' ing_P0; step P0-gate "$F_GATE" g_P0 P0
    step P1 '^cni0 inet ' ing_P1; step P1-gate "$F_GATE" g_P1
    g_ingrev || stop "ROLLBACK_REV cross-check"
    step P2 '^P2 compute-full-forwarded-for=\[' ing_P2 P2; step P2-gate "$F_GATE" g_P2 P2 P2
    step P3 '^(helm|kubectl-patch) (Apply|Update) keys=' ing_P3; step P3-gate "$F_GATE" g_P3
    step P4 '^(P4 |[a-z0-9-]+ restarts=)' ing_P4; step P4-gate "$F_GATE" g_P4
    step PREFLIGHT '^dry-run manifest: filtered' ing_PF; step PREFLIGHT-gate "$F_GATE" g_PF; step LIVE-MANIFEST '^live manifest: piped' ing_live; step ROWS '^rows\.json sha256 ' ing_rows; step PREFLIGHT-diff '^GATE rows\.json: PASS$' ing_diff
    state_put PREEND "$(date -u +%s)"; mark "$WORK/pre.pass"; echo "PHASE pre: PASS; next: roll ingress-nginx <inputs> upgrade within $PRE_MAX_AGE s (on the lead's word)" ;;
  upgrade)
    [ -e "$WORK/pre.pass" ] || refuse "no pre.pass in $WORK: run the pre phase first"; inputs_same
    [ ! -e "$WORK/upgrade.started" ] || refuse "$WORK/upgrade.started exists: the upgrade runs once per RUN_TAG"
    pre_fresh; LIVEREV=$(st_get LIVEREV) || refuse "state LIVEREV missing in $WORK/state.txt"
    [ "$LIVEREV" = "$ROLLBACK_REV" ] || refuse "state LIVEREV $LIVEREV != inputs ROLLBACK_REV $ROLLBACK_REV"
    newout upgrade; mark "$WORK/upgrade.started"; echo "== WINDOW OPEN (upgrade start) $(date -u +%FT%TZ); rollback target = ROLLBACK_REV $ROLLBACK_REV (= the LIVEREV read live by pre)"
    step UPGRADE '^upgrade rc=0$' ing_UP
    mark "$WORK/upgrade.pass"; echo "PHASE upgrade: PASS; next: roll ingress-nginx <inputs> post" ;;
  post)
    [ -e "$WORK/upgrade.pass" ] || refuse "no upgrade.pass in $WORK"; [ ! -e "$WORK/post.pass" ] || refuse "post.pass exists in $WORK"; inputs_same
    newout post
    step R1-R3 '^R3 reload lines: [0-9]+$' ing_R; step R-gate "$F_GATE" g_R R1-R3
    mark "$WORK/post.pass"; echo "PHASE post: PASS; R4 = prodroll.sh readback ingress-nginx <inputs>, >= 5 min after the upgrade (organic traffic only, D6310)" ;;
  esac
}

# ==== secret-pipe f1pipe: gate M + A-step (fixed code) then the attested f1pipe-11709.sh body, unchanged, in acp's run-line form ====
f1_M() { rsh 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; f=/home/ubuntu/.config/dev-health/pg-owner-rotation.marker; if [ -e "$f" ] || [ -L "$f" ]; then echo "PRESENT $f"; else echo "ABSENT $f"; fi'; }
g_M() { [ "$(cat -- "$OUTD/GATE-M.out")" = "ABSENT /home/ubuntu/.config/dev-health/pg-owner-rotation.marker" ] || { echo "GATE M: the rotation marker is not ABSENT"; return 1; }; echo "GATE M: PASS (marker ABSENT)"; }
f1_A() { rsh 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; cd '"$F1_TREE"' && git rev-parse HEAD HEAD:scripts/load-secrets.sh HEAD:scripts/lib/secret-write.sh HEAD:scripts/lib/pg-exec-sql.sh HEAD:values.prod.yaml HEAD:vendor/dev-health-ops && git hash-object scripts/load-secrets.sh scripts/lib/secret-write.sh scripts/lib/pg-exec-sql.sh values.prod.yaml && git -C vendor/dev-health-ops rev-parse HEAD HEAD:deploy/helm/dev-health/values.yaml && git -C vendor/dev-health-ops hash-object deploy/helm/dev-health/values.yaml && git status --porcelain --untracked-files=no | wc -l'; }
g_A() { printf '%s\n' "${ASTEP_LINE[@]}" | diff - "$OUTD/A-STEP.out" > /dev/null || { echo "GATE A-STEP: the 14 lines differ from ASTEP_LINE"; return 1; }; echo "GATE A-STEP: PASS (14 lines exact)"; }
f1_run() {
  local rlog
  echo "f1pipe-11709.sh sha256 $(sha_of "$KIT/f1pipe-11709.sh") (acp run-line form; the SUMS-checked kit file is fed unchanged on stdin)"
  rlog=$(rtool 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; umask 077; set -o noclobber; L=/home/ubuntu/lane-prod-k8s/11709-logs/F1PIPE-$(date -u +%H%M%S)Z.log; env -i PATH=/usr/local/bin:/usr/bin:/bin HOME=/home/ubuntu LANG=C.UTF-8 KUBECONFIG=/etc/rancher/k3s/k3s.yaml bash --norc --noprofile -s > "$L" 2>&1; echo rc=$? >> "$L"; echo "$L"' f1pipe-11709.sh 2>/dev/null) || { echo "F1PIPE ssh rc=$?"; return 1; }
  [[ $rlog =~ ^/home/ubuntu/lane-prod-k8s/11709-logs/F1PIPE-[0-9]{6}Z\.log$ ]] || { echo "F1PIPE: the remote log path is not the fixed form"; return 1; }
  echo "remote log: $rlog"
  rsh "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; cat -- '$rlog'" 2>/dev/null
}
g_F1() { local f=$OUTD/F1PIPE.out
  [ "$(tail -1 "$f")" = rc=0 ] && grep -qE '^F1PIPE: PASS' "$f" || { echo "GATE F1PIPE: no 'F1PIPE: PASS' line or the remote rc is not 0"; return 1; }
  echo "GATE F1PIPE: PASS"; }
secret_f1() {
  [ ! -e "$WORK/f1pipe.started" ] || refuse "$WORK/f1pipe.started exists: a forward rerun needs a new RUN_TAG (new log name, pm Q2)"
  newout "secret-pipe-$(date -u +%H%M%S)"
  step GATE-M '^(ABSENT|PRESENT) /home/ubuntu/\.config/dev-health/pg-owner-rotation\.marker$' f1_M; step GATE-M-gate "$F_GATE" g_M
  step A-STEP '^[0-9]+$' f1_A; step A-STEP-gate "$F_GATE" g_A
  mark "$WORK/f1pipe.started"
  step F1PIPE '^rc=0$' f1_run; step F1PIPE-gate "$F_GATE" g_F1
  mark "$WORK/f1pipe.pass"; echo "SECRET-PIPE f1pipe: PASS; next (lead, outside the kit): F12, R0 (PREP-11709-rev424.md s4)"
}

# ==== readback (read-only) and rollback (bound to a RUN_TAG's state) ====
readback() {
  case "$ARG" in
  dev-health-post) newout "readback-dev-health-post-$(date -u +%H%M%S)"; step I1-read '^STATE LIVEREV=[0-9]+$' dh_I1; step I6p '^PGVER: PASS$' dh_I6p; step I6l '^LIVEROWS: (PASS|n/a)' dh_I6l ;;
  scrapecheck)
    [ -n "${V[SERIES_FILE]+x}" ] || refuse "inputs: readback scrapecheck needs SERIES_FILE"; lpath_ok "${V[SERIES_FILE]}" || refuse "inputs: SERIES_FILE is not a regular, non-link file under the fixed roots"
    [ -s "$WORK/post/I6s-1.out" ] || refuse "no $WORK/post/I6s-1.out (the post phase I6s-1 scrape)"
    newout "readback-scrapecheck-$(date -u +%H%M%S)"; echo "SERIES_FILE sha256 $(sha_of "${V[SERIES_FILE]}")"; step I6s-3 '^SCRAPECHECK PASS$' dh_scrapecheck ;;
  podsnap)
    [ -s "$WORK/pre/PODSNAP-before.out" ] || refuse "no $WORK/pre/PODSNAP-before.out"
    newout "readback-podsnap-$(date -u +%H%M%S)"; step PODSNAP-now "$F_POD" dh_podsnap_read; step PODSNAP-cmp '^PODSNAP: PASS$' dh_podsnap_cmp "$OUTD/PODSNAP-now.out" ;;
  ingress-nginx)
    [ -e "$WORK/pre.pass" ] || refuse "no pre.pass in $WORK (R4 compares with P4)"
    newout "readback-ingress-nginx-$(date -u +%H%M%S)"; step R1-R3 '^R3 reload lines: [0-9]+$' ing_R; step R-gate "$F_GATE" g_R R1-R3; step R4 '^(P4 |[a-z0-9-]+ restarts=)' ing_P4; step R4-gate '^R4: PASS' g_R4 ;;
  esac
  echo "READBACK $ARG: PASS"
}
rollback() {
  local started=deploy.started rec; [ "$ARG" = ingress-nginx ] && started=upgrade.started
  [ -d "$WORK" ] || refuse "rollback: no run state for RUN_TAG $RB_TAG ($WORK)"
  [ -e "$WORK/pre.pass" ] && [ -e "$WORK/$started" ] || refuse "rollback: RUN_TAG $RB_TAG has no pre.pass + $started"
  inputs_same
  LIVEREV=$(st_get LIVEREV) || refuse "rollback: state LIVEREV missing in $WORK/state.txt"
  if [ "$ARG" = dev-health ]; then rec=$(sed -n 's/^STATE LIVEREV=//p' "$WORK/pre/I1.out" 2>/dev/null | tail -1); else rec=$(helm_newest "$WORK/pre/P1.out" 2>/dev/null | cut -d' ' -f1); fi
  [ -n "$rec" ] && [ "$rec" = "$LIVEREV" ] || refuse "rollback: the target recorded in this RUN_TAG's pre log (${rec:-none}) != state LIVEREV $LIVEREV"
  [ "$ROLLBACK_REV" = "$LIVEREV" ] || refuse "rollback: inputs ROLLBACK_REV $ROLLBACK_REV != the LIVEREV $LIVEREV that pre read live"
  [ "$EXPECT_NEWEST_REV" -gt "$LIVEREV" ] || refuse "rollback: EXPECT_NEWEST_REV $EXPECT_NEWEST_REV is not above LIVEREV $LIVEREV"
  echo "ROLLBACK target = ROLLBACK_REV $ROLLBACK_REV = the LIVEREV read live by the pre phase of RUN_TAG $RB_TAG (state + its pre log)"
  newout "rollback-$(date -u +%H%M%S)"
  case "$ARG" in
  dev-health)
    step NEWEST "$F_HIST" dh_newest; step NEWEST-gate "$F_GATE" g_NEW NEWEST any "$EXPECT_NEWEST_REV"
    step HISTORY "$F_HIST" dh_hist; step HISTORY-gate "$F_GATE" g_HAS
    step X1h-1app '^pid [0-9]+ log ' dh_X1
    local i; for i in 1 2 3 4; do step_rc "X1h-2-$i" "0 3" '^(deploy_rc=0|STILL-RUNNING .+)$' dh_X2; [ "$SRC" = 0 ] && break; done
    [ "$SRC" = 0 ] || { echo "PRODROLL HOLD (exit 3): the helm rollback is still running after 4 bounded waits; read: prodroll.sh readback dev-health-post <inputs>"; exit 3; }
    step I9 '^ROLLCHECK: PASS' dh_I9 ;;
  ingress-nginx)
    step NEWEST "$F_HIST" ing_newest; step NEWEST-gate "$F_GATE" g_NEW NEWEST any "$EXPECT_NEWEST_REV"
    step HISTORY "$F_HIST" ing_hist; step HISTORY-gate "$F_GATE" g_HAS
    step ROLLBACK '^rollback rc=0$' ing_RB
    step P2-after '^P2 compute-full-forwarded-for=\[' ing_P2 P2; step P2-after-gate "$F_GATE" g_P2 P2-after P2 ;;
  esac
  echo "ROLLBACK $ARG to revision $LIVEREV: PASS"
}

main() {
  echo "$LINE1"
  echo "PRODROLL mode=$MODE run log: $LOG"
  self_check
  kit_check
  [ "$TGT" != stub ] || refuse "secret-pipe $ARG is not in v3 (CHAOS-11788 scope; the 11709 load-secrets run and the 11712 --pgbouncer-secret step stay lead steps)"
  parse_inputs
  echo "WORK: $WORK"
  case "$SUB" in
    roll) case "$TGT" in dev-health) roll_dh;; ingress-nginx) roll_ing;; esac ;;
    secret-pipe) secret_f1 ;;
    readback) readback ;;
    rollback) rollback ;;
  esac
}

main 2>&1 | tee -a -- "$LOG"
rc=${PIPESTATUS[0]}
echo "PRODROLL END rc=$rc $(date -u +%FT%TZ) log=$LOG" | tee -a -- "$LOG"
exit "$rc"
