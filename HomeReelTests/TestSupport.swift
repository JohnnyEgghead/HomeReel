import Foundation
import XCTest
@testable import HomeReel

/// Answers every request from a closure. No network is touched.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var seen: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        StubURLProtocol.seen.append(request)
        let (code, data) = StubURLProtocol.handler?(request) ?? (404, Data())
        let resp = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static func session() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: cfg)
    }
    static func reset() { handler = nil; seen = [] }
}

enum Fixture {
    static func data(_ name: String) -> Data {
        guard let url = Bundle(for: AppModel.self).url(forResource: name, withExtension: "json"),
              let d = try? Data(contentsOf: url) else { fatalError("missing fixture \(name).json") }
        return d
    }
    static func container(_ name: String) throws -> PlexContainer {
        try JSONDecoder().decode(PlexEnvelope<PlexContainer>.self, from: data(name)).MediaContainer
    }
}

let testIdentity = PlexIdentity(clientID: "test-client-id")

func makeClient(session: URLSession = StubURLProtocol.session()) -> PlexClient {
    PlexClient(baseURL: URL(string: "http://10.0.0.5:32400")!, token: "SECRET", identity: testIdentity, session: session)
}
