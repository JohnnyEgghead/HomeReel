import XCTest
@testable import HomeReel

final class SortAndRecentTests: XCTestCase {
    override func setUp() { StubURLProtocol.reset() }

    private func query(_ req: URLRequest) -> [String: String] {
        URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!.queryItems!.reduce(into: [:]) { $0[$1.name] = $1.value }
    }

    func testTVSortsUseEpisodeDates() {
        XCTAssertEqual(PlexSort.added.query(forShows: true), "episode.addedAt:desc", "newest episode added")
        XCTAssertEqual(PlexSort.aired.query(forShows: true), "episode.originallyAvailableAt:desc")
        XCTAssertEqual(PlexSort.added.query(forShows: false), "addedAt:desc", "movies keep the plain date added")
    }

    func testRecentlyAiredIsOnlyOfferedForShows() {
        XCTAssertTrue(PlexSort.options(forShows: true).contains(.aired))
        XCTAssertFalse(PlexSort.options(forShows: false).contains(.aired))
        XCTAssertEqual(PlexSort.aired.label, "Recently Aired Episode")
    }

    func testRecentShowsComeAsWholeSeriesByNewestEpisode() async throws {
        StubURLProtocol.handler = { _ in (200, Fixture.data("shows")) }
        let section = PlexSection(key: "2", type: "show", title: "TV Shows")
        let shows = try await makeClient().recentlyAdded(section: section)
        let req = try XCTUnwrap(StubURLProtocol.seen.first)
        XCTAssertEqual(req.url?.path, "/library/sections/2/all")
        XCTAssertEqual(query(req)["type"], "2")
        XCTAssertEqual(query(req)["sort"], "episode.addedAt:desc")
        XCTAssertTrue(shows.allSatisfy { $0.type == .show })
    }

    func testRecentMoviesStillUseTheRecentlyAddedList() async throws {
        StubURLProtocol.handler = { _ in (200, Fixture.data("recent")) }
        let section = PlexSection(key: "1", type: "movie", title: "Movies", agent: "tv.plex.agents.movie")
        _ = try await makeClient().recentlyAdded(section: section)
        XCTAssertEqual(StubURLProtocol.seen.first?.url?.path, "/library/sections/1/recentlyAdded")
    }

    func testRemoveFromContinueWatchingIsAPutWithTheKey() async throws {
        StubURLProtocol.handler = { _ in (200, Data()) }
        try await makeClient().removeFromContinueWatching(ratingKey: "15492")
        let req = try XCTUnwrap(StubURLProtocol.seen.first)
        XCTAssertEqual(req.httpMethod, "PUT")
        XCTAssertEqual(req.url?.path, "/actions/removeFromContinueWatching")
        XCTAssertEqual(query(req)["ratingKey"], "15492")
    }

    func testRemoveFailureIsReported() async {
        StubURLProtocol.handler = { _ in (500, Data()) }
        do { try await makeClient().removeFromContinueWatching(ratingKey: "1"); XCTFail("should throw") }
        catch { XCTAssertEqual(error as? PlexError, .badResponse(500)) }
    }
}
