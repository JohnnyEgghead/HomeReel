import SwiftUI

@MainActor
final class HomeModel: ObservableObject {
    @Published var continueWatching: [PlexItem] = []
    @Published var recentMovies: [PlexItem] = []
    @Published var recentShows: [PlexItem] = []
    @Published var loaded = false
    @Published var error: String?
    /// A short message when a menu action fails.
    @Published var notice: String?

    /// Takes the item off the row at once, then tells Plex. If Plex refuses, the row comes back with a message.
    func remove(_ item: PlexItem, app: AppModel) async {
        guard let c = app.client else { return }
        continueWatching.removeAll { $0.ratingKey == item.ratingKey }
        do {
            try await c.removeFromContinueWatching(ratingKey: item.ratingKey)
            notice = nil
        } catch {
            notice = "Could not remove it: \(error.localizedDescription)"
            await load(app: app)
        }
    }

    /// Marks a movie or episode watched or unwatched. Unwatched also clears its place, so it leaves Continue Watching.
    func mark(_ item: PlexItem, watched: Bool, app: AppModel) async {
        guard let c = app.client else { return }
        do {
            try await c.setWatched(watched, ratingKey: item.ratingKey)
            if !watched { try? await c.removeFromContinueWatching(ratingKey: item.ratingKey) }
            notice = nil
            continueWatching.removeAll { $0.ratingKey == item.ratingKey }
            await app.loadDetailAndParents(item)
        } catch {
            notice = "Could not change the watched mark: \(error.localizedDescription)"
        }
        await load(app: app)
    }

    func load(app: AppModel) async {
        guard let c = app.client else { return }
        error = nil
        do {
            async let cont = c.continueWatching()
            async let movies = c.recentlyAdded(section: app.movieLibraries.first ?? PlexSection(key: "1", type: "movie", title: ""))
            async let shows = c.recentlyAdded(section: app.showLibraries.first ?? PlexSection(key: "2", type: "show", title: ""))
            continueWatching = try await cont
            recentMovies = app.movieLibraries.isEmpty ? [] : try await movies
            recentShows = app.showLibraries.isEmpty ? [] : try await shows
            loaded = true
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
            loaded = true
        }
    }
}

/// A movie or episode to play from the Home screen.
private struct HomePlay: Identifiable {
    let id = UUID()
    let item: PlexItem
    let startAt: Double?
}

struct HomeView: View {
    @EnvironmentObject var app: AppModel
    @StateObject private var model = HomeModel()
    @State private var playing: HomePlay?
    @Environment(\.openEpisodeList) private var openEpisodeList
    @Environment(\.openSeries) private var openSeries

    private func play(_ item: PlexItem, at start: Double?) {
        guard let c = app.client else { return }
        Task {
            // The row has a short copy of the item; playback wants the full details (streams, chapters).
            let full = (try? await c.metadata(item.ratingKey)) ?? item
            playing = HomePlay(item: full, startAt: start)
        }
    }

    /// The menu for a poster in Continue Watching: movies and episodes get different choices.
    private func continueActions(for item: PlexItem) -> [ShelfAction] {
        let resume = PlaybackPolicy.resumePosition(for: item)
        var playActions: [ShelfAction] = []
        if let r = resume {
            playActions = [
                ShelfAction(title: "Resume", systemImage: "play.fill") { play(item, at: r) },
                ShelfAction(title: "Start from Beginning", systemImage: "arrow.counterclockwise") { play(item, at: nil) },
            ]
        } else if item.type == .movie {
            playActions = [ShelfAction(title: "Play", systemImage: "play.fill") { play(item, at: nil) }]
        }
        if item.type == .episode {
            let playEpisode = resume == nil ? [ShelfAction(title: "Play Episode", systemImage: "play.fill") { play(item, at: nil) }] : playActions
            return [
                ShelfAction(title: "Open Series", systemImage: "tv") { openSeries(item) },
                ShelfAction(title: "Open Season", systemImage: "list.number") { openEpisodeList(item) },
                ShelfAction(title: "Remove from Continue Watching", systemImage: "xmark.circle", destructive: true) {
                    Task { await model.remove(item, app: app) }
                },
            ] + playEpisode
        }
        return playActions + [
            ShelfAction(title: "Mark Watched", systemImage: "checkmark.circle") { Task { await model.mark(item, watched: true, app: app) } },
            ShelfAction(title: "Mark Unwatched", systemImage: "eye.slash") { Task { await model.mark(item, watched: false, app: app) } },
        ]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let error = model.error {
                    MessageView(title: "Could not load Home", detail: error, retry: { Task { await model.load(app: app) } })
                } else if model.loaded && model.continueWatching.isEmpty && model.recentMovies.isEmpty && model.recentShows.isEmpty {
                    MessageView(title: "Nothing here yet", detail: "Add movies or shows to your Plex libraries.", systemImage: "film")
                } else {
                    if let notice = model.notice {
                        Text(notice).font(.callout).foregroundStyle(.orange).padding(.horizontal, 80)
                    }
                    Shelf(title: "Continue Watching", items: model.continueWatching, landscape: true, actions: continueActions(for:))
                    Shelf(title: "Recently Added Movies", items: model.recentMovies)
                    Shelf(title: "Recently Added TV Shows", items: model.recentShows)
                }
            }
        }
        .overlay { if !model.loaded { ProgressView() } }
        .fullScreenCover(item: $playing) { p in
            if let c = app.client {
                PlayerView(item: p.item, client: c, startAt: p.startAt) { exit in
                    playing = nil
                    if case .episodeList(let last) = exit { openEpisodeList(last) }
                }
            }
        }
        .task { await model.load(app: app) }
        .onAppear { if model.loaded { Task { await model.load(app: app) } } }   // coming back from a detail page
        .onChange(of: app.playbackSaves) { _, _ in Task { await model.load(app: app) } }  // the player saved in the background
    }
}
