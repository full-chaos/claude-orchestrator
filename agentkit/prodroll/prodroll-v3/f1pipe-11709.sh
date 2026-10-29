#!/usr/bin/env bash
# f1pipe-11709.sh -- CHAOS-11709 gate f1 "pipe it" (chris YES via pm 13:5xZ): build ops.clickhouseCloud {host, database, user,
# password} in the operator's values.prod-secrets.yaml from the LIVE Secret dev-health-ops key CLICKHOUSE_NATIVE_URI.
# The value moves ONLY as: kubectl jsonpath (D6423) | base64 -d | python3 -I writer (stdin). It is never on argv, in a shell
# variable, in output or in a log; the only files that get it are the target (via a 0600 temp in the same dir + atomic rename).
# The writer refuses unless the URI load-secrets.sh 4711ba49 :230 would build from the 4 values is BYTE-EQUAL to the live URI.
# Prints names, booleans, counts and D6423 sha12 only. Before/after: sha12 of the URI built from the file vs the live sha12.
# Run (fcc, as the file owner ubuntu, on prod; new log name):
#   ssh prod 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; umask 077; set -o noclobber; env -i PATH=/usr/local/bin:/usr/bin:/bin HOME=/home/ubuntu LANG=C.UTF-8 KUBECONFIG=/etc/rancher/k3s/k3s.yaml bash --norc --noprofile -s > /home/ubuntu/lane-prod-k8s/11709-logs/F1PIPE-<HHMMSS>Z.log 2>&1; echo rc=$? >> /home/ubuntu/lane-prod-k8s/11709-logs/F1PIPE-<HHMMSS>Z.log' < f1pipe-11709.sh
# Exit: 0 = written (or already equal) and AFTER EQUAL; 1 = STOP before any write (file unchanged); 3 = a read failed (file
# unchanged); 4 = STOP AFTER the write (restore line printed); 10 = xtrace on.
# shellcheck disable=SC2016
set -uo pipefail
set -o noclobber
case "$-" in *x*) echo "REFUSED (exit 10): xtrace on"; exit 10;; esac
case ":${SHELLOPTS:-}:" in *:xtrace:*) echo "REFUSED (exit 10): SHELLOPTS has xtrace"; exit 10;; esac
set +a
umask 077

NS=${NS:-dev-health}
PSV=${PROD_SECRETS_VALUES:-/home/ubuntu/.config/dev-health/values.prod-secrets.yaml}
OWNER=${PSV_OWNER:-ubuntu}
MARKER=${ROTATION_MARKER:-/home/ubuntu/.config/dev-health/pg-owner-rotation.marker}
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
BAK="$PSV.pre-11709-f1pipe-$STAMP"
die() { echo "STOP: $* (nothing written)"; exit 1; }
die3() { echo "STOP (exit 3): $* (nothing written)"; exit 3; }
allzero() { local s; for s in "$@"; do [ "$s" = 0 ] || return 1; done; }
kg() { kubectl -n "$NS" "$@" </dev/null; }

# Python that builds the URI from the FILE (as load-secrets.sh 4711ba49 :202-231) to stdout, for a sha12 pipe only.
# rc 0 = built; 2 = block absent; 3 = block invalid; 6 = file unreadable or not YAML (type only).
BUILD='
import sys, re
from urllib.parse import quote
try:
    import yaml
    with open(sys.argv[1]) as fh:
        s = yaml.safe_load(fh)
except BaseException as e:
    sys.stderr.write("f1pipe: prod-secrets unreadable or not YAML (%s; detail withheld)\n" % type(e).__name__); sys.exit(6)
