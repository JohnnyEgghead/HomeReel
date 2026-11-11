import XCTest
@testable import HomeReel

/// A cache that remembers every request it was asked to keep, so a test can see what would have reached the disk.
final class RecordingCache: URLCache, @unchecked Sendable {
    private(set) var stored: [URLRequest] = []
    override func storeCachedResponse(_ cachedResponse: CachedURLResponse, for request: URLRequest) {
        stored.append(request)
        super.storeCachedResponse(cachedResponse, for: request)
    }
}

/// The Plex token must reach no file. A URL cache saves each request with its headers, so nothing that carries
/// the token may go through one.
final class TokenStorageTests: XCTestCase {
    override func setUp() { StubURLProtocol.reset() }

    private func pngData() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).pngData { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
    }

    func testPictureCacheNeverHoldsARequestWithTheToken() async throws {
        let png = pngData()
        StubURLProtocol.handler = { _ in (200, png) }
        StubURLProtocol.cacheable = true      // as a real server's answer is: a cache wired into the session would keep it
        let cache = RecordingCache(memoryCapacity: 1 << 20, diskCapacity: 0)
        let images = ImageStore(cache: cache, protocolClasses: [StubURLProtocol.self])
        let request = try XCTUnwrap(makeClient().imageRequest("/library/metadata/1/thumb/2", width: 10, height: 10))
        let picture = await images.image(for: request)
        XCTAssertNotNil(picture)

        XCTAssertEqual(StubURLProtocol.seen.count, 1)
        XCTAssertEqual(StubURLProtocol.seen.first?.value(forHTTPHeaderField: "X-Plex-Token"), "SECRET", "the fetch itself still sends it")
        XCTAssertEqual(cache.stored.count, 1, "the picture is kept")
        for kept in cache.stored {
            XCTAssertNil(kept.value(forHTTPHeaderField: "X-Plex-Token"))
            XCTAssertTrue((kept.allHTTPHeaderFields ?? [:]).isEmpty, "a saved request has no headers at all")
            XCTAssertFalse(try XCTUnwrap(kept.url).absoluteString.contains("SECRET"))
        }
    }

    func testSavedPictureIsFoundAgainWithoutTheNetwork() async throws {
        let png = pngData()
        StubURLProtocol.handler = { _ in (200, png) }
        let cache = RecordingCache(memoryCapacity: 1 << 20, diskCapacity: 0)
        let request = try XCTUnwrap(makeClient().imageRequest("/library/metadata/1/thumb/2", width: 10, height: 10))
        _ = await ImageStore(cache: cache, protocolClasses: [StubURLProtocol.self]).image(for: request)
        // A new store has an empty memory cache, as after a relaunch. Only the saved copy can answer.
        let again = await ImageStore(cache: cache, protocolClasses: [StubURLProtocol.self]).image(for: request)
        XCTAssertNotNil(again)
        XCTAssertEqual(StubURLProtocol.seen.count, 1, "the second picture came from the cache")
    }

    func testAFailedPictureIsNotKept() async throws {
        StubURLProtocol.handler = { _ in (404, Data()) }
        let cache = RecordingCache(memoryCapacity: 1 << 20, diskCapacity: 0)
        let request = try XCTUnwrap(makeClient().imageRequest("/library/metadata/1/thumb/2", width: 10, height: 10))
        let picture = await ImageStore(cache: cache, protocolClasses: [StubURLProtocol.self]).image(for: request)
        XCTAssertNil(picture)
        XCTAssertTrue(cache.stored.isEmpty)
    }

    func testEveryCallThatCarriesASecretUsesASessionWithNoCache() {
        XCTAssertNil(URLSession.uncached.configuration.urlCache)
        let client = PlexClient(baseURL: URL(string: "http://10.0.0.5:32400")!, token: "t", identity: testIdentity)
        XCTAssertTrue(client.session === URLSession.uncached)
        XCTAssertTrue(BraviaClient(host: "192.0.2.50", psk: "k").session === URLSession.uncached)
        XCTAssertTrue(PlexAuth(identity: testIdentity).session === URLSession.uncached)
    }

    func testClearingAlsoEmptiesTheAppsSharedCache() async throws {
        let url = URL(string: "http://10.0.0.5:32400/library/sections")!
        let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        var old = URLRequest(url: url)
        old.setValue("SECRET", forHTTPHeaderField: "X-Plex-Token")
        URLCache.shared.storeCachedResponse(CachedURLResponse(response: resp, data: Data("x".utf8)), for: old)
        XCTAssertNotNil(URLCache.shared.cachedResponse(for: old))
        ImageStore(cache: RecordingCache(memoryCapacity: 1 << 20, diskCapacity: 0)).clear()
        // The cache finishes removing from its disk store a moment after the call returns.
        for _ in 0..<50 where URLCache.shared.cachedResponse(for: old) != nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNil(URLCache.shared.cachedResponse(for: old))
    }
}
