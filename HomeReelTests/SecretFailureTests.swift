import XCTest
@testable import HomeReel

/// A secret store that fails on purpose, and records what was asked of it.
final class FailingSecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String]
    var unreadable: Set<String> = []
    var removalFails = false
    var writesFail = false
    private(set) var writes: [String] = []
    private(set) var removals: [String] = []

    init(_ initial: [String: String] = [:]) { values = initial }

    func read(_ key: String) -> SecretRead {
        lock.lock(); defer { lock.unlock() }
        if unreadable.contains(key) { return .failed(-25308) }       // errSecInteractionNotAllowed: locked
        return values[key].map(SecretRead.value) ?? .missing
    }
    func set(_ value: String, for key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        writes.append(key)
        if writesFail { return false }
        values[key] = value
        return true
    }
    func remove(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        removals.append(key)
        if removalFails { return false }
        values[key] = nil
        return true
    }
}

/// Keychain trouble must not look like "nothing saved" (J-17).
@MainActor
final class SecretFailureTests: XCTestCase {
    override func setUp() { StubURLProtocol.reset() }

    private func saved() -> [String: String] {
        [AppModel.Key.token: "t", AppModel.Key.server: "http://10.0.0.5:32400", AppModel.Key.serverID: "m1"]
    }

    func testASavedSignInThatCannotBeReadIsNotTreatedAsSignedOut() async {
        let store = FailingSecretStore(saved())
        store.unreadable = [AppModel.Key.token]
        let m = AppModel(secrets: store, session: StubURLProtocol.session())
        await m.start()
        guard case .failed(let message) = m.phase else { return XCTFail("expected a failure, got \(m.phase)") }
        XCTAssertTrue(message.contains("Nothing was deleted"))
        XCTAssertTrue(store.removals.isEmpty, "the sign-in is left alone")
        XCTAssertTrue(StubURLProtocol.seen.isEmpty, "and no token went anywhere")
    }

    func testTryingAgainAfterTheStoreComesBackSignsIn() async {
        StubURLProtocol.handler = answering { _ in (200, Fixture.data("sections")) }
        let store = FailingSecretStore(saved())
        store.unreadable = [AppModel.Key.token]
        let m = AppModel(secrets: store, session: StubURLProtocol.session())
        await m.start()
        store.unreadable = []
        await m.connect()
        XCTAssertEqual(m.phase, .ready)
    }

    func testAnIdThatCannotBeReadIsNeverWrittenOver() {
        let store = FailingSecretStore(["clientID": "real-id"])
        store.unreadable = [AppModel.Key.clientID]
        let m = AppModel(secrets: store, session: StubURLProtocol.session())
        XCTAssertFalse(m.identity.clientID.isEmpty)
        XCTAssertNotEqual(m.identity.clientID, "real-id")
        XCTAssertFalse(store.writes.contains(AppModel.Key.clientID), "the stored id must survive")
    }

    func testANewIdIsMadeAndKeptWhenNoneExists() {
        let store = FailingSecretStore()
        let m = AppModel(secrets: store, session: StubURLProtocol.session())
        XCTAssertEqual(store.get(AppModel.Key.clientID), m.identity.clientID)
    }

    func testSavingTheTVReportsAFailedSave() {
        let store = FailingSecretStore()
        let m = AppModel(secrets: store, session: StubURLProtocol.session())
        XCTAssertTrue(m.saveTV(host: "192.0.2.50", key: "k"))
        store.writesFail = true
        XCTAssertFalse(m.saveTV(host: "192.0.2.51", key: "k2"))
        store.removalFails = true
        XCTAssertFalse(m.saveTV(host: "", key: ""), "clearing counts too")
    }

    func testSignOutSaysWhenTheSavedSignInCouldNotBeDeleted() async {
        StubURLProtocol.handler = answering { _ in (200, Fixture.data("sections")) }
        let store = FailingSecretStore(saved())
        let m = AppModel(secrets: store, session: StubURLProtocol.session())
        await m.start()
        store.removalFails = true
        m.signOut()
        XCTAssertEqual(m.phase, .signedOut)
        XCTAssertNotNil(m.signInNotice)
        XCTAssertEqual(Set(store.removals), [AppModel.Key.token, AppModel.Key.server, AppModel.Key.serverName, AppModel.Key.serverID],
                       "every item is tried even after one fails")
    }

