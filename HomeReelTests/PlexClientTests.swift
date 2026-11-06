import XCTest
@testable import HomeReel

final class PlexClientTests: XCTestCase {
    override func setUp() { StubURLProtocol.reset() }

    func testRequestsCarryTokenAndIdentity() async throws {
        StubURLProtocol.handler = { _ in (200, Fixture.data("sections")) }
        _ = try await makeClient().libraries()
        let req = try XCTUnwrap(StubURLProtocol.seen.first)
        XCTAssertEqual(req.value(forHTTPHeaderField: "X-Plex-Token"), "SECRET")
        XCTAssertEqual(req.value(forHTTPHeaderField: "X-Plex-Client-Identifier"), "test-client-id")
        XCTAssertEqual(req.value(forHTTPHeaderField: "X-Plex-Product"), "HomeReel")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Accept"), "application/json")
    }

    func testLibrariesFiltersToMoviesAndShows() async throws {
        StubURLProtocol.handler = { _ in (200, Fixture.data("sections")) }
        let libs = try await makeClient().libraries()
        XCTAssertEqual(libs.movies.map(\.key), ["1"])
        XCTAssertEqual(libs.shows.map(\.key), ["2"])
    }

    func testItemsQueryHasSortTypeAndPaging() async throws {
        StubURLProtocol.handler = { _ in (200, Fixture.data("movies")) }
        let section = PlexSection(key: "1", type: "movie", title: "Movies", agent: "tv.plex.agents.movie")
        let page = try await makeClient().items(section: section, sort: .added, unwatchedOnly: true, start: 60, size: 60)
        XCTAssertEqual(page.items.count, 3)
        XCTAssertGreaterThan(page.total, 3)
        let url = try XCTUnwrap(StubURLProtocol.seen.first?.url)
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.reduce(into: [String: String]()) { $0[$1.name] = $1.value }
        XCTAssertEqual(url.path, "/library/sections/1/all")
        XCTAssertEqual(q["type"], "1")
        XCTAssertEqual(q["sort"], "addedAt:desc")
        XCTAssertEqual(q["unwatched"], "1")
        XCTAssertEqual(q["X-Plex-Container-Start"], "60")
        XCTAssertEqual(q["X-Plex-Container-Size"], "60")
    }

    func testShowSectionAsksForShows() async throws {
        StubURLProtocol.handler = { _ in (200, Fixture.data("shows")) }
        let section = PlexSection(key: "2", type: "show", title: "TV Shows")
        _ = try await makeClient().items(section: section, sort: .title, unwatchedOnly: false, start: 0, size: 60)
        XCTAssertTrue(StubURLProtocol.seen[0].url!.query!.contains("type=2"))
        XCTAssertFalse(StubURLProtocol.seen[0].url!.query!.contains("unwatched"))
    }

    func testContinueWatchingReturnsMoviesAndEpisodesOnly() async throws {
        StubURLProtocol.handler = { _ in (200, Fixture.data("continue")) }
        let items = try await makeClient().continueWatching()
        XCTAssertFalse(items.isEmpty)
        XCTAssertTrue(items.allSatisfy { $0.type == .movie || $0.type == .episode })
    }

    func testSearchSplitsMoviesAndShows() async throws {
        StubURLProtocol.handler = { _ in (200, Fixture.data("search")) }
        let r = try await makeClient().search("the")
        XCTAssertTrue(r.movies.allSatisfy { $0.type == .movie })
        XCTAssertTrue(r.shows.allSatisfy { $0.type == .show })
        XCTAssertFalse(r.movies.isEmpty && r.shows.isEmpty)
        XCTAssertTrue(StubURLProtocol.seen[0].url!.query!.contains("query=the"))
    }

    func testSearchDropsResultsFromOtherLibraries() async throws {
        StubURLProtocol.handler = { _ in (200, Fixture.data("search")) }
        let all = try await makeClient().search("the")
        let onlyShows = try await makeClient().search("the", inSections: ["2"])
        XCTAssertTrue(onlyShows.movies.isEmpty, "no movie lives in library 2")
        XCTAssertTrue(onlyShows.shows.allSatisfy { $0.librarySectionID == 2 })
        let none = try await makeClient().search("the", inSections: [])
        XCTAssertTrue(none.movies.isEmpty && none.shows.isEmpty)
        XCTAssertGreaterThanOrEqual(all.movies.count + all.shows.count, onlyShows.shows.count)
    }

    func testMarkWatchedAndUnwatchedPaths() async throws {
        StubURLProtocol.handler = { _ in (200, Data()) }
        let c = makeClient()
        try await c.setWatched(true, ratingKey: "42")
        try await c.setWatched(false, ratingKey: "42")
        XCTAssertEqual(StubURLProtocol.seen.map { $0.url!.path }, ["/:/scrobble", "/:/unscrobble"])
        XCTAssertTrue(StubURLProtocol.seen[0].url!.query!.contains("key=42"))
    }

    func testUnauthorizedMapsToUnauthorized() async {
        StubURLProtocol.handler = { _ in (401, Data()) }
        do { _ = try await makeClient().libraries(); XCTFail("should throw") }
        catch { XCTAssertEqual(error as? PlexError, .unauthorized) }
    }

    func testServerErrorMapsToBadResponse() async {
        StubURLProtocol.handler = { _ in (500, Data()) }
        do { _ = try await makeClient().libraries(); XCTFail("should throw") }
        catch { XCTAssertEqual(error as? PlexError, .badResponse(500)) }
    }

