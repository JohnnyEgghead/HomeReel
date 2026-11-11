import XCTest
@testable import HomeReel

/// What a Plex server answers at /identity.
private func machineAnswer(_ id: String) -> (Int, Data) { (200, Data(#"{"MediaContainer":{"machineIdentifier":"\#(id)"}}"#.utf8)) }

/// One sign-in owns its data (J-8), a revoked token ends it in one place (J-9), and the saved address has to be
/// the same server before the token goes there (J-12).
@MainActor
final class SessionTests: XCTestCase {
    override func setUp() { StubURLProtocol.reset() }

    private func signedIn(serverID: String? = "m1", server: String = "http://10.0.0.5:32400") -> InMemorySecretStore {
        var v = [AppModel.Key.token: "t", AppModel.Key.server: server, AppModel.Key.serverName: "NAS"]
        if let serverID { v[AppModel.Key.serverID] = serverID }
        return InMemorySecretStore(v)
    }

    private func model(_ store: InMemorySecretStore) -> AppModel {
        AppModel(secrets: store, session: StubURLProtocol.session(), images: ImageStore(cache: CountingCache()))
    }

    private func waitUntil(_ what: String, _ done: () -> Bool) async throws {
        for _ in 0..<100 where !done() { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(done(), what)
    }

    // MARK: J-8 one owner per sign-in

    func testAPageFetchedBeforeSignOutNeverAppearsAfterTheNextSignIn() async throws {
        StubURLProtocol.handler = answering { r in r.url!.path.hasPrefix("/library/metadata/") ? (200, Fixture.data("movie_detail")) : (200, Fixture.data("sections")) }
        StubURLProtocol.delayFor = { r in r.url!.path.hasPrefix("/library/metadata/") ? 0.3 : 0 }
        let m = model(signedIn())
        await m.start()
        let late = Task { await m.loadDetail("16218") }       // answers 0.3 seconds from now
        try await Task.sleep(for: .milliseconds(50))
        m.signOut()
        await m.signInManually(address: "10.0.0.6", token: "t2")
        XCTAssertEqual(m.phase, .ready)
        await late.value
        XCTAssertTrue(m.details.isEmpty, "the answer belongs to the sign-in that asked")
    }

    func testSignInAfterARejectedTokenStartsWithEmptyCaches() async throws {
        StubURLProtocol.handler = answering { r in r.url!.path.hasPrefix("/library/metadata/") ? (200, Fixture.data("movie_detail")) : (200, Fixture.data("sections")) }
        let m = model(signedIn())
        await m.start()
        await m.loadDetail("16218")
        XCTAssertFalse(m.details.isEmpty)
        StubURLProtocol.handler = answering { _ in (401, Data()) }
        _ = try? await m.client?.metadata("1")
        try await waitUntil("signed out by the 401") { m.phase == .signedOut }
        StubURLProtocol.handler = answering { _ in (200, Fixture.data("sections")) }
        await m.signInManually(address: "10.0.0.5", token: "t2")
        XCTAssertEqual(m.phase, .ready)
        XCTAssertTrue(m.details.isEmpty, "nothing from the earlier sign-in is shown")
    }

    func testTypingAnAddressStopsAPendingCodeSignIn() async throws {
        StubURLProtocol.handler = answering { r in
            if r.url?.host == "plex.tv" {
                if r.url!.path.hasSuffix("/pins") { return (201, Data(#"{"id":1,"code":"ABCD","authToken":null}"#.utf8)) }
                if r.url!.path.contains("/pins/") { return (200, Data(#"{"id":1,"code":"ABCD","authToken":"late"}"#.utf8)) }
                return (500, Data())            // the code sign-in would end in a failure if it ran on
            }
            return (200, Fixture.data("sections"))
        }
        let m = model(InMemorySecretStore())
        m.linkPollInterval = .milliseconds(100)
        m.signInWithCode()
        try await waitUntil("the code is showing") { if case .linking = m.phase { return true } else { return false } }
        await m.signInManually(address: "10.0.0.5", token: "typed")
        XCTAssertEqual(m.phase, .ready)
        try await Task.sleep(for: .seconds(0.8))      // several poll waits of the code sign-in
        XCTAssertEqual(m.phase, .ready, "the code sign-in must not finish over the typed one")
    }

    func testSubtitleChoicesAreKeptPerServer() throws {
        let item = try XCTUnwrap(Fixture.container("movie_detail").items.first)
        let a = PlayerModel(item: item, client: PlexClient(baseURL: URL(string: "http://a")!, token: "t", identity: testIdentity, serverID: "serverA"))
        let b = PlayerModel(item: item, client: PlexClient(baseURL: URL(string: "http://b")!, token: "t", identity: testIdentity, serverID: "serverB"))
        XCTAssertNotEqual(a.prefKey, b.prefKey)
        let none = PlayerModel(item: item, client: makeClient())
        XCTAssertEqual(none.prefKey, item.ratingKey, "with no server id the key is the one earlier versions used")
    }

    // MARK: J-9 a revoked token

    func testAnyScreensRejectedRequestSignsOutWithTheNotice() async throws {
        StubURLProtocol.handler = answering { _ in (200, Fixture.data("sections")) }
        let store = signedIn()
        let m = model(store)
        await m.start()
        XCTAssertEqual(m.phase, .ready)
        StubURLProtocol.handler = answering { _ in (401, Data()) }
        _ = try? await m.client?.children("5")            // some screen's request, nowhere near sign-in code
        try await waitUntil("signed out") { m.phase == .signedOut }
        XCTAssertEqual(m.signInNotice, AppModel.signInRefusedNotice)
        XCTAssertNil(store.get(AppModel.Key.token))
        XCTAssertNil(m.client)
    }

    func testAnOldSignInsLateRejectionDoesNotEndTheNewOne() async throws {
        StubURLProtocol.handler = answering { _ in (200, Fixture.data("sections")) }
        let m = model(signedIn())
        await m.start()
        let old = try XCTUnwrap(m.client)
        m.signOut()
        await m.signInManually(address: "10.0.0.5", token: "t2")
        XCTAssertEqual(m.phase, .ready)
        StubURLProtocol.handler = answering { _ in (401, Data()) }
        _ = try? await old.children("5")
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(m.phase, .ready, "a rejection for a sign-in that is gone changes nothing")
    }

    // MARK: J-12 the saved address must be the same server

    func testAWrongServerAtTheSavedAddressReceivesNoToken() async throws {
        StubURLProtocol.handler = { r in
            if r.url?.path == "/identity" { return machineAnswer("someone-else") }
            if r.url?.host == "plex.tv" { return (200, Data("[]".utf8)) }
            return (200, Fixture.data("sections"))
        }
        let m = model(signedIn())
        await m.start()
        if case .failed = m.phase {} else { XCTFail("expected a failure, got \(m.phase)") }
        let toServer = StubURLProtocol.seen.filter { $0.url?.host == "10.0.0.5" }
        XCTAssertFalse(toServer.isEmpty, "the check itself was made")
        XCTAssertTrue(toServer.allSatisfy { $0.value(forHTTPHeaderField: "X-Plex-Token") == nil }, "but it carried no token")
    }

    func testAMovedServerIsFoundAgainThroughPlexTV() async throws {
        let resources = #"[{"name":"NAS","provides":"server","owned":true,"clientIdentifier":"m1","connections":[{"uri":"http://10.0.0.7:32400","address":"10.0.0.7","port":32400,"local":true,"relay":false}]}]"#
        StubURLProtocol.handler = { r in
            if r.url?.path == "/identity" { return r.url?.host == "10.0.0.7" ? machineAnswer("m1") : (500, Data()) }
            if r.url?.host == "plex.tv" { return (200, Data(resources.utf8)) }
            return (200, Fixture.data("sections"))
        }
        let store = signedIn()
        let m = model(store)
        await m.start()
        XCTAssertEqual(m.phase, .ready)
        XCTAssertEqual(m.client?.baseURL.host(), "10.0.0.7")
        XCTAssertEqual(store.get(AppModel.Key.server), "http://10.0.0.7:32400", "the new address is kept")
    }

    func testServerNotListedByPlexTVFailsWithAMessage() async throws {
        StubURLProtocol.handler = { r in
            if r.url?.path == "/identity" { return (500, Data()) }
            if r.url?.host == "plex.tv" { return (200, Data("[]".utf8)) }
            return (200, Fixture.data("sections"))
        }
        let m = model(signedIn())
        await m.start()
        guard case .failed(let message) = m.phase else { return XCTFail("expected a failure, got \(m.phase)") }
        XCTAssertTrue(message.contains("NAS"))
    }

    func testRevokedTokenFoundWhileLookingForTheServerSignsOut() async throws {
        StubURLProtocol.handler = { r in
            if r.url?.path == "/identity" { return (500, Data()) }
            if r.url?.host == "plex.tv" { return (401, Data()) }
            return (200, Fixture.data("sections"))
        }
        let store = signedIn()
        let m = model(store)
        await m.start()
        XCTAssertEqual(m.phase, .signedOut)
        XCTAssertNotNil(m.signInNotice)
        XCTAssertNil(store.get(AppModel.Key.token))
    }

    func testAnAddressWithNoSavedIdLearnsItOnceAndThenHoldsIt() async throws {
        StubURLProtocol.handler = { r in r.url?.path == "/identity" ? machineAnswer("m1") : (200, Fixture.data("sections")) }
        let store = signedIn(serverID: nil)
        await model(store).start()
        XCTAssertEqual(store.get(AppModel.Key.serverID), "m1", "the first connection records which server this is")
        // Later, something else answers at the same address.
        StubURLProtocol.reset()
        StubURLProtocol.handler = { r in
            if r.url?.path == "/identity" { return machineAnswer("impostor") }
            if r.url?.host == "plex.tv" { return (200, Data("[]".utf8)) }
            return (200, Fixture.data("sections"))
        }
        let m = model(store)
        await m.start()
        if case .failed = m.phase {} else { XCTFail("expected a failure, got \(m.phase)") }
        XCTAssertTrue(StubURLProtocol.seen.filter { $0.url?.host == "10.0.0.5" }.allSatisfy { $0.value(forHTTPHeaderField: "X-Plex-Token") == nil })
    }

    func testAnAddressThatCannotBeAskedWhoItIsIsNotTrusted() async throws {
        StubURLProtocol.handler = { r in r.url?.path == "/identity" ? (500, Data()) : (200, Fixture.data("sections")) }
        let m = model(signedIn(serverID: nil))
        await m.start()
        if case .failed = m.phase {} else { XCTFail("expected a failure, got \(m.phase)") }
        XCTAssertTrue(StubURLProtocol.seen.allSatisfy { $0.value(forHTTPHeaderField: "X-Plex-Token") == nil })
    }

    func testTypingADifferentServerForgetsTheOldId() async throws {
        StubURLProtocol.handler = { r in r.url?.path == "/identity" ? machineAnswer("new-server") : (200, Fixture.data("sections")) }
        let store = signedIn(serverID: "old-server")
        let m = model(store)
        await m.signInManually(address: "10.0.0.9", token: "t2")
        XCTAssertEqual(m.phase, .ready)
        XCTAssertEqual(store.get(AppModel.Key.serverID), "new-server")
    }

    func testAnAnswerWithNoIdIsNotAcceptedAsTheServer() async {
        StubURLProtocol.handler = { _ in (200, Data(#"{"MediaContainer":{}}"#.utf8)) }
        let picked = await PlexConnectionPicker.firstReachable([URL(string: "http://10.0.0.5:32400")!], machineID: "m1", session: StubURLProtocol.session())
        XCTAssertNil(picked)
    }
}
