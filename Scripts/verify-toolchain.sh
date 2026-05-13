#!/usr/bin/env bash
# Verify that Scripts/install-toolchain.sh produces a working Swift 6.2
# environment when run from a clean container of a target Linux distro.
#
# Usage:
#   Scripts/verify-toolchain.sh <docker-image>
#
# Example:
#   Scripts/verify-toolchain.sh ubuntu:22.04
#   Scripts/verify-toolchain.sh ubuntu:24.04
#   Scripts/verify-toolchain.sh archlinux:latest
#
# Exit codes:
#   0  swift --version reports 6.2.x AND an empty SwiftPM package builds
#   1  test assertion failed (script ran, but the resulting toolchain is wrong)
#   2  environmental error (docker missing, install script missing, etc.)

set -euo pipefail

if [ $# -lt 1 ]; then
    printf 'usage: %s <docker-image>\n' "${0##*/}" >&2
    exit 2
fi

IMAGE="$1"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SCRIPT="$REPO_ROOT/Scripts/install-toolchain.sh"

if ! command -v docker >/dev/null 2>&1; then
    printf 'verify-toolchain: docker not on PATH\n' >&2
    exit 2
fi

if [ ! -x "$INSTALL_SCRIPT" ]; then
    printf 'verify-toolchain: %s not found or not executable\n' "$INSTALL_SCRIPT" >&2
    exit 2
fi

# The container-side driver:
#   1. Run the mounted install script.
#   2. Source the env hint it prints so `swift` is on PATH for this shell.
#   3. Assert `swift --version` matches Swift 6.2.
#   4. Build an empty SwiftPM package to assert the toolchain is usable.
#
# All temporary state lives inside the container's writable layer; no host
# mounts are written.
CONTAINER_DRIVER='
set -euo pipefail
/mnt/install-toolchain.sh
# install-toolchain.sh prints `export PATH=...` lines for the calling shell.
# Re-run it with --print-env to source just those lines reliably.
eval "$(/mnt/install-toolchain.sh --print-env)"

echo "::verify:: swift --version output:"
swift --version

if ! swift --version | grep -qE "Swift version 6\.2(\.[0-9]+)?"; then
    echo "::verify:: FAIL: swift --version did not report 6.2.x" >&2
    exit 1
fi

cd "$(mktemp -d)"
swift package init --type executable --name hello >/dev/null
swift build >/dev/null
./.build/debug/hello | grep -q "Hello, world" || {
    echo "::verify:: FAIL: empty SwiftPM package did not build/run" >&2
    exit 1
}

echo "::verify:: PASS"
'

docker run --rm \
    -v "$INSTALL_SCRIPT:/mnt/install-toolchain.sh:ro" \
    "$IMAGE" \
    bash -c "$CONTAINER_DRIVER"
