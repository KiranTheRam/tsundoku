import Foundation
import CryptoKit
import SwiftData

@Model final class ServerProfileRecord {
    var id: String = ""
    var name: String = ""
    var baseURL: String = ""
    var userID: String = ""
    var username: String = ""
    var isActive: Bool = false
    var providerRaw: String = ServerKind.komga.rawValue
    var modifiedAt: Date = Date()

    init(profile: ServerProfile) {
        id = profile.id.description
        name = profile.name
        baseURL = profile.baseURL.absoluteString
        userID = profile.userID
        username = profile.username
        isActive = profile.isActive
        providerRaw = profile.kind.rawValue
        modifiedAt = .now
    }

    var value: ServerProfile? {
        guard let serverID = ServerID(string: id), let url = URL(string: baseURL) else { return nil }
        return ServerProfile(
            id: serverID,
            name: name,
            baseURL: url,
            userID: userID,
            username: username,
            isActive: isActive,
            kind: ServerKind(rawValue: providerRaw) ?? .komga
        )
    }
}

@Model final class PreferenceRecord {
    var id: String = "global"
    var serverID: String?
    var seriesID: String?
    var encodedPreferences: Data = Data()
    var modifiedAt: Date = Date()

    init(id: String, serverID: String? = nil, seriesID: String? = nil, preferences: ReaderPreferences) {
        self.id = id
        self.serverID = serverID
        self.seriesID = seriesID
        encodedPreferences = (try? JSONEncoder().encode(preferences)) ?? Data()
    }

    init(id: String, encodedValue: Data) {
        self.id = id
        encodedPreferences = encodedValue
    }
}

@Model final class BookmarkRecord {
    var id: String = ""
    var serverID: String = ""
    var bookID: String = ""
    var page: Int = 0
    var locator: String?
    var title: String = ""
    var createdAt: Date = Date()

    init(key: PageKey, title: String) {
        id = key.id
        serverID = key.book.serverID.description
        bookID = key.book.remoteID
        page = key.index
        self.title = title
    }

    init(book: BookKey, page: Int, locator: String, title: String) {
        let locatorID = SHA256.hash(data: Data(locator.utf8)).map { String(format: "%02x", $0) }.joined()
        id = "\(book.id):epub:\(page):\(locatorID)"
        serverID = book.serverID.description
        bookID = book.remoteID
        self.page = page
        self.locator = locator
        self.title = title
    }
}

@Model final class HistoryRecord {
    var id: String = UUID().uuidString
    var serverID: String = ""
    var seriesID: String = ""
    var bookID: String = ""
    var seriesTitle: String = ""
    var bookTitle: String = ""
    var page: Int = 0
    var readAt: Date = Date()

    init(book: Book, seriesTitle: String, page: Int) {
        serverID = book.key.serverID.description
        seriesID = book.seriesKey.remoteID
        bookID = book.key.remoteID
        self.seriesTitle = seriesTitle
        bookTitle = book.displayTitle
        self.page = page
    }
}

@Model final class CachedSeriesRecord {
    var id: String = ""
    var serverID: String = ""
    var remoteID: String = ""
    var libraryID: String = ""
    var title: String = ""
    var payload: Data = Data()
    var cachedAt: Date = Date()

    init(series: Series) {
        id = series.id
        serverID = series.key.serverID.description
        remoteID = series.key.remoteID
        libraryID = series.libraryID
        title = series.title
        payload = (try? JSONEncoder().encode(series)) ?? Data()
    }
}

@Model final class CachedBookRecord {
    var id: String = ""
    var serverID: String = ""
    var remoteID: String = ""
    var seriesID: String = ""
    var payload: Data = Data()
    var cachedAt: Date = Date()

    init(book: Book) {
        id = book.id
        serverID = book.key.serverID.description
        remoteID = book.key.remoteID
        seriesID = book.seriesKey.remoteID
        payload = (try? JSONEncoder().encode(book)) ?? Data()
    }
}

@Model final class PendingProgressRecord {
    var id: String = ""
    var serverID: String = ""
    var bookID: String = ""
    var payload: Data = Data()
    var attempts: Int = 0
    var nextAttemptAt: Date = Date()
    var lastError: String?

