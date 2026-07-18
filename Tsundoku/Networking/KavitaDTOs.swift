import Foundation

struct KavitaUserDTO: Decodable, Sendable {
    let id: Int
    let username: String?
    let email: String?
}

struct KavitaAuthKeyExpiryDTO: Decodable, Sendable {
    let expiresAt: Date?
}

struct KavitaLibraryDTO: Decodable, Sendable {
    let id: Int
    let name: String?
    let type: Int

    var domain: Library {
        Library(
            id: String(id),
            name: name ?? "Library \(id)",
            unavailable: false,
            contentType: type == KavitaLibraryType.manga.rawValue ? .manga : .other
        )
    }
}

struct KavitaSeriesDTO: Decodable, Sendable {
    let id: Int
    let name: String?
    let localizedName: String?
    let sortName: String?
    let pages: Int
    let pagesRead: Int
    let libraryId: Int
    let lastChapterAddedUtc: Date?

    func domain(
        serverID: ServerID,
        libraryType: Int?,
        metadata: KavitaSeriesMetadataDTO? = nil,
        detail: KavitaSeriesDetailDTO? = nil
    ) -> Series {
        let totalCount = detail?.totalCount ?? (pages > 0 ? 1 : 0)
        let unreadCount = detail?.unreadCount ?? (pagesRead < pages ? totalCount : 0)
        let readCount = max(0, totalCount - unreadCount)
        let inProgress = pagesRead > 0 && pagesRead < pages ? 1 : 0
        return Series(
            key: SeriesKey(serverID: serverID, remoteID: String(id)),
            libraryID: String(libraryId),
            title: [localizedName, name, sortName].compactMap { $0?.nilIfEmpty }.first ?? "Series \(id)",
            summary: metadata?.summary ?? "",
            status: metadata?.publicationStatus.title ?? "",
            readingDirection: libraryType == KavitaLibraryType.manga.rawValue ? "RIGHT_TO_LEFT" : "LEFT_TO_RIGHT",
            genres: metadata?.genres?.compactMap(\.title) ?? [],
            tags: metadata?.tags?.compactMap(\.title) ?? [],
            booksCount: totalCount,
            booksReadCount: readCount,
            booksInProgressCount: inProgress,
            lastModified: lastChapterAddedUtc,
            libraryContentType: libraryType == KavitaLibraryType.manga.rawValue ? .manga : .other
        )
    }
}

struct KavitaSeriesMetadataDTO: Decodable, Sendable {
    struct NamedValue: Decodable, Sendable { let title: String? }
    let summary: String?
    let genres: [NamedValue]?
    let tags: [NamedValue]?
    let publicationStatus: Int
}

struct KavitaSeriesDetailDTO: Decodable, Sendable {
    let specials: [KavitaChapterDTO]?
    let chapters: [KavitaChapterDTO]?
    let volumes: [KavitaVolumeDTO]?
    let storylineChapters: [KavitaChapterDTO]?
    let unreadCount: Int
    let totalCount: Int

    struct ChapterEntry: Sendable {
        let chapter: KavitaChapterDTO
        let volumeTitle: String?
        let volumeNumber: Double?
    }

    var allChapterEntries: [ChapterEntry] {
        let volumeCandidates = (volumes ?? []).flatMap { volume in
            (volume.chapters ?? []).map {
                ChapterEntry(chapter: $0, volumeTitle: volume.name, volumeNumber: volume.number)
            }
        }
        let unscopedCandidates = ((chapters ?? []) + (storylineChapters ?? []) + (specials ?? []))
            .map { ChapterEntry(chapter: $0, volumeTitle: nil, volumeNumber: nil) }
        var seen = Set<Int>()
        return (volumeCandidates + unscopedCandidates)
            .filter { seen.insert($0.chapter.id).inserted }
            .sorted { lhs, rhs in
                let leftOrder = lhs.chapter.effectiveSortOrder(parentVolumeNumber: lhs.volumeNumber)
                let rightOrder = rhs.chapter.effectiveSortOrder(parentVolumeNumber: rhs.volumeNumber)
                if leftOrder == rightOrder { return lhs.chapter.id < rhs.chapter.id }
                return leftOrder < rightOrder
            }
    }

