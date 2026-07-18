import Foundation
import Observation
import SwiftData

enum TrackerAutomaticSetupOutcome: Equatable {
    case noAction
    case needsManualConfiguration([TrackerService])
}

@MainActor @Observable
final class TrackerSyncEngine {
    private struct ClientIDs: Codable, Equatable {
        var aniList: String?
        var myAnimeList: String?

        subscript(service: TrackerService) -> String? {
            get { service == .aniList ? aniList : myAnimeList }
            set {
                if service == .aniList { aniList = newValue }
                else { myAnimeList = newValue }
            }
        }
    }

    private struct ClientIDSnapshot: Codable {
        var version = 1
        let clientIDs: ClientIDs
        let modifiedAt: Date
    }

    private struct LinkValue: Codable, Equatable {
        let id: String
        let serverID: String
        let seriesID: String
        let service: String
        let mediaID: Int
        let mediaTitle: String
        let rule: TrackerProgressRule
        let updatedAt: Date
    }

    private struct LinkSnapshot: Codable, Equatable {
        var version = 1
        let links: [LinkValue]
        let modifiedAt: Date
    }

    private let container: ModelContainer
    private let credentials: CredentialStore
    private let defaults: UserDefaults
    @ObservationIgnored private var malRefreshTask: Task<String, Error>?
    @ObservationIgnored private var didPerformInitialLinkSync = false
    private(set) var connected: Set<TrackerService> = []

    init(modelContainer: ModelContainer, credentials: CredentialStore, defaults: UserDefaults = .standard) {
        self.container = modelContainer
        self.credentials = credentials
        self.defaults = defaults
        refreshConfiguration()
        Task {
            await reconcileKeychainConfiguration()
            await reconcileKeychainLinks()
            await reconcileKeychainPromptState()
            await refreshConnections()
            await retryPending()
        }
    }

    func refreshConnections() async {
        var values: Set<TrackerService> = []
        if (try? await credentials.value(kind: .aniListToken, account: "default")) != nil { values.insert(.aniList) }
        if (try? await credentials.value(kind: .myAnimeListToken, account: "default")) != nil { values.insert(.myAnimeList) }
        connected = values
    }

