import SwiftUI
import AetherEngine

/// How the player was left.
enum PlayerExit {
    case back
    /// Playback ended (or moved on to later episodes): show this episode's season.
    case episodeList(PlexItem)
}

/// Plays one item, and moves on to the next episode when the viewer asks for it.
struct PlayerView: View {
    let first: PlexItem
    let client: PlexClient
    let firstStart: Double?
    let onClose: (PlayerExit) -> Void
    @State private var item: PlexItem
    @State private var startAt: Double?

    init(item: PlexItem, client: PlexClient, startAt: Double?, onClose: @escaping (PlayerExit) -> Void) {
        first = item; self.client = client; firstStart = startAt; self.onClose = onClose
        _item = State(initialValue: item); _startAt = State(initialValue: startAt)
    }

    var body: some View {
        PlayerSession(item: item, client: client, startAt: startAt,
                      onNext: { next in startAt = nil; item = next },
                      onClose: { exit in
                          // Leaving a later episode with Menu goes to the episode list, not back to the first page.
                          if case .back = exit, item.ratingKey != first.ratingKey { onClose(.episodeList(item)) } else { onClose(exit) }
                      })
            .id(item.ratingKey)
    }
}

struct PlayerSession: View {
    @EnvironmentObject var app: AppModel
    @StateObject private var model: PlayerModel
    let startAt: Double?
    let onNext: (PlexItem) -> Void
    let onClose: (PlayerExit) -> Void
    /// Set once the viewer leaves, so more presses of Menu do nothing.
    @State private var closing = false
    /// Set while the next episode's details load.
    @State private var movingOn = false

    init(item: PlexItem, client: PlexClient, startAt: Double?, onNext: @escaping (PlexItem) -> Void, onClose: @escaping (PlayerExit) -> Void) {
        _model = StateObject(wrappedValue: PlayerModel(item: item, client: client))
        self.startAt = startAt
        self.onNext = onNext
        self.onClose = onClose
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let engine = model.engine { AetherPlayerSurface(engine: engine).ignoresSafeArea() }

            // One UIKit view takes focus and hears every remote press and swipe. (SwiftUI cannot tell a
            // swipe from an edge click, so a swipe would also have skipped 10 seconds.)
            RemoteSurface(
                enabled: !isFailed && !model.panelOpen && !showsEnd,
                onSkip: { model.skip($0) },
                onSelect: { model.togglePlayPause() },
                onPlayPause: { model.togglePlayPause() },
                onUp: { model.showOverlay() },
                onDown: { model.openPanel() },
                onMenu: {
                    if model.panelOpen { model.closePanel() }
                    else if model.isScrubbing { model.scrubCancel() }
                    else { close(.back) }
                },
                onScrubBegan: { model.scrubBegan() },
                onScrubChanged: { t, w, v in model.scrubChanged(translation: t, width: w, speed: v) },
                onScrubEnded: { model.scrubCommit() },
                onScrubCancelled: { model.scrubCancel() }
            )

            SubtitleOverlay(feed: model.feed, liftForControls: model.overlayVisible)

            if model.isBuffering || model.phase == .loading || movingOn { ProgressView().scaleEffect(2) }
            if case .failed(let msg) = model.phase { FailureOverlay(message: msg, onClose: { close(.back) }) }
            if model.overlayVisible, model.phase != .loading, !model.panelOpen, !showsEnd { TransportOverlay(model: model) }
            if model.panelOpen { PlayerPanel(model: model) }
            if showsEnd {
                EpisodeEndedOverlay(model: model, onNext: { playNext($0) }, onList: { close(.episodeList(model.item)) })
            }
        }
        .task {
            #if DEBUG
            if LaunchOptions.value("-showend") != nil { await model.showEndForTesting(); return }
            if let v = LaunchOptions.value("-showpanel") {
                model.openPanel(PanelTab.allCases.first { $0.rawValue.lowercased() == v } ?? .info)
                return
            }
            #endif
            await model.start(from: startAt)
        }
        .onChange(of: model.phase) { _, p in
            guard p == .ended else { return }
            model.closePanel()
            if model.item.type != .episode { close(.back) }     // a movie returns to its page; an episode offers what is next
            else if model.nextLookupFailed { Task { await model.loadNextEpisode() } }   // the first try was at the start
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private var isFailed: Bool { if case .failed = model.phase { return true } else { return false } }
    private var showsEnd: Bool { model.phase == .ended && model.item.type == .episode }

    /// Closes at once and saves afterward, so a slow or missing network never holds the screen open.
    private func close(_ exit: PlayerExit) {
        guard !closing else { return }
        closing = true
        onClose(exit)
        let model = self.model, app = self.app
        Task { await app.finishPlayback(model) }
    }

    /// Saves this episode as watched, loads the next one's full details (the season list has no file info), and plays it.
    private func playNext(_ next: PlexItem) {
        guard !closing, !movingOn else { return }
        movingOn = true
        let model = self.model, app = self.app
        Task { await app.finishPlayback(model) }
        Task {
            let full = try? await model.client.metadata(next.ratingKey)
            movingOn = false
            guard !closing else { return }
            if let full { onNext(full) } else { close(.episodeList(model.item)) }
        }
    }
}

/// Shown when an episode finishes: play the next one, or go back to the list. Menu also goes to the list.
struct EpisodeEndedOverlay: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var model: PlayerModel
    let onNext: (PlexItem) -> Void
    let onList: () -> Void
    private enum Choice { case next, list, retry }
    @FocusState private var focus: Choice?

