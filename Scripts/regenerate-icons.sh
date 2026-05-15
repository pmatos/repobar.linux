#!/usr/bin/env bash
# Regenerate the hicolor PNG icon set from the 1024×1024 master that lives in
# the submodule (`repobar/Icon.icon/Assets/repobaricon.png`).
#
# Hicolor sizes follow the freedesktop Icon Theme Specification's recommended
# rasters for application icons:
#   https://specifications.freedesktop.org/icon-theme-spec/latest/
#
# Re-run this whenever the master PNG changes. The generated PNGs are checked
# in (so distro packagers don't need ImageMagick at build time) — running this
# is purely a maintenance step before a commit that updates the master.
#
# Usage: Scripts/regenerate-icons.sh [--check]
#   --check    Regenerate to a temp dir and diff against the committed PNGs;
#              exit 0 if identical, non-zero otherwise. Useful for CI.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$REPO_ROOT/repobar/Icon.icon/Assets/repobaricon.png"
OUT_BASE="$REPO_ROOT/share/icons/hicolor"
SIZES=(16 24 32 48 64 128 256 512)

if [[ ! -f "$SOURCE" ]]; then
    echo "error: master icon not found at $SOURCE" >&2
    echo "       did you forget 'git submodule update --init'?" >&2
    exit 1
fi

if ! command -v magick >/dev/null 2>&1; then
    echo "error: ImageMagick (magick) is required" >&2
    exit 1
fi

CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

generate_into() {
    local base="$1"
    for size in "${SIZES[@]}"; do
        local dir="$base/${size}x${size}/apps"
        mkdir -p "$dir"
        magick "$SOURCE" -resize "${size}x${size}" -strip "$dir/repobar.png"
    done
}

if [[ $CHECK -eq 1 ]]; then
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    generate_into "$tmp"
    if ! diff -qr "$tmp" "$OUT_BASE" >/dev/null; then
        echo "Generated icons differ from committed PNGs:" >&2
        diff -r "$tmp" "$OUT_BASE" || true
        exit 1
    fi
    echo "All hicolor sizes match the master."
else
    generate_into "$OUT_BASE"
    echo "Regenerated:"
    for size in "${SIZES[@]}"; do
        echo "  $OUT_BASE/${size}x${size}/apps/repobar.png"
    done
fi
