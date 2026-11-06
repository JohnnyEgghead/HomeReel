import Foundation

struct PlexPin: Decodable, Sendable {
    var id: Int
    var code: String
    var authToken: String?
}

struct PlexResourceConnection: Decodable, Sendable {
    var uri: String
    var local: Bool
    var relay: Bool
    var `protocol`: String?
    var address: String?
    var port: Int?
}

struct PlexResource: Decodable, Sendable {
    var name: String
    var provides: String
    var owned: Bool?
    /// The server's own id, which its /identity page also reports.
    var clientIdentifier: String?
    var connections: [PlexResourceConnection]
    var isServer: Bool { provides.split(separator: ",").contains("server") }
}

/// Sign in with the plex.tv "link" flow: show a 4-letter code, the user types it at plex.tv/link on a phone.
struct PlexAuth: Sendable {
    let identity: PlexIdentity
    var session: URLSession = .shared
    var tvBase = URL(string: "https://plex.tv")!

    private func request(_ path: String, method: String = "GET", token: String? = nil, query: [URLQueryItem] = []) -> URLRequest {
        var c = URLComponents(url: tvBase.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        c.queryItems = query.isEmpty ? nil : query
        var r = URLRequest(url: c.url!, timeoutInterval: 20)
        r.httpMethod = method
        for (k, v) in identity.headers { r.setValue(v, forHTTPHeaderField: k) }
        if let token { r.setValue(token, forHTTPHeaderField: "X-Plex-Token") }
        return r
    }

    private func fetch<T: Decodable>(_ req: URLRequest, as: T.Type) async throws -> T {
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: req) }
        catch {
            if error.isCancellation { throw CancellationError() }
            throw error
        }
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw PlexError.badResponse((resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw PlexError.decoding("\(error)") }
    }

    func createPin() async throws -> PlexPin {
        try await fetch(request("api/v2/pins", method: "POST", query: [URLQueryItem(name: "strong", value: "false")]), as: PlexPin.self)
    }

    /// nil until the user has entered the code.
    func checkPin(_ id: Int) async throws -> String? {
        try await fetch(request("api/v2/pins/\(id)"), as: PlexPin.self).authToken
    }

    func servers(token: String) async throws -> [PlexResource] {
        let all = try await fetch(request("api/v2/resources", token: token, query: [
            URLQueryItem(name: "includeHttps", value: "1"),
            URLQueryItem(name: "includeRelay", value: "0"),
        ]), as: [PlexResource].self)
        return all.filter(\.isServer)
    }
}

/// Picks the address to use: local first, then any direct (non-relay) address.
enum PlexConnectionPicker {
    /// For a local server, plex.tv usually lists only a "*.plex.direct" https name. Some home routers
    /// refuse to resolve those names (DNS rebinding protection), which fails in a fraction of a second, so
    /// that name is tried first and the plain local IP comes right after it. The token is account-wide,
    /// so it should only cross the network in the clear when https is not available.
    static func candidates(for server: PlexResource) -> [URL] {
        let direct = server.connections.filter { !$0.relay }
        var out: [URL] = []
        for c in direct.filter(\.local) + direct.filter({ !$0.local }) {
            if let u = URL(string: c.uri) { out.append(u) }
            if c.local, let a = c.address, let p = c.port, let ip = URL(string: "http://\(a):\(p)") { out.append(ip) }
        }
        var seen = Set<URL>()
        return out.filter { seen.insert($0).inserted }
    }

    /// First address that answers /identity within a few seconds. With `machineID`, it must also be that server:
    /// a local address from plex.tv can belong to some other device on the network you are on, and the token
    /// goes to whatever address is picked here. The check itself sends no token.
    static func firstReachable(_ urls: [URL], machineID: String? = nil, session: URLSession = .shared) async -> URL? {
        for u in urls {
            var r = URLRequest(url: u.appendingPathComponent("identity"), timeoutInterval: 3)
            r.setValue("application/json", forHTTPHeaderField: "Accept")
            guard let (data, resp) = try? await session.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200 else { continue }
            if let machineID, reportedID(in: data) != machineID { continue }
            return u
        }
        return nil
    }

    private static func reportedID(in identity: Data) -> String? {
        struct Reply: Decodable { struct MC: Decodable { var machineIdentifier: String? }; var MediaContainer: MC }
        return (try? JSONDecoder().decode(Reply.self, from: identity))?.MediaContainer.machineIdentifier
    }
}
