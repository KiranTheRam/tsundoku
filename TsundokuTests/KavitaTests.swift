import Foundation
import XCTest
@testable import Tsundoku

final class KavitaTests: XCTestCase {
    override func setUp() {
        super.setUp()
        KavitaMockURLProtocol.reset()
    }

    func testOPDSURLParsingExtractsAuthKeyAndBaseURL() throws {
        let input = try KavitaURLParser.parse("https://kavita.example.com/api/opds/abc?apiKey=secret")
        XCTAssertEqual(input.baseURL.absoluteString, "https://kavita.example.com")
        XCTAssertEqual(input.pastedAuthKey, "secret")
    }

    func testVersionComparisonAndGate() throws {
        XCTAssertLessThan(try XCTUnwrap(KavitaVersion("0.9.0.1")), try XCTUnwrap(KavitaVersion("0.9.0.2")))
        XCTAssertEqual(KavitaVersion("0.9.0.2"), KavitaVersion("0.9.0.2.0"))
    }

    func testAuthKeyRedaction() {
        XCTAssertEqual(KavitaClient.redact("bad secret value", secret: "secret"), "bad [REDACTED] value")
    }

    func testProgressConversionIncludesFirstPageAndCompletionSentinel() {
        XCTAssertFalse(KavitaProgressPolicy.hasProgress(rawPage: 0))
        XCTAssertTrue(KavitaProgressPolicy.hasProgress(rawPage: 1))
        XCTAssertEqual(KavitaProgressPolicy.normalizedPosition(rawPage: 0, pageCount: 10), 1)
        XCTAssertEqual(KavitaProgressPolicy.normalizedPosition(rawPage: 4, pageCount: 10), 5)
        XCTAssertEqual(KavitaProgressPolicy.normalizedPosition(rawPage: 10, pageCount: 10), 10)
        XCTAssertEqual(KavitaProgressPolicy.rawPage(position: 1, pageCount: 10, completed: false), 0)
        XCTAssertEqual(KavitaProgressPolicy.rawPage(position: 5, pageCount: 10, completed: false), 4)
        XCTAssertEqual(KavitaProgressPolicy.rawPage(position: 10, pageCount: 10, completed: true), 10)
        XCTAssertTrue(KavitaProgressPolicy.isComplete(rawPage: 10, pageCount: 10))
    }

