import ActivityKit
import Foundation
import Observation
import SwiftData

enum DownloadTaskKind: String, Codable, Sendable {
    case imagePage
    case epubSpine
    case epubResource
}

struct DownloadTaskDescriptor: Codable, Sendable {
    let serverID: ServerID
    let bookID: String
    let page: Int
    let kind: DownloadTaskKind
    let resourceURL: String?

    init(serverID: ServerID, bookID: String, page: Int) {
        self.serverID = serverID
        self.bookID = bookID
        self.page = page
        kind = .imagePage
        resourceURL = nil
    }

    init(serverID: ServerID, bookID: String, spine: Int) {
        self.serverID = serverID
        self.bookID = bookID
        page = spine
        kind = .epubSpine
        resourceURL = nil
    }

    init(serverID: ServerID, bookID: String, resourceURL: String) {
        self.serverID = serverID
        self.bookID = bookID
        page = -1
        kind = .epubResource
        self.resourceURL = resourceURL
    }

    private enum CodingKeys: String, CodingKey { case serverID, bookID, page, kind, resourceURL }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        serverID = try values.decode(ServerID.self, forKey: .serverID)
        bookID = try values.decode(String.self, forKey: .bookID)
        page = try values.decodeIfPresent(Int.self, forKey: .page) ?? -1
        kind = try values.decodeIfPresent(DownloadTaskKind.self, forKey: .kind) ?? .imagePage
        resourceURL = try values.decodeIfPresent(String.self, forKey: .resourceURL)
    }

    func belongs(to book: BookKey) -> Bool {
        serverID == book.serverID && bookID == book.remoteID
    }
}

enum DownloadPackagePolicy {
    static func requiresReplacement(
        existingRevision: String,
        newRevision: String,
        existingPageCount: Int,
        newPageCount: Int
    ) -> Bool {
        existingRevision != newRevision || existingPageCount != newPageCount
    }
}

enum DownloadThroughputPolicy {
    /// Six concurrent transfers keeps Komga/Kavita downloads moving without
    /// overwhelming the server or allowing one book to monopolize the device.
    static let maximumConnectionsPerHost = 6

    /// Image downloads account for the file that just arrived instead of
    /// rescanning every page and recursively walking the package after each
    /// completion. This keeps completion work constant as books get larger.
    static func completedPageCount(current: Int, pageCount: Int) -> Int {
        min(max(0, pageCount), max(0, current) + 1)
    }

    static func packageSize(current: Int64, addingFileBytes bytes: Int64) -> Int64 {
        max(0, current) + max(0, bytes)
    }
}

enum DownloadLiveActivityPolicy {
    static func isVisible(for state: DownloadState) -> Bool {
        state == .queued || state == .downloading || state == .paused
    }
}

private struct DownloadActivitySnapshot: Sendable {
    let id: String
    let seriesTitle: String
    let bookTitle: String
    let completedPages: Int
    let pageCount: Int
    let state: DownloadState

    init(_ record: DownloadRecord) {
        id = record.id
        seriesTitle = record.seriesTitle
        bookTitle = record.bookTitle
        completedPages = record.completedPages
        pageCount = record.pageCount
        state = record.state
    }

    var contentState: DownloadLiveActivityAttributes.ContentState {
        DownloadLiveActivityAttributes.ContentState(
            completedUnitCount: completedPages,
            totalUnitCount: pageCount,
            status: state == .paused ? "Paused" : "Downloading"
        )
    }
}

