import XCTest
@testable import HomeReel

/// What happens when the network fails or a request is cancelled. These paths used to hide the failure.
@MainActor
final class FailurePathTests: XCTestCase {
    override func setUp() { StubURLProtocol.reset() }

    private func signedIn(server: String = "http://10.0.0.5:32400") -> InMemorySecretStore {
        InMemorySecretStore([AppModel.Key.token: "t", AppModel.Key.server: server])
    }

    private func movie() throws -> PlexItem { try XCTUnwrap(Fixture.container("movie_detail").items.first) }

    private func requests(_ pathEnd: String) -> [URLRequest] {
        StubURLProtocol.seen.filter { $0.url?.path.hasSuffix(pathEnd) == true }
    }

    // MARK: Watched mark (J-08)

    func testFailedWatchedMarkIsRetriedAndThePositionIsStillSaved() async throws {
        StubURLProtocol.handler = { req in req.url?.path.hasSuffix("/scrobble") == true ? (500, Data()) : (200, Data()) }
        let model = PlayerModel(item: try movie(), client: makeClient())
        model.watchedRetryDelay = .zero
        await model.showEndForTesting()
        let message = await model.finish()
        XCTAssertEqual(requests("/scrobble").count, PlaybackPolicy.watchedAttempts, "a failed watched mark should be tried again")
        XCTAssertEqual(requests("/:/timeline").count, 1, "the position must not be lost when the mark fails")
        XCTAssertNotNil(message, "the viewer should hear about it")
    }

    func testSavedWatchedMarkIsSentOnce() async throws {
        StubURLProtocol.handler = { _ in (200, Data()) }
        let model = PlayerModel(item: try movie(), client: makeClient())
        await model.showEndForTesting()
        let message = await model.finish()
        XCTAssertEqual(requests("/scrobble").count, 1)
        XCTAssertNil(message)
    }

    func testAFailedSaveShowsABannerAndListsStillHearAboutIt() async throws {
        StubURLProtocol.handler = answering { req in req.url?.path.hasSuffix("/scrobble") == true ? (500, Data()) : (200, Fixture.data("sections")) }
        let m = AppModel(secrets: signedIn(), session: StubURLProtocol.session(), images: ImageStore(cache: CountingCache()))
        await m.start()
        let model = PlayerModel(item: try movie(), client: makeClient())
        model.watchedRetryDelay = .zero
        await model.showEndForTesting()
        await m.finishPlayback(model)
        XCTAssertNotNil(m.banner)
        XCTAssertEqual(m.playbackSaves, 1)
    }

    // MARK: Ending the session (J-11, J-16)

