import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Fetches images by URL, deduping concurrent requests and serving from a
/// disk cache when possible. Tests substitute a `RecordingImageLoader` for
/// the real `DiskImageCache`.
///
/// `cachedSync` is the bridge to synchronous rendering paths: the GTK menu
/// rebuild runs on the main loop and must produce widgets without awaiting.
/// We render whatever's already on disk; the async `load` is fired in the
/// background so subsequent rebuilds pick up freshly-cached data.
public protocol ImageLoader: Sendable {
    func load(_ url: URL) async throws -> Data
    func cachedSync(_ url: URL) -> Data?
}

public enum ImageLoaderError: Error, Equatable, Sendable {
    case badStatus(Int)
    case badResponse
}

/// XDG-conformant disk cache for binary image blobs.
///
/// Layout:
///
///     $XDG_CACHE_HOME/repobar/img/<hash>.bin   ← raw bytes
///     $XDG_CACHE_HOME/repobar/img/<hash>.meta  ← {"etag": ..., "lastModified": ...}
///
/// `<hash>` is a 16-character lowercase hex FNV-1a digest of the absolute
/// URL string. The hash is stable across runs and processes; the same URL
/// always lands at the same path so the cache survives restarts.
///
/// Revalidation policy: any entry younger than `ttl` (default 24h, by file
/// mtime) is served straight from disk without a network call. Past TTL,
/// a conditional GET is issued with `If-None-Match` / `If-Modified-Since`
/// from the sidecar `.meta`; 304 bumps the mtime and reuses the cached
/// data, 200 overwrites both files.
public actor DiskImageCache: ImageLoader {
    public typealias Fetch = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    private let cacheDir: URL
    private let fetch: Fetch
    private let ttl: TimeInterval
    private let fileManager = FileManager.default
    private var inFlight: [URL: Task<Data, Error>] = [:]

    public init(
        cacheDir: URL? = nil,
        fetch: Fetch? = nil,
        ttl: TimeInterval = 24 * 60 * 60
    ) {
        self.cacheDir = cacheDir ?? Self.defaultCacheDir()
        self.fetch = fetch ?? Self.urlSessionFetch
        self.ttl = ttl
        try? self.fileManager.createDirectory(
            at: self.cacheDir,
            withIntermediateDirectories: true
        )
    }

    /// Default fetcher: plain `URLSession.shared.data(for:)`. Hoisted out so
    /// tests can inject a stub via the `fetch:` parameter.
    static let urlSessionFetch: Fetch = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ImageLoaderError.badResponse
        }
        return (data, http)
    }

    public static func defaultCacheDir(
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        let xdg = env["XDG_CACHE_HOME"].flatMap { $0.isEmpty ? nil : $0 }
        if let xdg, xdg.isEmpty == false {
            return URL(fileURLWithPath: xdg)
                .appending(path: "repobar/img", directoryHint: .isDirectory)
        }
        let home = env["HOME"] ?? NSHomeDirectory()
        return URL(fileURLWithPath: home)
            .appending(path: ".cache/repobar/img", directoryHint: .isDirectory)
    }

    /// Stable 16-char lowercase hex digest. FNV-1a is not cryptographic but
    /// for cache keys we only need collision-resistance under the size of
    /// the user's avatar set (thousands at the absolute most).
    static func cacheKey(for url: URL) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in url.absoluteString.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return String(format: "%016x", hash)
    }

    public func load(_ url: URL) async throws -> Data {
        if let task = self.inFlight[url] {
            return try await task.value
        }
        let task = Task<Data, Error> {
            try await self.loadOrFetch(url)
        }
        self.inFlight[url] = task
        defer { self.inFlight[url] = nil }
        return try await task.value
    }

    public nonisolated func cachedSync(_ url: URL) -> Data? {
        let dataFile = self.dataFile(for: url)
        return try? Data(contentsOf: dataFile)
    }

    private func loadOrFetch(_ url: URL) async throws -> Data {
        let dataFile = self.dataFile(for: url)
        let metaFile = self.metaFile(for: url)

        // Fresh cache hit: skip network entirely.
        if let cached = try? Data(contentsOf: dataFile),
           let age = self.mtimeAge(of: dataFile),
           age < self.ttl
        {
            return cached
        }

        // Build conditional GET headers from sidecar meta when available.
        var request = URLRequest(url: url)
        let cachedMeta = self.readMeta(at: metaFile)
        if let etag = cachedMeta?.etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        if let lastMod = cachedMeta?.lastModified {
            request.setValue(lastMod, forHTTPHeaderField: "If-Modified-Since")
        }

        let (body, httpResp) = try await self.fetch(request)
        switch httpResp.statusCode {
        case 200:
            try body.write(to: dataFile, options: .atomic)
            let newMeta = CacheMeta(
                etag: httpResp.value(forHTTPHeaderField: "ETag"),
                lastModified: httpResp.value(forHTTPHeaderField: "Last-Modified")
            )
            self.writeMeta(newMeta, to: metaFile)
            return body
        case 304:
            // Cached data is still valid; bump mtime so we don't re-validate
            // on every subsequent load() call within this TTL window.
            try? self.fileManager.setAttributes(
                [.modificationDate: Date()],
                ofItemAtPath: dataFile.path
            )
            if let cached = try? Data(contentsOf: dataFile) {
                return cached
            }
            // Race: 304 said reuse but we have no body. Treat as miss.
            throw ImageLoaderError.badResponse
        default:
            throw ImageLoaderError.badStatus(httpResp.statusCode)
        }
    }

    private struct CacheMeta: Codable, Sendable {
        let etag: String?
        let lastModified: String?
    }

    private nonisolated func dataFile(for url: URL) -> URL {
        self.cacheDir.appending(path: "\(Self.cacheKey(for: url)).bin")
    }

    private nonisolated func metaFile(for url: URL) -> URL {
        self.cacheDir.appending(path: "\(Self.cacheKey(for: url)).meta")
    }

    private func readMeta(at url: URL) -> CacheMeta? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CacheMeta.self, from: data)
    }

    private func writeMeta(_ meta: CacheMeta, to url: URL) {
        guard let data = try? JSONEncoder().encode(meta) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func mtimeAge(of url: URL) -> TimeInterval? {
        guard let attrs = try? self.fileManager.attributesOfItem(atPath: url.path),
              let date = attrs[.modificationDate] as? Date
        else { return nil }
        return Date().timeIntervalSince(date)
    }
}

/// Captures the URLs that would have been loaded; serves a primed Data
/// payload back for both `load` and `cachedSync`.
public final class RecordingImageLoader: ImageLoader, @unchecked Sendable {
    private let lock = NSLock()
    private var _loadCalls: [URL] = []
    private let stubData: Data?
    private let stubError: ImageLoaderError?

    public init(stubData: Data? = nil, stubError: ImageLoaderError? = nil) {
        self.stubData = stubData
        self.stubError = stubError
    }

    public var loadCalls: [URL] {
        self.snapshot()
    }

    public func load(_ url: URL) async throws -> Data {
        self.record(url)
        if let stubError = self.stubError {
            throw stubError
        }
        return self.stubData ?? Data()
    }

    public func cachedSync(_ url: URL) -> Data? {
        // Tests that want to assert "synchronous cache hit serves stubData"
        // can prime stubData. By default, return nil so callers exercise the
        // miss path.
        self.stubData
    }

    private func record(_ url: URL) {
        self.lock.lock()
        defer { self.lock.unlock() }
        self._loadCalls.append(url)
    }

    private func snapshot() -> [URL] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self._loadCalls
    }
}
