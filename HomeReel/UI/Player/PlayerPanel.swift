import SwiftUI

/// The swipe-down sheet: what is playing, and the subtitle and audio menus.
struct PlayerPanel: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var model: PlayerModel

    private var item: PlexItem { app.details[model.item.ratingKey] ?? model.item }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 24) {
                Picker("Panel", selection: $model.panelTab) {
                    ForEach(PanelTab.visible(tvEnabled: app.tvEnabled)) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 700)

                switch model.panelTab {
                case .info: InfoTab(item: item, model: model)
                case .subtitles: SubtitleTab(model: model)
                case .audio: AudioTab(model: model)
                case .picture: PictureTab()
                }
            }
            .padding(.horizontal, 80).padding(.top, 40).padding(.bottom, 50)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 620, alignment: .top)
            .background(.regularMaterial)
            .environment(\.colorScheme, .dark)
        }
        .ignoresSafeArea()
        .transition(.move(edge: .bottom))
    }
}

private enum InfoField: Hashable { case summary, cast(Int), crew(Int) }

/// A person chosen in the panel. The video pauses and their page opens over the player.
private struct PanelPerson: Identifiable {
    let tag: PlexTag
    var id: String { "\(tag.tag)-\(tag.tagKey ?? "")" }
}

private struct InfoTab: View {
    @EnvironmentObject var app: AppModel
    let item: PlexItem
    @ObservedObject var model: PlayerModel
    /// The description takes focus when the panel opens: one press up reaches the tabs, one press down the first person.
    @FocusState private var focus: InfoField?
    @State private var person: PanelPerson?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline, spacing: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        if item.type == .episode {
                            Text("\(item.grandparentTitle ?? "")").font(.system(size: 24)).foregroundStyle(Theme.secondaryText)
                        }
                        Text(item.title).font(.system(size: 42, weight: .bold))
                    }
                }
                let line = [item.episodeCode, Fmt.metaLine(item)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                if !line.isEmpty { Text(line).font(.system(size: 26)).foregroundStyle(Theme.secondaryText) }
                RatingsRow(item: item)
                if let s = item.summary {
                    // Focusable so the panel can scroll back up to it, but with no highlight: selecting it does nothing.
                    Text(s).font(.system(size: 26)).frame(maxWidth: .infinity, alignment: .leading)
                        .focusable()
                        .focusEffectDisabled()
                        .focused($focus, equals: .summary)
                }
                if let f = Fmt.fileSummary(item) {
                    Label(f, systemImage: "film").font(.system(size: 20)).foregroundStyle(Theme.tertiaryText)
                }
                PanelPeople(title: "Cast", people: item.Role ?? [], limit: 20, field: { .cast($0) }, focus: $focus, onSelect: choose).focusSection()
                PanelPeople(title: "Crew", people: Crew.people(for: item), limit: 12, field: { .crew($0) }, focus: $focus, onSelect: choose).focusSection()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            DispatchQueue.main.async {
                if item.summary != nil { focus = .summary }
                else if !(item.Role ?? []).isEmpty { focus = .cast(0) }
                else if !Crew.people(for: item).isEmpty { focus = .crew(0) }
            }
        }
        // Coming down from the description, the focus engine picks the person nearest the middle of the screen.
        // Start the row at the first person instead. Moves inside the row are untouched.
        .onChange(of: focus) { old, new in
            guard old == .summary else { return }
            if case .cast(let i)? = new, i != 0 { focus = .cast(0) }
            if case .crew(let i)? = new, i != 0, (item.Role ?? []).isEmpty { focus = .crew(0) }
        }
        .fullScreenCover(item: $person) { p in
            NavigationStack { PersonView(tag: p.tag).withDestinations() }
                .environment(\.colorScheme, .dark)
        }
    }

    private func choose(_ tag: PlexTag) {
        model.pauseIfPlaying()
        person = PanelPerson(tag: tag)
    }
}

/// A compact row of people for the panel. Selecting one opens their page.
private struct PanelPeople: View {
    @EnvironmentObject var app: AppModel
    let title: String
    let people: [PlexTag]
    let limit: Int
    let field: (Int) -> InfoField
    @FocusState.Binding var focus: InfoField?
    let onSelect: (PlexTag) -> Void

