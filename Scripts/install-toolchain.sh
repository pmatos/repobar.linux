#!/usr/bin/env bash
# Install Swift 6.2 on a supported Linux distro.
#
# Supported targets (auto-detected from /etc/os-release):
#   ubuntu 22.04   official Swift.org tarball
#   ubuntu 24.04   official Swift.org tarball
#   arch           official Swift.org Ubuntu 24.04 tarball (works on Arch
#                  thanks to its current glibc)
#
# Modes:
#   default          install dependencies and the toolchain; print env hints
#                    on stdout for the calling shell to source.
#   --print-env      print only the env hints (no install). Useful for
#                    sourcing into a shell after a previous install.
#   --check          dry-run: print what would be installed, no side effects.
#
# Output: zero or more `export PATH=...` lines on stdout (mode-dependent).
# All progress chatter goes to stderr so `eval "$(install-toolchain.sh --print-env)"`
# remains safe.

set -euo pipefail

SWIFT_VERSION="6.2"
SWIFT_RELEASE="swift-${SWIFT_VERSION}-RELEASE"
INSTALL_PREFIX="${SWIFT_INSTALL_PREFIX:-$HOME/.swift/${SWIFT_RELEASE}}"

MODE="install"
SKIP_DEPS=0
case "${1:-}" in
    --print-env) MODE="print-env" ;;
    --check)     MODE="check" ;;
    --skip-deps) SKIP_DEPS=1 ;;
    "")          ;;
    *)           printf 'install-toolchain: unknown arg %q\n' "$1" >&2; exit 2 ;;
esac
# Allow env override too (useful for CI / non-root machines where deps are
# pre-installed and we don't want the script to invoke a package manager).
[ "${SWIFT_INSTALL_SKIP_DEPS:-0}" = "1" ] && SKIP_DEPS=1

log() { printf '[install-toolchain] %s\n' "$*" >&2; }

detect_distro() {
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        printf '%s %s\n' "${ID:-unknown}" "${VERSION_ID:-}"
    else
        printf 'unknown\n'
    fi
}

# Choose the tarball URL for the detected distro. Arch and other rolling
# distros fall back to the Ubuntu 24.04 tarball because Swift.org does not
# ship native builds for them; the dynamic linker tolerates this on current
# Arch installs (glibc >= 2.39).
tarball_url() {
    local id="$1"
    case "$id" in
        ubuntu-22.04) printf 'https://download.swift.org/swift-%s-release/ubuntu2204/%s/%s-ubuntu22.04.tar.gz\n' \
                          "$SWIFT_VERSION" "$SWIFT_RELEASE" "$SWIFT_RELEASE" ;;
        ubuntu-24.04) printf 'https://download.swift.org/swift-%s-release/ubuntu2404/%s/%s-ubuntu24.04.tar.gz\n' \
                          "$SWIFT_VERSION" "$SWIFT_RELEASE" "$SWIFT_RELEASE" ;;
        arch-*)       printf 'https://download.swift.org/swift-%s-release/ubuntu2404/%s/%s-ubuntu24.04.tar.gz\n' \
                          "$SWIFT_VERSION" "$SWIFT_RELEASE" "$SWIFT_RELEASE" ;;
        *)            return 1 ;;
    esac
}

# Print the env additions for the installed toolchain. Stdout only.
#
# Always emits PATH; also emits LD_LIBRARY_PATH because some hosts (notably
# Arch) need a shim lib dir on the loader search path. Including it on hosts
# where the shim dir contains nothing is harmless.
print_env() {
    printf 'export PATH=%q:${PATH:-}\n' "$INSTALL_PREFIX/usr/bin"
    printf 'export LD_LIBRARY_PATH=%q:${LD_LIBRARY_PATH:-}\n' "$INSTALL_PREFIX/usr/lib"
}

install_deps_ubuntu() {
    local prereqs=(
        binutils
        ca-certificates
        curl
        git
        gnupg
        libcurl4
        libedit2
        libncurses6
        libpython3-dev
        libsqlite3-0
        libxml2
        libz3-dev
        pkg-config
        tzdata
        unzip
        zlib1g-dev
    )
    case "$1" in
        22.04) prereqs+=(libgcc-11-dev libstdc++-11-dev) ;;
        24.04) prereqs+=(libgcc-13-dev libstdc++-13-dev) ;;
    esac
    log "installing apt prerequisites"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >&2
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${prereqs[@]}" >&2
}

