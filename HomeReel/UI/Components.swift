import SwiftUI

/// Text colors for a dark UI. `.secondary` is translucent, so on busy backdrops it turns muddy.
enum Theme {
    static let secondaryText = Color.white.opacity(0.85)
    static let tertiaryText = Color.white.opacity(0.7)
}

/// Unbuffered log to stderr in debug builds, so `devicectl --console` shows lines as they happen.
func debugLog(_ message: String) {
    #if DEBUG
    FileHandle.standardError.write(Data("HR: \(message)\n".utf8))
    #endif
}

/// A gentle grow-on-focus that replaces tvOS's own zoom, which cropped artwork.
struct FocusScaleStyle: ButtonStyle {
    var scale: CGFloat = 1.06
    func makeBody(configuration: Configuration) -> some View {
        Scaler(content: configuration.label, scale: scale)
    }
    private struct Scaler<C: View>: View {
        @Environment(\.isFocused) private var focused
        let content: C
        let scale: CGFloat
        var body: some View {
            content.scaleEffect(focused ? scale : 1).animation(.easeOut(duration: 0.15), value: focused)
        }
    }
}

/// A bold ring around whatever has focus. The system's own zoom is too subtle from the couch.
struct FocusRing: ViewModifier {
    @Environment(\.isFocused) private var focused
    var cornerRadius: CGFloat = 12
    var circle = false

    func body(content: Content) -> some View {
        content.overlay {
            if focused {
                // Drawn outside the artwork so it never covers any of it.
                ZStack {
                    ringShape.stroke(.black.opacity(0.6), lineWidth: 4).padding(-9)
                    ringShape.stroke(.white, lineWidth: 6).padding(-3)
                }
                .shadow(color: .white.opacity(0.4), radius: 12)
            }
        }
    }

    private var ringShape: AnyShape {
        circle ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}

extension View {
    func focusRing(cornerRadius: CGFloat = 12, circle: Bool = false) -> some View {
        modifier(FocusRing(cornerRadius: cornerRadius, circle: circle))
    }
}

/// Text that turns bold and bright when its card has focus.
struct FocusText: View {
    @Environment(\.isFocused) private var focused
    let text: String
    var size: CGFloat = 24
    var secondary = false
    var body: some View {
        Text(text).lineLimit(1)
            .font(.system(size: size, weight: focused ? .bold : .regular))
            .foregroundStyle(focused ? Color.white : (secondary ? Theme.secondaryText : Color.white.opacity(0.92)))
    }
}

/// Loads a picture through the server's image resizer and keeps a small disk cache.
final class ImageStore: @unchecked Sendable {
    static let shared = ImageStore()
    private(set) var session: URLSession
    private let memory = NSCache<NSURL, UIImage>()
    private let cache: URLCache
    private static let oldCacheRemovedKey = "imageCacheWithTokensRemoved"

    init(cache: URLCache = URLCache(memoryCapacity: 40 << 20, diskCapacity: 150 << 20)) {
        self.cache = cache
        let cfg = URLSessionConfiguration.default
        cfg.urlCache = cache
        session = URLSession(configuration: cfg)
    }

    /// Forgets every picture, in memory and on disk. Called at sign-out.
    func clear() {
        memory.removeAllObjects()
        cache.removeAllCachedResponses()
    }

    /// Older versions put the token in picture addresses, and the disk cache kept those addresses.
    /// Clears that cache once, the first time this version runs.
    func removeOldCacheOnce(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: Self.oldCacheRemovedKey) else { return }
        clear()
        defaults.set(true, forKey: Self.oldCacheRemovedKey)
    }

    /// UI tests swap in the pretend server so no picture request leaves the Mac.
    func use(session: URLSession) { self.session = session; memory.removeAllObjects() }

    func image(for request: URLRequest) async -> UIImage? {
        guard let url = request.url else { return nil }
        if let hit = memory.object(forKey: url as NSURL) { return hit }
        var request = request
        request.cachePolicy = .returnCacheDataElseLoad
        do {
            let (data, resp) = try await session.data(for: request)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200, let img = UIImage(data: data) else {
                #if DEBUG
                debugLog("image failed status=\(code) bytes=\(data.count) host=\(url.host() ?? "?") path=\(url.path.suffix(40))")
                #endif
                return nil
            }
            memory.setObject(img, forKey: url as NSURL)
            return img
        } catch {
            #if DEBUG
            if !(error is CancellationError), (error as? URLError)?.code != .cancelled {
                debugLog("image error \(error.localizedDescription) host=\(url.host() ?? "?") path=\(url.path.suffix(40))")
            }
            #endif
            return nil
        }
    }
}

struct RemoteImage: View {
    let request: URLRequest?
    var contentMode: ContentMode = .fill
    var showsPlaceholder = true
    @State private var image: UIImage?

    /// A picture from the signed-in server. Build the request with `PlexClient.imageRequest`.
    init(request: URLRequest?, contentMode: ContentMode = .fill, showsPlaceholder: Bool = true) {
        self.request = request
        self.contentMode = contentMode
        self.showsPlaceholder = showsPlaceholder
    }

