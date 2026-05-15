#!/usr/bin/env bash
# Install (or uninstall) RepoBar's Linux desktop integration: the .desktop
# entry, the hicolor icon set, and the systemd user service unit.
#
# Usage:
#   Scripts/install-desktop.sh [--prefix PREFIX] [--destdir DESTDIR]
#                              [--bindir BINDIR]
#                              [--uninstall] [--no-cache-update] [--quiet]
#
#   --prefix PREFIX         Install under PREFIX/share/... (default /usr/local).
#                           For a packaging build use --prefix /usr.
#   --destdir DESTDIR       Stage files under DESTDIR + PREFIX rather than
#                           writing to PREFIX directly. Useful for PKGBUILD,
#                           debian/rules, fakeroot, etc.
#   --bindir BINDIR         Where the RepoBarGtk binary will live at runtime.
#                           Substituted into the systemd unit's ExecStart=.
#                           Default: PREFIX/bin.
#   --uninstall             Remove the files this script would have installed.
#   --no-cache-update       Skip update-desktop-database and gtk-update-icon-cache
#                           after the install. Packagers always want this
#                           (the package manager runs the caches post-install).
#   --quiet                 Less chatter on stdout. Errors still go to stderr.
#
# Files placed (or removed):
#   PREFIX/share/applications/repobar.desktop
#   PREFIX/share/icons/hicolor/<size>x<size>/apps/repobar.png  (for 16..512)
#   PREFIX/share/systemd/user/repobar.service

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PREFIX="/usr/local"
DESTDIR=""
BINDIR=""
ACTION="install"
RUN_CACHE=1
QUIET=0
SIZES=(16 24 32 48 64 128 256 512)

while [[ $# -gt 0 ]]; do
    case "$1" in
        --prefix)
            PREFIX="$2"; shift 2 ;;
        --prefix=*)
            PREFIX="${1#--prefix=}"; shift ;;
        --destdir)
            DESTDIR="$2"; shift 2 ;;
        --destdir=*)
            DESTDIR="${1#--destdir=}"; shift ;;
        --bindir)
            BINDIR="$2"; shift 2 ;;
        --bindir=*)
            BINDIR="${1#--bindir=}"; shift ;;
        --uninstall)
            ACTION="uninstall"; shift ;;
        --no-cache-update)
            RUN_CACHE=0; shift ;;
        --quiet)
            QUIET=1; shift ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *)
            echo "error: unknown argument: $1" >&2; exit 2 ;;
    esac
done

# DESTDIR + PREFIX is the staging path; PREFIX alone is the runtime path the
# files will live at after the package is installed. update-{desktop,icon}
# operate on the staging tree when DESTDIR is set.
STAGE="${DESTDIR}${PREFIX}"
# BINDIR defaults to PREFIX/bin and is substituted at runtime — it must be the
# *runtime* path, not the staged path, because that's where the binary will
# live when systemd reads the unit.
: "${BINDIR:=${PREFIX}/bin}"
say() { [[ $QUIET -eq 1 ]] || echo "$1"; }

install_one() {
    local src="$1" dst="$2"
    mkdir -p "$(dirname "$dst")"
    install -m 0644 "$src" "$dst"
    say "  install $dst"
}

install_systemd_unit() {
    local src="$REPO_ROOT/share/systemd/user/repobar.service.in"
    local dst="$STAGE/share/systemd/user/repobar.service"
    mkdir -p "$(dirname "$dst")"
    # Substitute @BINDIR@ → BINDIR. Using a sentinel that cannot appear in
    # legitimate paths means we don't have to escape sed metacharacters on the
    # replacement side. We use # as the delimiter so paths with / pass through.
    sed "s#@BINDIR@#${BINDIR}#g" "$src" > "$dst"
    chmod 0644 "$dst"
    say "  install $dst (BINDIR=$BINDIR)"
}

remove_one() {
    local dst="$1"
    if [[ -e "$dst" ]]; then
        rm -f "$dst"
        say "  remove  $dst"
    fi
}

if [[ "$ACTION" == "install" ]]; then
    say "Installing RepoBar desktop files into ${STAGE} ..."
    install_one "$REPO_ROOT/share/applications/repobar.desktop" \
                "$STAGE/share/applications/repobar.desktop"
    for size in "${SIZES[@]}"; do
        install_one "$REPO_ROOT/share/icons/hicolor/${size}x${size}/apps/repobar.png" \
                    "$STAGE/share/icons/hicolor/${size}x${size}/apps/repobar.png"
    done
    install_systemd_unit

    if [[ $RUN_CACHE -eq 1 ]]; then
        if command -v update-desktop-database >/dev/null 2>&1; then
            say "Updating desktop database ..."
            update-desktop-database -q "$STAGE/share/applications" || true
        fi
        if command -v gtk-update-icon-cache >/dev/null 2>&1; then
            say "Updating icon cache ..."
            gtk-update-icon-cache --force --quiet "$STAGE/share/icons/hicolor" || true
        fi
    fi
    say "Done."
else
    say "Uninstalling RepoBar desktop files from ${STAGE} ..."
    remove_one "$STAGE/share/applications/repobar.desktop"
    for size in "${SIZES[@]}"; do
        remove_one "$STAGE/share/icons/hicolor/${size}x${size}/apps/repobar.png"
    done
    remove_one "$STAGE/share/systemd/user/repobar.service"
    # Best-effort: drop now-empty hicolor/<size>/apps, hicolor/<size>, and
    # systemd/user dirs.
    for size in "${SIZES[@]}"; do
        rmdir --ignore-fail-on-non-empty "$STAGE/share/icons/hicolor/${size}x${size}/apps" 2>/dev/null || true
        rmdir --ignore-fail-on-non-empty "$STAGE/share/icons/hicolor/${size}x${size}" 2>/dev/null || true
    done
    rmdir --ignore-fail-on-non-empty "$STAGE/share/icons/hicolor" 2>/dev/null || true
    rmdir --ignore-fail-on-non-empty "$STAGE/share/icons" 2>/dev/null || true
    rmdir --ignore-fail-on-non-empty "$STAGE/share/applications" 2>/dev/null || true
    rmdir --ignore-fail-on-non-empty "$STAGE/share/systemd/user" 2>/dev/null || true
    rmdir --ignore-fail-on-non-empty "$STAGE/share/systemd" 2>/dev/null || true
    if [[ $RUN_CACHE -eq 1 ]]; then
        if command -v update-desktop-database >/dev/null 2>&1 && [[ -d "$STAGE/share/applications" ]]; then
            update-desktop-database -q "$STAGE/share/applications" || true
        fi
    fi
    say "Done."
fi
