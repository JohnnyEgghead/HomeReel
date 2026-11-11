import XCTest
@testable import HomeReel

final class AuthTests: XCTestCase {
    override func setUp() { StubURLProtocol.reset() }

    func testCreatePinAndCheckPin() async throws {
        StubURLProtocol.handler = { req in
            if req.httpMethod == "POST" { return (201, Data(#"{"id":7,"code":"ABCD","authToken":null}"#.utf8)) }
            return (200, Data(#"{"id":7,"code":"ABCD","authToken":"tok"}"#.utf8))
        }
        let auth = PlexAuth(identity: testIdentity, session: StubURLProtocol.session())
        let pin = try await auth.createPin()
        XCTAssertEqual(pin.code, "ABCD")
        XCTAssertNil(pin.authToken)
        let token = try await auth.checkPin(7)
        XCTAssertEqual(token, "tok")
        XCTAssertEqual(StubURLProtocol.seen[0].url?.host, "plex.tv")
        XCTAssertEqual(StubURLProtocol.seen[0].value(forHTTPHeaderField: "X-Plex-Client-Identifier"), "test-client-id")
    }

    func testServersKeepsOnlyServers() async throws {
        let json = """
        [{"name":"NAS","provides":"server","owned":true,"connections":[{"uri":"http://10.0.0.5:32400","local":true,"relay":false,"protocol":"http"}]},
         {"name":"Phone","provides":"client","owned":true,"connections":[]}]
        """
        StubURLProtocol.handler = { _ in (200, Data(json.utf8)) }
        let auth = PlexAuth(identity: testIdentity, session: StubURLProtocol.session())
        let servers = try await auth.servers(token: "t")
        XCTAssertEqual(servers.map(\.name), ["NAS"])
        XCTAssertEqual(StubURLProtocol.seen[0].value(forHTTPHeaderField: "X-Plex-Token"), "t")
    }

    func testConnectionOrderIsLocalFirstAndNeverRelay() {
        let s = PlexResource(name: "NAS", provides: "server", owned: true, connections: [
            PlexResourceConnection(uri: "https://remote.example:443", local: false, relay: false, protocol: "https"),
            PlexResourceConnection(uri: "https://relay.plex.direct:8443", local: false, relay: true, protocol: "https"),
            PlexResourceConnection(uri: "http://10.0.0.5:32400", local: true, relay: false, protocol: "http"),
        ])
        XCTAssertEqual(PlexConnectionPicker.candidates(for: s).map(\.absoluteString),
                       ["http://10.0.0.5:32400", "https://remote.example:443"])
    }

    func testLocalServerTriesPlexDirectNameBeforePlainIP() throws {
        let json = #"""
        [{"name":"NAS","provides":"server","owned":true,"connections":[
          {"protocol":"https","address":"10.0.0.5","port":32400,
           "uri":"https://10-0-0-5.abc.plex.direct:32400","local":true,"relay":false}]}]
        """#
        let servers = try JSONDecoder().decode([PlexResource].self, from: Data(json.utf8))
        XCTAssertEqual(PlexConnectionPicker.candidates(for: servers[0]).map(\.absoluteString),
                       ["https://10-0-0-5.abc.plex.direct:32400", "http://10.0.0.5:32400"], "https first, plain address as the fallback")
    }

    func testFirstReachableSkipsDeadAddresses() async {
        StubURLProtocol.handler = { req in req.url!.host == "10.0.0.9" ? (200, Data(#"{"MediaContainer":{"machineIdentifier":"m1"}}"#.utf8)) : (500, Data()) }
        let r = await PlexConnectionPicker.firstReachable(
            [URL(string: "http://10.0.0.8:32400")!, URL(string: "http://10.0.0.9:32400")!], machineID: "m1", session: StubURLProtocol.session())
        XCTAssertEqual(r?.host, "10.0.0.9")
    }

    func testFirstReachableReturnsNilWhenNothingAnswers() async {
        StubURLProtocol.handler = { _ in (500, Data()) }
        let r = await PlexConnectionPicker.firstReachable([URL(string: "http://10.0.0.8:32400")!], machineID: "m1", session: StubURLProtocol.session())
        XCTAssertNil(r)
    }
}

@MainActor
final class AppModelTests: XCTestCase {
    override func setUp() { StubURLProtocol.reset() }

    func testStartWithNothingSavedIsSignedOut() async {
        let m = AppModel(secrets: InMemorySecretStore(), session: StubURLProtocol.session())
        await m.start()
        XCTAssertEqual(m.phase, .signedOut)
    }

    func testStartWithSavedLoginBecomesReady() async {
        StubURLProtocol.handler = answering { _ in (200, Fixture.data("sections")) }
        let store = InMemorySecretStore([AppModel.Key.token: "t", AppModel.Key.server: "http://10.0.0.5:32400", AppModel.Key.serverName: "NAS"])
        let m = AppModel(secrets: store, session: StubURLProtocol.session())
        await m.start()
        XCTAssertEqual(m.phase, .ready)
        XCTAssertEqual(m.serverName, "NAS")
        XCTAssertEqual(m.movieLibraries.map(\.title), ["Movies"])
        XCTAssertEqual(m.showLibraries.map(\.title), ["TV Shows"])
    }

    func testRejectedTokenIsForgottenAndSignsOut() async {
        StubURLProtocol.handler = answering { _ in (401, Data()) }
        let store = InMemorySecretStore([AppModel.Key.token: "old", AppModel.Key.server: "http://10.0.0.5:32400"])
        let m = AppModel(secrets: store, session: StubURLProtocol.session())
        await m.start()
        XCTAssertEqual(m.phase, .signedOut)
        XCTAssertNil(store.get(AppModel.Key.token))
    }

    func testUnreachableServerShowsFailureAndKeepsLogin() async {
        StubURLProtocol.handler = answering { _ in (503, Data()) }
        let store = InMemorySecretStore([AppModel.Key.token: "t", AppModel.Key.server: "http://10.0.0.5:32400"])
        let m = AppModel(secrets: store, session: StubURLProtocol.session())
        await m.start()
        if case .failed = m.phase {} else { XCTFail("expected failed, got \(m.phase)") }
        XCTAssertNotNil(store.get(AppModel.Key.token))
    }

    func testSignOutClearsEverything() async {
        StubURLProtocol.handler = answering { _ in (200, Fixture.data("sections")) }
        let store = InMemorySecretStore([AppModel.Key.token: "t", AppModel.Key.server: "http://10.0.0.5:32400"])
        let m = AppModel(secrets: store, session: StubURLProtocol.session())
        await m.start()
        m.signOut()
        XCTAssertEqual(m.phase, .signedOut)
        XCTAssertNil(m.client)
        XCTAssertNil(store.get(AppModel.Key.token))
        XCTAssertNil(store.get(AppModel.Key.server))
    }

    func testSignOutClearsThePictureCache() async {
        StubURLProtocol.handler = answering { _ in (200, Fixture.data("sections")) }
        let store = InMemorySecretStore([AppModel.Key.token: "t", AppModel.Key.server: "http://10.0.0.5:32400"])
        let cache = CountingCache()
        let m = AppModel(secrets: store, session: StubURLProtocol.session(), images: ImageStore(cache: cache))
        m.signOut()
        XCTAssertEqual(cache.cleared, 1)
    }

    func testPersonPhotosSendTheTokenOnlyToTheServer() async throws {
        StubURLProtocol.handler = answering { _ in (200, Fixture.data("sections")) }
        let store = InMemorySecretStore([AppModel.Key.token: "t", AppModel.Key.server: "http://10.0.0.5:32400"])
        let m = AppModel(secrets: store, session: StubURLProtocol.session())
        await m.start()
        let web = try XCTUnwrap(PersonImages.request("https://metadata-static.plex.tv/a.jpg", app: m, size: 300))
        XCTAssertNil(web.value(forHTTPHeaderField: "X-Plex-Token"), "the token must never leave for another host")
        let server = try XCTUnwrap(PersonImages.request("/library/metadata/1/thumb", app: m, size: 300))
        XCTAssertEqual(server.value(forHTTPHeaderField: "X-Plex-Token"), "t")
    }

    func testWebPicturesCarryNoToken() throws {
        let r = try XCTUnwrap(RemoteImage(url: URL(string: "https://image.tmdb.org/t/p/w342/a.jpg")).request)
        XCTAssertNil(r.value(forHTTPHeaderField: "X-Plex-Token"))
    }

    func testPictureFetchKeepsTheTokenInTheHeader() async throws {
        StubURLProtocol.handler = { _ in (404, Data()) }
        let images = ImageStore(cache: CountingCache())
        images.use(session: StubURLProtocol.session())
        let r = try XCTUnwrap(makeClient().imageRequest("/library/metadata/1/thumb", width: 10, height: 10))
        _ = await images.image(for: r)
        let sent = try XCTUnwrap(StubURLProtocol.seen.first)
        XCTAssertEqual(sent.value(forHTTPHeaderField: "X-Plex-Token"), "SECRET")
        XCTAssertFalse(try XCTUnwrap(sent.url).absoluteString.contains("SECRET"))
    }

    func testOldCacheIsRemovedOnlyOnce() throws {
        let suite = "homereel.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cache = CountingCache()
        let images = ImageStore(cache: cache)
        images.removeOldCacheOnce(defaults: defaults)
        images.removeOldCacheOnce(defaults: defaults)
        XCTAssertEqual(cache.cleared, 1)
    }

    func testManualSignInAddsSchemeAndDefaultPort() async {
        StubURLProtocol.handler = answering { _ in (200, Fixture.data("sections")) }
        let store = InMemorySecretStore()
        let m = AppModel(secrets: store, session: StubURLProtocol.session())
        await m.signInManually(address: "10.0.0.5", token: " tok ")
        XCTAssertEqual(store.get(AppModel.Key.server), "http://10.0.0.5:32400")
        XCTAssertEqual(store.get(AppModel.Key.token), "tok")
        XCTAssertEqual(m.phase, .ready)
    }

    func testLoadDetailKeepsFullCastInTheAppModel() async throws {
        StubURLProtocol.handler = answering { req in
            req.url!.path.hasPrefix("/library/metadata/") ? (200, Fixture.data("movie_detail")) : (200, Fixture.data("sections"))
        }
        let store = InMemorySecretStore([AppModel.Key.token: "t", AppModel.Key.server: "http://10.0.0.5:32400"])
        let m = AppModel(secrets: store, session: StubURLProtocol.session())
        await m.start()
        let key = try Fixture.container("movie_detail").items[0].ratingKey
        XCTAssertNil(m.details[key])
        await m.loadDetail(key)
        XCTAssertFalse((m.details[key]?.Role ?? []).isEmpty)
        m.signOut()
        XCTAssertTrue(m.details.isEmpty)
    }

    func testCurrentPrefersLoadedDetailOverListCopy() async throws {
        StubURLProtocol.handler = answering { req in
            req.url!.path.hasPrefix("/library/metadata/") ? (200, Fixture.data("movie_detail")) : (200, Fixture.data("sections"))
        }
        let store = InMemorySecretStore([AppModel.Key.token: "t", AppModel.Key.server: "http://10.0.0.5:32400"])
        let m = AppModel(secrets: store, session: StubURLProtocol.session())
        await m.start()
        var listCopy = try Fixture.container("movie_detail").items[0]
        listCopy.viewCount = nil
        listCopy.Role = nil
        XCTAssertNil(m.current(listCopy).Role, "nothing loaded yet: the list copy is shown")
        await m.loadDetail(listCopy.ratingKey)
        XCTAssertFalse((m.current(listCopy).Role ?? []).isEmpty, "after loading: the full copy is shown")
    }

    func testEpisodeChangeAlsoReloadsSeasonAndShow() async throws {
        StubURLProtocol.handler = answering { req in
            req.url!.path.hasPrefix("/library/metadata/") ? (200, Fixture.data("movie_detail")) : (200, Fixture.data("sections"))
        }
        let store = InMemorySecretStore([AppModel.Key.token: "t", AppModel.Key.server: "http://10.0.0.5:32400"])
        let m = AppModel(secrets: store, session: StubURLProtocol.session())
        await m.start()
        StubURLProtocol.seen = []
        var ep = try Fixture.container("episodes").items[0]
        ep.parentRatingKey = "P1"; ep.grandparentRatingKey = "G1"
        await m.loadDetailAndParents(ep)
        let paths = StubURLProtocol.seen.map { $0.url!.path }
        XCTAssertEqual(paths, ["/library/metadata/\(ep.ratingKey)", "/library/metadata/P1", "/library/metadata/G1"])
    }

    func testALoadThatFailsReturnsWhyAndOneThatWorksReturnsNothing() async {
        StubURLProtocol.handler = answering { r in r.url!.path.hasPrefix("/library/metadata/") ? (500, Data()) : (200, Fixture.data("sections")) }
        let m = AppModel(secrets: InMemorySecretStore([AppModel.Key.token: "t", AppModel.Key.server: "http://10.0.0.5:32400"]), session: StubURLProtocol.session())
        await m.start()
        let problem = await m.loadDetail("1")
        XCTAssertEqual(problem, PlexError.badResponse(500).errorDescription, "the page can say why")
        StubURLProtocol.handler = answering { r in r.url!.path.hasPrefix("/library/metadata/") ? (200, Fixture.data("movie_detail")) : (200, Fixture.data("sections")) }
        let ok = await m.loadDetail("16218")
        XCTAssertNil(ok)
    }

    // MARK: Typed sign-in (J-19) and the code sign-in's poll (J-18)

    func testOnlyARealAddressIsAccepted() {
        XCTAssertEqual(AppModel.validServerAddress("10.0.0.5"), "http://10.0.0.5:32400")
        XCTAssertEqual(AppModel.validServerAddress("https://nas.example:443"), "https://nas.example:443")
        for bad in ["", "   ", "http://", "ftp://nas", "my server", "http://bad host", "://"] {
            XCTAssertNil(AppModel.validServerAddress(bad), "\"\(bad)\" is not an address")
        }
    }

    func testATypoInTheAddressSaysSoAndSavesNothing() async {
        let store = InMemorySecretStore()
        let m = AppModel(secrets: store, session: StubURLProtocol.session())
        await m.signInManually(address: "my server", token: "tok")
        XCTAssertEqual(m.phase, .signedOut)
        XCTAssertNotNil(m.signInNotice)
        XCTAssertNil(store.get(AppModel.Key.token))
        XCTAssertNil(store.get(AppModel.Key.server))
        await m.signInManually(address: "10.0.0.5", token: "   ")
        XCTAssertEqual(m.signInNotice, "Enter your Plex token.")
        XCTAssertNil(store.get(AppModel.Key.server))
    }

    func testADroppedCodeCheckDoesNotEndTheSignIn() async throws {
        let checks = CheckCounter()
        let resources = #"[{"name":"NAS","provides":"server","owned":true,"clientIdentifier":"m1","connections":[{"uri":"http://10.0.0.5:32400","address":"10.0.0.5","port":32400,"local":true,"relay":false}]}]"#
        StubURLProtocol.handler = answering { r in
            if r.url?.host == "plex.tv" {
                if r.url!.path.hasSuffix("/pins") { return (201, Data(#"{"id":1,"code":"ABCD","authToken":null}"#.utf8)) }
                if r.url!.path.contains("/pins/") {
                    let n = checks.next()
                    return n == 1 ? (200, Data(#"{"id":1,"code":"ABCD","authToken":null}"#.utf8))
                        : n == 2 ? (500, Data())                                                  // one check is lost
                        : (200, Data(#"{"id":1,"code":"ABCD","authToken":"tok"}"#.utf8))
                }
                return (200, Data(resources.utf8))
            }
            return (200, Fixture.data("sections"))
        }
        let m = AppModel(secrets: InMemorySecretStore(), session: StubURLProtocol.session())
        m.linkPollInterval = .milliseconds(10)
        m.signInWithCode()
        for _ in 0..<300 where m.phase != .ready { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(m.phase, .ready, "the lost check was tried again")
    }

    func testClientIDIsStable() {
        let store = InMemorySecretStore()
        let m = AppModel(secrets: store, session: StubURLProtocol.session())
        XCTAssertEqual(m.identity.clientID, m.identity.clientID)
        XCTAssertNotNil(store.get(AppModel.Key.clientID))
    }
}

/// Counts calls, safely from any thread.
final class CheckCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
}

/// Counts how often the picture cache is emptied.
final class CountingCache: URLCache, @unchecked Sendable {
    private(set) var cleared = 0
    override func removeAllCachedResponses() { cleared += 1 }
}
