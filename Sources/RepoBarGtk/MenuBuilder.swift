import CGtk3
import Foundation

// MARK: - The menu-rebuild contract
//
// `rebuildMenu(_:snapshot:opener:)` is the single seam between the pure-Swift
// `MenuSnapshot` model and the GTK widget tree. It is idempotent and safe to
// invoke as many times as needed: every call destroys the current menu items
// and rebuilds them from the snapshot. Each call also tears down any signal
// handlers attached to the previous widgets, which fires the
// `destroyBoxedAction` notify and frees the per-item closure boxes.
//
// Action dispatch goes through `BoxedAction`, a tiny class whose retained
// pointer is handed to `g_signal_connect_data` as `user_data`. A single
// `@convention(c)` trampoline (`invokeBoxedAction`) unwraps it and runs the
// captured closure. This pattern (vs the per-case static trampoline used in
// #13) is what lets us carry per-item context like the URL to open for an
// `.openURL` action.

/// Reconciles a `GtkMenu`'s children to match `snapshot`. Idempotent.
///
/// `opener` is the `URLOpener` used by `.openURL` actions. `loader` is the
/// avatar cache; we synchronously look up `cachedSync` for each row's
/// `avatarURL` and only render an icon when warm — async fetches kick off
/// elsewhere (in `RepoListController`) and the next rebuild picks them up.
/// Tests can pass a `RecordingURLOpener` / `RecordingImageLoader` to assert
/// what would have been opened / requested.
func rebuildMenu(
    _ menu: UnsafeMutablePointer<GtkMenu>,
    snapshot: MenuSnapshot,
    opener: URLOpener,
    loader: ImageLoader
) {
    let container = UnsafeMutableRawPointer(menu).assumingMemoryBound(to: GtkContainer.self)

    // Destroy existing children. `gtk_container_foreach` walks the live
    // children list; `gtk_widget_destroy` removes each from the container
    // and drops the implicit container reference, finalizing the widget
    // (and any submenus it parents — GTK recurses) and firing any attached
    // `destroyBoxedAction` notifies so we don't leak boxes from the
    // previous snapshot.
    gtk_container_foreach(container, { widget, _ in
        if let widget {
            gtk_widget_destroy(widget)
        }
    }, nil)

    populateMenu(menu, rows: snapshot.rows, opener: opener, loader: loader)
}

/// Build the widgets for `rows` and append them to `menu`.
///
/// `populateMenu` is also called recursively to populate freshly-allocated
/// submenus inside `.submenu` rows.
private func populateMenu(
    _ menu: UnsafeMutablePointer<GtkMenu>,
    rows: [MenuSnapshot.Row],
    opener: URLOpener,
    loader: ImageLoader
) {
    let shell = UnsafeMutableRawPointer(menu).assumingMemoryBound(to: GtkMenuShell.self)
    for row in rows {
        guard let child = buildRow(row, opener: opener, loader: loader) else { continue }
        gtk_menu_shell_append(shell, child)
        // `gtk_widget_show_all` recurses into any child box / image / label
        // we added inside the menu item. `gtk_widget_show` alone would leave
        // a custom-widget icon row blank.
        gtk_widget_show_all(child)
    }
}

private func buildRow(
    _ row: MenuSnapshot.Row,
    opener: URLOpener,
    loader: ImageLoader
) -> UnsafeMutablePointer<GtkWidget>? {
    switch row {
    case .separator:
        return gtk_separator_menu_item_new()
    case let .item(label, enabled, action, avatarURL):
        guard let item = makeMenuItem(label: label, avatarURL: avatarURL, loader: loader) else { return nil }
        gtk_widget_set_sensitive(item, enabled ? gboolean(1) : gboolean(0))
        if let action {
            attachActivate(item, action: action, opener: opener)
        }
        return item
    case let .submenu(label, rows, avatarURL):
        guard let item = makeMenuItem(label: label, avatarURL: avatarURL, loader: loader) else { return nil }
        guard let subMenuWidget = gtk_menu_new() else { return item }
        let subMenu = UnsafeMutableRawPointer(subMenuWidget).assumingMemoryBound(to: GtkMenu.self)
        populateMenu(subMenu, rows: rows, opener: opener, loader: loader)
        let menuItem = UnsafeMutableRawPointer(item).assumingMemoryBound(to: GtkMenuItem.self)
        gtk_menu_item_set_submenu(menuItem, subMenuWidget)
        return item
    }
}

/// Build either a plain text menu item or — if an avatar is available and
/// cached — a custom-widget menu item with a 22×22 icon to the left of the
/// label.
private func makeMenuItem(
    label: String,
    avatarURL: URL?,
    loader: ImageLoader
) -> UnsafeMutablePointer<GtkWidget>? {
    if let avatarURL,
       let data = loader.cachedSync(avatarURL),
       let pixbuf = decodePixbuf(data: data, targetSize: 22)
    {
        defer { g_object_unref(UnsafeMutableRawPointer(pixbuf)) }
        guard let item = gtk_menu_item_new() else { return nil }
        guard let box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6) else { return item }
        guard let image = gtk_image_new_from_pixbuf(pixbuf) else { return item }
        guard let labelWidget = gtk_label_new(label) else { return item }
        let boxContainer = UnsafeMutableRawPointer(box).assumingMemoryBound(to: GtkContainer.self)
        let itemContainer = UnsafeMutableRawPointer(item).assumingMemoryBound(to: GtkContainer.self)
        gtk_container_add(boxContainer, image)
        gtk_container_add(boxContainer, labelWidget)
        gtk_container_add(itemContainer, box)
        return item
    }
    return gtk_menu_item_new_with_label(label)
}

// MARK: - Action wiring

/// Carries a captured closure into a GTK signal handler.
///
/// We hand a retained `Unmanaged` pointer to GTK; the `destroyBoxedAction`
/// notify pairs with the retain and releases when the closure is destroyed
/// (which happens when the menu item is finalized).
private final class BoxedAction {
    let invoke: @Sendable () -> Void
    init(_ invoke: @escaping @Sendable () -> Void) { self.invoke = invoke }
}

private let invokeBoxedAction: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { _, userData in
    guard let userData else { return }
    let box = Unmanaged<BoxedAction>.fromOpaque(userData).takeUnretainedValue()
    box.invoke()
}

private let destroyBoxedAction: @convention(c) (UnsafeMutableRawPointer?, OpaquePointer?) -> Void = { userData, _ in
    guard let userData else { return }
    Unmanaged<BoxedAction>.fromOpaque(userData).release()
}

private func attachActivate(
    _ widget: UnsafeMutablePointer<GtkWidget>,
    action: MenuSnapshot.Action,
    opener: URLOpener
) {
    let box = BoxedAction { [opener] in
        // GTK's signal callbacks fire on the main loop thread. We hand the
        // actual work off to a detached Task so we never block the loop on
        // a `Process` spawn or async URL-open round trip.
        Task.detached {
            await dispatchMenuAction(action, opener: opener)
        }
    }
    let opaque = Unmanaged.passRetained(box).toOpaque()
    let instance = UnsafeMutableRawPointer(widget)
    g_signal_connect_data(
        instance,
        "activate",
        unsafeBitCast(invokeBoxedAction, to: GCallback.self),
        opaque,
        unsafeBitCast(destroyBoxedAction, to: GClosureNotify?.self),
        GConnectFlags(rawValue: 0)
    )
}
