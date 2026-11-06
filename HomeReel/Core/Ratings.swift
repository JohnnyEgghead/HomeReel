import SwiftUI

/// One score shown on a detail page, such as "RT Critics 91%".
struct RatingBadge: Identifiable, Equatable {
    enum Source: String { case rtCritics, rtAudience, tmdb, imdb }
    enum Mood { case good, bad, neutral }

    var source: Source
    var label: String
    var value: String
    var mood: Mood
    var id: String { source.rawValue }
}

enum Ratings {
    /// Turns Plex's ratings into the badges to show, in a fixed order: RT critics, RT audience, TMDB, IMDb.
    /// Plex scores run 0 to 10. RT is shown as a percentage, TMDB and IMDb as x.x.
    static func badges(for item: PlexItem) -> [RatingBadge] {
        var found: [RatingBadge.Source: RatingBadge] = [:]
        func add(image: String?, value: Double?, type: String?) {
            guard let image, let value else { return }
            if image.hasPrefix("rottentomatoes://") {
                let critic = (type == "critic") || image.hasSuffix(".ripe") || image.hasSuffix(".rotten")
                let good = image.hasSuffix(".ripe") || image.hasSuffix(".upright")
                let text = "\(Int((value * 10).rounded()))%"
                if critic {
                    found[.rtCritics] = RatingBadge(source: .rtCritics, label: "RT Critics", value: text, mood: good ? .good : .bad)
                } else {
                    found[.rtAudience] = RatingBadge(source: .rtAudience, label: "RT Audience", value: text, mood: good ? .good : .bad)
                }
            } else if image.hasPrefix("themoviedb://") {
                found[.tmdb] = RatingBadge(source: .tmdb, label: "TMDB", value: String(format: "%.1f", value), mood: .neutral)
            } else if image.hasPrefix("imdb://") {
                found[.imdb] = RatingBadge(source: .imdb, label: "IMDb", value: String(format: "%.1f", value), mood: .neutral)
            }
        }
        for r in item.Rating ?? [] { add(image: r.image, value: r.value, type: r.type) }
        if found.isEmpty {   // older servers: only the two summary scores
            add(image: item.ratingImage, value: item.rating, type: "critic")
            add(image: item.audienceRatingImage, value: item.audienceRating, type: "audience")
        }
        return [.rtCritics, .rtAudience, .tmdb, .imdb].compactMap { found[$0] }
    }
}

/// People behind the camera, with their job as the "role" line.
enum Crew {
    static func people(for item: PlexItem, limit: Int = 12) -> [PlexTag] {
        var seen = Set<String>()
        var out: [PlexTag] = []
        func add(_ tags: [PlexTag]?, job: String) {
            for var t in tags ?? [] {
                let key = (t.tagKey ?? t.tag) + "|" + job
                guard seen.insert(key).inserted else { continue }
                t.role = job
                out.append(t)
            }
        }
        add(item.Director, job: "Director")
        add(item.Writer, job: "Writer")
        add(item.Producer, job: "Producer")
        return Array(out.prefix(limit))
    }
}
