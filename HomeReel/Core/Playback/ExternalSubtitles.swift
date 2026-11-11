import Foundation

/// A subtitle file that sits next to the video on the server (Plex lists it as a stream with a key).
struct ExternalSubtitleSpec: Equatable {
    var url: URL
    var name: String
    var language: String?
    var format: String
    var isForced: Bool
    var isHearingImpaired: Bool
}

enum ExternalSubtitles {
    /// Text formats the engine can read from a file. Image formats in side files (idx/sub) are left out.
    static let supported: Set<String> = ["srt", "subrip", "ass", "ssa", "vtt", "webvtt"]

    static func specs(for part: PlexPart, client: PlexClient) -> [ExternalSubtitleSpec] {
        (part.Stream ?? []).compactMap { s in
            guard s.streamType == 3, let key = s.key, !key.isEmpty else { return nil }
            let format = (s.format ?? s.codec ?? "").lowercased()
            guard supported.contains(format) else { return nil }
            return ExternalSubtitleSpec(
                url: client.url(key),                    // no token: the player sends it as a header
                name: s.displayTitle ?? s.title ?? "External subtitles",
                language: s.languageCode ?? s.languageTag ?? s.language,
                format: format == "subrip" ? "srt" : format,
                isForced: s.forced == true,
                isHearingImpaired: s.hearingImpaired == true
            )
        }
    }
}