install_deps_arch() {
    log "installing pacman prerequisites"
    pacman -Sy --noconfirm --needed \
        base-devel ca-certificates curl gcc git icu libedit libxml2 ncurses \
        python sqlite tar unzip zlib >&2
}

# Arch ships only the widechar ncurses (libncursesw.so.6); the Ubuntu-built
# Swift binaries link against libncurses.so.6. Provide a private shim inside
# the toolchain's lib dir so the dynamic linker resolves it via rpath without
# needing root or LD_LIBRARY_PATH on the host. Same trick for libpython if
# the host's python soname differs from what Swift expects.
shim_arch_libs() {
    local lib_dir="$INSTALL_PREFIX/usr/lib"
    mkdir -p "$lib_dir"

    if [ ! -e "$lib_dir/libncurses.so.6" ] && [ -e /usr/lib/libncursesw.so.6 ]; then
        ln -sf /usr/lib/libncursesw.so.6 "$lib_dir/libncurses.so.6"
        log "shimmed libncurses.so.6 -> libncursesw.so.6"
    fi
    if [ ! -e "$lib_dir/libtinfo.so.6" ] && [ -e /usr/lib/libncursesw.so.6 ]; then
        ln -sf /usr/lib/libncursesw.so.6 "$lib_dir/libtinfo.so.6"
        log "shimmed libtinfo.so.6 -> libncursesw.so.6"
    fi

    # Arch's libxml2 is at soversion 16; the Ubuntu-built Swift links against
    # libxml2.so.2. Best-effort shim — symbol compatibility is good enough for
    # SwiftPM/swift-package, which is the main user of libxml2 here. If Swift
    # ever needs an API that changed between soversions, the user can install
    # libxml2-legacy from AUR; we document that fallback.
    if [ ! -e "$lib_dir/libxml2.so.2" ]; then
        local libxml2_so
        libxml2_so="$(ls /usr/lib/libxml2.so.[0-9]* 2>/dev/null | sort -V | tail -1 || true)"
        if [ -n "$libxml2_so" ]; then
            ln -sf "$libxml2_so" "$lib_dir/libxml2.so.2"
            log "shimmed libxml2.so.2 -> $libxml2_so"
        fi
    fi
}

install_tarball() {
    local url="$1"
    local tarball
    tarball="$(mktemp -t swift-XXXXXX.tar.gz)"

    log "downloading $url"
    curl --fail --location --silent --show-error --output "$tarball" "$url"

    log "extracting to $INSTALL_PREFIX"
    mkdir -p "$INSTALL_PREFIX"
    # The tarball contains a top-level directory named like the release; strip it.
    tar -xzf "$tarball" -C "$INSTALL_PREFIX" --strip-components=1

    rm -f "$tarball"
}

main() {
    local distro id version
    distro="$(detect_distro)"
    id="${distro%% *}"
    version="${distro##* }"
    local target_id="${id}-${version}"

    log "detected distro: $target_id"

    local url
    if ! url="$(tarball_url "$target_id")"; then
        log "no toolchain available for $target_id"
        exit 2
    fi

    if [ "$MODE" = "print-env" ]; then
        print_env
        return
    fi

    if [ "$MODE" = "check" ]; then
        log "would install $SWIFT_RELEASE from $url into $INSTALL_PREFIX"
        return
    fi

    if [ "$SKIP_DEPS" = "0" ]; then
        case "$id" in
            ubuntu) install_deps_ubuntu "$version" ;;
            arch)   install_deps_arch ;;
        esac
    else
        log "SKIP_DEPS=1; skipping package-manager step"
    fi

    install_tarball "$url"

    if [ "$id" = "arch" ]; then
        shim_arch_libs
    fi

    print_env
    log "done — Swift $SWIFT_VERSION installed in $INSTALL_PREFIX"
}

main "$@"
