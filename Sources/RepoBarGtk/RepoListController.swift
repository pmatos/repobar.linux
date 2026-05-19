import Foundation
import RepoBarCore

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Last-writer-wins drop slot for `MenuSnapshot` updates produced off the
/// GLib main loop.
///
/// `RepoListController` posts here from an async `Task`; the main-loop
/// polling source installed by `installMainLoopSnapshotPoller` consumes
/// pending values and feeds them to `rebuildMenu`. One slot is enough — the
/// consumer only cares about the latest state and the producer fetches at
/// human time scales (seconds, not microseconds).
public final class SnapshotInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: MenuSnapshot?

    public init() {}

    public func post(_ snapshot: MenuSnapshot) {
        self.lock.lock()
        self.pending = snapshot
        self.lock.unlock()
    }

    public func consume() -> MenuSnapshot? {
        self.lock.lock()
        defer { self.lock.unlock() }
        let value = self.pending
        self.pending = nil
        return value
    }
}

/// Tray-side equivalent of the CLI's `resolveCLIAuthSource` (which lives
/// inside the `repobarcli` target and is therefore not visible from
/// `RepoBarGtk`). Promotes the same three-stage precedence: `GITHUB_TOKEN`
/// env var first, then stored OAuth tokens, then a stored PAT. If this
/// drifts away from the CLI's behaviour, fix it in both places.
public enum TrayAuthSource: Equatable, Sendable {
    case envToken(String)
    case storedOAuth
    case storedPAT(String)
    case unauthenticated
}

public func resolveTrayAuthSource(
    env: [String: String] = ProcessInfo.processInfo.environment,
    hasOAuth: Bool = (try? TokenStore.shared.load()) != nil,
    pat: String? = try? TokenStore.shared.loadPAT()
) -> TrayAuthSource {
    let envToken = env["GITHUB_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if envToken.isEmpty == false {
        return .envToken(envToken)
    }
    if hasOAuth {
        return .storedOAuth
    }
    if let pat, pat.isEmpty == false {
        return .storedPAT(pat)
    }
    return .unauthenticated
}

