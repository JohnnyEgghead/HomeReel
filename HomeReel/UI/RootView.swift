import SwiftUI

struct RootView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        Group {
            switch app.phase {
            case .launching, .connecting:
                ProgressView("Connecting").frame(maxWidth: .infinity, maxHeight: .infinity)
            case .signedOut, .linking:
                SignInView()
            case .failed(let message):
                FailedView(message: message)
            case .ready:
                MainTabView()
            }
        }
        .overlay(alignment: .bottom) {
            if let banner = app.banner { BannerView(text: banner) }
        }
        .preferredColorScheme(.dark)
        .task { await app.start() }
    }
}

struct FailedView: View {
    @EnvironmentObject var app: AppModel
    let message: String
    var body: some View {
        VStack(spacing: 30) {
            MessageView(title: "Could not connect", detail: message)
            HStack(spacing: 40) {
                Button("Try Again") { Task { await app.connect() } }
                Button("Sign Out", role: .destructive) { app.signOut() }
            }
        }
    }
}

/// Launch arguments for screenshots and tests. docs/DESIGN.md lists them.
enum LaunchOptions {
    static func value(_ name: String) -> String? {
        let a = ProcessInfo.processInfo.arguments
        guard let i = a.firstIndex(of: name), i + 1 < a.count else { return nil }
        return a[i + 1]
    }
}

private struct OpenEpisodeListKey: EnvironmentKey {
    nonisolated(unsafe) static let defaultValue: (PlexItem) -> Void = { _ in }
}
extension EnvironmentValues {
    /// Shows the list of episodes (the season page) for an episode. Used when playback ends.
    var openEpisodeList: (PlexItem) -> Void {
        get { self[OpenEpisodeListKey.self] }
        set { self[OpenEpisodeListKey.self] = newValue }
    }
}

private struct OpenSeriesKey: EnvironmentKey {
    nonisolated(unsafe) static let defaultValue: (PlexItem) -> Void = { _ in }
}
extension EnvironmentValues {
    /// Shows the TV show page for an episode (or a season).
    var openSeries: (PlexItem) -> Void {
        get { self[OpenSeriesKey.self] }
        set { self[OpenSeriesKey.self] = newValue }
    }
}

struct MainTabView: View {
    @EnvironmentObject var app: AppModel
    @State private var tab = LaunchOptions.value("-tab") ?? "home"
    /// Each tab keeps its own trail of pages, so choosing a tab can send it back to its first page.
    @State private var paths: [String: NavigationPath] = [:]

    private func path(_ key: String) -> Binding<NavigationPath> {
        Binding(get: { paths[key] ?? NavigationPath() }, set: { paths[key] = $0 })
    }

    /// Choosing a tab, or choosing the tab you are already on, shows that tab's first page.
    private var selection: Binding<String> {
        Binding(get: { tab }, set: { new in
            paths[new] = NavigationPath()
            tab = new
        })
    }

    /// Lives inside a tab's content so it can reach the tab bar controller above it.
    private var catcher: some View { TabReselectCatcher(onClick: { paths[tab] = NavigationPath() }) }

    /// Replaces the current tab's pages with the show and then the season the episode belongs to.
    private func openEpisodeList(_ episode: PlexItem) {
        guard let c = app.client, let seasonKey = episode.parentRatingKey, let showKey = episode.grandparentRatingKey else { return }
        let key = tab
        Task {
            guard let show = try? await c.metadata(showKey), let season = try? await c.metadata(seasonKey) else {
                // Could not reach the server: say so, and do what Menu normally does so the remote never feels stuck.
                app.show(banner: "Could not open the season. Check the server and try again.")
                if var p = paths[key], !p.isEmpty { p.removeLast(); paths[key] = p }
                return
            }
            paths[key] = NavigationPath([show, season])
        }
    }

    /// Replaces the current tab's pages with the TV show an episode or season belongs to.
    private func openSeries(_ item: PlexItem) {
        guard let c = app.client, let showKey = item.grandparentRatingKey ?? item.parentRatingKey else { return }
        let key = tab
        Task {
            guard let show = try? await c.metadata(showKey) else {
                app.show(banner: "Could not open the series. Check the server and try again.")
                return
            }
            paths[key] = NavigationPath([show])
        }
    }

