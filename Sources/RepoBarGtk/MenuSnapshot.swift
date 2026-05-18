import Foundation
import RepoBarCore

/// Declarative description of the tray popup menu, decoupled from GTK.
///
/// The GTK side (`rebuildMenu(_:snapshot:)`) reconciles a `GtkMenu`'s children
/// against this model. Future content slices — per-repo submenus (#22),
/// notifications (#18), and so on — produce new `MenuSnapshot` values from
/// `RepoBarCore` data and hand them to the rebuilder; the rebuilder is the
/// only code that knows about GTK widgets.
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

    /// A user-visible action that a menu row can trigger. Cases are
    /// interpreted by `dispatchMenuAction(_:opener:)`; the GTK rebuilder
    /// wraps each into a boxed closure and wires it into
    /// `g_signal_connect_data` with a `destroy_notify` that releases the box.
    public enum Action: Equatable, Sendable {
        case quit
        case openURL(URL)
    }
}

extension MenuSnapshot {
    /// Static placeholder shape mandated by issue #13: the tracer for the
    /// menu rebuild path before any GitHub data exists. Now superseded for
    /// runtime use by the auth-aware factories below (`.signedOut`, `.loading`,
    /// `.fromRepositories(_:cap:)`), but kept around for backwards-compatible
    /// menu-rebuild tests.
    public static let staticPlaceholder = MenuSnapshot(rows: [
        .item(label: "Repositories", enabled: false, action: nil),
        .separator,
        .item(label: "Preferences…", enabled: false, action: nil),
        .item(label: "Quit RepoBar", enabled: true, action: .quit),
    ])

    /// Shown before any data has arrived from `RepoBarCore`. The first slice
    /// where this appears is the gap between `app_indicator_set_status(ACTIVE)`
    /// and the first successful `repositoryList` response.
    public static let loading = MenuSnapshot(rows: [
        .item(label: "Loading repositories…", enabled: false, action: nil),
        .separator,
        .item(label: "Preferences…", enabled: false, action: nil),
        .item(label: "Quit RepoBar", enabled: true, action: .quit),
    ])

    /// Shown when no credentials are configured (no `GITHUB_TOKEN`, no stored
    /// OAuth tokens, no stored PAT). Today the user has to run `repobar login`
    /// or `repobar import-gh-token` in a terminal — #24 will eventually add an
    /// in-tray sign-in path.
    public static let signedOut = MenuSnapshot(rows: [
        .item(label: "Not signed in", enabled: false, action: nil),
        .item(label: "Run `repobar login` to sign in", enabled: false, action: nil),
        .separator,
        .item(label: "Preferences…", enabled: false, action: nil),
        .item(label: "Quit RepoBar", enabled: true, action: .quit),
    ])

    /// Shown when the fetch fails (network down, GitHub returning 5xx, token
    /// revoked, etc). The error text is collapsed onto one disabled row so the
    /// menu remains scannable.
    public static func error(_ message: String) -> MenuSnapshot {
        MenuSnapshot(rows: [
            .item(label: "Couldn't load repositories", enabled: false, action: nil),
            .item(label: message, enabled: false, action: nil),
            .separator,
            .item(label: "Preferences…", enabled: false, action: nil),
            .item(label: "Quit RepoBar", enabled: true, action: .quit),
        ])
    }

    /// Build a snapshot from a `RepoBarCore` repository list.
    ///
    /// - Rows show `owner/name — Ni Np` where `Ni` is open-issue count and
    ///   `Np` is open-PR count. Counts are suppressed when both are zero so
    ///   quiet repos don't visually shout.
    /// - Rows are enabled and carry an `.openURL` action pointing at
    ///   `host/owner/name`. The action is dispatched through the URLOpener
    ///   (`xdg-open` on real installs). Per-repo submenus (issues, PRs,
    ///   releases) follow in #22.
    /// - The list is truncated to `cap` (default 50, matching the issue spec).
    ///   A trailing disabled row reports the trim when it happens.
    /// - `host` is normally `https://github.com`; enterprise installs feed in
    ///   their own host from `UserSettings.githubHost`.
    public static func fromRepositories(
        _ repos: [Repository],
        host: URL = URL(string: "https://github.com")!,
        cap: Int = 50
    ) -> MenuSnapshot {
        var rows: [Row] = []
        if repos.isEmpty {
            rows.append(.item(label: "No repositories", enabled: false, action: nil))
        } else {
            let visible = repos.prefix(cap)
            for repo in visible {
                let url = host.appending(path: "\(repo.owner)/\(repo.name)")
                rows.append(.item(
                    label: repoRowLabel(repo),
                    enabled: true,
                    action: .openURL(url)
                ))
            }
            if repos.count > cap {
                rows.append(.item(
                    label: "… and \(repos.count - cap) more",
                    enabled: false,
                    action: nil
                ))
            }
        }
        rows.append(.separator)
        rows.append(.item(label: "Preferences…", enabled: false, action: nil))
        rows.append(.item(label: "Quit RepoBar", enabled: true, action: .quit))
        return MenuSnapshot(rows: rows)
    }

    static func repoRowLabel(_ repo: Repository) -> String {
        let issues = repo.openIssues
        let pulls = repo.openPulls
        if issues == 0 && pulls == 0 {
            return repo.fullName
        }
        return "\(repo.fullName) — \(issues)i \(pulls)p"
    }
}
