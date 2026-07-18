import Foundation
import Observation
import SwiftData
import UIKit

struct ProgressSyncNotice: Identifiable, Equatable, Sendable {
    enum State: Equatable, Sendable {
        case syncing
        case succeeded
        case failed(String)
    }

    enum Operation: Equatable, Sendable {
        case progress(page: Int)
        case markRead(title: String)
        case markUnread(title: String)
    }

    let id = UUID()
    let state: State
    let operation: Operation
    let providerName: String

    init(state: State, page: Int, providerName: String) {
        self.state = state
        operation = .progress(page: page)
        self.providerName = providerName
    }

    init(state: State, operation: Operation, providerName: String) {
        self.state = state
        self.operation = operation
        self.providerName = providerName
    }
}

enum ProgressNoticePolicy: Equatable, Sendable {
    case silent
    case afterReaderExit
}

@MainActor @Observable
final class ProgressCoordinator {
    private let container: ModelContainer
    private let mergePolicy = ProgressMergePolicy()
    @ObservationIgnored private var debounceTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var retryTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var noticeDismissTask: Task<Void, Never>?
    @ObservationIgnored private var backgroundFlushTask: Task<Void, Never>?
    @ObservationIgnored private var backgroundTaskIdentifier: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var noticeCheckpoints: [String: ReadingCheckpoint] = [:]
    @ObservationIgnored var onAcknowledged: ((ReadingCheckpoint) async -> Void)?
    private(set) var syncProblemCount = 0
    private(set) var syncNotice: ProgressSyncNotice?

    init(modelContainer: ModelContainer) {
        container = modelContainer
        refreshProblemCount()
    }

    func record(
        _ checkpoint: ReadingCheckpoint,
        client: ServerClient,
        immediate: Bool = false,
        noticePolicy: ProgressNoticePolicy = .silent
    ) {
        persist(checkpoint)
        if noticePolicy == .afterReaderExit {
            noticeCheckpoints[checkpoint.book.id] = checkpoint
        }
        retryTasks[checkpoint.book.id]?.cancel()
        retryTasks[checkpoint.book.id] = nil
        debounceTasks[checkpoint.book.id]?.cancel()
        debounceTasks[checkpoint.book.id] = Task { [weak self] in
            if !immediate { try? await Task.sleep(for: .seconds(2)) }
            guard !Task.isCancelled else { return }
            await self?.flush(checkpoint, client: client)
        }
    }

    /// Persists a checkpoint while its content server is unavailable. The
    /// normal activation path retries this durable mutation after reconnecting.
    func recordOffline(_ checkpoint: ReadingCheckpoint) {
        persist(checkpoint)
        retryTasks[checkpoint.book.id]?.cancel()
        retryTasks[checkpoint.book.id] = nil
        debounceTasks[checkpoint.book.id]?.cancel()
        debounceTasks[checkpoint.book.id] = nil
    }

    func retryAll(client: ServerClient) async {
        let records = (try? container.mainContext.fetch(FetchDescriptor<PendingProgressRecord>())) ?? []
        for record in records {
            guard let checkpoint = try? JSONDecoder().decode(ReadingCheckpoint.self, from: record.payload), checkpoint.book.serverID == client.profile.id else { continue }
            retryTasks[checkpoint.book.id]?.cancel()
            retryTasks[checkpoint.book.id] = nil
            await flush(checkpoint, client: client)
        }
    }

    /// Restores durable retry timers without bypassing the persisted backoff.
    /// Explicit Retry All and final reader-exit flushes intentionally use
    /// `retryAll(client:)` to force an immediate attempt.
    func retryPending(client: ServerClient, now: Date = .now) async {
        let records = (try? container.mainContext.fetch(FetchDescriptor<PendingProgressRecord>())) ?? []
        for record in records {
            guard let checkpoint = try? JSONDecoder().decode(ReadingCheckpoint.self, from: record.payload),
                  checkpoint.book.serverID == client.profile.id else { continue }
            if record.nextAttemptAt <= now {
                await flush(checkpoint, client: client)
            } else {
                scheduleRetry(checkpoint, client: client, at: record.nextAttemptAt)
            }
        }
    }