private actor DownloadLiveActivityCoordinator {
    static let shared = DownloadLiveActivityCoordinator()

    func sync(_ snapshots: [DownloadActivitySnapshot]) async {
        let visible = snapshots.filter { DownloadLiveActivityPolicy.isVisible(for: $0.state) }
        let visibleIDs = Set(visible.map(\.id))

        for activity in Activity<DownloadLiveActivityAttributes>.activities
            where !visibleIDs.contains(activity.attributes.downloadID) {
            await activity.end(nil, dismissalPolicy: .immediate)
        }

        for snapshot in visible {
            let content = ActivityContent(state: snapshot.contentState, staleDate: nil)
            if let activity = Activity<DownloadLiveActivityAttributes>.activities.first(where: {
                $0.attributes.downloadID == snapshot.id
            }) {
                await activity.update(content)
            } else if ActivityAuthorizationInfo().areActivitiesEnabled {
                let attributes = DownloadLiveActivityAttributes(
                    downloadID: snapshot.id,
                    seriesTitle: snapshot.seriesTitle,
                    bookTitle: snapshot.bookTitle
                )
                _ = try? Activity.request(attributes: attributes, content: content)
            }
        }
    }

    func endAll() async {
        for activity in Activity<DownloadLiveActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}

enum BackgroundDownloadEvent: Sendable {
    case finished(DownloadTaskDescriptor, URL)
    case failed(DownloadTaskDescriptor, String)
}

final class BackgroundDownloadCoordinator: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let sessionIdentifier = "com.example.Tsundoku.background-pages"
    static let shared = BackgroundDownloadCoordinator()

    private let lock = NSLock()
    private var backgroundContinuation: CheckedContinuation<Void, Never>?
    private var handler: (@Sendable (BackgroundDownloadEvent) async -> Void)?
    private var pendingHandlerEvents = 0
    private var sessionFinishedDeliveringEvents = false

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.waitsForConnectivity = true
        configuration.httpMaximumConnectionsPerHost = DownloadThroughputPolicy.maximumConnectionsPerHost
        configuration.allowsCellularAccess = !UserDefaults.standard.bool(forKey: "downloadsWiFiOnly")
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    func setHandler(_ handler: @escaping @Sendable (BackgroundDownloadEvent) async -> Void) {
        lock.withLock { self.handler = handler }
    }

    /// Reconnects this process to tasks already owned by the system background
    /// session. Creating the session is intentionally deferred until either the
    /// app needs it or iOS invokes the URL-session background task.
    func reconnect() { _ = session }

    func enqueue(_ request: URLRequest, descriptor: DownloadTaskDescriptor) {
        let task = session.downloadTask(with: request)
        task.taskDescription = (try? JSONEncoder().encode(descriptor).base64EncodedString())
        task.resume()
    }

    func tasks() async -> [URLSessionTask] { await session.allTasks }

    func suspend(book: BookKey) async {
        for task in await session.allTasks where descriptor(from: task)?.belongs(to: book) == true {
            task.suspend()
        }
    }

    func resume(book: BookKey) async {
        for task in await session.allTasks where descriptor(from: task)?.belongs(to: book) == true {
            task.resume()
        }
    }

    func cancel(book: BookKey) async {
        for task in await session.allTasks where descriptor(from: task)?.belongs(to: book) == true {
            task.cancel()
        }
    }

    func cancelAll() async {
        for task in await session.allTasks { task.cancel() }
    }

    func handleBackgroundEvents() async {
        await withCheckedContinuation { continuation in
            lock.withLock {
                backgroundContinuation = continuation
                sessionFinishedDeliveringEvents = false
            }
            // A background URLSession must be recreated with the same identifier
            // before iOS can deliver the events that relaunched the app.
            reconnect()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let descriptor = descriptor(from: downloadTask) else { return }
        let temporary = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: temporary)
            dispatch(.finished(descriptor, temporary))
        } catch {
            dispatch(.failed(descriptor, error.localizedDescription))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let descriptor = descriptor(from: task) else { return }
        dispatch(.failed(descriptor, error.localizedDescription))
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            sessionFinishedDeliveringEvents = true
            guard pendingHandlerEvents == 0 else { return nil }
            defer { backgroundContinuation = nil }
            return backgroundContinuation
        }
        continuation?.resume()
    }

    private func dispatch(_ event: BackgroundDownloadEvent) {
        let callback = lock.withLock { () -> (@Sendable (BackgroundDownloadEvent) async -> Void)? in
            guard let handler else { return nil }
            pendingHandlerEvents += 1
            return handler
        }
        guard let callback else { return }
        Task {
            await callback(event)
            handlerFinished()
        }
    }

    private func handlerFinished() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            pendingHandlerEvents = max(0, pendingHandlerEvents - 1)
            guard pendingHandlerEvents == 0, sessionFinishedDeliveringEvents else { return nil }
            defer { backgroundContinuation = nil }
            return backgroundContinuation
        }
        continuation?.resume()
    }

    private func descriptor(from task: URLSessionTask) -> DownloadTaskDescriptor? {
        guard let description = task.taskDescription, let data = Data(base64Encoded: description) else { return nil }
        return try? JSONDecoder().decode(DownloadTaskDescriptor.self, from: data)
    }
}