    func testGarbageMapsToDecodingError() async {
        StubURLProtocol.handler = { _ in (200, Data("not json".utf8)) }
        do { _ = try await makeClient().libraries(); XCTFail("should throw") }
        catch { if case .decoding = (error as? PlexError) ?? .unauthorized {} else { XCTFail("wrong error \(error)") } }
    }

    func testImageURLUsesResizerWithGivenPath() throws {
        let u = try XCTUnwrap(makeClient().imageURL("/library/metadata/1/thumb/2", width: 480, height: 720))
        XCTAssertEqual(u.path, "/photo/:/transcode")
        let q = URLComponents(url: u, resolvingAgainstBaseURL: false)!.queryItems!.reduce(into: [String: String]()) { $0[$1.name] = $1.value }
        XCTAssertEqual(q["url"], "/library/metadata/1/thumb/2")
        XCTAssertEqual(q["width"], "480")
        XCTAssertNil(makeClient().imageURL(nil, width: 1, height: 1))
    }

    func testImageRequestSendsTheTokenAsAHeaderAndNeverInTheAddress() throws {
        let r = try XCTUnwrap(makeClient().imageRequest("/library/metadata/1/thumb/2", width: 480, height: 720))
        XCTAssertFalse(try XCTUnwrap(r.url).absoluteString.contains("SECRET"), "caches keep addresses on disk")
        XCTAssertFalse(try XCTUnwrap(r.url).absoluteString.contains("X-Plex-Token"))
        XCTAssertEqual(r.value(forHTTPHeaderField: "X-Plex-Token"), "SECRET")
        XCTAssertNil(r.value(forHTTPHeaderField: "Accept"), "the JSON Accept header does not suit an image")
        XCTAssertNil(makeClient().imageRequest(nil, width: 1, height: 1))
    }

    func testDirectPlayURLIsTheOriginalFileNotATranscode() throws {
        let part = try XCTUnwrap(Fixture.container("movie_detail").items[0].primaryPart)
        let u = makeClient().directPlayURL(part: part)
        XCTAssertEqual(u.path, part.key)
        XCTAssertFalse(u.absoluteString.contains("transcode"))
        XCTAssertFalse(u.absoluteString.contains("start.m3u8"))
        XCTAssertTrue(u.absoluteString.contains("X-Plex-Token=SECRET"))
    }

    // MARK: Next episode and batched details

    private func episode(_ key: String, season: String = "1003", show: String = "1002") -> PlexItem {
        let json = #"{"ratingKey":"\#(key)","type":"episode","title":"E\#(key)","parentRatingKey":"\#(season)","grandparentRatingKey":"\#(show)"}"#
        return try! JSONDecoder().decode(PlexItem.self, from: Data(json.utf8))
    }

    private static func listing(_ type: String, _ keys: [String]) -> Data {
        let items = keys.map { #"{"ratingKey":"\#($0)","type":"\#(type)","title":"T\#($0)"}"# }.joined(separator: ",")
        return Data(#"{"MediaContainer":{"size":\#(keys.count),"Metadata":[\#(items)]}}"#.utf8)
    }

    func testNextEpisodeIsTheOneAfterInTheSameSeason() async throws {
        StubURLProtocol.handler = { r in (200, Self.listing("episode", ["1004", "1005", "1006"])) }
        let next = try await makeClient().nextEpisode(after: episode("1005"))
        XCTAssertEqual(next?.ratingKey, "1006")
        XCTAssertEqual(StubURLProtocol.seen.first?.url?.path, "/library/metadata/1003/children")
    }

    func testNextEpisodeAfterTheLastOneIsTheFirstOfTheNextSeason() async throws {
        StubURLProtocol.handler = { r in
            switch r.url!.path {
            case "/library/metadata/1003/children": return (200, Self.listing("episode", ["1004", "1005"]))
            case "/library/metadata/1002/children": return (200, Self.listing("season", ["1003", "2003"]))
            case "/library/metadata/2003/children": return (200, Self.listing("episode", ["2004", "2005"]))
            default: return (404, Data())
            }
        }
        let next = try await makeClient().nextEpisode(after: episode("1005"))
        XCTAssertEqual(next?.ratingKey, "2004")
    }

    func testNoNextEpisodeAtTheEndOfTheShow() async throws {
        StubURLProtocol.handler = { r in
            r.url!.path == "/library/metadata/1002/children" ? (200, Self.listing("season", ["1003"])) : (200, Self.listing("episode", ["1004", "1005"]))
        }
        let next = try await makeClient().nextEpisode(after: episode("1005"))
        XCTAssertNil(next)
    }

    func testNoNextEpisodeForAMovie() async throws {
        let movie = try JSONDecoder().decode(PlexItem.self, from: Data(#"{"ratingKey":"1","type":"movie","title":"M"}"#.utf8))
        let next = try await makeClient().nextEpisode(after: movie)
        XCTAssertNil(next)
        XCTAssertTrue(StubURLProtocol.seen.isEmpty)
    }

    func testSeveralItemsAreFetchedInOneRequest() async throws {
        StubURLProtocol.handler = { _ in (200, Self.listing("episode", ["1", "2", "3"])) }
        let items = try await makeClient().metadata(keys: ["1", "2", "3"])
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(StubURLProtocol.seen.count, 1)
        XCTAssertEqual(StubURLProtocol.seen.first?.url?.path, "/library/metadata/1,2,3")
        let none = try await makeClient().metadata(keys: [])
        XCTAssertTrue(none.isEmpty)
    }
}
