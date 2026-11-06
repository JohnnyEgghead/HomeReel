import XCTest
@testable import HomeReel

final class RatingsTests: XCTestCase {
    private func item(_ json: String) throws -> PlexItem {
        try JSONDecoder().decode(PlexItem.self, from: Data(json.utf8))
    }
    private let base = #""ratingKey":"1","type":"movie","title":"T""#

    func testMovieFixtureShowsAllFourScoresInOrder() throws {
        let movie = try XCTUnwrap(Fixture.container("movie_detail").items.first)
        let labels = Ratings.badges(for: movie).map(\.label)
        XCTAssertEqual(labels, ["RT Critics", "RT Audience", "TMDB", "IMDb"])
    }

    func testRottenTomatoesIsAPercentageAndTmdbIsOneDecimal() throws {
        let i = try item("{\(base),\"Rating\":[{\"image\":\"rottentomatoes://image.rating.ripe\",\"value\":9.1,\"type\":\"critic\"},{\"image\":\"themoviedb://image.rating\",\"value\":7.46,\"type\":\"audience\"}]}")
        let b = Ratings.badges(for: i)
        XCTAssertEqual(b.first?.value, "91%")
        XCTAssertEqual(b.first?.mood, .good)
        XCTAssertEqual(b.last?.value, "7.5")
    }

    func testRottenAndSpilledCountAsBad() throws {
        let i = try item("{\(base),\"Rating\":[{\"image\":\"rottentomatoes://image.rating.rotten\",\"value\":3.0,\"type\":\"critic\"},{\"image\":\"rottentomatoes://image.rating.spilled\",\"value\":4.0,\"type\":\"audience\"}]}")
        let b = Ratings.badges(for: i)
        XCTAssertEqual(b.map(\.source), [.rtCritics, .rtAudience])
        XCTAssertEqual(b.map(\.mood), [.bad, .bad])
    }

    func testUprightAudienceIsGood() throws {
        let i = try item("{\(base),\"Rating\":[{\"image\":\"rottentomatoes://image.rating.upright\",\"value\":8.7,\"type\":\"audience\"}]}")
        XCTAssertEqual(Ratings.badges(for: i).first?.source, .rtAudience)
        XCTAssertEqual(Ratings.badges(for: i).first?.mood, .good)
    }

    func testEpisodesHaveNoRottenTomatoes() throws {
        let ep = try XCTUnwrap(Fixture.container("episode_detail").items.first)
        let labels = Ratings.badges(for: ep).map(\.label)
        XCTAssertFalse(labels.contains { $0.hasPrefix("RT") })
        XCTAssertTrue(labels.contains("IMDb"))
        XCTAssertTrue(labels.contains("TMDB"))
    }

    func testFallsBackToTheSummaryScores() throws {
        let i = try item("{\(base),\"rating\":8.0,\"ratingImage\":\"rottentomatoes://image.rating.ripe\",\"audienceRating\":6.5,\"audienceRatingImage\":\"rottentomatoes://image.rating.upright\"}")
        let b = Ratings.badges(for: i)
        XCTAssertEqual(b.map(\.value), ["80%", "65%"])
    }

    func testNoScoresMeansNoBadges() throws {
        XCTAssertTrue(Ratings.badges(for: try item("{\(base)}")).isEmpty)
    }
}

final class CrewTests: XCTestCase {
    func testCrewListsDirectorsThenWritersThenProducersWithJobs() throws {
        let movie = try XCTUnwrap(Fixture.container("movie_detail").items.first)
        let crew = Crew.people(for: movie, limit: 100)
        XCTAssertFalse(crew.isEmpty)
        let jobs = crew.compactMap(\.role)
        let order = ["Director", "Writer", "Producer"]
        XCTAssertEqual(jobs, jobs.sorted { order.firstIndex(of: $0)! < order.firstIndex(of: $1)! })
    }

    func testSamePersonWithTwoJobsAppearsTwiceButNeverTwiceForOneJob() throws {
        let json = #"{"ratingKey":"1","type":"movie","title":"T","Director":[{"tag":"A","tagKey":"k1"},{"tag":"A","tagKey":"k1"}],"Writer":[{"tag":"A","tagKey":"k1"}]}"#
        let i = try JSONDecoder().decode(PlexItem.self, from: Data(json.utf8))
        XCTAssertEqual(Crew.people(for: i).compactMap(\.role), ["Director", "Writer"])
    }

    func testLimitApplies() throws {
        let movie = try XCTUnwrap(Fixture.container("movie_detail").items.first)
        XCTAssertLessThanOrEqual(Crew.people(for: movie, limit: 2).count, 2)
    }
}