    func configuredClientID(for service: TrackerService) -> String {
        if let saved = localClientIDs()[service]?.trimmingCharacters(in: .whitespacesAndNewlines), !saved.isEmpty {
            return saved
        }
        let saved = defaults.string(forKey: clientIDKey(for: service))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !saved.isEmpty { return saved }
        let bundleKey = service == .aniList ? "AniListClientID" : "MALClientID"
        return (Bundle.main.object(forInfoDictionaryKey: bundleKey) as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func setClientID(_ clientID: String, for service: TrackerService) {
        let normalized = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        var configuration = localClientIDs()
        configuration[service] = normalized.isEmpty ? nil : normalized
        let modifiedAt = Date.now
        persist(configuration, modifiedAt: modifiedAt)
        defaults.removeObject(forKey: clientIDKey(for: service))
        Task { try? await saveKeychainConfiguration(configuration, modifiedAt: modifiedAt) }
    }

    /// Reconciles user-entered OAuth configuration after SwiftData imports a
    /// newer CloudKit copy. Bundled Client IDs remain the final fallback.
    func refreshConfiguration() {
        var local = localClientIDs()
        var localModifiedAt = defaults.object(forKey: clientIDsModifiedAtKey) as? Date ?? .distantPast
        if local == ClientIDs() {
            for service in TrackerService.allCases {
                let legacy = defaults.string(forKey: clientIDKey(for: service))?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let legacy, !legacy.isEmpty { local[service] = legacy }
            }
            if local != ClientIDs() {
                localModifiedAt = .now
                mirrorLocally(local, modifiedAt: localModifiedAt)
            }
        }

        let recordID = clientIDsRecordID
        let descriptor = FetchDescriptor<PreferenceRecord>(
            predicate: #Predicate { $0.id == recordID },
            sortBy: [SortDescriptor(\.modifiedAt, order: .reverse)]
        )
        let cloudRecord = try? container.mainContext.fetch(descriptor).first
        let cloud = cloudRecord.flatMap { try? JSONDecoder().decode(ClientIDs.self, from: $0.encodedPreferences) }
        if let cloudRecord, let cloud, cloudRecord.modifiedAt > localModifiedAt {
            mirrorLocally(cloud, modifiedAt: cloudRecord.modifiedAt)
        } else if local != ClientIDs(), cloudRecord == nil || localModifiedAt > (cloudRecord?.modifiedAt ?? .distantPast) {
            persist(local, modifiedAt: localModifiedAt)
        }
    }

    func reconcileKeychainConfiguration() async {
        let local = localClientIDs()
        let localModifiedAt = defaults.object(forKey: clientIDsModifiedAtKey) as? Date ?? .distantPast
        do {
            guard let value = try await credentials.value(kind: .trackerSetup, account: "default") else {
                guard local != ClientIDs() else { return }
                try await saveKeychainConfiguration(local, modifiedAt: localModifiedAt)
                return
            }
            guard let data = value.data(using: .utf8),
                  let snapshot = try? JSONDecoder().decode(ClientIDSnapshot.self, from: data) else { return }
            if localModifiedAt > snapshot.modifiedAt {
                try await saveKeychainConfiguration(local, modifiedAt: localModifiedAt)
            } else if local != snapshot.clientIDs || localModifiedAt != snapshot.modifiedAt {
                persist(snapshot.clientIDs, modifiedAt: snapshot.modifiedAt)
            }
        } catch {
            // CloudKit and the bundled IDs remain available as fallbacks.
        }
    }

    func eraseSyncedConfiguration() async throws {
        try await saveKeychainConfiguration(ClientIDs(), modifiedAt: .now)
        try await saveKeychainLinks([], modifiedAt: .now)
        let resetPromptState = TrackerPromptState(decisions: [], resetAt: .now)
        persistPromptState(resetPromptState)
        try await saveKeychainPromptState(resetPromptState)
        let recordID = clientIDsRecordID
        let descriptor = FetchDescriptor<PreferenceRecord>(predicate: #Predicate { $0.id == recordID })
        try container.mainContext.fetch(descriptor).forEach(container.mainContext.delete)
        try container.mainContext.save()
        defaults.removeObject(forKey: clientIDsDataKey)
        defaults.removeObject(forKey: clientIDsModifiedAtKey)
        defaults.removeObject(forKey: promptStateDataKey)
        TrackerService.allCases.forEach { defaults.removeObject(forKey: clientIDKey(for: $0)) }
    }

    func connect(_ service: TrackerService) async throws -> String {
        let oauth = TrackerOAuth()
        let id = configuredClientID(for: service)
        switch service {
        case .aniList:
            let token = try await oauth.authenticateAniList(clientID: id)
            let identity = try await AniListClient(token: token).identity()
            try await credentials.save(token, kind: .aniListToken, account: "default")
            await refreshConnections()
            await retryPending()
            return identity.name
        case .myAnimeList:
            let tokens = try await oauth.authenticateMAL(clientID: id)
            let identity = try await MyAnimeListClient(token: tokens.access).identity()
            try await credentials.save(tokens.access, kind: .myAnimeListToken, account: "default")
            if let refresh = tokens.refresh { try await credentials.save(refresh, kind: .myAnimeListRefreshToken, account: "default") }
            await refreshConnections()
            await retryPending()
            return identity.name
        }
    }

    func testConnection(_ service: TrackerService) async throws -> String {
        let identity = try await client(for: service).identity()
        return identity.name
    }

    func disconnect(_ service: TrackerService) async {
        switch service {
        case .aniList: try? await credentials.delete(kind: .aniListToken, account: "default")
        case .myAnimeList:
            try? await credentials.delete(kind: .myAnimeListToken, account: "default")
            try? await credentials.delete(kind: .myAnimeListRefreshToken, account: "default")
        }
        await refreshConnections()
    }

    func search(_ service: TrackerService, title: String) async throws -> [TrackerMedia] {
        let client = try await client(for: service)
        return try await client.search(title: title)
    }

    func linkedServices(for series: Series) -> Set<TrackerService> {
        let serverID = series.key.serverID.description
        let seriesID = series.key.remoteID
        let records = (try? container.mainContext.fetch(FetchDescriptor<TrackerLinkRecord>(predicate: #Predicate {
            $0.serverID == serverID && $0.seriesID == seriesID
        }))) ?? []
        return Set(records.compactMap { TrackerService(rawValue: $0.service) })
    }

    func linkedMediaTitle(for series: Series, service: TrackerService) -> String? {
        let serverID = series.key.serverID.description
        let seriesID = series.key.remoteID
        let serviceRaw = service.rawValue
        return try? container.mainContext.fetch(FetchDescriptor<TrackerLinkRecord>(predicate: #Predicate {
            $0.serverID == serverID && $0.seriesID == seriesID && $0.service == serviceRaw
        })).first?.mediaTitle
    }

    func prepareAutomaticTracking(for series: Series) async -> TrackerAutomaticSetupOutcome {
        guard trackingAllowed(
            serverID: series.key.serverID.description,
            seriesID: series.key.remoteID
        ) else { return .noAction }
        let unlinked = connected.subtracting(linkedServices(for: series))
            .sorted { $0.rawValue < $1.rawValue }
        guard !unlinked.isEmpty else { return .noAction }

        var uncertain: [TrackerService] = []
        for service in unlinked {
            do {
                let candidates = try await search(service, title: series.title)
                guard let match = TrackerMatchPolicy.confidentMatch(for: series.title, in: candidates) else {
                    uncertain.append(service)
                    continue
                }
                try link(
                    series: series,
                    service: service,
                    media: match,
                    rule: .bookNumber(offset: 0)
                )
            } catch {
                // A temporary tracker or network error is retried on a future
                // series refresh and must not consume the one-time prompt.
            }
        }

        guard !uncertain.isEmpty else { return .noAction }
        let seriesID = series.key.id
        var state = localPromptState()
        guard !state.decisions.contains(where: { $0.seriesID == seriesID }) else { return .noAction }
        state = TrackerPromptSyncPolicy.merge(
            state,
            TrackerPromptState(
                decisions: [TrackerPromptDecision(seriesID: seriesID, handledAt: .now)],
                resetAt: nil
            )
        )
        persistPromptState(state)
        Task { try? await saveKeychainPromptState(state) }
        return .needsManualConfiguration(uncertain)
    }

    /// Reconciles tracker progress from the latest cached server state. This
    /// also catches books that were marked read before tracker syncing was
    /// configured or while a tracker was temporarily unavailable.
    func syncLinkedProgress(for series: Series) async {
        guard !linkedServices(for: series).isEmpty else { return }
        await syncSeries(
            serverID: series.key.serverID.description,
            seriesID: series.key.remoteID
        )
    }

    func link(series: Series, service: TrackerService, media: TrackerMedia, rule: TrackerProgressRule) throws {
        let context = container.mainContext
        let id = "\(series.key.serverID):\(series.key.remoteID):\(service.rawValue)"
        let descriptor = FetchDescriptor<TrackerLinkRecord>(predicate: #Predicate { $0.id == id })
        if let existing = try context.fetch(descriptor).first {
            existing.service = service.rawValue
            existing.mediaID = media.id
            existing.mediaTitle = media.title
            existing.encodedRule = try JSONEncoder().encode(rule)
            existing.updatedAt = .now
        } else {
            context.insert(TrackerLinkRecord(serverID: series.key.serverID, seriesID: series.key.remoteID, service: service.rawValue, mediaID: media.id, mediaTitle: media.title, rule: rule))
        }
        try context.save()
        Task {
            try? await saveKeychainLinks()
            await syncSeries(serverID: series.key.serverID.description, seriesID: series.key.remoteID)
        }
    }

    func reconcileKeychainLinks() async {
        let local = linkValues()
        do {
            guard let value = try await credentials.value(kind: .trackerLinks, account: "default") else {
                guard !local.isEmpty else { return }
                try await saveKeychainLinks(local)
                await syncExistingLinksOnce(local)
                return
            }
            guard let data = value.data(using: .utf8),
                  let snapshot = try? JSONDecoder().decode(LinkSnapshot.self, from: data) else { return }
            var newest: [String: LinkValue] = [:]
            for link in snapshot.links { newest[link.id] = link }
            for link in local where link.updatedAt > snapshot.modifiedAt
                && (newest[link.id]?.updatedAt ?? .distantPast) < link.updatedAt {
                newest[link.id] = link
            }
            let merged = newest.values.sorted { $0.id < $1.id }
            if applyLinkValues(merged) { try container.mainContext.save() }
            if merged != snapshot.links { try await saveKeychainLinks(merged) }
            await syncExistingLinksOnce(merged)
        } catch {
            // CloudKit-backed tracker links remain the fallback.
        }
    }

    private func syncExistingLinksOnce(_ links: [LinkValue]) async {
        guard !didPerformInitialLinkSync else { return }
        didPerformInitialLinkSync = true
        var series = Set(links.map { "\($0.serverID):\($0.seriesID)" })
        for link in links where series.remove("\(link.serverID):\(link.seriesID)") != nil {
            await syncSeries(serverID: link.serverID, seriesID: link.seriesID)
        }
    }

    func serverDidAcknowledge(_ checkpoint: ReadingCheckpoint) async {
        guard checkpoint.completed else { return }
        let context = container.mainContext
        let bookID = checkpoint.book.remoteID
        let serverID = checkpoint.book.serverID.description
        guard let cached = try? context.fetch(FetchDescriptor<CachedBookRecord>(predicate: #Predicate {
            $0.remoteID == bookID && $0.serverID == serverID
        })).first,
              let completedBook = try? JSONDecoder().decode(Book.self, from: cached.payload) else { return }
        let seriesID = completedBook.seriesKey.remoteID
        guard trackingAllowed(serverID: serverID, seriesID: seriesID) else { return }
        let links = (try? context.fetch(FetchDescriptor<TrackerLinkRecord>(predicate: #Predicate { $0.serverID == serverID && $0.seriesID == seriesID }))) ?? []
        let cachedBooks = (try? context.fetch(FetchDescriptor<CachedBookRecord>(predicate: #Predicate { $0.serverID == serverID && $0.seriesID == seriesID }))) ?? []
        var progressBooks = cachedBooks.compactMap { try? JSONDecoder().decode(Book.self, from: $0.payload) }.map {
            TrackerBookProgress(
                bookID: $0.key.remoteID,
                numberSort: $0.numberSort,
                completed: $0.completed || $0.key == checkpoint.book,
                trackerProgressUnit: $0.trackerProgressUnit
            )
        }
        if !progressBooks.contains(where: { $0.bookID == checkpoint.book.remoteID }) {
            progressBooks.append(TrackerBookProgress(
                bookID: checkpoint.book.remoteID,
                numberSort: completedBook.numberSort,
                completed: true,
                trackerProgressUnit: completedBook.trackerProgressUnit
            ))
        }
        await publish(progressBooks: progressBooks, links: links)
    }

    private func syncSeries(serverID: String, seriesID: String) async {
        guard trackingAllowed(serverID: serverID, seriesID: seriesID) else { return }
        let context = container.mainContext
        let links = (try? context.fetch(FetchDescriptor<TrackerLinkRecord>(predicate: #Predicate {
            $0.serverID == serverID && $0.seriesID == seriesID
        }))) ?? []
        let cachedBooks = (try? context.fetch(FetchDescriptor<CachedBookRecord>(predicate: #Predicate {
            $0.serverID == serverID && $0.seriesID == seriesID
        }))) ?? []
        let progressBooks = cachedBooks.compactMap { try? JSONDecoder().decode(Book.self, from: $0.payload) }.map {
            TrackerBookProgress(
                bookID: $0.key.remoteID,
                numberSort: $0.numberSort,
                completed: $0.completed,
                trackerProgressUnit: $0.trackerProgressUnit
            )
        }
        await publish(progressBooks: progressBooks, links: links)
    }

    private func trackingAllowed(serverID: String, seriesID: String) -> Bool {
        let records = (try? container.mainContext.fetch(FetchDescriptor<CachedSeriesRecord>(predicate: #Predicate {
            $0.serverID == serverID && $0.remoteID == seriesID
        }))) ?? []
        if let series = records.compactMap({ try? JSONDecoder().decode(Series.self, from: $0.payload) }).first,
           let libraryContentType = series.libraryContentType {
            return libraryContentType == .manga
        }

        let profile = (try? container.mainContext.fetch(FetchDescriptor<ServerProfileRecord>(predicate: #Predicate {
            $0.id == serverID
        })).first)?.value
        // An older Kavita cache is ineligible until a catalog refresh proves
        // that the library is Manga. Komga has no library-type concept here and
        // retains its existing tracker behavior.
        return profile?.kind != .kavita
    }

    private func publish(progressBooks: [TrackerBookProgress], links: [TrackerLinkRecord]) async {
        let context = container.mainContext
        for link in links {
            guard let service = TrackerService(rawValue: link.service), let rule = try? JSONDecoder().decode(TrackerProgressRule.self, from: link.encodedRule) else { continue }
            let update = TrackerProgressCalculator.update(rule: rule, books: progressBooks)
            let mutation = TrackerMutationRecord(
                service: service.rawValue,
                mediaID: link.mediaID,
                progress: update.chapterProgress,
                volumeProgress: update.volumeProgress,
                status: update.completed ? "COMPLETED" : "CURRENT"
            )
            let serviceRaw = service.rawValue
            let mediaID = link.mediaID
            let stale = (try? context.fetch(FetchDescriptor<TrackerMutationRecord>(predicate: #Predicate {
                $0.service == serviceRaw && $0.mediaID == mediaID
            }))) ?? []
            stale.forEach(context.delete)
            context.insert(mutation)
            try? context.save()
            await flush(mutation)
        }
    }

    func retryPending() async {
        let context = container.mainContext
        let mutations = (try? context.fetch(FetchDescriptor<TrackerMutationRecord>())) ?? []
        let grouped = Dictionary(grouping: mutations) { "\($0.service):\($0.mediaID)" }
        for values in grouped.values {
            let sorted = values.sorted { $0.updatedAt > $1.updatedAt }
            guard let newest = sorted.first else { continue }
            sorted.dropFirst().forEach(context.delete)
            if newest.nextAttemptAt <= .now { await flush(newest) }
        }
        try? context.save()
    }

    private func flush(_ mutation: TrackerMutationRecord) async {
        guard let service = TrackerService(rawValue: mutation.service) else { return }
        do {
            let client = try await client(for: service)
            try await client.update(
                mediaID: mutation.mediaID,
                progress: mutation.progress,
                volumeProgress: mutation.volumeProgress,
                status: mutation.status
            )
            container.mainContext.delete(mutation)
            try? container.mainContext.save()
        } catch {
            mutation.attempts += 1
            mutation.lastError = error.localizedDescription
            mutation.nextAttemptAt = Date().addingTimeInterval(min(pow(2, Double(mutation.attempts)) * 30, 21_600))
            try? container.mainContext.save()
        }
    }

    private func client(for service: TrackerService) async throws -> any TrackerClient {
        switch service {
        case .aniList:
            guard let token = try await credentials.value(kind: .aniListToken, account: "default") else { throw TrackerClientError.notConfigured("AniList") }
            return AniListClient(token: token)
        case .myAnimeList:
            guard let token = try await credentials.value(kind: .myAnimeListToken, account: "default") else { throw TrackerClientError.notConfigured("MyAnimeList") }
            return MyAnimeListClient(token: token) { [weak self] in
                guard let self else { throw CancellationError() }
                return try await self.refreshMALAccessToken()
            }
        }
    }

    private func refreshMALAccessToken() async throws -> String {
        if let task = malRefreshTask { return try await task.value }
        let task = Task<String, Error> { [credentials] in
            guard let refreshToken = try await credentials.value(kind: .myAnimeListRefreshToken, account: "default") else {
                throw TrackerClientError.service("MyAnimeList authorization expired. Sign in again to reconnect.")
            }
            let clientID = configuredClientID(for: .myAnimeList)
            let tokens = try await TrackerOAuth.refreshMAL(clientID: clientID, refreshToken: refreshToken)
            try await credentials.save(tokens.access, kind: .myAnimeListToken, account: "default")
            if let refresh = tokens.refresh {
                try await credentials.save(refresh, kind: .myAnimeListRefreshToken, account: "default")
            }
            return tokens.access
        }
        malRefreshTask = task
        defer { malRefreshTask = nil }
        return try await task.value
    }

    func reconcileKeychainPromptState() async {
        let local = localPromptState()
        do {
            guard let value = try await credentials.value(kind: .trackerPromptState, account: "default") else {
                guard local != .empty else { return }
                try await saveKeychainPromptState(local)
                return
            }
            guard let data = value.data(using: .utf8),
                  let remote = try? JSONDecoder().decode(TrackerPromptState.self, from: data) else { return }
            let merged = TrackerPromptSyncPolicy.merge(local, remote)
            if merged != local { persistPromptState(merged) }
            if merged != remote { try await saveKeychainPromptState(merged) }
        } catch {
            // Prompt suppression remains device-local until Keychain is ready.
        }
    }

    private var clientIDsRecordID: String { "trackerClientIDs.global.v1" }
    private var clientIDsDataKey: String { "trackerClientIDs.global.data" }
    private var clientIDsModifiedAtKey: String { "trackerClientIDs.global.modifiedAt" }
    private var promptStateDataKey: String { "trackerPromptState.global.data" }

    private func localClientIDs() -> ClientIDs {
        defaults.data(forKey: clientIDsDataKey)
            .flatMap { try? JSONDecoder().decode(ClientIDs.self, from: $0) }
            ?? ClientIDs()
    }

    private func persist(_ configuration: ClientIDs, modifiedAt: Date = .now) {
        mirrorLocally(configuration, modifiedAt: modifiedAt)
        guard let encoded = try? JSONEncoder().encode(configuration) else { return }
        let recordID = clientIDsRecordID
        let descriptor = FetchDescriptor<PreferenceRecord>(
            predicate: #Predicate { $0.id == recordID },
            sortBy: [SortDescriptor(\.modifiedAt, order: .reverse)]
        )
        if let record = try? container.mainContext.fetch(descriptor).first {
            record.encodedPreferences = encoded
            record.modifiedAt = modifiedAt
        } else {
            let record = PreferenceRecord(id: recordID, encodedValue: encoded)
            record.modifiedAt = modifiedAt
            container.mainContext.insert(record)
        }
        try? container.mainContext.save()
    }

    private func mirrorLocally(_ configuration: ClientIDs, modifiedAt: Date) {
        guard let encoded = try? JSONEncoder().encode(configuration) else { return }
        defaults.set(encoded, forKey: clientIDsDataKey)
        defaults.set(modifiedAt, forKey: clientIDsModifiedAtKey)
    }

    private func saveKeychainConfiguration(_ configuration: ClientIDs, modifiedAt: Date) async throws {
        let snapshot = ClientIDSnapshot(clientIDs: configuration, modifiedAt: modifiedAt)
        let data = try JSONEncoder().encode(snapshot)
        guard let value = String(data: data, encoding: .utf8) else { return }
        try await credentials.save(value, kind: .trackerSetup, account: "default")
    }

    private func localPromptState() -> TrackerPromptState {
        defaults.data(forKey: promptStateDataKey)
            .flatMap { try? JSONDecoder().decode(TrackerPromptState.self, from: $0) }
            ?? .empty
    }

    private func persistPromptState(_ state: TrackerPromptState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: promptStateDataKey)
    }

    private func saveKeychainPromptState(_ state: TrackerPromptState) async throws {
        let data = try JSONEncoder().encode(state)
        guard let value = String(data: data, encoding: .utf8) else { return }
        try await credentials.save(value, kind: .trackerPromptState, account: "default")
    }

    private func linkValues() -> [LinkValue] {
        let records = (try? container.mainContext.fetch(FetchDescriptor<TrackerLinkRecord>())) ?? []
        var newest: [String: LinkValue] = [:]
        for record in records {
            guard let rule = try? JSONDecoder().decode(TrackerProgressRule.self, from: record.encodedRule) else { continue }
            let value = LinkValue(
                id: record.id,
                serverID: record.serverID,
                seriesID: record.seriesID,
                service: record.service,
                mediaID: record.mediaID,
                mediaTitle: record.mediaTitle,
                rule: rule,
                updatedAt: record.updatedAt
            )
            if (newest[value.id]?.updatedAt ?? .distantPast) < value.updatedAt { newest[value.id] = value }
        }
        return newest.values.sorted { $0.id < $1.id }
    }

    @discardableResult
    private func applyLinkValues(_ values: [LinkValue]) -> Bool {
        let context = container.mainContext
        let records = (try? context.fetch(FetchDescriptor<TrackerLinkRecord>())) ?? []
        let byID = Dictionary(grouping: records, by: \.id)
        var changed = false
        let desiredIDs = Set(values.map(\.id))
        for record in records where !desiredIDs.contains(record.id) {
            context.delete(record)
            changed = true
        }
        for value in values {
            if let record = byID[value.id]?.max(by: { $0.updatedAt < $1.updatedAt }) {
                if record.updatedAt < value.updatedAt {
                    record.serverID = value.serverID
                    record.seriesID = value.seriesID
                    record.service = value.service
                    record.mediaID = value.mediaID
                    record.mediaTitle = value.mediaTitle
                    record.encodedRule = (try? JSONEncoder().encode(value.rule)) ?? record.encodedRule
                    record.updatedAt = value.updatedAt
                    changed = true
                }
                byID[value.id]?.filter { $0 !== record }.forEach { context.delete($0); changed = true }
            } else if let serverID = ServerID(string: value.serverID) {
                let record = TrackerLinkRecord(
                    serverID: serverID,
                    seriesID: value.seriesID,
                    service: value.service,
                    mediaID: value.mediaID,
                    mediaTitle: value.mediaTitle,
                    rule: value.rule
                )
                record.updatedAt = value.updatedAt
                context.insert(record)
                changed = true
            }
        }
        return changed
    }

    private func saveKeychainLinks(_ values: [LinkValue]? = nil, modifiedAt: Date = .now) async throws {
        let links = values ?? linkValues()
        let snapshot = LinkSnapshot(links: links, modifiedAt: modifiedAt)
        let data = try JSONEncoder().encode(snapshot)
        guard let value = String(data: data, encoding: .utf8) else { return }
        try await credentials.save(value, kind: .trackerLinks, account: "default")
    }

    private func clientIDKey(for service: TrackerService) -> String {
        "trackerClientID.\(service.rawValue)"
    }
}
