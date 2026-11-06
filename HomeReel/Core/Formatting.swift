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

    /// "2023 · R · 1h 52m"
    static func metaLine(_ item: PlexItem) -> String {
        var p: [String] = []
        if let y = item.year { p.append(String(y)) }
        if let c = item.contentRating { p.append(c) }
        if let r = runtime(ms: item.duration) { p.append(r) }
        return p.joined(separator: " · ")
    }
}
