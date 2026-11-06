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

    private let secrets: SecretStore
    private let session: URLSession
    private let images: ImageStore
    private var linkTask: Task<Void, Never>?

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
        // Developer shortcut: seed the Keychain from launch environment variables (simulator and devicectl).
        let env = ProcessInfo.processInfo.environment
        if let t = env["HR_TOKEN"], let s = env["HR_SERVER"] {
            secrets.set(t, for: Key.token)
            secrets.set(s, for: Key.server)
        }
        if let k = env["HR_TV_PSK"] { secrets.set(k, for: Key.tvKey) }
        if let h = env["HR_TV_HOST"] { secrets.set(h, for: Key.tvHost) }
        if let e = env["HR_TV_ENABLED"] { tvEnabled = e == "1" }
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
            phase = .signedOut
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: Library catalog

    private var catalog: (date: Date, items: [PlexItem])?

    /// Every movie and show you own, kept for ten minutes. Person pages match online credits against it.
    func libraryCatalog() async -> [PlexItem] {
        if let catalog, Date().timeIntervalSince(catalog.date) < 600 { return catalog.items }
        guard let c = client, let items = try? await c.allTitles(in: movieLibraries + showLibraries) else { return catalog?.items ?? [] }
        catalog = (Date(), items)
        return items
    }

    // MARK: Details

    /// The freshest copy of an item: the full details if we have loaded them, else what the list gave us.
    /// Posters read this so a watched mark made on a detail page shows on every list.
    func current(_ item: PlexItem) -> PlexItem { details[item.ratingKey] ?? item }

    /// After an episode changes, its season and show change too (unwatched counts), so reload those as well.
    func loadDetailAndParents(_ item: PlexItem) async {
        await loadDetail(item.ratingKey)
        for key in [item.parentRatingKey, item.grandparentRatingKey].compactMap({ $0 }) { await loadDetail(key) }
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

    func signInWithCode() {
        linkTask?.cancel()
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
                phase = .connecting
                let servers = try await auth.servers(token: token)
                guard let server = servers.first(where: { $0.owned == true }) ?? servers.first else {
                    phase = .failed("No Plex server found on this account.")
                    return
                }
                guard let url = await PlexConnectionPicker.firstReachable(PlexConnectionPicker.candidates(for: server), session: session) else {
                    phase = .failed("Found \(server.name) but could not reach it from this network. You can also sign in with the server address and token.")
                    return
                }
                secrets.set(token, for: Key.token)
                secrets.set(url.absoluteString, for: Key.server)
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
        var a = address.trimmingCharacters(in: .whitespaces)
        if !a.contains("://") { a = "http://" + a }
        if URL(string: a)?.port == nil, let u = URL(string: a), u.scheme == "http" { a += ":32400" }
        secrets.set(token.trimmingCharacters(in: .whitespaces), for: Key.token)
        secrets.set(a, for: Key.server)
        secrets.remove(Key.serverName)
        await connect()
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
        details = [:]
        movieLibraries = []
        showLibraries = []
        phase = .signedOut
    }
}
