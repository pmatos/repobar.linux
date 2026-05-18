import Foundation
#if canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

/// Pure-Swift dispatcher for `MenuSnapshot.Action`. The GTK rebuilder wraps a
/// `Task.detached { await dispatchMenuAction(...) }` invocation in each
/// menu-item's activate handler. Keeping the switch here (and not inside the
/// boxed closure in `MenuBuilder.swift`) means every case is unit-testable
/// against an injected `URLOpener` — no GTK widget required.
public func dispatchMenuAction(_ action: MenuSnapshot.Action, opener: URLOpener) async {
    switch action {
    case .quit:
        shouldQuit = 1
    case let .openURL(url):
        if let error = await opener.open(url) {
            await reportURLOpenFailure(url: url, error: error)
        }
    }
}

/// Surface an URL-open failure. Today we write to stderr and best-effort fire
/// `notify-send`; #18 replaces this with a real `Gio.Notification`.
func reportURLOpenFailure(url: URL, error: URLOpenError) async {
    let line = "[RepoBar] couldn't open \(url.absoluteString): \(error.displayMessage)\n"
    line.withCString { ptr in
        FileHandle.standardError.write(Data(bytes: ptr, count: strlen(ptr)))
    }
    // Best-effort desktop notification via libnotify. If notify-send is not
    // installed we silently fall back to the stderr line above — the user
    // will at least see something in `journalctl --user -u repobar`.
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [
        "notify-send",
        "--app-name", "RepoBar",
        "RepoBar",
        "Couldn't open \(url.absoluteString) — \(error.displayMessage)",
    ]
    do {
        try process.run()
    } catch {
        // notify-send missing or unrunnable; stderr above is our last word.
    }
}
