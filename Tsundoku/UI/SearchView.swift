import SwiftUI

struct SearchView: View {
    @Environment(AppState.self) private var appState
    let activationID: Int
    let requestedQuery: String?
    @State private var query = ""
    @State private var results: [Series] = []
    @State private var isSearching = false
    @State private var isSearchPresented = false
    @State private var errorMessage: String?
    @FocusState private var isSearchFocused: Bool

    init(activationID: Int = 0, requestedQuery: String? = nil) {
        self.activationID = activationID
        self.requestedQuery = requestedQuery
    }

    var body: some View {
        ScrollView {
            if query.isEmpty {
                ContentUnavailableView("Search Tsundoku", systemImage: "magnifyingglass", description: Text("Search titles and metadata across the active server."))
                    .frame(minHeight: 400)
            } else if isSearching {
                SeriesGridSkeleton().padding()
            } else if let errorMessage {
                LoadFailureView(title: "Search failed", message: errorMessage) {
                    Task { await search() }
                }
                .frame(minHeight: 400)
            } else if results.isEmpty {
                ContentUnavailableView.search(text: query).frame(minHeight: 400)
            } else {
                SeriesGrid(series: results, onLoadMore: nil).padding()
            }
        }
        .navigationTitle("Search")
        .searchable(
            text: $query,
            isPresented: $isSearchPresented,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search your library"
        )
        .searchFocused($isSearchFocused)
        .task(id: activationID) {
            if let requestedQuery { query = requestedQuery }
            await Task.yield()
            isSearchPresented = true
            isSearchFocused = true
        }
        .task(id: query) {
            guard !query.isEmpty else { results = []; errorMessage = nil; return }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await search()
        }
    }

    private func search() async {
        guard let client = appState.activeClient else { return }
        isSearching = true
        errorMessage = nil
        do {
            results = try await client.series(pageSize: 100, search: query).content
            appState.cacheSeriesForSystemIntegration(results)
        }
        catch is CancellationError { return }
        catch { errorMessage = error.localizedDescription }
        isSearching = false
    }
}
