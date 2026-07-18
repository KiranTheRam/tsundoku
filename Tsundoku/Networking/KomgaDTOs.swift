import Foundation

struct KomgaUserDTO: Decodable, Sendable {
    let id: String
    let email: String
    let roles: [String]
}

struct KomgaAPIKeyDTO: Decodable, Sendable {
    let id: String
    let key: String
}

struct KomgaLibraryDTO: Decodable, Sendable {
    let id: String
    let name: String
    let unavailable: Bool
}

struct KomgaCollectionDTO: Decodable, Sendable {
    let id: String
    let name: String
    let ordered: Bool
    let seriesIds: [String]
    var domain: CatalogCollection {
        CatalogCollection(id: id, name: name, ordered: ordered, itemCount: seriesIds.count)
    }
}

struct KomgaReadListDTO: Decodable, Sendable {
    let id: String
    let name: String
    let summary: String
    let ordered: Bool
    let bookIds: [String]
    var domain: CatalogReadingList {
        CatalogReadingList(id: id, name: name, summary: summary, ordered: ordered, itemCount: bookIds.count)
    }
}

struct KomgaCollectionPageDTO: Decodable, Sendable {
    let content: [KomgaCollectionDTO]
    let number: Int
    let totalPages: Int
    let totalElements: Int
    let last: Bool
}

struct KomgaReadListPageDTO: Decodable, Sendable {
    let content: [KomgaReadListDTO]
    let number: Int
    let totalPages: Int
    let totalElements: Int
    let last: Bool
}

struct KomgaSeriesPageDTO: Decodable, Sendable {
    let content: [KomgaSeriesDTO]
    let number: Int
    let totalPages: Int
    let totalElements: Int
    let last: Bool
}

struct KomgaSeriesDTO: Decodable, Sendable {
    struct Metadata: Decodable, Sendable {
        let title: String
        let summary: String
        let status: String
        let readingDirection: String
        let genres: [String]
        let tags: [String]
        let links: [WebLink]
    }
    struct WebLink: Decodable, Sendable {
        let label: String
        let url: String
    }

    let id: String
    let libraryId: String
    let name: String
    let metadata: Metadata
    let booksCount: Int
    let booksReadCount: Int
    let booksInProgressCount: Int
    let lastModified: Date?

    func domain(serverID: ServerID) -> Series {
        Series(
            key: SeriesKey(serverID: serverID, remoteID: id),
            libraryID: libraryId,
            title: metadata.title.isEmpty ? name : metadata.title,
            summary: metadata.summary,
            status: metadata.status,
            readingDirection: metadata.readingDirection,
            genres: metadata.genres,
            tags: metadata.tags,
            booksCount: booksCount,
            booksReadCount: booksReadCount,
            booksInProgressCount: booksInProgressCount,
            lastModified: lastModified
        )
    }
}

struct KomgaBookPageDTO: Decodable, Sendable {
    let content: [KomgaBookDTO]
    let number: Int
    let totalPages: Int
    let totalElements: Int
    let last: Bool
}

struct KomgaBookDTO: Decodable, Sendable {
    struct Metadata: Decodable, Sendable {
        let title: String
        let number: String
        let numberSort: Double
    }
    struct Media: Decodable, Sendable {
        let mediaType: String
        let pagesCount: Int
        let status: String
    }
    struct ReadProgress: Decodable, Sendable {
        let page: Int
        let completed: Bool
        let lastModified: Date
    }

    let id: String
    let seriesId: String
    let seriesTitle: String
    let name: String
    let fileHash: String
    let sizeBytes: Int64
    let metadata: Metadata
    let media: Media
    let readProgress: ReadProgress?
    let lastModified: Date?

    func domain(serverID: ServerID) -> Book {
        Book(
            key: BookKey(serverID: serverID, remoteID: id),
            seriesKey: SeriesKey(serverID: serverID, remoteID: seriesId),
            title: metadata.title.isEmpty ? name : metadata.title,
            number: metadata.number,
            numberSort: metadata.numberSort,
            sizeBytes: sizeBytes,
            fileHash: fileHash,
            mediaType: media.mediaType,
            pageCount: media.pagesCount,
            readPage: readProgress?.page,
            completed: readProgress?.completed ?? false,
            readProgressModifiedAt: readProgress?.lastModified,
            lastModified: lastModified
        )
    }
}

struct KomgaPageDTO: Decodable, Sendable {
    let number: Int
    let fileName: String
    let mediaType: String
    let width: Int?
    let height: Int?
    let sizeBytes: Int64?

    var domain: BookPage {
        BookPage(number: number, fileName: fileName, mediaType: mediaType, width: width, height: height, sizeBytes: sizeBytes)
    }
}

extension JSONDecoder {
    static var komga: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            if let date = APIWireDateParser.iso8601(value) { return date }
            throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(), debugDescription: "Invalid ISO-8601 date")
        }
        return decoder
    }
}

enum APIWireDateParser {
    private static let precise = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let basic = Date.ISO8601FormatStyle()

    static func iso8601(_ value: String) -> Date? {
        (try? precise.parse(value)) ?? (try? basic.parse(value))
    }
}
