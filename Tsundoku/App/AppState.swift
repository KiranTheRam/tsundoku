import CloudKit
import Foundation
import Observation
import SwiftData
import UIKit

enum StartupConnectionErrorPolicy {
    static let requiredConsecutiveFailures = 3

    static func message(failureCount: Int, latestError: String) -> String? {
        failureCount >= requiredConsecutiveFailures ? latestError : nil
    }
}

@MainActor @Observable
final class AppState {
    enum CloudSyncStatus: Equatable {
        case checking
        case available
        case noAccount
        case restricted
        case temporarilyUnavailable
        case failed(String)
    }

    enum SetupSyncStatus: Equatable {
        case checking
        case waitingForCredentials
        case ready
    }

    private enum ActivationResult: Equatable {
        case connected
        case missingCredential
        case superseded
        case failed(String)
    }

    let modelContainer: ModelContainer
    let credentials: CredentialStore
    let progress: ProgressCoordinator
    let downloads: DownloadManager
    let trackers: TrackerSyncEngine
    let posters: PosterCache

    private let defaults: UserDefaults
    @ObservationIgnored private var activationRequestID = UUID()
    @ObservationIgnored private var setupReconciliationTask: Task<Void, Never>?

    private(set) var profiles: [ServerProfile] = []
    private(set) var activeProfile: ServerProfile?
    private(set) var activeClient: ServerClient?
    private(set) var posterCacheRevision = 0
    private(set) var cloudSyncStatus: CloudSyncStatus = .checking
    private(set) var setupSyncStatus: SetupSyncStatus = .checking
    private(set) var pinnedSeriesKeys: [SeriesKey] = []
    private(set) var continueReadingActivities: [HomeSeriesActivity] = []
    private(set) var recentBookActivities: [HomeBookActivity] = []
    var readingStatisticsBuckets: [ReadingStatisticsBucket] = []
    var startupError: String?
    var isPresentingConnection = false

    init(
        modelContainer: ModelContainer,
        credentials: CredentialStore = CredentialStore(),
        defaults: UserDefaults = .standard
    ) {
        self.modelContainer = modelContainer
        self.credentials = credentials
        self.defaults = defaults
        posters = PosterCache()
        trackers = TrackerSyncEngine(modelContainer: modelContainer, credentials: credentials, defaults: defaults)
        progress = ProgressCoordinator(modelContainer: modelContainer)
        downloads = DownloadManager(modelContainer: modelContainer)
        progress.onAcknowledged = { [weak trackers] checkpoint in
            await trackers?.serverDidAcknowledge(checkpoint)
        }
        refreshPinnedSeries()
        refreshContinueReadingActivities()
        refreshReadingStatisticsBuckets()
        loadProfiles(activateClient: false)
        if !Self.isRunningUnitTests {
            refreshSystemIntegrationSnapshot(reindexSeries: true)
            beginSetupReconciliation()
        }
    }

    func refreshCloudSyncStatus() async {
        guard !Self.isRunningUnitTests else {
            cloudSyncStatus = .temporarilyUnavailable
            return
        }
        do {
            // Use the entitlement-selected container, matching SwiftData's
            // `.automatic` CloudKit configuration.
            let container = CKContainer.default()
            switch try await container.accountStatus() {
            case .available: cloudSyncStatus = .available
            case .noAccount: cloudSyncStatus = .noAccount
            case .restricted: cloudSyncStatus = .restricted
            case .couldNotDetermine: cloudSyncStatus = .temporarilyUnavailable
            case .temporarilyUnavailable: cloudSyncStatus = .temporarilyUnavailable
            @unknown default: cloudSyncStatus = .temporarilyUnavailable
            }
        } catch {
            cloudSyncStatus = .failed(error.localizedDescription)
        }
    }

    static var isRunningUnitTests: Bool {
        NSClassFromString("XCTestCase") != nil ||
            Bundle.allBundles.contains { $0.bundlePath.hasSuffix(".xctest") }
    }

    func loadProfiles(activateClient: Bool = true) {
        do {
            let records = try modelContainer.mainContext.fetch(FetchDescriptor<ServerProfileRecord>(sortBy: [SortDescriptor(\.modifiedAt, order: .reverse)]))
            profiles = records.compactMap(\.value)
            activeProfile = profiles.first(where: \.isActive) ?? profiles.first
            if let activeProfile {
                if activateClient, activeClient?.profile != activeProfile {
                    Task { await activate(activeProfile) }
                }
            } else {
                activationRequestID = UUID()
                activeClient = nil
            }
        } catch {
            startupError = error.localizedDescription
        }
    }

    private func reconcileServerSetupMirror() async {
        do {
            let localRecords = try modelContainer.mainContext.fetch(
                FetchDescriptor<ServerProfileRecord>(sortBy: [SortDescriptor(\.modifiedAt, order: .reverse)])
            )
            let localProfiles = ServerSetupMirror.profiles(from: localRecords)
            guard let encoded = try await credentials.value(kind: .serverSetup, account: "default") else {
                // Absence means this installation predates the mirror. Only a
                // device that actually has setup may seed it; an empty device
                // must wait instead of overwriting another device with [].
                guard !localProfiles.isEmpty else { return }
                try await saveServerSetupMirror(localProfiles, force: true)
                return
            }
            guard let data = encoded.data(using: .utf8),
                  var snapshot = try? JSONDecoder().decode(ServerSetupSnapshot.self, from: data) else {
                return
            }

            // During the build-29 migration window, a newer CloudKit record may
            // have been created by an older app that cannot update this mirror.
            // Merge only records newer than the snapshot; otherwise the mirror
            // is authoritative, including an explicit empty deletion snapshot.
            let newerLocalRecords = localRecords.filter { $0.modifiedAt > snapshot.modifiedAt }
            if !newerLocalRecords.isEmpty {
                var merged: [ServerID: ServerProfile] = [:]
                for profile in snapshot.profiles { merged[profile.id] = profile }
                for record in newerLocalRecords {
                    if let profile = record.value { merged[profile.id] = profile }
                }
                snapshot = ServerSetupSnapshot(
                    profiles: Array(merged.values),
                    modifiedAt: newerLocalRecords.map(\.modifiedAt).max() ?? .now
                )
                try await saveServerSetupMirror(snapshot.profiles, force: true, modifiedAt: snapshot.modifiedAt)
            }

            if try ServerSetupMirror.apply(snapshot, to: modelContainer.mainContext) {
                try modelContainer.mainContext.save()
            }
        } catch {
            // CloudKit remains the fallback. A transient Keychain failure must
            // never prevent an already configured local server from opening.
        }
    }

