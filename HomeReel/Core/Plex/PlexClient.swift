import Foundation

enum PlexError: Error, Equatable, LocalizedError {
    case unauthorized
    case unreachable(String)
    case badResponse(Int)
    /// The text says what was being read, for the log. The viewer sees a plain sentence instead (see `errorDescription`).
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized: return "The server did not accept this request."
        case .unreachable(let w): return "Could not reach the server (\(w))."
        case .badResponse(let c): return "The server answered with error \(c)."
        case .decoding: return "The server sent an answer HomeReel could not read."
        }
    }
}

/// Keeps a request's headers (the Plex token, the TV key) on the host they were meant for. URLSession copies every
/// custom header to the new address when a server answers with a redirect, so a redirect to another host would carry
/// the token with it. This refuses any redirect that leaves the original host. The one exception is an upgrade from
/// http to https on the same host, which is safer, not riskier.
final class SameHostRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    /// Whether a request to `original` may follow a redirect to `redirected`.
    static func allows(from original: URL?, to redirected: URL?) -> Bool {
        guard let a = original, let b = redirected,
              let hostA = a.host()?.lowercased(), let hostB = b.host()?.lowercased(), hostA == hostB,
              let schemeA = a.scheme?.lowercased(), let schemeB = b.scheme?.lowercased() else { return false }
        if schemeA == schemeB { return a.port == b.port }
        return schemeA == "http" && schemeB == "https"
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Always compared with the first address, so a chain of redirects cannot walk away one step at a time.
        let ok = Self.allows(from: task.originalRequest?.url, to: request.url)
        if !ok { debugLog("redirect refused: \(task.originalRequest?.url?.host() ?? "?") -> \(request.url?.host() ?? "?")") }
        completionHandler(ok ? request : nil)       // nil: the redirect answer itself comes back, as an error status
    }
}

extension URLSession {
    /// A session with no cache that stays on its host. `protocolClasses` is for tests, which answer requests without a network.
    /// `ignoreLocalCache` sets the request policy too. `ImageStore` leaves it off: with it on, a session made there made
    /// `testClearingAlsoEmptiesTheAppsSharedCache` fail (seen twice, and gone when only that line was removed). The cache is
    /// nil either way.
    static func makeUncached(protocolClasses: [AnyClass]? = nil, ignoreLocalCache: Bool = true) -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.urlCache = nil
        if ignoreLocalCache { cfg.requestCachePolicy = .reloadIgnoringLocalCacheData }
        if let protocolClasses { cfg.protocolClasses = protocolClasses }
        return URLSession(configuration: cfg, delegate: SameHostRedirects(), delegateQueue: nil)
    }

    /// The session for every call that carries a token or key in a header. It keeps no cache: a URL cache saves
    /// each request on disk with its headers, and that would put the Plex token (or the TV key) in a file.
    /// It also refuses a redirect to another host, which would carry those headers along (see `SameHostRedirects`).
    static let uncached: URLSession = makeUncached()
}

extension Error {
    /// True for a cancelled task, however it surfaced. URLSession reports one as `URLError(.cancelled)`,
    /// not `CancellationError`, so a plain `catch is CancellationError` misses it.
    var isCancellation: Bool { self is CancellationError || (self as? URLError)?.code == .cancelled }
}

/// Who we are to Plex. The client ID is made once per install and kept.
struct PlexIdentity: Sendable {
    var clientID: String
    var product = "HomeReel"
    var version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
    var deviceName = "Apple TV"

    /// Headers Plex asks every app to send.
    var headers: [String: String] {
        [
            "X-Plex-Client-Identifier": clientID,
            "X-Plex-Product": product,
            "X-Plex-Version": version,
            "X-Plex-Platform": "tvOS",
            "X-Plex-Device": "Apple TV",
            "X-Plex-Device-Name": deviceName,
            "Accept": "application/json",
        ]
    }
}

enum PlexSort: String, CaseIterable, Identifiable {
    case title, added, aired, year, rating
    var id: String { rawValue }
    var label: String {
        switch self {
        case .title: return "Title"
        case .added: return "Date Added"
        case .aired: return "Recently Aired Episode"
        case .year: return "Year"
        case .rating: return "Rating"
        }
    }

    /// The choices in the Sort menu. "Recently Aired Episode" only makes sense for TV shows.
    static func options(forShows: Bool) -> [PlexSort] {
        forShows ? allCases : allCases.filter { $0 != .aired }
    }