    func testTheRealKeychainTellsMissingFromFound() {
        let key = "test-\(UUID().uuidString)"
        defer { Keychain.remove(key) }
        XCTAssertEqual(Keychain.read(key), .missing)
        XCTAssertTrue(Keychain.set("v", for: key))
        XCTAssertEqual(Keychain.read(key), .value("v"))
        XCTAssertTrue(Keychain.remove(key))
        XCTAssertTrue(Keychain.remove(key), "removing what is not there still leaves it gone")
        XCTAssertEqual(Keychain.read(key), .missing)
    }
}

/// Which copy of an item is shown (J-21), and what the remote may do while loading (J-22).
@MainActor
final class FreshnessAndLoadingTests: XCTestCase {
    override func setUp() { StubURLProtocol.reset() }

    private func readyModel() async -> AppModel {
        StubURLProtocol.handler = answering { r in r.url!.path.hasPrefix("/library/metadata/") ? (200, Fixture.data("movie_detail")) : (200, Fixture.data("sections")) }
        let m = AppModel(secrets: InMemorySecretStore([AppModel.Key.token: "t", AppModel.Key.server: "http://10.0.0.5:32400", AppModel.Key.serverID: "m1"]),
                         session: StubURLProtocol.session())
        await m.start()
        return m
    }

    func testANewerListCopyShowsAnUnwatchedMarkMadeElsewhere() async throws {
        let m = await readyModel()
        let detail = try XCTUnwrap(Fixture.container("movie_detail").items.first)
        await m.loadDetail(detail.ratingKey)
        let full = try XCTUnwrap(m.details[detail.ratingKey])
        XCTAssertNotNil(full.fetchedAt)
        try await Task.sleep(for: .milliseconds(20))
        // The list is fetched later, after the item was marked unwatched on another device (Plex keeps lastViewedAt).
        var list = try XCTUnwrap(Fixture.container("movie_detail").items.first)
        list.viewCount = nil
        list.viewOffset = nil
        list.lastViewedAt = full.lastViewedAt
        XCTAssertGreaterThan(try XCTUnwrap(list.fetchedAt), try XCTUnwrap(full.fetchedAt))
        XCTAssertFalse(m.current(list).isWatched, "the newer copy wins")
    }

    func testANewerDetailBeatsAnOlderListCopy() async throws {
        var list = try XCTUnwrap(Fixture.container("movie_detail").items.first)
        list.viewCount = nil
        list.viewOffset = nil
        try await Task.sleep(for: .milliseconds(20))
        let m = await readyModel()                     // details are fetched after the list copy
        await m.loadDetail(list.ratingKey)
        let full = try XCTUnwrap(m.details[list.ratingKey])
        XCTAssertEqual(m.current(list).viewCount, full.viewCount)
    }

    func testCopiesWithNoStampFallBackToTheLastViewedTime() async throws {
        let m = await readyModel()
        var list = try XCTUnwrap(Fixture.container("movie_detail").items.first)
        await m.loadDetail(list.ratingKey)
        let full = try XCTUnwrap(m.details[list.ratingKey])
        list.fetchedAt = nil
        list.lastViewedAt = (full.lastViewedAt ?? 0) + 100
        XCTAssertEqual(m.current(list).lastViewedAt, list.lastViewedAt)
    }

    func testSkipScrubAndPlayDoNothingWhileLoading() throws {
        let item = try XCTUnwrap(Fixture.container("movie_detail").items.first)
        let model = PlayerModel(item: item, client: makeClient())
        XCTAssertEqual(model.phase, .loading)
        model.scrubBegan()
        XCTAssertFalse(model.isScrubbing, "no scrubbing before the picture plays")
        model.setPhaseForTesting(.playing)
        model.scrubBegan()
        XCTAssertTrue(model.isScrubbing)
    }
}
