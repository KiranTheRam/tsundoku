import SwiftData
import SwiftUI

struct ReaderScreen: View {
    @Environment(AppState.self) private var appState
    @Environment(ProgressCoordinator.self) private var progress
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let seriesTitle: String
    let seriesReadingDirection: String
    let seriesTags: [String]
    let opensDownloadedPackage: Bool

    @State private var book: Book
    @State private var pages: [BookPage] = []
    @State private var displayUnits: [ReaderDisplayUnit] = []
    @State private var isLandscape = false
    @State private var currentPage = 0
    @State private var preferences = ReaderPreferences()
    @State private var showsChrome = true
    @State private var showsSettings = false
    @State private var errorMessage: String?
    @State private var loader = PageLoader()
    @State private var navigationRequestID = 0
    @State private var didRestorePreferences = false
    @State private var isScrubbing = false
    @State private var bookmarkFeedbackTrigger = 0
    @State private var adjacentBookFeedbackTrigger = 0
    @State private var lastStatisticsPosition: Int?

    init(
        book: Book,
        seriesTitle: String,
        seriesReadingDirection: String,
        seriesTags: [String],
        opensDownloadedPackage: Bool = false
    ) {
        _book = State(initialValue: book)
        self.seriesTitle = seriesTitle
        self.seriesReadingDirection = seriesReadingDirection
        self.seriesTags = seriesTags
        self.opensDownloadedPackage = opensDownloadedPackage
    }

