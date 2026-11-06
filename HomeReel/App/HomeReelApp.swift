import SwiftUI

@main
struct HomeReelApp: App {
    @StateObject private var app = Self.makeModel()

    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(app)
        }
    }

    /// Normal launches use the Keychain and the real network. UI tests pass `-fixture <mode>` to use a pretend server.
    @MainActor private static func makeModel() -> AppModel {
        #if DEBUG
        if let mode = LaunchOptions.value("-fixture") {
            var seeded: [String: String] = mode == "signedout" ? [:] : [
                AppModel.Key.token: "fixture-token",
                AppModel.Key.server: "http://10.0.0.5:32400",
                AppModel.Key.serverName: "Fixture NAS",
            ]
            if let k = LaunchOptions.value("-tvkey") { seeded[AppModel.Key.tvKey] = k }
            if LaunchOptions.value("-tv") == "on" { seeded[AppModel.Key.tvHost] = "192.0.2.50" }   // an address the pretend TV answers on
            let session = FixtureURLProtocol.session(mode: mode)
            ImageStore.shared.use(session: session)
            let model = AppModel(secrets: InMemorySecretStore(seeded), session: session)
            model.tvEnabled = LaunchOptions.value("-tv") == "on"      // tests choose; never inherit a saved value
            return model
        }
        #endif
        return AppModel()
    }
}