/// Owns the `GitHubClient` and refreshes the tray's repository list.
///
/// Today the controller does a single fetch when `refresh()` is awaited.
/// Subsequent slices (a periodic refresh tick wired into
/// `UserSettings.refreshInterval`) extend this without changing the inbox
/// contract.
public actor RepoListController {
    private let inbox: SnapshotInbox
    private let loader: ImageLoader
    private let cap: Int

    public init(inbox: SnapshotInbox, loader: ImageLoader, cap: Int = 50) {
        self.inbox = inbox
        self.loader = loader
        self.cap = cap
    }

    /// One-shot refresh. Posts one of `.signedOut`, `.fromRepositories(...)`,
    /// or `.error(...)` to the inbox depending on auth state and fetch
    /// outcome. Never throws — callers don't have a sensible recovery path
    /// from inside an async `Task` and the inbox is the channel for failure
    /// surfacing.
    public func refresh() async {
        let source = resolveTrayAuthSource()
        if case .unauthenticated = source {
            self.inbox.post(.signedOut)
            return
        }
        let settings = SettingsStore().load()
        let webHost = settings.enterpriseHost ?? settings.githubHost
        do {
            let client = try await self.makeClient(for: source, settings: settings)
            let repos = try await client.repositoryList(limit: self.cap)
            // Phase 1: flat list of clickable repo rows. Lands fast so the
            // tray menu is usable while we go fetch the per-repo details.
            self.inbox.post(.fromRepositories(repos, host: webHost, cap: self.cap))

            // Avatar prefetch: pull owner avatars in parallel so the next
            // rebuild can render them. The DiskImageCache dedupes and serves
            // from disk on subsequent runs, so this is cheap once warm.
            await Self.prefetchOwnerAvatars(repos: repos, loader: self.loader)
            // Re-post the same flat snapshot to nudge the main-loop poller
            // into re-rendering now that the avatars are cached. The
            // snapshot-equality short-circuit in MainLoopBridge means we
            // need a value-distinct snapshot to trigger; passing the same
            // value is fine because the poller drops it.
            self.inbox.post(.fromRepositories(repos, host: webHost, cap: self.cap))

            // Phase 2: per-repo recent issues / PRs / releases in parallel.
            // Per-repo failures are swallowed — a single 404 or rate-limited
            // repo shouldn't gut the rest of the snapshot.
            let details = await Self.fetchAllDetails(repos: repos, client: client)
            self.inbox.post(.fromRepositoryDetails(details, host: webHost, cap: self.cap))
        } catch {
            self.inbox.post(.error(self.displayMessage(for: error)))
        }
    }

    /// Pull owner avatars in parallel from `https://github.com/<owner>.png`.
    /// Errors are swallowed; a missing avatar just means the row renders
    /// without an icon (the loader returns nil from `cachedSync`).
    static func prefetchOwnerAvatars(repos: [Repository], loader: ImageLoader) async {
        await withTaskGroup(of: Void.self) { group in
            // Dedup by owner; the same org appears in many rows.
            var seen = Set<String>()
            for repo in repos where seen.insert(repo.owner).inserted {
                guard let url = MenuSnapshot.ownerAvatarURL(owner: repo.owner) else { continue }
                group.addTask { _ = try? await loader.load(url) }
            }
            for await _ in group {}
        }
    }

    /// Fetch recent issues / PRs / releases for every repo in parallel.
    /// Results are returned in the same order as `repos`. Per-repo errors
    /// degrade to empty lists; cache-first behavior in RepoBarCore keeps
    /// the per-tick cost manageable.
    static func fetchAllDetails(repos: [Repository], client: GitHubClient) async -> [RepoMenuData] {
        await withTaskGroup(of: (Int, RepoMenuData).self) { group in
            for (index, repo) in repos.enumerated() {
                group.addTask {
                    let owner = repo.owner
                    let name = repo.name
                    // The three endpoints are independent, so kick them off
                    // concurrently via `async let`; the constructor then
                    // awaits them in any order (they finish independently).
                    async let issues: [RepoIssueSummary] =
                        (try? await client.recentIssues(owner: owner, name: name, limit: 8)) ?? []
                    async let pulls: [RepoPullRequestSummary] =
                        (try? await client.recentPullRequests(owner: owner, name: name, limit: 8)) ?? []
                    async let releases: [RepoReleaseSummary] =
                        (try? await client.recentReleases(owner: owner, name: name, limit: 8)) ?? []
                    let data = RepoMenuData(
                        repo: repo,
                        issues: await issues,
                        pulls: await pulls,
                        releases: await releases
                    )
                    return (index, data)
                }
            }
            var collected: [(Int, RepoMenuData)] = []
            for await item in group {
                collected.append(item)
            }
            collected.sort { $0.0 < $1.0 }
            return collected.map { $0.1 }
        }
    }

    private func makeClient(for source: TrayAuthSource, settings: UserSettings) async throws -> GitHubClient {
        let host = settings.enterpriseHost ?? settings.githubHost
        let apiHost: URL = if let enterprise = settings.enterpriseHost {
            enterprise.appending(path: "/api/v3")
        } else {
            RepoBarAuthDefaults.apiHost
        }
        let client = GitHubClient()
        await client.setAPIHost(apiHost)
        switch source {
        case let .envToken(token):
            await client.setTokenProvider { @Sendable in
                OAuthTokens(accessToken: token, refreshToken: "", expiresAt: nil)
            }
        case .storedOAuth:
            await client.setTokenProvider { @Sendable in
                try await OAuthTokenRefresher().refreshIfNeeded(host: host)
            }
        case let .storedPAT(token):
            await client.setTokenProvider { @Sendable in
                OAuthTokens(accessToken: token, refreshToken: "", expiresAt: nil)
            }
        case .unauthenticated:
            throw URLError(.userAuthenticationRequired)
        }
        return client
    }

    private func displayMessage(for error: Error) -> String {
        // A menu row gets one line of text; collapse the error to its first
        // line and clip to a length that won't push the popup wider than the
        // SNI menu typically wants to render.
        let raw = String(describing: error)
        let firstLine = raw.split(separator: "\n").first.map(String.init) ?? raw
        let maxLen = 120
        if firstLine.count > maxLen {
            return String(firstLine.prefix(maxLen)) + "…"
        }
        return firstLine
    }
}
