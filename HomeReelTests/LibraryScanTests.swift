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

    @MainActor func testAPageFromBeforeAReloadIsDropped() async throws {
        // The title-sorted page answers late. The year-sorted page, asked for after it, answers at once.
        StubURLProtocol.handler = { r in r.url!.query!.contains("sort=titleSort") ? (200, Fixture.data("movies")) : (200, Fixture.data("recent")) }
        StubURLProtocol.delayFor = { r in r.url!.query!.contains("sort=titleSort") ? 0.4 : 0 }
        let model = LibraryModel()
        let first = Task { await model.configure(client: makeClient(), section: movies) }
        try await Task.sleep(for: .milliseconds(100))
        model.sort = .year                       // reloads while the first page is still on its way
        await first.value
        try await Task.sleep(for: .milliseconds(150))
        let wanted = Set(try Fixture.container("recent").items.map(\.ratingKey))
        XCTAssertEqual(Set(model.items.map(\.ratingKey)), wanted, "only the page for the current sort is shown")
        XCTAssertEqual(model.items.count, wanted.count, "and it is not doubled")
        XCTAssertEqual(model.total, wanted.count)
        XCTAssertFalse(model.loading)
    }

    @MainActor func testAScanThatOutlastsTheWaitSaysTheServerIsStillAtIt() async throws {
        StubURLProtocol.handler = { r in
            switch r.url!.path {
            case "/library/sections/1/refresh": return (200, Data())
            case "/library/sections": return (200, Self.sections(refreshing: true))      // never finishes
            default: return (200, Fixture.data("movies"))
            }
        }
        let model = LibraryModel()
        model.scanPollInterval = .milliseconds(5)
        model.maxScanPolls = 6
        await model.configure(client: makeClient(), section: movies)
        await model.scanForNewContent()
        XCTAssertEqual(model.scan, .stillRunning, "not \"finished\": the server has not finished")
    }

    @MainActor func testOneOrTwoMissedScanChecksAreForgiven() async throws {
        let polls = Counter()
        StubURLProtocol.handler = { r in
            switch r.url!.path {
            case "/library/sections/1/refresh": return (200, Data())
            case "/library/sections":
                let n = polls.next()
                if n == 2 || n == 3 { return (500, Data()) }              // two misses in a row
                return (200, Self.sections(refreshing: n <= 1))
            default: return (200, Fixture.data("movies"))
            }
        }
        let model = LibraryModel()
        model.scanPollInterval = .milliseconds(5)
        await model.configure(client: makeClient(), section: movies)
        let before = StubURLProtocol.seen.count
        let task = Task { await model.scanForNewContent() }
        for _ in 0..<300 where model.scan == .scanning || model.scan == .idle { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.scan, .finished)
        task.cancel()
        XCTAssertGreaterThan(StubURLProtocol.seen.count, before)
    }

    @MainActor func testThreeMissedScanChecksInARowFailTheScan() async throws {
        let polls = Counter()
        StubURLProtocol.handler = { r in
            switch r.url!.path {
            case "/library/sections/1/refresh": return (200, Data())
            case "/library/sections": return polls.next() == 1 ? (200, Self.sections(refreshing: true)) : (500, Data())
            default: return (200, Fixture.data("movies"))
            }
        }
        let model = LibraryModel()
        model.scanPollInterval = .milliseconds(5)
        await model.configure(client: makeClient(), section: movies)
        await model.scanForNewContent()
        if case .failed = model.scan {} else { XCTFail("expected a failed scan, got \(model.scan)") }
    }

    // MARK: Items the server sent that cannot be read (J-13)

    private static let oneGoodOneBad = Data(#"{"MediaContainer":{"size":2,"totalSize":2,"Metadata":[{"nonsense":1},{"ratingKey":"7","type":"movie","title":"Readable"}]}}"#.utf8)
    private static let allBad = Data(#"{"MediaContainer":{"size":2,"totalSize":2,"Metadata":[{"nonsense":1},{"nonsense":2}]}}"#.utf8)

    @MainActor func testTheListSaysHowManyItemsCouldNotBeRead() async throws {
        StubURLProtocol.handler = { _ in (200, Self.oneGoodOneBad) }
        let model = LibraryModel()
        await model.configure(client: makeClient(), section: movies)
        XCTAssertEqual(model.items.map(\.title), ["Readable"])
        XCTAssertEqual(model.dropped, 1)
        XCTAssertNil(model.error)
    }

    @MainActor func testAPageWhereNothingCouldBeReadIsAFailureNotAnEmptyLibrary() async throws {
        StubURLProtocol.handler = { _ in (200, Self.allBad) }
        let model = LibraryModel()
        await model.configure(client: makeClient(), section: movies)
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertEqual(model.error, PlexError.decoding("").errorDescription, "a plain sentence, not an empty-library message")
    }

    func testAnEpisodeListWhereNothingCouldBeReadIsAFailure() async {
        StubURLProtocol.handler = { _ in (200, Self.allBad) }
        do { _ = try await makeClient().children("5"); XCTFail("should throw") }
        catch { XCTAssertEqual(error as? PlexError, .decoding("every entry in a children list")) }
    }

    @MainActor func testAFailedScanCheckDuringTheLoopStillShowsTheFailureText() async throws {
        StubURLProtocol.handler = { r in r.url!.path.hasSuffix("/refresh") ? (500, Data()) : (200, Fixture.data("movies")) }
        let model = LibraryModel()
        await model.configure(client: makeClient(), section: movies)
        await model.scanForNewContent()
        if case .failed(let m) = model.scan { XCTAssertFalse(m.isEmpty) } else { XCTFail("expected a failed scan, got \(model.scan)") }
    }

    @MainActor func testModelShowsAFailedScan() async throws {
        StubURLProtocol.handler = { r in r.url!.path.hasSuffix("/refresh") ? (500, Data()) : (200, Fixture.data("movies")) }
        let model = LibraryModel()
        await model.configure(client: makeClient(), section: movies)
        await model.scanForNewContent()
        if case .failed = model.scan {} else { XCTFail("expected a failed scan, got \(model.scan)") }
    }
}
