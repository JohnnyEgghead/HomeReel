import SwiftUI

enum LibraryKind { case movies, shows }

@MainActor
final class LibraryModel: ObservableObject {
    @Published var items: [PlexItem] = []
    @Published var total = 0
    @Published var loading = false
    @Published var error: String?
    @Published var sort: PlexSort = .title { didSet { if oldValue != sort { Task { await reload() } } } }
    @Published var unwatchedOnly = false { didSet { if oldValue != unwatchedOnly { Task { await reload() } } } }

    /// Where a library scan stands, for the button and the line beside it.
    enum ScanState: Equatable { case idle, scanning, finished, stillRunning, failed(String) }
    @Published private(set) var scan: ScanState = .idle
    /// How often to ask the server whether the scan is done. Short in test runs.
    var scanPollInterval: Duration = LaunchOptions.value("-fixture") != nil ? .milliseconds(300) : .seconds(2)
    /// How many times to ask before giving up on waiting (10 minutes at the normal interval).
    var maxScanPolls = 300
    /// Items the server listed that could not be read, so the list says it is not showing everything.
    @Published private(set) var dropped = 0

    private var client: PlexClient?
    private var section: PlexSection?
    private let pageSize = 60
    /// Where the next page starts on the server. Not `items.count`: an odd item can be skipped when decoding.
    private var nextStart = 0

    func configure(client: PlexClient?, section: PlexSection?) async {
        guard self.section?.key != section?.key || items.isEmpty else { return }
        self.client = client
        self.section = section
        await reload()
    }

    /// Goes up with every reload. A page that was asked for under an older number is out of date (the sort, the
    /// filter, or the library changed while it was on its way), so it is dropped instead of added to the new list.
    private var generation = 0

    /// Starts the list again. A reload always asks, even when an older request is still running.
    func reload() async {
        generation += 1
        items = []
        total = 0
        nextStart = 0
        dropped = 0
        error = nil
        await fetchPage()
    }

    func loadMore() async {
        guard !loading, items.isEmpty || nextStart < total else { return }
        await fetchPage()
    }

    private func fetchPage() async {
        guard let client, let section else { return }
        let mine = generation
        loading = true
        defer { if mine == generation { loading = false } }
        do {
            let page = try await client.items(section: section, sort: sort, unwatchedOnly: unwatchedOnly, start: nextStart, size: pageSize)
            guard mine == generation else { return }
            items += page.items
            dropped += page.dropped
            total = page.total
            nextStart += pageSize
            error = nil
        } catch is CancellationError {
            return
        } catch {
            guard mine == generation else { return }
            self.error = error.localizedDescription
        }
    }

    /// Starts a scan for new files, waits for the server to finish (up to 10 minutes), then reloads the list.
    func scanForNewContent() async {
        guard let client, let section, scan != .scanning else { return }
        scan = .scanning
        do {
            try await client.scanLibrary(section)
            // The server may not report "scanning" the instant it accepts the request, so give it a few polls to start.
            var sawScanning = false, polls = 0, missed = 0, busy = false
            while polls < maxScanPolls {
                try await Task.sleep(for: scanPollInterval)
                polls += 1
                do {
                    busy = try await client.isScanning(section)
                    missed = 0
                } catch {
                    if error.isCancellation { throw error }
                    // One or two dropped answers are not the end of the scan. A third in a row is.
                    missed += 1
                    if missed > 2 { throw error }
                    continue
                }
                if busy { sawScanning = true }
                else if sawScanning || polls >= 3 { break }
            }
            await reload()
            if busy {
                scan = .stillRunning       // the wait ran out while the server was still at it
            } else {
                scan = .finished
                try? await Task.sleep(for: .seconds(5))
                if scan == .finished { scan = .idle }
            }
        } catch is CancellationError {
            scan = .idle
        } catch {
            scan = .failed(error.localizedDescription)
        }
    }

    func loadMoreIfNeeded(after item: PlexItem) async {
        guard let idx = items.firstIndex(of: item), idx >= items.count - 12 else { return }
        await loadMore()
    }
}

struct LibraryView: View {
    @EnvironmentObject var app: AppModel
    let kind: LibraryKind
    @StateObject private var model = LibraryModel()
    private enum Field: Hashable { case sort, filter, scan, item(String) }
    @FocusState private var focus: Field?
    @Namespace private var focusScope
    /// The item at the top of the screen as you scroll. Drives the highlighted letter.
    @State private var topID: String?

    /// The letter of the poster you are on. If focus is elsewhere (the Sort button), the first poster on screen.
    /// Screen is 1920 x 1080 points. Posters end at x = 1750, so the margin is 1750...1920.
    private static let stripCenterX: CGFloat = 1835
    private static let stripCenterY: CGFloat = 590

    private var currentLetter: String {
        if case .item(let id) = focus, let item = model.items.first(where: { $0.id == id }) { return AlphaIndex.letter(for: item) }
        let item = model.items.first { $0.id == topID } ?? model.items.first
        return item.map(AlphaIndex.letter(for:)) ?? "#"
    }

