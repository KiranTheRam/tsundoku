import Foundation

struct ServerCapabilities: Hashable, Sendable {
    let supportsEPUB: Bool
    let supportsPasswordLogin: Bool
    let collectionsAreLibraryScoped: Bool
    let readingListsAreLibraryScoped: Bool
    let regressionRequiresReset: Bool
}

enum ServerClientError: LocalizedError {
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let message): message
        }
    }
}

struct ServerClient: Sendable {
    private enum Backend: Sendable {
        case komga(KomgaClient)
        case kavita(KavitaClient)
    }

    let profile: ServerProfile
    private let backend: Backend

    init(komga: KomgaClient, profile: ServerProfile) {
        self.profile = profile
        backend = .komga(komga)
    }

    init(kavita: KavitaClient, profile: ServerProfile) {
        self.profile = profile
        backend = .kavita(kavita)
    }

    var kind: ServerKind { profile.kind }
    var providerName: String { profile.kind.title }

    var capabilities: ServerCapabilities {
        switch kind {
        case .komga:
            ServerCapabilities(
                supportsEPUB: false,
                supportsPasswordLogin: true,
                collectionsAreLibraryScoped: true,
                readingListsAreLibraryScoped: true,
                regressionRequiresReset: true
            )
        case .kavita:
            ServerCapabilities(
                supportsEPUB: true,
                supportsPasswordLogin: false,
                collectionsAreLibraryScoped: false,
                readingListsAreLibraryScoped: false,
                regressionRequiresReset: false
            )
        }
    }

    func libraries() async throws -> [Library] {
        switch backend {
        case .komga(let client): try await client.libraries()
        case .kavita(let client): try await client.libraries()
        }
    }

    func collections(page: Int = 0, pageSize: Int = 100, libraryID: String? = nil) async throws -> PageResult<CatalogCollection> {
        switch backend {
        case .komga(let client): try await client.collections(page: page, pageSize: pageSize, libraryID: libraryID)
        case .kavita(let client): try await client.collections(page: page, pageSize: pageSize)
        }
    }

    func collectionSeries(collectionID: String, page: Int = 0, pageSize: Int = 100) async throws -> PageResult<Series> {
        switch backend {
        case .komga(let client): try await client.collectionSeries(collectionID: collectionID, page: page, pageSize: pageSize)
        case .kavita(let client): try await client.collectionSeries(collectionID: collectionID, page: page, pageSize: pageSize)
        }
    }

    func readLists(page: Int = 0, pageSize: Int = 100, libraryID: String? = nil) async throws -> PageResult<CatalogReadingList> {
        switch backend {
        case .komga(let client): try await client.readLists(page: page, pageSize: pageSize, libraryID: libraryID)
        case .kavita(let client): try await client.readLists(page: page, pageSize: pageSize)
        }
    }

    func readListBooks(readListID: String, page: Int = 0, pageSize: Int = 200) async throws -> PageResult<Book> {
        switch backend {
        case .komga(let client):
            let page = try await client.readListBooks(readListID: readListID, page: page, pageSize: pageSize)
            return PageResult(
                content: page.content.map { $0.withSequence(.readingList(readingListID: readListID)) },
                page: page.page,
                totalPages: page.totalPages,
                totalElements: page.totalElements,
                isLast: page.isLast
            )
        case .kavita(let client): return try await client.readListBooks(readListID: readListID, page: page, pageSize: pageSize)
        }
    }

    func series(
        page: Int = 0,
        pageSize: Int = 40,
        libraryID: String? = nil,
        search: String? = nil,
        sort: String = "metadata.titleSort,asc"
    ) async throws -> PageResult<Series> {
        switch backend {
        case .komga(let client): try await client.series(page: page, pageSize: pageSize, libraryID: libraryID, search: search, sort: sort)
        case .kavita(let client): try await client.series(page: page, pageSize: pageSize, libraryID: libraryID, search: search)
        }
    }

    func updatedSeries(page: Int = 0, pageSize: Int = 24, libraryID: String? = nil) async throws -> PageResult<Series> {
        switch backend {
        case .komga(let client): try await client.updatedSeries(page: page, pageSize: pageSize, libraryID: libraryID)
        case .kavita(let client): try await client.updatedSeries(page: page, pageSize: pageSize, libraryID: libraryID)
        }
    }

    func series(id: String) async throws -> Series {
        switch backend {
        case .komga(let client): try await client.series(id: id)
        case .kavita(let client): try await client.series(id: id)
        }
    }

