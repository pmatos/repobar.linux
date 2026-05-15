/// Declarative description of the tray popup menu, decoupled from GTK.
///
/// The GTK side (`rebuildMenu(_:snapshot:)`) reconciles a `GtkMenu`'s children
/// against this model. Future content slices — real repository rows (#17),
/// per-repo submenus (#22), notifications (#18), and so on — produce new
/// `MenuSnapshot` values from `RepoBarCore` data and hand them to the
/// rebuilder; the rebuilder is the only code that knows about GTK widgets.
///
/// Why a snapshot instead of imperative menu mutation:
///
/// - We can diff snapshots, log them, golden-test them, and round-trip them
///   through tests without touching GTK.
/// - The producer (GitHub data fetcher) and the consumer (GTK rebuilder) stay
///   pleasantly ignorant of each other.
/// - On macOS the same `MenuSnapshot` shape will drive `NSMenu` rebuilds when
///   we eventually share this model with `RepoBarCore`.
public struct MenuSnapshot: Equatable, Sendable {
    public let rows: [Row]

    public init(rows: [Row]) {
        self.rows = rows
    }
}

extension MenuSnapshot {
    public enum Row: Equatable, Sendable {
        case item(label: String, enabled: Bool, action: Action?)
        case separator
    }

    /// A user-visible action that a menu row can trigger. Each new case lands
    /// alongside a `@convention(c)` trampoline in `MenuBuilder.swift` so that
    /// the GTK rebuilder can wire it into `g_signal_connect_data`.
    public enum Action: Equatable, Sendable {
        case quit
    }
}

extension MenuSnapshot {
    /// Static placeholder shape mandated by issue #13: the tracer for the
    /// menu rebuild path before any GitHub data exists. The first two rows
    /// are disabled because they will be replaced by real content in #17
    /// (`Repositories` becomes a submenu of repos) and #24 (`Preferences…`
    /// opens the settings window).
    public static let staticPlaceholder = MenuSnapshot(rows: [
        .item(label: "Repositories", enabled: false, action: nil),
        .separator,
        .item(label: "Preferences…", enabled: false, action: nil),
        .item(label: "Quit RepoBar", enabled: true, action: .quit),
    ])
}
