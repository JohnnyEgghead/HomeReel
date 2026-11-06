import Foundation
import Combine
import AetherEngine

/// What the subtitle layer needs, kept apart from the player model so the picture does not redraw 10 times a second.
@MainActor
final class SubtitleFeed: ObservableObject {
    @Published var cues: [SubtitleCue] = []
    @Published var time: Double = 0
    @Published var videoSize: CGSize = .zero

    var active: [SubtitleCue] { SubtitleFeed.active(cues, at: time) }

    nonisolated static func active(_ cues: [SubtitleCue], at time: Double) -> [SubtitleCue] {
        Array(cues.filter { $0.startTime <= time && time < $0.endTime }.suffix(4))
    }
}

extension TrackDescriptor {
    init(_ t: TrackInfo) {
        self.init(id: t.id, name: t.name, codec: t.codec, language: t.language, channels: t.channels,
                  isDefault: t.isDefault, isForced: t.isForced, isHearingImpaired: t.isHearingImpaired,
                  isCommentary: t.isCommentary, isAtmos: t.isAtmos, isExternal: t.isExternal)
    }
}

enum PanelTab: String, CaseIterable, Identifiable {
    case info = "Info", subtitles = "Subtitles", audio = "Audio", picture = "Picture"
    var id: String { rawValue }

    /// The tabs to show. Picture is only there when TV control is turned on in Settings.
    static func visible(tvEnabled: Bool) -> [PanelTab] { tvEnabled ? allCases : allCases.filter { $0 != .picture } }
}

/// Runs one playback session: loads the file, tracks time, and keeps Plex up to date.
@MainActor
final class PlayerModel: ObservableObject {
    enum Phase: Equatable { case loading, playing, paused, ended, failed(String) }

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var time: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isBuffering = false
    @Published private(set) var routeText = ""
    @Published private(set) var formatText = ""
    @Published var overlayVisible = true
    /// Where the swipe is pointing while the viewer scrubs. nil when not scrubbing.
    @Published private(set) var scrubTarget: Double?
    private var scrubLastTranslation: Double = 0
    private var scrubPosition: Double = 0
    private var scrubBoostSmoothed: Double = 1

    // Subtitles, audio, and the info panel
    @Published private(set) var subtitleTracks: [TrackDescriptor] = []
    @Published private(set) var audioTracks: [TrackDescriptor] = []
    @Published private(set) var activeSubtitleID: Int?
    @Published private(set) var activeAudioID: Int?
    /// The episode that follows this one, found in the background so it is ready when playback ends.
    @Published private(set) var nextEpisode: PlexItem?
    @Published private(set) var nextChecked = false
    @Published var panelOpen = false
    @Published var panelTab: PanelTab = .info
    let feed = SubtitleFeed()

    let item: PlexItem
    private(set) var engine: AetherEngine?
    let client: PlexClient
    private let prefs: SubtitlePreferences
    private var bag = Set<AnyCancellable>()
    private var reportTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private var finished = false

    /// Subtitle choices are remembered per show (episodes) or per movie.
    private var prefKey: String { item.grandparentRatingKey ?? item.ratingKey }

    init(item: PlexItem, client: PlexClient, prefs: SubtitlePreferences = SubtitlePreferences()) {
        self.item = item
        self.client = client
        self.prefs = prefs
    }

    // MARK: Start and stop

    func loadNextEpisode() async {
        guard item.type == .episode else { nextChecked = true; return }
        nextEpisode = try? await client.nextEpisode(after: item)
        nextChecked = true
    }

    #if DEBUG
    /// Developer check (`-showend 1`): jump straight to the end-of-episode screen without playing anything.
    func showEndForTesting() async {
        phase = .ended
        await loadNextEpisode()
    }
    #endif