    func testSeriesPaginationFilterAndHeaders() async throws {
        KavitaMockURLProtocol.handler = { request in
            switch request.url?.path {
            case "/api/Series/all-v2":
                let pagination = #"{"currentPage":1,"totalPages":2,"totalItems":3,"itemsPerPage":2}"#
                return KavitaMockURLProtocol.response(
                    request,
                    headers: ["Pagination": pagination],
                    body: #"[{"id":7,"name":"Series","pages":20,"pagesRead":4,"libraryId":2}]"#
                )
            case "/api/Library/libraries":
                return KavitaMockURLProtocol.response(request, body: #"[{"id":2,"name":"Manga","type":0}]"#)
            default:
                return KavitaMockURLProtocol.response(request, status: 404, body: "{}")
            }
        }
        let client = makeClient()
        let result = try await client.series(page: 0, pageSize: 2, libraryID: "2")
        XCTAssertEqual(result.page, 0)
        XCTAssertEqual(result.totalPages, 2)
        XCTAssertEqual(result.totalElements, 3)
        XCTAssertFalse(result.isLast)
        XCTAssertEqual(result.content.first?.readingDirection, "RIGHT_TO_LEFT")
        XCTAssertEqual(result.content.first?.libraryContentType, .manga)

        let request = try XCTUnwrap(KavitaMockURLProtocol.requests.first { $0.url?.path == "/api/Series/all-v2" })
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "PageNumber" })?.value, "1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "secret")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Device-Id"), "device")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Tsundoku-iOS/Test")
        let body = try XCTUnwrap(KavitaMockURLProtocol.requestBodies["/api/Series/all-v2"])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let statements = try XCTUnwrap(object["statements"] as? [[String: Any]])
        XCTAssertEqual(statements.first?["field"] as? Int, 19)
        XCTAssertEqual(statements.first?["comparison"] as? Int, 0)
        XCTAssertEqual(statements.first?["value"] as? String, "2")
    }

    func testKavitaLibraryTypeControlsTrackerEligibility() throws {
        let manga = try JSONDecoder.kavita.decode(
            KavitaLibraryDTO.self,
            from: Data(#"{"id":1,"name":"Manga","type":0}"#.utf8)
        )
        let books = try JSONDecoder.kavita.decode(
            KavitaLibraryDTO.self,
            from: Data(#"{"id":2,"name":"Books","type":2}"#.utf8)
        )

        XCTAssertEqual(manga.domain.contentType, .manga)
        XCTAssertEqual(books.domain.contentType, .other)
    }

    func testConnectionRejectsOldKavita() async throws {
        KavitaMockURLProtocol.handler = { request in
            switch request.url?.path {
            case "/api/Plugin/version": return KavitaMockURLProtocol.response(request, body: "0.9.0.1")
            case "/api/Account": return KavitaMockURLProtocol.response(request, body: #"{"id":1,"username":"reader"}"#)
            case "/api/Plugin/authkey-expires": return KavitaMockURLProtocol.response(request, body: #"{"expiresAt":null}"#)
            default: return KavitaMockURLProtocol.response(request, status: 404, body: "{}")
            }
        }
        do {
            _ = try await makeClient().validateConnection()
            XCTFail("Expected version gate")
        } catch let error as KavitaClientError {
            XCTAssertEqual(error, .unsupportedVersion(found: "0.9.0.1", minimum: "0.9.0.2"))
        }
    }

    func testConnectionRejectsExpiredAuthKey() async throws {
        KavitaMockURLProtocol.handler = { request in
            switch request.url?.path {
            case "/api/Plugin/version": return KavitaMockURLProtocol.response(request, body: "0.9.0.2")
            case "/api/Account": return KavitaMockURLProtocol.response(request, body: #"{"id":1,"username":"reader"}"#)
            case "/api/Plugin/authkey-expires": return KavitaMockURLProtocol.response(request, body: #"{"expiresAt":"2020-01-01T00:00:00Z"}"#)
            default: return KavitaMockURLProtocol.response(request, status: 404, body: "{}")
            }
        }
        do {
            _ = try await makeClient().validateConnection(now: Date(timeIntervalSince1970: 1_700_000_000))
            XCTFail("Expected expired key rejection")
        } catch let error as KavitaClientError {
            XCTAssertEqual(error, .expiredAuthKey)
        }
    }

    func testProgressPayloadPreservesLocatorAndSupportsRegression() async throws {
        KavitaMockURLProtocol.handler = { request in
            KavitaMockURLProtocol.response(request, body: "{}")
        }
        let client = makeClient()
        let book = makeBook(mediaType: "application/epub+zip")
        try await client.markProgress(
            book: book,
            position: 5,
            completed: false,
            locator: "//body/main[1]/p[2]"
        )
        try await client.markProgress(book: book, position: 1, completed: false, locator: nil)

        let bodies = KavitaMockURLProtocol.requestBodyLists["/api/Reader/progress"] ?? []
        XCTAssertEqual(bodies.count, 2)
        let forward = try JSONDecoder.kavita.decode(KavitaProgressDTO.self, from: bodies[0])
        let backward = try JSONDecoder.kavita.decode(KavitaProgressDTO.self, from: bodies[1])
        XCTAssertEqual(forward.pageNum, 4)
        XCTAssertEqual(forward.bookScrollId, "//body/main[1]/p[2]")
        XCTAssertEqual(backward.pageNum, 0)
    }

    func testMarkUnreadRemovesExactChapterProgress() async throws {
        KavitaMockURLProtocol.handler = { request in
            KavitaMockURLProtocol.response(request, body: "{}")
        }

        try await makeClient().markUnread(book: makeBook(mediaType: "application/zip"))

        let body = try XCTUnwrap(
            KavitaMockURLProtocol.requestBodyLists["/api/Reader/mark-multiple-unread"]?.first
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["seriesId"] as? Int, 3)
        XCTAssertEqual(json["chapterIds"] as? [Int], [5])
        XCTAssertEqual(json["volumeIds"] as? [Int], [])
    }

    func testPDFManifestAndPageRequestsEnableExtraction() async throws {
        KavitaMockURLProtocol.handler = { request in
            KavitaMockURLProtocol.response(
                request,
                body: #"{"chapterNumber":"1","volumeNumber":"1","volumeId":4,"seriesName":"PDF","seriesFormat":4,"seriesId":3,"libraryId":2,"libraryType":1,"chapterTitle":"PDF","pages":2,"fileName":"book.pdf","pageDimensions":[{"width":1200,"height":1800,"pageNumber":0,"fileName":"0.jpg"},{"width":1200,"height":1800,"pageNumber":1,"fileName":"1.jpg"}]}"#
            )
        }
        let client = makeClient()
        let book = makeBook(mediaType: "application/pdf")
        let pages = try await client.pages(book: book)
        let imageRequest = try await client.pageRequest(book: book, zeroBasedPage: 1)
        XCTAssertEqual(pages.count, 2)
        XCTAssertEqual(pages.map(\.number), [1, 2])
        XCTAssertEqual(pages.first?.width, 1200)

        var preferences = ReaderPreferences()
        preferences.mode = .pagedLeftToRight
        preferences.spreadMode = .single
        let units = ReaderPagePlanner.units(pages: pages, preferences: preferences, landscape: false)
        XCTAssertEqual(units.map(\.firstPage), [0, 1])

        let chapterInfo = try XCTUnwrap(KavitaMockURLProtocol.requests.first { $0.url?.path == "/api/Reader/chapter-info" })
        XCTAssertEqual(chapterInfo.url?.queryValue(named: "extractPdf"), "true")
        XCTAssertEqual(chapterInfo.url?.queryValue(named: "includeDimensions"), "true")
        XCTAssertEqual(imageRequest.url?.queryValue(named: "extractPdf"), "true")
        XCTAssertEqual(imageRequest.url?.queryValue(named: "page"), "1")
        XCTAssertEqual(imageRequest.url?.queryValue(named: "apiKey"), "secret")
    }

    func testCollectionsAndReadingListsMapCounts() async throws {
        KavitaMockURLProtocol.handler = { request in
            switch request.url?.path {
            case "/api/Collection":
                return KavitaMockURLProtocol.response(request, body: #"[{"id":2,"title":"Favorites","itemCount":7}]"#)
            case "/api/ReadingList/all":
                return KavitaMockURLProtocol.response(request, body: #"[{"id":4,"title":"Queue","summary":"Next","itemCount":3}]"#)
            default:
                return KavitaMockURLProtocol.response(request, status: 404, body: "{}")
            }
        }
        let client = makeClient()
        let collections = try await client.collections()
        let lists = try await client.readLists()
        XCTAssertEqual(collections.content.first?.name, "Favorites")
        XCTAssertEqual(collections.content.first?.itemCount, 7)
        XCTAssertEqual(lists.content.first?.name, "Queue")
        XCTAssertEqual(lists.content.first?.itemCount, 3)
    }

    func testServerErrorsRedactAuthKey() async throws {
        KavitaMockURLProtocol.handler = { request in
            KavitaMockURLProtocol.response(request, status: 400, body: #"{"message":"rejected secret"}"#)
        }
        do {
            _ = try await makeClient().libraries()
            XCTFail("Expected server error")
        } catch let error as KavitaClientError {
            XCTAssertEqual(error, .server(status: 400, message: "rejected [REDACTED]"))
        }
    }

    func testChapterOrderingDeduplicatesAllKavitaBuckets() throws {
        let chapter1 = #"{"id":1,"range":"1","minNumber":1,"sortOrder":2,"pages":10,"isSpecial":false,"pagesRead":0,"volumeId":1,"format":3}"#
        let chapter2 = #"{"id":2,"range":"2","minNumber":2,"sortOrder":1,"pages":10,"isSpecial":false,"pagesRead":0,"volumeId":1,"format":3}"#
        let data = Data("{\"specials\":[\(chapter1)],\"chapters\":[\(chapter2)],\"volumes\":[{\"id\":1,\"seriesId\":9,\"chapters\":[\(chapter1)]}],\"storylineChapters\":[],\"unreadCount\":2,\"totalCount\":2}".utf8)
        let detail = try JSONDecoder.kavita.decode(KavitaSeriesDetailDTO.self, from: data)
        XCTAssertEqual(detail.allChapters.map(\.id), [2, 1])
    }

    func testWholeVolumeArchivesUseParentVolumeNamesNumbersAndOrdering() throws {
        let volumeTwoChapter = #"{"id":20,"range":"-100000","minNumber":-100000,"sortOrder":-100000,"pages":180,"isSpecial":false,"title":"Chapter -100000","titleName":"","pagesRead":0,"volumeId":2,"volumeTitle":"Volume 2","format":3}"#
        let volumeOneChapter = #"{"id":10,"range":"-100000","minNumber":-100000,"sortOrder":-100000,"pages":170,"isSpecial":false,"title":"Chapter -100000","titleName":"","pagesRead":0,"volumeId":1,"volumeTitle":"Volume 1","format":3}"#
        let json = "{\"specials\":[],\"chapters\":[],\"volumes\":["
            + "{\"id\":2,\"seriesId\":9,\"name\":\"Volume 2\",\"number\":2,\"chapters\":[\(volumeTwoChapter)]},"
            + "{\"id\":1,\"seriesId\":9,\"name\":\"Volume 1\",\"number\":1,\"chapters\":[\(volumeOneChapter)]}"
            + "],\"storylineChapters\":[],\"unreadCount\":2,\"totalCount\":2}"
        let data = Data(json.utf8)
        let detail = try JSONDecoder.kavita.decode(KavitaSeriesDetailDTO.self, from: data)
        let serverID = ServerID()
        let books = detail.allChapterEntries.map { entry in
            entry.chapter.domain(
                serverID: serverID,
                seriesID: 9,
                libraryID: 3,
                libraryType: KavitaLibraryType.manga.rawValue,
                parentVolumeTitle: entry.volumeTitle,
                parentVolumeNumber: entry.volumeNumber
            )
        }

        XCTAssertEqual(books.map(\.displayTitle), ["Volume 1", "Volume 2"])
        XCTAssertEqual(books.map(\.number), ["1", "2"])
        XCTAssertEqual(books.map(\.numberSort), [1, 2])
    }

    func testVolumeArchiveFallbackNeverExposesKavitaSentinel() {
        let label = KavitaBookNaming.resolve(
            chapterTitle: "",
            titleName: nil,
            chapterNumber: "-100000.0",
            minNumber: -100_000,
            sortOrder: -100_000,
            volumeTitle: nil,
            volumeNumber: "7",
            fileName: "Example v07.cbz",
            fallbackID: "42"
        )

        XCTAssertEqual(label, KavitaBookLabel(
            title: "Volume 7",
            number: "7",
            sortOrder: 7,
            trackerProgressUnit: .volume
        ))
    }

    func testStandaloneBookSentinelUsesBookTitleInsteadOfVolumePlaceholder() {
        let catalogLabel = KavitaBookNaming.resolve(
            chapterTitle: "Angels' Blood",
            titleName: "Angels' Blood",
            chapterNumber: "Angels' Blood",
            minNumber: -100_000,
            sortOrder: -100_000,
            volumeTitle: "",
            volumeNumber: nil,
            fileName: "(1) Angels' Blood.epub",
            fallbackID: "234"
        )
        let hydratedLabel = KavitaBookNaming.resolve(
            chapterTitle: "Angels' Blood",
            titleName: nil,
            chapterNumber: "-100000.0",
            minNumber: -100_000,
            sortOrder: -100_000,
            volumeTitle: nil,
            volumeNumber: "-100000",
            fileName: "(1) Angels' Blood.epub",
            fallbackID: "234"
        )

        XCTAssertEqual(catalogLabel.title, "Angels' Blood")
        XCTAssertEqual(catalogLabel.number, "Angels' Blood")
        XCTAssertEqual(hydratedLabel.title, "Angels' Blood")
        XCTAssertEqual(hydratedLabel.number, "Angels' Blood")
    }

    func testKavitaFilePathProvidesAReadableFallbackName() throws {
        let json = #"{"id":234,"range":"-100000","minNumber":-100000,"sortOrder":-100000,"pages":55,"isSpecial":true,"title":"Chapter -100000","titleName":"","files":[{"id":1,"filePath":"/books/The Example Book.epub","pages":55,"bytes":1024,"format":3,"extension":".epub"}],"pagesRead":0,"volumeId":234,"volumeTitle":"","format":3}"#
        let chapter = try JSONDecoder.kavita.decode(KavitaChapterDTO.self, from: Data(json.utf8))
        let book = chapter.domain(serverID: ServerID(), seriesID: 81, libraryID: 2)

        XCTAssertEqual(book.displayTitle, "The Example Book")
        XCTAssertFalse(book.displayTitle.contains("100000"))
    }

    func testSeriesBooksUseNumericThenNaturalOrdering() {
        let serverID = ServerID()
        let seriesKey = SeriesKey(serverID: serverID, remoteID: "series")
        func book(id: String, number: String, numberSort: Double) -> Book {
            Book(
                key: BookKey(serverID: serverID, remoteID: id),
                seriesKey: seriesKey,
                title: "Volume \(number)",
                number: number,
                numberSort: numberSort,
                sizeBytes: 0,
                fileHash: id,
                mediaType: "application/epub+zip",
                pageCount: 1,
                readPage: nil,
                completed: false,
                readProgressModifiedAt: nil,
                lastModified: nil,
                contentKind: .epub
            )
        }

        let unordered = [
            book(id: "10", number: "10", numberSort: 0),
            book(id: "2", number: "2", numberSort: 0),
            book(id: "1", number: "1", numberSort: -1),
            book(id: "3", number: "3", numberSort: 3)
        ]
        XCTAssertEqual(SeriesBookOrdering.sorted(unordered).map(\.key.remoteID), ["1", "2", "10", "3"])
    }

    private func makeClient() -> KavitaClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KavitaMockURLProtocol.self]
        let profile = ServerProfile(
            id: ServerID(),
            name: "Kavita",
            baseURL: URL(string: "https://kavita.example.com")!,
            userID: "1",
            username: "reader",
            isActive: true,
            kind: .kavita
        )
        return KavitaClient(
            profile: profile,
            authKey: "secret",
            deviceID: "device",
            userAgent: "Tsundoku-iOS/Test",
            session: URLSession(configuration: configuration)
        )
    }

    private func makeBook(mediaType: String) -> Book {
        let serverID = ServerID()
        return Book(
            key: BookKey(serverID: serverID, remoteID: "5"),
            seriesKey: SeriesKey(serverID: serverID, remoteID: "3"),
            title: "Book",
            number: "1",
            numberSort: 1,
            sizeBytes: 0,
            fileHash: "revision",
            mediaType: mediaType,
            pageCount: 10,
            readPage: nil,
            completed: false,
            readProgressModifiedAt: nil,
            lastModified: nil,
            contentKind: mediaType == "application/epub+zip" ? .epub : .images,
            remoteContext: RemoteBookContext(seriesID: "3", volumeID: "4", libraryID: "2", chapterID: "5")
        )
    }
}

private final class KavitaMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var requestBodies: [String: Data] = [:]
    nonisolated(unsafe) static var requestBodyLists: [String: [Data]] = [:]
    private static let lock = NSLock()

    static func reset() {
        lock.withLock {
            handler = nil
            requests = []
            requestBodies = [:]
            requestBodyLists = [:]
        }
    }

    static func response(
        _ request: URLRequest,
        status: Int = 200,
        headers: [String: String] = [:],
        body: String
    ) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: headers
        )!
        return (response, Data(body.utf8))
    }

    static func bodyData(for request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var result = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4_096)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: 4_096)
            guard count > 0 else { break }
            result.append(buffer, count: count)
        }
        return result
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let body = Self.bodyData(for: request)
            let callback = Self.lock.withLock { () -> ((URLRequest) throws -> (HTTPURLResponse, Data))? in
                Self.requests.append(request)
                if let body, let path = request.url?.path {
                    Self.requestBodies[path] = body
                    Self.requestBodyLists[path, default: []].append(body)
                }
                return Self.handler
            }
            let (response, data) = try XCTUnwrap(callback)(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private extension URL {
    func queryValue(named name: String) -> String? {
        URLComponents(url: self, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == name })?.value
    }
}

private extension NSLock {
    func withLock<T>(_ operation: () -> T) -> T {
        lock(); defer { unlock() }
        return operation()
    }
}
