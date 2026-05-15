import CAyatanaAppIndicator
import CGtk3
import Foundation
#if canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

// MARK: - SIGINT / SIGTERM handling

// The GLib main loop runs on the main thread. POSIX signal handlers cannot
// touch GObject state from inside the handler, so we just flip a `sig_atomic_t`
// flag and have a `g_timeout_add` source poll it. Crude, but cheap, and avoids
// needing glib-unix.h.
private nonisolated(unsafe) var shouldQuit: sig_atomic_t = 0
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

    // The icon name resolves against the active XDG icon theme. For the
    // tracer we use a name that every standard theme carries; a custom
    // hicolor icon ships with the .desktop file work in a later issue.
    guard let indicator = app_indicator_new(
        "com.steipete.repobar.linux",
        "applications-utilities",
        APP_INDICATOR_CATEGORY_APPLICATION_STATUS
    ) else {
        let message = "RepoBarGtk: failed to construct AppIndicator\n"
        message.withCString { FileHandle.standardError.write(Data(bytes: $0, count: strlen($0))) }
        return 1
    }

    // libayatana-appindicator3 quirk: it will not export its StatusNotifierItem
    // on D-Bus until a `GtkMenu` is attached, even if the menu is empty. The
    // tracer is "icon only" by spec, so we attach a deliberately empty menu;
    // the real menu lands in issue #13. Without this, the indicator silently
    // fails to register with `org.kde.StatusNotifierWatcher` and no SNI host
    // (Quickshell, Plasma, GNOME-AppIndicator-extension, …) renders the icon.
    // `gtk_menu_new` returns a `GtkWidget *`; the indicator wants `GtkMenu *`.
    // In C that's the `GTK_MENU()` cast macro. From Swift the equivalent is to
    // rebind the opaque pointer to the menu type — safe because GtkMenu is a
    // subclass of GtkWidget and gtk_menu_new always returns a GtkMenu instance.
    guard let menuWidget = gtk_menu_new() else {
        let message = "RepoBarGtk: gtk_menu_new returned NULL\n"
        message.withCString { FileHandle.standardError.write(Data(bytes: $0, count: strlen($0))) }
        return 1
    }
    let menu = UnsafeMutableRawPointer(menuWidget).assumingMemoryBound(to: GtkMenu.self)
    app_indicator_set_menu(indicator, menu)

    app_indicator_set_status(indicator, APP_INDICATOR_STATUS_ACTIVE)
    app_indicator_set_title(indicator, "RepoBar")

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
