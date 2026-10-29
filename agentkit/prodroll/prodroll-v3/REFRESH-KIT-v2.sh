#!/usr/bin/env bash
# REFRESH-KIT-v2.sh -- prodroll v2 pre-phase refresh, KIT-OWNED (pm v2 (a): no pre-phase script may come from the checked-out tree).
# Run ON prod: ssh ... prod 'bash -s -- kitrefresh <roll-tree sha> <rollback-tree sha>' < REFRESH-KIT-v2.sh
# = the r11 ROLL-24d.sh `refresh` verb (ROLL-24d.sh :150-157, 6c9949c8) with ONE change: verify_pins runs from THIS kit file -- the function
# verify_pins_kit below holds lines 14-62 of deploy 309dadea:scripts/run-verify-pins.sh (blob a650c6ef) verbatim -- and never from the tree.
# Nothing in either tree is executed: git (fetch, checkout, submodule update) and helm (dependency build, template; the chart is data) only.
# Exit 0 = both trees at their sha, verify_pins passed, helm template rc 0; 1 = FAIL; 2 = usage; 10 = xtrace.
case "$-" in *x*) echo "REFRESH-KIT REFUSED (exit 10): xtrace is on"; exit 10;; esac
case ":${SHELLOPTS:-}:" in *:xtrace:*) echo "REFRESH-KIT REFUSED (exit 10): SHELLOPTS has xtrace"; exit 10;; esac
set -u; export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
NS=dev-health; D=$HOME/lane-prod-k8s; R=24d; C=$D/deploy-roll-$R; RB=$D/deploy-rollback-$R
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0='*'
okhelm() { helm template dev-health chart --namespace $NS $( [ -e $D/roll-24d-values.yaml ] && echo "-f $D/roll-24d-values.yaml" ) -f values.kiac.yaml -f values.prod.yaml -f $HOME/.config/dev-health/values.prod-secrets.yaml "$@" >/dev/null 2>&1 && echo "PASS helm template rc 0" || { echo "FAIL helm template"; return 1; }; }
verify_pins_kit() (
# >>> verbatim: deploy 309dadea:scripts/run-verify-pins.sh lines 14-62 (blob a650c6ef5e9b07ed974782b6ee666988ae048003)
set -euo pipefail
values_file=${1:-values.local.yaml}
expected_pairs='vendor/dev-health-ops|https://github.com/full-chaos/dev-health-ops.git vendor/dev-health-web|https://github.com/full-chaos/dev-health-web.git vendor/dev-health-acr|https://github.com/full-chaos/dev-health-acr.git'
norm() { printf '%s' "$1" | sed -E 's#^(https://|git@)github\.com[:/]##; s#\.git$##'; }
actual_count=$(git config --file .gitmodules --get-regexp '^submodule\..*\.path$' | wc -l | tr -d ' ')
[ "$actual_count" = 3 ] || { printf '%s\n' 'pin_error=unexpected_submodule_set' >&2; exit 1; }
for pair in $expected_pairs; do
    path=${pair%%|*}; url=${pair#*|}
    [ -d "$path/.git" ] || [ -f "$path/.git" ] || { printf '%s\n' "pin_error=uninitialized_submodule path=$path" >&2; exit 1; }
    configured_url=$(git config --file .gitmodules --get "submodule.$path.url" || true)
    [ "$configured_url" = "$url" ] || { printf '%s\n' "pin_error=unexpected_submodule_url path=$path" >&2; exit 1; }
    actual_url=$(git -C "$path" remote get-url origin || true)
    [ "$(norm "$actual_url")" = "$(norm "$url")" ] || { printf '%s\n' "pin_error=unexpected_submodule_origin path=$path" >&2; exit 1; }
    git -C "$path" rev-parse --verify --quiet 'HEAD^{commit}' >/dev/null || { printf '%s\n' "pin_error=unresolved_submodule_head path=$path" >&2; exit 1; }
    dirty_status=$(git -C "$path" status --porcelain)
    [ -z "$dirty_status" ] || { printf '%s\n' "pin_error=dirty_submodule path=$path" >&2; exit 1; }
done
if ! status=$(git submodule status --recursive); then
    printf '%s\n' 'pin_error=gitlink_status_unavailable' >&2; exit 1
fi
printf '%s\n' "$status" | while IFS= read -r status_line; do
    case "$status_line" in +*|-*|U*) printf '%s\n' 'pin_error=gitlink_mismatch' >&2; exit 1;; esac
done
# Two values-file shapes (CHAOS-6994 / D2740):
#  - tag-pinned (values.local.yaml, k3d): the ops image `tag:` must equal the vendored ops
#    submodule HEAD (short 12) -- the original check, unchanged;
#  - digest-pinned (values.prod.yaml): no `tag:` line at all; every image reference the file
#    names (an `image:`/`repository:` value holding a registry path, anchors included) must be an
#    immutable @sha256:<64 hex> digest. Before this split, a digest-pinned file failed the tag
#    check with an EMPTY actual tag -- a false failure on every prod pre-roll.
if awk '$1 == "tag:" { found = 1 } END { exit !found }' "$values_file"; then
    expected_local_tag=$(git -C vendor/dev-health-ops rev-parse --short=12 HEAD)
    actual_local_tag=$(awk '$1 == "tag:" { gsub(/"/, "", $2); print $2; exit }' "$values_file")
    [ "$actual_local_tag" = "$expected_local_tag" ] || { printf '%s\n' "pin_error=local_ops_image_tag_mismatch expected=$expected_local_tag actual=$actual_local_tag" >&2; exit 1; }
else
    # Image references: the value of an image:/repository: key (after an optional &anchor) that
    # contains a registry path. Alias references (*name) point at an anchored value already checked.
    refs=$(awk '
        $1 == "image:" || $1 == "repository:" {
            v = $2; if (v ~ /^&/) v = $3
            gsub(/"/, "", v)
            if (v ~ /\//) print v
        }' "$values_file")
    ref_count=$(printf '%s\n' "$refs" | grep -c . || true)
    [ "$ref_count" -gt 0 ] || { printf '%s\n' 'pin_error=no_image_pin_in_values' >&2; exit 1; }
    unpinned=$(printf '%s\n' "$refs" | grep -vcE '@sha256:[0-9a-f]{64}$' || true)
    [ "$unpinned" = 0 ] || { printf '%s\n' "pin_error=image_not_digest_pinned count=$unpinned" >&2; exit 1; }
fi
printf '%s\n' 'verify_pins=passed'
# <<< verbatim end
)
[ "${1:-}" = kitrefresh ] && [[ ${2:-} =~ ^[0-9a-f]{40}$ ]] && [[ ${3:-} =~ ^[0-9a-f]{40}$ ]] || { echo "usage: kitrefresh <roll-tree sha> <rollback-tree sha> (40 hex each): STOP"; exit 2; }
for pair in "$C $2" "$RB $3"; do set -- $pair; d=$1; s=$2
  git -C $d fetch -q origin "+refs/heads/*:refs/remotes/origin/*" && git -C $d checkout -q --detach "$s" && git -C $d submodule update -q --init || { echo FAIL $d; exit 1; }
  [ "$(git -C $d rev-parse HEAD)" = "$s" ] && echo "PASS $d @ $s" || { echo "FAIL sha $d"; exit 1; }
  echo "gitlinks: acr $(git -C $d ls-tree HEAD vendor/dev-health-acr | awk '{print $3}' | cut -c1-8) ops $(git -C $d ls-tree HEAD vendor/dev-health-ops | awk '{print $3}' | cut -c1-8)"
  vp=$(cd $d && verify_pins_kit values.prod.yaml 2>&1); vrc=$?; echo "$vp" | tail -1; [ "$vrc" = 0 ] || { echo "FAIL verify_pins (kit copy) $d (rc $vrc)"; exit 1; }
  (cd $d && helm dependency build chart >/dev/null 2>&1 && okhelm) || { echo "FAIL helm template $d"; exit 1; }
done
echo "KITREFRESH: PASS (both trees; verify_pins from the kit, nothing run from the trees)"
