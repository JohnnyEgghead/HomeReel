import XCTest
@testable import HomeReel

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
}

final class LibraryScanTests: XCTestCase {
    override func setUp() { StubURLProtocol.reset() }

    private let movies = PlexSection(key: "1", type: "movie", title: "Movies", agent: "tv.plex.agents.movie")

    private static func sections(refreshing: Bool) -> Data {
        Data(#"{"MediaContainer":{"Directory":[{"key":"1","type":"movie","title":"Movies","agent":"tv.plex.agents.movie","refreshing":\#(refreshing)}]}}"#.utf8)
    }

    func testScanAsksTheServerToRefreshThatLibrary() async throws {
        StubURLProtocol.handler = { _ in (200, Data()) }
        try await makeClient().scanLibrary(movies)
        let req = try XCTUnwrap(StubURLProtocol.seen.first)
        XCTAssertEqual(req.url?.path, "/library/sections/1/refresh")
        XCTAssertEqual(req.value(forHTTPHeaderField: "X-Plex-Token"), "SECRET")
    }

    func testScanFailureIsReported() async {
        StubURLProtocol.handler = { _ in (500, Data()) }
        do { try await makeClient().scanLibrary(movies); XCTFail("should throw") } catch {}
    }

    func testIsScanningReadsTheLibrariesFlag() async throws {
        StubURLProtocol.handler = { _ in (200, Self.sections(refreshing: true)) }
        let on = try await makeClient().isScanning(movies)
        XCTAssertTrue(on)
        StubURLProtocol.handler = { _ in (200, Self.sections(refreshing: false)) }
        let off = try await makeClient().isScanning(movies)
        XCTAssertFalse(off)
    }

    @MainActor func testModelScansWaitsThenReloads() async throws {
        let sectionPolls = Counter()
        StubURLProtocol.handler = { r in
            switch r.url!.path {
            case "/library/sections/1/refresh": return (200, Data())
            case "/library/sections": return (200, Self.sections(refreshing: sectionPolls.next() <= 2))   // scanning for 2 polls
            default: return (200, Fixture.data("movies"))
            }
        }
        let model = LibraryModel()
        model.scanPollInterval = .milliseconds(10)
        await model.configure(client: makeClient(), section: movies)
        let before = StubURLProtocol.seen.count
        let done = Task { await model.scanForNewContent() }
        try await Task.sleep(for: .milliseconds(5))
        XCTAssertEqual(model.scan, .scanning)
        // Wait until the model has finished the scan itself (it then holds "finished" for a few seconds).
        for _ in 0..<200 where model.scan == .scanning { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.scan, .finished)
        done.cancel()
        let paths = StubURLProtocol.seen.dropFirst(before).compactMap { $0.url?.path }
        XCTAssertEqual(paths.first, "/library/sections/1/refresh")
        XCTAssertEqual(paths.filter { $0 == "/library/sections" }.count, 3)
        XCTAssertEqual(paths.last, "/library/sections/1/all", "the list is reloaded after the scan")
    }

    @MainActor func testModelShowsAFailedScan() async throws {
        StubURLProtocol.handler = { r in r.url!.path.hasSuffix("/refresh") ? (500, Data()) : (200, Fixture.data("movies")) }
        let model = LibraryModel()
        await model.configure(client: makeClient(), section: movies)
        await model.scanForNewContent()
        if case .failed = model.scan {} else { XCTFail("expected a failed scan, got \(model.scan)") }
    }
}