ops = s.get("ops") if isinstance(s, dict) else None
cc = ops.get("clickhouseCloud") if isinstance(ops, dict) else None
if cc is None: sys.exit(2)
f = ("host", "database", "user", "password")
if not isinstance(cc, dict) or sorted(cc) != sorted(f) or not all(isinstance(cc[k], str) and cc[k] for k in f): sys.exit(3)
sys.stdout.write("clickhouse://%s:%s@%s:9440/%s?secure=true" % (quote(cc["user"], safe=""), quote(cc["password"], safe=""), cc["host"], cc["database"]))
'
live_sha() { # D6423 form
  local a s1 s2 s3 s4
  a=$(kg get secret dev-health-ops -o jsonpath='{.data.CLICKHOUSE_NATIVE_URI}' | base64 -d | sha256sum | cut -c1-12; echo " ${PIPESTATUS[*]}"); a=${a//$'\n'/ }
  read -r LIVE s1 s2 s3 s4 <<<"$a"; allzero "$s1" "$s2" "$s3" "$s4" || die3 "live CLICKHOUSE_NATIVE_URI read (stage status: $s1 $s2 $s3 $s4)"
}
file_vs_live() { # prints EQUAL / DIFF / ABSENT / INVALID; the built value only feeds sha256sum
  local b e t1 t2 t3
  b=$(python3 -I -c "$BUILD" "$PSV" </dev/null | sha256sum | cut -c1-12; echo " ${PIPESTATUS[*]}"); b=${b//$'\n'/ }
  read -r e t1 t2 t3 <<<"$b"
  allzero "$t2" "$t3" || die3 "sha pipe (stage status: $t1 $t2 $t3)"
  case "$t1" in
    0) if [ "$e" = "$LIVE" ]; then CMP=EQUAL; else CMP=DIFF; fi ;;
    2) CMP=ABSENT ;; 3) CMP=INVALID ;;
    *) die3 "file parse (python rc $t1: 6 = unreadable or not YAML)" ;;
  esac
  unset e
}
names() { python3 -I -c '
import sys, yaml
try:
    with open(sys.argv[1]) as fh:
        s = yaml.safe_load(fh)
except BaseException as e:
    print("parse=FAIL(%s)" % type(e).__name__); sys.exit(0)
ops = s.get("ops") if isinstance(s, dict) else None
cc = ops.get("clickhouseCloud", "ABSENT") if isinstance(ops, dict) else "ABSENT"
if isinstance(cc, str) and cc == "ABSENT": print("ABSENT"); sys.exit(0)
if not isinstance(cc, dict): print("NOT_A_MAPPING"); sys.exit(0)
w = ("database", "host", "password", "user")
print("present=%s other_keys=%d nonempty_strings=%d" % (",".join(x for x in w if x in cc) or "none", sum(1 for x in cc if x not in w), sum(1 for x in w if isinstance(cc.get(x), str) and cc.get(x))))
' "$PSV" </dev/null; }

echo "== f1pipe-11709 ns=$NS time=$STAMP"
echo "== P0 preconditions"
[ "$(id -un)" = "$OWNER" ] || die "run as $OWNER (the file owner), not $(id -un)"
[ -f "$PSV" ] && [ ! -L "$PSV" ] || die "$PSV is not a regular file"
[ ! -L "$(dirname "$PSV")" ] || die "$(dirname "$PSV") is a link"
om=$(stat -c '%a %U' "$PSV") || die3 "stat $PSV"
echo "P0 file mode/owner before: $om"
[ "$om" = "600 $OWNER" ] || die "$PSV mode/owner $om (want 600 $OWNER)"
if [ -e "$MARKER" ] || [ -L "$MARKER" ]; then die "a Postgres owner rotation marker exists ($MARKER): the file is mid-rotation"; fi
echo "P0 rotation marker: absent"
[ ! -e "$BAK" ] || die "backup name $BAK exists"
ty=$(kg get secret dev-health-ops -o jsonpath='{.type}') || die3 "type of dev-health-ops"
[ "$ty" = Opaque ] || die "dev-health-ops type=$ty (want Opaque)"
kn=$(kg get secret dev-health-ops -o go-template='{{range $k, $v := .data}}{{$k}}{{"\n"}}{{end}}'; echo "rc=$?")
[ "${kn##*rc=}" = 0 ] || die3 "key names of dev-health-ops"
grep -qx CLICKHOUSE_NATIVE_URI <<<"${kn%rc=*}" || die "dev-health-ops has no key CLICKHOUSE_NATIVE_URI"
echo "P0 dev-health-ops type=Opaque, key CLICKHOUSE_NATIVE_URI present"

echo "== BEFORE"
live_sha
file_vs_live
echo "BEFORE live CLICKHOUSE_NATIVE_URI sha12=$LIVE; URI built from the file: $CMP; ops.clickhouseCloud $(names)"
if [ "$CMP" = EQUAL ]; then echo "F1PIPE: PASS (already EQUAL; nothing written)"; exit 0; fi

echo "== WRITE (one pipe: kubectl jsonpath | base64 -d | python3 -I writer on stdin)"
WRITER='
import sys, os, re, json
from urllib.parse import unquote, quote
def say(m): print("WRITE " + m)
def refuse(m): print("WRITE REFUSED: " + m + " (nothing written)"); sys.exit(1)
def main():
    path, bak = sys.argv[1], sys.argv[2]
    raw = sys.stdin.buffer.read()
    try:
        uri = raw.decode("utf-8", "strict")
    except UnicodeDecodeError:
        refuse("the live value is not UTF-8")
    if not uri or any(c in uri for c in "\r\n\x00"):
        refuse("the live value is empty or has CR, LF or NUL")
    m = re.fullmatch(r"clickhouse://([^@/?#]+)@([^@/?#]+):9440/([A-Za-z0-9_]+)\?secure=true", uri)
    if not m:
        refuse("the live value is not clickhouse://<userinfo>@<host>:9440/<db>?secure=true")
    ui, host, db = m.group(1), m.group(2), m.group(3)
    if ui.count(":") != 1:
        refuse("the userinfo is not exactly user:password")
    u_enc, p_enc = ui.split(":")
    try:
        user, pw = unquote(u_enc, errors="strict"), unquote(p_enc, errors="strict")
    except UnicodeDecodeError:
        refuse("the userinfo does not decode as UTF-8")
    if len(host) > 253 or not all(re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?", x) for x in host.split(".")):
        refuse("the host is not a DNS name (load-secrets.sh :226)")
    if not user or not pw:
        refuse("user or password is empty")
    if "clickhouse://%s:%s@%s:9440/%s?secure=true" % (quote(user, safe=""), quote(pw, safe=""), host, db) != uri:
        refuse("round trip: the URI load-secrets.sh :230 builds from these 4 values is not byte-equal to the live CLICKHOUSE_NATIVE_URI")
    if user != "dho_app":
        refuse("the user is not dho_app")
    say("parsed: scheme clickhouse, port 9440, secure=true, user_is_dho_app=true, host_dns_ok=true, db_ok=true, roundtrip=EQUAL")
    import yaml
    st = os.lstat(path)
    if not os.path.isfile(path) or os.path.islink(path) or (st.st_mode & 0o777) != 0o600:
        refuse("the target is not a regular 0600 file")
    with open(path, "rb") as fh:
        orig = fh.read()
    try:
        text = orig.decode("utf-8", "strict")
        data = yaml.safe_load(text)
    except BaseException as e:
        refuse("the target is not UTF-8 YAML (%s; detail withheld)" % type(e).__name__)
    if "\t" in text:
        refuse("the target has a TAB")
    if not isinstance(data, dict) or not isinstance(data.get("ops"), dict):
        refuse("the target has no ops mapping")
    lines = text.splitlines(keepends=True)
    tops = [i for i, l in enumerate(lines) if re.fullmatch(r"ops:[ ]*(#[^\n]*)?\r?\n?", l)]
    if len(tops) != 1:
        refuse("the target has not exactly one block-style top-level ops: line")
    i0 = tops[0]
    def ind(l):
        return len(l) - len(l.lstrip(" "))
    def blank(l):
        return l.strip() == "" or l.lstrip(" ").startswith("#")
    end = len(lines)
    for k in range(i0 + 1, len(lines)):
        if lines[k].strip() and ind(lines[k]) == 0:
            end = k
            break
    kids = [k for k in range(i0 + 1, end) if not blank(lines[k])]
    if not kids:
        refuse("ops: has no child lines")
    n = ind(lines[kids[0]])
    if n == 0:
        refuse("cannot tell the ops child indent")
    hits = [k for k in range(i0 + 1, end) if ind(lines[k]) == n and re.match(r"clickhouseCloud:(\s|$)", lines[k][n:])]
    if len(hits) > 1:
        refuse("ops.clickhouseCloud appears more than once")
    sp, sp2 = " " * n, " " * (2 * n)
    block = [sp + "clickhouseCloud:\n"] + ["%s%s: %s\n" % (sp2, k, json.dumps(v)) for k, v in (("host", host), ("database", db), ("user", user), ("password", pw))]
    if hits:
        j = hits[0]
        e = j + 1
        while e < end and (lines[e].strip() == "" or ind(lines[e]) > n):
            e += 1
        new_lines = lines[:j] + block + lines[e:]
        action = "replaced"
    else:
        new_lines = lines[:i0 + 1] + block + lines[i0 + 1:]
        action = "added"
    new_text = "".join(new_lines)
    try:
        new = yaml.safe_load(new_text)
    except BaseException as e:
        refuse("the edited text does not parse (%s; detail withheld)" % type(e).__name__)
    want = dict(data)
    want["ops"] = dict(data["ops"])
    want["ops"]["clickhouseCloud"] = {"host": host, "database": db, "user": user, "password": pw}
    if new != want:
        refuse("the edited file does not parse to the old file + exactly ops.clickhouseCloud")
    if new_text.count("clickhouseCloud:") != 1:
        refuse("the edited file has not exactly one clickhouseCloud: text (r0 F1 counts it)")
    d = os.path.dirname(path) or "."
    fd = os.open(bak, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "wb") as fh:
        fh.write(orig); fh.flush(); os.fsync(fh.fileno())
    with open(path, "rb") as fh:
        if fh.read() != orig:
            refuse("the target changed while it was read (backup %s kept)" % bak)
    tmp = os.path.join(d, ".%s.f1pipe-%d.tmp" % (os.path.basename(path), os.getpid()))
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(new_text.encode("utf-8")); fh.flush(); os.fsync(fh.fileno())
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    dfd = os.open(d, os.O_RDONLY)
    os.fsync(dfd); os.close(dfd)
    say("ops.clickhouseCloud %s (4 keys); every other key unchanged=true; backup of the old file: %s (0600)" % (action, bak))
try:
    main()
except SystemExit:
    raise
except BaseException as e:
    print("WRITE ERROR: %s (detail withheld)" % type(e).__name__)
    sys.exit(9)
'
w=$(kg get secret dev-health-ops -o jsonpath='{.data.CLICKHOUSE_NATIVE_URI}' | base64 -d | python3 -I -c "$WRITER" "$PSV" "$BAK"; echo "rc=${PIPESTATUS[*]}")
printf '%s\n' "${w%rc=*}" | sed '/^$/d'
read -r k1 k2 k3 <<<"${w##*rc=}"
if [ "$k3" = 1 ]; then echo "STOP: the writer refused (nothing written)"; exit 1; fi
allzero "$k1" "$k2" || { if [ -e "$BAK" ]; then echo "STOP (exit 4): read stage failed after the backup (stage status: $k1 $k2 $k3); check the file"; exit 4; fi; die3 "live read (stage status: $k1 $k2 $k3)"; }
if [ "$k3" != 0 ]; then
  if [ -e "$BAK" ]; then echo "STOP (exit 4): writer rc $k3 after the backup; restore: mv -f -- '$BAK' '$PSV' (as $OWNER) after a check"; exit 4; fi
  die3 "writer rc $k3"
fi

echo "== AFTER"
om2=$(stat -c '%a %U' "$PSV") || { echo "STOP (exit 4): stat after the write"; exit 4; }
live_sha
file_vs_live
echo "AFTER file mode/owner: $om2; backup $BAK mode/owner: $(stat -c '%a %U' "$BAK")"
echo "AFTER live CLICKHOUSE_NATIVE_URI sha12=$LIVE; URI built from the file: $CMP; ops.clickhouseCloud $(names)"
if [ "$CMP" = EQUAL ] && [ "$om2" = "600 $OWNER" ]; then echo "F1PIPE: PASS"; exit 0; fi
echo "STOP (exit 4): AFTER is not EQUAL or the mode changed; restore: mv -f -- '$BAK' '$PSV' (as $OWNER) after acp/pm word"
exit 4