    var body: some View {
        TabView(selection: selection) {
            NavigationStack(path: path("home")) { HomeView().withDestinations() }
                .background(catcher)
                .tabItem { Label("Home", systemImage: "house") }.tag("home")
            NavigationStack(path: path("movies")) { LibraryView(kind: .movies).withDestinations() }
                .background(catcher)
                .tabItem { Label("Movies", systemImage: "film") }.tag("movies")
            NavigationStack(path: path("shows")) { LibraryView(kind: .shows).withDestinations() }
                .background(catcher)
                .tabItem { Label("TV Shows", systemImage: "tv") }.tag("shows")
            NavigationStack(path: path("search")) { SearchView(initialText: LaunchOptions.value("-query") ?? "").withDestinations() }
                .tabItem { Label("Search", systemImage: "magnifyingglass") }.tag("search")
            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape") }.tag("settings")
        }
        .environment(\.openEpisodeList, { openEpisodeList($0) })
        .environment(\.openSeries, { openSeries($0) })
        .task {
            if let key = LaunchOptions.value("-open"), let c = app.client, let item = try? await c.metadata(key) {
                tab = "home"
                var p = NavigationPath()
                p.append(item)
                // Developer check: also push the season's first episode, as tapping it would (list data, not full metadata).
                if LaunchOptions.value("-autoepisode") != nil, let ep = try? await c.children(key).first { p.append(SeasonEpisode(item: ep)) }
                // Developer check: also push a person, as selecting a cast member would.
                if LaunchOptions.value("-person") != nil {
                    let full = try? await c.metadata(key)
                    if let first = item.Role?.first ?? full?.Role?.first { p.append(first) }
                }
                paths["home"] = p
            }
        }
    }
}

extension View {
    /// Where taps lead: items open their pages, people open their profile.
    func withDestinations() -> some View {
        navigationDestination(for: PlexItem.self) { ItemDestination(item: $0) }
            .navigationDestination(for: SeasonEpisode.self) { MediaDetailView(item: $0.item, fromSeasonList: true) }
            .navigationDestination(for: PlexTag.self) { PersonView(tag: $0) }
            .navigationDestination(for: NotInLibrary.self) { NotInLibraryView(page: $0) }
    }
}

/// Tells us when the viewer clicks a tab in the tab bar. On tvOS, moving onto a tab already selects it,
/// and SwiftUI does not report a click on the tab you are on, so this listens for the click itself.
struct TabReselectCatcher: UIViewControllerRepresentable {
    var onClick: () -> Void

    func makeUIViewController(context: Context) -> Finder { Finder(onClick: onClick) }
    func updateUIViewController(_ vc: Finder, context: Context) { vc.onClick = onClick }

    final class Finder: UIViewController, UIGestureRecognizerDelegate {
        var onClick: () -> Void
        private var attachedTo: UITabBarController?

        init(onClick: @escaping () -> Void) {
            self.onClick = onClick
            super.init(nibName: nil, bundle: nil)
            view.isUserInteractionEnabled = false
        }
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard attachedTo == nil, let tbc = tabBarController ?? findTabBarController() else { return }
            // Already attached by another tab's catcher? Then leave it.
            if tbc.view.gestureRecognizers?.contains(where: { $0.name == "HomeReelTabClick" }) == true { attachedTo = tbc; return }
            // A zero-length press fires the moment Select goes down, while focus is still on the tab bar.
            let press = UILongPressGestureRecognizer(target: self, action: #selector(pressed(_:)))
            press.name = "HomeReelTabClick"
            press.minimumPressDuration = 0
            press.allowedPressTypes = [NSNumber(value: UIPress.PressType.select.rawValue)]
            press.allowedTouchTypes = []
            press.cancelsTouchesInView = false
            press.delegate = self
            tbc.view.addGestureRecognizer(press)
            attachedTo = tbc
        }

        @objc private func pressed(_ g: UILongPressGestureRecognizer) {
            guard g.state == .began, let tbc = attachedTo else { return }
            let focusInTabBar = (UIFocusSystem.focusSystem(for: tbc)?.focusedItem as? UIView)?.isDescendant(of: tbc.tabBar) ?? false
            if focusInTabBar { DispatchQueue.main.async { self.onClick() } }
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        private func findTabBarController() -> UITabBarController? {
            var p = parent
            while let x = p { if let t = x as? UITabBarController { return t }; p = x.parent }
            var r: UIResponder? = self
            while let n = r?.next { if let t = n as? UITabBarController { return t }; r = n }
            return nil
        }
    }
}