    var allChapters: [KavitaChapterDTO] { allChapterEntries.map(\.chapter) }
}

struct KavitaVolumeDTO: Decodable, Sendable {
    let id: Int
    let seriesId: Int
    let name: String?
    let number: Double?
    let chapters: [KavitaChapterDTO]?
}

struct KavitaMangaFileDTO: Decodable, Sendable {
    let id: Int
    let pages: Int
    let bytes: Int64
    let format: Int
    let filePath: String?
    let `extension`: String?
    let koreaderHash: String?

    var displayName: String? {
        guard let filePath = filePath?.nilIfEmpty else { return nil }
        return URL(fileURLWithPath: filePath).lastPathComponent.nilIfEmpty
    }
}

struct KavitaChapterDTO: Decodable, Sendable {
    let id: Int
    let range: String?
    let minNumber: Double
    let sortOrder: Double
    let pages: Int
    let isSpecial: Bool
    let title: String?
    let titleName: String?
    let files: [KavitaMangaFileDTO]?
    let pagesRead: Int
    let lastReadingProgressUtc: Date?
    let volumeId: Int
    let lastModifiedUtc: Date?
    let volumeTitle: String?
    let format: Int

    func domain(
        serverID: ServerID,
        seriesID: Int,
        libraryID: Int,
        libraryType: Int? = nil,
        sequence: ReaderSequence? = nil,
        parentVolumeTitle: String? = nil,
        parentVolumeNumber: Double? = nil
    ) -> Book {
        let file = files?.first
        let resolvedFormat = file?.format ?? format
        let pageCount = max(1, max(pages, file?.pages ?? 0))
        let progressDate = lastReadingProgressUtc?.meaningfulKavitaProgressDate
        let hasProgress = KavitaProgressPolicy.hasProgress(rawPage: pagesRead)
        let normalizedPage = hasProgress ? KavitaProgressPolicy.normalizedPosition(rawPage: pagesRead, pageCount: pageCount) : nil
        let completed = KavitaProgressPolicy.isComplete(rawPage: pagesRead, pageCount: pageCount)
        let contentKind: BookContentKind = resolvedFormat == KavitaMangaFormat.epub.rawValue ? .epub : .images
        let revision = file?.koreaderHash?.nilIfEmpty
            ?? lastModifiedUtc?.ISO8601Format()
            ?? "kavita-\(id)-\(pageCount)"
        let label = KavitaBookNaming.resolve(
            chapterTitle: title,
            titleName: titleName,
            chapterNumber: range,
            minNumber: minNumber,
            sortOrder: sortOrder,
            volumeTitle: volumeTitle?.nilIfEmpty ?? parentVolumeTitle?.nilIfEmpty,
            volumeNumber: parentVolumeNumber.map(KavitaBookNaming.displayNumber),
            fileName: file?.displayName,
            fallbackID: String(id)
        )
        return Book(
            key: BookKey(serverID: serverID, remoteID: String(id)),
            seriesKey: SeriesKey(serverID: serverID, remoteID: String(seriesID)),
            title: label.title,
            number: label.number,
            numberSort: label.sortOrder,
            sizeBytes: file?.bytes ?? 0,
            fileHash: revision,
            mediaType: resolvedFormat.mediaType,
            pageCount: pageCount,
            readPage: normalizedPage,
            completed: completed,
            readProgressModifiedAt: hasProgress ? progressDate : nil,
            lastModified: lastModifiedUtc,
            contentKind: contentKind,
            remoteContext: RemoteBookContext(
                seriesID: String(seriesID),
                volumeID: String(volumeId),
                libraryID: String(libraryID),
                chapterID: String(id),
                sequence: sequence,
                readingDirection: libraryType == KavitaLibraryType.manga.rawValue ? "RIGHT_TO_LEFT" : "LEFT_TO_RIGHT"
            ),
            contentRevision: revision,
            trackerProgressUnit: label.trackerProgressUnit
        )
    }