    private func saveServerSetupMirror(
        _ profiles: [ServerProfile]? = nil,
        force: Bool = false,
        modifiedAt: Date = .now
    ) async throws {
        let values: [ServerProfile]
        if let profiles {
            values = profiles
        } else {
            values = ServerSetupMirror.profiles(
                from: try modelContainer.mainContext.fetch(FetchDescriptor<ServerProfileRecord>())
            )
        }
        if !force,
           let existing = try await credentials.value(kind: .serverSetup, account: "default"),
           let data = existing.data(using: .utf8),
           let snapshot = try? JSONDecoder().decode(ServerSetupSnapshot.self, from: data),
           ServerSetupMirror.normalized(snapshot.profiles) == ServerSetupMirror.normalized(values) {
            return
        }
        let snapshot = ServerSetupSnapshot(profiles: values, modifiedAt: modifiedAt)
        let data = try JSONEncoder().encode(snapshot)
        guard let value = String(data: data, encoding: .utf8) else { return }
        try await credentials.save(value, kind: .serverSetup, account: "default")
    }

    func addServer(
        kind: ServerKind = .komga,
        name: String,
        urlInput: String,
        apiKey: String?,
        email: String?,
        password: String?
    ) async throws {
        let resolvedKey: String
        var profile: ServerProfile
        switch kind {
        case .komga:
            let baseURL = try KomgaURLValidator.validate(urlInput)
            let provisional = ServerProfile(
                id: ServerID(),
                name: name.isEmpty ? (baseURL.host ?? "Komga") : name,
                baseURL: baseURL,
                userID: "",
                username: email ?? "",
                isActive: true,
                kind: .komga
            )
            let user: KomgaUserDTO
            if let apiKey, !apiKey.isEmpty {
                let client = KomgaClient(profile: provisional, apiKey: apiKey)
                user = try await client.currentUser()
                resolvedKey = apiKey
            } else {
                guard let email, let password, !email.isEmpty, !password.isEmpty else {
                    throw KomgaClientError.unauthorized
                }
                (user, resolvedKey) = try await KomgaClient.createAPIKey(
                    baseURL: baseURL,
                    email: email,
                    password: password,
                    deviceName: UIDevice.current.name
                )
            }
            profile = provisional
            profile.userID = user.id
            profile.username = user.email

        case .kavita:
            let parsed = try KavitaURLParser.parse(urlInput)
            let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? parsed.pastedAuthKey
            guard let key else { throw KavitaClientError.unauthorized }
            let provisional = ServerProfile(
                id: ServerID(),
                name: name.isEmpty ? (parsed.baseURL.host ?? "Kavita") : name,
                baseURL: parsed.baseURL,
                userID: "",
                username: "",
                isActive: true,
                kind: .kavita
            )
            let client = KavitaClient(
                profile: provisional,
                authKey: key,
                deviceID: installationDeviceID,
                userAgent: userAgent
            )
            let connection = try await client.validateConnection()
            profile = provisional
            profile.userID = String(connection.user.id)
            profile.username = connection.user.username ?? connection.user.email ?? "Kavita user"
            resolvedKey = key
        }

        try await credentials.save(resolvedKey, kind: credentialKind(for: profile.kind), account: profile.id.description)
        let context = modelContainer.mainContext
        do {
            let existing = try context.fetch(FetchDescriptor<ServerProfileRecord>())
            existing.forEach { $0.isActive = false }
            context.insert(ServerProfileRecord(profile: profile))
            try context.save()
        } catch {
            context.rollback()
            try? await credentials.delete(kind: credentialKind(for: profile.kind), account: profile.id.description)
            throw error
        }
        do {
            try await saveServerSetupMirror()
        } catch {
            startupError = "The server was added on this device, but its cross-device setup copy could not be saved yet. Tsundoku will retry automatically."
        }
        // Refresh the observable profile list, then perform exactly one
        // connection validation through the awaited activation below.
        let records = try context.fetch(FetchDescriptor<ServerProfileRecord>(sortBy: [SortDescriptor(\.modifiedAt, order: .reverse)]))
        profiles = records.compactMap(\.value)
        activeProfile = profiles.first(where: { $0.id == profile.id }) ?? profile
        await activate(profile)
    }

    func activate(_ profile: ServerProfile) async {
        if await activate(profile, missingCredentialIsTransient: false) == .connected {
            setupSyncStatus = .ready
        }
    }