    /// Value for Plex's `sort` query item. For TV shows, "Date Added" means the newest episode added,
    /// so a show that just got a new episode comes first.
    func query(forShows: Bool) -> String {
        switch self {
        case .title: return "titleSort"
        case .added: return forShows ? "episode.addedAt:desc" : "addedAt:desc"
        case .aired: return "episode.originallyAvailableAt:desc"
        case .year: return "year:desc"
        case .rating: return "audienceRating:desc"
        }
    }
}

struct PlexPage {
    var items: [PlexItem]
    var total: Int
    /// Items on this page that could not be read and were left out.
    var dropped = 0
}

/// Talks to one Plex Media Server. Always asks for original files:
/// there is no transcode call anywhere in this type except the image resizer.
struct PlexClient: Sendable {
    let baseURL: URL
    let token: String
    let identity: PlexIdentity
    let session: URLSession
    /// The server's own id (what its /identity page reports). Tells apart choices saved for different servers.
    let serverID: String?
    /// Called when the server answers 401: the token was revoked or expired. One place handles it for every screen.
    let onUnauthorized: (@Sendable () -> Void)?

    init(baseURL: URL, token: String, identity: PlexIdentity, session: URLSession = .uncached,
         serverID: String? = nil, onUnauthorized: (@Sendable () -> Void)? = nil) {
        self.baseURL = baseURL
        self.token = token
        self.identity = identity
        self.session = session
        self.serverID = serverID
        self.onUnauthorized = onUnauthorized
    }

    // MARK: Request plumbing

