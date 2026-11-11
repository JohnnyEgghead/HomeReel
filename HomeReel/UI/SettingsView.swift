import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var app: AppModel
    @State private var confirmSignOut = false
    @State private var tvHost = ""
    @State private var tvKey = ""
    @State private var tvStatus: String?
    @State private var tvLoaded = false
    @AppStorage(SubtitlePreferences.defaultLanguageKey) private var defaultSubtitleLanguage = "off"

    private static let languages: [(code: String, name: String)] = [
        ("off", "Off"), ("en", "English"), ("es", "Spanish"), ("fr", "French"), ("de", "German"),
        ("it", "Italian"), ("pt", "Portuguese"), ("ja", "Japanese"), ("ko", "Korean"), ("zh", "Chinese"),
    ]

    var body: some View {
        List {
            Section("Server") {
                LabeledContent("Name", value: app.serverName)
                LabeledContent("Address", value: app.client?.baseURL.absoluteString ?? "")
                LabeledContent("Movie library", value: app.movieLibraries.first?.title ?? "None")
                LabeledContent("TV library", value: app.showLibraries.first?.title ?? "None")
            }
            Section("Playback") {
                Picker("Default subtitles", selection: $defaultSubtitleLanguage) {
                    ForEach(Self.languages, id: \.code) { Text($0.name).tag($0.code) }
                }
                Text("Used when a show has no saved choice. Your last choice for a show wins over this.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("TV Picture") {
                Toggle("Control a Sony TV's picture mode", isOn: $app.tvEnabled)
                if app.tvEnabled {
                    TextField("TV address, for example 192.168.1.50", text: $tvHost)
                    SecureField("TV key (pre-shared key)", text: $tvKey)
                    Button("Save and Test") { Task { await saveAndTestTV() } }
                    if let tvStatus { Text(tvStatus).font(.footnote).foregroundStyle(.secondary) }
                }
                Text(app.tvEnabled
                     ? "Adds a Picture tab to the video panel that switches a Sony BRAVIA TV between Dolby Vision modes. The key is stored in this Apple TV's Keychain."
                     : "Off. Turn this on only for an Apple TV that is connected to a Sony BRAVIA TV.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Account") {
                Button { confirmSignOut = true } label: { Text("Sign Out").foregroundStyle(Color(red: 0.86, green: 0.12, blue: 0.12)) }
            }
            Section("About") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                Text("HomeReel is an independent app and is not affiliated with or endorsed by Plex.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
        .onAppear {
            guard !tvLoaded else { return }
            tvHost = app.tvHost
            tvKey = app.tvKey
            tvLoaded = true
        }
        .confirmationDialog("Sign out of this server?", isPresented: $confirmSignOut) {
            Button("Sign Out", role: .destructive) { app.signOut() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func saveAndTestTV() async {
        guard app.saveTV(host: tvHost, key: tvKey) else {
            tvStatus = "This Apple TV would not save the TV settings. Try again."
            return
        }
        tvStatus = "Asking the TV..."
        do {
            let modes = try await app.tv.pictureModes()
            let current = "Connected. Picture mode: \(modes.currentLabel)."
            if tvKey.isEmpty {
                tvStatus = current + " No key yet, so it can be read but not changed."
            } else if modes.isAvailable {
                try await app.tv.verifyKey(modes)
                tvStatus = current + " Key accepted."
            } else {
                tvStatus = current + " The key can be tested while a video is playing."
            }
        } catch { tvStatus = error.localizedDescription }
    }
}
