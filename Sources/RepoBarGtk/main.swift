import CAyatanaAppIndicator
import CGtk3
import Foundation
#if canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

// MARK: - SIGINT / SIGTERM handling

// The GLib main loop runs on the main thread. POSIX signal handlers and
// GObject signal trampolines (see `MenuBuilder.swift`'s `activateQuit`) both
// flip a shared `sig_atomic_t` flag; a `g_timeout_add` source polls it and
// tears the loop down on the next tick. Crude, but cheap, and avoids needing
// `g_unix_signal_add` (which would pull in glib-unix.h) or a separate exit
// path for "user clicked Quit" vs "user hit Ctrl-C".
nonisolated(unsafe) var shouldQuit: sig_atomic_t = 0
private nonisolated(unsafe) var activeLoop: OpaquePointer?

@_cdecl("repobar_signal_handler")
func repobarSignalHandler(_ signum: Int32) {
    _ = signum
    shouldQuit = 1
}

// GSourceFunc trampoline: a C-compatible function pointer, no captures.
@_cdecl("repobar_quit_poll")
func repobarQuitPoll(_ userData: UnsafeMutableRawPointer?) -> Int32 {
    _ = userData
    if shouldQuit != 0 {
        if let target = activeLoop {
            g_main_loop_quit(target)
        }
        return 0 // remove the source
    }
    return 1 // keep polling
}

// MARK: - Main

func main() -> Int32 {
    // libayatana-appindicator3 sits on top of GTK3 internally (icon theme
    // lookup, GObject signals). It is *not* optional: without `gtk_init` the
    // indicator emits `gtk_icon_theme_get_for_screen: GDK_IS_SCREEN failed`
    // critical warnings and never publishes its SNI item. We initialize GTK3
    // but never construct a widget — the tracer is a headless GLib loop.
    var argc: Int32 = 0
    var argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>? = nil
    if gtk_init_check(&argc, &argv) == 0 {
        let message = "RepoBarGtk: gtk_init_check failed (no display?)\n"
        message.withCString { FileHandle.standardError.write(Data(bytes: $0, count: strlen($0))) }
        return 1
    }

    // The icon name resolves against the active XDG icon theme. The hicolor
    // PNGs shipped by `Scripts/install-desktop.sh` (16–512 px) land under
    // `share/icons/hicolor/<size>/apps/repobar.png`; if the assets are not
    // installed, libayatana-appindicator3 falls back to the freedesktop
    // missing-image placeholder rather than crashing.
    guard let indicator = app_indicator_new(
        "com.steipete.repobar.linux",
        "repobar",
        APP_INDICATOR_CATEGORY_APPLICATION_STATUS
    ) else {
        let message = "RepoBarGtk: failed to construct AppIndicator\n"
        message.withCString { FileHandle.standardError.write(Data(bytes: $0, count: strlen($0))) }
        return 1
    }

    // The indicator owns its menu. `gtk_menu_new` returns a `GtkWidget *`;
    // `app_indicator_set_menu` wants `GtkMenu *`. In C that's the `GTK_MENU()`
    // cast macro. From Swift we rebind the typed pointer — safe because
    // `gtk_menu_new` always returns a `GtkMenu` instance.
    guard let menuWidget = gtk_menu_new() else {
        let message = "RepoBarGtk: gtk_menu_new returned NULL\n"
        message.withCString { FileHandle.standardError.write(Data(bytes: $0, count: strlen($0))) }
        return 1
    }
    let menu = UnsafeMutableRawPointer(menuWidget).assumingMemoryBound(to: GtkMenu.self)
    app_indicator_set_menu(indicator, menu)

    // Initial render: show "Loading repositories…" until the controller's
    // first fetch lands a real snapshot via the inbox. We still rebuild
    // twice up front so the destroy-and-rebuild leak path from #13 gets
    // exercised before any user interaction; GTK widgets removed via
    // `gtk_widget_destroy` are finalized synchronously by GObject and an
    // unbounded leak would show up immediately.
    let opener: URLOpener = SystemURLOpener()
    let loader: ImageLoader = DiskImageCache()
    rebuildMenu(menu, snapshot: .loading, opener: opener, loader: loader)
    rebuildMenu(menu, snapshot: .loading, opener: opener, loader: loader)

    app_indicator_set_status(indicator, APP_INDICATOR_STATUS_ACTIVE)
    app_indicator_set_title(indicator, "RepoBar")

    // Bridge: an inbox lets the async fetch Task push snapshots back to
    // the main loop, and a 250 ms timeout source drains it.
    let inbox = SnapshotInbox()
    installMainLoopSnapshotPoller(menu: menu, inbox: inbox, opener: opener, loader: loader)
    let controller = RepoListController(inbox: inbox, loader: loader)
    Task.detached { await controller.refresh() }

    // SIGINT (Ctrl-C) and SIGTERM (systemctl --user stop) walk us to a clean
    // exit. SIGPIPE we ignore.
    signal(SIGINT, repobarSignalHandler)
    signal(SIGTERM, repobarSignalHandler)
    signal(SIGPIPE, SIG_IGN)

    let loop = g_main_loop_new(nil, gboolean(0))
    defer { g_main_loop_unref(loop) }
    activeLoop = loop
    defer { activeLoop = nil }

    // Poll the signal flag every 100 ms.
    _ = g_timeout_add(100, repobarQuitPoll, nil)

    g_main_loop_run(loop)
    return 0
}

exit(main())
