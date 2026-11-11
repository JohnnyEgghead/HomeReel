import XCTest
@testable import HomeReel

/// Answers the first request with a redirect to another address, copying the headers as the system does, and every
/// later request with 200. Records every request that reaches it.
final class RedirectURLProtocol: URLProtocol {
    nonisolated(unsafe) static var target = "http://elsewhere.example:32400/x"
    nonisolated(unsafe) static var seen: [URLRequest] = []
    private static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.seen.append(request); Self.lock.unlock()
        let isFirst = request.url?.absoluteString.hasSuffix("/first") == true
        if isFirst {
            var next = URLRequest(url: URL(string: Self.target)!)
            next.allHTTPHeaderFields = request.allHTTPHeaderFields
            let resp = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil, headerFields: ["Location": Self.target])!
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: resp)
            return
        }
        let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    static func reset() { lock.lock(); seen = []; lock.unlock() }
    static var hosts: [String] { lock.lock(); defer { lock.unlock() }; return seen.compactMap { $0.url?.host } }
}

/// A knob a test turns while the app runs, safely from any thread.
final class Knob: @unchecked Sendable {
    private let lock = NSLock()
    private var v: Int
    init(_ v: Int) { self.v = v }
    var value: Int { get { lock.lock(); defer { lock.unlock() }; return v } set { lock.lock(); v = newValue; lock.unlock() } }
}

/// J-27: a redirect must not carry the token to another host.
final class RedirectTests: XCTestCase {
    override func setUp() { RedirectURLProtocol.reset(); RedirectURLProtocol.target = "http://elsewhere.example:32400/x" }

    func testOnlyTheSameHostMayBeFollowed() {
        func allowed(_ a: String, _ b: String) -> Bool { SameHostRedirects.allows(from: URL(string: a), to: URL(string: b)) }
        XCTAssertTrue(allowed("http://10.0.0.5:32400/a", "http://10.0.0.5:32400/b"))
        XCTAssertTrue(allowed("http://10.0.0.5:32400/a", "https://10.0.0.5:32400/a"), "an upgrade to https on the same host is safer")
        XCTAssertTrue(allowed("https://NAS.example/a", "https://nas.example/b"), "host names do not differ by case")
        XCTAssertFalse(allowed("http://10.0.0.5:32400/a", "http://10.0.0.6:32400/a"), "another host")
        XCTAssertFalse(allowed("http://10.0.0.5:32400/a", "http://10.0.0.5:9999/a"), "another port")
        XCTAssertFalse(allowed("https://10.0.0.5:32400/a", "http://10.0.0.5:32400/a"), "https must not drop to http")
        XCTAssertFalse(allowed("http://10.0.0.5/a", "http://10.0.0.5.evil.example/a"), "a host that only starts the same")
        XCTAssertFalse(SameHostRedirects.allows(from: URL(string: "http://10.0.0.5/a"), to: nil))
    }

    func testARedirectToAnotherHostGetsNoToken() async throws {
        let client = PlexClient(baseURL: URL(string: "http://10.0.0.5:32400")!, token: "SECRET", identity: testIdentity,
                                session: URLSession.makeUncached(protocolClasses: [RedirectURLProtocol.self]))
        _ = try? await client.send(client.request("/first"))
        XCTAssertEqual(RedirectURLProtocol.hosts, ["10.0.0.5"], "the other host never received a request")
        XCTAssertFalse(RedirectURLProtocol.seen.contains { $0.url?.host == "elsewhere.example" })
    }

    func testARedirectOnTheSameHostIsFollowed() async throws {
        RedirectURLProtocol.target = "http://10.0.0.5:32400/second"
        let client = PlexClient(baseURL: URL(string: "http://10.0.0.5:32400")!, token: "SECRET", identity: testIdentity,
                                session: URLSession.makeUncached(protocolClasses: [RedirectURLProtocol.self]))
        _ = try await client.send(client.request("/first"))
        XCTAssertEqual(RedirectURLProtocol.seen.count, 2, "the follow-up reached the same server")
    }

    func testAPictureFetchDoesNotFollowARedirectToAnotherHost() async throws {
        let images = ImageStore(cache: CountingCache(), protocolClasses: [RedirectURLProtocol.self])
        let r = try XCTUnwrap(makeClient().imageRequest("/first", width: 10, height: 10))
        _ = await images.image(for: r)
        XCTAssertFalse(RedirectURLProtocol.seen.contains { $0.url?.host == "elsewhere.example" })
    }

    func testTheSharedSessionIsTheOneThatStaysOnItsHost() {
        let delegate = URLSession.uncached.delegate
        XCTAssertTrue(delegate is SameHostRedirects, "the session every token call uses must carry the policy")
    }
}

/// J-28: the account token goes only to a server the account owns.
@MainActor
final class OwnedServerTests: XCTestCase {
    override func setUp() { StubURLProtocol.reset() }