    private func activate(_ profile: ServerProfile, missingCredentialIsTransient: Bool) async -> ActivationResult {
        let requestID = UUID()
        activationRequestID = requestID
        activeClient = nil
        do {
            guard let key = try await credentials.value(kind: credentialKind(for: profile.kind), account: profile.id.description) else {
                if missingCredentialIsTransient {
                    setupSyncStatus = .waitingForCredentials
                    startupError = nil
                } else {
                    startupError = "The credential for \(profile.name) is missing. iCloud Keychain may still be syncing; try again shortly."
                }
                return .missingCredential
            }
            let client: ServerClient
            switch profile.kind {
            case .komga:
                let komga = KomgaClient(profile: profile, apiKey: key)
                _ = try await komga.currentUser()
                client = ServerClient(komga: komga, profile: profile)
            case .kavita:
                let kavita = KavitaClient(
                    profile: profile,
                    authKey: key,
                    deviceID: installationDeviceID,
                    userAgent: userAgent
                )
                _ = try await kavita.validateConnection()
                client = ServerClient(kavita: kavita, profile: profile)
            }
            guard activationRequestID == requestID else { return .superseded }
            activeClient = client
            activeProfile = profile
            downloads.register(client)
            let context = modelContainer.mainContext
            let records = try context.fetch(FetchDescriptor<ServerProfileRecord>())
            records.forEach {
                let shouldBeActive = $0.id == profile.id.description
                if $0.isActive != shouldBeActive {
                    $0.isActive = shouldBeActive
                    $0.modifiedAt = .now
                }
            }
            try context.save()
            try? await saveServerSetupMirror()
            profiles = profiles.map { value in
                var copy = value
                copy.isActive = value.id == profile.id
                return copy
            }
            startupError = nil
            await progress.retryPending(client: client)
            return .connected
        } catch {
            if activationRequestID == requestID {
                if !missingCredentialIsTransient {
                    startupError = error.localizedDescription
                }
            }
            return .failed(error.localizedDescription)
        }
    }

    /// Refetches CloudKit-backed setup and retries iCloud Keychain credentials.
    /// CloudKit and Keychain are independent services and can finish importing
    /// in either order on a newly installed device.
    func beginSetupReconciliation() {
        guard !Self.isRunningUnitTests else { return }
        setupReconciliationTask?.cancel()
        setupReconciliationTask = Task { [weak self] in
            await self?.reconcileSyncedSetup()
        }
    }

    func pauseSetupReconciliation() {
        setupReconciliationTask?.cancel()
        setupReconciliationTask = nil
    }