    var body: some View {
        ZStack {
            Color.black.opacity(0.92).ignoresSafeArea()
            VStack(spacing: 36) {
                if let next = model.nextEpisode {
                    Text("Up Next").font(.system(size: 30, weight: .semibold)).foregroundStyle(Theme.secondaryText)
                    HStack(alignment: .top, spacing: 40) {
                        RemoteImage(request: app.client?.imageRequest(next.thumb, width: 640, height: 360))
                            .frame(width: 480, height: 270).clipShape(RoundedRectangle(cornerRadius: 12))
                        VStack(alignment: .leading, spacing: 12) {
                            Text([next.episodeCode, next.parentTitle].compactMap { $0 }.joined(separator: " · "))
                                .font(.system(size: 28)).foregroundStyle(Theme.secondaryText)
                            Text(next.title).font(.system(size: 44, weight: .bold)).lineLimit(2)
                            if let s = next.summary { Text(s).font(.system(size: 26)).foregroundStyle(Theme.secondaryText).lineLimit(4) }
                        }
                        .frame(width: 800, alignment: .leading)
                    }
                    HStack(spacing: 40) {
                        Button { onNext(next) } label: { Label("Play Next Episode", systemImage: "play.fill") }
                            .focused($focus, equals: .next)
                        Button { onList() } label: { Label("Episode List", systemImage: "list.bullet") }
                            .focused($focus, equals: .list)
                    }
                } else if model.nextLookupFailed {
                    Text("Could not find the next episode").font(.system(size: 40, weight: .bold))
                    HStack(spacing: 40) {
                        Button { Task { await model.loadNextEpisode() } } label: { Label("Try Again", systemImage: "arrow.clockwise") }
                            .focused($focus, equals: .retry)
                        Button { onList() } label: { Label("Episode List", systemImage: "list.bullet") }
                            .focused($focus, equals: .list)
                    }
                } else if model.nextChecked {
                    Text("That was the last episode").font(.system(size: 40, weight: .bold))
                    Button { onList() } label: { Label("Episode List", systemImage: "list.bullet") }
                        .focused($focus, equals: .list)
                } else {
                    ProgressView().scaleEffect(2)
                }
            }
            .padding(80)
        }
        .onAppear { focus = model.nextEpisode != nil ? .next : (model.nextLookupFailed ? .retry : .list) }
        .onChange(of: model.nextEpisode) { _, n in if n != nil { focus = .next } }
        .onChange(of: model.nextChecked) { _, _ in if model.nextEpisode == nil { focus = model.nextLookupFailed ? .retry : .list } }
        .onExitCommand { onList() }
    }
}

struct TransportOverlay: View {
    @ObservedObject var model: PlayerModel
    private var shown: Double { model.scrubTarget ?? model.time }

