import SwiftUI

/// What a person page shows. The profile and credits come from Plex's online database; the
/// titles you own come from your own server. Either side can fail without hiding the other.
@MainActor
final class PersonModel: ObservableObject {
    @Published private(set) var profile: PersonProfile?
    @Published private(set) var knownFor: [DiscoverTitle] = []
    @Published private(set) var groups: [CreditGroup] = []
    @Published private(set) var library: [PlexItem] = []
    @Published private(set) var onlineError: String?
    @Published private(set) var loaded = false

    /// Everything you own, by the id Plex uses on both sides ("plex://movie/<id>").
    private var owned: [String: PlexItem] = [:]

    /// Your own copy of a title.
    func local(for title: DiscoverTitle) -> PlexItem? { owned[title.ratingKey] }

    static func databaseID(of guid: String?) -> String? {
        guard let guid, let last = guid.split(separator: "/").last else { return nil }
        return String(last)
    }

    func load(tag: PlexTag, app: AppModel) async {
        async let own: Void = loadLibrary(tag: tag, app: app)
        async let online: Void = loadOnline(tag: tag, app: app)
        async let all = app.libraryCatalog()
        _ = await (own, online)
        matchCredits(against: await all)
        loaded = true
    }

    /// Plex keeps a separate record for a person in each role (the same name once as a writer and once as a director),
    /// so the role you opened them from finds only part of their work. Matching their online credits against
    /// everything you own finds the rest, whatever role it was.
    private func matchCredits(against catalog: [PlexItem]) {
        var byID: [String: PlexItem] = [:]
        for item in catalog { if let id = Self.databaseID(of: item.guid) { byID[id] = item } }
        for item in library { if let id = Self.databaseID(of: item.guid) { byID[id] = item } }
        owned = byID
        let creditIDs = Set(knownFor.map(\.ratingKey) + groups.flatMap { $0.Credit.map { $0.Metadata.ratingKey } })
        var shown = library
        var seen = Set(library.map(\.ratingKey))
        for id in creditIDs {
            if let item = byID[id], seen.insert(item.ratingKey).inserted { shown.append(item) }
        }
        library = shown.sorted { ($0.year ?? 0, $0.title) > ($1.year ?? 0, $1.title) }
    }

    private func loadLibrary(tag: PlexTag, app: AppModel) async {
        guard let c = app.client, let filter = tag.filter else { return }
        library = (try? await c.titles(withPerson: filter, in: app.movieLibraries + app.showLibraries)) ?? []
    }

    private func loadOnline(tag: PlexTag, app: AppModel) async {
        guard let key = tag.tagKey, let d = app.discover else {
            onlineError = "Plex has no online page for this person."
            return
        }
        do {
            async let p = d.profile(tagKey: key)
            async let k = d.knownFor(tagKey: key)
            async let g = d.credits(tagKey: key)
            profile = try await p
            knownFor = (try? await k) ?? []
            groups = (try? await g) ?? []
            onlineError = nil
        } catch {
            onlineError = error.localizedDescription
        }
    }
}

/// A person's page: who they are, what you own with them, and everything they have worked on.
struct PersonView: View {
    @EnvironmentObject var app: AppModel
    let tag: PlexTag
    @StateObject private var model = PersonModel()
    @State private var showBio = false
    @State private var notOwned: DiscoverTitle?

    var body: some View {
        ZStack {
            Color(white: 0.08).ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    header
                    if let e = model.onlineError {
                        HStack(spacing: 30) {
                            Text("Could not reach Plex's online database: \(e)").font(.callout).foregroundStyle(Theme.secondaryText)
                            Button("Try Again") { Task { await model.load(tag: tag, app: app) } }
                        }
                        .padding(.horizontal, 80)
                    }
                    Shelf(title: "In Your Library", items: model.library)
                    if !model.knownFor.isEmpty {
                        CreditShelf(title: "Known For", titles: model.knownFor.map { ($0, nil) }, model: model, notOwned: $notOwned)
                    }
                    ForEach(model.groups) { g in
                        CreditList(title: g.title, titles: g.Credit.map { ($0.Metadata, $0.role) }, model: model, notOwned: $notOwned)
                    }
                    if model.loaded, model.onlineError == nil, model.library.isEmpty, model.groups.isEmpty, model.knownFor.isEmpty {
                        Text("No titles found.").font(.title3).foregroundStyle(Theme.secondaryText).padding(.horizontal, 80)
                    }
                }
                .padding(.vertical, 60)
            }
            if !model.loaded { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .environment(\.colorScheme, .dark)
        .task(id: tag.tag) { await model.load(tag: tag, app: app) }
        .sheet(isPresented: $showBio) { BiographySheet(name: tag.tag, text: model.profile?.summary ?? "") }
        .sheet(item: $notOwned) { NotInLibrarySheet(title: $0) }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 50) {
            CastPhoto(name: tag.tag, request: PersonImages.request(model.profile?.thumb ?? tag.thumb, app: app, size: 500))
                .frame(width: 240, height: 240).clipShape(Circle())
            VStack(alignment: .leading, spacing: 14) {
                Text(tag.tag).font(.system(size: 56, weight: .bold))
                if let born = model.profile?.bornLine {
                    Text(born).font(.system(size: 28)).foregroundStyle(Theme.secondaryText)
                }
                if let bio = model.profile?.summary, !bio.isEmpty {
                    Button { showBio = true } label: {
                        Text(bio).font(.body).lineLimit(5).multilineTextAlignment(.leading)
                            .frame(maxWidth: 1200, alignment: .leading).padding(16)
                    }
                    .buttonStyle(.card)
                }
            }
        }
        .padding(.horizontal, 80)
    }
}

