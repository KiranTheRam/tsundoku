import Foundation

enum ServerKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case komga
    case kavita

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var minimumVersion: String { self == .komga ? "1.25" : "0.9.0.2" }
}

struct ServerProfile: Hashable, Codable, Sendable, Identifiable {
    let id: ServerID
    var name: String
    var baseURL: URL
    var userID: String
    var username: String
    var isActive: Bool
    var kind: ServerKind

    init(
        id: ServerID,
        name: String,
        baseURL: URL,
        userID: String,
        username: String,
        isActive: Bool,
        kind: ServerKind = .komga
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.userID = userID
        self.username = username
        self.isActive = isActive
        self.kind = kind
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, baseURL, userID, username, isActive, kind
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(ServerID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        baseURL = try values.decode(URL.self, forKey: .baseURL)
        userID = try values.decode(String.self, forKey: .userID)
        username = try values.decode(String.self, forKey: .username)
        isActive = try values.decode(Bool.self, forKey: .isActive)
        kind = try values.decodeIfPresent(ServerKind.self, forKey: .kind) ?? .komga
    }
}

enum LibraryContentType: String, Codable, Hashable, Sendable {
    case manga
    case other
}

struct Library: Hashable, Codable, Sendable, Identifiable {
    let id: String
    let name: String
    let unavailable: Bool
    let contentType: LibraryContentType?

    init(
        id: String,
        name: String,
        unavailable: Bool,
        contentType: LibraryContentType? = nil
    ) {
        self.id = id
        self.name = name
        self.unavailable = unavailable
        self.contentType = contentType
    }
}

struct CatalogCollection: Hashable, Codable, Sendable, Identifiable {
    let id: String
    let name: String
    let ordered: Bool
    let itemCount: Int
}

struct CatalogReadingList: Hashable, Codable, Sendable, Identifiable {
    let id: String
    let name: String
    let summary: String
    let ordered: Bool
    let itemCount: Int
}

enum BookContentKind: String, Codable, Hashable, Sendable {
    case images
    case epub
}

enum TrackerProgressUnit: String, Codable, Hashable, Sendable {
    case chapter
    case volume
}

enum ReaderSequence: Hashable, Codable, Sendable {
    case series(seriesID: String, volumeID: String?)
    case readingList(readingListID: String)
}

struct RemoteBookContext: Hashable, Codable, Sendable {
    let seriesID: String
    let volumeID: String?
    let libraryID: String?
    let chapterID: String
    let sequence: ReaderSequence
    let readingDirection: String?

    init(
        seriesID: String,
        volumeID: String? = nil,
        libraryID: String? = nil,
        chapterID: String,
        sequence: ReaderSequence? = nil,
        readingDirection: String? = nil
    ) {
        self.seriesID = seriesID
        self.volumeID = volumeID
        self.libraryID = libraryID
        self.chapterID = chapterID
        self.sequence = sequence ?? .series(seriesID: seriesID, volumeID: volumeID)
        self.readingDirection = readingDirection
    }
}

struct Series: Hashable, Codable, Sendable, Identifiable {
    let key: SeriesKey
    let libraryID: String
    let title: String
    let summary: String
    let status: String
    let readingDirection: String
    let genres: [String]
    let tags: [String]
    let booksCount: Int
    let booksReadCount: Int
    let booksInProgressCount: Int
    let lastModified: Date?
    let libraryContentType: LibraryContentType?

    var id: String { key.id }
    var unreadCount: Int { max(0, booksCount - booksReadCount) }
    var progress: Double { booksCount == 0 ? 0 : Double(booksReadCount) / Double(booksCount) }

    init(
        key: SeriesKey,
        libraryID: String,
        title: String,
        summary: String,
        status: String,
        readingDirection: String,
        genres: [String],
        tags: [String],
        booksCount: Int,
        booksReadCount: Int,
        booksInProgressCount: Int,
        lastModified: Date?,
        libraryContentType: LibraryContentType? = nil
    ) {
        self.key = key
        self.libraryID = libraryID
        self.title = title
        self.summary = summary
        self.status = status
        self.readingDirection = readingDirection
        self.genres = genres
        self.tags = tags
        self.booksCount = booksCount
        self.booksReadCount = booksReadCount
        self.booksInProgressCount = booksInProgressCount
        self.lastModified = lastModified
        self.libraryContentType = libraryContentType
    }
}

struct Book: Hashable, Codable, Sendable, Identifiable {
    let key: BookKey
    let seriesKey: SeriesKey
    let title: String
    let number: String
    let numberSort: Double
    let sizeBytes: Int64
    let fileHash: String
    let mediaType: String
    let pageCount: Int
    let readPage: Int?
    let completed: Bool
    let readProgressModifiedAt: Date?
    let lastModified: Date?
    let contentKind: BookContentKind
    let remoteContext: RemoteBookContext
    let contentRevision: String
    let trackerProgressUnit: TrackerProgressUnit