    func intentionalRewind(book: Book, toOneBasedPage page: Int, client: ServerClient) {
        let checkpoint = ReadingCheckpoint(book: book, zeroBasedPage: max(0, page - 1), intentionalRegression: true)
        record(checkpoint, client: client, immediate: true)
    }

    @discardableResult
    func setReadStatus(book: Book, read: Bool, client: ServerClient) async -> Bool {
        let operation: ProgressSyncNotice.Operation = read
            ? .markRead(title: book.displayTitle)
            : .markUnread(title: book.displayTitle)
        cancelPendingProgress(for: book.key)
        showNotice(.init(state: .syncing, operation: operation, providerName: client.providerName))
        do {
            if read {
                try await client.markRead(book: book)
                let checkpoint = ReadingCheckpoint(
                    book: book,
                    zeroBasedPage: max(0, book.pageCount - 1),
                    completed: true
                )
                await onAcknowledged?(checkpoint)
            } else {
                try await client.markUnread(book: book)
            }
            showNotice(.init(state: .succeeded, operation: operation, providerName: client.providerName), dismissAfter: .seconds(3.5))
            return true
        } catch {
            guard ProgressSyncFailurePolicy.shouldReport(error) else { return false }
            showNotice(.init(state: .failed(error.localizedDescription), operation: operation, providerName: client.providerName), dismissAfter: .seconds(6))
            return false
        }
    }

