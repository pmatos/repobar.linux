import Foundation
@testable import RepoBarGtk
import Testing

@Suite("dispatchMenuAction")
struct MenuActionDispatchTests {
    @Test
    func `openURL forwards the exact URL to the opener`() async {
        let opener = RecordingURLOpener()
        let url = URL(string: "https://github.com/pmatos/repobar.linux")!

        await dispatchMenuAction(.openURL(url), opener: opener)

        #expect(opener.opens == [url])
    }

    @Test
    func `openURL with a failing opener does not crash and does not retry`() async {
        let opener = RecordingURLOpener(stubError: .binaryNotFound)
        let url = URL(string: "https://example.com")!

        await dispatchMenuAction(.openURL(url), opener: opener)
        await dispatchMenuAction(.openURL(url), opener: opener)

        // Two dispatches → two recorded opens; the failure is surfaced via
        // reportURLOpenFailure (stderr + best-effort notify-send) without
        // any retry inside dispatchMenuAction itself.
        #expect(opener.opens == [url, url])
    }

    @Test
    func `quit action does not touch the opener`() async {
        let opener = RecordingURLOpener()

        await dispatchMenuAction(.quit, opener: opener)

        #expect(opener.opens.isEmpty)
        // We reset shouldQuit so the next test isn't surprised; this is a
        // module-global flag that the real main-loop poll source consumes.
        shouldQuit = 0
    }
}