final class PersonTests: XCTestCase {
    override func setUp() { StubURLProtocol.reset() }

    private func discover() -> PlexDiscover {
        PlexDiscover(token: "SECRET", identity: testIdentity, session: StubURLProtocol.session())
    }

    func testCastTagCarriesThePersonIds() throws {
        let movie = try XCTUnwrap(Fixture.container("movie_detail").items.first)
        let first = try XCTUnwrap(movie.Role?.first)
        XCTAssertNotNil(first.tagKey)
        XCTAssertTrue(first.filter?.hasPrefix("actor=") == true)
    }

    func testProfileDecodesAndFormatsTheBirthLine() async throws {
        StubURLProtocol.handler = { _ in (200, Fixture.data("person")) }
        let p = try await discover().profile(tagKey: "61b2333e140347dd3fe3d118")
        XCTAssertEqual(p.title, "Dana Whitfield")
        XCTAssertEqual(p.bornLine, "Born March 4, 1971 · Springfield, Exampleland")
        let req = try XCTUnwrap(StubURLProtocol.seen.first)
        XCTAssertEqual(req.url?.host, "discover.provider.plex.tv")
        XCTAssertEqual(req.url?.path, "/library/people/61b2333e140347dd3fe3d118")
        XCTAssertEqual(req.value(forHTTPHeaderField: "X-Plex-Token"), "SECRET")
    }

    func testBornLineHandlesMissingParts() {
        XCTAssertNil(PersonProfile(title: "X").bornLine)
        XCTAssertEqual(PersonProfile(title: "X", birthPlace: "Paris").bornLine, "Paris")
        XCTAssertEqual(PersonProfile(title: "X", bornAt: "2000-01-02").bornLine, "Born January 2, 2000")
    }

    func testCreditsAreGroupedByJob() async throws {
        StubURLProtocol.handler = { _ in (200, Fixture.data("person_credits")) }
        let groups = try await discover().credits(tagKey: "abc")
        XCTAssertEqual(groups.map(\.title).prefix(4), ["Actor", "Writer", "Appearances", "Producer"])
        XCTAssertEqual(StubURLProtocol.seen.first?.url?.path, "/library/people/abc/credits")
        XCTAssertEqual(groups.first?.Credit.first?.role, "Lucian Brandt")
    }

    func testKnownForDecodes() async throws {
        StubURLProtocol.handler = { _ in (200, Fixture.data("person_knownfor")) }
        let titles = try await discover().knownFor(tagKey: "abc")
        XCTAssertFalse(titles.isEmpty)
        XCTAssertEqual(StubURLProtocol.seen.first?.url?.path, "/library/people/abc/person_known_for")
    }

    func testOnlineFailureIsReported() async {
        StubURLProtocol.handler = { _ in (500, Data()) }
        do { _ = try await discover().credits(tagKey: "abc"); XCTFail("should throw") }
        catch { XCTAssertTrue("\(error)".contains("500") || error is PlexError) }
    }

    func testPostersAreAskedForAtASmallSize() {
        let big = "https://image.tmdb.org/t/p/original/abc.jpg"
        XCTAssertEqual(DiscoverImages.sized(big)?.absoluteString, "https://image.tmdb.org/t/p/w342/abc.jpg")
        XCTAssertEqual(DiscoverImages.sized(big, width: 500)?.absoluteString, "https://image.tmdb.org/t/p/w500/abc.jpg")
        XCTAssertEqual(DiscoverImages.sized("https://example.com/a.jpg")?.absoluteString, "https://example.com/a.jpg")
        XCTAssertNil(DiscoverImages.sized(nil))
        XCTAssertNil(DiscoverImages.sized(""))
    }

    func testLibraryTitlesForAPersonUseTheActorFilter() async throws {
        StubURLProtocol.handler = { _ in (200, Fixture.data("movies")) }
        let section = PlexSection(key: "1", type: "movie", title: "Movies", agent: "tv.plex.agents.movie")
        _ = try await makeClient().titles(withPerson: "actor=470", in: [section])
        let url = try XCTUnwrap(StubURLProtocol.seen.first?.url)
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(q.first { $0.name == "actor" }?.value, "470")
    }

    @MainActor func testLocalCopyIsFoundByTheDatabaseId() throws {
        XCTAssertEqual(PersonModel.databaseID(of: "plex://movie/3abcc2155cd39306ed3eb45d"), "3abcc2155cd39306ed3eb45d")
        XCTAssertNil(PersonModel.databaseID(of: nil))
    }
}