    private func reconcileSyncedSetup() async {
        setupSyncStatus = .checking
        await refreshCloudSyncStatus()
        let delays: [Duration] = [.zero, .seconds(2), .seconds(5), .seconds(10), .seconds(20), .seconds(30)]
        var attempt = 0
        var missingCredentialAttempts = 0
        var connectionFailureAttempts = 0
        while !Task.isCancelled {
            let delay = delays[min(attempt, delays.count - 1)]
            if delay != .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }

            await reconcileServerSetupMirror()
            await reconcileHomeStateMirror()
            await reconcileReadingStatisticsMirror()
            loadProfiles(activateClient: false)
            refreshPinnedSeries()
            trackers.refreshConfiguration()
            await trackers.reconcileKeychainConfiguration()
            await trackers.reconcileKeychainLinks()
            await trackers.reconcileKeychainPromptState()
            await trackers.refreshConnections()
            await trackers.retryPending()

            guard let profile = activeProfile else {
                // Keep checking because an empty local store can precede the
                // first CloudKit or Keychain import on a newly installed device.
                attempt += 1
                continue
            }
            if activeClient?.profile == profile {
                setupSyncStatus = .ready
                missingCredentialAttempts = 0
            } else {
                switch await activate(profile, missingCredentialIsTransient: true) {
                case .connected:
                    setupSyncStatus = .ready
                    missingCredentialAttempts = 0
                    connectionFailureAttempts = 0
                case .missingCredential:
                    missingCredentialAttempts += 1
                    connectionFailureAttempts = 0
                    if missingCredentialAttempts >= delays.count {
                        startupError = "Your server setup arrived from iCloud, but its credential has not arrived from iCloud Keychain yet. Keep Tsundoku open and try again shortly."
                    }
                case .superseded:
                    connectionFailureAttempts = 0
                case .failed(let message):
                    connectionFailureAttempts += 1
                    if let sustainedError = StartupConnectionErrorPolicy.message(
                        failureCount: connectionFailureAttempts,
                        latestError: message
                    ) {
                        startupError = sustainedError
                    }
                    // The setup itself is present. Retry in the background and
                    // surface only a sustained outage, not a startup network blip.
                    setupSyncStatus = .ready
                }
            }
            attempt += 1
        }
    }

    func remove(_ profile: ServerProfile) async throws {
        let context = modelContainer.mainContext
        let id = profile.id.description
        let descriptor = FetchDescriptor<ServerProfileRecord>(predicate: #Predicate { $0.id == id })
        let remainingProfiles = ServerSetupMirror.profiles(
            from: try context.fetch(FetchDescriptor<ServerProfileRecord>()).filter { $0.id != id }
        )
        try await saveServerSetupMirror(remainingProfiles, force: true)
        try context.fetch(descriptor).forEach(context.delete)
        try context.save()
        try await credentials.delete(kind: credentialKind(for: profile.kind), account: id)
        defaults.removeObject(forKey: defaultLibraryKey(serverID: id))
        defaults.removeObject(forKey: cachedLibrariesKey(serverID: id))
        if activeProfile?.id == profile.id {
            activationRequestID = UUID()
            activeClient = nil
            activeProfile = nil
        }
        let remainingPins = pinnedSeriesKeys.filter { $0.serverID != profile.id }
        if remainingPins != pinnedSeriesKeys { persistPinnedSeries(remainingPins) }
        loadProfiles()
    }

    /// Clears device-only data while retaining CloudKit setup and synchronizable
    /// Keychain credentials so the configuration can restore automatically.
    func resetThisDevice() async throws {
        pauseSetupReconciliation()
        activationRequestID = UUID()
        activeClient = nil
        progress.prepareForDeviceReset()
        await downloads.prepareForDeviceReset()

        let context = modelContainer.mainContext
        try DeviceResetPolicy.deleteLocalRecords(in: context)
        try context.save()

        let storedDefaults = Bundle.main.bundleIdentifier
            .flatMap { defaults.persistentDomain(forName: $0) }
            ?? defaults.dictionaryRepresentation()
        for key in storedDefaults.keys { defaults.removeObject(forKey: key) }
        try DownloadPaths.removeAll()
        let pageCache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "PageCache", directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: pageCache.path) {
            try FileManager.default.removeItem(at: pageCache)
        }
        URLCache.shared.removeAllCachedResponses()
        await posters.removeAll()
        posterCacheRevision &+= 1
        pinnedSeriesKeys = []
        continueReadingActivities = []
        recentBookActivities = []
        refreshReadingStatisticsBuckets()
        refreshSystemIntegrationSnapshot(reindexSeries: true)
        startupError = nil
        setupSyncStatus = .checking
        loadProfiles(activateClient: false)
        beginSetupReconciliation()
    }

    /// Removes shared server/tracker setup from CloudKit and synchronizable
    /// Keychain, then performs the same device-local reset.
    func eraseSyncedSetupEverywhere() async throws {
        pauseSetupReconciliation()
        let context = modelContainer.mainContext
        let serverRecords = try context.fetch(FetchDescriptor<ServerProfileRecord>())
        let serverProfiles = serverRecords.compactMap(\.value)
        try await saveServerSetupMirror([], force: true)
        serverRecords.forEach(context.delete)
        try context.fetch(FetchDescriptor<TrackerLinkRecord>()).forEach(context.delete)
        try await trackers.eraseSyncedConfiguration()
        try context.save()

        for profile in serverProfiles {
            try? await credentials.delete(kind: credentialKind(for: profile.kind), account: profile.id.description)
        }
        for service in TrackerService.allCases { await trackers.disconnect(service) }
        try await resetThisDevice()
    }

    func defaultLibraryID(for serverID: ServerID) -> String? {
        let value = defaults.string(forKey: defaultLibraryKey(serverID: serverID.description))
        return value?.isEmpty == false ? value : nil
    }

    func setDefaultLibraryID(_ libraryID: String?, for serverID: ServerID) {
        let key = defaultLibraryKey(serverID: serverID.description)
        if let libraryID, !libraryID.isEmpty {
            defaults.set(libraryID, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    func cachedLibraries(for serverID: ServerID) -> [Library] {
        guard let data = defaults.data(forKey: cachedLibrariesKey(serverID: serverID.description)) else { return [] }
        return (try? JSONDecoder().decode([Library].self, from: data)) ?? []
    }

    func cacheLibraries(_ libraries: [Library], for serverID: ServerID) {
        guard let data = try? JSONEncoder().encode(libraries) else { return }
        defaults.set(data, forKey: cachedLibrariesKey(serverID: serverID.description))
    }

    /// Removes only cached cover artwork. Downloads, catalog fallback data,
    /// bookmarks, history, and reading progress are intentionally preserved.
    func refreshPosterArtwork() async {
        await posters.removeAll()
        posterCacheRevision &+= 1
    }

    func readerPreferences() -> ReaderPreferences? {
        let localPreferences = defaults.data(forKey: readerPreferencesDataKey)
            .flatMap { try? JSONDecoder().decode(ReaderPreferences.self, from: $0) }
        let localModifiedAt = defaults.object(forKey: readerPreferencesModifiedAtKey) as? Date ?? .distantPast
        let recordID = "global"
        let descriptor = FetchDescriptor<PreferenceRecord>(
            predicate: #Predicate { $0.id == recordID },
            sortBy: [SortDescriptor(\.modifiedAt, order: .reverse)]
        )
        let cloudRecord = try? modelContainer.mainContext.fetch(descriptor).first
        let cloudPreferences = cloudRecord.flatMap { try? JSONDecoder().decode(ReaderPreferences.self, from: $0.encodedPreferences) }

        if let cloudRecord, let cloudPreferences, cloudRecord.modifiedAt > localModifiedAt {
            mirrorReaderPreferencesLocally(cloudPreferences, modifiedAt: cloudRecord.modifiedAt)
            return cloudPreferences
        }
        return localPreferences ?? cloudPreferences
    }

    func setReaderPreferences(_ preferences: ReaderPreferences) {
        let modifiedAt = Date.now
        mirrorReaderPreferencesLocally(preferences, modifiedAt: modifiedAt)
        guard let encoded = try? JSONEncoder().encode(preferences) else { return }

        let context = modelContainer.mainContext
        let recordID = "global"
        let descriptor = FetchDescriptor<PreferenceRecord>(
            predicate: #Predicate { $0.id == recordID },
            sortBy: [SortDescriptor(\.modifiedAt, order: .reverse)]
        )
        if let record = try? context.fetch(descriptor).first {
            record.encodedPreferences = encoded
            record.modifiedAt = modifiedAt
        } else {
            let record = PreferenceRecord(id: recordID, preferences: preferences)
            record.modifiedAt = modifiedAt
            context.insert(record)
        }
        try? context.save()
    }

    func epubReaderPreferences() -> EPUBReaderPreferences {
        defaults.data(forKey: epubReaderPreferencesKey)
            .flatMap { try? JSONDecoder().decode(EPUBReaderPreferences.self, from: $0) }
            ?? EPUBReaderPreferences()
    }

    func setEPUBReaderPreferences(_ preferences: EPUBReaderPreferences) {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: epubReaderPreferencesKey)
    }

    func isPinned(_ series: Series) -> Bool {
        pinnedSeriesKeys.contains(series.key)
    }

    func setPinned(_ pinned: Bool, series: Series) {
        refreshPinnedSeries()
        let values: [SeriesKey]
        if pinned {
            guard !pinnedSeriesKeys.contains(series.key) else { return }
            values = pinnedSeriesKeys + [series.key]
        } else {
            guard pinnedSeriesKeys.contains(series.key) else { return }
            values = pinnedSeriesKeys.filter { $0 != series.key }
        }
        persistPinnedSeries(values)
    }

    func recordHistory(book: Book, seriesTitle: String, page: Int) {
        let context = modelContainer.mainContext
        let bookID = book.key.remoteID
        let serverID = book.key.serverID.description
        let descriptor = FetchDescriptor<HistoryRecord>(predicate: #Predicate {
            $0.bookID == bookID && $0.serverID == serverID
        })
        let readAt = Date.now
        if let record = try? context.fetch(descriptor).first {
            record.page = page
            record.readAt = readAt
        } else {
            let record = HistoryRecord(book: book, seriesTitle: seriesTitle, page: page)
            record.readAt = readAt
            context.insert(record)
        }
        try? context.save()

        let activity = HomeSeriesActivity(
            serverID: serverID,
            seriesID: book.seriesKey.remoteID,
            seriesTitle: seriesTitle,
            readAt: readAt
        )
        continueReadingActivities = HomeSyncPolicy.mergeActivities(
            continueReadingActivities,
            [activity]
        )
        mirrorContinueReadingLocally(continueReadingActivities)
        let bookActivity = HomeBookActivity(
            serverID: serverID,
            seriesID: book.seriesKey.remoteID,
            bookID: book.key.remoteID,
            seriesTitle: seriesTitle,
            bookTitle: book.displayTitle,
            page: page,
            pageCount: book.pageCount,
            readAt: readAt
        )
        recentBookActivities = HomeSyncPolicy.mergeBookActivities(
            recentBookActivities,
            [bookActivity]
        )
        mirrorRecentBooksLocally(recentBookActivities)
        scheduleHomeStateMirror()
        refreshSystemIntegrationSnapshot()
    }

    /// Removes every local resume signal for a server-acknowledged Mark Unread.
    /// A page-one activity is still meaningful when it came from actual reading,
    /// so removal is keyed by the exact book rather than by page number.
    func clearReadingProgress(for book: Book) {
        let context = modelContainer.mainContext
        let bookID = book.key.remoteID
        let serverID = book.key.serverID.description
        let seriesID = book.seriesKey.remoteID
        let descriptor = FetchDescriptor<HistoryRecord>(predicate: #Predicate {
            $0.bookID == bookID && $0.serverID == serverID
        })
        if let records = try? context.fetch(descriptor) {
            records.forEach(context.delete)
        }
        try? context.save()

        recentBookActivities.removeAll {
            $0.serverID == serverID && $0.bookID == bookID
        }
        let seriesStillHasProgress = recentBookActivities.contains {
            $0.serverID == serverID && $0.seriesID == seriesID
        } || historyBookActivities().contains {
            $0.serverID == serverID && $0.seriesID == seriesID
        }
        if !seriesStillHasProgress {
            continueReadingActivities.removeAll {
                $0.serverID == serverID && $0.seriesID == seriesID
            }
        }
        mirrorContinueReadingLocally(continueReadingActivities)
        mirrorRecentBooksLocally(recentBookActivities)
        refreshSystemIntegrationSnapshot()
        scheduleHomeStateMirror(replacingActivities: true)
    }

    /// Cleans resume artifacts left by older builds after a manual Read/Unread
    /// operation. Server series state is authoritative, while a durable local
    /// checkpoint protects reading that has not reached the server yet.
    func reconcileFinishedResumeActivities(with seriesValues: [Series]) {
        let serversAndSeriesWithoutProgress = Set(seriesValues.compactMap { series -> String? in
            guard series.booksInProgressCount == 0 else { return nil }
            return series.key.id
        })
        let stale = recentBookActivities.filter { activity in
            guard serversAndSeriesWithoutProgress.contains("\(activity.serverID):series:\(activity.seriesID)"),
                  let uuid = UUID(uuidString: activity.serverID) else { return false }
            return progress.pendingCheckpoint(
                for: BookKey(serverID: ServerID(uuid), remoteID: activity.bookID)
            ) == nil
        }
        guard !stale.isEmpty else { return }

        let context = modelContainer.mainContext
        for activity in stale {
            let serverID = activity.serverID
            let bookID = activity.bookID
            let descriptor = FetchDescriptor<HistoryRecord>(predicate: #Predicate {
                $0.serverID == serverID && $0.bookID == bookID
            })
            if let records = try? context.fetch(descriptor) {
                records.forEach(context.delete)
            }
        }
        try? context.save()

        let staleIDs = Set(stale.map(\.id))
        recentBookActivities.removeAll { staleIDs.contains($0.id) }
        let activeSeriesIDs = Set(recentBookActivities.map { "\($0.serverID):\($0.seriesID)" })
        continueReadingActivities.removeAll { activity in
            !activeSeriesIDs.contains(activity.id)
                && stale.contains { staleActivity in
                    staleActivity.serverID == activity.serverID
                        && staleActivity.seriesID == activity.seriesID
                }
        }
        mirrorContinueReadingLocally(continueReadingActivities)
        mirrorRecentBooksLocally(recentBookActivities)
        refreshSystemIntegrationSnapshot()
        scheduleHomeStateMirror(replacingActivities: true)
    }

    /// Reconciles the fast local mirror with the CloudKit-backed preference
    /// record. The most recently modified copy wins, matching reader settings.
    func refreshPinnedSeries() {
        let localValue = defaults.data(forKey: pinnedSeriesDataKey)
            .flatMap { try? JSONDecoder().decode(PinnedSeriesPreferences.self, from: $0) }
        let localModifiedAt = defaults.object(forKey: pinnedSeriesModifiedAtKey) as? Date ?? .distantPast
        let recordID = pinnedSeriesRecordID
        let descriptor = FetchDescriptor<PreferenceRecord>(
            predicate: #Predicate { $0.id == recordID },
            sortBy: [SortDescriptor(\.modifiedAt, order: .reverse)]
        )
        let cloudRecord = try? modelContainer.mainContext.fetch(descriptor).first
        let cloudValue = cloudRecord.flatMap {
            try? JSONDecoder().decode(PinnedSeriesPreferences.self, from: $0.encodedPreferences)
        }

        if let cloudRecord, let cloudValue, cloudRecord.modifiedAt > localModifiedAt {
            pinnedSeriesKeys = cloudValue.keys
            mirrorPinnedSeriesLocally(cloudValue, modifiedAt: cloudRecord.modifiedAt)
        } else {
            pinnedSeriesKeys = localValue?.keys ?? cloudValue?.keys ?? []
        }
    }

    func refreshContinueReadingActivities() {
        let mirrored = defaults.data(forKey: homeActivitiesDataKey)
            .flatMap { try? JSONDecoder().decode([HomeSeriesActivity].self, from: $0) }
            ?? []
        continueReadingActivities = HomeSyncPolicy.mergeActivities(
            mirrored,
            historyActivities()
        )
        let mirroredBooks = defaults.data(forKey: recentBookActivitiesDataKey)
            .flatMap { try? JSONDecoder().decode([HomeBookActivity].self, from: $0) }
            ?? []
        recentBookActivities = HomeSyncPolicy.mergeBookActivities(
            mirroredBooks,
            historyBookActivities()
        )
        mirrorContinueReadingLocally(continueReadingActivities)
        mirrorRecentBooksLocally(recentBookActivities)
    }

    private func defaultLibraryKey(serverID: String) -> String {
        "defaultLibrary.\(serverID)"
    }

    private func cachedLibrariesKey(serverID: String) -> String {
        "cachedLibraries.\(serverID)"
    }

    private var readerPreferencesDataKey: String { "readerPreferences.global.data" }
    private var readerPreferencesModifiedAtKey: String { "readerPreferences.global.modifiedAt" }
    private var epubReaderPreferencesKey: String { "epubReaderPreferences.global.data" }
    private var pinnedSeriesRecordID: String { "pinnedSeries.global.v1" }
    private var pinnedSeriesDataKey: String { "pinnedSeries.global.data" }
    private var pinnedSeriesModifiedAtKey: String { "pinnedSeries.global.modifiedAt" }
    private var homeActivitiesDataKey: String { "homeActivities.global.data" }
    private var recentBookActivitiesDataKey: String { "recentBookActivities.global.data" }

    var installationDeviceID: String {
        let key = "tsundoku.installationDeviceID"
        if let value = defaults.string(forKey: key), UUID(uuidString: value) != nil { return value }
        let value = UUID().uuidString
        defaults.set(value, forKey: key)
        return value
    }

    private var userAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        return "Tsundoku-iOS/\(version)"
    }

    private func credentialKind(for serverKind: ServerKind) -> CredentialStore.Kind {
        serverKind == .komga ? .komgaAPIKey : .kavitaAuthKey
    }

    private func mirrorReaderPreferencesLocally(_ preferences: ReaderPreferences, modifiedAt: Date) {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: readerPreferencesDataKey)
        defaults.set(modifiedAt, forKey: readerPreferencesModifiedAtKey)
    }

    private func persistPinnedSeries(_ keys: [SeriesKey]) {
        let uniqueKeys = keys.reduce(into: [SeriesKey]()) { result, key in
            if !result.contains(key) { result.append(key) }
        }
        let modifiedAt = Date.now
        applyPinnedSeries(uniqueKeys, modifiedAt: modifiedAt)
        scheduleHomeStateMirror()
    }

    private func applyPinnedSeries(_ keys: [SeriesKey], modifiedAt: Date) {
        let preferences = PinnedSeriesPreferences(keys: keys)
        guard let encoded = try? JSONEncoder().encode(preferences) else { return }
        pinnedSeriesKeys = keys
        mirrorPinnedSeriesLocally(preferences, modifiedAt: modifiedAt)

        let context = modelContainer.mainContext
        let recordID = pinnedSeriesRecordID
        let descriptor = FetchDescriptor<PreferenceRecord>(
            predicate: #Predicate { $0.id == recordID },
            sortBy: [SortDescriptor(\.modifiedAt, order: .reverse)]
        )
        if let record = try? context.fetch(descriptor).first {
            record.encodedPreferences = encoded
            record.modifiedAt = modifiedAt
        } else {
            let record = PreferenceRecord(id: recordID, encodedValue: encoded)
            record.modifiedAt = modifiedAt
            context.insert(record)
        }
        try? context.save()
    }

    private func reconcileHomeStateMirror() async {
        refreshPinnedSeries()
        refreshContinueReadingActivities()
        let localPinsModifiedAt = defaults.object(forKey: pinnedSeriesModifiedAtKey) as? Date ?? .distantPast
        do {
            guard let encoded = try await credentials.value(kind: .homeState, account: "default") else {
                guard !pinnedSeriesKeys.isEmpty || !continueReadingActivities.isEmpty || !recentBookActivities.isEmpty else { return }
                await saveHomeStateMirror()
                return
            }
            guard let data = encoded.data(using: .utf8),
                  let remote = try? JSONDecoder().decode(HomeSyncSnapshot.self, from: data) else { return }

            var selectedPins = pinnedSeriesKeys
            var selectedPinsModifiedAt = localPinsModifiedAt
            if remote.pinsModifiedAt > localPinsModifiedAt {
                selectedPins = remote.pinnedSeriesKeys
                selectedPinsModifiedAt = remote.pinsModifiedAt
                applyPinnedSeries(selectedPins, modifiedAt: selectedPinsModifiedAt)
            }
            let mergedActivities = HomeSyncPolicy.mergeActivities(
                continueReadingActivities,
                remote.continueReading
            )
            let mergedBooks = HomeSyncPolicy.mergeBookActivities(
                recentBookActivities,
                remote.recentBooks
            )
            if mergedActivities != continueReadingActivities {
                continueReadingActivities = mergedActivities
                mirrorContinueReadingLocally(mergedActivities)
            }
            if mergedBooks != recentBookActivities {
                recentBookActivities = mergedBooks
                mirrorRecentBooksLocally(mergedBooks)
            }
            let merged = HomeSyncSnapshot(
                pinnedSeriesKeys: selectedPins,
                pinsModifiedAt: selectedPinsModifiedAt,
                continueReading: mergedActivities,
                recentBooks: mergedBooks,
                modifiedAt: max(
                    remote.modifiedAt,
                    max(
                        mergedActivities.first?.readAt ?? .distantPast,
                        mergedBooks.first?.readAt ?? .distantPast
                    )
                )
            )
            if merged != remote {
                try await saveHomeStateSnapshot(merged)
            }
        } catch {
            // CloudKit-backed preferences/history remain the fallback.
        }
    }

    private func saveHomeStateMirror() async {
        refreshPinnedSeries()
        refreshContinueReadingActivities()
        let pinsModifiedAt = defaults.object(forKey: pinnedSeriesModifiedAtKey) as? Date ?? .distantPast
        do {
            let remote: HomeSyncSnapshot? = try await credentials.value(kind: .homeState, account: "default")
                .flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONDecoder().decode(HomeSyncSnapshot.self, from: $0) }
            let useRemotePins = (remote?.pinsModifiedAt ?? .distantPast) > pinsModifiedAt
            let activities = HomeSyncPolicy.mergeActivities(
                remote?.continueReading ?? [],
                continueReadingActivities
            )
            let books = HomeSyncPolicy.mergeBookActivities(
                remote?.recentBooks ?? [],
                recentBookActivities
            )
            let snapshot = HomeSyncSnapshot(
                pinnedSeriesKeys: useRemotePins ? remote?.pinnedSeriesKeys ?? [] : pinnedSeriesKeys,
                pinsModifiedAt: useRemotePins ? remote?.pinsModifiedAt ?? pinsModifiedAt : pinsModifiedAt,
                continueReading: activities,
                recentBooks: books,
                modifiedAt: .now
            )
            if snapshot != remote { try await saveHomeStateSnapshot(snapshot) }
        } catch {
            // Best effort; the next foreground reconciliation retries it.
        }
    }

    private func scheduleHomeStateMirror(replacingActivities: Bool = false) {
        guard !Self.isRunningUnitTests else { return }
        Task {
            if replacingActivities {
                await replaceHomeStateActivities()
            } else {
                await saveHomeStateMirror()
            }
        }
    }

    /// Mark Unread is an explicit deletion, so an older append-only Keychain
    /// mirror must not immediately restore the activity that was just removed.
    private func replaceHomeStateActivities() async {
        refreshPinnedSeries()
        let pinsModifiedAt = defaults.object(forKey: pinnedSeriesModifiedAtKey) as? Date ?? .distantPast
        let snapshot = HomeSyncSnapshot(
            pinnedSeriesKeys: pinnedSeriesKeys,
            pinsModifiedAt: pinsModifiedAt,
            continueReading: continueReadingActivities,
            recentBooks: recentBookActivities,
            modifiedAt: .now
        )
        try? await saveHomeStateSnapshot(snapshot)
    }

    private func saveHomeStateSnapshot(_ snapshot: HomeSyncSnapshot) async throws {
        let data = try JSONEncoder().encode(snapshot)
        guard let value = String(data: data, encoding: .utf8) else { return }
        try await credentials.save(value, kind: .homeState, account: "default")
    }

    private func historyActivities() -> [HomeSeriesActivity] {
        let records = (try? modelContainer.mainContext.fetch(
            FetchDescriptor<HistoryRecord>(sortBy: [SortDescriptor(\.readAt, order: .reverse)])
        )) ?? []
        return HomeSyncPolicy.mergeActivities([], records.map {
            HomeSeriesActivity(
                serverID: $0.serverID,
                seriesID: $0.seriesID,
                seriesTitle: $0.seriesTitle,
                readAt: $0.readAt
            )
        })
    }

    private func historyBookActivities() -> [HomeBookActivity] {
        let context = modelContainer.mainContext
        let records = (try? context.fetch(
            FetchDescriptor<HistoryRecord>(sortBy: [SortDescriptor(\.readAt, order: .reverse)])
        )) ?? []
        let cachedBooks = (try? context.fetch(FetchDescriptor<CachedBookRecord>())) ?? []
        let booksByID = Dictionary(uniqueKeysWithValues: cachedBooks.compactMap { record in
            (try? JSONDecoder().decode(Book.self, from: record.payload)).map { ($0.key.id, $0) }
        })
        return HomeSyncPolicy.mergeBookActivities([], records.map { record in
            let cached = booksByID["\(record.serverID):book:\(record.bookID)"]
            return HomeBookActivity(
                serverID: record.serverID,
                seriesID: record.seriesID,
                bookID: record.bookID,
                seriesTitle: record.seriesTitle,
                bookTitle: record.bookTitle,
                page: record.page,
                pageCount: cached?.pageCount ?? max(1, record.page),
                readAt: record.readAt
            )
        })
    }

    private func mirrorContinueReadingLocally(_ activities: [HomeSeriesActivity]) {
        guard let data = try? JSONEncoder().encode(activities) else { return }
        defaults.set(data, forKey: homeActivitiesDataKey)
    }

    private func mirrorRecentBooksLocally(_ activities: [HomeBookActivity]) {
        guard let data = try? JSONEncoder().encode(activities) else { return }
        defaults.set(data, forKey: recentBookActivitiesDataKey)
    }

    private func mirrorPinnedSeriesLocally(_ preferences: PinnedSeriesPreferences, modifiedAt: Date) {
        guard let encoded = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(encoded, forKey: pinnedSeriesDataKey)
        defaults.set(modifiedAt, forKey: pinnedSeriesModifiedAtKey)
    }
}

