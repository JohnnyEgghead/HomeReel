import SwiftUI

/// Full-screen art behind a detail page.
struct Backdrop: View {
    @EnvironmentObject var app: AppModel
    let path: String?
    var body: some View {
        RemoteImage(request: app.client?.imageRequest(path, width: 1920, height: 1080))
            .overlay {
                // A flat dark layer keeps text readable on bright art; the gradient adds depth on the left.
                ZStack {
                    Color.black.opacity(0.5)
                    LinearGradient(colors: [.black.opacity(0.75), .black.opacity(0.25), .black.opacity(0.6)], startPoint: .leading, endPoint: .trailing)
                    LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
                }
            }
            .ignoresSafeArea()
    }
}

/// A row of people (cast or crew). Selecting one opens their page.
struct PeopleRow: View {
    @EnvironmentObject var app: AppModel
    let title: String
    let people: [PlexTag]
    var limit = 30

    var body: some View {
        if !people.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.title3.bold()).padding(.horizontal, 80)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 40) {
                        ForEach(Array(people.prefix(limit).enumerated()), id: \.offset) { _, p in
                            NavigationLink(value: p) {
                                VStack(spacing: 8) {
                                    CastPhoto(name: p.tag, request: PersonImages.request(p.thumb, app: app, size: 320))
                                        .frame(width: 160, height: 160).clipShape(Circle())
                                        .focusRing(circle: true)
                                    FocusText(text: p.tag, size: 21)
                                    if let r = p.role, !r.isEmpty { FocusText(text: r, size: 19, secondary: true) }
                                }
                                .frame(width: 180)
                            }
                            .buttonStyle(FocusScaleStyle())
                            .focusEffectDisabled()
                        }
                    }
                    .padding(.horizontal, 80).padding(.vertical, 20)
                }
            }
        }
    }
}

/// Photos of people are full web addresses from plex.tv, or paths on the server.
/// Only paths on the server get the token.
enum PersonImages {
    @MainActor static func request(_ thumb: String?, app: AppModel, size: Int) -> URLRequest? {
        guard let thumb, !thumb.isEmpty else { return nil }
        if thumb.hasPrefix("http") { return URL(string: thumb).map { URLRequest(url: $0) } }
        return app.client?.imageRequest(thumb, width: size, height: size)
    }
}