    private func timelineStates() -> [String] {
        requests("/:/timeline").compactMap { r in
            URLComponents(url: r.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value
        }
    }

    func testAWatchedExitEndsTheSessionAfterTheMark() async throws {
        StubURLProtocol.handler = { _ in (200, Data()) }
        let model = PlayerModel(item: try movie(), client: makeClient())
        await model.showEndForTesting()
        let message = await model.finish()
        XCTAssertNil(message)
        XCTAssertEqual(timelineStates(), ["stopped"], "Plex must hear that playback ended")
        let order = StubURLProtocol.seen.compactMap { $0.url?.path }.filter { $0.hasSuffix("/scrobble") || $0 == "/:/timeline" }
        XCTAssertEqual(order, ["/:/scrobble", "/:/timeline"], "the mark first, so the report cannot undo it")
    }

    func testAnEarlyExitTellsYouWhenThePlaceCouldNotBeSaved() async throws {
        StubURLProtocol.handler = { _ in (500, Data()) }
        // Stopped at 1 minute of 100: not watched, so the stop report is the only thing that keeps the place.
        let early = PlayerModel(item: try movie(), client: makeClient())
        early.setTimeForTesting(60, duration: 6000)
        let message = await early.finish()
        XCTAssertEqual(timelineStates(), ["stopped"])
        XCTAssertNotNil(message, "a place that was not saved is told to the viewer")
    }

    func testAnEarlyExitThatSavesIsQuiet() async throws {
        StubURLProtocol.handler = { _ in (200, Data()) }
        let early = PlayerModel(item: try movie(), client: makeClient())
        early.setTimeForTesting(60, duration: 6000)
        let message = await early.finish()
        XCTAssertNil(message)
        XCTAssertEqual(requests("/scrobble").count, 0, "not watched")
        XCTAssertEqual(timelineStates(), ["stopped"])
    }

    func testStoppedReportThrowsButProgressReportDoesNot() async throws {
        StubURLProtocol.handler = { _ in (500, Data()) }
        let c = makeClient()
        await c.reportTimeline(try movie(), state: .playing, time: 5, duration: 100)      // a miss is fine
        do { try await c.reportStopped(try movie(), time: 5, duration: 100); XCTFail("should throw") }
        catch { XCTAssertEqual(error as? PlexError, .badResponse(500)) }
    }

    // MARK: Cancellation (J-09)

    func testACancelledServerRequestStaysACancellation() async {
        StubURLProtocol.handler = { _ in (200, Fixture.data("sections")) }
        let c = makeClient()
        let task = Task { try await c.libraries() }
        task.cancel()
        do { _ = try await task.value; XCTFail("expected a cancellation") }
        catch { XCTAssertTrue(error is CancellationError, "got \(error)") }
    }

    func testACancelledPinCheckStaysACancellation() async {
        StubURLProtocol.handler = { _ in (200, Data(#"{"id":1,"code":"ABCD"}"#.utf8)) }
        let auth = PlexAuth(identity: testIdentity, session: StubURLProtocol.session())
        let task = Task { try await auth.checkPin(1) }
        task.cancel()
        do { _ = try await task.value; XCTFail("expected a cancellation") }
        catch { XCTAssertTrue(error is CancellationError, "got \(error)") }
    }

    func testPressingCancelWhileLinkingReturnsToSignInNotToAFailure() async throws {
        StubURLProtocol.handler = { _ in (201, Data(#"{"id":1,"code":"ABCD"}"#.utf8)) }
        let m = AppModel(secrets: InMemorySecretStore(), session: StubURLProtocol.session())
        m.signInWithCode()
        m.cancelLinking()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(m.phase, .signedOut)
    }

    // MARK: Sign-out (J-10)

    func testSigningOutForgetsTheOldServersCatalog() async throws {
        let old = #"{"MediaContainer":{"size":1,"totalSize":1,"Metadata":[{"ratingKey":"1","key":"/k","type":"movie","title":"Old Server Movie"}]}}"#
        let new = #"{"MediaContainer":{"size":1,"totalSize":1,"Metadata":[{"ratingKey":"1","key":"/k","type":"movie","title":"New Server Movie"}]}}"#
        StubURLProtocol.handler = answering { req in
            guard req.url?.path.hasSuffix("/all") == true else { return (200, Fixture.data("sections")) }
            return (200, Data((req.url?.host == "10.0.0.5" ? old : new).utf8))
        }
        let store = signedIn()
        let m = AppModel(secrets: store, session: StubURLProtocol.session(), images: ImageStore(cache: CountingCache()))
        await m.start()
        let first = await m.libraryCatalog()
        XCTAssertEqual(first?.first?.title, "Old Server Movie")
        m.signOut()
        await m.signInManually(address: "10.0.0.6", token: "t2")
        let second = await m.libraryCatalog()
        XCTAssertEqual(second?.first?.title, "New Server Movie")
    }

    // MARK: Small defects (J-26, J-27)

    func testNothingPlayedMeansNoPositionReport() async throws {
        StubURLProtocol.handler = { _ in (200, Data()) }
        let model = PlayerModel(item: try movie(), client: makeClient())
        await model.finish()
        XCTAssertTrue(requests("/:/timeline").isEmpty)
    }

    func testTypedAddressesBecomeWhole() {
        XCTAssertEqual(AppModel.serverAddress(from: "10.0.0.5"), "http://10.0.0.5:32400")
        XCTAssertEqual(AppModel.serverAddress(from: " http://nas.local/ "), "http://nas.local:32400")
        XCTAssertEqual(AppModel.serverAddress(from: "http://nas.local:8080"), "http://nas.local:8080")
        XCTAssertEqual(AppModel.serverAddress(from: "https://plex.example"), "https://plex.example")
    }

    func testAServerPathWithoutASlashDoesNotCrash() {
        XCTAssertEqual(makeClient().url("library/parts/1/file.mkv").path, "/library/parts/1/file.mkv")
    }

    func testPostersTrustTheNewestViewing() async throws {
        let older = #"{"MediaContainer":{"Metadata":[{"ratingKey":"1","key":"/k","type":"movie","title":"Detail","lastViewedAt":100}]}}"#
        StubURLProtocol.handler = answering { req in req.url?.path == "/library/sections" ? (200, Fixture.data("sections")) : (200, Data(older.utf8)) }
        let m = AppModel(secrets: signedIn(), session: StubURLProtocol.session(), images: ImageStore(cache: CountingCache()))
        await m.start()
        await m.loadDetail("1")
        func listItem(_ viewed: Int) throws -> PlexItem {
            let json = #"{"ratingKey":"1","key":"/k","type":"movie","title":"List","lastViewedAt":\#(viewed)}"#
            return try JSONDecoder().decode(PlexItem.self, from: Data(json.utf8))
        }
        XCTAssertEqual(m.current(try listItem(50)).title, "Detail", "a stale list must not undo a mark made on the detail page")
        XCTAssertEqual(m.current(try listItem(200)).title, "List", "a viewing on another device should show")
    }

    func testAFailedLaterPageKeepsThePostersAndCanBeRetried() async {
        func page(_ first: Int) -> Data {
            let rows = (first..<first + 60).map { #"{"ratingKey":"\#($0)","key":"/k","type":"movie","title":"T\#($0)"}"# }.joined(separator: ",")
            return Data(#"{"MediaContainer":{"totalSize":100,"Metadata":[\#(rows)]}}"#.utf8)
        }
        let one = page(0), two = page(60)
        StubURLProtocol.handler = { req in
            URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "X-Plex-Container-Start" }?.value == "0" ? (200, one) : (500, Data())
        }
        let model = LibraryModel()
        await model.configure(client: makeClient(), section: PlexSection(key: "1", type: "movie", title: "M"))
        await model.loadMore()
        XCTAssertEqual(model.items.count, 60)
        XCTAssertNotNil(model.error)
        StubURLProtocol.handler = { _ in (200, two) }
        await model.loadMore()
        XCTAssertEqual(model.items.count, 120)
        XCTAssertNil(model.error)
    }

    // MARK: Choosing an address (J-15)

    private let urls = [URL(string: "https://a.plex.direct:32400")!, URL(string: "http://10.0.0.5:32400")!]

    func testHTTPSIsUsedWhenItAnswers() async {
        StubURLProtocol.handler = { _ in (200, Data(#"{"MediaContainer":{"machineIdentifier":"m1"}}"#.utf8)) }
        let picked = await PlexConnectionPicker.firstReachable(urls, machineID: "m1", session: StubURLProtocol.session())
        XCTAssertEqual(picked, urls[0])
    }

    func testPlainAddressIsTheFallbackWhenHTTPSIsBlocked() async {
        StubURLProtocol.handler = { req in
            req.url?.scheme == "https" ? (500, Data()) : (200, Data(#"{"MediaContainer":{"machineIdentifier":"m1"}}"#.utf8))
        }
        let picked = await PlexConnectionPicker.firstReachable(urls, machineID: "m1", session: StubURLProtocol.session())
        XCTAssertEqual(picked, urls[1])
    }

    func testADifferentDeviceAtTheAddressIsSkipped() async {
        StubURLProtocol.handler = { _ in (200, Data(#"{"MediaContainer":{"machineIdentifier":"someone-else"}}"#.utf8)) }
        let picked = await PlexConnectionPicker.firstReachable(urls, machineID: "m1", session: StubURLProtocol.session())
        XCTAssertNil(picked, "the token must not go to a device that is not this server")
    }

    func testTheReachabilityCheckSendsNoToken() async {
        StubURLProtocol.handler = { _ in (200, Data()) }
        _ = await PlexConnectionPicker.firstReachable(urls, machineID: "m1", session: StubURLProtocol.session())
        XCTAssertNil(StubURLProtocol.seen.first?.value(forHTTPHeaderField: "X-Plex-Token"))
    }

    // MARK: Sign-in messages (J-07, J-11)

    func testARejectedTokenSaysWhy() async {
        StubURLProtocol.handler = answering { _ in (401, Data()) }
        let m = AppModel(secrets: signedIn(), session: StubURLProtocol.session(), images: ImageStore(cache: CountingCache()))
        await m.start()
        XCTAssertEqual(m.phase, .signedOut)
        XCTAssertEqual(m.signInNotice, AppModel.signInRefusedNotice)
    }

    func testTryingAgainClearsTheRejectedTokenMessage() async {
        StubURLProtocol.handler = answering { _ in (401, Data()) }
        let m = AppModel(secrets: signedIn(), session: StubURLProtocol.session(), images: ImageStore(cache: CountingCache()))
        await m.start()
        StubURLProtocol.handler = answering { _ in (200, Fixture.data("sections")) }
        await m.signInManually(address: "10.0.0.5", token: "good")
        XCTAssertNil(m.signInNotice)
        XCTAssertEqual(m.phase, .ready)
    }

    func testAKeychainThatRefusesTheTokenIsReported() async {
        StubURLProtocol.handler = { _ in (200, Fixture.data("sections")) }
        let m = AppModel(secrets: RefusingStore(), session: StubURLProtocol.session(), images: ImageStore(cache: CountingCache()))
        await m.signInManually(address: "10.0.0.5", token: "t")
        guard case .failed(let message) = m.phase else { return XCTFail("got \(m.phase)") }
        XCTAssertTrue(message.contains("Could not save"))
    }

    func testKeychainReplacesAValueInPlace() {
        let key = "test-\(UUID().uuidString)"
        defer { Keychain.remove(key) }
        XCTAssertTrue(Keychain.set("one", for: key))
        XCTAssertTrue(Keychain.set("two", for: key))
        XCTAssertEqual(Keychain.get(key), "two")
    }

    // MARK: Next episode and missing details (J-13)

    func testAFailedNextEpisodeLookupIsNotTheLastEpisode() async throws {
        StubURLProtocol.handler = { _ in (500, Data()) }
        let episode = try XCTUnwrap(Fixture.container("episodes").items.first)
        let model = PlayerModel(item: episode, client: makeClient())
        await model.loadNextEpisode()
        XCTAssertTrue(model.nextLookupFailed)
        XCTAssertNil(model.nextEpisode)
        StubURLProtocol.handler = { _ in (200, Fixture.data("episodes")) }
        await model.loadNextEpisode()
        XCTAssertFalse(model.nextLookupFailed, "a later try that works clears the failure")
    }

    func testALookUpAlreadyRunningIsNotStartedAgain() async throws {
        let episode = try XCTUnwrap(Fixture.container("episodes").items.first)
        StubURLProtocol.handler = { _ in (200, Fixture.data("episodes")) }
        let once = PlayerModel(item: episode, client: makeClient())
        await once.loadNextEpisode()
        let perLookUp = StubURLProtocol.seen.count
        XCTAssertGreaterThan(perLookUp, 0)

        StubURLProtocol.reset()
        StubURLProtocol.handler = { _ in (200, Fixture.data("episodes")) }
        StubURLProtocol.delayFor = { _ in 0.15 }
        let model = PlayerModel(item: episode, client: makeClient())
        async let first: Void = model.loadNextEpisode()
        try await Task.sleep(for: .milliseconds(30))
        await model.loadNextEpisode()               // pressed while the first is still waiting
        await first
        XCTAssertEqual(StubURLProtocol.seen.count, perLookUp, "the second press did not ask the server again")
    }

    func testPlayingWithoutFileDetailsDuringAnOutageSaysItIsTheNetwork() async throws {
        StubURLProtocol.handler = { _ in (500, Data()) }
        let bare = #"{"MediaContainer":{"Metadata":[{"ratingKey":"9","key":"/k","type":"episode","title":"No Details"}]}}"#
        let item = try XCTUnwrap(JSONDecoder().decode(PlexEnvelope<PlexContainer>.self, from: Data(bare.utf8)).MediaContainer.items.first)
        let model = PlayerModel(item: item, client: makeClient())
        await model.start(from: nil)
        guard case .failed(let message) = model.phase else { return XCTFail("got \(model.phase)") }
        XCTAssertFalse(message.contains("no playable file"), message)
    }

    // MARK: Person pages (J-14)

    func testAnUnreadableServerIsAnUnknownLibraryNotAnEmptyOne() async {
        StubURLProtocol.handler = answering { req in req.url?.path == "/library/sections" ? (200, Fixture.data("sections")) : (500, Data()) }
        let m = AppModel(secrets: signedIn(), session: StubURLProtocol.session(), images: ImageStore(cache: CountingCache()))
        await m.start()
        let catalog = await m.libraryCatalog()
        XCTAssertNil(catalog)
        let person = PersonModel()
        await person.load(tag: PlexTag(tag: "Someone"), app: m)
        XCTAssertTrue(person.libraryUnknown)
    }

    func testAPersonPageThatReadTheServerKnowsTheLibrary() async {
        let empty = #"{"MediaContainer":{"size":0,"totalSize":0,"Metadata":[]}}"#
        StubURLProtocol.handler = answering { req in req.url?.path == "/library/sections" ? (200, Fixture.data("sections")) : (200, Data(empty.utf8)) }
        let m = AppModel(secrets: signedIn(), session: StubURLProtocol.session(), images: ImageStore(cache: CountingCache()))
        await m.start()
        let person = PersonModel()
        await person.load(tag: PlexTag(tag: "Someone"), app: m)
        XCTAssertFalse(person.libraryUnknown)
    }

    // MARK: Odd data from the server (J-12)

    func testOneOddItemCostsThatItemNotThePage() throws {
        let json = #"{"MediaContainer":{"Metadata":[{"ratingKey":"1","key":"/k","type":"movie","title":"Good"},{"no":"ratingKey"}]}}"#
        let c = try JSONDecoder().decode(PlexEnvelope<PlexContainer>.self, from: Data(json.utf8)).MediaContainer
        XCTAssertEqual(c.items.map(\.title), ["Good"])
    }

    func testOneOddCreditCostsThatCreditNotTheGroup() throws {
        let json = #"{"title":"Actor","Credit":[{"role":"Lead","Metadata":{"ratingKey":"a","title":"Good"}},{"role":"Bad"}]}"#
        let g = try JSONDecoder().decode(CreditGroup.self, from: Data(json.utf8))
        XCTAssertEqual(g.Credit.map(\.Metadata.title), ["Good"])
    }

    func testAllTitlesFollowsTheServersCountWhenAPageComesBackShort() async throws {
        func page(_ n: Int, first: Int) -> String {
            var rows = (first..<first + n).map { #"{"ratingKey":"\#($0)","key":"/k","type":"movie","title":"T\#($0)"}"# }
            rows[0] = #"{"odd":true}"#
            return #"{"MediaContainer":{"size":\#(n),"totalSize":1500,"Metadata":[\#(rows.joined(separator: ","))]}}"#
        }
        let first = Data(page(1000, first: 0).utf8), second = Data(page(500, first: 1000).utf8)
        StubURLProtocol.handler = { req in
            let start = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "X-Plex-Container-Start" }?.value
            return (200, start == "0" ? first : second)
        }
        let all = try await makeClient().allTitles(in: [PlexSection(key: "1", type: "movie", title: "M")])
        XCTAssertEqual(all.count, 1498, "2 odd items are skipped, and the second page is still read")
    }
}

/// A Keychain that refuses every write.
final class RefusingStore: SecretStore {
    func read(_ key: String) -> SecretRead { .missing }
    func set(_ value: String, for key: String) -> Bool { false }
    func remove(_ key: String) -> Bool { false }
}
