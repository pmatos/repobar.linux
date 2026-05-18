import Foundation

/// Outcome of an `xdg-open` invocation that we care about diagnostically.
///
/// We deliberately don't try to map every possible `xdg-open` exit code; the
/// xdg-open spec defines codes 1–4 but in practice handlers freely return 0
/// while failing, or non-zero while succeeding (the browser opens but xdg-open
/// itself bailed). What we *do* want to surface is "the binary was not found"
/// vs "the binary ran and reported a non-zero exit" vs "we couldn't even
/// launch the process". Those three buckets cover the actionable cases.
public enum URLOpenError: Error, Equatable, Sendable {
    case binaryNotFound
    case exitedNonZero(Int32)
    case launchFailed(String)

    public var displayMessage: String {
        switch self {
        case .binaryNotFound:
            "xdg-open is not installed (install xdg-utils)"
        case let .exitedNonZero(code):
            "xdg-open exited with status \(code)"
        case let .launchFailed(reason):
            "couldn't launch xdg-open: \(reason)"
        }
    }
}

/// Opens a URL in the user's default browser / handler.
///
/// Real callers use `SystemURLOpener` (spawns `xdg-open`). Tests use
/// `RecordingURLOpener` to assert on what would have been opened without
/// actually shelling out. Both KDE (which routes `xdg-open` through
/// `kde-open5`) and GNOME / vanilla freedesktop installs satisfy this
/// contract — we only ever invoke `xdg-open` and let the system dispatch.
public protocol URLOpener: Sendable {
    /// Open `url`. Returns `nil` on success, or an error describing why the
    /// open didn't reach a handler.
    func open(_ url: URL) async -> URLOpenError?
}

public struct SystemURLOpener: URLOpener {
    public init() {}

    public func open(_ url: URL) async -> URLOpenError? {
        await withCheckedContinuation { (continuation: CheckedContinuation<URLOpenError?, Never>) in
            let process = Process()
            // `/usr/bin/env` is the portable binary path on every supported
            // distro; it walks `$PATH` for `xdg-open` itself so we don't have
            // to. Pinning a specific install location (e.g. `/usr/bin/xdg-open`)
            // breaks on systems that put it under `/usr/local/bin/`.
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["xdg-open", url.absoluteString]
            process.terminationHandler = { proc in
                let code = proc.terminationStatus
                if code == 0 {
                    continuation.resume(returning: nil)
                } else if code == 127 {
                    // env's exit code when the requested binary is not found.
                    continuation.resume(returning: .binaryNotFound)
                } else {
                    continuation.resume(returning: .exitedNonZero(code))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: .launchFailed(String(describing: error)))
            }
        }
    }
}

/// Captures URLs that would have been opened, without spawning anything.
public final class RecordingURLOpener: URLOpener, @unchecked Sendable {
    private let lock = NSLock()
    private var _opens: [URL] = []
    private let stubError: URLOpenError?

    /// `stubError != nil` makes every `open(...)` call return that error,
    /// useful for exercising the failure path in tests.
    public init(stubError: URLOpenError? = nil) {
        self.stubError = stubError
    }

    public var opens: [URL] {
        self.snapshot()
    }

    public func open(_ url: URL) async -> URLOpenError? {
        self.record(url)
        return self.stubError
    }

    // NSLock.lock/unlock are marked unavailable when the caller is async;
    // dispatching the actual lock work through sync helpers keeps both the
    // protocol's async signature and the compiler check satisfied. The
    // critical section is bounded (one array append / one copy) so blocking
    // a Swift Concurrency thread for that long is harmless.
    private func record(_ url: URL) {
        self.lock.lock()
        defer { self.lock.unlock() }
        self._opens.append(url)
    }

    private func snapshot() -> [URL] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self._opens
    }
}
