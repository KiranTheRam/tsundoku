import Foundation

enum KavitaClientError: LocalizedError, Equatable {
    case invalidResponse
    case unauthorized
    case forbidden
    case unsupportedVersion(found: String, minimum: String)
    case expiredAuthKey
    case missingRemoteContext
    case server(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "Kavita returned an invalid response."
        case .unauthorized: "The Kavita Auth Key was rejected."
        case .forbidden: "This Kavita account cannot perform that action."
        case .unsupportedVersion(let found, let minimum):
            "Kavita \(found) is unsupported. Tsundoku requires Kavita \(minimum) or newer."
        case .expiredAuthKey: "The Kavita Auth Key has expired. Create a new Auth Key in Kavita."
        case .missingRemoteContext: "This cached item is missing the Kavita identifiers needed for that action. Refresh the series and try again."
        case .server(let status, let message): "Kavita error \(status): \(message)"
        }
    }
}

struct KavitaVersion: Comparable, Equatable, CustomStringConvertible, Sendable {
    let components: [Int]

    init?(_ value: String) {
        let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: "\" \r\n\t"))
        let values = trimmed.split(separator: ".").compactMap { Int($0) }
        guard !values.isEmpty, values.count == trimmed.split(separator: ".").count else { return nil }
        components = values
    }

    var description: String { components.map(String.init).joined(separator: ".") }

    static func < (lhs: KavitaVersion, rhs: KavitaVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    static func == (lhs: KavitaVersion, rhs: KavitaVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }
}

struct KavitaConnection: Sendable {
    let user: KavitaUserDTO
    let version: KavitaVersion
    let authKeyExpiresAt: Date?
}