/// Critic and audience scores, side by side.
struct RatingsRow: View {
    let item: PlexItem
    /// Smaller type, for rows in a list.
    var compact = false
    var body: some View {
        let badges = Ratings.badges(for: item)
        if !badges.isEmpty {
            HStack(spacing: compact ? 10 : 14) {
                ForEach(badges) { b in
                    HStack(spacing: compact ? 6 : 8) {
                        Circle().fill(color(b)).frame(width: compact ? 11 : 14, height: compact ? 11 : 14)
                        Text(b.label).font(.system(size: compact ? 17 : 20)).foregroundStyle(Theme.secondaryText)
                        Text(b.value).font(.system(size: compact ? 19 : 22, weight: .bold))
                    }
                    .padding(.horizontal, compact ? 10 : 14).padding(.vertical, compact ? 4 : 6)
                    .background(Color.white.opacity(0.14), in: Capsule())
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func color(_ b: RatingBadge) -> Color {
        switch (b.source, b.mood) {
        case (_, .good): return Color(red: 0.98, green: 0.30, blue: 0.20)      // fresh / upright
        case (_, .bad): return Color(red: 0.45, green: 0.75, blue: 0.25)       // rotten / spilled
        case (.imdb, _): return Color(red: 0.96, green: 0.77, blue: 0.09)
        default: return Color(red: 0.20, green: 0.75, blue: 0.80)              // TMDB
        }
    }
}

/// Handles Menu only when there is something to do. (`onExitCommand(perform: nil)` still swallows the press.)
struct OptionalExit: ViewModifier {
    let action: (() -> Void)?
    func body(content: Content) -> some View {
        if let action { content.onExitCommand(perform: action) } else { content }
    }
}

/// An episode opened from its own season list. Menu then goes back one page, which is that list.
/// An episode opened any other way (Home, Search) sends Menu to the season list instead.
struct SeasonEpisode: Hashable {
    let item: PlexItem
}

/// Movie or episode page.
struct MediaDetailView: View {
    @EnvironmentObject var app: AppModel
    /// What the list handed us. The full details arrive through `app.details`.
    let initial: PlexItem
    @State private var error: String?
    @State private var playing: PlayRequest?
    @Environment(\.openEpisodeList) private var openEpisodeList
    /// True when this page was opened from the season's own episode list.
    private let fromSeasonList: Bool

    init(item: PlexItem, fromSeasonList: Bool = false) {
        initial = item
        self.fromSeasonList = fromSeasonList
    }

    /// Menu on an episode page goes to the season's episode list, however you got here.
    /// Nil leaves Menu alone (movies, and episodes opened from that list, which already go back to it).
    private var episodeMenu: (() -> Void)? {
        guard item.type == .episode, !fromSeasonList, item.parentRatingKey != nil, item.grandparentRatingKey != nil else { return nil }
        return { openEpisodeList(item) }
    }

    private var item: PlexItem { app.details[initial.ratingKey] ?? initial }

    /// Episode pages carry more heading lines than movies, so their type is smaller to leave room for the summary.
    private var isEpisode: Bool { item.type == .episode }

    var body: some View {
        ZStack {
            Backdrop(path: item.landscapePath)
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    HStack(alignment: .top, spacing: 60) {
                        RemoteImage(request: app.client?.imageRequest(item.posterPath, width: 600, height: 900))
                            .frame(width: 300, height: 450).clipShape(RoundedRectangle(cornerRadius: 12))
                        VStack(alignment: .leading, spacing: 16) {
                            if item.type == .episode {
                                Text(item.grandparentTitle ?? "").font(.system(size: 30)).foregroundStyle(Theme.secondaryText)
                            }
                            Text(item.title).font(isEpisode ? .system(size: 48, weight: .bold) : .largeTitle.bold())
                            if let code = item.episodeCode {
                                Text([code, item.parentTitle].compactMap { $0 }.joined(separator: " · ")).font(.system(size: 30))
                            }
                            Text(Fmt.metaLine(item)).font(isEpisode ? .system(size: 30) : .title3).foregroundStyle(Theme.secondaryText)
                            RatingsRow(item: item)
                            if let tag = item.tagline { Text(tag).font(.headline).italic() }
                            if let s = item.summary { Text(s).font(.body).lineLimit(8) }
                            if let f = Fmt.fileSummary(item) {
                                Label(f, systemImage: "film").font(.system(size: 20)).foregroundStyle(Theme.tertiaryText)
                            }
                            HStack(spacing: 30) {
                                if let resume = PlaybackPolicy.resumePosition(for: item) {
                                    Button { playing = PlayRequest(startAt: resume) } label: {
                                        Label("Resume from \(TransportOverlay.clock(resume))", systemImage: "play.fill")
                                    }
                                    Button { playing = PlayRequest(startAt: nil) } label: {
                                        Label("Start from Beginning", systemImage: "arrow.counterclockwise")
                                    }
                                } else {
                                    Button { playing = PlayRequest(startAt: nil) } label: {
                                        Label("Play", systemImage: "play.fill")
                                    }
                                }
                                Button { toggleWatched() } label: {
                                    Label(item.isWatched ? "Mark Unwatched" : "Mark Watched",
                                          systemImage: item.isWatched ? "eye.slash" : "checkmark.circle")
                                }
                            }
                            if let error { Text(error).foregroundStyle(.red).font(.callout) }
                        }
                        .shadow(color: .black.opacity(0.7), radius: 8, y: 2)
                    }
                    .padding(.horizontal, 80).padding(.top, 60)
                    PeopleRow(title: "Cast", people: item.Role ?? [])
                    PeopleRow(title: "Crew", people: Crew.people(for: item), limit: 12)
                }
            }
        }
        .environment(\.colorScheme, .dark)
        .modifier(OptionalExit(action: episodeMenu))
        .fullScreenCover(item: $playing) { req in
            if let c = app.client {
                PlayerView(item: item, client: c, startAt: req.startAt) { exit in
                    playing = nil
                    if case .episodeList(let last) = exit { openEpisodeList(last) }
                }
            }
        }
        .task(id: initial.ratingKey) {
            await app.loadDetail(initial.ratingKey)
            // Developer check: `-autoplay` starts playback as soon as the page opens.
            if LaunchOptions.value("-autoplay") != nil, playing == nil { playing = PlayRequest(startAt: nil) }
        }
    }

    private func toggleWatched() {
        guard let c = app.client else { return }
        let target = !item.isWatched
        Task {
            do {
                try await c.setWatched(target, ratingKey: item.ratingKey)
                error = nil
                await app.loadDetailAndParents(item)
            } catch { self.error = error.localizedDescription }
        }
    }
}

/// TV show page: seasons plus cast.
struct ShowDetailView: View {
    @EnvironmentObject var app: AppModel
    @State var item: PlexItem
    @State private var seasons: [PlexItem] = []
    @State fileprivate var error: String?

    var body: some View {
        ZStack {
            Backdrop(path: item.art ?? item.landscapePath)
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(item.title).font(.system(size: 50, weight: .bold))
                        Text([item.year.map(String.init), item.contentRating, item.childCount.map { "\($0) season\($0 == 1 ? "" : "s")" }]
                            .compactMap { $0 }.joined(separator: " · ")).font(.system(size: 30)).foregroundStyle(Theme.secondaryText)
                        RatingsRow(item: item)
                        if let s = item.summary { Text(s).font(.body).lineLimit(6) }
                        if let error {
                            Text(error).foregroundStyle(.red)
                            Button("Try Again") { Task { await load() } }
                        }
                    }
                    .shadow(color: .black.opacity(0.7), radius: 8, y: 2)
                    .padding(.horizontal, 80).padding(.top, 60)
                    Shelf(title: "Seasons", items: seasons)
                    PeopleRow(title: "Cast", people: item.Role ?? [])
                    PeopleRow(title: "Crew", people: Crew.people(for: item), limit: 12)
                }
            }
        }
        .task { await load() }
    }
}

