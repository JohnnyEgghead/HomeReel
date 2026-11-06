import Foundation

// MARK: - Person details come from Plex's online database (discover.provider.plex.tv), not from the home server.

struct PersonProfile: Decodable, Equatable {
    var title: String
    var summary: String?
    var bornAt: String?
    var birthPlace: String?
    var thumb: String?
    var knownFor: String?
    var CreditType: [CreditCount]?
    var External: [ExternalLink]?

    struct CreditCount: Decodable, Equatable { var type: String?; var count: Int?; var title: String? }
    struct ExternalLink: Decodable, Equatable { var url: String? }

    /// "Born March 3, 1971 · Paper Falls, Ohio, USA"
    var bornLine: String? {
        var parts: [String] = []
        if let d = Self.parse(bornAt) {
            // Parsed as UTC, so it must be written as UTC too, or the day shifts by one west of Greenwich.
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "MMMM d, yyyy"
            parts.append("Born " + f.string(from: d))
        }
        if let p = birthPlace, !p.isEmpty { parts.append(p) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func parse(_ s: String?) -> Date? {
        guard let s, s.count >= 10 else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: String(s.prefix(10)))
    }
}

/// A movie or show in Plex's database, as listed in someone's credits.
struct DiscoverTitle: Decodable, Identifiable, Hashable {
    var ratingKey: String
    var title: String
    var type: String?
    var year: Int?
    var thumb: String?
    var id: String { ratingKey }

    var typeLabel: String {
        switch type { case "movie": return "Movie"; case "show": return "TV Show"; case "episode": return "Episode"; default: return "Title" }
    }
}

struct Credit: Decodable, Identifiable, Hashable {
    var order: Int?
    var role: String?
    var Metadata: DiscoverTitle
    var id: String { Metadata.id + "|" + (role ?? "") }
}

struct CreditGroup: Decodable, Identifiable, Hashable {
    var title: String
    var type: String?
    var Credit: [Credit]
    var id: String { title }

    private enum CodingKeys: String, CodingKey { case title, type, Credit }

    /// One odd credit should cost that credit, not the whole group.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        type = try c.decodeIfPresent(String.self, forKey: .type)
        Credit = try c.decode([Lossy<HomeReel.Credit>].self, forKey: .Credit).compactMap(\.value)
    }
}

struct PlexDiscover: Sendable {
    let token: String
    let identity: PlexIdentity
    var session: URLSession = .shared
    var base = URL(string: "https://discover.provider.plex.tv")!

    func request(_ path: String) -> URLRequest {
        var r = URLRequest(url: base.appendingPathComponent(path), timeoutInterval: 20)
        for (k, v) in identity.headers { r.setValue(v, forHTTPHeaderField: k) }
        r.setValue(token, forHTTPHeaderField: "X-Plex-Token")
        return r
    }

    private func fetch<T: Decodable>(_ path: String, as: T.Type) async throws -> T {
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: request(path)) }
        catch {
            if error.isCancellation { throw CancellationError() }
            throw PlexError.unreachable((error as? URLError)?.localizedDescription ?? "\(error)")
        }
        guard let http = resp as? HTTPURLResponse else { throw PlexError.badResponse(0) }
        guard (200..<300).contains(http.statusCode) else { throw PlexError.badResponse(http.statusCode) }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw PlexError.decoding("\(error)") }
    }

    private struct Meta<T: Decodable>: Decodable {
        struct MC: Decodable { var Metadata: [Lossy<T>]? }
        var MediaContainer: MC
        var items: [T] { MediaContainer.Metadata?.compactMap(\.value) ?? [] }
    }
    private struct Groups: Decodable {
        struct MC: Decodable { var CreditGroup: [Lossy<HomeReel.CreditGroup>]? }
        var MediaContainer: MC
    }

    func profile(tagKey: String) async throws -> PersonProfile {
        let r = try await fetch("library/people/\(tagKey)", as: Meta<PersonProfile>.self)
        guard let p = r.items.first else { throw PlexError.decoding("no such person") }
        return p
    }

    func knownFor(tagKey: String) async throws -> [DiscoverTitle] {
        try await fetch("library/people/\(tagKey)/person_known_for", as: Meta<DiscoverTitle>.self).items
    }

    /// Credit groups: Actor, Writer, Producer, Director, and so on.
    func credits(tagKey: String) async throws -> [CreditGroup] {
        try await fetch("library/people/\(tagKey)/credits", as: Groups.self).MediaContainer.CreditGroup?.compactMap(\.value) ?? []
    }
}

enum DiscoverImages {
    /// Online posters come as "original" size files (very large). TMDB serves smaller sizes from the same path.
    static func sized(_ urlString: String?, width: Int = 342) -> URL? {
        guard let urlString, !urlString.isEmpty else { return nil }
        let smaller = urlString.replacingOccurrences(of: "image.tmdb.org/t/p/original", with: "image.tmdb.org/t/p/w\(width)")
        return URL(string: smaller)
    }
}
