#!/usr/bin/env bash
# Proves, without a codex call or docker: a `du` that exits 1 after a clean warm (files vanished mid-walk in the shared
# go-build cache) must not abort the round. The test extracts the wrapper's own warm-size lines, runs them under the wrapper's
# `set -euo pipefail` with a fake `du` first on PATH, and requires the round to continue and the size to be kept.
# Usage: test-du-guard-v4.8.33.sh WRAPPER   (rc 0 = round continues; rc 1 = the round would die silently)
set -uo pipefail
W="${1:?usage: $0 WRAPPER}"
[ -f "$W" ] || { echo "FAIL: no such wrapper $W"; exit 2; }
T=$(mktemp -d /var/lib/oci-cache/lane-scratch/pm-11436/du-guard-XXXXXX) || exit 2
trap 'rm -rf "$T"' EXIT
mkdir "$T/bin" "$T/modcache" "$T/gocache"

# the wrapper's own lines, from the first WARM_MODCACHE_SIZE assignment to the WARM_GOCACHE_SIZE default
awk '/^  WARM_MODCACHE_SIZE=\$\(du/{p=1} p{print} p&&/^  WARM_GOCACHE_SIZE=\$\{WARM_GOCACHE_SIZE:-unknown\}/{exit}' "$W" > "$T/block.sh"
[ "$(wc -l < "$T/block.sh")" -eq 4 ] || { echo "FAIL: warm-size block not extracted ($(wc -l < "$T/block.sh") lines)"; exit 2; }

# fake du: prints a size line, then exits 1 like du does when a file vanishes during the walk
cat > "$T/bin/du" <<'DU'
#!/usr/bin/env bash
printf '123M\t%s\n' "${!#}"
echo "du: cannot access '${!#}/x': No such file or directory" >&2
exit 1
DU
chmod +x "$T/bin/du"

out=$(PATH="$T/bin:$PATH" RGOMODCACHE="$T/modcache" RGOCACHE="$T/gocache" bash -c '
  set -euo pipefail
  . "$1"
  echo "CONTINUED mod=$WARM_MODCACHE_SIZE go=$WARM_GOCACHE_SIZE"' _ "$T/block.sh" 2>&1)
rc=$?
echo "$out"
echo "rc=$rc"
case "$out" in *"CONTINUED mod=123M go=123M"*) [ "$rc" -eq 0 ] && { echo "PASS: the round continues and keeps the size"; exit 0; };; esac
echo "FAIL: the round died after a du exit 1 (silent abort under set -euo pipefail)"
exit 1