enum DeviceResetPolicy {
    @MainActor
    static func deleteLocalRecords(in context: ModelContext) throws {
        try context.fetch(FetchDescriptor<CachedSeriesRecord>()).forEach(context.delete)
        try context.fetch(FetchDescriptor<CachedBookRecord>()).forEach(context.delete)
        try context.fetch(FetchDescriptor<PendingProgressRecord>()).forEach(context.delete)
        try context.fetch(FetchDescriptor<DownloadRecord>()).forEach(context.delete)
        try context.fetch(FetchDescriptor<TrackerMutationRecord>()).forEach(context.delete)
    }
}

struct ServerSetupSnapshot: Codable, Equatable {
    var version = 1
    let profiles: [ServerProfile]
    let modifiedAt: Date
}

enum ServerSetupMirror {
    static func normalized(_ profiles: [ServerProfile]) -> [ServerProfile] {
        var newestByID: [ServerID: ServerProfile] = [:]
        for profile in profiles { newestByID[profile.id] = profile }
        return newestByID.values.sorted { $0.id.description < $1.id.description }
    }

    @MainActor
    static func profiles(from records: [ServerProfileRecord]) -> [ServerProfile] {
        var newestByID: [String: ServerProfileRecord] = [:]
        for record in records where (newestByID[record.id]?.modifiedAt ?? .distantPast) < record.modifiedAt {
            newestByID[record.id] = record
        }
        return normalized(newestByID.values.compactMap(\.value))
    }