    func effectiveSortOrder(parentVolumeNumber: Double?) -> Double {
        KavitaBookNaming.isVolumeArchive(chapterNumber: range, minNumber: minNumber)
            ? parentVolumeNumber ?? sortOrder
            : sortOrder
    }
}

struct KavitaBookLabel: Equatable, Sendable {
    let title: String
    let number: String
    let sortOrder: Double
    let trackerProgressUnit: TrackerProgressUnit

    init(
        title: String,
        number: String,
        sortOrder: Double,
        trackerProgressUnit: TrackerProgressUnit = .chapter
    ) {
        self.title = title
        self.number = number
        self.sortOrder = sortOrder
        self.trackerProgressUnit = trackerProgressUnit
    }
}

enum KavitaBookNaming {
    private static let volumeArchiveSentinel = -100_000.0

    static func isVolumeArchive(chapterNumber: String?, minNumber: Double?) -> Bool {
        if let chapterNumber = chapterNumber?.nilIfEmpty {
            return Double(chapterNumber) == volumeArchiveSentinel
        }
        return minNumber == volumeArchiveSentinel
    }

    static func resolve(
        chapterTitle: String?,
        titleName: String?,
        chapterNumber: String?,
        minNumber: Double?,
        sortOrder: Double,
        volumeTitle: String?,
        volumeNumber: String?,
        fileName: String?,
        fallbackID: String
    ) -> KavitaBookLabel {
        let normalizedVolumeNumber = meaningfulValue(volumeNumber)
        let normalizedVolumeTitle = meaningfulValue(volumeTitle)
        // Kavita also uses -100000 for standalone books. Those entries have no
        // real volume metadata, so they must retain their book/file title.
        let isVolume = isVolumeArchive(chapterNumber: chapterNumber, minNumber: minNumber)
            && (normalizedVolumeNumber != nil || normalizedVolumeTitle != nil)
        if isVolume {
            let title = normalizedVolumeTitle
                ?? normalizedVolumeNumber.map { "Volume \($0)" }
                ?? fileTitle(fileName)
                ?? meaningfulValue(titleName)
                ?? meaningfulValue(chapterTitle)
                ?? "Volume"
            let number = normalizedVolumeNumber ?? normalizedVolumeTitle ?? fallbackID
            return KavitaBookLabel(
                title: title,
                number: number,
                sortOrder: normalizedVolumeNumber.flatMap(Double.init) ?? sortOrder,
                trackerProgressUnit: .volume
            )
        }

        let chapterLabel = meaningfulValue(chapterNumber)
        let minimumLabel = minNumber.flatMap { $0 == volumeArchiveSentinel ? nil : displayNumber($0) }
        let title = [
            meaningfulValue(titleName),
            meaningfulValue(chapterTitle),
            fileTitle(fileName),
            chapterLabel
        ].compactMap { $0 }.first ?? "Book \(fallbackID)"
        let hasSentinel = isVolumeArchive(chapterNumber: chapterNumber, minNumber: minNumber)
            || minNumber == volumeArchiveSentinel
        let number = chapterLabel ?? minimumLabel ?? (hasSentinel ? title : fallbackID)
        return KavitaBookLabel(title: title, number: number, sortOrder: sortOrder)
    }

    static func displayNumber(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(value)
    }

    private static func meaningfulValue(_ value: String?) -> String? {
        guard let value = value?.nilIfEmpty else { return nil }
        if Double(value) == volumeArchiveSentinel { return nil }
        let compact = value.lowercased().filter { !$0.isWhitespace }
        let synthetic = [
            "chapter-100000", "chapter-100000.0",
            "book-100000", "book-100000.0",
            "volume-100000", "volume-100000.0"
        ]
        return synthetic.contains(compact) ? nil : value
    }

    private static func fileTitle(_ value: String?) -> String? {
        guard let value = value?.nilIfEmpty else { return nil }
        let name = URL(fileURLWithPath: value).lastPathComponent
        return URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent.nilIfEmpty
    }

}

struct KavitaChapterInfoDTO: Decodable, Sendable {
    let chapterNumber: String?
    let volumeNumber: String?
    let volumeId: Int
    let seriesName: String?
    let seriesFormat: Int
    let seriesId: Int
    let libraryId: Int
    let libraryType: Int
    let chapterTitle: String?
    let pages: Int
    let fileName: String?
    let pageDimensions: [KavitaFileDimensionDTO]?
}

