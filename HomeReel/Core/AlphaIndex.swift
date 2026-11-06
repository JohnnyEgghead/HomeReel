import Foundation

/// The letter a title files under in the A-Z strip. Plex sorts by its own "sort title" (it ignores a leading
/// "The" and similar), so that is used when present. Digits and symbols go under "#", which sorts first.
enum AlphaIndex {
    static let letters: [String] = ["#"] + (65...90).map { String(UnicodeScalar($0)!) }

    static func letter(for item: PlexItem) -> String {
        letter(forTitle: item.titleSort?.isEmpty == false ? item.titleSort! : item.title)
    }

    static func letter(forTitle title: String) -> String {
        guard let first = title.trimmingCharacters(in: .whitespaces).first else { return "#" }
        // Fold accents so "Émile" files under E.
        let folded = String(first).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .init(identifier: "en_US")).uppercased()
        if let c = folded.unicodeScalars.first, (65...90).contains(c.value), folded.count == 1 { return folded }
        return "#"
    }
}
