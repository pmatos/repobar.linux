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
    private let cap: Int

    public init(inbox: SnapshotInbox, cap: Int = 50) {
        self.inbox = inbox
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
        do {
            let client = try await self.makeClient(for: source)
            let repos = try await client.repositoryList(limit: self.cap)
            self.inbox.post(.fromRepositories(repos, cap: self.cap))
        } catch {
            self.inbox.post(.error(self.displayMessage(for: error)))
        }
    }

    private func makeClient(for source: TrayAuthSource) async throws -> GitHubClient {
        let settings = SettingsStore().load()
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