    @MainActor
    @discardableResult
    static func apply(_ snapshot: ServerSetupSnapshot, to context: ModelContext) throws -> Bool {
        let desired = normalized(snapshot.profiles)
        let records = try context.fetch(FetchDescriptor<ServerProfileRecord>())
        if profiles(from: records) == desired, records.count == desired.count { return false }

        var recordsByID = Dictionary(grouping: records, by: \.id)
        let desiredIDs = Set(desired.map { $0.id.description })
        for record in records where !desiredIDs.contains(record.id) { context.delete(record) }

        for profile in desired {
            let id = profile.id.description
            let matches = (recordsByID[id] ?? []).sorted { $0.modifiedAt > $1.modifiedAt }
            if let record = matches.first {
                record.name = profile.name
                record.baseURL = profile.baseURL.absoluteString
                record.userID = profile.userID
                record.username = profile.username
                record.isActive = profile.isActive
                record.providerRaw = profile.kind.rawValue
                record.modifiedAt = snapshot.modifiedAt
                matches.dropFirst().forEach(context.delete)
            } else {
                let record = ServerProfileRecord(profile: profile)
                record.modifiedAt = snapshot.modifiedAt
                context.insert(record)
            }
            recordsByID[id] = nil
        }
        return true
    }
}

private struct PinnedSeriesPreferences: Codable {
    let keys: [SeriesKey]
}