    var body: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height
            ZStack {
                Color.black.ignoresSafeArea()
                if !pages.isEmpty {
                    ReaderHost(
                        units: displayUnits,
                        pages: pages,
                        book: book,
                        client: matchingClient,
                        loader: loader,
                        preferences: preferences,
                        initialPage: currentPage,
                        navigationRequestID: navigationRequestID,
                        onPageChanged: visiblePageChanged,
                        onPageSettled: pageSettled,
                        onToggleChrome: { withAnimation(.snappy) { showsChrome.toggle() } }
                    )
                    .id("\(book.id)-\(preferences.mode.rawValue)-\(preferences.spreadMode.rawValue)-\(landscape)")
                    .zIndex(0)
                } else {
                    ProgressView().tint(.white)
                }
                Color.black.opacity(max(0, 1 - preferences.brightness) * 0.8)
                    .allowsHitTesting(false)
                    .ignoresSafeArea()
                    .zIndex(1)
                if showsChrome {
                    readerChrome
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                        .zIndex(10)
                }
            }
            .onAppear { updateLayout(for: geometry.size) }
            .onChange(of: geometry.size) { _, size in updateLayout(for: size) }
        }
        .statusBarHidden(!preferences.showsStatusBar)
        .persistentSystemOverlays(showsChrome ? .automatic : .hidden)
        .task {
            restorePreferences()
            await load()
        }
        .onChange(of: preferences) { _, updated in
            guard didRestorePreferences else { return }
            appState.setReaderPreferences(updated)
            rebuildDisplayUnits()
        }
        .onDisappear {
            appState.setReaderPreferences(preferences)
            flushCurrentPage()
        }
        .overlay(alignment: .top) {
            if let notice = progress.syncNotice {
                ProgressSyncToast(notice: notice)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.3), value: progress.syncNotice)
        .sensoryFeedback(.selection, trigger: currentPage) { _, _ in isScrubbing }
        .sensoryFeedback(.impact(weight: .light), trigger: bookmarkFeedbackTrigger) { old, new in new > old }
        .sensoryFeedback(.impact(weight: .medium), trigger: adjacentBookFeedbackTrigger) { old, new in new > old }
        .sheet(isPresented: $showsSettings) { ReaderSettingsView(preferences: $preferences) }
        .alert("Reader error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) { Button("Close") { dismiss() } } message: { Text(errorMessage ?? "") }
    }

    private var readerChrome: some View {
        let topControlSize = ReaderChromeMetrics.topControlSize(
            isRegularWidth: horizontalSizeClass == .regular
        )

        return VStack {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .frame(width: topControlSize, height: topControlSize)
                        .contentShape(.rect)
                }
                .accessibilityLabel("Close reader")
                .accessibilityIdentifier("reader.close")

                VStack(alignment: .leading, spacing: 2) {
                    Text(seriesTitle).font(.headline).lineLimit(1)
                    Text(book.displayTitle).font(.caption).lineLimit(1)
                }
                .layoutPriority(1)
                Spacer()
                Button { toggleBookmark() } label: {
                    Image(systemName: isCurrentPageBookmarked ? "bookmark.fill" : "bookmark")
                        .frame(width: topControlSize, height: topControlSize)
                        .contentShape(.rect)
                }
                .accessibilityLabel(isCurrentPageBookmarked ? "Remove bookmark" : "Add bookmark")
                .accessibilityIdentifier("reader.bookmark")

                Menu {
                    Button("Reader settings", systemImage: "gearshape") { showsSettings = true }
                        .accessibilityIdentifier("reader.settings")
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .frame(width: topControlSize, height: topControlSize)
                        .contentShape(.rect)
                }
                .accessibilityLabel("Reader options")
                .accessibilityIdentifier("reader.readerOptions")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .readerChromePanel()
            .padding(.horizontal)
            .padding(.top, 8)
            Spacer()
            VStack(spacing: ReaderChromeMetrics.bottomPanelSpacing) {
                if let sliderRange = ReaderChromeMetrics.pageSliderRange(pageCount: pages.count) {
                    Slider(
                        value: Binding(get: { Double(currentPage) }, set: { currentPage = Int($0) }),
                        in: sliderRange,
                        step: 1,
                        onEditingChanged: { isEditing in
                            isScrubbing = isEditing
                            if !isEditing {
                                lastStatisticsPosition = currentPage + 1
                                navigationRequestID &+= 1
                            }
                        }
                    )
                } else if pages.isEmpty {
                    ProgressView()
                        .tint(.white)
                }
                HStack {
                    Button { Task { await moveToAdjacent(next: false) } } label: {
                        Label("Previous book", systemImage: "backward.end")
                            .labelStyle(.iconOnly)
                            .frame(width: 44, height: 44)
                            .contentShape(.rect)
                    }
                    .accessibilityIdentifier("reader.previousBook")
                    .disabled(opensDownloadedPackage || matchingClient == nil)

                    Spacer()
                    VStack(spacing: 2) {
                        Text(pages.isEmpty ? "Loading pages…" : "Page \(currentPage + 1) of \(pages.count)")
                        Text(preferences.mode.title).foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    Spacer()

                    Button { Task { await moveToAdjacent(next: true) } } label: {
                        Label("Next book", systemImage: "forward.end")
                            .labelStyle(.iconOnly)
                            .frame(width: 44, height: 44)
                            .contentShape(.rect)
                    }
                    .accessibilityIdentifier("reader.nextBook")
                    .disabled(opensDownloadedPackage || matchingClient == nil)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, ReaderChromeMetrics.bottomPanelHorizontalPadding)
            .padding(.vertical, ReaderChromeMetrics.bottomPanelVerticalPadding)
            .readerChromePanel()
            .padding(.horizontal)
            .padding(.bottom, ReaderChromeMetrics.bottomPanelOuterPadding)
        }
        .foregroundStyle(.white)
    }

    private func load() async {
        if let downloadedPages = DownloadPaths.imageManifest(for: book.key) {
            pages = downloadedPages
            rebuildDisplayUnits()
            restorePosition(for: book)
        }
        if opensDownloadedPackage {
            if pages.isEmpty {
                errorMessage = "The downloaded package is incomplete or unavailable."
            }
            return
        }
        guard let client = matchingClient else {
            if pages.isEmpty { errorMessage = "This book is not available offline." }
            return
        }
        do {
            async let loadedPages = client.pages(book: book)
            async let refreshedBook = client.book(id: book.key.remoteID)
            let (remotePages, remoteBook) = try await (loadedPages, refreshedBook)
            pages = remotePages
            book = remoteBook
            rebuildDisplayUnits()
            restorePosition(for: remoteBook)
        } catch {
            if pages.isEmpty { errorMessage = error.localizedDescription }
        }
    }

    private func restorePosition(for sourceBook: Book) {
        let pending = progress.pendingCheckpoint(for: sourceBook.key)
        currentPage = ReaderResumePosition.zeroBasedPage(
            remoteOneBasedPage: sourceBook.readPage,
            remoteModifiedAt: sourceBook.readProgressModifiedAt,
            pendingOneBasedPage: pending?.page,
            pendingObservedAt: pending?.observedAt,
            historyOneBasedPage: localHistory?.page,
            pageCount: pages.count
        )
        lastStatisticsPosition = currentPage + 1
    }

    private func restorePreferences() {
        guard !didRestorePreferences else { return }
        if let saved = appState.readerPreferences() {
            preferences = saved
        } else {
            preferences.mode = defaultMode
            appState.setReaderPreferences(preferences)
        }
        didRestorePreferences = true
    }

    private func moveToAdjacent(next: Bool) async {
        guard !opensDownloadedPackage, let client = matchingClient else { return }
        flushCurrentPage(noticePolicy: .silent, beginBackgroundExecution: false)
        do {
            book = try await client.adjacentBook(from: book, next: next)
            pages = []
            currentPage = 0
            adjacentBookFeedbackTrigger &+= 1
            await load()
        } catch {
            errorMessage = next ? "There is no next book in this series." : "There is no previous book in this series."
        }
    }

    private var defaultMode: ReaderMode {
        let tags = seriesTags.map { $0.lowercased() }
        if tags.contains(where: { $0.contains("webtoon") || $0.contains("long strip") }) { return .verticalContinuous }
        switch seriesReadingDirection.lowercased() {
        case "left_to_right", "ltr": return .pagedLeftToRight
        case "vertical": return .verticalContinuous
        default: return .pagedRightToLeft
        }
    }

    private func visiblePageChanged(_ page: Int) {
        currentPage = page
    }

    private func pageSettled(_ page: Int) {
        currentPage = page
        let position = page + 1
        if let previous = lastStatisticsPosition {
            appState.recordReadingAdvance(
                book: book,
                seriesTitle: seriesTitle,
                from: previous,
                to: position
            )
        }
        lastStatisticsPosition = position
        let checkpoint = ReadingCheckpoint(book: book, zeroBasedPage: page, pageCount: pages.count, completed: page == pages.count - 1)
        if let client = matchingClient {
            progress.record(checkpoint, client: client, immediate: checkpoint.completed, noticePolicy: .silent)
        } else {
            progress.recordOffline(checkpoint)
        }
        recordHistory(page: page + 1)
    }

    private func flushCurrentPage(
        noticePolicy: ProgressNoticePolicy = .afterReaderExit,
        beginBackgroundExecution: Bool = true
    ) {
        guard !pages.isEmpty else { return }
        let checkpoint = ReadingCheckpoint(book: book, zeroBasedPage: currentPage, pageCount: pages.count)
        if let client = matchingClient {
            progress.record(checkpoint, client: client, immediate: true, noticePolicy: noticePolicy)
            if beginBackgroundExecution { progress.beginBackgroundFlush(client: client) }
        } else {
            progress.recordOffline(checkpoint)
        }
        recordHistory(page: checkpoint.page)
    }

    private func updateLayout(for size: CGSize) {
        let landscape = size.width > size.height
        guard landscape != isLandscape || displayUnits.isEmpty else { return }
        isLandscape = landscape
        rebuildDisplayUnits()
    }

    private func rebuildDisplayUnits() {
        displayUnits = ReaderPagePlanner.units(
            pages: pages,
            preferences: preferences,
            landscape: isLandscape
        )
    }

    private var localHistory: HistoryRecord? {
        let bookID = book.key.remoteID
        let serverID = book.key.serverID.description
        let descriptor = FetchDescriptor<HistoryRecord>(
            predicate: #Predicate { $0.bookID == bookID && $0.serverID == serverID },
            sortBy: [SortDescriptor(\.readAt, order: .reverse)]
        )
        return try? modelContext.fetch(descriptor).first
    }

    private func recordHistory(page: Int) {
        appState.recordHistory(book: book, seriesTitle: seriesTitle, page: page)
    }

    private var matchingClient: ServerClient? {
        guard appState.activeClient?.profile.id == book.key.serverID else { return nil }
        return appState.activeClient
    }

    private var isCurrentPageBookmarked: Bool {
        let id = PageKey(book: book.key, index: currentPage).id
        let descriptor = FetchDescriptor<BookmarkRecord>(predicate: #Predicate { $0.id == id })
        return ((try? modelContext.fetchCount(descriptor)) ?? 0) > 0
    }

    private func toggleBookmark() {
        let key = PageKey(book: book.key, index: currentPage)
        let id = key.id
        let descriptor = FetchDescriptor<BookmarkRecord>(predicate: #Predicate { $0.id == id })
        if let existing = try? modelContext.fetch(descriptor).first { modelContext.delete(existing) }
        else { modelContext.insert(BookmarkRecord(key: key, title: "\(seriesTitle) · \(book.displayTitle)")) }
        try? modelContext.save()
        bookmarkFeedbackTrigger &+= 1
    }
}

extension View {
    func readerChromePanel() -> some View {
        background {
            RoundedRectangle(cornerRadius: DesignTokens.readerPanelCornerRadius, style: .continuous)
                .fill(.black.opacity(DesignTokens.readerPanelFillOpacity))
                .overlay {
                    RoundedRectangle(cornerRadius: DesignTokens.readerPanelCornerRadius, style: .continuous)
                        .stroke(.white.opacity(DesignTokens.readerHairlineOpacity), lineWidth: 1)
                }
                .shadow(
                    color: .black.opacity(DesignTokens.readerShadowOpacity),
                    radius: DesignTokens.floatingShadowRadius,
                    y: DesignTokens.floatingShadowYOffset
                )
                // The reader owns full-screen edge-tap gestures. Make the
                // complete panel interactive so a near-miss around a control
                // cannot fall through and turn a page.
                .onTapGesture { }
        }
    }
}

enum ReaderChromeMetrics {
    static let bottomPanelSpacing: CGFloat = 6
    static let bottomPanelHorizontalPadding: CGFloat = 12
    static let bottomPanelVerticalPadding: CGFloat = 8
    static let bottomPanelOuterPadding: CGFloat = 6

    static func topControlSize(isRegularWidth: Bool) -> CGFloat {
        isRegularWidth ? 56 : 44
    }

    static func pageSliderRange(pageCount: Int) -> ClosedRange<Double>? {
        guard pageCount > 1 else { return nil }
        return 0...Double(pageCount - 1)
    }
}

enum ReaderResumePosition {
    static func zeroBasedPage(
        remoteOneBasedPage: Int?,
        remoteModifiedAt: Date?,
        pendingOneBasedPage: Int?,
        pendingObservedAt: Date?,
        historyOneBasedPage: Int?,
        pageCount: Int
    ) -> Int {
        guard pageCount > 0 else { return 0 }
        let pendingIsNewer = pendingOneBasedPage != nil && {
            guard let remoteModifiedAt else { return true }
            guard let pendingObservedAt else { return false }
            return pendingObservedAt > remoteModifiedAt
        }()
        let oneBasedPage: Int
        if pendingIsNewer {
            oneBasedPage = pendingOneBasedPage ?? 1
        } else if let remoteOneBasedPage {
            // A live content-server checkpoint is authoritative across devices. CloudKit
            // history is metadata/offline fallback and never wins by page number.
            oneBasedPage = remoteOneBasedPage
        } else {
            oneBasedPage = pendingOneBasedPage ?? historyOneBasedPage ?? 1
        }
        return min(max(0, oneBasedPage - 1), pageCount - 1)
    }
}

private struct ReaderSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var preferences: ReaderPreferences

    var body: some View {
        NavigationStack {
            Form {
                Section("Layout") {
                    Picker("Mode", selection: $preferences.mode) { ForEach(ReaderMode.allCases) { Text($0.title).tag($0) } }
                    Picker("Spreads", selection: $preferences.spreadMode) { ForEach(SpreadMode.allCases) { Text($0.rawValue.capitalized).tag($0) } }
                    Picker("Wide pages", selection: $preferences.widePagePolicy) { ForEach(WidePagePolicy.allCases) { Text($0.rawValue.capitalized).tag($0) } }
                    Picker("Border crop", selection: $preferences.cropPolicy) { ForEach(CropPolicy.allCases) { Text($0.rawValue.capitalized).tag($0) } }
                    Toggle("Keep cover single", isOn: $preferences.keepsCoverSingle)
                }
                Section("Display") {
                    if preferences.mode == .verticalContinuous {
                        LabeledContent("Page gap", value: "\(Int(preferences.pageGap)) pt")
                        Slider(value: $preferences.pageGap, in: 0...32, step: 1) { Text("Page gap") }
                    }
                    LabeledContent("Brightness", value: preferences.brightness.formatted(.percent.precision(.fractionLength(0))))
                    Slider(value: $preferences.brightness, in: 0.15...1) { Text("Brightness") }
                    Toggle("Show status bar", isOn: $preferences.showsStatusBar)
                }
            }
            .navigationTitle("Reader")
            .toolbar { Button("Done") { dismiss() } }
        }
        .presentationDetents([.medium, .large])
    }
}