/// A shelf of posters from the online database. Titles you own open your copy; others say so.
struct CreditShelf: View {
    let title: String
    let titles: [(DiscoverTitle, String?)]
    @ObservedObject var model: PersonModel
    @Binding var notOwned: DiscoverTitle?
    @State private var expanded = false
    private let firstPage = 30

    private var shown: [(DiscoverTitle, String?)] { expanded ? titles : Array(titles.prefix(firstPage)) }

    var body: some View {
        if !titles.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(title) (\(titles.count))").font(.title3.bold()).padding(.horizontal, 80)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 36) {
                        ForEach(Array(shown.enumerated()), id: \.offset) { _, entry in
                            CreditCard(title: entry.0, role: entry.1, own: model.local(for: entry.0), notOwned: $notOwned)
                        }
                        if !expanded, titles.count > firstPage {
                            Button { expanded = true } label: {
                                Text("Show all \(titles.count)").font(.title3.bold())
                                    .frame(width: 200, height: 300)
                            }
                            .buttonStyle(.card)
                        }
                    }
                    .padding(.horizontal, 80).padding(.vertical, 24)
                }
            }
        }
    }
}

/// A person's work in one job (Actor, Writer...) as a list: poster, title, year, and role. The first 30, then "Show all".
struct CreditList: View {
    let title: String
    let titles: [(DiscoverTitle, String?)]
    @ObservedObject var model: PersonModel
    @Binding var notOwned: DiscoverTitle?
    @State private var expanded = false
    private let firstPage = 30

    private var shown: [(DiscoverTitle, String?)] { expanded ? titles : Array(titles.prefix(firstPage)) }

    var body: some View {
        if !titles.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("\(title) (\(titles.count))").font(.title3.bold()).padding(.horizontal, 80)
                LazyVStack(spacing: 12) {
                    ForEach(Array(shown.enumerated()), id: \.offset) { _, entry in
                        CreditRow(title: entry.0, role: entry.1, own: model.local(for: entry.0), notOwned: $notOwned)
                    }
                    if !expanded, titles.count > firstPage {
                        Button { expanded = true } label: {
                            Text("Show all \(titles.count)").font(.title3.bold()).frame(maxWidth: .infinity).padding(.vertical, 10)
                        }
                        .buttonStyle(.card)
                    }
                }
                .padding(.horizontal, 80)
            }
        }
    }
}

struct CreditRow: View {
    let title: DiscoverTitle
    let role: String?
    let own: PlexItem?
    @Binding var notOwned: DiscoverTitle?

    var body: some View {
        if let own {
            NavigationLink(value: own) { row }.buttonStyle(.card)
        } else {
            Button { notOwned = title } label: { row }.buttonStyle(.card)
        }
    }

    private var row: some View {
        HStack(spacing: 24) {
            RemoteImage(url: DiscoverImages.sized(title.thumb, width: 185))
                .frame(width: 80, height: 120).clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                Text(title.title).font(.system(size: 30, weight: .semibold)).lineLimit(1)
                Text([title.typeLabel, title.year.map(String.init), role.map { "as \($0)" }].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 24)).foregroundStyle(Theme.secondaryText).lineLimit(1)
            }
            Spacer(minLength: 0)
            if own != nil {
                Label("In your library", systemImage: "checkmark.seal.fill").font(.system(size: 24)).foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }
}

struct CreditCard: View {
    let title: DiscoverTitle
    let role: String?
    let own: PlexItem?
    @Binding var notOwned: DiscoverTitle?

    var body: some View {
        if let own {
            NavigationLink(value: own) { card }.buttonStyle(FocusScaleStyle()).focusEffectDisabled()
        } else {
            Button { notOwned = title } label: { card }.buttonStyle(FocusScaleStyle()).focusEffectDisabled()
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 8) {
            RemoteImage(url: DiscoverImages.sized(title.thumb))
                .frame(width: 200, height: 300)
                .overlay(alignment: .topLeading) {
                    if own != nil {
                        Image(systemName: "checkmark.seal.fill").font(.system(size: 26)).foregroundStyle(.white)
                            .padding(8).shadow(color: .black, radius: 3)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .focusRing()
            VStack(alignment: .leading, spacing: 2) {
                FocusText(text: title.title, size: 22)
                FocusText(text: [title.year.map(String.init), role].compactMap { $0 }.joined(separator: " · "), size: 19, secondary: true)
            }
            .frame(width: 200, alignment: .leading)
        }
    }
}

struct BiographySheet: View {
    let name: String
    let text: String
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(name).font(.largeTitle.bold())
                Text(text).font(.body).focusable()
            }
            .padding(80).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct NotInLibrarySheet: View {
    let title: DiscoverTitle

    var body: some View {
        HStack(alignment: .top, spacing: 50) {
            RemoteImage(url: DiscoverImages.sized(title.thumb, width: 500))
                .frame(width: 280, height: 420).clipShape(RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 16) {
                Text(title.title).font(.largeTitle.bold())
                Text([title.typeLabel, title.year.map(String.init)].compactMap { $0 }.joined(separator: " · "))
                    .font(.title3).foregroundStyle(Theme.secondaryText)
                Label("Not in your library", systemImage: "xmark.circle").font(.title3)
            }
        }
        .padding(80)
    }
}
