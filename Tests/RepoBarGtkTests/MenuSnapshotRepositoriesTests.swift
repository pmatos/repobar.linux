@testable import RepoBarGtk
import RepoBarCore
import Testing

@Suite("MenuSnapshot.fromRepositories")
struct MenuSnapshotRepositoriesTests {
    @Test
    func `empty list yields a 'No repositories' disabled row plus controls`() {
        let snapshot = MenuSnapshot.fromRepositories([])
        #expect(snapshot.rows == [
            .item(label: "No repositories", enabled: false, action: nil),
            .separator,
            .item(label: "Preferences…", enabled: false, action: nil),
            .item(label: "Quit RepoBar", enabled: true, action: .quit),
        ])
    }

    @Test
    func `single repo with both counts zero shows just owner-slash-name`() {
        let snapshot = MenuSnapshot.fromRepositories([
            stubRepo(owner: "pmatos", name: "repobar.linux", openIssues: 0, openPulls: 0),
        ])
        #expect(snapshot.rows.first == .item(
            label: "pmatos/repobar.linux", enabled: false, action: nil
        ))
    }

    @Test
    func `repo with nonzero counts shows the 'Ni Np' suffix`() {
        let snapshot = MenuSnapshot.fromRepositories([
            stubRepo(owner: "octo", name: "hello-world", openIssues: 3, openPulls: 1),
        ])
        #expect(snapshot.rows.first == .item(
            label: "octo/hello-world — 3i 1p", enabled: false, action: nil
        ))
    }

    @Test
    func `repo rows are read-only at this stage — no actions`() {
        let snapshot = MenuSnapshot.fromRepositories([
            stubRepo(owner: "a", name: "b", openIssues: 0, openPulls: 0),
        ])
        // The acceptance criteria for #17 explicitly say clicks do nothing
        // yet; #21 / #22 will wire actions in subsequent slices. Encoded as
        // a test so a future change doesn't silently make the rows live
        // without updating the model.
        for row in snapshot.rows {
            switch row {
            case let .item(_, _, action):
                #expect(action == nil || action == .quit)
            case .separator:
                continue
            }
        }
    }

    @Test
    func `cap truncates to the requested limit and reports overflow`() {
        let repos = (1...55).map { i in
            stubRepo(owner: "o", name: "r\(i)", openIssues: 0, openPulls: 0)
        }
        let snapshot = MenuSnapshot.fromRepositories(repos, cap: 50)
        let repoLikeRows = snapshot.rows.prefix(while: { row in
            if case .separator = row { return false }
            return true
        })
        // 50 visible rows + 1 "and N more" disabled row before the separator.
        #expect(repoLikeRows.count == 51)
        #expect(repoLikeRows.last == .item(
            label: "… and 5 more", enabled: false, action: nil
        ))
    }

    @Test
    func `cap is not advertised when the list fits under it`() {
        let repos = (1...5).map { i in
            stubRepo(owner: "o", name: "r\(i)", openIssues: 0, openPulls: 0)
        }
        let snapshot = MenuSnapshot.fromRepositories(repos, cap: 50)
        // No "and N more" row should appear when count <= cap.
        for row in snapshot.rows {
            if case let .item(label, _, _) = row {
                #expect(label.contains("and") == false || label == "Quit RepoBar")
            }
        }
    }

    @Test
    func `loading placeholder shows a single disabled row then controls`() {
        let snapshot = MenuSnapshot.loading
        #expect(snapshot.rows.first == .item(
            label: "Loading repositories…", enabled: false, action: nil
        ))
        #expect(snapshot.rows.last == .item(
            label: "Quit RepoBar", enabled: true, action: .quit
        ))
    }

    @Test
    func `signedOut placeholder mentions repobar login`() {
        let snapshot = MenuSnapshot.signedOut
        let labels = snapshot.rows.compactMap { row -> String? in
            if case let .item(label, _, _) = row { return label }
            return nil
        }
        #expect(labels.contains("Not signed in"))
        #expect(labels.contains(where: { $0.contains("repobar login") }))
    }

    @Test
    func `error snapshot exposes the message on its own row`() {
        let snapshot = MenuSnapshot.error("network unreachable")
        let labels = snapshot.rows.compactMap { row -> String? in
            if case let .item(label, _, _) = row { return label }
            return nil
        }
        #expect(labels.contains("network unreachable"))
        #expect(labels.contains("Couldn't load repositories"))
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