    func books(seriesID: String, page: Int = 0, pageSize: Int = 200) async throws -> PageResult<Book> {
        switch backend {
        case .komga(let client): try await client.books(seriesID: seriesID, page: page, pageSize: pageSize)
        case .kavita(let client): try await client.books(seriesID: seriesID, page: page, pageSize: pageSize)
        }
    }

    func book(id: String) async throws -> Book {
        switch backend {
        case .komga(let client): try await client.book(id: id)
        case .kavita(let client): try await client.book(id: id)
        }
    }

    func adjacentBook(from book: Book, next: Bool) async throws -> Book {
        switch backend {
        case .komga(let client): try await client.adjacentBook(from: book.key.remoteID, next: next)
        case .kavita(let client): try await client.adjacentBook(from: book, next: next)
        }
    }

    func pages(book: Book) async throws -> [BookPage] {
        switch backend {
        case .komga(let client): try await client.pages(bookID: book.key.remoteID)
        case .kavita(let client): try await client.pages(book: book)
        }
    }

    func posterData(seriesID: String) async throws -> Data {
        switch backend {
        case .komga(let client): try await client.posterData(seriesID: seriesID)
        case .kavita(let client): try await client.posterData(seriesID: seriesID)
        }
    }

    func pageRequest(book: Book, zeroBasedPage: Int) async throws -> URLRequest {
        switch backend {
        case .komga(let client):
            try await client.authenticatedRequest(
                path: "api/v1/books/\(book.key.remoteID)/pages/\(zeroBasedPage)",
                queryItems: [.init(name: "zero_based", value: "true")],
                accept: "image/*"
            )
        case .kavita(let client): try await client.pageRequest(book: book, zeroBasedPage: zeroBasedPage)
        }
    }

    func remoteProgress(for book: Book) async throws -> RemoteProgress {
        switch backend {
        case .komga(let client):
            let remote = try await client.book(id: book.key.remoteID)
            return RemoteProgress(
                position: remote.readPage,
                completed: remote.completed,
                modifiedAt: remote.readProgressModifiedAt,
                epubLocator: nil
            )
        case .kavita(let client): return try await client.remoteProgress(for: book)
        }
    }

    func markProgress(book: Book, position: Int, completed: Bool = false, locator: String? = nil) async throws {
        switch backend {
        case .komga(let client): try await client.markProgress(bookID: book.key.remoteID, page: position, completed: completed)
        case .kavita(let client): try await client.markProgress(book: book, position: position, completed: completed, locator: locator)
        }
    }

    func markRead(book: Book) async throws {
        switch backend {
        case .komga(let client): try await client.markProgress(bookID: book.key.remoteID, page: book.pageCount, completed: true)
        case .kavita(let client): try await client.markRead(book: book)
        }
    }

    func markUnread(book: Book) async throws {
        switch backend {
        case .komga(let client): try await client.markUnread(bookID: book.key.remoteID)
        case .kavita(let client): try await client.markUnread(book: book)
        }
    }

    func epubInfo(book: Book) async throws -> KavitaBookInfoDTO {
        switch backend {
        case .komga: throw ServerClientError.unsupported("Komga does not expose prepared EPUB content.")
        case .kavita(let client): try await client.epubInfo(book: book)
        }
    }

    func epubTableOfContents(book: Book) async throws -> [EPUBTableOfContentsItem] {
        switch backend {
        case .komga: throw ServerClientError.unsupported("Komga does not expose prepared EPUB content.")
        case .kavita(let client): try await client.epubTableOfContents(book: book)
        }
    }

    func epubPage(book: Book, index: Int) async throws -> String {
        switch backend {
        case .komga: throw ServerClientError.unsupported("Komga does not expose prepared EPUB content.")
        case .kavita(let client): try await client.epubPage(book: book, index: index)
        }
    }

    func epubPageRequest(book: Book, index: Int) async throws -> URLRequest {
        switch backend {
        case .komga: throw ServerClientError.unsupported("Komga does not expose prepared EPUB content.")
        case .kavita(let client): try await client.epubPageRequest(book: book, index: index)
        }
    }

    func epubResourceRequest(book: Book, reference: String) async throws -> URLRequest {
        switch backend {
        case .komga: throw ServerClientError.unsupported("Komga does not expose prepared EPUB content.")
        case .kavita(let client): try await client.epubResourceRequest(book: book, reference: reference)
        }
    }

    func data(for request: URLRequest) async throws -> Data {
        switch backend {
        case .komga: throw ServerClientError.unsupported("This resource request is unavailable for Komga.")
        case .kavita(let client): try await client.data(for: request)
        }
    }
}
