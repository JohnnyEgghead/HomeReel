import Foundation

/// What the menus need to know about an audio or subtitle track. Built from the engine's own track type,
/// so the labels and choices below can be tested without the engine.
struct TrackDescriptor: Identifiable, Equatable {
    var id: Int
    var name: String = ""
    var codec: String = ""
    var language: String?
    var channels: Int = 0
    var isDefault = false
    var isForced = false
    var isHearingImpaired = false
    var isCommentary = false
    var isAtmos = false
    var isExternal = false
}

enum TrackLabels {
    private static let english = Locale(identifier: "en_US")

    /// "eng" or "en" becomes "English". Unknown codes are shown as typed, in capitals.
    static func languageName(_ code: String?) -> String? {
        guard let code, !code.isEmpty, code.lowercased() != "und" else { return nil }
        if let n = english.localizedString(forLanguageCode: code), n.lowercased() != code.lowercased() { return n }
        if let two = alpha2(code), let n = english.localizedString(forLanguageCode: two) { return n }
        return code.uppercased()
    }

    /// Two-letter form of a language code: "eng" and "en-US" both give "en". nil if not recognized.
    static func alpha2(_ code: String?) -> String? {
        guard let code, !code.isEmpty else { return nil }
        let base = code.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? code
        // ISO 639-2/B codes (used by many MKV and Plex files) that Apple's list does not know.
        let bibliographic = ["fre": "fr", "ger": "de", "chi": "zh", "dut": "nl", "gre": "el", "cze": "cs", "per": "fa",
                             "rum": "ro", "slo": "sk", "wel": "cy", "baq": "eu", "alb": "sq", "arm": "hy", "geo": "ka",
                             "ice": "is", "mac": "mk", "mao": "mi", "may": "ms", "bur": "my", "tib": "bo"]
        if let a2 = bibliographic[base.lowercased()] { return a2 }
        let lc = Locale.LanguageCode(base.lowercased())
        if let a2 = lc.identifier(.alpha2) as String?, a2.count == 2 { return a2 }
        return base.count == 2 ? base.lowercased() : nil
    }

    static func sameLanguage(_ a: String?, _ b: String?) -> Bool {
        guard let x = alpha2(a), let y = alpha2(b) else { return false }
        return x == y
    }

    static func subtitleFormat(codec: String) -> String {
        switch codec.lowercased() {
        case "subrip", "srt": return "SRT"
        case "ass", "ssa": return "ASS"
        case "webvtt", "vtt": return "WebVTT"
        case "mov_text": return "Text"
        case "hdmv_pgs_subtitle", "pgs", "pgssub": return "PGS"
        case "dvd_subtitle", "dvdsub", "vobsub": return "VobSub"
        case "dvb_subtitle": return "DVB"
        case "eia_608", "cc_dec", "eia_708": return "Captions"
        case "": return ""
        default: return codec.uppercased()
        }
    }

    /// Row text for the subtitle menu: a main line and a smaller line under it.
    static func subtitle(_ t: TrackDescriptor) -> (title: String, detail: String) {
        let title = languageName(t.language) ?? (t.name.isEmpty ? "Subtitle \(t.id)" : t.name)
        var bits: [String] = []
        let f = subtitleFormat(codec: t.codec)
        if !f.isEmpty { bits.append(f) }
        if t.isForced { bits.append("Forced") }
        if t.isHearingImpaired { bits.append("SDH") }
        if t.isCommentary { bits.append("Commentary") }
        if t.isExternal { bits.append("File") }
        return (title, bits.joined(separator: " · "))
    }

    static func audio(_ t: TrackDescriptor) -> (title: String, detail: String) {
        let title = languageName(t.language) ?? (t.name.isEmpty ? "Audio \(t.id)" : t.name)
        var bits: [String] = []
        bits.append(Fmt.audioLabel(codec: t.codec, channels: t.channels > 0 ? t.channels : nil) + (t.isAtmos ? " Atmos" : ""))
        if t.isCommentary { bits.append("Commentary") }
        if t.isDefault { bits.append("Default") }
        return (title, bits.joined(separator: " · "))
    }
}

// MARK: - Remembering the viewer's choice

/// What the viewer last chose for a show: no subtitles, or a language.
/// A track with no language says nothing about what to pick next time, so nothing is saved for it.
enum SubtitleChoiceRecord: Equatable {
    case off
    case language(String)
}

extension SubtitleChoiceRecord {
    /// What to remember after the viewer picks this track. Nil for a track with no language: it cannot be found
    /// again by language, so remembering it would switch subtitles off at the next start.
    static func remembered(afterPicking track: TrackDescriptor) -> SubtitleChoiceRecord? {
        guard let code = track.language, TrackLabels.languageName(code) != nil else { return nil }
        return .language(code)
    }
}

extension SubtitleChoiceRecord: Codable {
    // Stored as it always was: {"off": Bool, "language": String?}, so a choice saved by an earlier version still reads.
    private enum Keys: String, CodingKey { case off, language }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        if try c.decode(Bool.self, forKey: .off) { self = .off; return }
        guard let lang = try c.decodeIfPresent(String.self, forKey: .language), !lang.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .language, in: c, debugDescription: "no language")
        }
        self = .language(lang)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .off: try c.encode(true, forKey: .off)
        case .language(let l): try c.encode(false, forKey: .off); try c.encode(l, forKey: .language)
        }
    }
}

/// Stored in UserDefaults, one record per show (movies: per movie).
struct SubtitlePreferences {
    var defaults: UserDefaults = .standard
    private let prefix = "subtitleChoice."
    static let defaultLanguageKey = "defaultSubtitleLanguage"   // "off" or a language code

    func record(for key: String) -> SubtitleChoiceRecord? {
        guard let data = defaults.data(forKey: prefix + key) else { return nil }
        return try? JSONDecoder().decode(SubtitleChoiceRecord.self, from: data)
    }

    /// A nil record forgets the choice, so the next start falls back to the Settings default.
    func save(_ record: SubtitleChoiceRecord?, for key: String) {
        guard let record, let data = try? JSONEncoder().encode(record) else { defaults.removeObject(forKey: prefix + key); return }
        defaults.set(data, forKey: prefix + key)
    }

    /// The Settings value: nil means "Off".
    var defaultLanguage: String? {
        let v = defaults.string(forKey: Self.defaultLanguageKey)
        return (v == nil || v == "off") ? nil : v
    }
}

enum SubtitleDecision: Equatable {
    case off
    case track(Int)
    case leaveAsIs
}

enum SubtitleChooser {
    /// Picks the track to start with. A saved choice for the show wins, then the Settings default.
    static func decide(tracks: [TrackDescriptor], saved: SubtitleChoiceRecord?, defaultLanguage: String?) -> SubtitleDecision {
        switch saved {
        case .off?: return .off
        case .language(let lang)?:
            if let t = best(in: tracks, language: lang) { return .track(t.id) }
            return .off
        case nil: break
        }
        if let lang = defaultLanguage {
            if let t = best(in: tracks, language: lang) { return .track(t.id) }
        }
        return .leaveAsIs
    }

    /// Full dialogue first, then hearing-impaired, then forced-only tracks. Commentary is never picked.
    static func best(in tracks: [TrackDescriptor], language: String) -> TrackDescriptor? {
        let match = tracks.filter { TrackLabels.sameLanguage($0.language, language) && !$0.isCommentary }
        return match.first { !$0.isForced && !$0.isHearingImpaired }
            ?? match.first { !$0.isForced }
            ?? match.first
    }
}
