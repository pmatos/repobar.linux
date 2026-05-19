#!/usr/bin/env bash
# Build a Debian .deb from the source tree.
#
# Why a wrapper: `dpkg-buildpackage` expects `debian/` at the source
# root, but we keep our packaging at `packaging/debian/` so the
# top-level stays clean. The wrapper symlinks `debian/` into place
# (or removes a stale one) before invoking the build.
#
# Usage:
#   Scripts/build-deb.sh           # build .deb in parent dir
#   Scripts/build-deb.sh --lintian # also run lintian on the result
#
# Pre-reqs (Ubuntu 22.04 / 24.04):
#   sudo apt-get install -y build-essential debhelper devscripts \
#       libgtk-3-dev libayatana-appindicator3-dev pkg-config git
#   # plus a Swift 6.2 toolchain on PATH, via Scripts/install-toolchain.sh
#   # or a manual swift.org tarball install.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
REPO_ROOT="$PWD"

RUN_LINTIAN=0
for arg in "$@"; do
    case "$arg" in
        --lintian) RUN_LINTIAN=1 ;;
        *)         printf 'build-deb: unknown arg %q\n' "$arg" >&2; exit 2 ;;
    esac
done

if ! command -v swift >/dev/null 2>&1; then
    printf 'build-deb: swift is not on PATH. Source the toolchain first:\n' >&2
    printf '         eval "$(Scripts/install-toolchain.sh --print-env)"\n' >&2
    exit 1
fi

if ! command -v dpkg-buildpackage >/dev/null 2>&1; then
    printf 'build-deb: dpkg-buildpackage missing. Install build-essential + debhelper.\n' >&2
    exit 1
fi

# Stage the packaging tree at the canonical location. We use a symlink
# so edits made under packaging/debian/ during a build are visible.
if [[ -e debian && ! -L debian ]]; then
    printf 'build-deb: refusing to touch existing non-symlink debian/. Move it aside first.\n' >&2
    exit 1
fi
ln -sfn packaging/debian debian
trap 'rm -f debian' EXIT

# `-us -uc` skip GPG signing (we don't have a key in CI). `-b` builds
# only the binary package (no source tarball — this is a native repo).
# `-d` skips Build-Depends checks because Swift isn't in apt and the
# control file deliberately omits it.
dpkg-buildpackage -us -uc -b -d

# `dpkg-buildpackage` drops the resulting .deb in the parent directory.
DEB="$(ls -t ../repobar_*.deb 2>/dev/null | head -1 || true)"
if [[ -z "$DEB" ]]; then
    printf 'build-deb: no .deb produced — check dpkg-buildpackage output above.\n' >&2
    exit 1
fi
printf 'build-deb: produced %s\n' "$DEB"

if (( RUN_LINTIAN )); then
    if command -v lintian >/dev/null 2>&1; then
        lintian "$DEB" || true
    else
        printf 'build-deb: lintian not installed; skipping lint pass.\n' >&2
    fi
fi
