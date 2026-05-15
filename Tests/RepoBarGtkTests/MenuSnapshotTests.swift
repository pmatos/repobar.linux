@testable import RepoBarGtk
import Testing

@Suite
struct MenuSnapshotTests {
    @Test
    func `staticPlaceholder has the four rows specified in #13`() {
        let snapshot = MenuSnapshot.staticPlaceholder
        #expect(snapshot.rows == [
            .item(label: "Repositories", enabled: false, action: nil),
            .separator,
            .item(label: "Preferences…", enabled: false, action: nil),
            .item(label: "Quit RepoBar", enabled: true, action: .quit),
        ])
    }

    @Test
    func `MenuSnapshot is Equatable so rebuild can short-circuit on no-op`() {
        let a = MenuSnapshot.staticPlaceholder
        let b = MenuSnapshot.staticPlaceholder
        #expect(a == b)

        let c = MenuSnapshot(rows: [.separator])
        #expect(a != c)
    }
}