struct HomeSeriesActivity: Codable, Hashable, Sendable, Identifiable {
    let serverID: String
    let seriesID: String
    let seriesTitle: String
    let readAt: Date

    var id: String { "\(serverID):\(seriesID)" }
}

struct HomeBookActivity: Codable, Hashable, Sendable, Identifiable {
    let serverID: String
    let seriesID: String
    let bookID: String
    let seriesTitle: String
    let bookTitle: String
    let page: Int
    let pageCount: Int
    let readAt: Date

    var id: String { "\(serverID):\(bookID)" }
}

struct HomeSyncSnapshot: Codable, Equatable, Sendable {
    var version = 2
    let pinnedSeriesKeys: [SeriesKey]
    let pinsModifiedAt: Date
    let continueReading: [HomeSeriesActivity]
    let recentBooks: [HomeBookActivity]
    let modifiedAt: Date

    init(
        pinnedSeriesKeys: [SeriesKey],
        pinsModifiedAt: Date,
        continueReading: [HomeSeriesActivity],
        recentBooks: [HomeBookActivity],
        modifiedAt: Date
    ) {
        self.pinnedSeriesKeys = pinnedSeriesKeys
        self.pinsModifiedAt = pinsModifiedAt
        self.continueReading = continueReading
        self.recentBooks = recentBooks
        self.modifiedAt = modifiedAt
    }

