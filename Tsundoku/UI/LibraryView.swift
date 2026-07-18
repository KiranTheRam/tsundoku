import SwiftData
import SwiftUI

enum LibraryCatalogScope: String, CaseIterable, Identifiable {
    case series, collections, readLists
    var id: String { rawValue }
    var title: String { self == .readLists ? "Readlists" : rawValue.capitalized }
}

struct LibraryView: View {

    @Environment(AppState.self) private var appState
    @State private var libraries: [Library] = []
    @State private var selectedLibrary: String?
    @State private var items: [Series] = []
    @State private var page = 0
    @State private var isLast = false
    @State private var isLoading = false
    @State private var activeLoadID: UUID?
    @State private var errorMessage: String?
    @Binding private var scope: LibraryCatalogScope
    private let showsCatalogPicker: Bool
    @State private var configuredServerID: String?
    @State private var isRefreshingFromServer = false

    init(scope: Binding<LibraryCatalogScope>, showsCatalogPicker: Bool = true) {
        _scope = scope
        self.showsCatalogPicker = showsCatalogPicker
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 0) {
                librarySelector
                libraryContent
            }
        }
        .navigationTitle("Library")
        .toolbar {
            if showsCatalogPicker {
                ToolbarItem(placement: .principal) {
                    Picker("Catalog", selection: $scope) {
                        ForEach(LibraryCatalogScope.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 360)
                }
            }
        }
        .refreshable { await refreshFromServer() }
        .task(id: libraryLoadTaskID) { await loadLibraries() }
        .task(id: catalogTaskID) { if scope == .series { await reload() } }
    }

    private var librarySelector: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("\(appState.activeProfile?.kind.title ?? "Server") Library", systemImage: "books.vertical.fill")
                    .font(.headline)
                Spacer()
                Text(selectedLibraryName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    Task { await refreshFromServer() }
                } label: {
                    if isRefreshingFromServer {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(isRefreshingFromServer || appState.activeClient == nil)
                .accessibilityLabel("Refresh from server")
                .accessibilityHint("Reloads the catalog and fetches current cover artwork")
                .accessibilityIdentifier("library.refreshFromServer")
            }
            .padding(.horizontal)

            if isServerWideScope {
                Label(
                    "Kavita collections and reading lists span all libraries.",
                    systemImage: "info.circle"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.bottom, 12)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        libraryButton(title: "All Libraries", id: nil)
                        ForEach(libraries.filter { !$0.unavailable }) { library in
                            libraryButton(title: library.name, id: library.id)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 12)
                }
            }
        }
        .padding(.top, 10)
        .background(.bar)
    }

    private func libraryButton(title: String, id: String?) -> some View {
        let selected = selectedLibrary == id
        return Button {
            selectLibrary(id)
        } label: {
            HStack(spacing: 6) {
                if selected { Image(systemName: "checkmark") }
                Text(title).lineLimit(1)
            }
            .font(.subheadline.weight(selected ? .semibold : .regular))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(selected ? Color.accentColor : Color.secondary.opacity(0.12), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show \(title)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var libraryContent: some View {
        if scope == .collections {
            CollectionsCatalogView(libraryID: isServerWideScope ? nil : selectedLibrary)
        } else if scope == .readLists {
            ReadListsCatalogView(libraryID: isServerWideScope ? nil : selectedLibrary)
        } else if isLoading && items.isEmpty {
            SeriesGridSkeleton().padding()
        } else if let errorMessage, items.isEmpty {
            LoadFailureView(title: "Couldn't load the library", message: errorMessage) {
                Task { await reload() }
            }
            .frame(minHeight: 350)
        } else if items.isEmpty {
            ContentUnavailableView("No series", systemImage: "books.vertical", description: Text("This library is empty or unavailable."))
                .frame(minHeight: 350)
        } else {
            SeriesGrid(series: items, onLoadMore: isLast ? nil : { loadMore() })
                .padding()
        }
    }

    private var selectedLibraryName: String {
        if isServerWideScope { return "All Libraries" }
        guard let selectedLibrary else { return "All Libraries" }
        return libraries.first(where: { $0.id == selectedLibrary })?.name ?? "Selected Library"
    }

    private var isServerWideScope: Bool {
        guard scope != .series, let client = appState.activeClient else { return false }
        return scope == .collections
            ? !client.capabilities.collectionsAreLibraryScoped
            : !client.capabilities.readingListsAreLibraryScoped
    }

    private var catalogTaskID: String {
        "\(appState.activeProfile?.id.description ?? "none"):\(configuredServerID ?? "unconfigured"):\(appState.activeClient == nil ? "pending" : "ready"):\(scope.rawValue):\(selectedLibrary ?? "all")"
    }

    private var libraryLoadTaskID: String {
        "\(appState.activeProfile?.id.description ?? "none"):\(appState.activeClient == nil ? "pending" : "ready")"
    }

    private func loadLibraries() async {
        guard let profile = appState.activeProfile else { return }
        let serverID = profile.id.description
        if configuredServerID != serverID {
            configuredServerID = serverID
            libraries = appState.cachedLibraries(for: profile.id)
            selectedLibrary = appState.defaultLibraryID(for: profile.id)
            items = cachedSeries(libraryID: selectedLibrary)
            page = 0
            isLast = false
        }

        guard let client = appState.activeClient else { return }
        do {
            let refreshed = try await client.libraries()
            guard configuredServerID == serverID else { return }
            libraries = refreshed
            appState.cacheLibraries(refreshed, for: profile.id)
            if let selectedLibrary,
               !refreshed.contains(where: { $0.id == selectedLibrary && !$0.unavailable }) {
                selectLibrary(nil)
            }
        } catch is CancellationError {
            return
        } catch {
            if libraries.isEmpty { errorMessage = error.localizedDescription }
        }
    }

    private func reload() async {
        guard configuredServerID == appState.activeProfile?.id.description else { return }
        page = 0
        isLast = false
        let cached = cachedSeries(libraryID: selectedLibrary)
        if !cached.isEmpty || items.isEmpty { items = cached }
        await loadPage(0, replacing: true)
    }

    private func refreshFromServer() async {
        guard !isRefreshingFromServer else { return }
        isRefreshingFromServer = true
        defer { isRefreshingFromServer = false }
        await appState.refreshPosterArtwork()
        await loadLibraries()
        if scope == .series { await reload() }
    }

    private func loadMore() { guard !isLoading && !isLast else { return }; Task { await loadPage(page + 1, replacing: false) } }

    private func loadPage(_ target: Int, replacing: Bool) async {
        guard let client = appState.activeClient else { return }
        let requestedLibrary = selectedLibrary
        let loadID = UUID()
        activeLoadID = loadID
        isLoading = true
        defer {
            if activeLoadID == loadID {
                isLoading = false
                activeLoadID = nil
            }
        }
        do {
            let result = try await client.series(page: target, libraryID: requestedLibrary)
            guard requestedLibrary == selectedLibrary else { return }
            if replacing {
                items = result.content
            } else {
                let existingIDs = Set(items.map(\.id))
                items.append(contentsOf: result.content.filter { !existingIDs.contains($0.id) })
            }
            page = result.page; isLast = result.isLast
            cache(result.content)
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            guard requestedLibrary == selectedLibrary else { return }
            if items.isEmpty { items = cachedSeries(libraryID: requestedLibrary) }
            if items.isEmpty { errorMessage = error.localizedDescription }
        }
    }

    private func cache(_ values: [Series]) {
        appState.cacheSeriesForSystemIntegration(values)
    }

    private func cachedSeries(libraryID: String?) -> [Series] {
        guard let serverID = appState.activeProfile?.id.description else { return [] }
        let descriptor = FetchDescriptor<CachedSeriesRecord>(predicate: #Predicate { $0.serverID == serverID }, sortBy: [SortDescriptor(\.title)])
        let records = (try? appState.modelContainer.mainContext.fetch(descriptor)) ?? []
        return records
            .filter { libraryID == nil || $0.libraryID == libraryID }
            .compactMap { try? JSONDecoder().decode(Series.self, from: $0.payload) }
    }

    private func selectLibrary(_ libraryID: String?) {
        selectedLibrary = libraryID
        items = cachedSeries(libraryID: libraryID)
        page = 0
        isLast = false
        errorMessage = nil
    }
}
