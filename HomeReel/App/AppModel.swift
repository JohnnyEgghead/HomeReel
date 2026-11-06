import Foundation
import SwiftUI

/// Where the app is in the sign-in story, and the Plex connection once it is ready.
@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case launching
        case signedOut
        case linking(code: String)
        case connecting
        case ready
        case failed(String)
    }

    /// Whether this Apple TV may control a Sony TV's picture mode. Off unless turned on in Settings, so an Apple TV
    /// connected to a different TV never shows the Picture tab. Kept per device.
    @Published var tvEnabled: Bool = UserDefaults.standard.bool(forKey: AppModel.tvEnabledKey) {
        didSet { UserDefaults.standard.set(tvEnabled, forKey: Self.tvEnabledKey) }
    }

    @Published private(set) var phase: Phase = .launching
    @Published private(set) var client: PlexClient?
    @Published private(set) var serverName = ""
    @Published private(set) var movieLibraries: [PlexSection] = []
    @Published private(set) var showLibraries: [PlexSection] = []
    /// Full details (cast, streams) by rating key. Kept here, not in a screen, so a screen that is
    /// rebuilt by navigation never loses what it fetched.
    @Published private(set) var details: [String: PlexItem] = [:]

    /// Why the sign-in screen is showing, when something sent the viewer back to it.
    @Published private(set) var signInNotice: String?
    /// A short message over every screen for a few seconds, such as a watched mark that could not be saved.
    @Published private(set) var banner: String?
    /// Goes up each time the player finishes saving, so lists know to reload.
    @Published private(set) var playbackSaves = 0

    private let secrets: SecretStore
    private let session: URLSession
    private let images: ImageStore
    private var linkTask: Task<Void, Never>?
    private var bannerTask: Task<Void, Never>?

    enum Key {
        static let token = "plexToken"
        static let server = "serverURL"
        static let serverName = "serverName"
        static let clientID = "clientID"
        static let tvHost = "tvHost"
        static let tvKey = "tvKey"
    }

    init(secrets: SecretStore = KeychainSecretStore(), session: URLSession = .shared, images: ImageStore = .shared) {
        self.secrets = secrets
        self.session = session
        self.images = images
    }

    var identity: PlexIdentity {
        if let id = secrets.get(Key.clientID) { return PlexIdentity(clientID: id) }
        let id = UUID().uuidString
        secrets.set(id, for: Key.clientID)
        return PlexIdentity(clientID: id)
    }

    /// Plex's online database, for people and their credits. Nil when signed out.
    var discover: PlexDiscover? {
        guard let token = secrets.get(Key.token) else { return nil }
        return PlexDiscover(token: token, identity: identity, session: session)
    }

    // MARK: TV picture mode

    /// No default: the address of your own TV goes in Settings.
    static let defaultTVHost = ""
    static let tvEnabledKey = "tvControlEnabled"
    var tvHost: String { secrets.get(Key.tvHost) ?? Self.defaultTVHost }
    var tvKey: String { secrets.get(Key.tvKey) ?? "" }
    /// The Sony TV, for the Picture tab. Without a key it can read the mode but not change it.
    var tv: BraviaClient { BraviaClient(host: tvHost, psk: tvKey, session: session) }

    func saveTV(host: String, key: String) {
        let h = host.trimmingCharacters(in: .whitespaces)
        if h.isEmpty || h == Self.defaultTVHost { secrets.remove(Key.tvHost) } else { secrets.set(h, for: Key.tvHost) }
        if key.isEmpty { secrets.remove(Key.tvKey) } else { secrets.set(key, for: Key.tvKey) }
    }

    // MARK: Launch

    func start() async {
        images.removeOldCacheOnce()
        #if DEBUG
        // Developer shortcut: seed the Keychain from launch environment variables (simulator and devicectl).
        let env = ProcessInfo.processInfo.environment
        if let t = env["HR_TOKEN"], let s = env["HR_SERVER"] {
            secrets.set(t, for: Key.token)
            secrets.set(s, for: Key.server)
        }
        if let k = env["HR_TV_PSK"] { secrets.set(k, for: Key.tvKey) }
        if let h = env["HR_TV_HOST"] { secrets.set(h, for: Key.tvHost) }
        if let e = env["HR_TV_ENABLED"] { tvEnabled = e == "1" }
        #endif
        guard secrets.get(Key.token) != nil, secrets.get(Key.server) != nil else {
            phase = .signedOut
            return
        }
        await connect()
    }

    func connect() async {
        guard let token = secrets.get(Key.token), let s = secrets.get(Key.server), let url = URL(string: s) else {
            phase = .signedOut
            return
        }
        phase = .connecting
        let c = PlexClient(baseURL: url, token: token, identity: identity, session: session)
        do {
            let libs = try await c.libraries()
            client = c
            movieLibraries = libs.movies
            showLibraries = libs.shows
            serverName = secrets.get(Key.serverName) ?? url.host() ?? "Plex server"
            phase = .ready
        } catch PlexError.unauthorized {
            secrets.remove(Key.token)
            signInNotice = PlexError.unauthorized.errorDescription
            phase = .signedOut
        } catch is CancellationError {
            phase = .signedOut
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func show(banner text: String) {
        banner = text
        bannerTask?.cancel()
        bannerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self?.banner = nil
        }
    }

    // MARK: Library catalog

    private var catalog: (date: Date, items: [PlexItem])?

    /// Every movie and show you own, kept for ten minutes. Person pages match online credits against it.
    /// Nil when the server could not be read and there is no earlier copy: an unknown library, not an empty one.
    func libraryCatalog() async -> [PlexItem]? {
        if let catalog, Date().timeIntervalSince(catalog.date) < 600 { return catalog.items }
        guard let c = client, let items = try? await c.allTitles(in: movieLibraries + showLibraries) else { return catalog?.items }
        catalog = (Date(), items)
        return items
    }

    // MARK: Details

    /// The freshest copy of an item. Posters read this so a watched mark made on a detail page shows on every list.
    /// The full details usually win, unless the list saw a later viewing, such as one on another device.
    func current(_ item: PlexItem) -> PlexItem {
        guard let full = details[item.ratingKey] else { return item }
        return (item.lastViewedAt ?? 0) > (full.lastViewedAt ?? 0) ? item : full
    }

    /// After an episode changes, its season and show change too (unwatched counts), so reload those as well.
    func loadDetailAndParents(_ item: PlexItem) async {
        await loadDetail(item.ratingKey)
        for key in [item.parentRatingKey, item.grandparentRatingKey].compactMap({ $0 }) { await loadDetail(key) }
    }

    /// Saves what the player needs saved, then refreshes what changed. The screen has already closed by now,
    /// so a slow or missing network never holds it open.
    func finishPlayback(_ model: PlayerModel) async {
        if let problem = await model.finish() { show(banner: problem) }
        await loadDetailAndParents(model.item)
        playbackSaves += 1
    }

    func loadDetail(_ ratingKey: String) async {
        guard let c = client else { return }
        do {
            let full = try await c.metadata(ratingKey)
            details[ratingKey] = full
        } catch {
            debugLog("detail FAILED key=\(ratingKey) error=\(error)")
        }
    }

    // MARK: Sign in with a code (plex.tv/link)

    /// Keeps the sign-in. If this Apple TV refuses, says so here, because the next launch would look signed out.
    private func saveSignIn(token: String, server: String) -> Bool {
        guard secrets.set(token, for: Key.token), secrets.set(server, for: Key.server) else {
            secrets.remove(Key.token)
            phase = .failed("Could not save your sign-in on this Apple TV.")
            return false
        }
        return true
    }

    func signInWithCode() {
        linkTask?.cancel()
        signInNotice = nil
        linkTask = Task {
            let auth = PlexAuth(identity: identity, session: session)
            do {
                let pin = try await auth.createPin()
                phase = .linking(code: pin.code)
                let deadline = Date().addingTimeInterval(5 * 60)
                var token: String?
                while token == nil, Date() < deadline, !Task.isCancelled {
                    try await Task.sleep(for: .seconds(2))
                    token = try await auth.checkPin(pin.id)
                }
                guard let token else {
                    if !Task.isCancelled { phase = .failed("The code expired. Try again.") }
                    return
                }
                try Task.checkCancellation()
                phase = .connecting
                let servers = try await auth.servers(token: token)
                guard let server = servers.first(where: { $0.owned == true }) ?? servers.first else {
                    phase = .failed("No Plex server found on this account.")
                    return
                }
                guard let url = await PlexConnectionPicker.firstReachable(PlexConnectionPicker.candidates(for: server), machineID: server.clientIdentifier, session: session) else {
                    phase = .failed("Found \(server.name) but could not reach it from this network. You can also sign in with the server address and token.")
                    return
                }
                guard saveSignIn(token: token, server: url.absoluteString) else { return }
                secrets.set(server.name, for: Key.serverName)
                await connect()
            } catch is CancellationError {
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Fallback: type the server address and a token.
    func signInManually(address: String, token: String) async {
        signInNotice = nil
        guard saveSignIn(token: token.trimmingCharacters(in: .whitespacesAndNewlines), server: Self.serverAddress(from: address)) else { return }
        secrets.remove(Key.serverName)
        await connect()
    }

    /// What was typed as a server address, made complete: a scheme, and Plex's port for plain http.
    static func serverAddress(from typed: String) -> String {
        var a = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if !a.contains("://") { a = "http://" + a }
        guard var c = URLComponents(string: a), c.host?.isEmpty == false else { return a }
        if c.scheme == "http", c.port == nil { c.port = 32400 }
        c.path = ""
        return c.string ?? a
    }

    func cancelLinking() {
        linkTask?.cancel()
        phase = .signedOut
    }

    func signOut() {
        linkTask?.cancel()
        secrets.remove(Key.token)
        secrets.remove(Key.server)
        secrets.remove(Key.serverName)
        images.clear()
        client = nil
        catalog = nil
        serverName = ""
        details = [:]
        movieLibraries = []
        showLibraries = []
        phase = .signedOut
    }
}
