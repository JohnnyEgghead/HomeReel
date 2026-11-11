import SwiftUI

/// A title from Plex's online database that is not on your server. Pushed as a page, so Menu goes back
/// and a cast member opens their own page.
struct NotInLibrary: Hashable {
    let title: DiscoverTitle
    /// Your server could not be read, so "not in your library" would be a guess.
    var unknown = false
}

/// The online details of one title. The page shows what the credit already carried while these load.
@MainActor
final class NotInLibraryModel: ObservableObject {
    @Published private(set) var details: PlexItem?
    @Published private(set) var error: String?
    @Published private(set) var loaded = false

    func load(_ title: DiscoverTitle, app: AppModel) async {
        guard let d = app.discover else {
            error = "Plex's online database is not available."
            loaded = true
            return
        }
        error = nil
        do {
            details = try await d.details(ratingKey: title.ratingKey)
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }
}

/// The full page for a title you do not own: poster, description, scores, cast, and crew.
struct NotInLibraryView: View {
    @EnvironmentObject var app: AppModel
    let page: NotInLibrary
    @StateObject private var model = NotInLibraryModel()

    private var title: DiscoverTitle { page.title }
    private var details: PlexItem? { model.details }

    var body: some View {
        ZStack {
            Backdrop(url: DiscoverImages.sized(details?.art, width: 1280))
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    HStack(alignment: .top, spacing: 60) {
                        RemoteImage(url: DiscoverImages.sized(details?.thumb ?? title.thumb, width: 500))
                            .frame(width: 300, height: 450).clipShape(RoundedRectangle(cornerRadius: 12))
                        VStack(alignment: .leading, spacing: 16) {
                            Text(details?.title ?? title.title).font(.largeTitle.bold())
                            Text(metaLine).font(.title3).foregroundStyle(Theme.secondaryText)
                            if let genres = genreLine {
                                Text(genres).font(.system(size: 26)).foregroundStyle(Theme.secondaryText)
                            }
                            if let details { RatingsRow(item: details) }
                            if let tag = details?.tagline, !tag.isEmpty { Text(tag).font(.headline).italic() }
                            if let s = details?.summary, !s.isEmpty { Text(s).font(.body) }
                            status
                            if let e = model.error {
                                Text("Could not load the details: \(e)").font(.callout).foregroundStyle(.orange)
                                Button("Try Again") { Task { await model.load(title, app: app) } }
                            } else if !model.loaded {
                                ProgressView()
                            }
                        }
                        .shadow(color: .black.opacity(0.7), radius: 8, y: 2)
                    }
                    .padding(.horizontal, 80).padding(.top, 60)
                    if let details {
                        PeopleRow(title: "Cast", people: (details.Role ?? []).map(\.online))
                        PeopleRow(title: "Crew", people: Crew.people(for: details).map(\.online), limit: 12)
                    }
                }
            }
        }
        .environment(\.colorScheme, .dark)
        .task(id: title.ratingKey) { await model.load(title, app: app) }
    }

    @ViewBuilder private var status: some View {
        if page.unknown {
            Label("Could not check your library", systemImage: "exclamationmark.triangle").font(.title3)
        } else {
            Label("Not in your library", systemImage: "xmark.circle").font(.title3)
        }
    }

    /// "Movie · 2023 · R · 1h 52m". Until the details arrive, only what the credit carried.
    private var metaLine: String {
        guard let details else { return Self.basicLine(title) }
        var parts = [title.typeLabel]
        let facts = Fmt.metaLine(details)
        parts.append(facts.isEmpty ? (title.year.map(String.init) ?? "") : facts)
        if details.type == .show, let n = details.childCount, n > 0 { parts.append("\(n) season\(n == 1 ? "" : "s")") }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    static func basicLine(_ t: DiscoverTitle) -> String {
        [t.typeLabel, t.year.map(String.init)].compactMap { $0 }.joined(separator: " · ")
    }

    private var genreLine: String? {
        let names = (details?.Genre ?? []).map(\.tag).filter { !$0.isEmpty }
        return names.isEmpty ? nil : names.prefix(4).joined(separator: " · ")
    }
}