extension ShowDetailView {
    func load() async {
        guard let c = app.client else { return }
        do {
            async let full = c.metadata(item.ratingKey)
            async let kids = c.children(item.ratingKey)
            item = try await full
            seasons = try await kids
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

/// One season: a list of episodes.
struct SeasonView: View {
    @EnvironmentObject var app: AppModel
    let season: PlexItem
    @State private var episodes: [PlexItem] = []
    /// Full details by key. The season list only carries one score per episode; these add the rest.
    @State private var scored: [String: PlexItem] = [:]
    @State private var loaded = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(season.parentTitle ?? "").font(.title3).foregroundStyle(Theme.secondaryText).padding(.horizontal, 80)
                Text(season.title).font(.largeTitle.bold()).padding(.horizontal, 80)
                if let error {
                    MessageView(title: "Could not load episodes", detail: error, retry: { Task { await loadEpisodes() } })
                } else if loaded && episodes.isEmpty {
                    MessageView(title: "No episodes", systemImage: "tv")
                } else {
                    ForEach(episodes) { ep in
                        NavigationLink(value: SeasonEpisode(item: ep)) { EpisodeRow(episode: ep, scored: scored[ep.ratingKey]) }
                            .buttonStyle(.card)
                            .padding(.horizontal, 80)
                    }
                }
            }
        }
        .overlay { if !loaded { ProgressView() } }
        .task { await loadEpisodes() }
    }

    private func loadEpisodes() async {
        guard let c = app.client else { return }
        do { episodes = try await c.children(season.ratingKey); error = nil } catch { self.error = error.localizedDescription }
        loaded = true
        // Scores for the whole season in one request. The list already shows what it has; this fills in the rest.
        if let full = try? await c.metadata(keys: episodes.map(\.ratingKey)) {
            scored = Dictionary(full.map { ($0.ratingKey, $0) }, uniquingKeysWith: { a, _ in a })
        }
    }
}

struct EpisodeRow: View {
    @EnvironmentObject var app: AppModel
    let episode: PlexItem
    var scored: PlexItem?
    var body: some View {
        let shownEpisode = app.current(episode)
        HStack(spacing: 30) {
            RemoteImage(request: app.client?.imageRequest(episode.thumb, width: 480, height: 270))
                .frame(width: 320, height: 180)
                .overlay { WatchBadge(item: shownEpisode) }
            VStack(alignment: .leading, spacing: 8) {
                Text("\(episode.index.map { "\($0). " } ?? "")\(episode.title)").font(.headline).lineLimit(1)
                if let s = episode.summary { Text(s).font(.callout).foregroundStyle(Theme.secondaryText).lineLimit(3) }
                HStack(spacing: 16) {
                    if let r = Fmt.runtime(ms: episode.duration) { Text(r).font(.caption).foregroundStyle(Theme.secondaryText) }
                    RatingsRow(item: scored ?? episode, compact: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .focusRing(cornerRadius: 24)
    }
}


/// A cast photo, or the person's initials when Plex has no photo (or it fails to load).
struct CastPhoto: View {
    let name: String
    let request: URLRequest?
    var body: some View {
        ZStack {
            Circle().fill(Color.white.opacity(0.18))
            Text(initials).font(.system(size: 44, weight: .semibold)).foregroundStyle(Theme.secondaryText)
            if request != nil { RemoteImage(request: request, showsPlaceholder: false) }
        }
    }
    private var initials: String {
        name.split(separator: " ").prefix(2).compactMap { $0.first }.map(String.init).joined().uppercased()
    }
}


/// One press of Play, Resume, or Start from Beginning.
struct PlayRequest: Identifiable {
    let id = UUID()
    let startAt: Double?
}