    func pendingCheckpoint(for book: BookKey) -> ReadingCheckpoint? {
        let id = book.id
        let descriptor = FetchDescriptor<PendingProgressRecord>(predicate: #Predicate { $0.id == id })
        guard let record = try? container.mainContext.fetch(descriptor).first else { return nil }
        return try? JSONDecoder().decode(ReadingCheckpoint.self, from: record.payload)
    }

    /// Gives the final checkpoint a finite iOS background-execution window.
    /// The pending SwiftData record remains durable if the request cannot finish.
    func beginBackgroundFlush(client: ServerClient) {
        guard backgroundFlushTask == nil else { return }
        backgroundTaskIdentifier = UIApplication.shared.beginBackgroundTask(withName: "Tsundoku read progress") { [weak self] in
            Task { @MainActor in self?.finishBackgroundFlush(cancel: true) }
        }
        backgroundFlushTask = Task { [weak self] in
            guard let self else { return }
            await self.flushAllImmediately(client: client)
            self.finishBackgroundFlush(cancel: false)
        }
    }

    func flushAllImmediately(client: ServerClient) async {
        debounceTasks.values.forEach { $0.cancel() }
        debounceTasks.removeAll()
        await retryAll(client: client)
    }

    func prepareForDeviceReset() {
        debounceTasks.values.forEach { $0.cancel() }
        retryTasks.values.forEach { $0.cancel() }
        debounceTasks.removeAll()
        retryTasks.removeAll()
        noticeDismissTask?.cancel()
        noticeDismissTask = nil
        noticeCheckpoints.removeAll()
        syncNotice = nil
        finishBackgroundFlush(cancel: true)
        syncProblemCount = 0
    }

    private func persist(_ checkpoint: ReadingCheckpoint) {
        let context = container.mainContext
        let id = checkpoint.book.id
        let descriptor = FetchDescriptor<PendingProgressRecord>(predicate: #Predicate { $0.id == id })
        if let existing = try? context.fetch(descriptor).first {
            if let prior = try? JSONDecoder().decode(ReadingCheckpoint.self, from: existing.payload), prior.observedAt > checkpoint.observedAt {
                return
            }
            existing.payload = (try? JSONEncoder().encode(checkpoint)) ?? existing.payload
            existing.attempts = 0
            existing.nextAttemptAt = .now
            existing.lastError = nil
        } else {
            context.insert(PendingProgressRecord(checkpoint: checkpoint))
        }
        try? context.save()
        refreshProblemCount()
    }

    private func cancelPendingProgress(for book: BookKey) {
        debounceTasks[book.id]?.cancel()
        debounceTasks[book.id] = nil
        retryTasks[book.id]?.cancel()
        retryTasks[book.id] = nil
        noticeCheckpoints[book.id] = nil
        let context = container.mainContext
        let id = book.id
        let descriptor = FetchDescriptor<PendingProgressRecord>(predicate: #Predicate { $0.id == id })
        if let record = try? context.fetch(descriptor).first {
            context.delete(record)
            try? context.save()
        }
        refreshProblemCount()
    }

    private func flush(_ checkpoint: ReadingCheckpoint, client: ServerClient) async {
        do {
            guard isCurrent(checkpoint) else { return }
            if shouldShowNotice(for: checkpoint) {
                showNotice(.init(state: .syncing, page: checkpoint.page, providerName: client.providerName))
            }
            let book = resolvedBook(for: checkpoint)
            let remote = try await client.remoteProgress(for: book)
            guard isCurrent(checkpoint) else { return }
            let resolution = mergePolicy.resolve(
                local: checkpoint,
                remotePage: remote.position,
                remoteCompleted: remote.completed,
                remoteObservedAt: remote.modifiedAt
            )
            switch resolution {
            case .keepRemote:
                break
            case .pushLocal:
                try await client.markProgress(book: book, position: checkpoint.page, locator: checkpoint.epubLocator)
            case .pushCompletion:
                try await client.markProgress(book: book, position: checkpoint.page, completed: true, locator: checkpoint.epubLocator)
            case .pushRegression:
                if client.capabilities.regressionRequiresReset {
                    try await client.markUnread(book: book)
                    if checkpoint.page > 1 {
                        try await client.markProgress(book: book, position: checkpoint.page, locator: checkpoint.epubLocator)
                    }
                } else {
                    try await client.markProgress(book: book, position: checkpoint.page, locator: checkpoint.epubLocator)
                }
            }
            guard isCurrent(checkpoint) else { return }
            retryTasks[checkpoint.book.id]?.cancel()
            retryTasks[checkpoint.book.id] = nil
            deleteRecord(matching: checkpoint)
            // Tracker updates are downstream of an acknowledged local write.
            // A newer server checkpoint merely resolves the queue and must not
            // publish the superseded local checkpoint to a tracker.
            if resolution != .keepRemote { await onAcknowledged?(checkpoint) }
            if consumeNoticeRequest(for: checkpoint) {
                showNotice(.init(state: .succeeded, page: checkpoint.page, providerName: client.providerName), dismissAfter: .seconds(3.5))
            }
        } catch {
            // An immediate background flush deliberately cancels the pending
            // debounce and retries the same durable checkpoint. Cancellation is
            // coordination, not a content-server failure, and must never flash an error
            // before the replacement request succeeds.
            guard ProgressSyncFailurePolicy.shouldReport(error) else { return }
            if isCurrent(checkpoint) {
                if let nextAttemptAt = updateFailure(id: checkpoint.book.id, error: error) {
                    scheduleRetry(checkpoint, client: client, at: nextAttemptAt)
                }
                if consumeNoticeRequest(for: checkpoint) {
                    showNotice(.init(state: .failed(error.localizedDescription), page: checkpoint.page, providerName: client.providerName), dismissAfter: .seconds(6))
                }
            }
        }
    }

    private func shouldShowNotice(for checkpoint: ReadingCheckpoint) -> Bool {
        noticeCheckpoints[checkpoint.book.id] == checkpoint
    }

    private func resolvedBook(for checkpoint: ReadingCheckpoint) -> Book {
        let id = checkpoint.book.id
        let descriptor = FetchDescriptor<CachedBookRecord>(predicate: #Predicate { $0.id == id })
        if let record = try? container.mainContext.fetch(descriptor).first,
           let value = try? JSONDecoder().decode(Book.self, from: record.payload) {
            return value
        }
        let context = checkpoint.remoteContext ?? RemoteBookContext(
            seriesID: "",
            chapterID: checkpoint.book.remoteID
        )
        return Book(
            key: checkpoint.book,
            seriesKey: SeriesKey(serverID: checkpoint.book.serverID, remoteID: context.seriesID),
            title: "Book \(checkpoint.book.remoteID)",
            number: "",
            numberSort: 0,
            sizeBytes: 0,
            fileHash: "",
            mediaType: "application/octet-stream",
            pageCount: checkpoint.pageCount,
            readPage: nil,
            completed: false,
            readProgressModifiedAt: nil,
            lastModified: nil,
            contentKind: checkpoint.epubLocator == nil ? .images : .epub,
            remoteContext: context
        )
    }

    private func consumeNoticeRequest(for checkpoint: ReadingCheckpoint) -> Bool {
        guard shouldShowNotice(for: checkpoint) else { return false }
        noticeCheckpoints[checkpoint.book.id] = nil
        return true
    }

    private func showNotice(_ notice: ProgressSyncNotice, dismissAfter duration: Duration? = nil) {
        noticeDismissTask?.cancel()
        syncNotice = notice
        guard let duration else { return }
        noticeDismissTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, self?.syncNotice?.id == notice.id else { return }
            self?.syncNotice = nil
        }
    }

    private func finishBackgroundFlush(cancel: Bool) {
        if cancel { backgroundFlushTask?.cancel() }
        backgroundFlushTask = nil
        if backgroundTaskIdentifier != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskIdentifier)
            backgroundTaskIdentifier = .invalid
        }
    }

    private func isCurrent(_ checkpoint: ReadingCheckpoint) -> Bool {
        let id = checkpoint.book.id
        let descriptor = FetchDescriptor<PendingProgressRecord>(predicate: #Predicate { $0.id == id })
        guard let record = try? container.mainContext.fetch(descriptor).first,
              let current = try? JSONDecoder().decode(ReadingCheckpoint.self, from: record.payload) else { return false }
        return current == checkpoint
    }

    private func deleteRecord(matching checkpoint: ReadingCheckpoint) {
        let context = container.mainContext
        let id = checkpoint.book.id
        let descriptor = FetchDescriptor<PendingProgressRecord>(predicate: #Predicate { $0.id == id })
        if let record = try? context.fetch(descriptor).first,
           let current = try? JSONDecoder().decode(ReadingCheckpoint.self, from: record.payload),
           current == checkpoint {
            context.delete(record)
        }
        try? context.save()
        refreshProblemCount()
    }

    private func updateFailure(id: String, error: Error) -> Date? {
        let context = container.mainContext
        let descriptor = FetchDescriptor<PendingProgressRecord>(predicate: #Predicate { $0.id == id })
        if let record = try? context.fetch(descriptor).first {
            record.attempts += 1
            record.lastError = error.localizedDescription
            let seconds = ProgressRetryPolicy.delay(attempts: record.attempts)
            record.nextAttemptAt = Date().addingTimeInterval(seconds)
            try? context.save()
            refreshProblemCount()
            return record.nextAttemptAt
        }
        refreshProblemCount()
        return nil
    }

    private func scheduleRetry(_ checkpoint: ReadingCheckpoint, client: ServerClient, at date: Date) {
        let id = checkpoint.book.id
        retryTasks[id]?.cancel()
        retryTasks[id] = Task { [weak self] in
            let delay = max(0, date.timeIntervalSinceNow)
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            await self?.flush(checkpoint, client: client)
        }
    }

    private func refreshProblemCount() {
        syncProblemCount = ((try? container.mainContext.fetchCount(FetchDescriptor<PendingProgressRecord>())) ?? 0)
    }
}

enum ProgressRetryPolicy {
    static func delay(attempts: Int) -> TimeInterval {
        min(pow(2, Double(max(0, attempts))) * 5, 3_600)
    }
}

enum ProgressSyncFailurePolicy {
    static func shouldReport(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if let urlError = error as? URLError, urlError.code == .cancelled { return false }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return false }
        return true
    }
}