    var body: some View {
        if !people.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.system(size: 28, weight: .semibold))
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 30) {
                        ForEach(Array(people.prefix(limit).enumerated()), id: \.offset) { i, p in
                            Button { onSelect(p) } label: {
                                VStack(spacing: 6) {
                                    CastPhoto(name: p.tag, request: PersonImages.request(p.thumb, app: app, size: 220))
                                        .frame(width: 110, height: 110).clipShape(Circle())
                                        .focusRing(circle: true)
                                    FocusText(text: p.tag, size: 19)
                                    if let r = p.role, !r.isEmpty { FocusText(text: r, size: 17, secondary: true) }
                                }
                                .frame(width: 130)
                            }
                            .buttonStyle(FocusScaleStyle())
                            .focusEffectDisabled()
                            .focused($focus, equals: field(i))
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 16)
                }
            }
        }
    }
}

private struct SubtitleTab: View {
    @ObservedObject var model: PlayerModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                TrackRow(title: "Off", detail: "", selected: model.activeSubtitleID == nil) { model.selectSubtitle(nil) }
                ForEach(model.subtitleTracks) { t in
                    let l = TrackLabels.subtitle(t)
                    TrackRow(title: l.title, detail: l.detail, selected: model.activeSubtitleID == t.id) { model.selectSubtitle(t.id) }
                }
                if model.subtitleTracks.isEmpty {
                    Text("This video has no subtitle tracks.").font(.system(size: 24)).foregroundStyle(Theme.secondaryText)
                }
            }
        }
    }
}

private struct AudioTab: View {
    @ObservedObject var model: PlayerModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(model.audioTracks) { t in
                    let l = TrackLabels.audio(t)
                    TrackRow(title: l.title, detail: l.detail, selected: model.activeAudioID == t.id) { model.selectAudio(t.id) }
                }
                if model.audioTracks.isEmpty {
                    Text("No audio tracks found.").font(.system(size: 24)).foregroundStyle(Theme.secondaryText)
                }
            }
        }
    }
}

/// The TV's picture mode (Dolby Vision Bright, Dark...). The list comes from the TV itself.
@MainActor
private final class PictureModel: ObservableObject {
    enum State { case loading, ready(PictureModes), failed(String) }
    @Published var state: State = .loading
    @Published var changing: String?

    func load(_ tv: BraviaClient) async {
        state = .loading
        do { state = .ready(try await tv.pictureModes()) } catch { state = .failed(error.localizedDescription) }
    }

    func choose(_ value: String, tv: BraviaClient) async {
        changing = value
        defer { changing = nil }
        do { state = .ready(try await tv.setPictureMode(value)) }
        catch { state = .failed(error.localizedDescription) }
    }
}

private struct PictureTab: View {
    @EnvironmentObject var app: AppModel
    @StateObject private var model = PictureModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                switch model.state {
                case .loading:
                    HStack(spacing: 16) { ProgressView(); Text("Asking the TV...").font(.system(size: 24)).foregroundStyle(Theme.secondaryText) }
                case .failed(let message):
                    Text(message).font(.system(size: 24)).foregroundStyle(.orange)
                    Button("Try Again") { Task { await model.load(app.tv) } }
                case .ready(let modes):
                    Text("TV picture mode: \(modes.currentLabel)").font(.system(size: 24)).foregroundStyle(Theme.secondaryText)
                    ForEach(modes.choices) { c in
                        TrackRow(title: c.label, detail: model.changing == c.value ? "Changing..." : "", selected: modes.current == c.value) {
                            guard modes.isAvailable, model.changing == nil else { return }
                            Task { await model.choose(c.value, tv: app.tv) }
                        }
                        .opacity(modes.isAvailable ? 1 : 0.5)
                    }
                    if !modes.isAvailable {
                        Text("The TV is not offering a choice right now.").font(.system(size: 22)).foregroundStyle(Theme.secondaryText)
                    }
                    if app.tvKey.isEmpty {
                        Text("To change the mode, add the TV's key in Settings.").font(.system(size: 22)).foregroundStyle(Theme.secondaryText)
                    }
                }
            }
        }
        .task { await model.load(app.tv) }
    }
}

private struct TrackRow: View {
    let title: String
    let detail: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 20) {
                Image(systemName: "checkmark").opacity(selected ? 1 : 0).frame(width: 36)
                    .foregroundStyle(Color(red: 0.18, green: 0.84, blue: 0.33))
                Text(title).font(.system(size: 28, weight: selected ? .bold : .regular))
                if !detail.isEmpty { Text(detail).font(.system(size: 22)).foregroundStyle(Theme.secondaryText) }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4).padding(.horizontal, 12)
        }
    }
}