    init(checkpoint: ReadingCheckpoint) {
        id = checkpoint.book.id
        serverID = checkpoint.book.serverID.description
        bookID = checkpoint.book.remoteID
        payload = (try? JSONEncoder().encode(checkpoint)) ?? Data()
    }
}

enum DownloadState: String, Codable, CaseIterable {
    case queued, downloading, paused, complete, failed
}

@Model final class DownloadRecord {
    var id: String = ""
    var serverID: String = ""
    var bookID: String = ""
    var seriesTitle: String = ""
    var bookTitle: String = ""
    var bookPayload: Data = Data()
    var seriesReadingDirection: String = "RIGHT_TO_LEFT"
    var seriesTagsPayload: Data = Data()
    var fileHash: String = ""
    var contentKindRaw: String = BookContentKind.images.rawValue
    var pageCount: Int = 0
    var completedPages: Int = 0
    var sizeBytes: Int64 = 0
    var stateRaw: String = DownloadState.queued.rawValue
    var lastError: String?
    var updatedAt: Date = Date()

    init(
        book: Book,
        seriesTitle: String,
        seriesReadingDirection: String = "RIGHT_TO_LEFT",
        seriesTags: [String] = []
    ) {
        id = book.id
        serverID = book.key.serverID.description
        bookID = book.key.remoteID
        self.seriesTitle = seriesTitle
        bookTitle = book.displayTitle
        bookPayload = (try? JSONEncoder().encode(book)) ?? Data()
        self.seriesReadingDirection = seriesReadingDirection
        seriesTagsPayload = (try? JSONEncoder().encode(seriesTags)) ?? Data()
        // Download packages are invalidated by the provider's content revision,
        // which may be more precise than its underlying file hash.
        fileHash = book.contentRevision
        contentKindRaw = book.contentKind.rawValue
        pageCount = book.pageCount
    }

    var state: DownloadState {
        get { DownloadState(rawValue: stateRaw) ?? .failed }
        set { stateRaw = newValue.rawValue }
    }


    var contentKind: BookContentKind {
        get { BookContentKind(rawValue: contentKindRaw) ?? .images }
        set { contentKindRaw = newValue.rawValue }
    }

    var book: Book? { try? JSONDecoder().decode(Book.self, from: bookPayload) }
    var seriesTags: [String] { (try? JSONDecoder().decode([String].self, from: seriesTagsPayload)) ?? [] }
}

@Model final class TrackerLinkRecord {
    var id: String = ""
    var serverID: String = ""
    var seriesID: String = ""
    var service: String = ""
    var mediaID: Int = 0
    var mediaTitle: String = ""
    var encodedRule: Data = Data()
    var lastPushedProgress: Int = 0
    var updatedAt: Date = Date()

    init(serverID: ServerID, seriesID: String, service: String, mediaID: Int, mediaTitle: String, rule: TrackerProgressRule) {
        id = "\(serverID):\(seriesID):\(service)"
        self.serverID = serverID.description
        self.seriesID = seriesID
        self.service = service
        self.mediaID = mediaID
        self.mediaTitle = mediaTitle
        encodedRule = (try? JSONEncoder().encode(rule)) ?? Data()
    }
}

@Model final class TrackerMutationRecord {
    var id: String = UUID().uuidString
    var service: String = ""
    var mediaID: Int = 0
    var progress: Int = 0
    var volumeProgress: Int?
    var status: String = "CURRENT"
    var attempts: Int = 0
    var nextAttemptAt: Date = Date()
    var lastError: String?
    var updatedAt: Date = Date()

    init(service: String, mediaID: Int, progress: Int, volumeProgress: Int? = nil, status: String) {
        self.service = service
        self.mediaID = mediaID
        self.progress = progress
        self.volumeProgress = volumeProgress
        self.status = status
    }
}

extension PendingProgressRecord: Identifiable {}
extension DownloadRecord: Identifiable {}
extension TrackerMutationRecord: Identifiable {}
