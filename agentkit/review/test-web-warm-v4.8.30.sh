#!/usr/bin/env bash
# Proves, without a paid round: (A) the wrapper's pnpm block installs once into a per-round store and logs it,
# (B) vitest runs inside a round-shaped sandbox with NO install in the sandbox, (C) a non-web repo gets only a SKIPPED line,
# (D) the install leaves the repo's git hooks untouched.
# Usage: test-web-warm-v4.8.30.sh [scratch-dir]
set -uo pipefail
W=/home/ubuntu/devhealth/scripts/codex-review/codex-review.sh.v4.8.30-a0541efc
S="${1:-/var/lib/oci-cache/lane-scratch/fcc-10280-test}"
CH_REAL="${CODEX_HOME:-$HOME/.codex}"
fail() { echo "FAIL: $*"; exit 1; }
warn() { echo "warn: $*"; }
die() { echo "die: $*"; exit 1; }

[ "$(sha256sum "$W" | cut -c1-8)" = a0541efc ] || fail "wrapper sha"
rm -rf "$S"; mkdir -p "$S/ch" "$S/tmpd" "$S/gotmp" "$S/nonweb" "$S/rec" || fail mkdir
gh repo clone full-chaos/dev-health-web "$S/web" -- --depth 1 >/dev/null 2>&1 || fail clone

# extract the wrapper's own block
BLK="$S/block.sh"
awk '/^RPNPMSTORE="\$RGOTMPDIR\/pnpm-store"/{p=1} p{print} p&&/^fi$/{exit}' "$W" > "$BLK"
[ "$(wc -l < "$BLK")" -gt 10 ] || fail "block not extracted"
run_block() { # $1=RW  $2=logfile
  ( RW="$1" L="$2" RGOTMPDIR="$S/gotmp" RTMPDIR="$S/tmpd"; . "$BLK"; echo "RPNPMSTORE=$RPNPMSTORE" > "$S/rec/vars" )
}

echo "== C: non-web repo (no pnpm-lock.yaml) =="
: > "$S/nonweb.log"; run_block "$S/nonweb" "$S/nonweb.log" >/dev/null
cat "$S/nonweb.log"
[ "$(cat "$S/nonweb.log")" = "pnpm-store: SKIPPED reason=no-pnpm-lock" ] || fail "non-web log differs"
[ ! -e "$S/gotmp/pnpm-store" ] || fail "non-web created a store"

echo "== A: web repo, warm-step install once =="
HOOKS_BEFORE=$(ls "$S/web/.git/hooks" | sort | tr '\n' ' ')
: > "$S/web.log"; run_block "$S/web" "$S/web.log" >/dev/null
cat "$S/web.log"
grep -Eq "^pnpm-store: $S/gotmp/pnpm-store install=[0-9]+s$" "$S/web.log" || fail "log line missing/wrong"
[ "$(ls "$S/web/.git/hooks" | sort | tr '\n' ' ')" = "$HOOKS_BEFORE" ] || fail "install changed .git/hooks"
echo "hooks untouched"
STORE="$S/gotmp/pnpm-store"
[ -d "$STORE/v11" ] || fail "no per-round store"

echo "== B: vitest in round-shaped sandbox, no install inside =="
{ printf 'default_permissions = "codex-review"\n'; cat "$CH_REAL/config.toml"
  printf '\n[permissions.codex-review]\nextends = ":workspace"\n\n[permissions.codex-review.filesystem]\nglob_scan_max_depth = 8\n'
  for p in /var/lib/oci-cache/go-build /var/lib/oci-cache/go-mod "$S/gotmp" "$HOME/go" /var/lib/oci-cache/uv "$S/tmpd"; do printf '"%s" = "write"\n' "$p"; done
  printf '\n[permissions.codex-review.network]\nenabled = true\n'
} > "$S/ch/config.toml"
f=$(cd "$S/web" && git ls-files | grep -E '^src/.*\.test\.tsx?$' | head -1)
echo "vitest file: $f"
out=$(cd "$S/web" && env CODEX_HOME="$S/ch" TMPDIR="$S/tmpd" GOTMPDIR="$S/gotmp" pnpm_config_store_dir="$STORE" \
  codex sandbox -P codex-review -C "$S/web" -- pnpm exec vitest run "$f" 2>&1)
echo "$out" | tail -7
echo "$out" | grep -Eq 'Tests +[0-9]+ passed' || fail "vitest pass line missing"
echo "$out" | grep -q ERR_SQLITE_ERROR && fail "sqlite error"

echo "== control: v4.8.29 shape (default store, install inside sandbox) =="
rm -rf "$S/web/node_modules"
c=$(cd "$S/web" && env CODEX_HOME="$S/ch" TMPDIR="$S/tmpd" codex sandbox -P codex-review -C "$S/web" -- pnpm install --frozen-lockfile 2>&1)
echo "$c" | grep -q ERR_SQLITE_ERROR && echo "control reproduces ERR_SQLITE_ERROR" || fail "control did not reproduce"
echo "PASS"
