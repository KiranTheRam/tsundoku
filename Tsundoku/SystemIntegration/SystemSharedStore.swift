import ActivityKit
import Foundation
import Observation

struct DownloadLiveActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        let completedUnitCount: Int
        let totalUnitCount: Int
        let status: String

        var progress: Double {
            guard totalUnitCount > 0 else { return 0 }
            return min(1, max(0, Double(completedUnitCount) / Double(totalUnitCount)))
        }
    }

    let downloadID: String
    let seriesTitle: String
    let bookTitle: String
}

enum TsundokuSharedStore {
    static let appGroupIdentifier = "group.com.example.Tsundoku"
    static let snapshotKey = "tsundoku.system.snapshot.v1"
    static let pendingRouteKey = "tsundoku.system.pending-route.v1"

    static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroupIdentifier) ?? .standard
    }

    static var containerURL: URL {
        if let shared = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) {
            return shared
        }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "TsundokuSystemFallback", directoryHint: .isDirectory)
    }

    static var coverDirectory: URL {
        let directory = containerURL.appending(path: "WidgetCovers", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func coverURL(for seriesID: String) -> URL {
        let safeName = seriesID.map { character in
            character.isLetter || character.isNumber || character == "-" ? character : "_"
        }
        return coverDirectory.appending(path: String(safeName) + ".img")
    }

    static func loadSnapshot() -> TsundokuSystemSnapshot {
        guard let data = defaults.data(forKey: snapshotKey),
              let snapshot = try? JSONDecoder().decode(TsundokuSystemSnapshot.self, from: data) else {
            return .empty
        }
        return snapshot
    }

    static func saveSnapshot(_ snapshot: TsundokuSystemSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: snapshotKey)
    }

    static func savePendingRoute(_ request: SystemNavigationRequest) {
        guard let data = try? JSONEncoder().encode(request) else { return }
        defaults.set(data, forKey: pendingRouteKey)
    }

    static func pendingRoute() -> SystemNavigationRequest? {
        defaults.data(forKey: pendingRouteKey)
            .flatMap { try? JSONDecoder().decode(SystemNavigationRequest.self, from: $0) }
    }

    static func clearPendingRoute(id: UUID) {
        guard pendingRoute()?.id == id else { return }
        defaults.removeObject(forKey: pendingRouteKey)
    }
}

struct SystemSeriesSummary: Codable, Hashable, Sendable, Identifiable {
    let serverID: String
    let seriesID: String
    let title: String

    var id: String { "\(serverID):series:\(seriesID)" }
    var coverURL: URL { TsundokuSharedStore.coverURL(for: id) }
}

struct SystemResumeItem: Codable, Hashable, Sendable, Identifiable {
    let serverID: String
    let seriesID: String
    let bookID: String
    let seriesTitle: String
    let bookTitle: String
    let page: Int
    let pageCount: Int
    let readAt: Date

    var id: String { "\(serverID):book:\(bookID)" }
    var seriesEntityID: String { "\(serverID):series:\(seriesID)" }
    var coverURL: URL { TsundokuSharedStore.coverURL(for: seriesEntityID) }
    var progress: Double {
        guard pageCount > 0 else { return 0 }
        return min(1, max(0, Double(page) / Double(pageCount)))
    }

    var resumeURL: URL {
        var components = URLComponents()
        components.scheme = "tsundoku"
        components.host = "read"
        components.queryItems = [
            URLQueryItem(name: "server", value: serverID),
            URLQueryItem(name: "series", value: seriesID),
            URLQueryItem(name: "book", value: bookID)
        ]
        return components.url ?? URL(string: "tsundoku://home")!
    }
}

struct DailyReadingStatistics: Codable, Equatable, Sendable, Identifiable {
    let date: Date
    let pages: Int

    var id: Date { date }
}

struct ReadingStatistics: Codable, Equatable, Sendable {
    let pagesToday: Int
    let pagesThisWeek: Int
    let currentWeek: [DailyReadingStatistics]

    init(
        pagesToday: Int,
        pagesThisWeek: Int,
        currentWeek: [DailyReadingStatistics] = []
    ) {
        self.pagesToday = pagesToday
        self.pagesThisWeek = pagesThisWeek
        self.currentWeek = currentWeek
    }

    private enum CodingKeys: String, CodingKey {
        case pagesToday, pagesThisWeek, currentWeek
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        pagesToday = try values.decode(Int.self, forKey: .pagesToday)
        pagesThisWeek = try values.decode(Int.self, forKey: .pagesThisWeek)
        currentWeek = try values.decodeIfPresent([DailyReadingStatistics].self, forKey: .currentWeek) ?? []
    }

    static let zero = ReadingStatistics(pagesToday: 0, pagesThisWeek: 0)
}

struct TsundokuSystemSnapshot: Codable, Equatable, Sendable {
    var version = 1
    let series: [SystemSeriesSummary]
    let recentItems: [SystemResumeItem]
    let statistics: ReadingStatistics
    let generatedAt: Date

    static let empty = TsundokuSystemSnapshot(
        series: [],
        recentItems: [],
        statistics: .zero,
        generatedAt: .distantPast
    )
}

struct SystemNavigationRequest: Codable, Equatable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable {
        case series
        case search
    }

    let id: UUID
    let kind: Kind
    let serverID: String?
    let seriesID: String?
    let bookID: String?
    let query: String?

    init(
        id: UUID,
        kind: Kind,
        serverID: String?,
        seriesID: String?,
        bookID: String?,
        query: String?
    ) {
        self.id = id
        self.kind = kind
        self.serverID = serverID
        self.seriesID = seriesID
        self.bookID = bookID
        self.query = query
    }

    static func series(serverID: String, seriesID: String, bookID: String? = nil) -> Self {
        Self(
            id: UUID(),
            kind: .series,
            serverID: serverID,
            seriesID: seriesID,
            bookID: bookID,
            query: nil
        )
    }

    static func search(_ query: String) -> Self {
        Self(id: UUID(), kind: .search, serverID: nil, seriesID: nil, bookID: nil, query: query)
    }

    init?(url: URL) {
        guard url.scheme?.caseInsensitiveCompare("tsundoku") == .orderedSame else { return nil }
        let values = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            values.first { $0.name == name }?.value
        }
        switch url.host {
        case "read", "series":
            guard let serverID = value("server"), let seriesID = value("series") else { return nil }
            self = .series(serverID: serverID, seriesID: seriesID, bookID: value("book"))
        case "search":
            guard let query = value("query") else { return nil }
            self = .search(query)
        default:
            return nil
        }
    }
}

@MainActor @Observable
final class SystemNavigationRouter {
    static let shared = SystemNavigationRouter()

    private(set) var pendingRequest: SystemNavigationRequest?
    var errorMessage: String?

    private init() {}

    func submit(_ request: SystemNavigationRequest) {
        guard pendingRequest?.id != request.id else { return }
        pendingRequest = request
    }

    func complete(_ request: SystemNavigationRequest) {
        guard pendingRequest?.id == request.id else { return }
        pendingRequest = nil
        TsundokuSharedStore.clearPendingRoute(id: request.id)
    }

    func consumeStoredRequest() {
        guard let request = TsundokuSharedStore.pendingRoute() else { return }
        submit(request)
    }
}
