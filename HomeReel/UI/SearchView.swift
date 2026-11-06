import SwiftUI

struct SearchView: View {
    @EnvironmentObject var app: AppModel
    @State private var text: String
    init(initialText: String = "") { _text = State(initialValue: initialText) }
    @State private var movies: [PlexItem] = []
    @State private var shows: [PlexItem] = []
    @State private var searched = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let error {
                    MessageView(title: "Search failed", detail: error, retry: { Task { await runSearch(text.trimmingCharacters(in: .whitespaces)) } })
                } else if searched && movies.isEmpty && shows.isEmpty {
                    MessageView(title: "No results for \"\(text)\"", systemImage: "magnifyingglass")
                } else if !searched {
                    MessageView(title: "Search your movies and TV shows", detail: "Use the keyboard or dictate with the Siri Remote.", systemImage: "magnifyingglass")
                } else {
                    Shelf(title: "Movies", items: movies)
                    Shelf(title: "TV Shows", items: shows)
                }
            }
        }
        .searchable(text: $text, prompt: "Movies and TV Shows")
        .task(id: text) {
            let q = text.trimmingCharacters(in: .whitespaces)
            guard q.count >= 2 else { searched = false; error = nil; movies = []; shows = []; return }
            try? await Task.sleep(for: .milliseconds(350))      // wait for typing to pause
            guard !Task.isCancelled else { return }
            await runSearch(q)
        }
    }

    private func runSearch(_ q: String) async {
        guard let c = app.client else { return }
        do {
            let keys = Set((app.movieLibraries + app.showLibraries).map(\.key))
            let r = try await c.search(q, inSections: keys)
            movies = r.movies
            shows = r.shows
            error = nil
        } catch is CancellationError {
            return
        } catch { self.error = error.localizedDescription }
        searched = true
    }
}
