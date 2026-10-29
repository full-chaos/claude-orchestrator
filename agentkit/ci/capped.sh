#!/usr/bin/env bash
# D6265: run a command under a hard wall-clock limit and a memory cap.
# Usage: capped.sh [-t SECONDS] [-m GIB] -- <command...>   (defaults: 600 s, 16 GiB)
set -euo pipefail
t=600 m=16
while [ "$#" -gt 0 ]; do
  case "$1" in
    -t) t="$2"; shift 2 ;;
    -m) m="$2"; shift 2 ;;
    --) shift; break ;;
    *) break ;;
  esac
done
[ "$#" -gt 0 ] || { echo "usage: capped.sh [-t SECONDS] [-m GIB] -- <command...>" >&2; exit 2; }

if [ -z "${XDG_RUNTIME_DIR:-}" ]; then
  export XDG_RUNTIME_DIR="/run/user/$(id -u)"
  export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
fi

if timeout 10 systemd-run --user --scope --quiet -- true >/dev/null 2>&1; then
  exec timeout --kill-after=30 "$t" systemd-run --user --scope --quiet \
    -p MemoryMax="${m}G" -p MemorySwapMax=0 -- "$@"
fi

echo "capped.sh: NO systemd scope; fallback = timeout + GOMEMLIMIT=${m}GiB + GOFLAGS=-p=4, bounded by user-1001.slice MemoryMax=96G" >&2
export GOMEMLIMIT="${m}GiB"
export GOFLAGS="${GOFLAGS:+$GOFLAGS }-p=4"
exec timeout --kill-after=30 "$t" "$@"
