import Foundation
@testable import RepoBarGtk
import Testing

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@Suite("DiskImageCache")
struct DiskImageCacheTests {
    @Test
    func `defaultCacheDir uses XDG_CACHE_HOME when set`() {
        let dir = DiskImageCache.defaultCacheDir(env: ["XDG_CACHE_HOME": "/tmp/xdg"])
        #expect(dir.path == "/tmp/xdg/repobar/img")
    }

    @Test
    func `defaultCacheDir falls back to HOME/.cache when XDG_CACHE_HOME absent`() {
        let dir = DiskImageCache.defaultCacheDir(env: ["HOME": "/home/me"])
        #expect(dir.path == "/home/me/.cache/repobar/img")
    }

    @Test
    func `defaultCacheDir ignores empty XDG_CACHE_HOME`() {
        let dir = DiskImageCache.defaultCacheDir(env: ["XDG_CACHE_HOME": "", "HOME": "/home/me"])
        #expect(dir.path == "/home/me/.cache/repobar/img")
    }

    @Test
    func `cacheKey is stable and 16-hex for any URL`() {
        let url = URL(string: "https://github.com/pmatos.png?size=22")!
        let key = DiskImageCache.cacheKey(for: url)
        #expect(key.count == 16)
        #expect(key.allSatisfy { $0.isHexDigit })
        // Stable across calls.
        #expect(DiskImageCache.cacheKey(for: url) == key)
    }

    @Test
    func `cold load fetches and writes data plus meta sidecar`() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = URL(string: "https://example.test/a.png")!
        let payload = Data("first".utf8)
        let counter = Counter()
        let cache = DiskImageCache(cacheDir: dir, fetch: { _ in
            await counter.bump()
            let resp = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil,
                headerFields: ["ETag": "\"v1\"", "Last-Modified": "Wed, 21 Oct 2020 07:28:00 GMT"]
            )!
            return (payload, resp)
        })

        let data = try await cache.load(url)

        #expect(data == payload)
        #expect(await counter.value == 1)
        let key = DiskImageCache.cacheKey(for: url)
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "\(key).bin").path))
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "\(key).meta").path))
    }

    @Test
    func `warm load within TTL serves from disk and skips network`() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = URL(string: "https://example.test/b.png")!
        let payload = Data("second".utf8)
        let counter = Counter()
        let cache = DiskImageCache(cacheDir: dir, fetch: { _ in
            await counter.bump()
            let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [:])!
            return (payload, resp)
        }, ttl: 60)

        _ = try await cache.load(url)
        _ = try await cache.load(url)

        // Second load must not have hit the network — that's the acceptance
        // criterion "second open serves from cache".
        #expect(await counter.value == 1)
    }

    @Test
    func `stale load issues conditional GET with cached ETag`() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = URL(string: "https://example.test/c.png")!
        let payload = Data("third".utf8)
        let seenETags = HeaderSink()
        let cache = DiskImageCache(cacheDir: dir, fetch: { request in
            await seenETags.record(request.value(forHTTPHeaderField: "If-None-Match"))
            let resp = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil,
                headerFields: ["ETag": "\"v7\""]
            )!
            return (payload, resp)
        }, ttl: 0)

        _ = try await cache.load(url)
        _ = try await cache.load(url)

        let captured = await seenETags.values
        #expect(captured.count == 2)
        // First request: no If-None-Match (cache cold). Second: cached "v7".
        #expect(captured[0] == nil)
        #expect(captured[1] == "\"v7\"")
    }

    @Test
    func `304 response reuses cached data without overwriting it`() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = URL(string: "https://example.test/d.png")!
        let cachedPayload = Data("cached".utf8)
        let counter = Counter()
        // First call: 200 + ETag. Second call: 304.
        let cache = DiskImageCache(cacheDir: dir, fetch: { request in
            let n = await counter.bump()
            if n == 1 {
                return (cachedPayload, HTTPURLResponse(
                    url: url, statusCode: 200, httpVersion: nil,
                    headerFields: ["ETag": "\"v9\""]
                )!)
            }
            return (Data(), HTTPURLResponse(
                url: url, statusCode: 304, httpVersion: nil, headerFields: [:]
            )!)
        }, ttl: 0)

        _ = try await cache.load(url)
        let second = try await cache.load(url)

        #expect(second == cachedPayload)
        #expect(await counter.value == 2)
    }

    @Test
    func `concurrent loads of the same URL coalesce into one fetch`() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = URL(string: "https://example.test/e.png")!
        let payload = Data("e".utf8)
        let counter = Counter()
        // A small delay so the second load enters while the first is in flight.
        let cache = DiskImageCache(cacheDir: dir, fetch: { _ in
            await counter.bump()
            try? await Task.sleep(nanoseconds: 50_000_000)
            return (payload, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [:])!)
        })

        async let a = cache.load(url)
        async let b = cache.load(url)
        async let c = cache.load(url)
        _ = try await (a, b, c)

        #expect(await counter.value == 1)
    }

    @Test
    func `non-200 non-304 status throws badStatus`() async {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = URL(string: "https://example.test/f.png")!
        let cache = DiskImageCache(cacheDir: dir, fetch: { _ in
            let resp = HTTPURLResponse(url: url, statusCode: 500, httpVersion: nil, headerFields: [:])!
            return (Data(), resp)
        })

        do {
            _ = try await cache.load(url)
            Issue.record("expected throw")
        } catch ImageLoaderError.badStatus(let code) {
            #expect(code == 500)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test
    func `cachedSync returns data when present and nil otherwise`() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = URL(string: "https://example.test/g.png")!
        let payload = Data("g".utf8)
        let cache = DiskImageCache(cacheDir: dir, fetch: { _ in
            let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [:])!
            return (payload, resp)
        })

        #expect(cache.cachedSync(url) == nil)
        _ = try await cache.load(url)
        #expect(cache.cachedSync(url) == payload)
    }
}

private actor Counter {
    private(set) var value = 0
    @discardableResult
    func bump() -> Int { value += 1; return value }
}

private actor HeaderSink {
    private(set) var values: [String?] = []
    func record(_ value: String?) { values.append(value) }
}

private func makeTempDir() -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "repobar-img-test-\(UUID().uuidString)", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}
