import Foundation

// MARK: - Envelope

struct PlexEnvelope<T: Decodable>: Decodable {
    let MediaContainer: T
}

/// The JSON "MediaContainer" Plex wraps around every answer. Only the keys HomeReel uses are listed.
struct PlexContainer: Decodable {
    var size: Int?
    var totalSize: Int?
    var offset: Int?
    var Metadata: [PlexItem]?
    var Directory: [PlexSection]?
    var Hub: [PlexHub]?
    var items: [PlexItem] { Metadata ?? [] }

    private enum CodingKeys: String, CodingKey { case size, totalSize, offset, Metadata, Directory, Hub }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        size = try c.decodeIfPresent(Int.self, forKey: .size)
        totalSize = try c.decodeIfPresent(Int.self, forKey: .totalSize)
        offset = try c.decodeIfPresent(Int.self, forKey: .offset)
        // One odd item should cost that item, not the whole page.
        Metadata = try c.decodeIfPresent([Lossy<PlexItem>].self, forKey: .Metadata)?.compactMap(\.value)
        Hub = try c.decodeIfPresent([Lossy<PlexHub>].self, forKey: .Hub)?.compactMap(\.value)
        // "Directory" means library sections on /library/sections, but a show's children list also uses
        // it for an "All episodes" entry that is not a section. Keep only what decodes as a section.
        Directory = try c.decodeIfPresent([Lossy<PlexSection>].self, forKey: .Directory)?.compactMap(\.value)
    }
}

/// Decodes to nil instead of failing when one element has a different shape.
struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

// MARK: - Library sections

struct PlexSection: Decodable, Identifiable, Hashable {
    var key: String
    var type: String
    var title: String
    var agent: String?
    /// True while the server is scanning this library for new files.
    var refreshing: Bool?
    var id: String { key }

    /// Movies and TV Shows only. Plex also files home videos, music videos and live feeds
    /// under type "movie", but those use the "none" agent, so they are left out.
    var isMovieLibrary: Bool { type == "movie" && agent != "com.plexapp.agents.none" }
    var isShowLibrary: Bool { type == "show" }
}

// MARK: - Items (movie, show, season, episode)

enum PlexItemType: String, Codable, Hashable {
    case movie, show, season, episode
    case other
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PlexItemType(rawValue: raw) ?? .other
    }
}

/// A person (actor, director, writer, producer) on an item.
struct PlexTag: Decodable, Hashable {
    var tag: String
    var role: String?
    var thumb: String?
    /// Plex's id for this person on your server, and the filter that finds their titles there ("actor=470").
    var personID: Int?
    var filter: String?
    /// The person's id in Plex's online database (used for biography and full filmography).
    var tagKey: String?

    fileprivate enum CodingKeys: String, CodingKey { case tag, role, thumb, filter, tagKey, key, personID = "id" }
}

extension PlexTag {
    /// Plex's online database gives a person's `id` as text (and has no `tagKey`), and your server gives a number.
    /// A field in the wrong shape costs only that field, never the person, and never the title that lists them.
    /// For an online person the text id is also the key of their online page, so it becomes `tagKey`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tag = try c.decode(String.self, forKey: .tag)
        role = try? c.decodeIfPresent(String.self, forKey: .role)
        thumb = try? c.decodeIfPresent(String.self, forKey: .thumb)
        filter = try? c.decodeIfPresent(String.self, forKey: .filter)
        personID = (try? c.decodeIfPresent(Int.self, forKey: .personID)) ?? nil
        let textID = (try? c.decodeIfPresent(String.self, forKey: .personID)) ?? nil
        let link = ((try? c.decodeIfPresent(String.self, forKey: .key)) ?? nil)
            .flatMap { $0.hasPrefix("/library/people/") ? $0.split(separator: "/").last.map(String.init) : nil }
        tagKey = ((try? c.decodeIfPresent(String.self, forKey: .tagKey)) ?? nil) ?? textID ?? link
    }

    /// The same person as listed by Plex's online database. Its `id` and `filter` belong to that database, not to
    /// your server, so they are dropped: a filter such as "actor=12" would ask your server about the wrong person.
    var online: PlexTag {
        var t = self
        t.personID = nil
        t.filter = nil
        return t
    }
}

/// One score from the `Rating` list: critic or audience, and which site it came from (in `image`).
struct PlexRating: Decodable, Hashable {
    var image: String?
    var value: Double?
    var type: String?
}

