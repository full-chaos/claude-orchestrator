#!/usr/bin/env bash
# Tests the testcontainers cleanup of codex-review.sh.v4.8.29-* (CHAOS-10091).
# Usage: test-containers-v4.8.29.sh [wrapper]   (default: the v4.8.29 file beside this script)
# Against v4.8.28 the reap, env and log-line checks FAIL (red); against v4.8.29 all pass.
set -u
D=$(cd "$(dirname "$0")" && pwd)
W=${1:-$(ls "$D"/codex-review.sh.v4.8.29-* | head -1)}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0
ok() { echo "PASS $1"; }
no() { echo "FAIL $1"; fail=1; }
chk() { if [ "$2" = 1 ]; then ok "$1"; else no "$1"; fi; }

# 1. census: TestMain must not run under the warm form; it runs without -exec.
mkdir -p "$T/c" && cd "$T/c" || exit 1
printf 'module census\ngo 1.22\n' > go.mod
echo 'package census' > a.go
cat > a_test.go <<'E'
package census
import ("os";"testing")
func TestMain(m *testing.M){ os.WriteFile(os.Getenv("SENTINEL"),[]byte("ran"),0o644); os.Exit(m.Run()) }
func TestX(t *testing.T){}
E
export GOCACHE=${GOCACHE:-$T/gocache} GOFLAGS=-mod=mod
SENTINEL=$T/s.plain go test -count=1 -run '^$' ./... >/dev/null 2>&1
SENTINEL=$T/s.exec go test -count=1 -run '^$' -exec /bin/true ./... >/dev/null 2>&1
chk "census: TestMain runs without -exec (control)" "$([ -e "$T/s.plain" ] && echo 1 || echo 0)"
chk "census: TestMain does not run with -exec /bin/true" "$([ ! -e "$T/s.exec" ] && echo 1 || echo 0)"
printf 'func Broken( {\n' >> a_test.go
go test -count=1 -run '^$' -exec /bin/true ./... >/dev/null 2>&1
chk "census: -exec form still compiles test files (syntax error fails)" "$([ $? -ne 0 ] && echo 1 || echo 0)"
cd "$D" || exit 1
chk "wrapper warm line keeps -exec /bin/true" "$(grep -q 'GOPROXY=off go test -count=1 -run "^\\$" -exec /bin/true ./\.\.\.' "$W" && echo 1 || echo 0)"

# 2. reap function against a fake docker.
sed -n '/^reap_round_containers() {/,/^}/p' "$W" > "$T/fn.sh"
if [ ! -s "$T/fn.sh" ]; then no "reap_round_containers missing in wrapper"; else
  mkdir -p "$T/bin"
  cat > "$T/bin/docker" <<'E'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_LOG"
case "$1" in
  ps)
    case "$*" in
      *"org.testcontainers.sessionId=mine-1"*) for i in $MINE; do echo "$i"; done ;;
      *"codex-review-round=mine-1"*) for i in $ROUND; do echo "$i"; done ;;
    esac ;;
  rm) [ "$3" = "$FAIL_ID" ] && exit 1; exit 0 ;;
  *) exit 0 ;;
esac
E
  chmod +x "$T/bin/docker"
  run() { ( export PATH="$T/bin:$PATH" FAKE_LOG="$T/log" MINE="$1" ROUND="$2" FAIL_ID="${3:-}"; : > "$T/log"; . "$T/fn.sh"; reap_round_containers "$4" mine-1 mine-1 ) ; }
  out=$(run "aaa111 bbb222" "bbb222 ccc333" "" exit)
  chk "reap line lists left ids once each" "$([ "$out" = "docker-reap: stage=exit session=mine-1 left=aaa111,bbb222,ccc333 removed=aaa111,bbb222,ccc333 remaining=-" ] && echo 1 || echo 0)"
  chk "rm only by the round's ids" "$([ "$(grep -c '^rm -f ' "$T/log")" = 3 ] && ! grep -q 'zzz999' "$T/log" && echo 1 || echo 0)"
  chk "no prune or other host-wide verb" "$(! grep -Eq 'prune|system|stop|kill' "$T/log" && echo 1 || echo 0)"
  out=$(run "" "" "" warm)
  chk "empty round prints '-' fields and calls no rm" "$([ "$out" = "docker-reap: stage=warm session=mine-1 left=- removed=- remaining=-" ] && ! grep -q '^rm' "$T/log" && echo 1 || echo 0)"
  out=$(run "aaa111 bbb222" "" bbb222 exit)
  chk "failed rm lands in remaining" "$([ "$out" = "docker-reap: stage=exit session=mine-1 left=aaa111,bbb222 removed=aaa111 remaining=bbb222" ] && echo 1 || echo 0)"
  out=$( export PATH=/nonexistent-dir; . "$T/fn.sh"; reap_round_containers exit mine-1 mine-1 2>&1 )
  chk "no docker binary: no output, no error" "$([ -z "$out" ] && echo 1 || echo 0)"
fi

# 3. wrapper wiring.
n=$(grep -c 'TESTCONTAINERS_SESSION_ID="\$NAME-\$TS"' "$W")
chk "TESTCONTAINERS_SESSION_ID exported to warm step and codex ($n sites, want 2)" "$([ "$n" = 2 ] && echo 1 || echo 0)"
chk "reap called after warm and at round exit" "$([ "$(grep -c '^ *reap_round_containers \(warm\|exit\) ' "$W")" -ge 3 ] && echo 1 || echo 0)"
chk "no docker prune in wrapper code" "$(! grep -v '^ *#' "$W" | grep -Eq 'docker +(system|container|image|builder) +prune' && echo 1 || echo 0)"
exit $fail
