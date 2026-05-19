import Foundation
@testable import RepoBarGtk
import RepoBarCore
import Testing

@Suite("MenuSnapshot.fromRepositoryDetails")
struct MenuSnapshotSubmenuTests {
    @Test
    func `top-level row for each repo is a submenu carrying the repo label`() {
        let snapshot = MenuSnapshot.fromRepositoryDetails([
            RepoMenuData(repo: stubRepo(owner: "pmatos", name: "repobar.linux", openIssues: 0, openPulls: 0)),
        ])
        guard case let .submenu(label, _, _) = snapshot.rows.first else {
            Issue.record("expected first row to be a submenu, got \(String(describing: snapshot.rows.first))")
            return
        }
        #expect(label == "pmatos/repobar.linux")
    }

    @Test
    func `submenu opens with an 'Open in browser' .openURL action`() {
        let snapshot = MenuSnapshot.fromRepositoryDetails([
            RepoMenuData(repo: stubRepo(owner: "a", name: "b", openIssues: 0, openPulls: 0)),
        ])
        guard case let .submenu(_, rows, _) = snapshot.rows.first else {
            Issue.record("first row not a submenu")
            return
        }
        #expect(rows.first == .item(
            label: "Open in browser",
            enabled: true,
            action: .openURL(URL(string: "https://github.com/a/b")!)
        ))
    }

    @Test
    func `empty sections render the (no recent X) placeholder rows`() {
        let snapshot = MenuSnapshot.fromRepositoryDetails([
            RepoMenuData(repo: stubRepo(owner: "a", name: "b", openIssues: 0, openPulls: 0)),
        ])
        guard case let .submenu(_, rows, _) = snapshot.rows.first else {
            Issue.record("first row not a submenu")
            return
        }
        let labels = rows.compactMap { row -> String? in
            if case let .item(label, _, _, _) = row { return label }
            return nil
        }
        #expect(labels.contains("  (no recent issues)"))
        #expect(labels.contains("  (no recent pull requests)"))
        #expect(labels.contains("  (no recent releases)"))
    }

    @Test
    func `populated issues emit one openURL row per issue`() {
        let issue = RepoIssueSummary(
            number: 42,
            title: "thing broke",
            url: URL(string: "https://github.com/a/b/issues/42")!,
            updatedAt: Date(),
            authorLogin: "someone",
            authorAvatarURL: nil,
            assigneeLogins: [],
            commentCount: 0,
            labels: []
        )
        let snapshot = MenuSnapshot.fromRepositoryDetails([
            RepoMenuData(
                repo: stubRepo(owner: "a", name: "b", openIssues: 1, openPulls: 0),
                issues: [issue]
            ),
        ])
        guard case let .submenu(_, rows, _) = snapshot.rows.first else {
            Issue.record("first row not a submenu")
            return
        }
        let issueRows = rows.filter { row in
            if case let .item(label, _, _, _) = row {
                return label.contains("#42")
            }
            return false
        }
        #expect(issueRows.count == 1)
        #expect(issueRows.first == .item(
            label: "  #42 thing broke",
            enabled: true,
            action: .openURL(URL(string: "https://github.com/a/b/issues/42")!)
        ))
    }

    @Test
    func `draft pull requests carry a (draft) suffix in their label`() {
        let pr = RepoPullRequestSummary(
            number: 7,
            title: "wip refactor",
            url: URL(string: "https://github.com/a/b/pull/7")!,
            updatedAt: Date(),
            authorLogin: nil,
            authorAvatarURL: nil,
            isDraft: true,
            commentCount: 0,
            reviewCommentCount: 0,
            labels: [],
            headRefName: nil,
            baseRefName: nil
        )
        let snapshot = MenuSnapshot.fromRepositoryDetails([
            RepoMenuData(
                repo: stubRepo(owner: "a", name: "b", openIssues: 0, openPulls: 1),
                pulls: [pr]
            ),
        ])
        guard case let .submenu(_, rows, _) = snapshot.rows.first else {
            Issue.record("first row not a submenu")
            return
        }
        let prRow = rows.first(where: { row in
            if case let .item(label, _, _, _) = row { return label.contains("#7") }
            return false
        })
        guard case let .item(label, _, _, _) = prRow else {
            Issue.record("PR row missing")
            return
        }
        #expect(label.hasSuffix("(draft)"))
    }

    @Test
    func `prerelease releases carry a (prerelease) suffix in their label`() {
        let release = RepoReleaseSummary(
            name: "Beta 1",
            tag: "v0.9-beta",
            url: URL(string: "https://github.com/a/b/releases/tag/v0.9-beta")!,
            publishedAt: Date(),
            isPrerelease: true,
            authorLogin: nil,
            authorAvatarURL: nil,
            assetCount: 0,
            downloadCount: 0,
            assets: []
        )
        let snapshot = MenuSnapshot.fromRepositoryDetails([
            RepoMenuData(
                repo: stubRepo(owner: "a", name: "b", openIssues: 0, openPulls: 0),
                releases: [release]
            ),
        ])
        guard case let .submenu(_, rows, _) = snapshot.rows.first else {
            Issue.record("first row not a submenu")
            return
        }
        let relRow = rows.first(where: { row in
            if case let .item(label, _, _, _) = row { return label.contains("v0.9-beta") }
            return false
        })
        guard case let .item(label, _, _, _) = relRow else {
            Issue.record("release row missing")
            return
        }
        #expect(label.hasSuffix("(prerelease)"))
    }

    @Test
    func `cap truncates and reports overflow with a disabled '… and N more' row`() {
        let repos = (1...55).map { i in
            RepoMenuData(repo: stubRepo(owner: "o", name: "r\(i)", openIssues: 0, openPulls: 0))
        }
        let snapshot = MenuSnapshot.fromRepositoryDetails(repos, cap: 50)
        let labels = snapshot.rows.compactMap { row -> String? in
            if case let .item(label, _, _, _) = row { return label }
            return nil
        }
        #expect(labels.contains("… and 5 more"))
    }

    @Test
    func `empty repo list produces 'No repositories' (not a stray submenu)`() {
        let snapshot = MenuSnapshot.fromRepositoryDetails([])
        #expect(snapshot.rows.first == .item(label: "No repositories", enabled: false, action: nil))
    }

    @Test
    func `section cap limits items per section`() {
        let issues = (1...20).map { i in
            RepoIssueSummary(
                number: i,
                title: "issue \(i)",
                url: URL(string: "https://github.com/a/b/issues/\(i)")!,
                updatedAt: Date(),
                authorLogin: nil,
                authorAvatarURL: nil,
                assigneeLogins: [],
                commentCount: 0,
                labels: []
            )
        }
        let snapshot = MenuSnapshot.fromRepositoryDetails(
            [RepoMenuData(repo: stubRepo(owner: "a", name: "b", openIssues: 1, openPulls: 0), issues: issues)],
            sectionCap: 5
        )
        guard case let .submenu(_, rows, _) = snapshot.rows.first else {
            Issue.record("first row not a submenu")
            return
        }
        let issueRows = rows.filter { row in
            if case let .item(label, _, _, _) = row {
                return label.contains("#") && label.contains("issue")
            }
            return false
        }
        #expect(issueRows.count == 5)
    }
}

private func stubRepo(
    owner: String,
    name: String,
    openIssues: Int,
    openPulls: Int
) -> Repository {
    Repository(
        id: "\(owner)/\(name)",
        name: name,
        owner: owner,
        sortOrder: nil,
        error: nil,
        rateLimitedUntil: nil,
        ciStatus: .unknown,
        openIssues: openIssues,
        openPulls: openPulls,
        latestRelease: nil,
        latestActivity: nil,
        traffic: nil,
        heatmap: []
    )
}