    func start(from startAt: Double?) async {
        guard let part = item.primaryPart else {
            phase = .failed("This item has no playable file.")
            return
        }
        do {
            let engine = try AetherEngine()
            self.engine = engine
            // Screenshot and test runs on the Mac pass `-mute 1` so a movie does not play through the Mac's speakers.
            if LaunchOptions.value("-mute") != nil { engine.volume = 0 }
            observe(engine)
            let url = client.directPlayURL(part: part)
            var options = LoadOptions()
            options.externalSubtitles = ExternalSubtitles.specs(for: part, client: client).map {
                ExternalSubtitleTrack(url: $0.url, name: $0.name, language: $0.language,
                                      isForced: $0.isForced, isHearingImpaired: $0.isHearingImpaired, formatHint: $0.format)
            }
            let begin = LaunchOptions.value("-startat").flatMap(Double.init) ?? startAt
            debugLog("play \(item.title) start=\(begin.map { String(Int($0)) } ?? "0") externalSubs=\(options.externalSubtitles.count)")
            try await engine.load(url: url, startPosition: begin, options: options)
            engine.play()
            duration = engine.duration > 0 ? engine.duration : (item.durationSeconds ?? 0)
            applyStartingSubtitles()
            applyDeveloperLaunchOptions()
            startReporting()
            scheduleHide()
            Task { await loadNextEpisode() }
        } catch {
            debugLog("play FAILED \(error)")
            phase = .failed(error.localizedDescription)
        }
    }

    /// Call when the player screen goes away. Saves the position and marks watched when due.
    func finish() async {
        guard !finished else { return }
        finished = true
        reportTask?.cancel()
        hideTask?.cancel()
        let t = time, d = duration > 0 ? duration : (item.durationSeconds ?? 0)
        engine?.stop()
        if PlaybackPolicy.countsAsWatched(time: t, duration: d) || phase == .ended {
            try? await client.setWatched(true, ratingKey: item.ratingKey)
        } else {
            await client.reportTimeline(item, state: .stopped, time: t, duration: d)
        }
    }

    // MARK: Remote actions

    /// Pauses for something that opens over the video, such as a person's page.
    func pauseIfPlaying() {
        if phase == .playing { engine?.pause() }
    }

    func togglePlayPause() {
        if isScrubbing { scrubCommit(); return }
        guard let engine else { return }
        if phase == .playing { engine.pause() } else { engine.play() }
        showOverlay()
    }

    func skip(_ seconds: Double) {
        guard let engine else { return }
        let target = min(max(0, time + seconds), max(0, duration - 1))
        time = target
        Task { await engine.seek(to: target) }
        showOverlay()
    }

    // MARK: Swipe scrubbing

    var isScrubbing: Bool { scrubTarget != nil }

    func scrubBegan() {
        scrubPosition = time
        scrubTarget = time
        scrubLastTranslation = 0
        scrubBoostSmoothed = 1
        overlayVisible = true
        hideTask?.cancel()
    }

    func scrubChanged(translation: Double, width: Double, speed: Double) {
        guard isScrubbing else { return }
        let dx = translation - scrubLastTranslation
        scrubLastTranslation = translation
        // Smooth the speed boost so one jittery reading cannot make the position jump.
        scrubBoostSmoothed = scrubBoostSmoothed * 0.85 + PlaybackPolicy.scrubBoost(speed: speed) * 0.15
        scrubPosition = PlaybackPolicy.scrubStep(position: scrubPosition, dx: dx, width: width, boost: scrubBoostSmoothed, duration: duration)
        scrubTarget = scrubPosition.rounded()
    }

    /// Finger lifted: jump to where the swipe pointed.
    func scrubCommit() {
        guard let target = scrubTarget, let engine else { return }
        scrubTarget = nil
        time = target
        Task { await engine.seek(to: target) }
        scheduleHide()
    }

    func scrubCancel() {
        scrubTarget = nil
        scheduleHide()
    }

