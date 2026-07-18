import AppIntents
import Foundation

struct SeriesAppEntity: AppEntity, IndexedEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Series",
        numericFormat: "\(placeholder: .int) series"
    )
    static let defaultQuery = SeriesAppEntityQuery()

    let id: String
    let serverID: String
    let seriesID: String
    let title: String

    init(summary: SystemSeriesSummary) {
        id = summary.id
        serverID = summary.serverID
        seriesID = summary.seriesID
        title = summary.title
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            image: .init(systemName: "books.vertical.fill")
        )
    }
}

struct SeriesAppEntityQuery: EntityStringQuery {
    func entities(for identifiers: [SeriesAppEntity.ID]) async throws -> [SeriesAppEntity] {
        let requested = Set(identifiers)
        return TsundokuSharedStore.loadSnapshot().series
            .filter { requested.contains($0.id) }
            .map(SeriesAppEntity.init)
    }

    func entities(matching string: String) async throws -> [SeriesAppEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return try await suggestedEntities() }
        return TsundokuSharedStore.loadSnapshot().series
            .filter { $0.title.localizedStandardContains(query) }
            .sorted { lhs, rhs in
                let lhsExact = lhs.title.caseInsensitiveCompare(query) == .orderedSame
                let rhsExact = rhs.title.caseInsensitiveCompare(query) == .orderedSame
                if lhsExact != rhsExact { return lhsExact }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
            .prefix(25)
            .map(SeriesAppEntity.init)
    }

    func suggestedEntities() async throws -> [SeriesAppEntity] {
        let snapshot = TsundokuSharedStore.loadSnapshot()
        let recentSeries = snapshot.recentItems.map(\.seriesEntityID)
        let rank = Self.suggestionRanks(for: recentSeries)
        return snapshot.series
            .sorted { lhs, rhs in
                let lhsRank = rank[lhs.id] ?? Int.max
                let rhsRank = rank[rhs.id] ?? Int.max
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
            .prefix(50)
            .map(SeriesAppEntity.init)
    }

    static func suggestionRanks(for seriesIDs: [String]) -> [String: Int] {
        var ranks: [String: Int] = [:]
        for (offset, seriesID) in seriesIDs.enumerated() where ranks[seriesID] == nil {
            ranks[seriesID] = offset
        }
        return ranks
    }
}

struct OpenSeriesIntent: OpenIntent {
    static let title: LocalizedStringResource = "Read or Open Series"
    static let description = IntentDescription(
        "Resume a series where you stopped, or open its series page if you haven't started it."
    )

    @Parameter(title: "Series")
    var target: SeriesAppEntity

    init() {}

    init(target: SeriesAppEntity) {
        self.target = target
    }

    func perform() async throws -> some IntentResult {
        let request = SystemNavigationRequest.series(
            serverID: target.serverID,
            seriesID: target.seriesID
        )
        TsundokuSharedStore.savePendingRoute(request)
        await SystemNavigationRouter.shared.submit(request)
        return .result()
    }
}

struct SearchLibraryIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Library"
    static let description = IntentDescription("Open Tsundoku and search the active library.")
    static let openAppWhenRun = true

    @Parameter(title: "Search")
    var query: String

    init() {}

    init(query: String) {
        self.query = query
    }

    func perform() async throws -> some IntentResult {
        let request = SystemNavigationRequest.search(query)
        TsundokuSharedStore.savePendingRoute(request)
        await SystemNavigationRouter.shared.submit(request)
        return .result()
    }
}

struct TsundokuAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenSeriesIntent(),
            phrases: [
                "Read \(\.$target) in \(.applicationName)",
                "Open \(\.$target) in \(.applicationName)"
            ],
            shortTitle: "Read a Series",
            systemImageName: "book.fill"
        )
        AppShortcut(
            intent: SearchLibraryIntent(),
            phrases: [
                "Search my library in \(.applicationName)",
                "Search in \(.applicationName)"
            ],
            shortTitle: "Search Library",
            systemImageName: "magnifyingglass"
        )
    }
}