    private func resource(_ name: String, id: String, owned: Bool, ip: String) -> String {
        #"{"name":"\#(name)","provides":"server","owned":\#(owned),"clientIdentifier":"\#(id)","connections":[{"uri":"http://\#(ip):32400","address":"\#(ip)","port":32400,"local":true,"relay":false}]}"#
    }

    private func signIn(resources: [String]) async throws -> AppModel {
        StubURLProtocol.handler = { r in
            if r.url?.host == "plex.tv" {
                if r.url!.path.hasSuffix("/pins") { return (201, Data(#"{"id":1,"code":"ABCD","authToken":null}"#.utf8)) }
                if r.url!.path.contains("/pins/") { return (200, Data(#"{"id":1,"code":"ABCD","authToken":"tok"}"#.utf8)) }
                return (200, Data("[\(resources.joined(separator: ","))]".utf8))
            }
            if r.url?.path == "/identity" {
                // Every address answers as the server that lives there.
                let id = r.url?.host == "10.0.0.7" ? "own" : "shared"
                return (200, Data(#"{"MediaContainer":{"machineIdentifier":"\#(id)"}}"#.utf8))
            }
            return (200, Fixture.data("sections"))
        }
        let m = AppModel(secrets: InMemorySecretStore(), session: StubURLProtocol.session(), images: ImageStore(cache: CountingCache()))
        m.linkPollInterval = .milliseconds(10)
        m.signInWithCode()
        for _ in 0..<300 {
            if m.phase == .ready { break }
            if case .failed = m.phase { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        return m
    }

    func testAnAccountWithOnlyASharedServerGetsAMessageAndNoTokenLeaves() async throws {
        let m = try await signIn(resources: [resource("Friend", id: "shared", owned: false, ip: "10.0.0.9")])
        guard case .failed(let message) = m.phase else { return XCTFail("expected a failure, got \(m.phase)") }
        XCTAssertTrue(message.contains("only shared"), message)
        let toServers = StubURLProtocol.seen.filter { $0.url?.host != "plex.tv" }
        XCTAssertTrue(toServers.allSatisfy { $0.value(forHTTPHeaderField: "X-Plex-Token") == nil }, "no request to a server carried the token")
        XCTAssertTrue(toServers.isEmpty, "the shared server was not even asked")
    }

    func testAnOwnedServerIsChosenEvenWhenASharedOneIsListedFirst() async throws {
        let m = try await signIn(resources: [resource("Friend", id: "shared", owned: false, ip: "10.0.0.9"),
                                             resource("Mine", id: "own", owned: true, ip: "10.0.0.7")])
        XCTAssertEqual(m.phase, .ready)
        let withToken = StubURLProtocol.seen.filter { $0.url?.host != "plex.tv" && $0.value(forHTTPHeaderField: "X-Plex-Token") != nil }
        XCTAssertFalse(withToken.isEmpty)
        XCTAssertTrue(withToken.allSatisfy { $0.url?.host == "10.0.0.7" }, "the token went only to the server the account owns")
    }

    func testAnAccountWithNoServerSaysSo() async throws {
        let m = try await signIn(resources: [])
        guard case .failed(let message) = m.phase else { return XCTFail("expected a failure, got \(m.phase)") }
        XCTAssertTrue(message.contains("No Plex server found"), message)
    }
}

/// J-29: one refused request does not delete the token. Only plex.tv's own refusal does.
@MainActor
final class RefusedRequestTests: XCTestCase {
    override func setUp() { StubURLProtocol.reset() }

    private let store = { InMemorySecretStore([AppModel.Key.token: "t", AppModel.Key.server: "http://10.0.0.5:32400",
                                               AppModel.Key.serverName: "NAS", AppModel.Key.serverID: "m1"]) }

    /// `server` is what the Plex server answers to a request, `plexTV` what plex.tv answers about the token.
    private func start(server: Knob, plexTV: Knob, store: InMemorySecretStore) async -> AppModel {
        StubURLProtocol.handler = answering { r in
            if r.url?.host == "plex.tv" { return (plexTV.value, Data("{}".utf8)) }
            return (server.value, Fixture.data("sections"))
        }
        let m = AppModel(secrets: store, session: StubURLProtocol.session(), images: ImageStore(cache: CountingCache()))
        await m.start()
        return m
    }

    private func waitUntil(_ what: String, _ done: () -> Bool) async throws {
        for _ in 0..<150 where !done() { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(done(), what)
    }

    func testARefusedScanKeepsTheTokenWhenPlexSaysItIsFine() async throws {
        let server = Knob(200), plexTV = Knob(200), store = store()
        let m = await start(server: server, plexTV: plexTV, store: store)
        XCTAssertEqual(m.phase, .ready)
        server.value = 401
        let section = try XCTUnwrap(m.movieLibraries.first)
        _ = try? await m.client?.scanLibrary(section)
        try await waitUntil("a message") { m.banner != nil }
        XCTAssertEqual(m.phase, .ready, "still signed in")
        XCTAssertEqual(store.get(AppModel.Key.token), "t", "the token was kept")
        XCTAssertTrue(m.banner?.contains("sign-in is fine") == true, m.banner ?? "no banner")
        XCTAssertNotNil(m.client)
    }

    func testARefusedRequestKeepsTheTokenWhenPlexCannotBeReached() async throws {
        let server = Knob(200), plexTV = Knob(503), store = store()
        let m = await start(server: server, plexTV: plexTV, store: store)
        server.value = 401
        _ = try? await m.client?.metadata("1")
        try await waitUntil("a message") { m.banner != nil }
        XCTAssertEqual(m.phase, .ready)
        XCTAssertEqual(store.get(AppModel.Key.token), "t")
        XCTAssertTrue(m.banner?.contains("could not be reached") == true, m.banner ?? "no banner")
    }

    func testTheTokenIsDeletedOnlyWhenPlexItselfRefusesIt() async throws {
        let server = Knob(200), plexTV = Knob(401), store = store()
        let m = await start(server: server, plexTV: plexTV, store: store)
        server.value = 401
        _ = try? await m.client?.metadata("1")
        try await waitUntil("signed out") { m.phase == .signedOut }
        XCTAssertNil(store.get(AppModel.Key.token))
        XCTAssertEqual(m.signInNotice, AppModel.signInRefusedNotice)
    }

    func testSeveralRefusedRequestsAskPlexOnce() async throws {
        let server = Knob(200), plexTV = Knob(200), store = store()
        let m = await start(server: server, plexTV: plexTV, store: store)
        StubURLProtocol.delayFor = { $0.url?.host == "plex.tv" ? 0.3 : 0 }       // the check is still running when the others fail
        server.value = 401
        let client = try XCTUnwrap(m.client)
        async let a = try? client.metadata("1")
        async let b = try? client.metadata("2")
        async let c = try? client.metadata("3")
        _ = await (a, b, c)
        try await waitUntil("a message") { m.banner != nil }
        XCTAssertEqual(StubURLProtocol.seen.filter { $0.url?.path == "/api/v2/user" }.count, 1)
    }

    func testARefusedTokenAtLaunchIsKeptWhenPlexSaysItIsFine() async throws {
        let server = Knob(401), plexTV = Knob(200), store = store()
        let m = await start(server: server, plexTV: plexTV, store: store)
        guard case .failed(let message) = m.phase else { return XCTFail("expected a failure, got \(m.phase)") }
        XCTAssertTrue(message.contains("Nothing was deleted"), message)
        XCTAssertEqual(store.get(AppModel.Key.token), "t")
    }

    func testTheTokenCheckIsSentWithTheTokenToPlexTV() async {
        StubURLProtocol.handler = { _ in (200, Data("{}".utf8)) }
        let status = await PlexAuth(identity: testIdentity, session: StubURLProtocol.session()).tokenStatus("abc")
        XCTAssertEqual(status, .valid)
        let sent = StubURLProtocol.seen.first
        XCTAssertEqual(sent?.url?.host, "plex.tv")
        XCTAssertEqual(sent?.value(forHTTPHeaderField: "X-Plex-Token"), "abc")
    }

    func testHomeAsksForNoLibraryThatIsNotThere() async throws {
        StubURLProtocol.handler = answering { r in
            r.url?.path == "/library/sections" ? (200, Data(#"{"MediaContainer":{"size":0,"Directory":[]}}"#.utf8)) : (200, Data(#"{"MediaContainer":{"size":0}}"#.utf8))
        }
        let m = AppModel(secrets: store(), session: StubURLProtocol.session(), images: ImageStore(cache: CountingCache()))
        await m.start()
        XCTAssertEqual(m.phase, .ready)
        let home = HomeModel()
        await home.load(app: m)
        XCTAssertNil(home.error)
        XCTAssertFalse(StubURLProtocol.seen.contains { $0.url?.path.hasPrefix("/library/sections/") == true }, "no made-up library was asked about")
    }
}

/// J-30: home videos are left out under either "none" agent.
final class HomeVideoAgentTests: XCTestCase {
    func testBothNoneAgentsAreLeftOut() throws {
        let all = try XCTUnwrap(Fixture.container("sections").Directory)
        XCTAssertTrue(all.contains { $0.agent == "tv.plex.agents.none" }, "the sample data has the newer agent")
        XCTAssertTrue(all.contains { $0.agent == "com.plexapp.agents.none" }, "and the older one")
        XCTAssertEqual(all.filter(\.isMovieLibrary).map(\.title), ["Movies"])
    }

    func testRealMovieAgentsStay() {
        for agent in ["tv.plex.agents.movie", "com.plexapp.agents.imdb", "com.plexapp.agents.themoviedb", nil] {
            XCTAssertTrue(PlexSection(key: "1", type: "movie", title: "M", agent: agent).isMovieLibrary, "\(agent ?? "no agent")")
        }
    }
}
