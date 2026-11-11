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
    /// Your server could not be read, so this page cannot say what you own.
    @Published private(set) var libraryUnknown = false

    /// Everything you own, by the id Plex uses on both sides ("plex://movie/<id>").
    private var owned: [String: PlexItem] = [:]

    /// Your own copy of a title.
    func local(for title: DiscoverTitle) -> PlexItem? { owned[title.ratingKey] }

    /// The credit groups to show for the chosen role. No role, or a role this person has no work in, shows every group.
    static func visibleGroups(_ groups: [CreditGroup], role: String?) -> [CreditGroup] {
        guard let role, groups.contains(where: { $0.title == role }) else { return groups }
        return groups.filter { $0.title == role }
    }

    static func databaseID(of guid: String?) -> String? {
        guard let guid, let last = guid.split(separator: "/").last else { return nil }
        return String(last)
    }

    func load(tag: PlexTag, app: AppModel) async {
        async let own: Bool = loadLibrary(tag: tag, app: app)
        async let online: Void = loadOnline(tag: tag, app: app)
        async let all = app.libraryCatalog()
        let (ownRead, _) = await (own, online)
        let catalog = await all
        libraryUnknown = !ownRead || catalog == nil
        matchCredits(against: catalog ?? [])
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

    /// False when the server could not be read.
    private func loadLibrary(tag: PlexTag, app: AppModel) async -> Bool {
        guard let c = app.client, let filter = tag.filter else { return true }
        do {
            library = try await c.titles(withPerson: filter, in: app.movieLibraries + app.showLibraries)
            return true
        } catch {
            library = []
            return false
        }
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
            groups = try await g
            onlineError = nil
        } catch is CancellationError {
            return
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
    /// The role the filmography is narrowed to. nil shows every role.
    @State private var role: String?

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
                    if model.libraryUnknown {
                        HStack(spacing: 30) {
                            Text("Could not read your library, so this page may not show everything you own.").font(.callout).foregroundStyle(Theme.secondaryText)
                            Button("Try Again") { Task { await model.load(tag: tag, app: app) } }
                        }
                        .padding(.horizontal, 80)
                    }
                    Shelf(title: "In Your Library", items: model.library)
                    if !model.knownFor.isEmpty {
                        CreditShelf(title: "Known For", titles: model.knownFor.map { ($0, nil) }, model: model)
                    }
                    if model.groups.count > 1 {
                        RoleFilter(groups: model.groups, selection: $role)
                    }
                    ForEach(PersonModel.visibleGroups(model.groups, role: role)) { g in
                        CreditList(title: g.title, titles: g.Credit.map { ($0.Metadata, $0.role) }, model: model)
                    }
                    if model.loaded, model.onlineError == nil, !model.libraryUnknown, model.library.isEmpty, model.groups.isEmpty, model.knownFor.isEmpty {
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
                            CreditCard(title: entry.0, role: entry.1, own: model.local(for: entry.0), unknown: model.libraryUnknown)
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
    @State private var expanded = false
    private let firstPage = 30

    private var shown: [(DiscoverTitle, String?)] { expanded ? titles : Array(titles.prefix(firstPage)) }

    var body: some View {
        if !titles.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("\(title) (\(titles.count))").font(.title3.bold()).padding(.horizontal, 80)
                LazyVStack(spacing: 12) {
                    ForEach(Array(shown.enumerated()), id: \.offset) { _, entry in
                        CreditRow(title: entry.0, role: entry.1, own: model.local(for: entry.0), unknown: model.libraryUnknown)
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
    /// Your server could not be read, so a title that looks missing may not be.
    var unknown = false

    var body: some View {
        if let own {
            NavigationLink(value: own) { row }.buttonStyle(.card)
        } else {
            NavigationLink(value: NotInLibrary(title: title, unknown: unknown)) { row }.buttonStyle(.card)
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
    /// Your server could not be read, so a title that looks missing may not be.
    var unknown = false

    var body: some View {
        if let own {
            NavigationLink(value: own) { card }.buttonStyle(FocusScaleStyle()).focusEffectDisabled()
        } else {
            NavigationLink(value: NotInLibrary(title: title, unknown: unknown)) { card }.buttonStyle(FocusScaleStyle()).focusEffectDisabled()
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

/// The full biography. The remote scrolls a screen by moving focus, so the text is cut into paragraph-sized
/// pieces that can each take focus, and so is the name above them. One big focusable block cannot be scrolled back up:
/// focus lands on it, the screen scrolls down to it, and nothing above it can take focus.
struct BiographySheet: View {
    let name: String
    let text: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                FocusBlock(text: name, font: .largeTitle.bold())
                ForEach(Array(Self.chunks(of: text).enumerated()), id: \.offset) { _, piece in
                    FocusBlock(text: piece, font: .body)
                }
            }
            .padding(80).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Paragraphs, with a long one cut at sentence ends so no piece is much taller than a few lines.
    static func chunks(of text: String, limit: Int = 450) -> [String] {
        var out: [String] = []
        for line in text.components(separatedBy: .newlines) {
            let paragraph = line.trimmingCharacters(in: .whitespaces)
            if paragraph.isEmpty { continue }
            if paragraph.count <= limit { out.append(paragraph); continue }
            var current = ""
            paragraph.enumerateSubstrings(in: paragraph.startIndex..., options: .bySentences) { sentence, _, _, _ in
                guard let sentence else { return }
                if !current.isEmpty, current.count + sentence.count > limit {
                    out.append(current.trimmingCharacters(in: .whitespaces))
                    current = ""
                }
                current += sentence
            }
            let rest = current.trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty { out.append(rest) }
        }
        return out
    }
}

/// A piece of text that can take focus. It has no highlight: moving focus is only what scrolls the screen.
private struct FocusBlock: View {
    let text: String
    let font: Font

    var body: some View {
        Text(text).font(font)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .focusable()
    }
}

/// A row of buttons that narrows the filmography to one role (Actor, Director, Writer...). "All" shows every role.
struct RoleFilter: View {
    let groups: [CreditGroup]
    @Binding var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Filter by role").font(.callout).foregroundStyle(Theme.secondaryText).padding(.horizontal, 80)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 20) {
                    chip("All", count: groups.reduce(0) { $0 + $1.Credit.count }, chosen: selection == nil || !groups.contains { $0.title == selection }) { selection = nil }
                    ForEach(groups) { g in
                        chip(g.title, count: g.Credit.count, chosen: selection == g.title) { selection = g.title }
                    }
                }
                .padding(.horizontal, 80).padding(.vertical, 14)
            }
        }
        .focusSection()
    }

    private func chip(_ name: String, count: Int, chosen: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text("\(name) (\(count))").font(.system(size: 28, weight: .semibold)).padding(.horizontal, 28).padding(.vertical, 12)
        }
        .buttonStyle(RoleChipStyle(chosen: chosen))
        .accessibilityValue(chosen ? "selected" : "")
    }
}

/// The chosen role is filled white; the others are dim. Focus adds a ring, since a fill alone cannot show both.
struct RoleChipStyle: ButtonStyle {
    let chosen: Bool
    func makeBody(configuration: Configuration) -> some View {
        Chip(label: configuration.label, chosen: chosen)
    }
    private struct Chip<L: View>: View {
        @Environment(\.isFocused) private var focused
        let label: L
        let chosen: Bool
        var body: some View {
            label
                .foregroundStyle(chosen ? Color.black : Color.white)
                .background(Capsule().fill(chosen ? Color.white : Color.white.opacity(0.16)))
                .overlay { if focused { Capsule().stroke(.white, lineWidth: 6).padding(-6) } }
                .scaleEffect(focused ? 1.06 : 1)
                .animation(.easeOut(duration: 0.15), value: focused)
        }
    }
}
