import XCTest
@testable import HomeReel

/// The page for a title you do not own, the role filter on a person's page, and previewing a point on the timeline.
@MainActor
final class TitlePageRoleFilterScrubTests: XCTestCase {
    override func setUp() { StubURLProtocol.reset() }

    // MARK: Title you do not own

    private func discover() -> PlexDiscover {
        PlexDiscover(token: "SECRET", identity: testIdentity, session: StubURLProtocol.session())
    }

    func testOnlineDetailsCarrySummaryScoresCastAndCrew() async throws {
        StubURLProtocol.handler = { _ in (200, Fixture.data("discover_detail")) }
        let d = try await discover().details(ratingKey: "51512ea3c8d6cd4c513286c1")
        XCTAssertEqual(StubURLProtocol.seen.first?.url?.host, "discover.provider.plex.tv")
        XCTAssertEqual(StubURLProtocol.seen.first?.url?.path, "/library/metadata/51512ea3c8d6cd4c513286c1")
        XCTAssertEqual(d.title, "Paper Summit")
        XCTAssertTrue(d.summary?.hasSuffix("what it costs them.") == true, "the whole description, not a cut")
        XCTAssertEqual(d.Role?.map(\.tag), ["Ada Fenwick", "Mira Voss"])
        XCTAssertEqual(Crew.people(for: d).map(\.role), ["Director", "Writer"])
        XCTAssertEqual(Ratings.badges(for: d).map(\.label), ["RT Critics", "IMDb"])
        XCTAssertEqual(d.Genre?.map(\.tag), ["Drama", "Mystery"])
        XCTAssertEqual(d.Role?.first?.tagKey, "5d776826161a76001e2d2f1a", "the online page of a cast member opens by this")
        XCTAssertEqual(Crew.people(for: d).first?.tagKey, "5d77686a7e9a51001f1c0d2e", "crew too")
    }

    func testAStreamingMediaEntryDoesNotCostTheTitle() async throws {
        // The online record of a title carries streaming details with text part ids (as Fargo does); the page never uses them.
        StubURLProtocol.handler = { _ in (200, Fixture.data("discover_detail")) }
        let d = try await discover().details(ratingKey: "x")
        XCTAssertNil(d.Media, "streaming details are not read")
        XCTAssertEqual(d.title, "Paper Summit")
    }

    func testOneBadFieldCostsOnlyThatField() async throws {
        let json = #"{"MediaContainer":{"Metadata":[{"ratingKey":"k","type":"movie","title":"T","year":"nineteen","duration":"long","summary":"S","Role":[{"tag":"A","id":"abc"},{"id":5}],"Rating":"none"}]}}"#
        StubURLProtocol.handler = { _ in (200, Data(json.utf8)) }
        let d = try await discover().details(ratingKey: "k")
        XCTAssertEqual(d.summary, "S")
        XCTAssertNil(d.year)
        XCTAssertEqual(d.Role?.map(\.tag), ["A"], "the broken cast entry is skipped, the good one stays")
    }

    func testOnlineDetailFailureIsReported() async {
        StubURLProtocol.handler = { _ in (500, Data()) }
        do { _ = try await discover().details(ratingKey: "x"); XCTFail("should throw") } catch {}
    }

