import CGtk3
import Foundation

// MARK: - The menu-rebuild contract
//
// `rebuildMenu(_:snapshot:)` is the single seam between the pure-Swift
// `MenuSnapshot` model and the GTK widget tree. It is idempotent and safe to
// invoke as many times as needed: every call destroys the current menu items
// and rebuilds them from the snapshot. For the tracer in #13 we call it once
// at startup; future content slices (#17 for real repository rows, #18 for
// notifications, …) re-invoke it every time the underlying snapshot changes.
//
// Action dispatch goes through `@convention(c)` trampolines below — one per
// case in `MenuSnapshot.Action`. The trampolines have no captures, so they
// can be passed as plain function pointers to `g_signal_connect_data`. When
// we eventually need per-item context (e.g. "open this specific URL"), we'll
// switch to a `Box<() -> Void>` pattern; for now the action enum is small
// enough that a static trampoline per case is the simpler design.

/// Reconciles a `GtkMenu`'s children to match `snapshot`. Idempotent.
///
/// On every call this function destroys all existing children (via
/// `gtk_widget_destroy`, which triggers GObject finalization and frees any
/// signal-connection memory) and appends fresh items. GTK accepts a menu
/// being rebuilt while it is attached to an AppIndicator; the indicator
/// picks up the new items on next popup.
func rebuildMenu(_ menu: UnsafeMutablePointer<GtkMenu>, snapshot: MenuSnapshot) {
    let container = UnsafeMutableRawPointer(menu).assumingMemoryBound(to: GtkContainer.self)

    // 1. Destroy existing children. `gtk_container_foreach` walks the live
    //    children list; `gtk_widget_destroy` removes each from the container
    //    and drops the implicit container reference, finalizing the widget.
    gtk_container_foreach(container, { widget, _ in
        if let widget {
            gtk_widget_destroy(widget)
        }
    }, nil)

    // 2. Build fresh children from the snapshot.
    let shell = UnsafeMutableRawPointer(menu).assumingMemoryBound(to: GtkMenuShell.self)
    for row in snapshot.rows {
        let child: UnsafeMutablePointer<GtkWidget>
        switch row {
        case .separator:
            guard let sep = gtk_separator_menu_item_new() else { continue }
            child = sep
        case let .item(label, enabled, action):
            guard let item = gtk_menu_item_new_with_label(label) else { continue }
            gtk_widget_set_sensitive(item, enabled ? gboolean(1) : gboolean(0))
            if let action {
                attachActivate(item, action: action)
            }
            child = item
        }
        gtk_menu_shell_append(shell, child)
        gtk_widget_show(child)
    }
}

// MARK: - Action wiring

/// Connects the appropriate `@convention(c)` trampoline to a menu item's
/// `activate` signal based on the `Action` case.
private func attachActivate(_ widget: UnsafeMutablePointer<GtkWidget>, action: MenuSnapshot.Action) {
    let trampoline: GCallback = switch action {
    case .quit:
        unsafeBitCast(activateQuit, to: GCallback.self)
    }
    let instance = UnsafeMutableRawPointer(widget)
    g_signal_connect_data(
        instance,
        "activate",
        trampoline,
        nil,
        nil,
        GConnectFlags(rawValue: 0))
}

/// `.quit`: flip the global `shouldQuit` flag. The same `g_timeout_add` source
/// that already polls it for SIGINT / SIGTERM (see `main.swift`) picks this up
/// and tears the main loop down cleanly.
private let activateQuit: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { _, _ in
    shouldQuit = 1
}
