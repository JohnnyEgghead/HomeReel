import Foundation

enum PlexError: Error, Equatable, LocalizedError {
    case unauthorized
    case unreachable(String)
    case badResponse(Int)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized: return "Plex did not accept the sign-in. Sign in again."
        case .unreachable(let w): return "Could not reach the server (\(w))."
        case .badResponse(let c): return "The server answered with error \(c)."
        case .decoding(let w): return "The server sent something unexpected (\(w))."
        }
    }
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
}

/// Talks to one Plex Media Server on the local network. Always asks for original files:
/// there is no transcode call anywhere in this type except the image resizer.
struct PlexClient: Sendable {
    let baseURL: URL
    let token: String
    let identity: PlexIdentity
    let session: URLSession

    init(baseURL: URL, token: String, identity: PlexIdentity, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.identity = identity
        self.session = session
    }

    // MARK: Request plumbing

    func url(_ path: String, _ query: [URLQueryItem] = []) -> URL {
        var c = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        c.path = path
        c.queryItems = query.isEmpty ? nil : query
        return c.url!
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
        catch { throw PlexError.unreachable((error as? URLError)?.localizedDescription ?? "\(error)") }
        guard let http = resp as? HTTPURLResponse else { throw PlexError.badResponse(0) }
        if http.statusCode == 401 { throw PlexError.unauthorized }
        guard (200..<300).contains(http.statusCode) else { throw PlexError.badResponse(http.statusCode) }
        return data
    }

    func container(_ path: String, _ query: [URLQueryItem] = []) async throws -> PlexContainer {
        let data = try await send(request(path, query))
        do { return try JSONDecoder().decode(PlexEnvelope<PlexContainer>.self, from: data).MediaContainer }
        catch { throw PlexError.decoding("\(error)") }
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
        return PlexPage(items: c.items, total: c.totalSize ?? c.items.count)
    }

    /// Every movie and show in the given libraries, in a few big requests. Used to tell which online credits you own.
    func allTitles(in sections: [PlexSection]) async throws -> [PlexItem] {
        var out: [PlexItem] = []
        let size = 1000
        for section in sections {
            var start = 0
            while true {
                let page = try await items(section: section, sort: .title, unwatchedOnly: false, start: start, size: size).items
                out += page
                if page.count < size { break }
                start += size
            }
        }
        return out
    }

    /// Everything in your Movie and TV libraries that a person is in or worked on.
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

    func continueWatching(limit: Int = 30) async throws -> [PlexItem] {
        let q = [URLQueryItem(name: "count", value: String(limit))]
        let hubs = try await container("/hubs/continueWatching", q).Hub ?? []
        return hubs.flatMap(\.items).filter { $0.type == .movie || $0.type == .episode }
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
        try await container("/library/metadata/\(ratingKey)/children").items
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

    /// Tells Plex where playback is. Plex stores the position (so Continue Watching works on every device)
    /// and shows the session as "now playing".
    func reportTimeline(_ item: PlexItem, state: TimelineState, time: Double, duration: Double) async {
        let q = [
            URLQueryItem(name: "ratingKey", value: item.ratingKey),
            URLQueryItem(name: "key", value: "/library/metadata/\(item.ratingKey)"),
            URLQueryItem(name: "identifier", value: "com.plexapp.plugins.library"),
            URLQueryItem(name: "state", value: state.rawValue),
            URLQueryItem(name: "time", value: String(Int(max(0, time) * 1000))),
            URLQueryItem(name: "duration", value: String(Int(max(0, duration) * 1000))),
            URLQueryItem(name: "playbackTime", value: String(Int(max(0, time) * 1000))),
        ]
        _ = try? await send(request("/:/timeline", q))
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

    /// The original file of a version, as one plain download. Not a transcode URL.
    func directPlayURL(part: PlexPart) -> URL {
        url(part.key, [URLQueryItem(name: "X-Plex-Token", value: token)])
    }
}
