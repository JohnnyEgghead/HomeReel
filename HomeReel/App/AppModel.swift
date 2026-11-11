import Foundation
import SwiftUI
import Combine

/// Everything that belongs to one sign-in: the connection, the libraries, and what was fetched through it.
/// Signing out, or being signed out by a rejected token, drops the whole object. Work still running for it can
/// only write into this dead copy, never into the next sign-in's.
@MainActor
final class Session: ObservableObject {
    let id: UUID
    let client: PlexClient
    let serverName: String
    let movieLibraries: [PlexSection]
    let showLibraries: [PlexSection]
    /// Full details (cast, streams) by rating key. Kept here, not in a screen, so a screen that is
    /// rebuilt by navigation never loses what it fetched.
    @Published fileprivate(set) var details: [String: PlexItem] = [:]
    fileprivate var catalog: (date: Date, items: [PlexItem])?

    init(id: UUID, client: PlexClient, serverName: String, libraries: (movies: [PlexSection], shows: [PlexSection])) {
        self.id = id
        self.client = client
        self.serverName = serverName
        movieLibraries = libraries.movies
        showLibraries = libraries.shows
    }
}

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
    /// The current sign-in's connection and data. Nil when signed out.
    @Published private(set) var active: Session? {
        didSet { activeObserver = active?.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() } }
    }
    private var activeObserver: AnyCancellable?

    var client: PlexClient? { active?.client }
    var serverName: String { active?.serverName ?? "" }
    var movieLibraries: [PlexSection] { active?.movieLibraries ?? [] }
    var showLibraries: [PlexSection] { active?.showLibraries ?? [] }
    var details: [String: PlexItem] { active?.details ?? [:] }

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
    /// How often the code sign-in asks plex.tv whether the code was entered. Short in tests.
    var linkPollInterval: Duration = .seconds(2)
    private var bannerTask: Task<Void, Never>?

    /// Shown on the sign-in screen after plex.tv itself refused the saved token.
    static let signInRefusedNotice = "Plex did not accept the sign-in. Sign in again."

    enum Key {
        static let token = "plexToken"
        static let server = "serverURL"
        static let serverName = "serverName"
        /// The id the server reported at /identity. The saved address must still answer with it before the token is sent.
        static let serverID = "serverID"
        static let clientID = "clientID"
        static let tvHost = "tvHost"
        static let tvKey = "tvKey"
    }

    init(secrets: SecretStore = KeychainSecretStore(), session: URLSession = .uncached, images: ImageStore = .shared) {
        self.secrets = secrets
        self.session = session
        self.images = images
        self.identity = Self.loadIdentity(secrets)
    }

    /// Who this Apple TV is to Plex. Loaded once, when the app model is made, so nothing reads or writes the
    /// Keychain behind a property access.
    let identity: PlexIdentity

    private static func loadIdentity(_ secrets: SecretStore) -> PlexIdentity {
        switch secrets.read(Key.clientID) {
        case .value(let id): return PlexIdentity(clientID: id)
        case .missing:
            let id = UUID().uuidString
            secrets.set(id, for: Key.clientID)
            return PlexIdentity(clientID: id)
        case .failed:
            // The store would not say whether an id exists. A throwaway for this run is safer than writing over a real one.
            return PlexIdentity(clientID: UUID().uuidString)
        }
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

    /// False when this Apple TV would not save the settings.
    @discardableResult
    func saveTV(host: String, key: String) -> Bool {
        let h = host.trimmingCharacters(in: .whitespaces)
        let hostSaved = (h.isEmpty || h == Self.defaultTVHost) ? secrets.remove(Key.tvHost) : secrets.set(h, for: Key.tvHost)
        let keySaved = key.isEmpty ? secrets.remove(Key.tvKey) : secrets.set(key, for: Key.tvKey)
        return hostSaved && keySaved
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
            secrets.remove(Key.serverID)      // learned again from the server at this address
        }
        if let k = env["HR_TV_PSK"] { secrets.set(k, for: Key.tvKey) }
        if let h = env["HR_TV_HOST"] { secrets.set(h, for: Key.tvHost) }
        if let e = env["HR_TV_ENABLED"] { tvEnabled = e == "1" }
        #endif
        await connect()
    }

    /// What is saved from the last sign-in. A store that will not answer is not the same as nothing saved.
    private enum Saved { case nothing, unreadable, found(token: String, server: URL) }

    private func savedSignIn() -> Saved {
        switch (secrets.read(Key.token), secrets.read(Key.server)) {
        case (.failed, _), (_, .failed): return .unreadable
        case (.value(let t), .value(let s)):
            guard let url = URL(string: s) else { return .nothing }
            return .found(token: t, server: url)
        default: return .nothing
        }
    }

    func connect() async {
        let token: String, saved: URL
        switch savedSignIn() {
        case .nothing:
            phase = .signedOut
            return
        case .unreadable:
            // Do not show the sign-in screen: signing in again would write over a sign-in that is probably fine.
            phase = .failed("This Apple TV would not let HomeReel read its saved sign-in. Try again in a moment. Nothing was deleted.")
            return
        case .found(let t, let s):
            token = t; saved = s
        }
        phase = .connecting
        do {
            // Ask the saved address who it is BEFORE the token goes there.
            guard let (url, serverID) = try await trustedAddress(saved: saved, token: token) else { return }
            let id = UUID()
            let c = PlexClient(baseURL: url, token: token, identity: identity, session: session, serverID: serverID,
                               onUnauthorized: { [weak self] in Task { @MainActor in await self?.serverRefused(token: token, sessionID: id) } })
            let libs = try await c.libraries()
            active = Session(id: id, client: c, serverName: secrets.get(Key.serverName) ?? url.host() ?? "Plex server", libraries: libs)
            phase = .ready
        } catch PlexError.unauthorized {
            // One refused request is not proof the token is bad. Only plex.tv's own answer deletes it.
            switch await PlexAuth(identity: identity, session: session).tokenStatus(token) {
            case .refused:
                secrets.remove(Key.token)
                signInNotice = Self.signInRefusedNotice
                endSession()
                phase = .signedOut
            case .valid:
                phase = .failed("The server did not accept your sign-in, but Plex says your account is fine. Try again in a moment. Nothing was deleted.")
            case .unknown:
                phase = .failed("The server did not accept your sign-in, and Plex could not be reached to check it. Try again in a moment. Nothing was deleted.")
            }
        } catch is CancellationError {
            phase = .signedOut
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// The address to send the token to, and the server's id. The saved address has to answer /identity as the server
    /// that was signed in to. If it does not (the server got a new address, or another device took the old one), plex.tv
    /// is asked where that server is now. Nil means this set `phase` to the failure.
    ///
    /// A sign-in with no saved id (a typed address, or one made before this check existed) learns it from the server
    /// the first time. From then on, a different server at that address is refused.
    private func trustedAddress(saved: URL, token: String) async throws -> (URL, String)? {
        guard let knownID = secrets.get(Key.serverID) else {
            guard let learned = await PlexConnectionPicker.machineID(at: saved, session: session) else {
                phase = .failed("Could not reach the server at \(saved.host() ?? "its saved address"). Check that it is on and on this network.")
                return nil
            }
            secrets.set(learned, for: Key.serverID)
            return (saved, learned)
        }
        if await PlexConnectionPicker.machineID(at: saved, session: session) == knownID { return (saved, knownID) }
        let auth = PlexAuth(identity: identity, session: session)
        let name = secrets.get(Key.serverName) ?? "your server"
        guard let server = try await auth.servers(token: token).first(where: { $0.clientIdentifier == knownID }),
              let fresh = await PlexConnectionPicker.firstReachable(PlexConnectionPicker.candidates(for: server), machineID: knownID, session: session) else {
            phase = .failed("Could not reach \(name). It does not answer at its saved address, and Plex has no other address for it that works from here.")
            return nil
        }
        secrets.set(fresh.absoluteString, for: Key.server)
        return (fresh, knownID)
    }

    /// Drops the current sign-in and everything that came through it.
    private func endSession() {
        active = nil
        images.clear()
    }

    /// A request to the server got 401. That alone does not delete the token: the server may be restarting, or unable
    /// to reach plex.tv. So plex.tv is asked, and only its own refusal ends the sign-in. Only the current sign-in can
    /// end itself: a late answer to a sign-in that is already gone is ignored.
    private func serverRefused(token: String, sessionID: UUID) async {
        guard active?.id == sessionID, !checkingToken else { return }     // one check at a time, however many requests failed
        checkingToken = true
        defer { checkingToken = false }
        let status = await PlexAuth(identity: identity, session: session).tokenStatus(token)
        guard active?.id == sessionID else { return }                      // signed out or replaced while asking
        switch status {
        case .refused: tokenRejected(sessionID: sessionID)
        case .valid: show(banner: "The server refused a request, but your Plex sign-in is fine. Try again.")
        case .unknown: show(banner: "The server refused a request, and Plex could not be reached to check your sign-in. It was kept.")
        }
    }

    private var checkingToken = false

    /// plex.tv itself refused the token: forget it and show the sign-in screen.
    private func tokenRejected(sessionID: UUID) {
        guard active?.id == sessionID else { return }
        secrets.remove(Key.token)
        signInNotice = Self.signInRefusedNotice
        endSession()
        phase = .signedOut
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

    /// Every movie and show you own, kept for ten minutes. Person pages match online credits against it.
    /// Nil when the server could not be read and there is no earlier copy: an unknown library, not an empty one.
    func libraryCatalog() async -> [PlexItem]? {
        guard let s = active else { return nil }
        if let catalog = s.catalog, Date().timeIntervalSince(catalog.date) < 600 { return catalog.items }
        guard let items = try? await s.client.allTitles(in: s.movieLibraries + s.showLibraries) else { return s.catalog?.items }
        s.catalog = (Date(), items)
        return items
    }

    // MARK: Details

    /// The freshest copy of an item. Posters read this so a watched mark made on a detail page shows on every list.
    /// The full details usually win, unless the list saw a later viewing, such as one on another device.
    func current(_ item: PlexItem) -> PlexItem {
        guard let full = details[item.ratingKey] else { return item }
        // Each copy knows when it was fetched, and the newer one is right (including after an Unwatched mark, which
        // leaves the last-viewed time alone). A copy with no stamp falls back to comparing last-viewed times.
        if let a = item.fetchedAt, let b = full.fetchedAt { return a > b ? item : full }
        return (item.lastViewedAt ?? 0) > (full.lastViewedAt ?? 0) ? item : full
    }

    /// After an episode changes, its season and show change too (unwatched counts), so reload those as well.
    func loadDetailAndParents(_ item: PlexItem) async {
        guard let s = active else { return }
        await loadDetailAndParents(item, in: s)
    }

    private func loadDetailAndParents(_ item: PlexItem, in s: Session) async {
        await loadDetail(item.ratingKey, in: s)
        for key in [item.parentRatingKey, item.grandparentRatingKey].compactMap({ $0 }) { await loadDetail(key, in: s) }
    }

    /// Saves what the player needs saved, then refreshes what changed. The screen has already closed by now,
    /// so a slow or missing network never holds it open. What it fetches goes to the sign-in that was current
    /// when playback ended, so it cannot land in a later one.
    func finishPlayback(_ model: PlayerModel) async {
        let s = active
        if let problem = await model.finish() { show(banner: problem) }
        if let s { await loadDetailAndParents(model.item, in: s) }
        playbackSaves += 1
    }

    /// Fetches the full details. Returns why it failed, so the page can say so, or nil when it worked (or was cancelled).
    @discardableResult
    func loadDetail(_ ratingKey: String) async -> String? {
        guard let s = active else { return nil }
        return await loadDetail(ratingKey, in: s)
    }

    @discardableResult
    private func loadDetail(_ ratingKey: String, in s: Session) async -> String? {
        do {
            s.details[ratingKey] = try await s.client.metadata(ratingKey)
            return nil
        } catch {
            if error.isCancellation { return nil }
            debugLog("detail FAILED key=\(ratingKey) error=\(error.localizedDescription)")
            return error.localizedDescription
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
                var lastProblem: Error?
                while token == nil, Date() < deadline, !Task.isCancelled {
                    try await Task.sleep(for: linkPollInterval)
                    // The code is good for 5 minutes, so one dropped answer must not end the sign-in.
                    do { token = try await auth.checkPin(pin.id); lastProblem = nil }
                    catch { if error.isCancellation { throw error }; lastProblem = error }
                }
                guard let token else {
                    if !Task.isCancelled {
                        phase = .failed(lastProblem.map { "Could not check the code: \($0.localizedDescription)" } ?? "The code expired. Try again.")
                    }
                    return
                }
                try Task.checkCancellation()
                phase = .connecting
                let servers = try await auth.servers(token: token)
                // Only a server this account owns. The token is account-wide, and a server shared with you belongs to
                // someone else, so it must not receive it. (The requirements say owned servers only.)
                guard let server = servers.first(where: { $0.owned == true }) else {
                    phase = .failed(servers.isEmpty
                        ? "No Plex server found on this account."
                        : "This account has no Plex server of its own, only shared ones. HomeReel signs in only to a server you own.")
                    return
                }
                // Without the server's own id there is no way to tell it from another device, and the token would go
                // to whatever answers. So no id means no sign-in.
                guard let serverID = server.clientIdentifier, !serverID.isEmpty else {
                    phase = .failed("Plex did not say which server \(server.name) is, so HomeReel cannot check that an address is really it.")
                    return
                }
                guard let url = await PlexConnectionPicker.firstReachable(PlexConnectionPicker.candidates(for: server), machineID: serverID, session: session) else {
                    phase = .failed("Found \(server.name) but could not reach it from this network. You can also sign in with the server address and token.")
                    return
                }
                guard saveSignIn(token: token, server: url.absoluteString) else { return }
                secrets.set(serverID, for: Key.serverID)
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
        linkTask?.cancel()          // a code sign-in still waiting must not finish over this one
        let cleanToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let server = Self.validServerAddress(address) else {
            signInNotice = "That does not look like a server address. Type it like 192.168.1.20 or http://192.168.1.20:32400."
            phase = .signedOut
            return
        }
        guard !cleanToken.isEmpty else {
            signInNotice = "Enter your Plex token."
            phase = .signedOut
            return
        }
        signInNotice = nil
        guard saveSignIn(token: cleanToken, server: server) else { return }
        secrets.remove(Key.serverName)
        secrets.remove(Key.serverID)         // the id of whatever server was here before is not this one's; connect() learns it
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

    /// The typed address made complete, or nil if it cannot be an address to reach a server at.
    static func validServerAddress(_ typed: String) -> String? {
        let full = serverAddress(from: typed)
        guard let c = URLComponents(string: full), let scheme = c.scheme, ["http", "https"].contains(scheme),
              let host = c.host, !host.isEmpty, !host.contains(" ") else { return nil }
        return full
    }

    func cancelLinking() {
        linkTask?.cancel()
        phase = .signedOut
    }

    func signOut() {
        linkTask?.cancel()
        // Every one is tried, even if an earlier one fails.
        let results = [Key.token, Key.server, Key.serverName, Key.serverID].map { secrets.remove($0) }
        endSession()
        signInNotice = results.allSatisfy { $0 } ? nil : "Signed out, but this Apple TV would not delete the saved sign-in. It may come back at the next launch."
        phase = .signedOut
    }
}
