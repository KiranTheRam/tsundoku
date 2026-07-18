import Foundation
import UIKit

enum PageLoadPriority: Sendable {
    case visible
    case prefetch

    var taskPriority: TaskPriority { self == .visible ? .userInitiated : .utility }
    var urlSessionPriority: Float { self == .visible ? URLSessionTask.highPriority : URLSessionTask.lowPriority }
    var requestTimeout: TimeInterval { self == .visible ? 45 : 90 }
    var maximumAttempts: Int { self == .visible ? 2 : 1 }
}

enum PageLoadRetryPolicy {
    static func shouldRetry(_ error: Error, attempt: Int, priority: PageLoadPriority) -> Bool {
        guard attempt < priority.maximumAttempts, let error = error as? URLError else { return false }
        return [
            .timedOut,
            .networkConnectionLost,
            .cannotFindHost,
            .cannotConnectToHost,
            .dnsLookupFailed,
            .notConnectedToInternet,
            .resourceUnavailable
        ].contains(error.code)
    }
}

actor PageLoader {
    typealias ProgressHandler = @Sendable (Double?) -> Void

    private struct Flight {
        let id: UUID
        let task: Task<Data, Error>
        let progress: PageProgressBroadcaster
        var waiters: Set<UUID>
    }

    private let memory = NSCache<NSString, NSData>()
    private let images = NSCache<NSString, UIImage>()
    private let fileManager = FileManager.default
    private let root: URL
    private let transfer = PageTransferSession()
    private var inFlight: [String: Flight] = [:]

    init() {
        memory.totalCostLimit = 96 * 1024 * 1024
        images.countLimit = 10
        images.totalCostLimit = 96 * 1024 * 1024
        root = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "PageCache", directoryHint: .isDirectory)
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func data(
        for book: Book,
        zeroBasedPage: Int,
        client: ServerClient?,
        priority: PageLoadPriority = .visible,
        progress: @escaping ProgressHandler = { _ in }
    ) async throws -> Data {
        let key = PageKey(book: book.key, index: zeroBasedPage)
        let resourceID = resourceID(for: book, page: key)
        let cacheKey = resourceID as NSString
        if let cached = memory.object(forKey: cacheKey) {
            progress(1)
            return cached as Data
        }
        let downloaded = DownloadPaths.page(key)
        if fileManager.fileExists(atPath: downloaded.path) {
            let data = try Data(contentsOf: downloaded, options: .mappedIfSafe)
            memory.setObject(data as NSData, forKey: cacheKey, cost: data.count)
            progress(1)
            return data
        }
        let disk = cacheURL(for: resourceID)
        if fileManager.fileExists(atPath: disk.path) {
            let data = try Data(contentsOf: disk, options: .mappedIfSafe)
            memory.setObject(data as NSData, forKey: cacheKey, cost: data.count)
            progress(1)
            return data
        }
        guard let client else {
            throw ServerClientError.unsupported("This page is not available in the downloaded package.")
        }
        let waiterID = UUID()
        if var flight = inFlight[resourceID] {
            flight.waiters.insert(waiterID)
            inFlight[resourceID] = flight
            flight.progress.add(waiterID, handler: progress)
            return try await wait(for: flight, resourceID: resourceID, waiterID: waiterID)
        }

        let flightID = UUID()
        let broadcaster = PageProgressBroadcaster()
        broadcaster.add(waiterID, handler: progress)
        let task = Task(priority: priority.taskPriority) { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.fetchAndCache(
                book: book,
                zeroBasedPage: zeroBasedPage,
                client: client,
                priority: priority,
                resourceID: resourceID,
                broadcaster: broadcaster
            )
        }
        let flight = Flight(id: flightID, task: task, progress: broadcaster, waiters: [waiterID])
        inFlight[resourceID] = flight
        return try await wait(for: flight, resourceID: resourceID, waiterID: waiterID)
    }

    func image(
        for book: Book,
        segment: PageSegment,
        cropPolicy: CropPolicy,
        client: ServerClient?,
        priority: PageLoadPriority = .visible,
        progress: @escaping ProgressHandler = { _ in }
    ) async throws -> UIImage? {
        let page = PageKey(book: book.key, index: segment.pageIndex)
        let rect = segment.normalizedCrop
        let imageID = "\(resourceID(for: book, page: page)):\(rect.minX):\(rect.minY):\(rect.width):\(rect.height):\(cropPolicy.rawValue)"
        if let cached = images.object(forKey: imageID as NSString) {
            progress(1)
            return cached
        }
        let bytes = try await data(
            for: book,
            zeroBasedPage: segment.pageIndex,
            client: client,
            priority: priority,
            progress: progress
        )
        let image = await Task.detached(priority: priority.taskPriority) {
            ImageProcessor.image(from: bytes, segment: segment, cropPolicy: cropPolicy)
        }.value
        if let image, let cgImage = image.cgImage {
            images.setObject(
                image,
                forKey: imageID as NSString,
                cost: cgImage.bytesPerRow * cgImage.height
            )
        }
        return image
    }

    func purgeMemory() {
        memory.removeAllObjects()
        images.removeAllObjects()
    }

    private func fetchAndCache(
        book: Book,
        zeroBasedPage: Int,
        client: ServerClient,
        priority: PageLoadPriority,
        resourceID: String,
        broadcaster: PageProgressBroadcaster
    ) async throws -> Data {
        var request = try await client.pageRequest(book: book, zeroBasedPage: zeroBasedPage)
        request.timeoutInterval = priority.requestTimeout
        var attempt = 1
        while true {
            do {
                let data = try await transfer.data(
                    for: request,
                    priority: priority.urlSessionPriority,
                    progress: { broadcaster.report($0) }
                )
                let disk = cacheURL(for: resourceID)
                try? data.write(to: disk, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                memory.setObject(data as NSData, forKey: resourceID as NSString, cost: data.count)
                broadcaster.report(1)
                return data
            } catch {
                guard !Task.isCancelled else { throw CancellationError() }
                guard PageLoadRetryPolicy.shouldRetry(error, attempt: attempt, priority: priority) else { throw error }
                attempt += 1
                broadcaster.report(0)
                try await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func wait(for flight: Flight, resourceID: String, waiterID: UUID) async throws -> Data {
        try await withTaskCancellationHandler {
            do {
                let data = try await flight.task.value
                finishWaiter(resourceID: resourceID, flightID: flight.id, waiterID: waiterID)
                return data
            } catch {
                finishWaiter(resourceID: resourceID, flightID: flight.id, waiterID: waiterID)
                throw error
            }
        } onCancel: {
            Task { await self.cancelWaiter(resourceID: resourceID, flightID: flight.id, waiterID: waiterID) }
        }
    }

    private func finishWaiter(resourceID: String, flightID: UUID, waiterID: UUID) {
        guard var flight = inFlight[resourceID], flight.id == flightID else { return }
        flight.progress.remove(waiterID)
        flight.waiters.remove(waiterID)
        inFlight[resourceID] = flight.waiters.isEmpty ? nil : flight
    }

    private func cancelWaiter(resourceID: String, flightID: UUID, waiterID: UUID) {
        guard var flight = inFlight[resourceID], flight.id == flightID else { return }
        flight.progress.remove(waiterID)
        flight.waiters.remove(waiterID)
        if flight.waiters.isEmpty {
            flight.task.cancel()
            inFlight[resourceID] = nil
        } else {
            inFlight[resourceID] = flight
        }
    }

    private func resourceID(for book: Book, page: PageKey) -> String {
        "\(page.id):\(book.contentRevision)"
    }

    private func cacheURL(for resourceID: String) -> URL {
        let safeName = resourceID.map { character in
            character.isLetter || character.isNumber || character == "-" ? character : "_"
        }
        return root.appending(path: String(safeName) + ".page")
    }
}

private final class PageProgressBroadcaster: @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [UUID: PageLoader.ProgressHandler] = [:]
    private var latest: Double? = 0

    func add(_ id: UUID, handler: @escaping PageLoader.ProgressHandler) {
        let value = lock.withLock {
            handlers[id] = handler
            return latest
        }
        handler(value)
    }

    func remove(_ id: UUID) {
        lock.withLock { handlers[id] = nil }
    }

    func report(_ value: Double?) {
        let callbacks = lock.withLock {
            latest = value
            return Array(handlers.values)
        }
        callbacks.forEach { $0(value) }
    }
}

enum PageLoadingProgress {
    static func fraction(totalBytesWritten: Int64, expectedBytes: Int64) -> Double? {
        guard expectedBytes > 0 else { return nil }
        return min(1, max(0, Double(totalBytesWritten) / Double(expectedBytes)))
    }
}

private final class PageTransferSession: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    typealias ProgressHandler = @Sendable (Double?) -> Void

    private struct Job {
        let continuation: CheckedContinuation<Data, Error>
        let progress: ProgressHandler
    }

    private final class CancellationToken: @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionDownloadTask?
        private var cancelled = false

        func setTask(_ task: URLSessionDownloadTask) -> Bool {
            let shouldCancel = lock.withLock {
                self.task = task
                return cancelled
            }
            if shouldCancel { task.cancel() }
            return !shouldCancel
        }

        func cancel() {
            let task = lock.withLock {
                cancelled = true
                return self.task
            }
            task?.cancel()
        }
    }

    private let lock = NSLock()
    private var jobs: [Int: Job] = [:]
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = 180
        configuration.httpMaximumConnectionsPerHost = 6
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    func data(for request: URLRequest, priority: Float, progress: @escaping ProgressHandler) async throws -> Data {
        let cancellationToken = CancellationToken()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.downloadTask(with: request)
                task.priority = priority
                // Register the continuation before cancellation can reach the
                // URLSession delegate. Otherwise an immediate cancel may finish
                // before the job exists and leave the caller suspended forever.
                lock.withLock {
                    jobs[task.taskIdentifier] = Job(continuation: continuation, progress: progress)
                }
                progress(0)
                _ = cancellationToken.setTask(task)
                task.resume()
            }
        } onCancel: {
            cancellationToken.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let callback = lock.withLock { jobs[downloadTask.taskIdentifier]?.progress }
        callback?(PageLoadingProgress.fraction(totalBytesWritten: totalBytesWritten, expectedBytes: totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let job = removeJob(for: downloadTask.taskIdentifier) else { return }
        do {
            guard let response = downloadTask.response as? HTTPURLResponse else {
                throw ServerClientError.unsupported("The page server returned an invalid response.")
            }
            guard (200..<300).contains(response.statusCode) else {
                let message = HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
                throw ServerClientError.unsupported("Page request failed (\(response.statusCode)): \(message)")
            }
            // The system removes this temporary file after the delegate returns,
            // so the page must own its bytes rather than memory-map the URL.
            let data = try Data(contentsOf: location)
            job.progress(1)
            job.continuation.resume(returning: data)
        } catch {
            job.continuation.resume(throwing: error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let job = removeJob(for: task.taskIdentifier) else { return }
        job.continuation.resume(throwing: error)
    }

    private func removeJob(for taskIdentifier: Int) -> Job? {
        lock.withLock { jobs.removeValue(forKey: taskIdentifier) }
    }
}

private extension NSLock {
    func withLock<T>(_ action: () -> T) -> T {
        lock(); defer { unlock() }
        return action()
    }
}

enum DownloadPaths {
    private static var baseRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Downloads", directoryHint: .isDirectory)
    }

    static var root: URL {
        var url = baseRoot
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return url
    }

    static func book(_ key: BookKey) -> URL {
        let url = root.appending(path: key.serverID.description).appending(path: key.remoteID, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func page(_ key: PageKey) -> URL { book(key.book).appending(path: String(format: "%06d.page", key.index)) }

    static func imageManifest(for key: BookKey) -> [BookPage]? {
        let url = book(key).appending(path: "manifest.json")
        guard let data = try? Data(contentsOf: url),
              let pages = try? JSONDecoder().decode([BookPage].self, from: data),
              !pages.isEmpty else { return nil }
        return pages
    }

    static func packageSize(for key: BookKey) -> Int64 {
        let properties: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: book(key),
            includingPropertiesForKeys: properties,
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(properties)),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    static func removeAll() throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: baseRoot.path) {
            try fileManager.removeItem(at: baseRoot)
        }
    }
}