    private enum CodingKeys: String, CodingKey {
        case version, pinnedSeriesKeys, pinsModifiedAt, continueReading, recentBooks, modifiedAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        pinnedSeriesKeys = try values.decode([SeriesKey].self, forKey: .pinnedSeriesKeys)
        pinsModifiedAt = try values.decode(Date.self, forKey: .pinsModifiedAt)
        continueReading = try values.decodeIfPresent([HomeSeriesActivity].self, forKey: .continueReading) ?? []
        recentBooks = try values.decodeIfPresent([HomeBookActivity].self, forKey: .recentBooks) ?? []
        modifiedAt = try values.decode(Date.self, forKey: .modifiedAt)
    }
}

enum HomeSyncPolicy {
    static func mergeActivities(
        _ lhs: [HomeSeriesActivity],
        _ rhs: [HomeSeriesActivity],
        limit: Int = 20
    ) -> [HomeSeriesActivity] {
        var newest: [String: HomeSeriesActivity] = [:]
        for activity in lhs + rhs where (newest[activity.id]?.readAt ?? .distantPast) < activity.readAt {
            newest[activity.id] = activity
        }
        return Array(newest.values.sorted { $0.readAt > $1.readAt }.prefix(limit))
    }

    static func mergeBookActivities(
        _ lhs: [HomeBookActivity],
        _ rhs: [HomeBookActivity],
        limit: Int = 20
    ) -> [HomeBookActivity] {
        var newest: [String: HomeBookActivity] = [:]
        for activity in lhs + rhs where (newest[activity.id]?.readAt ?? .distantPast) < activity.readAt {
            newest[activity.id] = activity
        }
        return Array(newest.values.sorted { $0.readAt > $1.readAt }.prefix(limit))
    }
}