actor KavitaClient {
    static let minimumVersion = KavitaVersion("0.9.0.2")!

    let profile: ServerProfile
    private let authKey: String
    private let deviceID: String
    private let userAgent: String
    private let session: URLSession
    private let decoder = JSONDecoder.kavita
    private var libraryTypes: [Int: Int] = [:]

    init(
        profile: ServerProfile,
        authKey: String,
        deviceID: String,
        userAgent: String = "Tsundoku-iOS/1.0",
        session: URLSession? = nil
    ) {
        self.profile = profile
        self.authKey = authKey
        self.deviceID = deviceID
        self.userAgent = userAgent
        self.session = session ?? Self.makeSession()
    }

    func validateConnection(now: Date = .now) async throws -> KavitaConnection {
        async let versionTask = version()
        async let userTask = currentUser()
        async let expiryTask = authKeyExpiry()
        let (version, user, expiry) = try await (versionTask, userTask, expiryTask)
        guard version >= Self.minimumVersion else {
            throw KavitaClientError.unsupportedVersion(
                found: version.description,
                minimum: Self.minimumVersion.description
            )
        }
        if let expiry, expiry <= now { throw KavitaClientError.expiredAuthKey }
        return KavitaConnection(user: user, version: version, authKeyExpiresAt: expiry)
    }

    func version() async throws -> KavitaVersion {
        let data = try await request(
            path: "api/Plugin/version",
            queryItems: [.init(name: "apiKey", value: authKey)],
            accept: "text/plain, application/json"
        ).data
        guard let value = String(data: data, encoding: .utf8), let version = KavitaVersion(value) else {
            throw KavitaClientError.invalidResponse
        }
        return version
    }

    func currentUser() async throws -> KavitaUserDTO {
        let response = try await request(path: "api/Account")
        return try decoder.decode(KavitaUserDTO.self, from: response.data)
    }

    func authKeyExpiry() async throws -> Date? {
        let response = try await request(path: "api/Plugin/authkey-expires")
        return try decoder.decode(KavitaAuthKeyExpiryDTO.self, from: response.data).expiresAt
    }

    func libraries() async throws -> [Library] {
        let response = try await request(path: "api/Library/libraries")
        let values = try decoder.decode([KavitaLibraryDTO].self, from: response.data)
        libraryTypes = Dictionary(uniqueKeysWithValues: values.map { ($0.id, $0.type) })
        return values.map(\.domain)
    }

    func series(
        page: Int = 0,
        pageSize: Int = 40,
        libraryID: String? = nil,
        search: String? = nil
    ) async throws -> PageResult<Series> {
        if let search, !search.isEmpty { return try await searchSeries(search, pageSize: pageSize) }
        var statements: [[String: Any]] = []
        if let libraryID {
            statements.append(["comparison": 0, "field": 19, "value": libraryID])
        }
        let body: [String: Any] = [
            "statements": statements,
            "combination": 1,
            "sortOptions": ["sortField": 1, "isAscending": true],
            "entityType": 0,
            "limitTo": 0
        ]
        let response = try await request(
            path: "api/Series/all-v2",
            method: "POST",
            queryItems: [
                .init(name: "PageNumber", value: String(page + 1)),
                .init(name: "PageSize", value: String(pageSize))
            ],
            jsonObject: body
        )
        let values = try decoder.decode([KavitaSeriesDTO].self, from: response.data)
        try await ensureLibraryTypes()
        let pagination = pagination(from: response.response, fallbackPage: page, itemCount: values.count, pageSize: pageSize)
        return PageResult(
            content: values.map { $0.domain(serverID: profile.id, libraryType: libraryTypes[$0.libraryId]) },
            page: max(0, pagination.currentPage - 1),
            totalPages: pagination.totalPages,
            totalElements: pagination.totalItems,
            isLast: pagination.currentPage >= pagination.totalPages
        )
    }

    func updatedSeries(page: Int = 0, pageSize: Int = 24, libraryID: String? = nil) async throws -> PageResult<Series> {
        let response = try await request(
            path: "api/Series/recently-updated-series",
            method: "POST",
            queryItems: [
                .init(name: "PageNumber", value: String(page + 1)),
                .init(name: "PageSize", value: String(pageSize))
            ],
            jsonObject: [:]
        )
        let grouped = try decoder.decode([KavitaGroupedSeriesDTO].self, from: response.data)
        var seen = Set<Int>()
        let ids = grouped.map(\.seriesId).filter { seen.insert($0).inserted }
        let values = try await seriesByIDs(ids)
        try await ensureLibraryTypes()
        let filtered = values.filter { libraryID == nil || String($0.libraryId) == libraryID }
        let pagination = pagination(from: response.response, fallbackPage: page, itemCount: filtered.count, pageSize: pageSize)
        return PageResult(
            content: filtered.map { $0.domain(serverID: profile.id, libraryType: libraryTypes[$0.libraryId]) },
            page: max(0, pagination.currentPage - 1),
            totalPages: pagination.totalPages,
            totalElements: pagination.totalItems,
            isLast: pagination.currentPage >= pagination.totalPages
        )
    }

    func series(id: String) async throws -> Series {
        async let valueTask = request(path: "api/Series/\(id)")
        async let metadataTask = request(path: "api/Series/metadata", queryItems: [.init(name: "seriesId", value: id)])
        async let detailTask = request(path: "api/Series/series-detail", queryItems: [.init(name: "seriesId", value: id)])
        let (valueResponse, metadataResponse, detailResponse) = try await (valueTask, metadataTask, detailTask)
        let value = try decoder.decode(KavitaSeriesDTO.self, from: valueResponse.data)
        let metadata = try decoder.decode(KavitaSeriesMetadataDTO.self, from: metadataResponse.data)
        let detail = try decoder.decode(KavitaSeriesDetailDTO.self, from: detailResponse.data)
        try await ensureLibraryTypes()
        return value.domain(serverID: profile.id, libraryType: libraryTypes[value.libraryId], metadata: metadata, detail: detail)
    }

    func books(seriesID: String, page: Int = 0, pageSize: Int = 200) async throws -> PageResult<Book> {
        async let seriesTask = request(path: "api/Series/\(seriesID)")
        async let detailTask = request(path: "api/Series/series-detail", queryItems: [.init(name: "seriesId", value: seriesID)])
        let (seriesResponse, detailResponse) = try await (seriesTask, detailTask)
        let series = try decoder.decode(KavitaSeriesDTO.self, from: seriesResponse.data)
        let detail = try decoder.decode(KavitaSeriesDetailDTO.self, from: detailResponse.data)
        try await ensureLibraryTypes()
        let values = detail.allChapterEntries.map { entry in
            entry.chapter.domain(
                serverID: profile.id,
                seriesID: series.id,
                libraryID: series.libraryId,
                libraryType: libraryTypes[series.libraryId],
                parentVolumeTitle: entry.volumeTitle,
                parentVolumeNumber: entry.volumeNumber
            )
        }
        let start = min(values.count, page * pageSize)
        let end = min(values.count, start + pageSize)
        let content = start < end ? Array(values[start..<end]) : []
        let totalPages = max(1, Int(ceil(Double(values.count) / Double(max(1, pageSize)))))
        return PageResult(content: content, page: page, totalPages: totalPages, totalElements: values.count, isLast: page + 1 >= totalPages)
    }

    func book(id: String) async throws -> Book {
        async let infoTask = chapterInfo(chapterID: id, includeDimensions: false)
        async let progressTask = progress(chapterID: id)
        let (info, progress) = try await (infoTask, progressTask)
        let pageCount = max(1, info.pages)
        let modifiedAt = progress.lastModifiedUtc?.meaningfulKavitaProgressDate
        let hasProgress = KavitaProgressPolicy.hasProgress(rawPage: progress.pageNum)
        let normalized = hasProgress ? KavitaProgressPolicy.normalizedPosition(rawPage: progress.pageNum, pageCount: pageCount) : nil
        let contentKind: BookContentKind = info.seriesFormat == KavitaMangaFormat.epub.rawValue ? .epub : .images
        let label = KavitaBookNaming.resolve(
            chapterTitle: info.chapterTitle,
            titleName: nil,
            chapterNumber: info.chapterNumber,
            minNumber: info.chapterNumber.flatMap(Double.init),
            sortOrder: Double(info.chapterNumber ?? "") ?? 0,
            volumeTitle: nil,
            volumeNumber: info.volumeNumber,
            fileName: info.fileName,
            fallbackID: id
        )
        return Book(
            key: BookKey(serverID: profile.id, remoteID: id),
            seriesKey: SeriesKey(serverID: profile.id, remoteID: String(info.seriesId)),
            title: label.title,
            number: label.number,
            numberSort: label.sortOrder,
            sizeBytes: 0,
            fileHash: "kavita-\(id)-\(info.fileName ?? "")-\(pageCount)",
            mediaType: info.seriesFormat.mediaType,
            pageCount: pageCount,
            readPage: normalized,
            completed: KavitaProgressPolicy.isComplete(rawPage: progress.pageNum, pageCount: pageCount),
            readProgressModifiedAt: hasProgress ? modifiedAt : nil,
            lastModified: nil,
            contentKind: contentKind,
            remoteContext: RemoteBookContext(
                seriesID: String(info.seriesId),
                volumeID: String(info.volumeId),
                libraryID: String(info.libraryId),
                chapterID: id,
                readingDirection: info.libraryType == KavitaLibraryType.manga.rawValue ? "RIGHT_TO_LEFT" : "LEFT_TO_RIGHT"
            ),
            trackerProgressUnit: label.trackerProgressUnit
        )
    }

    func adjacentBook(from book: Book, next: Bool) async throws -> Book {
        let context = book.remoteContext
        let path: String
        let query: [URLQueryItem]
        switch context.sequence {
        case .series:
            path = "api/Reader/\(next ? "next-chapter" : "prev-chapter")"
            query = [
                .init(name: "seriesId", value: context.seriesID),
                .init(name: "volumeId", value: context.volumeID),
                .init(name: "currentChapterId", value: context.chapterID)
            ]
        case .readingList(let readingListID):
            path = "api/ReadingList/\(next ? "next-chapter" : "prev-chapter")"
            query = [
                .init(name: "currentChapterId", value: context.chapterID),
                .init(name: "readingListId", value: readingListID)
            ]
        }
        let data = try await request(path: path, queryItems: query).data
        let id = try decoder.decode(Int.self, from: data)
        guard id > 0 else { throw KavitaClientError.server(status: 404, message: "No adjacent chapter") }
        return try await self.book(id: String(id)).withSequence(context.sequence)
    }

    func pages(book: Book) async throws -> [BookPage] {
        let info = try await chapterInfo(chapterID: book.remoteContext.chapterID, includeDimensions: true, extractPDF: book.mediaType == "application/pdf")
        let dimensions = Dictionary(uniqueKeysWithValues: (info.pageDimensions ?? []).map { ($0.pageNumber, $0) })
        return (0..<max(0, info.pages)).map { index in
            let dimension = dimensions[index]
            return BookPage(
                // BookPage.number is provider-neutral and one-based. The
                // Kavita image API remains zero-based at the request boundary.
                number: index + 1,
                fileName: dimension?.fileName ?? "page-\(index)",
                mediaType: "image/*",
                width: dimension?.width,
                height: dimension?.height,
                sizeBytes: nil
            )
        }
    }

    func posterData(seriesID: String) async throws -> Data {
        try await request(
            path: "api/Image/series-cover",
            // Kavita's image controller explicitly binds the plug-in key from
            // the query string rather than the normal authenticated API header.
            // This URL is used only for the immediate request and is never
            // persisted or handed to an image view/cache key.
            queryItems: [
                .init(name: "seriesId", value: seriesID),
                .init(name: "apiKey", value: authKey)
            ],
            accept: "image/*",
            cachePolicy: .reloadIgnoringLocalCacheData
        ).data
    }

    func pageRequest(book: Book, zeroBasedPage: Int) throws -> URLRequest {
        try authenticatedRequest(
            path: "api/Reader/image",
            queryItems: [
                .init(name: "chapterId", value: book.remoteContext.chapterID),
                .init(name: "page", value: String(zeroBasedPage)),
                .init(name: "extractPdf", value: String(book.mediaType == "application/pdf")),
                // Kavita's image action requires its plug-in key as an
                // explicit bound query field even when x-api-key is present.
                // The URL is used only by the immediate/background transfer
                // and is never persisted in Tsundoku's catalog or descriptors.
                .init(name: "apiKey", value: authKey)
            ],
            accept: "image/*"
        )
    }

    func remoteProgress(for book: Book) async throws -> RemoteProgress {
        let value = try await progress(chapterID: book.remoteContext.chapterID)
        let modifiedAt = value.lastModifiedUtc?.meaningfulKavitaProgressDate
        let hasProgress = KavitaProgressPolicy.hasProgress(rawPage: value.pageNum)
        return RemoteProgress(
            position: hasProgress ? KavitaProgressPolicy.normalizedPosition(rawPage: value.pageNum, pageCount: book.pageCount) : nil,
            completed: KavitaProgressPolicy.isComplete(rawPage: value.pageNum, pageCount: book.pageCount),
            modifiedAt: hasProgress ? modifiedAt : nil,
            epubLocator: hasProgress ? value.bookScrollId : nil
        )
    }

    func markProgress(book: Book, position: Int, completed: Bool, locator: String?) async throws {
        guard let context = numericContext(book.remoteContext) else { throw KavitaClientError.missingRemoteContext }
        let payload = KavitaProgressDTO(
            volumeId: context.volume,
            chapterId: context.chapter,
            pageNum: KavitaProgressPolicy.rawPage(position: position, pageCount: book.pageCount, completed: completed),
            seriesId: context.series,
            libraryId: context.library,
            bookScrollId: locator
        )
        _ = try await request(path: "api/Reader/progress", method: "POST", body: JSONEncoder.kavita.encode(payload))
    }

    func markRead(book: Book) async throws {
        guard let seriesID = Int(book.remoteContext.seriesID), let chapterID = Int(book.remoteContext.chapterID) else {
            throw KavitaClientError.missingRemoteContext
        }
        _ = try await request(
            path: "api/Reader/mark-chapter-read",
            method: "POST",
            jsonObject: ["seriesId": seriesID, "chapterId": chapterID, "generateReadingSession": true]
        )
    }

    func markUnread(book: Book) async throws {
        guard let seriesID = Int(book.remoteContext.seriesID),
              let chapterID = Int(book.remoteContext.chapterID) else {
            throw KavitaClientError.missingRemoteContext
        }
        _ = try await request(
            path: "api/Reader/mark-multiple-unread",
            method: "POST",
            jsonObject: [
                "seriesId": seriesID,
                "volumeIds": [Int](),
                "chapterIds": [chapterID]
            ]
        )
    }

    func collections(page: Int = 0, pageSize: Int = 100) async throws -> PageResult<CatalogCollection> {
        let response = try await request(path: "api/Collection")
        let values = try decoder.decode([KavitaCollectionDTO].self, from: response.data)
        let content = values.map { CatalogCollection(id: String($0.id), name: $0.title ?? "Collection \($0.id)", ordered: false, itemCount: $0.itemCount) }
        return unpaged(content, page: page, pageSize: pageSize)
    }

    func collectionSeries(collectionID: String, page: Int = 0, pageSize: Int = 100) async throws -> PageResult<Series> {
        let response = try await request(
            path: "api/Series/series-by-collection",
            queryItems: [
                .init(name: "collectionId", value: collectionID),
                .init(name: "PageNumber", value: String(page + 1)),
                .init(name: "PageSize", value: String(pageSize))
            ]
        )
        let values = try decoder.decode([KavitaSeriesDTO].self, from: response.data)
        try await ensureLibraryTypes()
        let pagination = pagination(from: response.response, fallbackPage: page, itemCount: values.count, pageSize: pageSize)
        return PageResult(
            content: values.map { $0.domain(serverID: profile.id, libraryType: libraryTypes[$0.libraryId]) },
            page: max(0, pagination.currentPage - 1), totalPages: pagination.totalPages,
            totalElements: pagination.totalItems, isLast: pagination.currentPage >= pagination.totalPages
        )
    }

    func readLists(page: Int = 0, pageSize: Int = 100) async throws -> PageResult<CatalogReadingList> {
        let response = try await request(
            path: "api/ReadingList/all",
            method: "POST",
            queryItems: [
                .init(name: "PageNumber", value: String(page + 1)),
                .init(name: "PageSize", value: String(pageSize))
            ],
            jsonObject: [
                "statements": [], "combination": 1,
                "sortOptions": ["sortField": 1, "isAscending": true],
                "entityType": 1, "limitTo": 0
            ]
        )
        let values = try decoder.decode([KavitaReadingListDTO].self, from: response.data)
        let pagination = pagination(from: response.response, fallbackPage: page, itemCount: values.count, pageSize: pageSize)
        return PageResult(
            content: values.map { CatalogReadingList(id: String($0.id), name: $0.title ?? "Reading List \($0.id)", summary: $0.summary ?? "", ordered: true, itemCount: $0.itemCount) },
            page: max(0, pagination.currentPage - 1), totalPages: pagination.totalPages,
            totalElements: pagination.totalItems, isLast: pagination.currentPage >= pagination.totalPages
        )
    }

    func readListBooks(readListID: String, page: Int = 0, pageSize: Int = 200) async throws -> PageResult<Book> {
        let response = try await request(
            path: "api/ReadingList/items",
            queryItems: [.init(name: "readingListId", value: readListID)]
        )
        let values = try decoder.decode(
            [KavitaReadingListItemDTO].self,
            from: response.data
        ).sorted { $0.order < $1.order }
        try await ensureLibraryTypes()
        return unpaged(
            values.map {
                $0.domain(
                    serverID: profile.id,
                    readingListID: readListID,
                    libraryType: libraryTypes[$0.libraryId]
                )
            },
            page: page,
            pageSize: pageSize
        )
    }

    func epubInfo(book: Book) async throws -> KavitaBookInfoDTO {
        let response = try await request(path: "api/Book/\(book.remoteContext.chapterID)/book-info")
        return try decoder.decode(KavitaBookInfoDTO.self, from: response.data)
    }

    func epubTableOfContents(book: Book) async throws -> [EPUBTableOfContentsItem] {
        let response = try await request(path: "api/Book/\(book.remoteContext.chapterID)/chapters")
        return try decoder.decode([EPUBTableOfContentsItem].self, from: response.data)
    }

    func epubPage(book: Book, index: Int) async throws -> String {
        let data = try await request(
            path: "api/Book/\(book.remoteContext.chapterID)/book-page",
            queryItems: [.init(name: "page", value: String(index))],
            accept: "text/plain, application/json"
        ).data
        if let decoded = try? decoder.decode(String.self, from: data) { return decoded }
        guard let value = String(data: data, encoding: .utf8) else { throw KavitaClientError.invalidResponse }
        return value
    }

    func epubPageRequest(book: Book, index: Int) throws -> URLRequest {
        try authenticatedRequest(
            path: "api/Book/\(book.remoteContext.chapterID)/book-page",
            queryItems: [.init(name: "page", value: String(index))],
            accept: "text/plain, application/json"
        )
    }

    func epubResourceRequest(book: Book, reference: String) throws -> URLRequest {
        guard let sanitized = EPUBResourceReference.sanitized(reference, relativeTo: profile.baseURL) else {
            throw KavitaClientError.invalidResponse
        }
        var request = URLRequest(url: sanitized)
        request.setValue(authKey, forHTTPHeaderField: "x-api-key")
        request.setValue(deviceID, forHTTPHeaderField: "X-Device-Id")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        return request
    }

    func data(for request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        return data
    }

    func authenticatedRequest(path: String, queryItems: [URLQueryItem] = [], accept: String? = nil) throws -> URLRequest {
        let url = try makeURL(path: path, queryItems: queryItems)
        var request = URLRequest(url: url)
        request.setValue(authKey, forHTTPHeaderField: "x-api-key")
        request.setValue(deviceID, forHTTPHeaderField: "X-Device-Id")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let accept { request.setValue(accept, forHTTPHeaderField: "Accept") }
        return request
    }

    private func searchSeries(_ query: String, pageSize: Int) async throws -> PageResult<Series> {
        let response = try await request(
            path: "api/Search/search",
            queryItems: [
                .init(name: "queryString", value: query),
                .init(name: "includeChapterAndFiles", value: "false")
            ]
        )
        let group = try decoder.decode(
            KavitaSearchGroupDTO.self,
            from: response.data
        )
        var seen = Set<Int>()
        let ids = (group.series ?? []).map(\.seriesId).filter { seen.insert($0).inserted }
        let values = try await seriesByIDs(Array(ids.prefix(pageSize)))
        try await ensureLibraryTypes()
        let content = values.map { $0.domain(serverID: profile.id, libraryType: libraryTypes[$0.libraryId]) }
        return PageResult(content: content, page: 0, totalPages: 1, totalElements: content.count, isLast: true)
    }

    private func seriesByIDs(_ ids: [Int]) async throws -> [KavitaSeriesDTO] {
        guard !ids.isEmpty else { return [] }
        let response = try await request(path: "api/Series/series-by-ids", method: "POST", jsonObject: ["seriesIds": ids])
        return try decoder.decode(
            [KavitaSeriesDTO].self,
            from: response.data
        )
    }

    private func chapterInfo(
        chapterID: String,
        includeDimensions: Bool,
        extractPDF: Bool = false
    ) async throws -> KavitaChapterInfoDTO {
        let response = try await request(
            path: "api/Reader/chapter-info",
            queryItems: [
                .init(name: "chapterId", value: chapterID),
                .init(name: "extractPdf", value: String(extractPDF)),
                .init(name: "includeDimensions", value: String(includeDimensions))
            ]
        )
        return try decoder.decode(
            KavitaChapterInfoDTO.self,
            from: response.data
        )
    }

    private func progress(chapterID: String) async throws -> KavitaProgressDTO {
        let response = try await request(
            path: "api/Reader/get-progress",
            queryItems: [.init(name: "chapterId", value: chapterID)]
        )
        return try decoder.decode(
            KavitaProgressDTO.self,
            from: response.data
        )
    }

    private func ensureLibraryTypes() async throws {
        if libraryTypes.isEmpty { _ = try await libraries() }
    }

    private func numericContext(_ context: RemoteBookContext) -> (series: Int, volume: Int, library: Int, chapter: Int)? {
        guard let series = Int(context.seriesID),
              let volumeID = context.volumeID, let volume = Int(volumeID),
              let libraryID = context.libraryID, let library = Int(libraryID),
              let chapter = Int(context.chapterID) else { return nil }
        return (series, volume, library, chapter)
    }

    private func request(
        path: String,
        method: String = "GET",
        queryItems: [URLQueryItem] = [],
        jsonObject: [String: Any]? = nil,
        body: Data? = nil,
        accept: String? = "application/json",
        cachePolicy: URLRequest.CachePolicy? = nil
    ) async throws -> (data: Data, response: HTTPURLResponse) {
        var request = try authenticatedRequest(path: path, queryItems: queryItems, accept: accept)
        request.httpMethod = method
        request.timeoutInterval = 90
        if let cachePolicy { request.cachePolicy = cachePolicy }
        if let jsonObject {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: jsonObject)
        } else if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }

        var lastError: Error?
        for attempt in 0..<3 {
            do {
                let (data, response) = try await session.data(for: request)
                try validate(response, data: data)
                guard let http = response as? HTTPURLResponse else { throw KavitaClientError.invalidResponse }
                return (data, http)
            } catch let error as URLError {
                if error.code == .cancelled { throw CancellationError() }
                guard Self.isTransient(error), attempt < 2 else { throw error }
                lastError = error
            } catch let error as KavitaClientError {
                guard case .server(let status, _) = error, (500...599).contains(status), attempt < 2 else { throw error }
                lastError = error
            }
            try await Task.sleep(for: .milliseconds(attempt == 0 ? 400 : 1_200))
            try Task.checkCancellation()
        }
        throw lastError ?? KavitaClientError.invalidResponse
    }

    private func makeURL(path: String, queryItems: [URLQueryItem]) throws -> URL {
        var url = profile.baseURL
        for component in path.split(separator: "/") { url.append(path: String(component)) }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw KavitaClientError.invalidResponse
        }
        if !queryItems.isEmpty { components.queryItems = queryItems }
        guard let result = components.url else { throw KavitaClientError.invalidResponse }
        return result
    }

    private func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw KavitaClientError.invalidResponse }
        switch http.statusCode {
        case 200..<300: return
        case 401: throw KavitaClientError.unauthorized
        case 403: throw KavitaClientError.forbidden
        default:
            let fallback = HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            let raw = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
                ?? fallback
            throw KavitaClientError.server(status: http.statusCode, message: Self.redact(raw, secret: authKey))
        }
    }

    nonisolated static func redact(_ value: String, secret: String) -> String {
        guard !secret.isEmpty else { return value }
        return value.replacingOccurrences(of: secret, with: "[REDACTED]")
    }

    private func pagination(
        from response: HTTPURLResponse,
        fallbackPage: Int,
        itemCount: Int,
        pageSize: Int
    ) -> KavitaPagination {
        if let value = response.value(forHTTPHeaderField: "Pagination"),
           let data = value.data(using: .utf8),
           let result = try? decoder.decode(KavitaPagination.self, from: data) {
            return result
        }
        return KavitaPagination(
            currentPage: fallbackPage + 1,
            totalPages: itemCount < pageSize ? fallbackPage + 1 : fallbackPage + 2,
            totalItems: fallbackPage * pageSize + itemCount,
            itemsPerPage: pageSize
        )
    }

    private func unpaged<T: Sendable>(_ values: [T], page: Int, pageSize: Int) -> PageResult<T> {
        let start = min(values.count, page * pageSize)
        let end = min(values.count, start + pageSize)
        let content = start < end ? Array(values[start..<end]) : []
        let totalPages = max(1, Int(ceil(Double(values.count) / Double(max(1, pageSize)))))
        return PageResult(content: content, page: page, totalPages: totalPages, totalElements: values.count, isLast: page + 1 >= totalPages)
    }

    private nonisolated static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = 180
        configuration.waitsForConnectivity = true
        configuration.httpMaximumConnectionsPerHost = 6
        configuration.requestCachePolicy = .reloadRevalidatingCacheData
        return URLSession(configuration: configuration)
    }

    private nonisolated static func isTransient(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost,
             .dnsLookupFailed, .notConnectedToInternet, .resourceUnavailable:
            true
        default:
            false
        }
    }
}

enum EPUBResourceReference {
    private static let credentialQueryNames = ["apiKey", "api_key", "token", "auth"]

    static func sanitized(_ reference: String, relativeTo baseURL: URL) -> URL? {
        guard let rawURL = URL(string: reference, relativeTo: baseURL)?.absoluteURL,
              var components = URLComponents(url: rawURL, resolvingAgainstBaseURL: false),
              let baseHost = baseURL.host,
              components.host?.caseInsensitiveCompare(baseHost) == .orderedSame,
              components.scheme == baseURL.scheme else { return nil }
        components.user = nil
        components.password = nil
        components.fragment = nil
        components.percentEncodedQueryItems = components.percentEncodedQueryItems?.filter { item in
            !credentialQueryNames.contains { $0.caseInsensitiveCompare(item.name) == .orderedSame }
        }
        if components.percentEncodedQueryItems?.isEmpty == true { components.percentEncodedQueryItems = nil }
        return components.url
    }
}