@MainActor @Observable
final class DownloadManager {
    private let container: ModelContainer
    private let coordinator: BackgroundDownloadCoordinator
    @ObservationIgnored private var clients: [String: ServerClient] = [:]
    @ObservationIgnored private var pendingActivitySnapshots: [DownloadActivitySnapshot]?
    @ObservationIgnored private var liveActivityUpdateTask: Task<Void, Never>?
    private(set) var activeCount = 0
    /// Bumped only when a record transitions into `.complete`; drives
    /// completion feedback in the UI without exposing record internals.
    private(set) var completedDownloadEventCount = 0

    init(modelContainer: ModelContainer, coordinator: BackgroundDownloadCoordinator = .shared) {
        container = modelContainer
        self.coordinator = coordinator
        coordinator.setHandler { [weak self] event in
            await self?.handle(event)
        }
        refreshCount()
    }

    func reconnect() {
        coordinator.reconnect()
        refreshCount()
    }

    func register(_ client: ServerClient) {
        clients[client.profile.id.description] = client
        Task { await resumePendingEPUB(client: client) }
    }

    func prepareForDeviceReset() async {
        await coordinator.cancelAll()
        liveActivityUpdateTask?.cancel()
        liveActivityUpdateTask = nil
        pendingActivitySnapshots = nil
        await DownloadLiveActivityCoordinator.shared.endAll()
        clients.removeAll()
        activeCount = 0
    }

    func start(
        book: Book,
        pages: [BookPage],
        seriesTitle: String,
        seriesReadingDirection: String = "RIGHT_TO_LEFT",
        seriesTags: [String] = [],
        client: ServerClient
    ) async throws {
        if book.contentKind == .epub {
            try await startEPUB(
                book: book,
                seriesTitle: seriesTitle,
                seriesReadingDirection: seriesReadingDirection,
                seriesTags: seriesTags,
                client: client
            )
            return
        }
        try await startImagePackage(
            book: book,
            pages: pages,
            seriesTitle: seriesTitle,
            seriesReadingDirection: seriesReadingDirection,
            seriesTags: seriesTags,
            client: client
        )
    }

