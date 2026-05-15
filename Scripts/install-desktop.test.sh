#!/usr/bin/env bash
# Tests for Scripts/install-desktop.sh.
#
# Each test installs into a fresh temp prefix, asserts the expected file
# layout + post-install validation, then exercises --uninstall.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/install-desktop.sh"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0
FAILED_NAMES=()
SIZES=(16 24 32 48 64 128 256 512)

note() { printf '%s\n' "$*"; }

assert_file() {
    local path="$1" name="$2"
    if [[ ! -f "$path" ]]; then
        note "  FAIL ($name): expected file $path"
        return 1
    fi
}

assert_missing() {
    local path="$1" name="$2"
    if [[ -e "$path" ]]; then
        note "  FAIL ($name): expected $path to be gone"
        return 1
    fi
}

run_test() {
    local name="$1"; shift
    note "▶ $name"
    if "$@"; then
        PASS=$((PASS+1))
        note "  PASS"
    else
        FAIL=$((FAIL+1))
        FAILED_NAMES+=("$name")
        note "  FAIL"
    fi
}

# -----------------------------------------------------------------------------

test_install_under_temp_prefix() (
    prefix="$(mktemp -d -t install-desktop-test.XXXXXX)"
    trap 'rm -rf "$prefix"' EXIT

    "$SCRIPT" --prefix "$prefix" --no-cache-update --quiet

    assert_file "$prefix/share/applications/repobar.desktop" install || exit 1
    for size in "${SIZES[@]}"; do
        assert_file "$prefix/share/icons/hicolor/${size}x${size}/apps/repobar.png" install || exit 1
    done
)

test_destdir_separates_stage_from_runtime_prefix() (
    destdir="$(mktemp -d -t install-desktop-destdir.XXXXXX)"
    prefix="/usr"
    trap 'rm -rf "$destdir"' EXIT

    "$SCRIPT" --destdir "$destdir" --prefix "$prefix" --no-cache-update --quiet

    assert_file "$destdir/usr/share/applications/repobar.desktop" destdir || exit 1
    assert_file "$destdir/usr/share/icons/hicolor/256x256/apps/repobar.png" destdir || exit 1
)

test_desktop_file_passes_validate() (
    prefix="$(mktemp -d -t install-desktop-validate.XXXXXX)"
    trap 'rm -rf "$prefix"' EXIT

    "$SCRIPT" --prefix "$prefix" --no-cache-update --quiet
    desktop-file-validate "$prefix/share/applications/repobar.desktop"
)

test_update_desktop_database_succeeds_on_install_tree() (
    prefix="$(mktemp -d -t install-desktop-update.XXXXXX)"
    trap 'rm -rf "$prefix"' EXIT

    "$SCRIPT" --prefix "$prefix" --quiet
    update-desktop-database --quiet "$prefix/share/applications"
    [[ -f "$prefix/share/applications/mimeinfo.cache" ]] || exit 1
)

test_gtk_update_icon_cache_succeeds_on_install_tree() (
    prefix="$(mktemp -d -t install-desktop-iconcache.XXXXXX)"
    trap 'rm -rf "$prefix"' EXIT

    "$SCRIPT" --prefix "$prefix" --no-cache-update --quiet
    # hicolor would normally have an index.theme; we don't ship one because our
    # PNGs merge into the system hicolor namespace. `--ignore-theme-index`
    # lets gtk-update-icon-cache run without one.
    gtk-update-icon-cache --force --ignore-theme-index --quiet \
        "$prefix/share/icons/hicolor"
    [[ -f "$prefix/share/icons/hicolor/icon-theme.cache" ]] || exit 1
)

test_uninstall_removes_all_files() (
    prefix="$(mktemp -d -t install-desktop-uninstall.XXXXXX)"
    trap 'rm -rf "$prefix"' EXIT

    "$SCRIPT" --prefix "$prefix" --no-cache-update --quiet
    "$SCRIPT" --prefix "$prefix" --no-cache-update --uninstall --quiet

    assert_missing "$prefix/share/applications/repobar.desktop" uninstall || exit 1
    for size in "${SIZES[@]}"; do
        assert_missing "$prefix/share/icons/hicolor/${size}x${size}/apps/repobar.png" uninstall || exit 1
    done
)

# -----------------------------------------------------------------------------

run_test "install lands all 9 files under prefix" test_install_under_temp_prefix
run_test "--destdir staging keeps runtime prefix in the path" test_destdir_separates_stage_from_runtime_prefix
run_test "installed .desktop passes desktop-file-validate" test_desktop_file_passes_validate
run_test "update-desktop-database succeeds on the install tree" test_update_desktop_database_succeeds_on_install_tree
run_test "gtk-update-icon-cache succeeds on the install tree" test_gtk_update_icon_cache_succeeds_on_install_tree
run_test "--uninstall removes everything it installed" test_uninstall_removes_all_files

note ""
note "PASS=$PASS  FAIL=$FAIL"
if [[ $FAIL -gt 0 ]]; then
    note "Failed tests:"
    for n in "${FAILED_NAMES[@]}"; do note "  - $n"; done
    exit 1
fi