    func showOverlay() {
        overlayVisible = true
        scheduleHide()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self else { return }
            if self.phase == .playing { self.overlayVisible = false }
        }
    }

    // MARK: Info panel, subtitles, audio

    func openPanel(_ tab: PanelTab = .info) {
        panelTab = tab
        panelOpen = true
        overlayVisible = false
    }

    func closePanel() { panelOpen = false }

    /// nil means subtitles off.
    func selectSubtitle(_ id: Int?) {
        guard let engine else { return }
        if let id {
            engine.selectSubtitleTrack(index: id)
            let lang = subtitleTracks.first { $0.id == id }?.language
            prefs.save(.init(off: false, language: lang), for: prefKey)
        } else {
            engine.clearSubtitle()
            prefs.save(.init(off: true, language: nil), for: prefKey)
        }
    }

    func selectAudio(_ id: Int) {
        engine?.selectAudioTrack(index: id)
    }

    /// Start with what the viewer last chose for this show, or the Settings default.
    private func applyStartingSubtitles() {
        guard let engine else { return }
        subtitleTracks = engine.subtitleTracks.map(TrackDescriptor.init)
        switch SubtitleChooser.decide(tracks: subtitleTracks, saved: prefs.record(for: prefKey), defaultLanguage: prefs.defaultLanguage) {
        case .off: engine.clearSubtitle()
        case .track(let id): engine.selectSubtitleTrack(index: id)
        case .leaveAsIs: break
        }
    }

    /// Launch arguments for screenshots and checks: `-sub N`, `-panel info|subtitles|audio`.
    private func applyDeveloperLaunchOptions() {
        guard let engine else { return }
        if let n = LaunchOptions.value("-sub").flatMap(Int.init), engine.subtitleTracks.indices.contains(n) {
            engine.selectSubtitleTrack(index: engine.subtitleTracks[n].id)
        }
        if let p = LaunchOptions.value("-panel"), let tab = PanelTab.allCases.first(where: { $0.rawValue.lowercased() == p }) {
            openPanel(tab)
        }
    }

    // MARK: Observing the engine

    private func observe(_ engine: AetherEngine) {
        engine.$state.receive(on: DispatchQueue.main).sink { [weak self] s in
            guard let self else { return }
            switch s {
            case .playing: self.phase = .playing
            case .paused: self.phase = .paused; self.overlayVisible = true
            case .ended: self.phase = .ended
            case .loading, .seeking, .idle: break
            @unknown default: break
            }
        }.store(in: &bag)
        engine.clock.$currentTime
            .throttle(for: .milliseconds(500), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] t in self?.time = t }.store(in: &bag)
        engine.clock.$sourceTime
            .throttle(for: .milliseconds(100), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] t in self?.feed.time = t }.store(in: &bag)
        engine.$subtitleCues.receive(on: DispatchQueue.main).sink { [weak self] c in self?.feed.cues = c }.store(in: &bag)
        engine.$duration.receive(on: DispatchQueue.main).sink { [weak self] d in
            if d > 0 { self?.duration = d }
        }.store(in: &bag)
        engine.$isBuffering.receive(on: DispatchQueue.main).sink { [weak self] b in self?.isBuffering = b }.store(in: &bag)
        engine.$videoRoute.receive(on: DispatchQueue.main).sink { [weak self] r in self?.routeText = "\(r)" }.store(in: &bag)
        engine.$videoFormat.receive(on: DispatchQueue.main).sink { [weak self] f in self?.formatText = "\(f)" }.store(in: &bag)
        engine.$errorInfo.receive(on: DispatchQueue.main).sink { [weak self] e in
            if let e { self?.phase = .failed("\(e)"); debugLog("engine error \(e)") }
        }.store(in: &bag)
        engine.$subtitleTracks.receive(on: DispatchQueue.main).sink { [weak self] t in
            self?.subtitleTracks = t.map(TrackDescriptor.init)
        }.store(in: &bag)
        engine.$audioTracks.receive(on: DispatchQueue.main).sink { [weak self] t in
            self?.audioTracks = t.map(TrackDescriptor.init)
        }.store(in: &bag)
        engine.$activeAudioTrackIndex.receive(on: DispatchQueue.main).sink { [weak self] i in self?.activeAudioID = i }.store(in: &bag)
        Publishers.CombineLatest(engine.$isSubtitleActive, engine.$activeSubtitleTrackIndex)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] active, idx in self?.activeSubtitleID = active ? idx : nil }.store(in: &bag)
        engine.$sourceVideoWidth.combineLatest(engine.$sourceVideoHeight)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] w, h in self?.feed.videoSize = CGSize(width: CGFloat(w), height: CGFloat(h)) }.store(in: &bag)
    }

    // MARK: Telling Plex

    private func startReporting() {
        reportTask?.cancel()
        reportTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let state: PlexClient.TimelineState = self.phase == .paused ? .paused : .playing
                await self.client.reportTimeline(self.item, state: state, time: self.time, duration: self.duration)
                try? await Task.sleep(for: .seconds(PlaybackPolicy.reportInterval))
            }
        }
    }
}
