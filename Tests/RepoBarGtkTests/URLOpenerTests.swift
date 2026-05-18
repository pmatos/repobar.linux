import Foundation
@testable import RepoBarGtk
import Testing

@Suite("URLOpener")
struct URLOpenerTests {
    @Test
    func `RecordingURLOpener captures the URL it would have opened`() async {
        let opener = RecordingURLOpener()
        let url = URL(string: "https://github.com/pmatos/repobar.linux")!

        let error = await opener.open(url)

        #expect(error == nil)
        #expect(opener.opens == [url])
    }

    @Test
    func `RecordingURLOpener captures multiple opens in order`() async {
        let opener = RecordingURLOpener()
        let a = URL(string: "https://github.com/a/a")!
        let b = URL(string: "https://github.com/b/b")!

        _ = await opener.open(a)
        _ = await opener.open(b)

        #expect(opener.opens == [a, b])
    }

    @Test
    func `RecordingURLOpener can be primed to return a failure`() async {
        let opener = RecordingURLOpener(stubError: .binaryNotFound)
        let url = URL(string: "https://example.com")!

        let error = await opener.open(url)

        #expect(error == .binaryNotFound)
        #expect(opener.opens == [url])
    }

    @Test
    func `URLOpenError displayMessage is non-empty for each case`() {
        // Tests don't pin the exact wording (low-value lock-in) but do assert
        // the user-facing notification path won't end up empty.
        for error in [
            URLOpenError.binaryNotFound,
            URLOpenError.exitedNonZero(2),
            URLOpenError.launchFailed("ENOENT"),
        ] {
            #expect(error.displayMessage.isEmpty == false)
        }
    }
}