    var body: some View {
        VStack {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    if model.item.type == .episode {
                        Text(model.item.grandparentTitle ?? "").font(.system(size: 26)).foregroundStyle(Theme.secondaryText)
                    }
                    Text(model.item.title).font(.system(size: 40, weight: .bold))
                }
                Spacer()
                // Which engine path and picture format are active. Doubles as the diagnostics readout.
                Text("\(model.routeText) · \(model.formatText)").font(.system(size: 20)).foregroundStyle(Theme.tertiaryText)
            }
            Spacer()
            VStack(spacing: 10) {
                if let target = model.scrubTarget {
                    Text(Self.clock(target))
                        .font(.system(size: 56, weight: .bold)).monospacedDigit()
                }
                ProgressView(value: model.duration > 0 ? min(1, shown / model.duration) : 0)
                HStack {
                    Text(Self.clock(shown))
                    Spacer()
                    Text("-" + Self.clock(max(0, model.duration - shown)))
                }
                .font(.system(size: 24)).monospacedDigit().foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(.horizontal, 80).padding(.vertical, 60)
        .background(LinearGradient(colors: [.black.opacity(0.7), .clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
        .shadow(color: .black.opacity(0.6), radius: 6)
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    static func clock(_ seconds: Double) -> String {
        let s = Int(max(0, seconds))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}

struct FailureOverlay: View {
    let message: String
    let onClose: () -> Void
    var body: some View {
        VStack(spacing: 24) {
            MessageView(title: "Could not play this", detail: message)
            Button("Close", action: onClose)
        }
        .background(.black.opacity(0.85))
    }
}




/// The player's remote control. One focusable UIKit view that receives the Siri Remote's presses and swipes.
struct RemoteSurface: UIViewRepresentable {
    var enabled: Bool
    var onSkip: (Double) -> Void
    var onSelect: () -> Void
    var onPlayPause: () -> Void
    var onUp: () -> Void
    var onDown: () -> Void
    var onMenu: () -> Void
    var onScrubBegan: () -> Void
    var onScrubChanged: (_ translation: Double, _ width: Double, _ speed: Double) -> Void
    var onScrubEnded: () -> Void
    var onScrubCancelled: () -> Void

    func makeUIView(context: Context) -> RemoteView {
        let v = RemoteView()
        v.install()
        v.apply(self)
        return v
    }

    func updateUIView(_ v: RemoteView, context: Context) { v.apply(self) }

    final class RemoteView: UIView {
        var spec: RemoteSurface?

        private var menuAttached = false

        /// Menu is caught on the whole screen, not on this view, so it works while the info panel has focus.
        private func attachMenuRecognizer() {
            guard !menuAttached else { return }
            var responder: UIResponder? = self
            while let next = responder?.next {
                if let vc = next as? UIViewController {
                    let tap = UITapGestureRecognizer(target: self, action: #selector(menuPressed))
                    tap.allowedPressTypes = [NSNumber(value: UIPress.PressType.menu.rawValue)]
                    vc.view.addGestureRecognizer(tap)
                    menuAttached = true
                    return
                }
                responder = next
            }
        }

        @objc private func menuPressed() { spec?.onMenu() }

        func install() {
            let pan = UIPanGestureRecognizer(target: self, action: #selector(pan(_:)))
            pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
            addGestureRecognizer(pan)
        }

        func apply(_ spec: RemoteSurface) {
            let wasEnabled = self.spec?.enabled
            self.spec = spec
            if wasEnabled != spec.enabled {
                setNeedsFocusUpdate()
                if spec.enabled { UIFocusSystem.focusSystem(for: self)?.requestFocusUpdate(to: self) }
            }
        }

        override var canBecomeFocused: Bool { spec?.enabled ?? true }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.attachMenuRecognizer()
                UIFocusSystem.focusSystem(for: self)?.requestFocusUpdate(to: self)
            }
        }

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            guard let spec else { return super.pressesBegan(presses, with: event) }
            var unhandled = Set<UIPress>()
            for press in presses {
                switch press.type {
                case .leftArrow: spec.onSkip(-PlaybackPolicy.skipSeconds)
                case .rightArrow: spec.onSkip(PlaybackPolicy.skipSeconds)
                case .upArrow: spec.onUp()
                case .downArrow: spec.onDown()
                case .select: spec.onSelect()
                case .playPause: spec.onPlayPause()
                default: unhandled.insert(press)
                }
            }
            if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
        }

        // Presses are consumed on "began"; swallow the matching "ended" so nothing else reacts.
        override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {}
        override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {}

        private enum SwipeMode { case undecided, scrubbing, vertical }
        private var mode: SwipeMode = .undecided
        private var scrubOrigin: Double = 0

        @objc private func pan(_ g: UIPanGestureRecognizer) {
            guard let spec else { return }
            let width = Double(bounds.width)
            let t = g.translation(in: self)
            switch g.state {
            case .began:
                mode = .undecided
            case .changed:
                if mode == .undecided {
                    // Decide the direction once the finger has moved a little: sideways scrubs, down opens the panel.
                    guard max(abs(t.x), abs(t.y)) > 40 else { return }
                    if abs(t.x) >= abs(t.y) {
                        mode = .scrubbing
                        scrubOrigin = Double(t.x)
                        spec.onScrubBegan()
                    } else {
                        mode = .vertical
                        if t.y > 0 { spec.onDown() } else { spec.onUp() }
                    }
                }
                if mode == .scrubbing {
                    let v = Double(g.velocity(in: self).x)
                    spec.onScrubChanged(Double(t.x) - scrubOrigin, width, abs(v) / max(1, width))
                }
            case .ended:
                if mode == .scrubbing { spec.onScrubEnded() }
                mode = .undecided
            case .cancelled, .failed:
                if mode == .scrubbing { spec.onScrubCancelled() }
                mode = .undecided
            default: break
            }
        }
    }
}