    var id: String { key.id }
    var displayTitle: String { title.isEmpty ? "Book \(number)" : title }

    init(
        key: BookKey,
        seriesKey: SeriesKey,
        title: String,
        number: String,
        numberSort: Double,
        sizeBytes: Int64,
        fileHash: String,
        mediaType: String,
        pageCount: Int,
        readPage: Int?,
        completed: Bool,
        readProgressModifiedAt: Date?,
        lastModified: Date?,
        contentKind: BookContentKind = .images,
        remoteContext: RemoteBookContext? = nil,
        contentRevision: String? = nil,
        trackerProgressUnit: TrackerProgressUnit = .chapter
    ) {
        self.key = key
        self.seriesKey = seriesKey
        self.title = title
        self.number = number
        self.numberSort = numberSort
        self.sizeBytes = sizeBytes
        self.fileHash = fileHash
        self.mediaType = mediaType
        self.pageCount = pageCount
        self.readPage = readPage
        self.completed = completed
        self.readProgressModifiedAt = readProgressModifiedAt
        self.lastModified = lastModified
        self.contentKind = contentKind
        self.remoteContext = remoteContext ?? RemoteBookContext(
            seriesID: seriesKey.remoteID,
            chapterID: key.remoteID
        )
        self.contentRevision = contentRevision ?? fileHash
        self.trackerProgressUnit = trackerProgressUnit
    }

    private enum CodingKeys: String, CodingKey {
        case key, seriesKey, title, number, numberSort, sizeBytes, fileHash, mediaType
        case pageCount, readPage, completed, readProgressModifiedAt, lastModified
        case contentKind, remoteContext, contentRevision, trackerProgressUnit
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        key = try values.decode(BookKey.self, forKey: .key)
        seriesKey = try values.decode(SeriesKey.self, forKey: .seriesKey)
        title = try values.decode(String.self, forKey: .title)
        number = try values.decode(String.self, forKey: .number)
        numberSort = try values.decode(Double.self, forKey: .numberSort)
        sizeBytes = try values.decode(Int64.self, forKey: .sizeBytes)
        fileHash = try values.decode(String.self, forKey: .fileHash)
        mediaType = try values.decode(String.self, forKey: .mediaType)
        pageCount = try values.decode(Int.self, forKey: .pageCount)
        readPage = try values.decodeIfPresent(Int.self, forKey: .readPage)
        completed = try values.decode(Bool.self, forKey: .completed)
        readProgressModifiedAt = try values.decodeIfPresent(Date.self, forKey: .readProgressModifiedAt)
        lastModified = try values.decodeIfPresent(Date.self, forKey: .lastModified)
        contentKind = try values.decodeIfPresent(BookContentKind.self, forKey: .contentKind) ?? .images
        remoteContext = try values.decodeIfPresent(RemoteBookContext.self, forKey: .remoteContext)
            ?? RemoteBookContext(seriesID: seriesKey.remoteID, chapterID: key.remoteID)
        contentRevision = try values.decodeIfPresent(String.self, forKey: .contentRevision) ?? fileHash
        trackerProgressUnit = try values.decodeIfPresent(TrackerProgressUnit.self, forKey: .trackerProgressUnit) ?? .chapter
    }

    func withSequence(_ sequence: ReaderSequence) -> Book {
        Book(
            key: key,
            seriesKey: seriesKey,
            title: title,
            number: number,
            numberSort: numberSort,
            sizeBytes: sizeBytes,
            fileHash: fileHash,
            mediaType: mediaType,
            pageCount: pageCount,
            readPage: readPage,
            completed: completed,
            readProgressModifiedAt: readProgressModifiedAt,
            lastModified: lastModified,
            contentKind: contentKind,
            remoteContext: RemoteBookContext(
                seriesID: remoteContext.seriesID,
                volumeID: remoteContext.volumeID,
                libraryID: remoteContext.libraryID,
                chapterID: remoteContext.chapterID,
                sequence: sequence,
                readingDirection: remoteContext.readingDirection
            ),
            contentRevision: contentRevision,
            trackerProgressUnit: trackerProgressUnit
        )
    }
}

struct BookPage: Hashable, Codable, Sendable, Identifiable {
    /// Provider-neutral page identity. This is always one-based; request
    /// adapters convert to a provider's wire indexing at the network boundary.
    let number: Int
    let fileName: String
    let mediaType: String
    let width: Int?
    let height: Int?
    let sizeBytes: Int64?

    var id: Int { number }
    var aspectRatio: Double {
        guard let width, let height, height > 0 else { return 0.7 }
        return Double(width) / Double(height)
    }
    var isWide: Bool { aspectRatio > 1.2 }
}

struct PageResult<Element: Sendable>: Sendable {
    let content: [Element]
    let page: Int
    let totalPages: Int
    let totalElements: Int
    let isLast: Bool
}

enum LoadState<Value> {
    case idle
    case loading
    case loaded(Value)
    case failed(String)
}