struct KavitaFileDimensionDTO: Decodable, Sendable {
    let width: Int
    let height: Int
    let pageNumber: Int
    let fileName: String?
}

struct KavitaProgressDTO: Codable, Sendable {
    let volumeId: Int
    let chapterId: Int
    let pageNum: Int
    let seriesId: Int
    let libraryId: Int
    let bookScrollId: String?
    let lastModifiedUtc: Date?

    init(
        volumeId: Int,
        chapterId: Int,
        pageNum: Int,
        seriesId: Int,
        libraryId: Int,
        bookScrollId: String?,
        lastModifiedUtc: Date? = nil
    ) {
        self.volumeId = volumeId
        self.chapterId = chapterId
        self.pageNum = pageNum
        self.seriesId = seriesId
        self.libraryId = libraryId
        self.bookScrollId = bookScrollId
        self.lastModifiedUtc = lastModifiedUtc
    }
}

struct KavitaBookInfoDTO: Decodable, Sendable {
    let bookTitle: String?
    let seriesId: Int
    let volumeId: Int
    let seriesFormat: Int
    let seriesName: String?
    let chapterNumber: String?
    let volumeNumber: String?
    let libraryId: Int
    let pages: Int
    let chapterTitle: String?
}

struct EPUBTableOfContentsItem: Codable, Hashable, Sendable, Identifiable {
    let title: String
    let part: String?
    let page: Int
    let children: [EPUBTableOfContentsItem]

    var id: String { "\(page):\(part ?? ""):\(title)" }

    private enum CodingKeys: String, CodingKey { case title, part, page, children }

    init(title: String, part: String?, page: Int, children: [EPUBTableOfContentsItem] = []) {
        self.title = title
        self.part = part
        self.page = page
        self.children = children
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        title = try values.decodeIfPresent(String.self, forKey: .title) ?? "Section"
        part = try values.decodeIfPresent(String.self, forKey: .part)
        page = try values.decodeIfPresent(Int.self, forKey: .page) ?? 0
        children = try values.decodeIfPresent([EPUBTableOfContentsItem].self, forKey: .children) ?? []
    }
}

struct KavitaCollectionDTO: Decodable, Sendable {
    let id: Int
    let title: String?
    let itemCount: Int
}

struct KavitaReadingListDTO: Decodable, Sendable {
    let id: Int
    let title: String?
    let summary: String?
    let itemCount: Int
}

struct KavitaReadingListItemDTO: Decodable, Sendable {
    struct Chapter: Decodable, Sendable {
        let id: Int
        let range: String?
        let titleName: String?
        let minNumber: Double
        let sortOrder: Double
        let pages: Int
        let isSpecial: Bool
    }

    struct Volume: Decodable, Sendable {
        let id: Int
        let seriesId: Int
        let name: String?
        let number: Double?
    }

    let order: Int
    let chapterId: Int
    let seriesId: Int
    let seriesName: String?
    let seriesFormat: Int
    let pagesRead: Int
    let volumeId: Int
    let libraryId: Int
    let title: String?
    let lastReadingProgressUtc: Date?
    let chapter: Chapter?
    let volume: Volume?

