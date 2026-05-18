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
    public indirect enum Row: Equatable, Sendable {
        case item(label: String, enabled: Bool, action: Action?)
        case separator
        /// A row that opens into a nested popup. The submenu items are full
        /// `Row` values themselves, so `.submenu` can recursively contain
        /// `.submenu`. We don't currently have a use for deeper than one
        /// level of nesting — repo rows fan out into issues / PRs / releases
        /// sections and those sections are flat — but the recursion makes the
        /// model uniform and keeps the GTK rebuilder simple.
        case submenu(label: String, rows: [Row])
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

/// Per-repo bundle of the data a tray submenu needs. Built by
/// `RepoListController`'s phase-2 fetch and consumed by
/// `MenuSnapshot.fromRepositoryDetails(_:host:cap:)`.
public struct RepoMenuData: Equatable, Sendable {
    public let repo: Repository
    public let issues: [RepoIssueSummary]
    public let pulls: [RepoPullRequestSummary]
    public let releases: [RepoReleaseSummary]

    public init(
        repo: Repository,
        issues: [RepoIssueSummary] = [],
        pulls: [RepoPullRequestSummary] = [],
        releases: [RepoReleaseSummary] = []
    ) {
        self.repo = repo
        self.issues = issues
        self.pulls = pulls
        self.releases = releases
    }
}

extension MenuSnapshot {
    /// Build a snapshot from a `RepoMenuData` list. Each repo becomes a
    /// `.submenu` whose children are:
    ///
    ///     Open in browser
    ///     ─────────────
    ///     Issues               (disabled header)
    ///       #N <title>         (.openURL action) — or "(no recent issues)"
    ///     ─────────────
    ///     Pull Requests
    ///       #N <title> (draft) — or "(no recent pull requests)"
    ///     ─────────────
    ///     Releases
    ///       <tag> — <name> (prerelease) — or "(no recent releases)"
    ///
    /// Section bodies are capped to `sectionCap` (default 8) so tall submenus
    /// don't dwarf the screen.
    public static func fromRepositoryDetails(
        _ items: [RepoMenuData],
        host: URL = URL(string: "https://github.com")!,
        cap: Int = 50,
        sectionCap: Int = 8
    ) -> MenuSnapshot {
        var rows: [Row] = []
        if items.isEmpty {
            rows.append(.item(label: "No repositories", enabled: false, action: nil))
        } else {
            let visible = items.prefix(cap)
            for item in visible {
                rows.append(self.buildRepoSubmenu(item, host: host, sectionCap: sectionCap))
            }
            if items.count > cap {
                rows.append(.item(
                    label: "… and \(items.count - cap) more",
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

    static func buildRepoSubmenu(
        _ data: RepoMenuData,
        host: URL,
        sectionCap: Int
    ) -> Row {
        let repoURL = host.appending(path: "\(data.repo.owner)/\(data.repo.name)")
        var subRows: [Row] = [
            .item(label: "Open in browser", enabled: true, action: .openURL(repoURL)),
            .separator,
        ]

        subRows.append(.item(label: "Issues", enabled: false, action: nil))
        if data.issues.isEmpty {
            subRows.append(.item(label: "  (no recent issues)", enabled: false, action: nil))
        } else {
            for issue in data.issues.prefix(sectionCap) {
                let label = "  #\(issue.number) \(self.truncated(issue.title, max: 60))"
                subRows.append(.item(label: label, enabled: true, action: .openURL(issue.url)))
            }
        }
        subRows.append(.separator)

        subRows.append(.item(label: "Pull Requests", enabled: false, action: nil))
        if data.pulls.isEmpty {
            subRows.append(.item(label: "  (no recent pull requests)", enabled: false, action: nil))
        } else {
            for pr in data.pulls.prefix(sectionCap) {
                let suffix = pr.isDraft ? " (draft)" : ""
                let label = "  #\(pr.number) \(self.truncated(pr.title, max: 60))\(suffix)"
                subRows.append(.item(label: label, enabled: true, action: .openURL(pr.url)))
            }
        }
        subRows.append(.separator)

        subRows.append(.item(label: "Releases", enabled: false, action: nil))
        if data.releases.isEmpty {
            subRows.append(.item(label: "  (no recent releases)", enabled: false, action: nil))
        } else {
            for rel in data.releases.prefix(sectionCap) {
                let suffix = rel.isPrerelease ? " (prerelease)" : ""
                let name = rel.name.isEmpty ? rel.tag : rel.name
                let label = "  \(rel.tag) — \(self.truncated(name, max: 50))\(suffix)"
                subRows.append(.item(label: label, enabled: true, action: .openURL(rel.url)))
            }
        }

        return .submenu(label: self.repoRowLabel(data.repo), rows: subRows)
    }

    static func truncated(_ string: String, max: Int) -> String {
        if string.count <= max { return string }
        return String(string.prefix(max - 1)) + "…"
    }
}
