import SwiftData
import SwiftUI

struct SeriesDetailView: View {
    @Environment(AppState.self) private var appState
    @Environment(ProgressCoordinator.self) private var progress
    @Query private var downloadRecords: [DownloadRecord]
    @State private var series: Series
    @State private var books: [Book] = []
    @State private var selectedBook: Book?
    @State private var showsTrackerLink = false
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var loadErrorMessage: String?
    @State private var trackerLinkReminder: String?
    @State private var didAttemptAutomaticResume = false
    private let preferredBookID: String?
    private let resumesReading: Bool

    init(series: Series, preferredBookID: String? = nil, resumesReading: Bool = false) {
        _series = State(initialValue: series)
        self.preferredBookID = preferredBookID
        self.resumesReading = resumesReading
    }

    var body: some View {
        List {
            Section {
                HStack(alignment: .top, spacing: 18) {
                    RemotePosterView(series: series)
                        .frame(width: 130, height: 195)
                        .clipShape(.rect(cornerRadius: 14))
                    VStack(alignment: .leading, spacing: 10) {
                        Text(series.title).displayHeader()
                        if !series.status.isEmpty { Label(series.status.capitalized, systemImage: "books.vertical") }
                        Text("\(series.booksReadCount) of \(series.booksCount) books read")
                            .foregroundStyle(.secondary)
                        ProgressView(value: series.progress)
                        if !series.genres.isEmpty {
                            Text(series.genres.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if !series.summary.isEmpty { Text(series.summary) }
            }

            Section("Books") {
                if isLoading && books.isEmpty { ProgressView().frame(maxWidth: .infinity) }
                if let loadErrorMessage, books.isEmpty, !isLoading {
                    LoadFailureView(title: "Couldn't load books", message: loadErrorMessage) {
                        Task { await load() }
                    }
                    .listRowSeparator(.hidden)
                }
                ForEach(books) { book in
                    HStack(spacing: 4) {
                        Button { selectedBook = book } label: {
                            BookRow(book: book, downloadState: downloadState(for: book))
                        }
                        .buttonStyle(.plain)

                        Menu {
                            bookActions(book)
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.title3)
                                .frame(width: 44, height: 44)
                                .contentShape(.rect)
                        }
                        .accessibilityLabel("Actions for \(book.displayTitle)")
                        .accessibilityIdentifier("book.actions.\(book.key.remoteID)")
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        if book.completed || book.readPage != nil {
                            Button { Task { await markUnread(book) } } label: { Label("Mark unread", systemImage: "circle") }
                                .tint(.orange)
                        } else {
                            Button { Task { await markRead(book) } } label: { Label("Mark read", systemImage: "checkmark.circle") }
                                .tint(.green)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button { Task { await download(book) } } label: { Label("Download", systemImage: "arrow.down.circle") }
                            .tint(.blue)
                    }
                    .contextMenu {
                        bookActions(book)
                    }
                }
            }
        }
        .navigationTitle(series.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    appState.setPinned(!appState.isPinned(series), series: series)
                } label: {
                    Image(systemName: appState.isPinned(series) ? "pin.fill" : "pin")
                }
                .accessibilityLabel(appState.isPinned(series) ? "Unpin series" : "Pin series")
                .accessibilityIdentifier("series.togglePin")

                Menu {
                    if series.libraryContentType != .other {
                        Button("Tracker settings", systemImage: "link") { showsTrackerLink = true }
                    }
                    Button("Download unread books", systemImage: "arrow.down.circle") {
                        Task { for book in books where !book.completed { await download(book) } }
                    }
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await load() } }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .task { await load() }
        .fullScreenCover(item: $selectedBook, onDismiss: {
            Task { await load() }
        }) { book in
            if book.contentKind == .epub {
                EPUBReaderScreen(book: book, seriesTitle: series.title)
            } else {
                ReaderScreen(
                    book: book,
                    seriesTitle: series.title,
                    seriesReadingDirection: series.readingDirection,
                    seriesTags: series.tags
                )
            }
        }
        .sheet(isPresented: $showsTrackerLink) { TrackerLinkView(series: series) }
        .alert("Series error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "Unknown error") }
        .alert("Tracker link required", isPresented: Binding(
            get: { trackerLinkReminder != nil },
            set: { if !$0 { trackerLinkReminder = nil } }
        )) {
            Button("Configure") { showsTrackerLink = true }
            Button("Later", role: .cancel) {}
        } message: {
            Text(trackerLinkReminder ?? "")
        }
    }

    private func load() async {
        loadCachedBooks()
        guard let client = appState.activeClient else { return }
        isLoading = books.isEmpty
        do {
            async let refreshed = client.series(id: series.key.remoteID)
            async let page = client.books(seriesID: series.key.remoteID)
            series = try await refreshed
            books = SeriesBookOrdering.sorted(try await page.content)
            cacheBooks()
            cacheSeries()
            resumeIfRequested()
            if books.contains(where: { $0.completed || $0.readPage != nil }) {
                switch await appState.trackers.prepareAutomaticTracking(for: series) {
                case .noAction:
                    break
                case .needsManualConfiguration(let services):
                    let names = services.map(\.title).joined(separator: " and ")
                    trackerLinkReminder = "Tsundoku couldn't confidently match \(series.title) on \(names). Configure the tracker match now, or choose Later and use Tracker Settings whenever you're ready."
                }
            }
            await appState.trackers.syncLinkedProgress(for: series)
            loadErrorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            if books.isEmpty { loadErrorMessage = error.localizedDescription }
        }
        isLoading = false
    }

    private func resumeIfRequested() {
        guard resumesReading, !didAttemptAutomaticResume else { return }
        didAttemptAutomaticResume = true
        if let preferredBookID,
           let preferred = books.first(where: { $0.key.remoteID == preferredBookID }) {
            selectedBook = preferred
            return
        }
        selectedBook = books
            .filter { !$0.completed && $0.readPage != nil }
            .max {
                ($0.readProgressModifiedAt ?? .distantPast) < ($1.readProgressModifiedAt ?? .distantPast)
            }
    }

    private func download(_ book: Book) async {
        guard let client = appState.activeClient else { return }
        do {
            let pages = book.contentKind == .epub ? [] : try await client.pages(book: book)
            try await appState.downloads.start(
                book: book,
                pages: pages,
                seriesTitle: series.title,
                seriesReadingDirection: series.readingDirection,
                seriesTags: series.tags,
                client: client
            )
        } catch { errorMessage = error.localizedDescription }
    }

    private func downloadState(for book: Book) -> DownloadState? {
        downloadRecords.first { $0.id == book.id }?.state
    }

    private func markRead(_ book: Book) async {
        guard let client = appState.activeClient else { return }
        if await progress.setReadStatus(book: book, read: true, client: client) {
            appState.clearReadingProgress(for: book)
            await load()
        }
    }

    private func markUnread(_ book: Book) async {
        guard let client = appState.activeClient else { return }
        if await progress.setReadStatus(book: book, read: false, client: client) {
            appState.clearReadingProgress(for: book)
            await load()
        }
    }

    @ViewBuilder private func bookActions(_ book: Book) -> some View {
        Button("Mark read", systemImage: "checkmark.circle") { Task { await markRead(book) } }
        Button("Mark unread", systemImage: "circle") { Task { await markUnread(book) } }
        Divider()
        Button("Download", systemImage: "arrow.down.circle") { Task { await download(book) } }
    }

    private func cacheBooks() {
        let context = appState.modelContainer.mainContext
        for book in books {
            let id = book.id
            let descriptor = FetchDescriptor<CachedBookRecord>(predicate: #Predicate { $0.id == id })
            if let record = try? context.fetch(descriptor).first {
                record.payload = (try? JSONEncoder().encode(book)) ?? record.payload
                record.cachedAt = .now
            } else { context.insert(CachedBookRecord(book: book)) }
        }
        try? context.save()
    }

    private func cacheSeries() {
        appState.cacheSeriesForSystemIntegration([series])
    }

    private func loadCachedBooks() {
        let serverID = series.key.serverID.description
        let seriesID = series.key.remoteID
        let descriptor = FetchDescriptor<CachedBookRecord>(predicate: #Predicate { $0.serverID == serverID && $0.seriesID == seriesID })
        books = ((try? appState.modelContainer.mainContext.fetch(descriptor)) ?? [])
            .compactMap { try? JSONDecoder().decode(Book.self, from: $0.payload) }
        books = SeriesBookOrdering.sorted(books)
    }
}

enum SeriesBookOrdering {
    static func sorted(_ books: [Book]) -> [Book] {
        books.sorted { lhs, rhs in
            if lhs.numberSort != rhs.numberSort { return lhs.numberSort < rhs.numberSort }
            let numberOrder = lhs.number.localizedStandardCompare(rhs.number)
            if numberOrder != .orderedSame { return numberOrder == .orderedAscending }
            let titleOrder = lhs.displayTitle.localizedStandardCompare(rhs.displayTitle)
            if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
            return lhs.key.remoteID.localizedStandardCompare(rhs.key.remoteID) == .orderedAscending
        }
    }
}

private struct BookRow: View {
    let book: Book
    let downloadState: DownloadState?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: book.completed ? "checkmark.circle.fill" : book.readPage == nil ? "circle" : "circle.lefthalf.filled")
                .foregroundStyle(book.completed ? .green : .secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(book.displayTitle).foregroundStyle(.primary)
                HStack {
                    if book.number.caseInsensitiveCompare(book.displayTitle) != .orderedSame {
                        Text("#\(book.number)")
                    }
                    Text("\(book.pageCount) \(book.contentKind == .epub ? "spines" : "pages")")
                    Text(ByteCountFormatter.string(fromByteCount: book.sizeBytes, countStyle: .file))
                }
                .font(.caption).foregroundStyle(.secondary)
                if let page = book.readPage, !book.completed {
                    ProgressView(value: Double(page), total: Double(max(1, book.pageCount)))
                }
            }
            Spacer()
            BookDownloadIndicator(state: downloadState)
        }
        .contentShape(.rect)
        .padding(.vertical, 3)
    }
}

private struct BookDownloadIndicator: View {
    let state: DownloadState?

    @ViewBuilder var body: some View {
        switch state {
        case .complete:
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(.tint)
                .accessibilityLabel("Downloaded")
        case .queued, .downloading:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Downloading")
        case .paused:
            Image(systemName: "pause.circle.fill")
                .foregroundStyle(.orange)
                .accessibilityLabel("Download paused")
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .accessibilityLabel("Download failed")
        case nil:
            EmptyView()
        }
    }
}