    func domain(serverID: ServerID, readingListID: String, libraryType: Int?) -> Book {
        let chapter = chapter
        let pageCount = max(1, chapter?.pages ?? 1)
        let progressDate = lastReadingProgressUtc?.meaningfulKavitaProgressDate
        let hasProgress = KavitaProgressPolicy.hasProgress(rawPage: pagesRead)
        let contentKind: BookContentKind = seriesFormat == KavitaMangaFormat.epub.rawValue ? .epub : .images
        let label = KavitaBookNaming.resolve(
            chapterTitle: title,
            titleName: chapter?.titleName,
            chapterNumber: chapter?.range,
            minNumber: chapter?.minNumber,
            sortOrder: chapter?.sortOrder ?? Double(order),
            volumeTitle: volume?.name,
            volumeNumber: volume?.number.map(KavitaBookNaming.displayNumber),
            fileName: nil,
            fallbackID: chapter == nil ? String(order + 1) : String(chapterId)
        )
        return Book(
            key: BookKey(serverID: serverID, remoteID: String(chapterId)),
            seriesKey: SeriesKey(serverID: serverID, remoteID: String(seriesId)),
            title: label.title,
            number: label.number,
            numberSort: label.sortOrder,
            sizeBytes: 0,
            fileHash: "kavita-\(chapterId)-\(pageCount)",
            mediaType: seriesFormat.mediaType,
            pageCount: pageCount,
            readPage: hasProgress ? KavitaProgressPolicy.normalizedPosition(rawPage: pagesRead, pageCount: pageCount) : nil,
            completed: KavitaProgressPolicy.isComplete(rawPage: pagesRead, pageCount: pageCount),
            readProgressModifiedAt: hasProgress ? progressDate : nil,
            lastModified: nil,
            contentKind: contentKind,
            remoteContext: RemoteBookContext(
                seriesID: String(seriesId),
                volumeID: String(volumeId),
                libraryID: String(libraryId),
                chapterID: String(chapterId),
                sequence: .readingList(readingListID: readingListID),
                readingDirection: libraryType == KavitaLibraryType.manga.rawValue ? "RIGHT_TO_LEFT" : "LEFT_TO_RIGHT"
            ),
            trackerProgressUnit: label.trackerProgressUnit
        )
    }
}

struct KavitaSearchGroupDTO: Decodable, Sendable {
    struct Result: Decodable, Sendable { let seriesId: Int }
    let series: [Result]?
}

struct KavitaGroupedSeriesDTO: Decodable, Sendable {
    let seriesId: Int
}

struct KavitaPagination: Decodable, Sendable {
    let currentPage: Int
    let totalPages: Int
    let totalItems: Int
    let itemsPerPage: Int
}

enum KavitaLibraryType: Int, Sendable { case manga = 0 }
enum KavitaMangaFormat: Int, Sendable { case image = 0, archive = 1, unknown = 2, epub = 3, pdf = 4 }

enum KavitaProgressPolicy {
    /// Kavita keeps an AppUserProgress row when Mark Unread sets PagesRead to
    /// zero. Its modification timestamp therefore cannot distinguish unread
    /// from started; only a positive raw page represents resumable progress.
    static func hasProgress(rawPage: Int) -> Bool {
        rawPage > 0
    }

    static func normalizedPosition(rawPage: Int, pageCount: Int) -> Int {
        guard pageCount > 0 else { return 1 }
        return min(pageCount, max(0, rawPage) + 1)
    }

    static func rawPage(position: Int, pageCount: Int, completed: Bool) -> Int {
        completed ? max(0, pageCount) : max(0, min(pageCount - 1, position - 1))
    }

    static func isComplete(rawPage: Int, pageCount: Int) -> Bool {
        pageCount > 0 && rawPage >= pageCount
    }
}

extension Int {
    var mediaType: String {
        switch KavitaMangaFormat(rawValue: self) {
        case .epub: "application/epub+zip"
        case .pdf: "application/pdf"
        case .archive: "application/x-comic-book"
        case .image: "image/*"
        case .unknown, .none: "application/octet-stream"
        }
    }
}

private extension Int {
    var title: String {
        switch self {
        case 0: "Ongoing"
        case 1: "Hiatus"
        case 2: "Completed"
        case 3: "Cancelled"
        case 4: "Ended"
        default: ""
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

extension Date {
    var meaningfulKavitaProgressDate: Date? {
        self > Date(timeIntervalSince1970: 0) ? self : nil
    }
}

extension JSONDecoder {
    static var kavita: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            if let date = APIWireDateParser.iso8601(value) { return date }
            for format in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSSS", "yyyy-MM-dd'T'HH:mm:ss"] {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.calendar = Calendar(identifier: .gregorian)
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.dateFormat = format
                if let date = formatter.date(from: value) { return date }
            }
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Invalid Kavita date"
            )
        }
        return decoder
    }
}

extension JSONEncoder {
    static var kavita: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
