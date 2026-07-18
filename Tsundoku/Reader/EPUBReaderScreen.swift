import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct EPUBReaderScreen: View {
    private enum PresentedSheet: String, Identifiable {
        case tableOfContents
        case settings
        var id: String { rawValue }
    }

    @Environment(AppState.self) private var appState
    @Environment(ProgressCoordinator.self) private var progress
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let seriesTitle: String
    @State private var book: Book
    @State private var preferences = EPUBReaderPreferences()
    @State private var tableOfContents: [EPUBTableOfContentsItem] = []
    @State private var spineCount = 0
    @State private var currentSpine = 0
    @State private var currentLocator: String?
    @State private var currentPercentage = 0.0
    @State private var currentRenderedPage = 1
    @State private var renderedPageCount = 1
    @State private var currentLocationIsBookmarked = false
    @State private var preparedHTML = ""
    @State private var resourceMap: [String: String] = [:]
    @State private var offlineManifest: EPUBPackageManifest?
    @State private var showsChrome = true
    @State private var presentedSheet: PresentedSheet?
    @State private var errorMessage: String?
    @State private var loadID = 0
    @State private var didRestorePreferences = false
    @State private var pageNavigationRequest: EPUBPageNavigationRequest?
    @State private var pageNavigationSequence = 0
    @State private var loadSpineAtEnd = false
    @State private var scrubSpine: Double?
    @State private var isLoadingSpine = false
    @State private var showsSpineLoadingPill = false
    @State private var bookmarkFeedbackTrigger = 0
    @State private var adjacentBookFeedbackTrigger = 0
    @State private var lastStatisticsPosition: Int?
    @State private var spineLoadSequence = 0
    @State private var preferenceReloadTask: Task<Void, Never>?

    init(book: Book, seriesTitle: String) {
        _book = State(initialValue: book)
        self.seriesTitle = seriesTitle
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if !preparedHTML.isEmpty {
                EPUBWebView(
                    html: preparedHTML,
                    resourceMap: resourceMap,
                    book: book,
                    client: matchingClient,
                    offlineManifest: offlineManifest,
                    mode: preferences.mode,
                    documentID: loadID,
                    initialLocator: currentLocator,
                    initialAtEnd: loadSpineAtEnd,
                    navigationRequest: pageNavigationRequest,
                    onLocationChanged: locationChanged,
                    onLocationSettled: locationSettled,
                    onPageBoundary: pageBoundaryReached,
                    onToggleChrome: { withAnimation(.snappy) { showsChrome.toggle() } }
                )
                .id("\(book.id):\(currentSpine):\(loadID):\(preferences.hashValue)")
                .allowsHitTesting(!isLoadingSpine)
            } else {
                ProgressView("Preparing book…").tint(.white).foregroundStyle(.white)
            }

            if showsSpineLoadingPill {
                spineLoadingPill.zIndex(5)
            }

            if showsChrome {
                readerChrome
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    .zIndex(10)
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(showsChrome ? .automatic : .hidden)
        .task {
            restorePreferences()
            await loadBook()
        }
        .task(id: isLoadingSpine) {
            guard isLoadingSpine, !preparedHTML.isEmpty else {
                showsSpineLoadingPill = false
                return
            }
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, isLoadingSpine else { return }
            withAnimation(.snappy) { showsSpineLoadingPill = true }
        }
        .onChange(of: preferences) { _, value in
            guard didRestorePreferences else { return }
            appState.setEPUBReaderPreferences(value)
            preferenceReloadTask?.cancel()
            let locator = currentLocator
            preferenceReloadTask = Task {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                await loadSpine(locator: locator)
            }
        }
        .onDisappear {
            preferenceReloadTask?.cancel()
            spineLoadSequence &+= 1
            flushCurrentLocation()
        }
        .sensoryFeedback(.selection, trigger: scrubSectionIndex) { _, new in new != nil }
        .sensoryFeedback(.impact(weight: .light), trigger: bookmarkFeedbackTrigger) { old, new in new > old }
        .sensoryFeedback(.impact(weight: .medium), trigger: adjacentBookFeedbackTrigger) { old, new in new > old }
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .tableOfContents:
                EPUBTableOfContentsSheet(
                    items: sectionItems,
                    selectedSectionID: EPUBSectionSelection.selectedID(
                        in: sectionItems,
                        currentSpine: currentSpine,
                        currentLocator: currentLocator
                    )
                ) { item in
                    currentSpine = min(max(0, item.page), max(0, spineCount - 1))
                    currentLocator = item.part?.nilIfEmpty
                    Task { await loadSpine(locator: currentLocator) }
                }
            case .settings:
                EPUBSettingsSheet(preferences: $preferences)
            }
        }
        .alert("EPUB reader error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("Close") { dismiss() }
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
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
                .accessibilityIdentifier("epub.close")

                VStack(alignment: .leading, spacing: 2) {
                    Text(seriesTitle).font(.headline).lineLimit(1)
                    Text(book.displayTitle).font(.caption).lineLimit(1)
                }
                Spacer()
                Button { toggleBookmark() } label: {
                    Image(systemName: currentLocationIsBookmarked ? "bookmark.fill" : "bookmark")
                        .frame(width: topControlSize, height: topControlSize)
                        .contentShape(.rect)
                }
                .accessibilityLabel(currentLocationIsBookmarked ? "Remove bookmark" : "Add bookmark")
                .accessibilityIdentifier("epub.bookmark")
                Menu {
                    Button("Sections", systemImage: "list.bullet.indent") {
                        presentedSheet = .tableOfContents
                    }
                    Button("Reader settings", systemImage: "textformat.size") {
                        presentedSheet = .settings
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .frame(width: topControlSize, height: topControlSize)
                        .contentShape(.rect)
                }
                .accessibilityLabel("Reader options")
                .accessibilityIdentifier("epub.readerOptions")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .readerChromePanel()
            .padding(.horizontal)
            .padding(.top, 8)

            Spacer()

            VStack(spacing: ReaderChromeMetrics.bottomPanelSpacing) {
                if let sliderRange = ReaderChromeMetrics.pageSliderRange(pageCount: spineCount) {
                    Slider(
                        value: Binding(
                            get: { scrubSpine ?? Double(currentSpine) },
                            set: { scrubSpine = $0 }
                        ),
                        in: sliderRange,
                        step: 1,
                        onEditingChanged: { isEditing in
                            if !isEditing { commitSectionScrub() }
                        }
                    )
                    .accessibilityLabel("Section")
                    .accessibilityIdentifier("epub.sectionSlider")
                }
                HStack {
                    Button { requestPageTurn(next: false) } label: {
                        Image(systemName: "chevron.backward").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Previous page")
                    .accessibilityIdentifier("epub.previousPage")
                    Spacer()
                    VStack(spacing: 2) {
                        Text(pageAndSectionLabel)
                        Menu {
                            Picker("Reader layout", selection: $preferences.mode) {
                                ForEach(EPUBReaderMode.allCases) { mode in
                                    Text(mode.title).tag(mode)
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text("\(Int((overallPercentage * 100).rounded()))% · \(preferences.mode.title)")
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.caption2)
                            }
                            .foregroundStyle(.secondary)
                        }
                        .accessibilityLabel("Reader layout, \(preferences.mode.title)")
                    }
                    .font(.caption)
                    Spacer()
                    Button { requestPageTurn(next: true) } label: {
                        Image(systemName: "chevron.forward").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Next page")
                    .accessibilityIdentifier("epub.nextPage")
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

    private var overallPercentage: Double {
        guard spineCount > 0 else { return 0 }
        return min(1, max(0, (Double(currentSpine) + currentPercentage) / Double(spineCount)))
    }

    private var scrubSectionIndex: Int? {
        scrubSpine.map { EPUBSectionScrub.commitTarget(value: $0, spineCount: spineCount) }
    }

    private var pageAndSectionLabel: String {
        let displaySpine = scrubSectionIndex ?? currentSpine
        var label = "Page \(currentRenderedPage) of \(renderedPageCount)"
        if spineCount > 1 { label += " · Section \(displaySpine + 1) of \(spineCount)" }
        return label
    }

    private var spineLoadingPill: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small).tint(.white)
            Text("Loading section…").font(.caption)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.black.opacity(DesignTokens.readerPanelFillOpacity), in: Capsule())
        .overlay { Capsule().stroke(.white.opacity(DesignTokens.readerHairlineOpacity), lineWidth: 1) }
        .allowsHitTesting(false)
        .transition(.opacity)
        .accessibilityIdentifier("epub.sectionLoading")
    }

    private func commitSectionScrub() {
        guard let value = scrubSpine else { return }
        let target = EPUBSectionScrub.commitTarget(value: value, spineCount: spineCount)
        scrubSpine = nil
        guard target != currentSpine else { return }
        currentSpine = target
        lastStatisticsPosition = target + 1
        currentLocator = nil
        Task { await loadSpine(locator: nil) }
    }

    private func restorePreferences() {
        guard !didRestorePreferences else { return }
        preferences = appState.epubReaderPreferences()
        didRestorePreferences = true
    }

    private func loadBook() async {
        let local = EPUBOfflinePackage.loadManifest(for: book.key)
        offlineManifest = local?.isComplete == true && local?.contentRevision == book.contentRevision ? local : nil
        do {
            let pending = progress.pendingCheckpoint(for: book.key)
            // A completed local package must remain readable during a server
            // outage. Live progress improves resume selection when available,
            // but is not a prerequisite for opening downloaded content.
            let remote = try? await matchingClient?.remoteProgress(for: book)
            if let offlineManifest {
                spineCount = offlineManifest.spineCount
                tableOfContents = offlineManifest.tableOfContents
            } else if let client = matchingClient {
                async let infoTask = client.epubInfo(book: book)
                async let tocTask = client.epubTableOfContents(book: book)
                let (info, toc) = try await (infoTask, tocTask)
                spineCount = max(1, info.pages)
                tableOfContents = toc
            } else {
                throw ServerClientError.unsupported("This EPUB is not fully downloaded and the server is offline.")
            }
            currentSpine = ReaderResumePosition.zeroBasedPage(
                remoteOneBasedPage: remote?.position,
                remoteModifiedAt: remote?.modifiedAt,
                pendingOneBasedPage: pending?.page,
                pendingObservedAt: pending?.observedAt,
                historyOneBasedPage: localHistory?.page,
                pageCount: spineCount
            )
            lastStatisticsPosition = currentSpine + 1
            let pendingIsNewer = pending.map { checkpoint in
                guard let modified = remote?.modifiedAt else { return true }
                return checkpoint.observedAt > modified
            } ?? false
            currentLocator = pendingIsNewer ? pending?.epubLocator : (remote?.epubLocator ?? pending?.epubLocator)
            await loadSpine(locator: currentLocator)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadSpine(locator: String?, atEnd: Bool = false) async {
        // Within-book section turns keep the current page rendered while the
        // next spine is fetched; only loadBook()/moveToAdjacent clear
        // preparedHTML for the full-screen "Preparing book…" state.
        spineLoadSequence &+= 1
        let requestID = spineLoadSequence
        let targetBook = book
        let targetSpine = currentSpine
        let targetPreferences = preferences
        isLoadingSpine = true
        defer {
            if spineLoadSequence == requestID { isLoadingSpine = false }
        }
        do {
            let fragment: String
            if let offlineManifest, offlineManifest.isComplete {
                fragment = try String(
                    contentsOf: EPUBOfflinePackage.spineURL(for: targetBook.key, index: targetSpine),
                    encoding: .utf8
                )
            } else if let client = matchingClient {
                fragment = try await client.epubPage(book: targetBook, index: targetSpine)
            } else {
                throw ServerClientError.unsupported("This EPUB package is incomplete and the server is unavailable.")
            }
            guard spineLoadSequence == requestID,
                  book.id == targetBook.id,
                  currentSpine == targetSpine else { return }
            let baseURL = matchingClient?.profile.baseURL ?? URL(string: "https://offline.invalid")!
            let prepared = EPUBDocumentBuilder.prepare(
                fragment: fragment,
                preferences: targetPreferences,
                baseURL: baseURL
            )
            currentLocator = locator
            currentPercentage = 0
            currentRenderedPage = 1
            renderedPageCount = 1
            refreshBookmarkState(locator: locator)
            loadSpineAtEnd = atEnd
            resourceMap = prepared.resources
            preparedHTML = prepared.html
            loadID &+= 1
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func locationChanged(locator: String?, percentage: Double, page: Int, pageCount: Int) {
        // The outgoing webview stays alive during a spine transition; its late
        // reports must not overwrite the next section's restored state.
        guard !isLoadingSpine else { return }
        let bookmarkLocationChanged = currentLocator != locator
        currentLocator = locator
        currentPercentage = percentage
        currentRenderedPage = max(1, min(page, pageCount))
        renderedPageCount = max(1, pageCount)
        if bookmarkLocationChanged {
            refreshBookmarkState(locator: locator)
        }
    }

    private func locationSettled(locator: String?, percentage: Double, page: Int, pageCount: Int) {
        guard !isLoadingSpine else { return }
        locationChanged(locator: locator, percentage: percentage, page: page, pageCount: pageCount)
        let position = currentSpine + 1
        if let previous = lastStatisticsPosition {
            appState.recordReadingAdvance(
                book: book,
                seriesTitle: seriesTitle,
                from: previous,
                to: position
            )
        }
        lastStatisticsPosition = position
        let completed = currentSpine == spineCount - 1 && percentage >= 0.98
        let checkpoint = ReadingCheckpoint(
            book: book,
            zeroBasedPage: currentSpine,
            pageCount: spineCount,
            completed: completed,
            epubLocator: locator
        )
        if let client = matchingClient {
            progress.record(checkpoint, client: client, immediate: completed, noticePolicy: .silent)
        } else {
            progress.recordOffline(checkpoint)
        }
        recordHistory(page: currentSpine + 1)
    }

    private func flushCurrentLocation(
        noticePolicy: ProgressNoticePolicy = .afterReaderExit,
        beginBackgroundExecution: Bool = true
    ) {
        guard spineCount > 0 else { return }
        let checkpoint = ReadingCheckpoint(
            book: book,
            zeroBasedPage: currentSpine,
            pageCount: spineCount,
            completed: currentSpine == spineCount - 1 && currentPercentage >= 0.98,
            epubLocator: currentLocator
        )
        if let client = matchingClient {
            progress.record(checkpoint, client: client, immediate: true, noticePolicy: noticePolicy)
            if beginBackgroundExecution { progress.beginBackgroundFlush(client: client) }
        } else {
            progress.recordOffline(checkpoint)
        }
        recordHistory(page: currentSpine + 1)
    }

    private func requestPageTurn(next: Bool) {
        pageNavigationSequence &+= 1
        pageNavigationRequest = EPUBPageNavigationRequest(
            id: pageNavigationSequence,
            documentID: loadID,
            direction: next ? .next : .previous
        )
    }

    private func pageBoundaryReached(next: Bool) {
        Task { await moveToSpine(next: next) }
    }

    private func moveToSpine(next: Bool) async {
        if next, currentSpine < spineCount - 1 {
            currentSpine += 1
            currentLocator = nil
            await loadSpine(locator: nil)
        } else if !next, currentSpine > 0 {
            currentSpine -= 1
            currentLocator = nil
            await loadSpine(locator: nil, atEnd: true)
        } else {
            await moveToAdjacent(next: next)
        }
    }

    private func moveToAdjacent(next: Bool) async {
        guard let client = matchingClient else { return }
        flushCurrentLocation(noticePolicy: .silent, beginBackgroundExecution: false)
        do {
            let adjacent = try await client.adjacentBook(from: book, next: next)
            guard adjacent.contentKind == .epub else {
                throw ServerClientError.unsupported("The adjacent item uses the image reader. Close this reader to open it.")
            }
            book = adjacent
            preparedHTML = ""
            currentSpine = 0
            currentLocator = nil
            adjacentBookFeedbackTrigger &+= 1
            await loadBook()
        } catch {
            errorMessage = next ? "There is no next EPUB in this sequence." : "There is no previous EPUB in this sequence."
        }
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

    private var sectionItems: [EPUBTableOfContentsItem] {
        guard tableOfContents.isEmpty else { return tableOfContents }
        return (0..<max(1, spineCount)).map {
            EPUBTableOfContentsItem(title: "Section \($0 + 1)", part: nil, page: $0)
        }
    }

    private func recordHistory(page: Int) {
        appState.recordHistory(book: book, seriesTitle: seriesTitle, page: page)
    }

    private var matchingClient: ServerClient? {
        guard appState.activeClient?.profile.id == book.key.serverID else { return nil }
        return appState.activeClient
    }

    private func refreshBookmarkState(locator: String?) {
        let locator = bookmarkLocator(locator)
        let bookID = book.key.remoteID
        let serverID = book.key.serverID.description
        let descriptor = FetchDescriptor<BookmarkRecord>(predicate: #Predicate {
            $0.bookID == bookID && $0.serverID == serverID && $0.locator == locator
        })
        currentLocationIsBookmarked = ((try? modelContext.fetchCount(descriptor)) ?? 0) > 0
    }

    private func toggleBookmark() {
        let locator = bookmarkLocator(currentLocator)
        let bookID = book.key.remoteID
        let serverID = book.key.serverID.description
        let descriptor = FetchDescriptor<BookmarkRecord>(predicate: #Predicate {
            $0.bookID == bookID && $0.serverID == serverID && $0.locator == locator
        })
        if let existing = try? modelContext.fetch(descriptor).first {
            modelContext.delete(existing)
            currentLocationIsBookmarked = false
        } else {
            modelContext.insert(BookmarkRecord(
                book: book.key,
                page: currentSpine,
                locator: locator,
                title: "\(seriesTitle) · \(book.displayTitle)"
            ))
            currentLocationIsBookmarked = true
        }
        do {
            try modelContext.save()
            bookmarkFeedbackTrigger &+= 1
        } catch {
            refreshBookmarkState(locator: locator)
            errorMessage = "The bookmark could not be saved. \(error.localizedDescription)"
        }
    }

    private func bookmarkLocator(_ locator: String?) -> String {
        EPUBBookmarkLocation.normalized(locator)
    }
}

enum EPUBBookmarkLocation {
    static func normalized(_ locator: String?) -> String {
        locator?.nilIfEmpty ?? "//body"
    }
}

enum EPUBSectionScrub {
    /// Clamps a slider value to a valid zero-based spine index.
    static func commitTarget(value: Double, spineCount: Int) -> Int {
        min(max(0, Int(value)), max(0, spineCount - 1))
    }
}

enum EPUBSectionSelection {
    static func selectedID(
        in items: [EPUBTableOfContentsItem],
        currentSpine: Int,
        currentLocator: String?
    ) -> String? {
        let flattened = flatten(items)
        if let locator = currentLocator?.nilIfEmpty,
           let exact = flattened.first(where: { $0.part?.nilIfEmpty == locator }) {
            return exact.id
        }
        return flattened.first(where: { $0.page == currentSpine })?.id
    }

    private static func flatten(_ items: [EPUBTableOfContentsItem]) -> [EPUBTableOfContentsItem] {
        items.flatMap { [$0] + flatten($0.children) }
    }
}

private struct EPUBPageNavigationRequest: Equatable {
    enum Direction {
        case previous
        case next
    }

    let id: Int
    let documentID: Int
    let direction: Direction
}

private struct EPUBWebView: UIViewRepresentable {
    let html: String
    let resourceMap: [String: String]
    let book: Book
    let client: ServerClient?
    let offlineManifest: EPUBPackageManifest?
    let mode: EPUBReaderMode
    let documentID: Int
    let initialLocator: String?
    let initialAtEnd: Bool
    let navigationRequest: EPUBPageNavigationRequest?
    let onLocationChanged: (String?, Double, Int, Int) -> Void
    let onLocationSettled: (String?, Double, Int, Int) -> Void
    let onPageBoundary: (Bool) -> Void
    let onToggleChrome: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            mode: mode,
            documentID: documentID,
            initialLocator: initialLocator,
            initialAtEnd: initialAtEnd,
            onLocationChanged: onLocationChanged,
            onLocationSettled: onLocationSettled,
            onPageBoundary: onPageBoundary,
            onToggleChrome: onToggleChrome
        )
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.add(context.coordinator, name: "readerEvent")
        let handler = EPUBResourceSchemeHandler(
            book: book,
            client: client,
            offlineManifest: offlineManifest,
            resourceMap: resourceMap
        )
        context.coordinator.resourceHandler = handler
        configuration.setURLSchemeHandler(handler, forURLScheme: "tsundoku-resource")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        // Paged EPUB navigation is deliberately controlled by exact JavaScript
        // viewport offsets. Allowing WebKit's pan recognizer to move the same
        // document can leave the viewport between two CSS columns.
        webView.scrollView.isPagingEnabled = false
        webView.scrollView.isScrollEnabled = mode == .scrolling
        webView.scrollView.bounces = mode == .scrolling
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        webView.addGestureRecognizer(tap)
        if mode == .paged {
            let previous = UISwipeGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.swiped(_:)))
            previous.direction = .right
            previous.delegate = context.coordinator
            let next = UISwipeGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.swiped(_:)))
            next.direction = .left
            next.delegate = context.coordinator
            tap.require(toFail: previous)
            tap.require(toFail: next)
            webView.addGestureRecognizer(previous)
            webView.addGestureRecognizer(next)
        }
        context.coordinator.webView = webView
        webView.loadHTMLString(html, baseURL: URL(string: "about:blank"))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.handle(navigationRequest)
    }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, UIGestureRecognizerDelegate {
        weak var webView: WKWebView?
        var resourceHandler: EPUBResourceSchemeHandler?
        private let mode: EPUBReaderMode
        private let documentID: Int
        private let initialLocator: String?
        private let initialAtEnd: Bool
        private let onLocationChanged: (String?, Double, Int, Int) -> Void
        private let onLocationSettled: (String?, Double, Int, Int) -> Void
        private let onPageBoundary: (Bool) -> Void
        private let onToggleChrome: () -> Void
        private var didRestoreInitialLocation = false
        private var lastNavigationRequestID: Int?
        private var pendingNavigationRequest: EPUBPageNavigationRequest?

        init(
            mode: EPUBReaderMode,
            documentID: Int,
            initialLocator: String?,
            initialAtEnd: Bool,
            onLocationChanged: @escaping (String?, Double, Int, Int) -> Void,
            onLocationSettled: @escaping (String?, Double, Int, Int) -> Void,
            onPageBoundary: @escaping (Bool) -> Void,
            onToggleChrome: @escaping () -> Void
        ) {
            self.mode = mode
            self.documentID = documentID
            self.initialLocator = initialLocator
            self.initialAtEnd = initialAtEnd
            self.onLocationChanged = onLocationChanged
            self.onLocationSettled = onLocationSettled
            self.onPageBoundary = onPageBoundary
            self.onToggleChrome = onToggleChrome
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
            let locatorJSON = initialLocator.flatMap { try? JSONSerialization.data(withJSONObject: [$0]) }
                .flatMap { String(data: $0, encoding: .utf8) }
                .map { String($0.dropFirst().dropLast()) }
                ?? "null"
            webView.evaluateJavaScript(Self.observationScript(locatorJSON: locatorJSON, initialAtEnd: initialAtEnd)) { [weak self] _, _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    guard let self else { return }
                    self.didRestoreInitialLocation = true
                    self.webView?.evaluateJavaScript("window.tsundokuReport(false)")
                    if let pending = self.pendingNavigationRequest {
                        self.pendingNavigationRequest = nil
                        self.handle(pending)
                    }
                }
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard didRestoreInitialLocation, let body = message.body as? [String: Any] else { return }
            let locator = body["locator"] as? String
            let percentage = min(1, max(0, body["percentage"] as? Double ?? 0))
            let page = max(1, (body["page"] as? NSNumber)?.intValue ?? 1)
            let pageCount = max(page, (body["pageCount"] as? NSNumber)?.intValue ?? 1)
            let settled = body["settled"] as? Bool ?? false
            onLocationChanged(locator, percentage, page, pageCount)
            if settled { onLocationSettled(locator, percentage, page, pageCount) }
        }

        @objc func tapped(_ gesture: UITapGestureRecognizer) {
            guard let webView else { return }
            let point = gesture.location(in: webView)
            guard mode == .paged else { onToggleChrome(); return }
            let edge = min(64, max(44, webView.bounds.width * 0.15))
            if point.x <= edge {
                turnPage(next: false)
            } else if point.x >= webView.bounds.width - edge {
                turnPage(next: true)
            } else {
                onToggleChrome()
            }
        }

        @objc func swiped(_ gesture: UISwipeGestureRecognizer) {
            turnPage(next: gesture.direction == .left)
        }

        func handle(_ request: EPUBPageNavigationRequest?) {
            guard let request,
                  request.documentID == documentID,
                  request.id != lastNavigationRequestID else { return }
            guard didRestoreInitialLocation else {
                pendingNavigationRequest = request
                return
            }
            lastNavigationRequestID = request.id
            turnPage(next: request.direction == .next)
        }

        private func turnPage(next: Bool) {
            guard didRestoreInitialLocation else { return }
            webView?.evaluateJavaScript("window.tsundokuTurnPage(\(next ? 1 : -1))") { [weak self] result, error in
                guard error == nil, let moved = result as? Bool else { return }
                if !moved { self?.onPageBoundary(next) }
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var view = touch.view
            while let current = view {
                if current is UIControl { return false }
                view = current.superview
            }
            return true
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool { true }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
            if navigationAction.navigationType == .linkActivated,
               url.scheme == "http" || url.scheme == "https" {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            let allowed = url.scheme == "about" || url.scheme == "tsundoku-resource"
            decisionHandler(allowed ? .allow : .cancel)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? { nil }

        private static func observationScript(locatorJSON: String, initialAtEnd: Bool) -> String {
            """
            (() => {
              const xpath = el => {
                if (!el) return null;
                const parts = [];
                while (el && el.nodeType === 1 && el !== document.documentElement) {
                  let index = 1, sibling = el.previousElementSibling;
                  while (sibling) { if (sibling.tagName === el.tagName) index++; sibling = sibling.previousElementSibling; }
                  parts.unshift(el.tagName.toLowerCase() + '[' + index + ']');
                  el = el.parentElement;
                }
                return '//body/' + parts.slice(parts.indexOf('body[1]') + 1).join('/');
              };
              let timer;
              let turnInProgress = false;
              const horizontalMetrics = () => {
                const root = document.scrollingElement;
                const horizontal = root.scrollWidth > root.clientWidth + 2;
                return {root, horizontal, viewport:Math.max(1, root.clientWidth)};
              };
              const snapHorizontalPage = () => {
                const {root, horizontal, viewport} = horizontalMetrics();
                if (!horizontal) return false;
                const target = Math.max(0, Math.min(root.scrollWidth - viewport, Math.round(root.scrollLeft / viewport) * viewport));
                if (Math.abs(target - root.scrollLeft) < .5) return false;
                root.scrollTo({left:target,behavior:'auto'});
                return true;
              };
              window.tsundokuReport = settled => {
                const nodes = Array.from(document.querySelectorAll('.book-content p,.book-content div,.book-content li,.book-content h1,.book-content h2,.book-content h3,.book-content img'));
                const line = Math.min(120, window.innerHeight * .15);
                let target = null, distance = Infinity;
                nodes.forEach(node => { const rect = node.getBoundingClientRect(); const d = Math.abs(rect.top - line) + Math.abs(rect.left) * .01; if (rect.bottom >= 0 && d < distance) { target = node; distance = d; } });
                const root = document.scrollingElement;
                const horizontal = root.scrollWidth > root.clientWidth + 2;
                const max = horizontal ? root.scrollWidth - root.clientWidth : root.scrollHeight - root.clientHeight;
                const offset = horizontal ? root.scrollLeft : root.scrollTop;
                const viewport = Math.max(1, horizontal ? root.clientWidth : root.clientHeight);
                const extent = Math.max(viewport, horizontal ? root.scrollWidth : root.scrollHeight);
                const pageCount = Math.max(1, Math.ceil(extent / viewport));
                const pageIndex = horizontal ? Math.round(offset / viewport) : Math.floor(offset / viewport);
                const page = Math.max(1, Math.min(pageCount, pageIndex + 1));
                window.webkit.messageHandlers.readerEvent.postMessage({locator:xpath(target), percentage:max > 0 ? offset/max : 0, page, pageCount, settled:!!settled});
              };
              window.tsundokuTurnPage = direction => {
                if (turnInProgress) return true;
                const root = document.scrollingElement;
                const horizontal = root.scrollWidth > root.clientWidth + 2;
                const viewport = horizontal ? root.clientWidth : Math.max(1, root.clientHeight * .9);
                const offset = horizontal ? root.scrollLeft : root.scrollTop;
                const max = horizontal ? root.scrollWidth - root.clientWidth : root.scrollHeight - root.clientHeight;
                const currentPage = horizontal ? Math.round(offset / Math.max(1, viewport)) : 0;
                const target = horizontal
                  ? Math.max(0, Math.min(max, (currentPage + direction) * viewport))
                  : Math.max(0, Math.min(max, offset + direction * viewport));
                if (Math.abs(target - offset) < 2) return false;
                turnInProgress = true;
                root.scrollTo(horizontal ? {left:target,behavior:'smooth'} : {top:target,behavior:'smooth'});
                clearTimeout(timer);
                timer=setTimeout(() => {
                  if (horizontal) snapHorizontalPage();
                  turnInProgress = false;
                  window.tsundokuReport(true);
                }, 400);
                return true;
              };
              addEventListener('scroll', () => {
                window.tsundokuReport(false);
                clearTimeout(timer);
                timer=setTimeout(() => {
                  if (snapHorizontalPage()) {
                    timer=setTimeout(() => window.tsundokuReport(true), 50);
                  } else {
                    window.tsundokuReport(true);
                  }
                  turnInProgress = false;
                }, 350);
              }, {passive:true});
              window.tsundokuResizeObserver = new ResizeObserver(() => window.tsundokuReport(false));
              const content = document.querySelector('.book-content');
              if (content) window.tsundokuResizeObserver.observe(content);
              const initial = \(locatorJSON);
              if (initial) {
                try { const node = document.evaluate(initial, document, null, XPathResult.FIRST_ORDERED_NODE_TYPE, null).singleNodeValue; if (node) node.scrollIntoView({block:'start',inline:'start'}); } catch (_) {}
              } else if (\(initialAtEnd ? "true" : "false")) {
                const root = document.scrollingElement;
                root.scrollTo({left:root.scrollWidth,top:root.scrollHeight});
              }
              requestAnimationFrame(() => requestAnimationFrame(() => {
                snapHorizontalPage();
                window.tsundokuReport(false);
              }));
            })();
            """
        }
    }
}

private final class EPUBResourceSchemeHandler: NSObject, WKURLSchemeHandler, @unchecked Sendable {
    private let book: Book
    private let client: ServerClient?
    private let offlineManifest: EPUBPackageManifest?
    private let resourceMap: [String: String]
    private let taskLock = NSLock()
    private var activeTasks: Set<ObjectIdentifier> = []

    init(book: Book, client: ServerClient?, offlineManifest: EPUBPackageManifest?, resourceMap: [String: String]) {
        self.book = book
        self.client = client
        self.offlineManifest = offlineManifest
        self.resourceMap = resourceMap
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let taskID = ObjectIdentifier(urlSchemeTask as AnyObject)
        _ = taskLock.withLock { activeTasks.insert(taskID) }
        guard let customURL = urlSchemeTask.request.url else {
            if consumeTask(taskID) {
                urlSchemeTask.didFailWithError(KavitaClientError.invalidResponse)
            }
            return
        }
        Task {
            do {
                guard let remoteURL = EPUBDocumentBuilder.remoteURL(from: customURL)
                    ?? resourceMap[customURL.absoluteString].flatMap(URL.init(string:)) else {
                    throw KavitaClientError.invalidResponse
                }
                let data: Data
                if let offlineManifest, offlineManifest.isComplete,
                   offlineManifest.completedResourceURLs.contains(remoteURL.absoluteString) {
                    data = try Data(contentsOf: EPUBOfflinePackage.resourceURL(for: book.key, remoteURL: remoteURL))
                } else if let client {
                    let request = try await client.epubResourceRequest(book: book, reference: remoteURL.absoluteString)
                    data = try await client.data(for: request)
                } else {
                    throw ServerClientError.unsupported("The EPUB resource is unavailable offline.")
                }
                let type = EPUBDocumentBuilder.resourceMIMEType(for: remoteURL)
                let response = URLResponse(url: customURL, mimeType: type, expectedContentLength: data.count, textEncodingName: nil)
                guard consumeTask(taskID) else { return }
                urlSchemeTask.didReceive(response)
                urlSchemeTask.didReceive(data)
                urlSchemeTask.didFinish()
            } catch {
                if consumeTask(taskID) {
                    urlSchemeTask.didFailWithError(error)
                }
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        let taskID = ObjectIdentifier(urlSchemeTask as AnyObject)
        _ = taskLock.withLock { activeTasks.remove(taskID) }
    }

    private func consumeTask(_ taskID: ObjectIdentifier) -> Bool {
        taskLock.withLock { activeTasks.remove(taskID) != nil }
    }
}

private struct EPUBTableOfContentsSheet: View {
    private struct Entry: Identifiable {
        let item: EPUBTableOfContentsItem
        let level: Int
        var id: String { "\(item.id):\(level)" }
    }

    @Environment(\.dismiss) private var dismiss
    let items: [EPUBTableOfContentsItem]
    let selectedSectionID: String?
    let select: (EPUBTableOfContentsItem) -> Void

    var body: some View {
        NavigationStack {
            List(flattenedItems) { entry in
                Button {
                    select(entry.item)
                    dismiss()
                } label: {
                    HStack {
                        Text(entry.item.title)
                            .padding(.leading, CGFloat(entry.level) * 14)
                        Spacer()
                        if entry.item.id == selectedSectionID {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                }
            }
                .navigationTitle("Sections")
                .toolbar { Button("Done") { dismiss() } }
        }
        .presentationDetents([.medium, .large])
    }

    private var flattenedItems: [Entry] {
        func append(_ values: [EPUBTableOfContentsItem], level: Int, to result: inout [Entry]) {
            for item in values {
                result.append(Entry(item: item, level: level))
                append(item.children, level: level + 1, to: &result)
            }
        }
        var result: [Entry] = []
        append(items, level: 0, to: &result)
        return result
    }
}

private struct EPUBSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var preferences: EPUBReaderPreferences

    var body: some View {
        NavigationStack {
            Form {
                Picker("Mode", selection: $preferences.mode) {
                    ForEach(EPUBReaderMode.allCases) { Text($0.title).tag($0) }
                }
                Picker("Theme", selection: $preferences.theme) {
                    ForEach(EPUBTheme.allCases) { Text($0.title).tag($0) }
                }
                Picker("Font", selection: $preferences.fontFamily) {
                    ForEach(EPUBFontFamily.allCases) { Text($0.title).tag($0) }
                }
                Section("Typography") {
                    LabeledContent("Font size", value: "\(Int(preferences.fontSize)) pt")
                    Slider(value: $preferences.fontSize, in: 13...32, step: 1)
                    LabeledContent("Line height", value: preferences.lineHeight.formatted(.number.precision(.fractionLength(2))))
                    Slider(value: $preferences.lineHeight, in: 1.1...2.1, step: 0.05)
                    LabeledContent("Margins", value: "\(Int(preferences.horizontalMargin)) pt")
                    Slider(value: $preferences.horizontalMargin, in: 8...64, step: 2)
                }
            }
            .navigationTitle("EPUB Reader")
            .toolbar { Button("Done") { dismiss() } }
        }
        .presentationDetents([.medium, .large])
    }
}
