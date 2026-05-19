import CGtk3
import Foundation

// Bridges async-world `SnapshotInbox` posts onto the GLib main thread.
//
// `g_timeout_add` only accepts a `@convention(c)` function pointer (no
// captures), so we keep the inbox + menu pointer in `nonisolated(unsafe)`
// globals. There's only ever one active tray at a time, so a singleton is
// fine. The same pattern is used for `shouldQuit` in `main.swift`.

private nonisolated(unsafe) var snapshotInbox: SnapshotInbox?
private nonisolated(unsafe) var snapshotMenu: UnsafeMutablePointer<GtkMenu>?
private nonisolated(unsafe) var snapshotOpener: URLOpener?
private nonisolated(unsafe) var snapshotLoader: ImageLoader?
private nonisolated(unsafe) var lastRenderedSnapshot: MenuSnapshot?

/// GSourceFunc trampoline. Returns `1` to stay registered.
@_cdecl("repobar_snapshot_poll")
func repobarSnapshotPoll(_ userData: UnsafeMutableRawPointer?) -> Int32 {
    _ = userData
    guard let inbox = snapshotInbox,
          let menu = snapshotMenu,
          let opener = snapshotOpener,
          let loader = snapshotLoader
    else {
        return 1
    }
    guard let snapshot = inbox.consume() else {
        return 1
    }
    // We don't short-circuit on snapshot equality. Two structurally identical
    // posts can carry meaningful new state — most notably, an avatar prefetch
    // run that didn't change the snapshot value but did warm `loader`'s disk
    // cache, so a re-render now shows icons that the previous render couldn't.
    rebuildMenu(menu, snapshot: snapshot, opener: opener, loader: loader)
    lastRenderedSnapshot = snapshot
    return 1
}

/// Registers a 250 ms `g_timeout_add` source that drains `inbox` into
/// `rebuildMenu(_:snapshot:opener:loader:)`. Call once, after the menu is
/// constructed.
///
/// 250 ms is short enough that a click on the tray icon almost always sees
/// the latest snapshot, and long enough that we don't burn CPU when the
/// fetcher is idle. (`g_idle_add` would be lower latency but it's a
/// busy-tick at lowest priority; `g_main_context_invoke` from the async
/// task is the better answer eventually.)
func installMainLoopSnapshotPoller(
    menu: UnsafeMutablePointer<GtkMenu>,
    inbox: SnapshotInbox,
    opener: URLOpener,
    loader: ImageLoader
) {
    snapshotMenu = menu
    snapshotInbox = inbox
    snapshotOpener = opener
    snapshotLoader = loader
    _ = g_timeout_add(250, repobarSnapshotPoll, nil)
}