    func url(_ path: String, _ query: [URLQueryItem] = []) -> URL {
        guard var c = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return baseURL }
        c.path = path.hasPrefix("/") ? path : "/" + path      // paths come from the server, and a bad one must not crash
        c.queryItems = query.isEmpty ? nil : query
        return c.url ?? baseURL
    }

    func request(_ path: String, _ query: [URLQueryItem] = [], method: String = "GET") -> URLRequest {
        var r = URLRequest(url: url(path, query), timeoutInterval: 20)
        r.httpMethod = method
        for (k, v) in identity.headers { r.setValue(v, forHTTPHeaderField: k) }
        r.setValue(token, forHTTPHeaderField: "X-Plex-Token")
        return r
    }

    func send(_ req: URLRequest) async throws -> Data {
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: req) }
        catch {
            if error.isCancellation { throw CancellationError() }
            throw PlexError.unreachable((error as? URLError)?.localizedDescription ?? "\(error)")
        }
        guard let http = resp as? HTTPURLResponse else { throw PlexError.badResponse(0) }
        if http.statusCode == 401 { onUnauthorized?(); throw PlexError.unauthorized }
        guard (200..<300).contains(http.statusCode) else { throw PlexError.badResponse(http.statusCode) }
        return data
    }

    func container(_ path: String, _ query: [URLQueryItem] = []) async throws -> PlexContainer {
        let data = try await send(request(path, query))
        do { return try JSONDecoder().decode(PlexEnvelope<PlexContainer>.self, from: data).MediaContainer }
        catch {
            debugLog("decode FAILED \(path): \(error)")
            throw PlexError.decoding(path)
        }
    }

    // MARK: Library

    /// Movie and TV Show libraries only.
    func libraries() async throws -> (movies: [PlexSection], shows: [PlexSection]) {
        let all = try await container("/library/sections").Directory ?? []
        return (all.filter(\.isMovieLibrary), all.filter(\.isShowLibrary))
    }

    /// Asks the server to look for new and changed files in a library. It returns at once; the scan runs on the server.
    func scanLibrary(_ section: PlexSection) async throws {
        _ = try await send(request("/library/sections/\(section.key)/refresh"))
    }

    /// Whether the server is still scanning this library.
    func isScanning(_ section: PlexSection) async throws -> Bool {
        let all = try await container("/library/sections").Directory ?? []
        return all.first { $0.key == section.key }?.refreshing ?? false
    }

    func items(section: PlexSection, sort: PlexSort, unwatchedOnly: Bool, start: Int, size: Int, filter: String? = nil) async throws -> PlexPage {
        var q = [
            URLQueryItem(name: "type", value: section.isShowLibrary ? "2" : "1"),
            URLQueryItem(name: "sort", value: sort.query(forShows: section.isShowLibrary)),
            URLQueryItem(name: "X-Plex-Container-Start", value: String(start)),
            URLQueryItem(name: "X-Plex-Container-Size", value: String(size)),
        ]
        if unwatchedOnly { q.append(URLQueryItem(name: "unwatched", value: "1")) }
        // A person filter looks like "actor=470".
        if let filter, let eq = filter.firstIndex(of: "=") {
            q.append(URLQueryItem(name: String(filter[..<eq]), value: String(filter[filter.index(after: eq)...])))
        }
        let c = try await container("/library/sections/\(section.key)/all", q)
        // A page where nothing could be read is a failure, not an empty library.
        if c.items.isEmpty, c.droppedMetadata > 0 { throw PlexError.decoding("every item on a library page") }
        return PlexPage(items: c.items, total: c.totalSize ?? c.items.count, dropped: c.droppedMetadata)
    }

    /// Every movie and show in the given libraries, in a few big requests. Used to tell which online credits you own.
    func allTitles(in sections: [PlexSection]) async throws -> [PlexItem] {
        var out: [PlexItem] = []
        let size = 1000
        for section in sections {
            var start = 0
            while true {
                // Follow the server's own count: a page can come back shorter when an odd item is skipped.
                let page = try await items(section: section, sort: .title, unwatchedOnly: false, start: start, size: size)
                out += page.items
                start += size
                if start >= page.total { break }
            }
        }
        return out
    }

    /// Up to 100 titles from each of your Movie and TV libraries that a person is in or worked on (the first page the server sends; there is no paging).
    func titles(withPerson filter: String, in sections: [PlexSection]) async throws -> [PlexItem] {
        var out: [PlexItem] = []
        for section in sections {
            out += try await items(section: section, sort: .year, unwatchedOnly: false, start: 0, size: 100, filter: filter).items
        }
        return out
    }

    /// Newest first. Movies come back in the order they were added. TV shows come back as whole series
    /// (one poster per show, not one per episode), ordered by the most recently added episode.
    func recentlyAdded(section: PlexSection, limit: Int = 20) async throws -> [PlexItem] {
        if section.isShowLibrary {
            return try await items(section: section, sort: .added, unwatchedOnly: false, start: 0, size: limit).items
        }
        let q = [
            URLQueryItem(name: "X-Plex-Container-Start", value: "0"),
            URLQueryItem(name: "X-Plex-Container-Size", value: String(limit)),
            URLQueryItem(name: "type", value: "1"),
        ]
        return try await container("/library/sections/\(section.key)/recentlyAdded", q).items
    }

    /// Like search, this row covers every library on the server (home videos, music videos...), so results are
    /// limited to the given Movie and TV Show library keys. With no keys given, nothing is dropped.
    func continueWatching(limit: Int = 30, inSections keys: Set<String>? = nil) async throws -> [PlexItem] {
        let q = [URLQueryItem(name: "count", value: String(limit))]
        let hubs = try await container("/hubs/continueWatching", q).Hub ?? []
        return hubs.flatMap(\.items)
            .filter { $0.type == .movie || $0.type == .episode }
            .filter { item in
                guard let keys else { return true }
                return item.librarySectionID.map { keys.contains(String($0)) } ?? false
            }
    }

    /// Takes an item off the Continue Watching row (a movie, or a next-up episode). Plex keeps the watch history.
    func removeFromContinueWatching(ratingKey: String) async throws {
        _ = try await send(request("/actions/removeFromContinueWatching", [URLQueryItem(name: "ratingKey", value: ratingKey)], method: "PUT"))
    }

    func metadata(_ ratingKey: String) async throws -> PlexItem {
        let c = try await container("/library/metadata/\(ratingKey)", [URLQueryItem(name: "includeChapters", value: "1")])
        guard let item = c.items.first else { throw PlexError.decoding("empty metadata") }
        return item
    }

    /// Several items in one request (Plex accepts comma-separated keys). Used to get every episode's scores at once.
    func metadata(keys: [String]) async throws -> [PlexItem] {
        guard !keys.isEmpty else { return [] }
        return try await container("/library/metadata/\(keys.joined(separator: ","))").items
    }

    /// The episode that follows this one: the next in its season, or the first of the next season. Nil at the end of the show.
    func nextEpisode(after episode: PlexItem) async throws -> PlexItem? {
        guard episode.type == .episode, let seasonKey = episode.parentRatingKey else { return nil }
        let inSeason = try await children(seasonKey)
        if let i = inSeason.firstIndex(where: { $0.ratingKey == episode.ratingKey }), i + 1 < inSeason.count {
            return inSeason[i + 1]
        }
        guard let showKey = episode.grandparentRatingKey else { return nil }
        let seasons = try await children(showKey).filter { $0.type == .season }
        guard let s = seasons.firstIndex(where: { $0.ratingKey == seasonKey }) else { return nil }
        for next in seasons.dropFirst(s + 1) {
            if let first = try await children(next.ratingKey).first(where: { $0.type == .episode }) { return first }
        }
        return nil
    }

    func children(_ ratingKey: String) async throws -> [PlexItem] {
        let c = try await container("/library/metadata/\(ratingKey)/children")
        if c.items.isEmpty, c.droppedMetadata > 0 { throw PlexError.decoding("every entry in a children list") }
        return c.items
    }

    /// Search covers every library on the server (music videos, home videos...), so results are
    /// limited to the given Movie and TV Show library keys.
    func search(_ text: String, inSections keys: Set<String>? = nil, limit: Int = 30) async throws -> (movies: [PlexItem], shows: [PlexItem]) {
        let q = [URLQueryItem(name: "query", value: text), URLQueryItem(name: "limit", value: String(limit))]
        let hubs = try await container("/hubs/search", q).Hub ?? []
        func keep(_ i: PlexItem) -> Bool {
            guard let keys else { return true }
            return i.librarySectionID.map { keys.contains(String($0)) } ?? false
        }
        let movies = hubs.filter { $0.type == "movie" }.flatMap(\.items).filter(keep)
        let shows = hubs.filter { $0.type == "show" }.flatMap(\.items).filter(keep)
        return (movies, shows)
    }

    // MARK: Watched state

    func setWatched(_ watched: Bool, ratingKey: String) async throws {
        let path = watched ? "/:/scrobble" : "/:/unscrobble"
        let q = [URLQueryItem(name: "key", value: ratingKey), URLQueryItem(name: "identifier", value: "com.plexapp.plugins.library")]
        _ = try await send(request(path, q))
    }

    // MARK: Playback progress

    enum TimelineState: String { case playing, paused, stopped }

    private func timelineRequest(_ item: PlexItem, state: TimelineState, time: Double, duration: Double) -> URLRequest {
        request("/:/timeline", [
            URLQueryItem(name: "ratingKey", value: item.ratingKey),
            URLQueryItem(name: "key", value: "/library/metadata/\(item.ratingKey)"),
            URLQueryItem(name: "identifier", value: "com.plexapp.plugins.library"),
            URLQueryItem(name: "state", value: state.rawValue),
            URLQueryItem(name: "time", value: String(Int(max(0, time) * 1000))),
            URLQueryItem(name: "duration", value: String(Int(max(0, duration) * 1000))),
            URLQueryItem(name: "playbackTime", value: String(Int(max(0, time) * 1000))),
        ])
    }

    /// Tells Plex where playback is. Plex stores the position (so Continue Watching works on every device)
    /// and shows the session as "now playing". A miss is fine here: the next report follows in seconds.
    func reportTimeline(_ item: PlexItem, state: TimelineState, time: Double, duration: Double) async {
        _ = try? await send(timelineRequest(item, state: state, time: time, duration: duration))
    }

    /// The last report of a session. It ends the "now playing" session, and it is the only thing that saves the
    /// place if playback stopped early, so unlike the reports above it tells the caller when it fails.
    func reportStopped(_ item: PlexItem, time: Double, duration: Double) async throws {
        _ = try await send(timelineRequest(item, state: .stopped, time: time, duration: duration))
    }

    // MARK: Images

    /// A picture, resized by the server (images only; never video or audio). The address has no token in it,
    /// because image caches keep addresses on disk. Use `imageRequest` to fetch it.
    func imageURL(_ path: String?, width: Int, height: Int) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        return url("/photo/:/transcode", [
            URLQueryItem(name: "width", value: String(width)),
            URLQueryItem(name: "height", value: String(height)),
            URLQueryItem(name: "minSize", value: "1"),
            URLQueryItem(name: "upscale", value: "1"),
            URLQueryItem(name: "url", value: path),
        ])
    }

    /// The same picture, with the token as a header. Only this header is set: the JSON `Accept` header
    /// the rest of this client sends does not suit an image.
    func imageRequest(_ path: String?, width: Int, height: Int) -> URLRequest? {
        guard let url = imageURL(path, width: width, height: height) else { return nil }
        var r = URLRequest(url: url)
        r.setValue(token, forHTTPHeaderField: "X-Plex-Token")
        return r
    }

    /// The original file of a version, as one plain download. Not a transcode URL. The address has no token in it:
    /// the player sends the token as a header (`playbackHeaders`), so it is not in any address a log or a cache could keep.
    func directPlayURL(part: PlexPart) -> URL {
        url(part.key)
    }

    /// The headers the player sends with every request for the file and its sidecar subtitles.
    var playbackHeaders: [String: String] {
        ["X-Plex-Token": token]
    }
}