    /// A short note beside the Scan button: what is happening, or how it ended.
    @ViewBuilder private var scanStatus: some View {
        switch model.scan {
        case .idle: EmptyView()
        case .scanning: Text("Looking for new files. This can take a few minutes.").font(.callout).foregroundStyle(Theme.secondaryText)
        case .finished: Text("Scan finished").font(.callout).foregroundStyle(Theme.secondaryText)
        case .stillRunning: Text("The server is still scanning. New titles will appear when it finishes.").font(.callout).foregroundStyle(Theme.secondaryText)
        case .failed(let m): Text("Scan failed: \(m)").font(.callout).foregroundStyle(.orange)
        }
    }

    private var section: PlexSection? {
        kind == .movies ? app.movieLibraries.first : app.showLibraries.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                VStack(alignment: .leading, spacing: 24) {
                    Text(kind == .movies ? "Movies" : "TV Shows").font(.largeTitle.bold())
                    // Sort and filter sit centered under the tab bar, so one press down from the tab bar
                    // reaches them (the focus engine picks the nearest control) and one more reaches the posters.
                    HStack(spacing: 30) {
                        Spacer(minLength: 0)
                        Menu {
                            Picker("Sort by", selection: $model.sort) {
                                ForEach(PlexSort.options(forShows: kind == .shows)) { Text($0.label).tag($0) }
                            }
                        } label: { Label("Sort: \(model.sort.label)", systemImage: "arrow.up.arrow.down") }
                            .focused($focus, equals: .sort)
                            .prefersDefaultFocus(true, in: focusScope)
                        Button { model.unwatchedOnly.toggle() } label: {
                            Label(model.unwatchedOnly ? "Unwatched Only" : "All", systemImage: model.unwatchedOnly ? "eye.slash" : "eye")
                        }
                        .focused($focus, equals: .filter)
                        Button { Task { await model.scanForNewContent() } } label: {
                            Label(model.scan == .scanning ? "Scanning…" : "Scan Library", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .focused($focus, equals: .scan)
                        Spacer(minLength: 0)
                    }
                    .focusSection()
                    // Its own line with a fixed height, so the buttons and posters do not move when it appears.
                    scanStatus.frame(maxWidth: .infinity, minHeight: 30)
                }
                .padding(.horizontal, 80)

                if let error = model.error, model.items.isEmpty {
                    MessageView(title: "Could not load the library", detail: error, retry: { Task { await model.reload() } })
                } else if section == nil {
                    MessageView(title: "No library found", detail: "This server has no \(kind == .movies ? "movie" : "TV show") library.", systemImage: "film")
                } else if model.items.isEmpty && !model.loading {
                    MessageView(title: model.unwatchedOnly ? "Everything is watched" : "This library is empty", systemImage: "checkmark.circle")
                } else {
                    // Six posters per row. 80 points on the left, and room on the right for the A-Z strip.
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(240), spacing: 30, alignment: .top), count: 6), alignment: .leading, spacing: 44) {
                        ForEach(model.items) { item in
                            PosterCard(item: item)
                                .focused($focus, equals: .item(item.id))
                                .task { await model.loadMoreIfNeeded(after: item) }
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.leading, 80)
                    if model.loading { ProgressView().frame(maxWidth: .infinity) }
                    if model.dropped > 0 {
                        Text("\(model.dropped) \(model.dropped == 1 ? "item" : "items") from the server could not be read, so \(model.dropped == 1 ? "it is" : "they are") not shown.")
                            .font(.callout).foregroundStyle(.orange).padding(.horizontal, 80)
                    }
                    if let error = model.error {
                        HStack(spacing: 30) {
                            Text("Could not load more: \(error)").font(.callout).foregroundStyle(.orange)
                            Button("Try Again") { Task { await model.loadMore() } }
                        }
                        .padding(.horizontal, 80)
                    }
                }
            }
        }
        .scrollPosition(id: $topID, anchor: .top)
        .overlay(alignment: .topLeading) {
            // The strip sits in the right margin, centered between the last poster column and the screen edge,
            // and clear of the bottom of the screen.
            if model.sort == .title, !model.items.isEmpty {
                AlphabetStrip(current: currentLetter)
                    .position(x: Self.stripCenterX, y: Self.stripCenterY)
                    .ignoresSafeArea()
            }
        }
        .focusScope(focusScope)
        .task(id: section?.key) { await model.configure(client: app.client, section: section) }
    }
}


/// A vertical A-Z strip down the right edge. The letter you are scrolled to is highlighted.
struct AlphabetStrip: View {
    let current: String

    var body: some View {
        VStack(spacing: 0) {
            ForEach(AlphaIndex.letters, id: \.self) { letter in
                let on = letter == current
                Text(letter)
                    .font(.system(size: 22, weight: on ? .heavy : .medium))
                    .foregroundStyle(on ? Color.black : Theme.tertiaryText)
                    .frame(width: 34, height: 29)
                    .background { if on { Circle().fill(Color.white) } }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .background(.black.opacity(0.25), in: Capsule())
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