    func testAnEmptyAnswerIsAnErrorNotABlankPage() async {
        StubURLProtocol.handler = { _ in (200, Data(#"{"MediaContainer":{"size":0}}"#.utf8)) }
        do { _ = try await discover().details(ratingKey: "x"); XCTFail("should throw") } catch {}
    }

    func testOnlineCastDropsIdsThatBelongToTheOnlineDatabase() throws {
        let tag = PlexTag(tag: "Ada", role: "Lucian", thumb: nil, personID: 7, filter: "actor=7", tagKey: "abc")
        let online = tag.online
        XCTAssertNil(online.filter, "a filter from the online database would ask your server about the wrong person")
        XCTAssertNil(online.personID)
        XCTAssertEqual(online.tagKey, "abc", "the online page still needs this")
        XCTAssertEqual(online.tag, "Ada")
    }

    func testNotInLibraryPagesOfDifferentTitlesAreDifferent() {
        let a = DiscoverTitle(ratingKey: "a", title: "A", type: "movie", year: 2000, thumb: nil)
        let b = DiscoverTitle(ratingKey: "b", title: "B", type: "movie", year: 2000, thumb: nil)
        XCTAssertNotEqual(NotInLibrary(title: a), NotInLibrary(title: b))
        XCTAssertNotEqual(NotInLibrary(title: a), NotInLibrary(title: a, unknown: true))
    }

    // MARK: Role filter

    func testRoleFilterShowsOnlyThatRole() throws {
        let groups = try JSONDecoder().decode(PlexEnvelope<GroupsBox>.self, from: Fixture.data("person_credits")).MediaContainer.CreditGroup
        XCTAssertGreaterThan(groups.count, 1)
        XCTAssertEqual(PersonModel.visibleGroups(groups, role: nil).map(\.title), groups.map(\.title))
        XCTAssertEqual(PersonModel.visibleGroups(groups, role: "Writer").map(\.title), ["Writer"])
    }

    func testARoleThePersonDoesNotHaveShowsEverything() throws {
        let groups = try JSONDecoder().decode(PlexEnvelope<GroupsBox>.self, from: Fixture.data("person_credits")).MediaContainer.CreditGroup
        XCTAssertEqual(PersonModel.visibleGroups(groups, role: "Gaffer").count, groups.count)
    }

    private struct GroupsBox: Decodable { var CreditGroup: [CreditGroup] }

    // MARK: Previewing a point on the timeline

    private func playingModel() throws -> PlayerModel {
        let item = try XCTUnwrap(Fixture.container("movie_detail").items.first)
        let model = PlayerModel(item: item, client: makeClient())
        model.setPhaseForTesting(.paused)
        model.setTimeForTesting(100, duration: 7200)
        return model
    }

    func testTimeStaysWhereYouWereWhilePreviewing() throws {
        let m = try playingModel()
        m.scrubBegan()
        m.skip(60)
        XCTAssertEqual(m.time, 100, "progress is reported from the real place, not the preview")
        m.scrubCancel()
        XCTAssertEqual(m.time, 100)
    }

    func testASwipeOnlyPreviews() throws {
        let m = try playingModel()
        m.scrubBegan()
        m.scrubChanged(translation: 500, width: 1000, speed: 0)
        XCTAssertTrue(m.isScrubbing)
        XCTAssertGreaterThan(try XCTUnwrap(m.scrubTarget), 100)
        XCTAssertEqual(m.time, 100, "nothing is sought until the viewer confirms")
    }

    func testMenuCancelsThePreviewAndKeepsThePlace() throws {
        let m = try playingModel()
        m.scrubBegan()
        m.scrubChanged(translation: 500, width: 1000, speed: 0)
        m.scrubCancel()
        XCTAssertFalse(m.isScrubbing)
        XCTAssertNil(m.scrubTarget)
        XCTAssertEqual(m.time, 100)
    }

    func testEdgeClickMovesThePreviewNotTheVideo() throws {
        let m = try playingModel()
        m.scrubBegan()
        m.skip(10)
        XCTAssertEqual(m.scrubTarget, 110)
        m.skip(-30)
        XCTAssertEqual(m.scrubTarget, 80)
        XCTAssertEqual(m.time, 100)
        m.skip(-500)
        XCTAssertEqual(m.scrubTarget, 0, "the preview stops at the start")
    }

    func testASecondSwipeCarriesOnFromThePreview() throws {
        let m = try playingModel()
        m.scrubBegan()
        m.skip(60)
        m.scrubBegan()      // the finger came down again
        XCTAssertEqual(m.scrubTarget, 160, "not back at the playing position")
    }

    func testOpeningThePanelDropsThePreview() throws {
        let m = try playingModel()
        m.scrubBegan()
        m.openPanel()
        XCTAssertFalse(m.isScrubbing)
    }

    func testASwipeNeedsRealMovementToStart() {
        XCTAssertGreaterThanOrEqual(PlaybackPolicy.swipeStartDistance, 80)
    }
}

final class TagDecodingTests: XCTestCase {
    func testAnOnlineTagWithATextIdStillDecodes() throws {
        let json = Data(#"{"id":"5d776826161a76001e2d2f1a","tag":"Ada","tagKey":"5d776826161a76001e2d2f1a","role":"Lucian"}"#.utf8)
        let t = try JSONDecoder().decode(PlexTag.self, from: json)
        XCTAssertEqual(t.tag, "Ada")
        XCTAssertNil(t.personID)
        XCTAssertEqual(t.tagKey, "5d776826161a76001e2d2f1a")
    }

    func testAnOnlinePersonIsOpenedByTheirTextId() throws {
        // As Plex's online database lists a cast member: a text `id`, no `tagKey`.
        let json = Data(#"{"id":"5d7768250000000000000abc","key":"/library/people/5d7768250000000000000abc","type":"person","tag":"Ada","role":"Dan"}"#.utf8)
        let t = try JSONDecoder().decode(PlexTag.self, from: json)
        XCTAssertEqual(t.tagKey, "5d7768250000000000000abc")
        XCTAssertNil(t.personID)
        XCTAssertNil(t.online.filter)
    }

    func testTheOnlineLinkAloneIsEnough() throws {
        let t = try JSONDecoder().decode(PlexTag.self, from: Data(#"{"tag":"Ada","key":"/library/people/abc123"}"#.utf8))
        XCTAssertEqual(t.tagKey, "abc123")
    }

    func testAServerTagKeepsItsNumericId() throws {
        let t = try JSONDecoder().decode(PlexTag.self, from: Data(#"{"id":470,"filter":"actor=470","tag":"Ada"}"#.utf8))
        XCTAssertEqual(t.personID, 470)
        XCTAssertEqual(t.filter, "actor=470")
    }
}

final class BiographyChunkTests: XCTestCase {
    func testEmptyTextHasNoPieces() {
        XCTAssertEqual(BiographySheet.chunks(of: ""), [])
        XCTAssertEqual(BiographySheet.chunks(of: " \n \n"), [])
    }

    func testEachParagraphIsItsOwnPiece() {
        XCTAssertEqual(BiographySheet.chunks(of: "One.\n\nTwo.\nThree."), ["One.", "Two.", "Three."])
    }

    func testALongParagraphIsCutAtSentenceEndsAndKeepsAllItsText() {
        let sentence = "This is one sentence of the biography. "
        let paragraph = String(repeating: sentence, count: 40)
        let pieces = BiographySheet.chunks(of: paragraph, limit: 200)
        XCTAssertGreaterThan(pieces.count, 4)
        XCTAssertTrue(pieces.allSatisfy { $0.count <= 200 }, "no piece is taller than a few lines")
        XCTAssertTrue(pieces.allSatisfy { $0.hasSuffix(".") }, "cut at sentence ends")
        XCTAssertEqual(pieces.joined(separator: " "), paragraph.trimmingCharacters(in: .whitespaces), "nothing is lost or repeated")
    }

    func testOneVeryLongSentenceStaysWhole() {
        let long = String(repeating: "word ", count: 200).trimmingCharacters(in: .whitespaces) + "."
        XCTAssertEqual(BiographySheet.chunks(of: long, limit: 100), [long])
    }
}
