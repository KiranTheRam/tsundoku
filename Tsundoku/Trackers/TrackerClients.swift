import Foundation

enum TrackerService: String, Codable, CaseIterable, Identifiable, Sendable {
    case aniList
    case myAnimeList
    var id: String { rawValue }
    var title: String { self == .aniList ? "AniList" : "MyAnimeList" }
}

struct TrackerMedia: Identifiable, Hashable, Sendable {
    let id: Int
    let title: String
    let alternateTitle: String?
    let total: Int?
}

enum TrackerClientError: LocalizedError {
    case notConfigured(String)
    case invalidResponse
    case rateLimited(Date?)
    case service(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let service): "Enter the \(service) Client ID in Settings → AniList & MyAnimeList."
        case .invalidResponse: "The tracker returned an invalid response."
        case .rateLimited(let date): date.map { "Tracker rate limited until \($0.formatted())." } ?? "Tracker rate limited the request."
        case .service(let message): message
        }
    }
}

struct TrackerIdentity: Equatable, Sendable {
    let id: Int
    let name: String
}

protocol TrackerClient: Sendable {
    func search(title: String) async throws -> [TrackerMedia]
    func update(mediaID: Int, progress: Int, volumeProgress: Int?, status: String) async throws
    func identity() async throws -> TrackerIdentity
}

actor AniListClient: TrackerClient {
    private let token: String
    private let session: URLSession
    init(token: String, session: URLSession = .shared) {
        self.token = token
        self.session = session
    }

    func search(title: String) async throws -> [TrackerMedia] {
        let query = "query ($search: String) { Page(perPage: 15) { media(search: $search, type: MANGA) { id chapters title { userPreferred romaji english } } } }"
        let data = try await request(query: query, variables: ["search": title])
        let response = try JSONDecoder().decode(AniListSearchResponse.self, from: data)
        return response.data.Page.media.map { TrackerMedia(id: $0.id, title: $0.title.userPreferred, alternateTitle: $0.title.english ?? $0.title.romaji, total: $0.chapters) }
    }

    func update(mediaID: Int, progress: Int, volumeProgress: Int?, status: String) async throws {
        let query = "mutation ($mediaId: Int, $progress: Int, $progressVolumes: Int, $status: MediaListStatus) { SaveMediaListEntry(mediaId: $mediaId, progress: $progress, progressVolumes: $progressVolumes, status: $status) { id } }"
        var variables: [String: Any] = ["mediaId": mediaID, "progress": progress, "status": status]
        if let volumeProgress { variables["progressVolumes"] = volumeProgress }
        _ = try await request(query: query, variables: variables)
    }

    func identity() async throws -> TrackerIdentity {
        let data = try await request(query: "query { Viewer { id name } }", variables: [:])
        let response = try JSONDecoder().decode(AniListViewerResponse.self, from: data)
        return TrackerIdentity(id: response.data.Viewer.id, name: response.data.Viewer.name)
    }

    private func request(query: String, variables: [String: Any]) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://graphql.anilist.co")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        let (data, response) = try await session.data(for: request)
        try validateTrackerResponse(response)
        return data
    }
}

actor MyAnimeListClient: TrackerClient {
    private var token: String
    private let refreshAccessToken: (@Sendable () async throws -> String)?
    private let session: URLSession

    init(
        token: String,
        refreshAccessToken: (@Sendable () async throws -> String)? = nil,
        session: URLSession = .shared
    ) {
        self.token = token
        self.refreshAccessToken = refreshAccessToken
        self.session = session
    }

    func search(title: String) async throws -> [TrackerMedia] {
        var components = URLComponents(string: "https://api.myanimelist.net/v2/manga")!
        components.queryItems = [.init(name: "q", value: title), .init(name: "limit", value: "15"), .init(name: "fields", value: "alternative_titles,num_chapters")]
        let (data, _) = try await perform(URLRequest(url: components.url!))
        let result = try JSONDecoder().decode(MALSearchResponse.self, from: data)
        return result.data.map { TrackerMedia(id: $0.node.id, title: $0.node.title, alternateTitle: $0.node.alternativeTitles?.en ?? $0.node.alternativeTitles?.ja, total: $0.node.numChapters) }
    }

    func update(mediaID: Int, progress: Int, volumeProgress: Int?, status: String) async throws {
        var request = URLRequest(url: URL(string: "https://api.myanimelist.net/v2/manga/\(mediaID)/my_list_status")!)
        request.httpMethod = "PATCH"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let malStatus = status == "COMPLETED" ? "completed" : "reading"
        var fields = ["status=\(malStatus)", "num_chapters_read=\(progress)"]
        if let volumeProgress { fields.append("num_volumes_read=\(volumeProgress)") }
        request.httpBody = fields.joined(separator: "&").data(using: .utf8)
        _ = try await perform(request)
    }

    func identity() async throws -> TrackerIdentity {
        var components = URLComponents(string: "https://api.myanimelist.net/v2/users/@me")!
        components.queryItems = [.init(name: "fields", value: "id,name")]
        let (data, _) = try await perform(URLRequest(url: components.url!))
        let user = try JSONDecoder().decode(MALUserResponse.self, from: data)
        return TrackerIdentity(id: user.id, name: user.name)
    }

    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        var authenticatedRequest = authenticated(request)
        var result = try await session.data(for: authenticatedRequest)
        if (result.1 as? HTTPURLResponse)?.statusCode == 401, let refreshAccessToken {
            token = try await refreshAccessToken()
            authenticatedRequest = authenticated(request)
            result = try await session.data(for: authenticatedRequest)
        }
        try validateTrackerResponse(result.1)
        return result
    }

    private func authenticated(_ request: URLRequest) -> URLRequest {
        var copy = request
        copy.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return copy
    }
}

private func validateTrackerResponse(_ response: URLResponse) throws {
    guard let http = response as? HTTPURLResponse else { throw TrackerClientError.invalidResponse }
    if http.statusCode == 429 {
        let date = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init).map { Date().addingTimeInterval($0) }
        throw TrackerClientError.rateLimited(date)
    }
    guard (200..<300).contains(http.statusCode) else { throw TrackerClientError.invalidResponse }
}

private struct AniListSearchResponse: Decodable {
    struct Payload: Decodable { let Page: PagePayload }
    struct PagePayload: Decodable { let media: [Media] }
    struct Media: Decodable { let id: Int; let chapters: Int?; let title: Titles }
    struct Titles: Decodable { let userPreferred: String; let romaji: String?; let english: String? }
    let data: Payload
}

private struct AniListViewerResponse: Decodable {
    struct Payload: Decodable { let Viewer: ViewerPayload }
    struct ViewerPayload: Decodable { let id: Int; let name: String }
    let data: Payload
}

private struct MALSearchResponse: Decodable {
    struct Result: Decodable { let node: Node }
    struct Node: Decodable {
        struct Alternate: Decodable { let en: String?; let ja: String? }
        let id: Int; let title: String; let alternativeTitles: Alternate?; let numChapters: Int?
        enum CodingKeys: String, CodingKey { case id, title; case alternativeTitles = "alternative_titles"; case numChapters = "num_chapters" }
    }
    let data: [Result]
}

private struct MALUserResponse: Decodable {
    let id: Int
    let name: String
}