    private func startImagePackage(
        book: Book,
        pages: [BookPage],
        seriesTitle: String,
        seriesReadingDirection: String,
        seriesTags: [String],
        client: ServerClient
    ) async throws {
        let context = container.mainContext
        let id = book.id
        let descriptor = FetchDescriptor<DownloadRecord>(predicate: #Predicate { $0.id == id })
        let record: DownloadRecord
        let replacesExistingPackage: Bool
        if let existing = try context.fetch(descriptor).first {
            record = existing
            replacesExistingPackage = DownloadPackagePolicy.requiresReplacement(
                existingRevision: existing.fileHash,
                newRevision: book.contentRevision,
                existingPageCount: existing.pageCount,
                newPageCount: pages.count
            )
            record.fileHash = book.contentRevision
            record.contentKind = book.contentKind
            record.pageCount = pages.count
            record.lastError = nil
            updateMetadata(
                record,
                book: book,
                seriesTitle: seriesTitle,
                seriesReadingDirection: seriesReadingDirection,
                seriesTags: seriesTags
            )
        } else {
            record = DownloadRecord(
                book: book,
                seriesTitle: seriesTitle,
                seriesReadingDirection: seriesReadingDirection,
                seriesTags: seriesTags
            )
            record.pageCount = pages.count
            replacesExistingPackage = false
            context.insert(record)
        }
        if replacesExistingPackage {
            await coordinator.cancel(book: book.key)
            try? FileManager.default.removeItem(at: DownloadPaths.book(book.key))
        }
        let package = DownloadPaths.book(book.key)
        let manifest = try JSONEncoder().encode(pages)
        try manifest.write(to: package.appending(path: "manifest.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        let completedPages = pages.indices.filter { index in
            FileManager.default.fileExists(atPath: DownloadPaths.page(PageKey(book: book.key, index: index)).path)
        }.count
        record.completedPages = completedPages
        record.sizeBytes = DownloadPaths.packageSize(for: book.key)
        record.state = !pages.isEmpty && completedPages == pages.count ? .complete : .downloading
        try context.save()

        for index in pages.indices {
            let pageKey = PageKey(book: book.key, index: index)
            guard !FileManager.default.fileExists(atPath: DownloadPaths.page(pageKey).path) else { continue }
            let request = try await client.pageRequest(book: book, zeroBasedPage: index)
            coordinator.enqueue(request, descriptor: DownloadTaskDescriptor(serverID: book.key.serverID, bookID: book.key.remoteID, page: index))
        }
        refreshCount()
    }

    private func startEPUB(
        book: Book,
        seriesTitle: String,
        seriesReadingDirection: String,
        seriesTags: [String],
        client: ServerClient
    ) async throws {
        clients[client.profile.id.description] = client
        async let infoTask = client.epubInfo(book: book)
        async let tocTask = client.epubTableOfContents(book: book)
        let (info, toc) = try await (infoTask, tocTask)
        let spineCount = max(1, info.pages)
        let context = container.mainContext
        let id = book.id
        let descriptor = FetchDescriptor<DownloadRecord>(predicate: #Predicate { $0.id == id })
        let record: DownloadRecord
        if let existing = try context.fetch(descriptor).first {
            record = existing
            record.fileHash = book.contentRevision
            record.contentKind = .epub
            record.pageCount = spineCount
            record.state = .downloading
            record.lastError = nil
            updateMetadata(
                record,
                book: book,
                seriesTitle: seriesTitle,
                seriesReadingDirection: seriesReadingDirection,
                seriesTags: seriesTags
            )
        } else {
            record = DownloadRecord(
                book: book,
                seriesTitle: seriesTitle,
                seriesReadingDirection: seriesReadingDirection,
                seriesTags: seriesTags
            )
            record.fileHash = book.contentRevision
            record.contentKind = .epub
            record.pageCount = spineCount
            record.state = .downloading
            context.insert(record)
        }

        let existing = EPUBOfflinePackage.loadManifest(for: book.key)
        let manifest: EPUBPackageManifest
        if let existing, existing.contentRevision == book.contentRevision, existing.spineCount == spineCount {
            manifest = existing
        } else {
            await coordinator.cancel(book: book.key)
            try? FileManager.default.removeItem(at: DownloadPaths.book(book.key))
            _ = DownloadPaths.book(book.key)
            manifest = EPUBPackageManifest(
                bookID: book.key.remoteID,
                contentRevision: book.contentRevision,
                spineCount: spineCount,
                tableOfContents: toc,
                resourceFiles: [:],
                completedSpineIndexes: [],
                completedResourceURLs: []
            )
        }
        try EPUBOfflinePackage.saveManifest(manifest, for: book.key)
        try context.save()
        await enqueueMissingEPUBTasks(book: book, manifest: manifest, client: client)
        refreshCount()
    }

    private func updateMetadata(
        _ record: DownloadRecord,
        book: Book,
        seriesTitle: String,
        seriesReadingDirection: String,
        seriesTags: [String]
    ) {
        record.seriesTitle = seriesTitle
        record.bookTitle = book.displayTitle
        record.bookPayload = (try? JSONEncoder().encode(book)) ?? record.bookPayload
        record.seriesReadingDirection = seriesReadingDirection
        record.seriesTagsPayload = (try? JSONEncoder().encode(seriesTags)) ?? record.seriesTagsPayload
    }

    func remove(_ record: DownloadRecord) throws {
        guard let serverID = ServerID(string: record.serverID) else {
            throw ServerClientError.unsupported("This download has an invalid server identifier.")
        }
        let key = BookKey(serverID: serverID, remoteID: record.bookID)
        try? FileManager.default.removeItem(at: DownloadPaths.book(key))
        container.mainContext.delete(record)
        try container.mainContext.save()
        Task { await coordinator.cancel(book: key) }
        refreshCount()
    }

    func pause(_ record: DownloadRecord) {
        record.state = .paused
        record.updatedAt = .now
        try? container.mainContext.save()
        guard let serverID = ServerID(string: record.serverID) else { return }
        let key = BookKey(serverID: serverID, remoteID: record.bookID)
        Task { await coordinator.suspend(book: key) }
        refreshCount()
    }

    func resume(_ record: DownloadRecord) {
        record.state = .downloading
        record.updatedAt = .now
        try? container.mainContext.save()
        guard let serverID = ServerID(string: record.serverID) else { return }
        let key = BookKey(serverID: serverID, remoteID: record.bookID)
        Task { await coordinator.resume(book: key) }
        refreshCount()
    }

    func retryFailed(client: ServerClient, books: [String: (Book, [BookPage], String)]) async {
        let serverID = client.profile.id.description
        let failed = (try? container.mainContext.fetch(
            FetchDescriptor<DownloadRecord>(predicate: #Predicate {
                $0.serverID == serverID && $0.stateRaw == "failed"
            })
        )) ?? []
        for item in failed {
            guard let value = books[item.bookID] else { continue }
            try? await start(book: value.0, pages: value.1, seriesTitle: value.2, client: client)
        }
    }

    private func handle(_ event: BackgroundDownloadEvent) {
        switch event {
        case .finished(let descriptor, let temporaryURL):
            guard downloadRecordExists(for: descriptor) else {
                try? FileManager.default.removeItem(at: temporaryURL)
                return
            }
            switch descriptor.kind {
            case .imagePage:
                finishImagePage(descriptor: descriptor, temporaryURL: temporaryURL)
            case .epubSpine:
                finishEPUBSpine(descriptor: descriptor, temporaryURL: temporaryURL)
            case .epubResource:
                finishEPUBResource(descriptor: descriptor, temporaryURL: temporaryURL)
            }
        case .failed(let descriptor, let message):
            updateRecord(descriptor: descriptor, error: message)
        }
    }

    private func downloadRecordExists(for descriptor: DownloadTaskDescriptor) -> Bool {
        let id = BookKey(serverID: descriptor.serverID, remoteID: descriptor.bookID).id
        let descriptor = FetchDescriptor<DownloadRecord>(predicate: #Predicate { $0.id == id })
        return (try? container.mainContext.fetchCount(descriptor)) ?? 0 > 0
    }

    private func finishImagePage(descriptor: DownloadTaskDescriptor, temporaryURL: URL) {
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        let key = BookKey(serverID: descriptor.serverID, remoteID: descriptor.bookID)
        var destination = DownloadPaths.page(PageKey(book: key, index: descriptor.page))
        // A duplicate background callback must not double-count or replace a
        // page that is already safely stored in the current package.
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            // Rare duplicate callbacks also provide a recovery point if the
            // process exited after moving a page but before saving its count.
            updateRecord(descriptor: descriptor, error: nil)
            return
        }
        do {
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
            try destination.setResourceValues({ var value = URLResourceValues(); value.isExcludedFromBackup = true; return value }())
            let bytes = Int64((try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            updateImageRecord(descriptor: descriptor, addedFileBytes: bytes)
        } catch {
            updateRecord(descriptor: descriptor, error: error.localizedDescription)
        }
    }

    private func finishEPUBSpine(descriptor: DownloadTaskDescriptor, temporaryURL: URL) {
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        let key = BookKey(serverID: descriptor.serverID, remoteID: descriptor.bookID)
        guard var manifest = EPUBOfflinePackage.loadManifest(for: key),
              let client = clients[descriptor.serverID.description] else {
            updateRecord(descriptor: descriptor, error: "Reconnect this server to continue the EPUB download.")
            return
        }
        do {
            let data = try Data(contentsOf: temporaryURL)
            let raw = try EPUBDocumentBuilder.unwrapServerPage(data)
            let prepared = EPUBDocumentBuilder.prepare(
                fragment: raw,
                preferences: EPUBReaderPreferences(),
                baseURL: client.profile.baseURL
            )
            let destination = EPUBOfflinePackage.spineURL(for: key, index: descriptor.page)
            try prepared.fragment.data(using: .utf8)?.write(
                to: destination,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
            manifest.completedSpineIndexes.insert(descriptor.page)
            let priorResources = Set(manifest.resourceFiles.keys)
            for remoteValue in prepared.resources.values {
                guard let remoteURL = URL(string: remoteValue) else { continue }
                manifest.resourceFiles[remoteValue] = EPUBDocumentBuilder.resourceFileName(for: remoteURL)
            }
            try EPUBOfflinePackage.saveManifest(manifest, for: key)
            let addedResources = Set(manifest.resourceFiles.keys).subtracting(priorResources)
            Task { [weak self] in
                guard let self else { return }
                for remoteValue in addedResources {
                    do {
                        guard let book = cachedBook(key: key) else { continue }
                        let request = try await client.epubResourceRequest(book: book, reference: remoteValue)
                        coordinator.enqueue(
                            request,
                            descriptor: DownloadTaskDescriptor(serverID: key.serverID, bookID: key.remoteID, resourceURL: remoteValue)
                        )
                    } catch {
                        if let current = EPUBOfflinePackage.loadManifest(for: key) {
                            updateEPUBRecord(key: key, manifest: current, error: error.localizedDescription)
                        }
                    }
                }
            }
            updateEPUBRecord(key: key, manifest: manifest, error: nil)
        } catch {
            updateRecord(descriptor: descriptor, error: error.localizedDescription)
        }
    }

    private func finishEPUBResource(descriptor: DownloadTaskDescriptor, temporaryURL: URL) {
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        let key = BookKey(serverID: descriptor.serverID, remoteID: descriptor.bookID)
        guard let remoteValue = descriptor.resourceURL,
              let remoteURL = URL(string: remoteValue),
              var manifest = EPUBOfflinePackage.loadManifest(for: key) else {
            updateRecord(descriptor: descriptor, error: "The EPUB resource manifest is missing.")
            return
        }
        var destination = EPUBOfflinePackage.resourceURL(for: key, remoteURL: remoteURL)
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
            try destination.setResourceValues({ var value = URLResourceValues(); value.isExcludedFromBackup = true; return value }())
            manifest.completedResourceURLs.insert(remoteValue)
            try EPUBOfflinePackage.saveManifest(manifest, for: key)
            updateEPUBRecord(key: key, manifest: manifest, error: nil)
        } catch {
            updateRecord(descriptor: descriptor, error: error.localizedDescription)
        }
    }

    private func resumePendingEPUB(client: ServerClient) async {
        let serverID = client.profile.id.description
        let records = (try? container.mainContext.fetch(
            FetchDescriptor<DownloadRecord>(predicate: #Predicate {
                $0.serverID == serverID && $0.contentKindRaw == "epub"
                    && ($0.stateRaw == "queued" || $0.stateRaw == "downloading")
            })
        )) ?? []
        for record in records {
            guard let server = ServerID(string: record.serverID),
                  let book = cachedBook(key: BookKey(serverID: server, remoteID: record.bookID)),
                  let manifest = EPUBOfflinePackage.loadManifest(for: book.key) else { continue }
            await enqueueMissingEPUBTasks(book: book, manifest: manifest, client: client)
        }
    }

    private func enqueueMissingEPUBTasks(book: Book, manifest: EPUBPackageManifest, client: ServerClient) async {
        let activeDescriptions = Set((await coordinator.tasks()).compactMap(\.taskDescription))
        for index in 0..<manifest.spineCount where !manifest.completedSpineIndexes.contains(index) {
            let descriptor = DownloadTaskDescriptor(serverID: book.key.serverID, bookID: book.key.remoteID, spine: index)
            let encoded = try? JSONEncoder().encode(descriptor).base64EncodedString()
            if let encoded, activeDescriptions.contains(encoded) { continue }
            if let request = try? await client.epubPageRequest(book: book, index: index) {
                coordinator.enqueue(request, descriptor: descriptor)
            }
        }
        for remoteValue in manifest.resourceFiles.keys where !manifest.completedResourceURLs.contains(remoteValue) {
            let descriptor = DownloadTaskDescriptor(serverID: book.key.serverID, bookID: book.key.remoteID, resourceURL: remoteValue)
            let encoded = try? JSONEncoder().encode(descriptor).base64EncodedString()
            if let encoded, activeDescriptions.contains(encoded) { continue }
            if let request = try? await client.epubResourceRequest(book: book, reference: remoteValue) {
                coordinator.enqueue(request, descriptor: descriptor)
            }
        }
    }

    private func cachedBook(key: BookKey) -> Book? {
        let id = key.id
        let descriptor = FetchDescriptor<CachedBookRecord>(predicate: #Predicate { $0.id == id })
        guard let record = try? container.mainContext.fetch(descriptor).first else { return nil }
        return try? JSONDecoder().decode(Book.self, from: record.payload)
    }

    private func updateEPUBRecord(key: BookKey, manifest: EPUBPackageManifest, error: String?) {
        let id = key.id
        let fetch = FetchDescriptor<DownloadRecord>(predicate: #Predicate { $0.id == id })
        guard let record = try? container.mainContext.fetch(fetch).first else { return }
        record.pageCount = manifest.spineCount + manifest.resourceFiles.count
        record.completedPages = manifest.completedSpineIndexes.count + manifest.completedResourceURLs.count
        record.sizeBytes = DownloadPaths.packageSize(for: key)
        let wasComplete = record.state == .complete
        if let error {
            record.lastError = error
            record.state = .failed
        } else if manifest.isComplete {
            record.lastError = nil
            record.state = .complete
        } else if record.lastError != nil {
            record.state = .failed
        } else {
            record.state = .downloading
        }
        if !wasComplete && record.state == .complete { completedDownloadEventCount &+= 1 }
        record.updatedAt = .now
        try? container.mainContext.save()
        refreshCount()
    }

    private func updateRecord(descriptor: DownloadTaskDescriptor, error: String?) {
        let id = BookKey(serverID: descriptor.serverID, remoteID: descriptor.bookID).id
        let fetch = FetchDescriptor<DownloadRecord>(predicate: #Predicate { $0.id == id })
        guard let record = try? container.mainContext.fetch(fetch).first else { return }
        if let error {
            record.state = .failed
            record.lastError = error
        } else {
            let key = BookKey(serverID: descriptor.serverID, remoteID: descriptor.bookID)
            let completed = (0..<record.pageCount).filter { FileManager.default.fileExists(atPath: DownloadPaths.page(PageKey(book: key, index: $0)).path) }.count
            record.completedPages = completed
            record.sizeBytes = DownloadPaths.packageSize(for: key)
            let wasComplete = record.state == .complete
            if completed == record.pageCount {
                record.state = .complete
                record.lastError = nil
            } else if record.lastError != nil {
                record.state = .failed
            } else {
                record.state = .downloading
            }
            if !wasComplete && record.state == .complete { completedDownloadEventCount &+= 1 }
        }
        record.updatedAt = .now
        try? container.mainContext.save()
        refreshCount()
    }

    private func updateImageRecord(descriptor: DownloadTaskDescriptor, addedFileBytes: Int64) {
        let id = BookKey(serverID: descriptor.serverID, remoteID: descriptor.bookID).id
        let fetch = FetchDescriptor<DownloadRecord>(predicate: #Predicate { $0.id == id })
        guard let record = try? container.mainContext.fetch(fetch).first else { return }
        let wasComplete = record.state == .complete
        record.completedPages = DownloadThroughputPolicy.completedPageCount(
            current: record.completedPages,
            pageCount: record.pageCount
        )
        record.sizeBytes = DownloadThroughputPolicy.packageSize(
            current: record.sizeBytes,
            addingFileBytes: addedFileBytes
        )
        if record.completedPages >= max(0, record.pageCount - 1) {
            // Reconcile only at the package boundary. This preserves crash
            // recovery without bringing back a full scan after every page.
            let key = BookKey(serverID: descriptor.serverID, remoteID: descriptor.bookID)
            record.completedPages = (0..<record.pageCount).filter {
                FileManager.default.fileExists(
                    atPath: DownloadPaths.page(PageKey(book: key, index: $0)).path
                )
            }.count
            record.sizeBytes = DownloadPaths.packageSize(for: key)
        }
        if record.completedPages == record.pageCount {
            record.state = .complete
            record.lastError = nil
        } else if record.lastError != nil {
            record.state = .failed
        } else {
            record.state = .downloading
        }
        if !wasComplete && record.state == .complete { completedDownloadEventCount &+= 1 }
        record.updatedAt = .now
        try? container.mainContext.save()
        refreshCount()
    }

    private func refreshCount() {
        let records = (try? container.mainContext.fetch(FetchDescriptor<DownloadRecord>())) ?? []
        activeCount = records.filter { $0.state == .queued || $0.state == .downloading }.count
        pendingActivitySnapshots = records.map(DownloadActivitySnapshot.init)
        guard liveActivityUpdateTask == nil else { return }
        liveActivityUpdateTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, let snapshots = pendingActivitySnapshots {
                pendingActivitySnapshots = nil
                await DownloadLiveActivityCoordinator.shared.sync(snapshots)
                do {
                    // ActivityKit does not need a separate update for every
                    // page. Coalescing to one current snapshot per second
                    // avoids competing with file moves and SwiftData saves.
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    break
                }
            }
            liveActivityUpdateTask = nil
        }
    }
}

private extension NSLock {
    func withLock<T>(_ action: () -> T) -> T {
        lock(); defer { unlock() }
        return action()
    }
}
