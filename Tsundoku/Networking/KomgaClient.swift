import Foundation

enum KomgaClientError: LocalizedError, Equatable {
    case invalidResponse
    case unauthorized
    case forbidden
    case missingPageStreamingRole
    case server(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "Komga returned an invalid response."
        case .unauthorized: "The Komga credentials were rejected."
        case .forbidden: "This Komga account cannot perform that action."
        case .missingPageStreamingRole: "This Komga account needs the PAGE_STREAMING role."
        case .server(let status, let message): "Komga error \(status): \(message)"
        }
    }
}

actor KomgaClient {
    let profile: ServerProfile
    private let apiKey: String
    private let session: URLSession
    private let decoder = JSONDecoder.komga

    init(profile: ServerProfile, apiKey: String, session: URLSession? = nil) {
        self.profile = profile
        self.apiKey = apiKey
        self.session = session ?? Self.makeSession()
    }

    static func createAPIKey(baseURL: URL, email: String, password: String, deviceName: String, session: URLSession = .shared) async throws -> (KomgaUserDTO, String) {
        let credential = Data("\(email):\(password)".utf8).base64EncodedString()
        var userRequest = URLRequest(url: baseURL.appending(path: "api/v2/users/me"))
        userRequest.setValue("Basic \(credential)", forHTTPHeaderField: "Authorization")
        let (userData, userResponse) = try await session.data(for: userRequest)
        try validate(userResponse, data: userData, secrets: [password, credential])
        let user = try JSONDecoder.komga.decode(KomgaUserDTO.self, from: userData)
        guard user.roles.contains("PAGE_STREAMING") else { throw KomgaClientError.missingPageStreamingRole }

        var keyRequest = URLRequest(url: baseURL.appending(path: "api/v2/users/me/api-keys"))
        keyRequest.httpMethod = "POST"
        keyRequest.setValue("Basic \(credential)", forHTTPHeaderField: "Authorization")
        keyRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        keyRequest.httpBody = try JSONEncoder().encode(["comment": "Tsundoku · \(deviceName)"])
        let (keyData, keyResponse) = try await session.data(for: keyRequest)
        try validate(keyResponse, data: keyData, secrets: [password, credential])
        let created = try JSONDecoder.komga.decode(KomgaAPIKeyDTO.self, from: keyData)
        return (user, created.key)
    }

    func currentUser() async throws -> KomgaUserDTO {
        let data = try await request(path: "api/v2/users/me")
        let user = try decoder.decode(KomgaUserDTO.self, from: data)
        guard user.roles.contains("PAGE_STREAMING") else { throw KomgaClientError.missingPageStreamingRole }
        return user
    }

    func libraries() async throws -> [Library] {
        let data = try await request(path: "api/v1/libraries")
        return try decoder.decode([KomgaLibraryDTO].self, from: data).map { Library(id: $0.id, name: $0.name, unavailable: $0.unavailable) }
    }

    func collections(page: Int = 0, pageSize: Int = 100, libraryID: String? = nil) async throws -> PageResult<CatalogCollection> {
        var query: [URLQueryItem] = [.init(name: "page", value: String(page)), .init(name: "size", value: String(pageSize))]
        if let libraryID { query.append(.init(name: "library_id", value: libraryID)) }
        let data = try await request(path: "api/v1/collections", queryItems: query)
        let result = try decoder.decode(KomgaCollectionPageDTO.self, from: data)
        return PageResult(content: result.content.map(\.domain), page: result.number, totalPages: result.totalPages, totalElements: result.totalElements, isLast: result.last)
    }

    func collectionSeries(collectionID: String, page: Int = 0, pageSize: Int = 100) async throws -> PageResult<Series> {
        let data = try await request(path: "api/v1/collections/\(collectionID)/series", queryItems: [.init(name: "page", value: String(page)), .init(name: "size", value: String(pageSize))])
        let result = try decoder.decode(KomgaSeriesPageDTO.self, from: data)
        return PageResult(content: result.content.map { $0.domain(serverID: profile.id) }, page: result.number, totalPages: result.totalPages, totalElements: result.totalElements, isLast: result.last)
    }

    func readLists(page: Int = 0, pageSize: Int = 100, libraryID: String? = nil) async throws -> PageResult<CatalogReadingList> {
        var query: [URLQueryItem] = [.init(name: "page", value: String(page)), .init(name: "size", value: String(pageSize))]
        if let libraryID { query.append(.init(name: "library_id", value: libraryID)) }
        let data = try await request(path: "api/v1/readlists", queryItems: query)
        let result = try decoder.decode(KomgaReadListPageDTO.self, from: data)
        return PageResult(content: result.content.map(\.domain), page: result.number, totalPages: result.totalPages, totalElements: result.totalElements, isLast: result.last)
    }

    func readListBooks(readListID: String, page: Int = 0, pageSize: Int = 200) async throws -> PageResult<Book> {
        let data = try await request(path: "api/v1/readlists/\(readListID)/books", queryItems: [.init(name: "page", value: String(page)), .init(name: "size", value: String(pageSize))])
        let result = try decoder.decode(KomgaBookPageDTO.self, from: data)
        return PageResult(content: result.content.map { $0.domain(serverID: profile.id) }, page: result.number, totalPages: result.totalPages, totalElements: result.totalElements, isLast: result.last)
    }

    func series(page: Int = 0, pageSize: Int = 40, libraryID: String? = nil, search: String? = nil, sort: String = "metadata.titleSort,asc") async throws -> PageResult<Series> {
        var body: [String: Any] = [:]
        if let search, !search.isEmpty { body["fullTextSearch"] = search }
        if let libraryID {
            body["condition"] = ["libraryId": ["operator": "is", "value": libraryID]]
        }
        let data = try await request(
            path: "api/v1/series/list",
            method: "POST",
            queryItems: [.init(name: "page", value: String(page)), .init(name: "size", value: String(pageSize)), .init(name: "sort", value: sort)],
            jsonObject: body
        )
        let result = try decoder.decode(KomgaSeriesPageDTO.self, from: data)
        return PageResult(content: result.content.map { $0.domain(serverID: profile.id) }, page: result.number, totalPages: result.totalPages, totalElements: result.totalElements, isLast: result.last)
    }

    func updatedSeries(page: Int = 0, pageSize: Int = 24, libraryID: String? = nil) async throws -> PageResult<Series> {
        var query: [URLQueryItem] = [
            .init(name: "page", value: String(page)),
            .init(name: "size", value: String(pageSize))
        ]
        if let libraryID { query.append(.init(name: "library_id", value: libraryID)) }
        let data = try await request(path: "api/v1/series/updated", queryItems: query)
        let result = try decoder.decode(KomgaSeriesPageDTO.self, from: data)
        return PageResult(
            content: result.content.map { $0.domain(serverID: profile.id) },
            page: result.number,
            totalPages: result.totalPages,
            totalElements: result.totalElements,
            isLast: result.last
        )
    }

    func series(id: String) async throws -> Series {
        let data = try await request(path: "api/v1/series/\(id)")
        return try decoder.decode(KomgaSeriesDTO.self, from: data).domain(serverID: profile.id)
    }

    func books(seriesID: String, page: Int = 0, pageSize: Int = 200) async throws -> PageResult<Book> {
        let body: [String: Any] = ["condition": ["seriesId": ["operator": "is", "value": seriesID]]]
        let data = try await request(
            path: "api/v1/books/list",
            method: "POST",
            queryItems: [.init(name: "page", value: String(page)), .init(name: "size", value: String(pageSize)), .init(name: "sort", value: "metadata.numberSort,asc")],
            jsonObject: body
        )
        let result = try decoder.decode(KomgaBookPageDTO.self, from: data)
        return PageResult(content: result.content.map { $0.domain(serverID: profile.id) }, page: result.number, totalPages: result.totalPages, totalElements: result.totalElements, isLast: result.last)
    }

    func book(id: String) async throws -> Book {
        let data = try await request(path: "api/v1/books/\(id)")
        return try decoder.decode(KomgaBookDTO.self, from: data).domain(serverID: profile.id)
    }

    func adjacentBook(from bookID: String, next: Bool) async throws -> Book {
        let data = try await request(path: "api/v1/books/\(bookID)/\(next ? "next" : "previous")")
        return try decoder.decode(KomgaBookDTO.self, from: data).domain(serverID: profile.id)
    }

    func pages(bookID: String) async throws -> [BookPage] {
        let data = try await request(path: "api/v1/books/\(bookID)/pages")
        return try decoder.decode([KomgaPageDTO].self, from: data).map(\.domain)
    }

    func posterData(seriesID: String) async throws -> Data {
        // PosterCache owns thumbnail caching. Bypass URLSession's cache so an
        // explicit artwork refresh always reaches Komga for the current image.
        try await request(
            path: "api/v1/series/\(seriesID)/thumbnail",
            accept: "image/*",
            cachePolicy: .reloadIgnoringLocalCacheData
        )
    }

    func pageData(bookID: String, zeroBasedPage: Int) async throws -> Data {
        try await request(path: "api/v1/books/\(bookID)/pages/\(zeroBasedPage)", queryItems: [.init(name: "zero_based", value: "true")], accept: "image/*")
    }

    func markProgress(bookID: String, page: Int, completed: Bool = false) async throws {
        let payload: [String: Any] = completed ? ["completed": true] : ["page": page]
        _ = try await request(path: "api/v1/books/\(bookID)/read-progress", method: "PATCH", jsonObject: payload)
    }

    func markUnread(bookID: String) async throws {
        _ = try await request(path: "api/v1/books/\(bookID)/read-progress", method: "DELETE")
    }

    func authenticatedRequest(path: String, queryItems: [URLQueryItem] = [], accept: String? = nil) throws -> URLRequest {
        let url = try makeURL(path: path, queryItems: queryItems)
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        if let accept { request.setValue(accept, forHTTPHeaderField: "Accept") }
        return request
    }

    private func request(
        path: String,
        method: String = "GET",
        queryItems: [URLQueryItem] = [],
        jsonObject: [String: Any]? = nil,
        accept: String? = "application/json",
        cachePolicy: URLRequest.CachePolicy? = nil
    ) async throws -> Data {
        var request = try authenticatedRequest(path: path, queryItems: queryItems, accept: accept)
        request.httpMethod = method
        request.timeoutInterval = 90
        if let cachePolicy { request.cachePolicy = cachePolicy }
        if let jsonObject {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: jsonObject)
        }

        var lastError: Error?
        for attempt in 0..<3 {
            do {
                let (data, response) = try await session.data(for: request)
                try Self.validate(response, data: data, secrets: [apiKey])
                return data
            } catch let error as URLError {
                if error.code == .cancelled { throw CancellationError() }
                guard Self.isTransient(error), attempt < 2 else { throw error }
                lastError = error
            } catch let error as KomgaClientError {
                guard case .server(let status, _) = error, (500...599).contains(status), attempt < 2 else { throw error }
                lastError = error
            }

            try await Task.sleep(for: .milliseconds(attempt == 0 ? 400 : 1_200))
            try Task.checkCancellation()
        }
        throw lastError ?? KomgaClientError.invalidResponse
    }

    private func makeURL(path: String, queryItems: [URLQueryItem]) throws -> URL {
        var url = profile.baseURL
        for component in path.split(separator: "/") { url.append(path: String(component)) }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw KomgaClientError.invalidResponse }
        if !queryItems.isEmpty { components.queryItems = queryItems }
        guard let result = components.url else { throw KomgaClientError.invalidResponse }
        return result
    }

    private static func validate(_ response: URLResponse, data: Data, secrets: [String] = []) throws {
        guard let http = response as? HTTPURLResponse else { throw KomgaClientError.invalidResponse }
        switch http.statusCode {
        case 200..<300: return
        case 401: throw KomgaClientError.unauthorized
        case 403: throw KomgaClientError.forbidden
        default:
            let raw = String(data: data, encoding: .utf8) ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            let message = secrets.reduce(raw) { value, secret in redact(value, secret: secret) }
            throw KomgaClientError.server(status: http.statusCode, message: message)
        }
    }

    nonisolated static func redact(_ value: String, secret: String) -> String {
        guard !secret.isEmpty else { return value }
        return value.replacingOccurrences(of: secret, with: "[REDACTED]")
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
