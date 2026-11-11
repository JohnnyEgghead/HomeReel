import Foundation

enum Fmt {
    /// "1h 52m", "47m"
    static func runtime(ms: Int?) -> String? {
        guard let ms, ms > 0 else { return nil }
        let m = ms / 60_000
        return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
    }

    static func videoLabel(_ s: PlexStream) -> String {
        if s.DOVIPresent == true { return "Dolby Vision" }
        if s.colorTrc == "smpte2084" { return "HDR10" }
        if s.colorTrc == "arib-std-b67" { return "HLG" }
        return "SDR"
    }

    static func audioLabel(codec: String?, channels: Int?) -> String {
        let name: String
        switch codec?.lowercased() {
        case "eac3": name = "Dolby Digital Plus"
        case "ac3": name = "Dolby Digital"
        case "truehd": name = "Dolby TrueHD"
        case "dca", "dts": name = "DTS"
        case "dca-ma": name = "DTS-HD MA"
        case "aac": name = "AAC"
        case "flac": name = "FLAC"
        case "mp3": name = "MP3"
        case let c?: name = c.uppercased()
        case nil: name = "Audio"
        }
        guard let ch = channels else { return name }
        let layout: String
        switch ch {
        case 1: layout = "1.0"
        case 2: layout = "2.0"
        case 6: layout = "5.1"
        case 8: layout = "7.1"
        default: layout = "\(ch)ch"
        }
        return "\(name) \(layout)"
    }

    /// One line about the file: "MKV · 4K · Dolby Vision · Dolby Digital Plus 5.1".
    static func fileSummary(_ item: PlexItem) -> String? {
        guard let media = item.primaryMedia else { return nil }
        let streams = media.Part?.first?.Stream ?? []
        var parts: [String] = []
        if let c = media.container { parts.append(c.uppercased()) }
        if let r = media.videoResolution { parts.append(r == "4k" ? "4K" : (r.allSatisfy(\.isNumber) ? "\(r)p" : r.uppercased())) }
        if let v = streams.first(where: { $0.streamType == 1 }) { parts.append(videoLabel(v)) }
        let audio = streams.first(where: { $0.streamType == 2 && $0.selected == true }) ?? streams.first(where: { $0.streamType == 2 })
        parts.append(audioLabel(codec: audio?.codec ?? media.audioCodec, channels: audio?.channels ?? media.audioChannels))
        return parts.joined(separator: " · ")
    }

    /// "Oct 11, 2006" from Plex's "2006-10-11" (or "2006-10-11T00:00:00.000Z"). Nil when the date is missing or not a date.
    /// The date is a calendar day, not a moment, so it is read and shown in UTC: in a time zone west of Greenwich
    /// a midnight UTC would otherwise be shown as the day before.
    static func airDate(_ raw: String?, locale: Locale = .current) -> String? {
        guard let raw else { return nil }
        let day = raw.prefix(10).split(separator: "-", omittingEmptySubsequences: false)
        guard day.count == 3, day[0].count == 4, day[1].count == 2, day[2].count == 2,
              let y = Int(day[0]), let m = Int(day[1]), let d = Int(day[2]), y > 0 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        let utc = TimeZone(identifier: "UTC") ?? .gmt
        calendar.timeZone = utc
        guard let date = calendar.date(from: DateComponents(year: y, month: m, day: d)),
              calendar.dateComponents([.year, .month, .day], from: date) == DateComponents(year: y, month: m, day: d) else { return nil }   // 2006-02-31 is not a day
        return date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale, calendar: calendar, timeZone: utc))
    }

    /// "2023 · R · 1h 52m". With `airDate`, an episode shows the day it first aired in place of the year: "Oct 11, 2006 · TV-14 · 47m".
    static func metaLine(_ item: PlexItem, airDate: Bool = false) -> String {
        var p: [String] = []
        if airDate, item.type == .episode, let day = Self.airDate(item.originallyAvailableAt) { p.append(day) }
        else if let y = item.year { p.append(String(y)) }
        if let c = item.contentRating { p.append(c) }
        if let r = runtime(ms: item.duration) { p.append(r) }
        return p.joined(separator: " · ")
    }
}
