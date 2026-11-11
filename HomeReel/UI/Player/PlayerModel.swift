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
    /// The point a swipe chose, shown as a preview until the viewer confirms it (Select) or cancels (Menu).
    /// Lifting the finger does not confirm it. nil when no preview is up.
    @Published private(set) var scrubTarget: Double?
    /// The video was playing when the preview opened, so cancelling or confirming starts it again.
    private var scrubResumes = false
    /// Where the video was when the preview opened. Cancelling goes back here.
    private var scrubOrigin: Double = 0
    /// The point the picture has been moved to for the preview, so Select can skip a seek it does not need.
    private var previewSeekedTo: Double?
    /// Moves the picture to the previewed point once the swipe has settled.
    private var previewTask: Task<Void, Never>?
    /// How long a swipe must rest before the picture follows it.
    static let previewSettle: Duration = .milliseconds(250)
    // One seek at a time. A newer request replaces one that has not started, so the last request always wins.
    private var pendingSeek: Double?
    private var seekRunning = false
    private var afterSeek: (() -> Void)?
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
    /// The look-up failed, so nobody knows whether there is a next episode.
    @Published private(set) var nextLookupFailed = false
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
    private var started = false
    /// The wait between tries at saving a watched mark. Zero in tests.
    var watchedRetryDelay: Duration = .seconds(2)

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
        #if DEBUG
        if simulatedLookupFailures > 0 {
            simulatedLookupFailures -= 1
            nextLookupFailed = true
            nextChecked = true
            return
        }
        #endif
        do {
            nextEpisode = try await client.nextEpisode(after: item)
            nextLookupFailed = false
        } catch {
            nextLookupFailed = true
        }
        nextChecked = true
    }

    #if DEBUG
    private var simulatedLookupFailures = 0

    /// For tests: pretend playback reached this point, without an engine.
    func setTimeForTesting(_ seconds: Double, duration total: Double) { time = seconds; duration = total }
    func setPhaseForTesting(_ p: Phase) { phase = p }

    /// Developer check (`-showend 1`): jump straight to the end-of-episode screen without playing anything.
    func showEndForTesting() async {
        // `-nextfail 1` fails the look-up and the automatic second try, so Try Again is the first to reach the server.
        if LaunchOptions.value("-nextfail") != nil { simulatedLookupFailures = 2 }
        phase = .ended
        await loadNextEpisode()
    }
    #endif

    func start(from startAt: Double?) async {
        guard !started else { return }
        started = true
        let part: PlexPart
        if let known = item.primaryPart {
            part = known
        } else {
            // Season lists carry no file details, so ask the server. A failure here is about the network, not the file.
            do {
                guard let fetched = try await client.metadata(item.ratingKey).primaryPart else {
                    phase = .failed("This item has no playable file.")
                    return
                }
                part = fetched
            } catch {
                phase = .failed(error.localizedDescription)
                return
            }
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
    /// Returns a message for the viewer if the watched mark could not be saved.
    @discardableResult
    func finish() async -> String? {
        guard !finished else { return nil }
        finished = true
        reportTask?.cancel()
        hideTask?.cancel()
        let t = time, d = duration > 0 ? duration : (item.durationSeconds ?? 0)
        engine?.stop()
        guard PlaybackPolicy.countsAsWatched(time: t, duration: d) || phase == .ended else {
            if t > 0 { await client.reportTimeline(item, state: .stopped, time: t, duration: d) }   // nothing played: nothing to save
            return nil
        }
        for attempt in 1...PlaybackPolicy.watchedAttempts {
            do {
                try await client.setWatched(true, ratingKey: item.ratingKey)
                return nil
            } catch {
                if attempt < PlaybackPolicy.watchedAttempts { try? await Task.sleep(for: watchedRetryDelay) }
            }
        }
        await client.reportTimeline(item, state: .stopped, time: t, duration: d)
        return "Could not mark \"\(item.title)\" as watched. Check the server, then mark it on its page."
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

    /// Nothing the remote does means anything until the picture is playing: the engine is not ready to seek or play.
    private var canControl: Bool { phase != .loading }

    func skip(_ seconds: Double) {
        guard canControl else { return }
        // With a preview up, an edge click moves the preview. Nothing is sought until the viewer confirms.
        if isScrubbing { scrubNudge(seconds); return }
        guard let engine else { return }
        let target = min(max(0, time + seconds), max(0, duration - 1))
        time = target
        requestSeek(target)
        showOverlay()
    }

    /// Seeks one at a time, whatever asks. `then` runs once the last requested seek is done.
    private func requestSeek(_ target: Double, then: (() -> Void)? = nil) {
        pendingSeek = target
        if let then { afterSeek = then }
        guard !seekRunning, let engine else { return }
        seekRunning = true
        Task { [weak self] in
            while let self, let next = self.pendingSeek {
                self.pendingSeek = nil
                await engine.seek(to: next)
            }
            guard let self else { return }
            self.seekRunning = false
            let done = self.afterSeek
            self.afterSeek = nil
            done?()
        }
    }

    // MARK: Swipe scrubbing: preview, then confirm

    var isScrubbing: Bool { scrubTarget != nil }

    /// A swipe starts (or carries on) a preview. The video pauses, and once the swipe rests the picture shows the
    /// point it chose. Nothing is final until the viewer confirms with `scrubCommit`; `scrubCancel` goes back.
    func scrubBegan() {
        guard canControl else { return }
        if let target = scrubTarget {
            scrubPosition = target       // a second swipe carries on from the preview
        } else {
            scrubResumes = phase == .playing
            if scrubResumes { engine?.pause() }
            scrubOrigin = time
            previewSeekedTo = nil
            scrubPosition = time
            scrubTarget = time
        }
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
        showPreviewSoon()
    }

    /// Moves the preview by a fixed step (an edge click while previewing).
    func scrubNudge(_ seconds: Double) {
        guard isScrubbing else { return }
        scrubPosition = min(max(0, scrubPosition + seconds), max(0, duration - 1))
        scrubTarget = scrubPosition.rounded()
        overlayVisible = true
        hideTask?.cancel()
        showPreviewSoon()
    }

    /// Once the swipe has rested, moves the (paused) picture to the previewed point.
    private func showPreviewSoon() {
        previewTask?.cancel()
        previewTask = Task { [weak self] in
            try? await Task.sleep(for: Self.previewSettle)
            guard !Task.isCancelled, let self, let target = self.scrubTarget, target != self.previewSeekedTo else { return }
            self.previewSeekedTo = target
            self.requestSeek(target)
        }
    }

    /// Select: go to the previewed point.
    func scrubCommit() {
        guard let target = scrubTarget, engine != nil else { return }
        previewTask?.cancel()
        scrubTarget = nil
        time = target
        let resume = scrubResumes
        scrubResumes = false
        let play: (() -> Void)? = resume ? { [weak self] in self?.engine?.play() } : nil
        if previewSeekedTo == target, !seekRunning, pendingSeek == nil {
            play?()                      // the picture is already there
        } else {
            requestSeek(target, then: play)
        }
        previewSeekedTo = nil
        scheduleHide()
    }

    /// Menu: drop the preview and put the picture back where it was.
    func scrubCancel() {
        guard isScrubbing else { return }
        previewTask?.cancel()
        scrubTarget = nil
        time = scrubOrigin
        let resume = scrubResumes
        scrubResumes = false
        let play: (() -> Void)? = resume ? { [weak self] in
            guard let self, self.phase == .paused else { return }
            self.engine?.play()
        } : nil
        if previewSeekedTo != nil || seekRunning || pendingSeek != nil {
            requestSeek(scrubOrigin, then: play)
        } else {
            play?()
        }
        previewSeekedTo = nil
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
        scrubCancel()
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

    /// Launch arguments for screenshots and checks: `-sub N`, `-panel info|subtitles|audio|picture`.
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
            .sink { [weak self] t in
                // While a preview moves the picture, the place that counts is still where you were.
                guard let self, !self.isScrubbing else { return }
                self.time = t
            }.store(in: &bag)
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
            if let e { self?.phase = .failed(e.message); debugLog("engine error \(e)") }
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
                // Only while something is on screen, so Plex never shows a session that is not really playing.
                if self.phase == .playing || self.phase == .paused {
                    await self.client.reportTimeline(self.item, state: self.phase == .paused ? .paused : .playing, time: self.time, duration: self.duration)
                }
                try? await Task.sleep(for: .seconds(PlaybackPolicy.reportInterval))
            }
        }
    }
}