    /// A picture from the open web. No token goes with it.
    init(url: URL?, contentMode: ContentMode = .fill, showsPlaceholder: Bool = true) {
        self.init(request: url.map { URLRequest(url: $0) }, contentMode: contentMode, showsPlaceholder: showsPlaceholder)
    }

    var body: some View {
        ZStack {
            if showsPlaceholder { Color.secondary.opacity(0.15) }
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
            }
        }
        .task(id: request) {
            image = nil
            guard let request else { return }
            image = await ImageStore.shared.image(for: request)
        }
    }
}

/// The small marks on a poster: unwatched count for shows, a check for watched, a bar for partly watched.
/// A bright green circle with a white check. Readable on both dark and light posters.
struct WatchedMark: View {
    var body: some View {
        Image(systemName: "checkmark.circle.fill")
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, Color(red: 0.18, green: 0.84, blue: 0.33))
            .font(.system(size: 30, weight: .bold))
            .shadow(color: .black.opacity(0.55), radius: 3, y: 1)
    }
}

struct WatchBadge: View {
    let item: PlexItem
    var body: some View {
        ZStack(alignment: .bottom) {
            if item.type == .show || item.type == .season {
                if let n = item.unwatchedCount, n > 0 {
                    Text("\(n)").font(.callout.bold()).padding(.horizontal, 12).padding(.vertical, 4)
                        .background(.regularMaterial, in: Capsule())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(10)
                } else if item.isWatched {
                    WatchedMark().padding(10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
            } else if item.isWatched {
                WatchedMark().padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
            if let p = item.progress {
                ProgressView(value: p).padding(.horizontal, 10).padding(.bottom, 10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }
}

struct PosterCard: View {
    @EnvironmentObject var app: AppModel
    let item: PlexItem
    var landscape = false

    private var size: CGSize { landscape ? CGSize(width: 400, height: 225) : CGSize(width: 240, height: 360) }

    var body: some View {
        let shown = app.current(item)
        let path = landscape ? item.landscapePath : item.posterPath
        NavigationLink(value: item) {
            VStack(alignment: .leading, spacing: 10) {
                RemoteImage(request: app.client?.imageRequest(path, width: Int(size.width * 2), height: Int(size.height * 2)))
                    .frame(width: size.width, height: size.height)
                    .overlay { WatchBadge(item: shown) }
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .focusRing()
                VStack(alignment: .leading, spacing: 2) {
                    FocusText(text: item.type == .episode ? item.grandparentTitle ?? item.title : item.title, size: 26)
                    if item.type == .episode {
                        FocusText(text: [item.episodeCode, item.title].compactMap { $0 }.joined(separator: " · "), size: 21, secondary: true)
                    } else if let y = item.year {
                        FocusText(text: String(y), size: 21, secondary: true)
                    }
                }
                .frame(width: size.width, alignment: .leading)
            }
        }
        .buttonStyle(FocusScaleStyle())
        .focusEffectDisabled()
    }
}

/// One entry in the menu that opens when you press and hold a poster.
struct ShelfAction: Identifiable {
    let title: String
    let systemImage: String
    var destructive = false
    let run: () -> Void
    var id: String { title }
}

private struct ActionsMenu: ViewModifier {
    let actions: [ShelfAction]
    func body(content: Content) -> some View {
        if actions.isEmpty {
            content
        } else {
            content.contextMenu {
                ForEach(actions) { a in
                    Button(role: a.destructive ? .destructive : nil, action: a.run) { Label(a.title, systemImage: a.systemImage) }
                }
            }
        }
    }
}

struct Shelf: View {
    let title: String
    let items: [PlexItem]
    var landscape = false
    /// When given, pressing and holding a poster opens a menu with these actions.
    var actions: ((PlexItem) -> [ShelfAction])?

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.title3.bold()).padding(.horizontal, 80)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 40) {
                        ForEach(items) { item in
                            PosterCard(item: item, landscape: landscape)
                                .modifier(ActionsMenu(actions: actions?(item) ?? []))
                        }
                    }
                    .padding(.horizontal, 80).padding(.vertical, 30)
                }
            }
        }
    }
}

struct MessageView: View {
    let title: String
    var detail: String?
    var systemImage = "exclamationmark.triangle"
    /// When given, a "Try Again" button is shown.
    var retry: (() -> Void)?

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: systemImage).font(.system(size: 60)).foregroundStyle(.secondary)
            Text(title).font(.title2)
            if let detail { Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center) }
            if let retry { Button("Try Again", action: retry).padding(.top, 8) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(80)
    }
}

/// Where a tapped item goes.
struct ItemDestination: View {
    let item: PlexItem
    var body: some View {
        switch item.type {
        case .movie, .episode: MediaDetailView(item: item)
        case .show: ShowDetailView(item: item)
        case .season: SeasonView(season: item)
        case .other: MessageView(title: item.title)
        }
    }
}
