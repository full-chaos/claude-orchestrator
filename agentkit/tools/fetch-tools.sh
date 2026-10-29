#!/usr/bin/env bash
# Fetch pinned lint tools into ./bin (binaries are not committed). Versions and checksums from the READMEs beside this file.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; out="${1:-$here/bin}"; mkdir -p "$out"; tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
arch="$(uname -m)"; case "$arch" in aarch64|arm64) sc=aarch64 ;; x86_64) sc=x86_64 ;; *) echo "unsupported arch $arch" >&2; exit 2 ;; esac
if [ "$sc" = aarch64 ]; then want=68a8133197a50beb8803f8d42f9908d1af1c5540d4bb05fdfca8c1fa47decefc; else want=""; fi
curl -fsSL "https://github.com/koalaman/shellcheck/releases/download/v0.11.0/shellcheck-v0.11.0.linux.$sc.tar.gz" -o "$tmp/sc.tgz"
[ -z "$want" ] || echo "$want  $tmp/sc.tgz" | sha256sum -c -
tar -xzf "$tmp/sc.tgz" -C "$tmp"; install -m 0755 "$tmp/shellcheck-v0.11.0/shellcheck" "$out/shellcheck"
GOBIN="$out" go install github.com/rhysd/actionlint/cmd/actionlint@v1.7.7
echo "installed to $out"