struct PlexItem: Decodable, Identifiable, Hashable {
    var ratingKey: String
    var type: PlexItemType
    var guid: String?
    var title: String
    var titleSort: String?
    var librarySectionID: Int?
    var summary: String?
    var tagline: String?
    var year: Int?
    var studio: String?
    var contentRating: String?
    var rating: Double?
    var audienceRating: Double?
    var duration: Int?              // milliseconds
    var viewOffset: Int?            // milliseconds
    var viewCount: Int?
    var lastViewedAt: Int?
    var addedAt: Int?
    var originallyAvailableAt: String?
    var index: Int?                 // episode number or season number
    var parentIndex: Int?           // season number of an episode
    var parentTitle: String?
    var parentRatingKey: String?
    var grandparentTitle: String?
    var grandparentRatingKey: String?
    var leafCount: Int?
    var viewedLeafCount: Int?
    var childCount: Int?
    var thumb: String?
    var art: String?
    var parentThumb: String?
    var grandparentThumb: String?
    var grandparentArt: String?
    var Media: [PlexMedia]?
    var Role: [PlexTag]?
    var Genre: [PlexTag]?
    var Director: [PlexTag]?
    var Writer: [PlexTag]?
    var Producer: [PlexTag]?
    var Rating: [PlexRating]?
    var audienceRatingImage: String?
    var ratingImage: String?

    var id: String { ratingKey }

    // Equality compares every field, so SwiftUI redraws a poster when its watched state changes.
    // (Comparing only ratingKey made SwiftUI think a changed item was unchanged.) Hashing by key stays valid.
    func hash(into h: inout Hasher) { h.combine(ratingKey) }

    // MARK: Derived

    var durationSeconds: Double? { duration.map { Double($0) / 1000 } }
    var offsetSeconds: Double { Double(viewOffset ?? 0) / 1000 }

    var isWatched: Bool {
        switch type {
        case .show, .season:
            if let leaf = leafCount, leaf > 0 { return (viewedLeafCount ?? 0) >= leaf }
            return false
        default:
            return (viewCount ?? 0) > 0 && viewOffset == nil
        }
    }

    /// 0...1 when partly watched, nil otherwise.
    var progress: Double? {
        guard let d = duration, d > 0, let o = viewOffset, o > 0 else { return nil }
        return min(1, Double(o) / Double(d))
    }

    var unwatchedCount: Int? {
        guard let leaf = leafCount else { return nil }
        return max(0, leaf - (viewedLeafCount ?? 0))
    }

    /// "S2 E5" for episodes.
    var episodeCode: String? {
        guard type == .episode, let s = parentIndex, let e = index else { return nil }
        return "S\(s) E\(e)"
    }

    /// Wide image for shelves: art for movies/shows, the episode still or show art for episodes.
    var landscapePath: String? {
        switch type {
        case .episode: return art ?? grandparentArt ?? thumb
        default: return art ?? thumb
        }
    }

    /// Tall poster. Episodes borrow the show poster.
    var posterPath: String? {
        switch type {
        case .episode: return grandparentThumb ?? parentThumb ?? thumb
        case .season: return thumb ?? parentThumb
        default: return thumb
        }
    }

    var primaryMedia: PlexMedia? { Media?.first }
    var primaryPart: PlexPart? { Media?.first?.Part?.first }
}

// MARK: - Files and streams

struct PlexMedia: Decodable, Hashable {
    var id: Int
    var container: String?
    var videoCodec: String?
    var audioCodec: String?
    var videoResolution: String?
    var audioChannels: Int?
    var bitrate: Int?
    var Part: [PlexPart]?
}

struct PlexPart: Decodable, Hashable {
    var id: Int
    var key: String
    var duration: Int?
    var size: Int?
    var container: String?
    var Stream: [PlexStream]?
}

struct PlexStream: Decodable, Hashable, Identifiable {
    var id: Int
    var streamType: Int             // 1 video, 2 audio, 3 subtitle
    var codec: String?
    var format: String?
    var key: String?                // present for external subtitle files
    var title: String?
    var displayTitle: String?
    var extendedDisplayTitle: String?
    var language: String?
    var languageTag: String?
    var languageCode: String?
    var selected: Bool?
    var `default`: Bool?
    var forced: Bool?
    var hearingImpaired: Bool?
    var channels: Int?
    var audioChannelLayout: String?
    var profile: String?
    var bitDepth: Int?
    var colorTrc: String?
    var DOVIPresent: Bool?
    var DOVIProfile: Int?
}

// MARK: - Hubs (Continue Watching, Recently Added, search results)

struct PlexHub: Decodable, Identifiable, Hashable {
    var hubIdentifier: String?
    var title: String
    var type: String?
    var Metadata: [PlexItem]?
    var id: String { (hubIdentifier ?? title) + (type ?? "") }
    var items: [PlexItem] { Metadata ?? [] }

    static func == (a: PlexHub, b: PlexHub) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    private enum CodingKeys: String, CodingKey { case hubIdentifier, title, type, Metadata }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hubIdentifier = try c.decodeIfPresent(String.self, forKey: .hubIdentifier)
        title = try c.decode(String.self, forKey: .title)
        type = try c.decodeIfPresent(String.self, forKey: .type)
        Metadata = try c.decodeIfPresent([Lossy<PlexItem>].self, forKey: .Metadata)?.compactMap(\.value)
    }
}
