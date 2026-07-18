import Foundation
import SwiftData

enum AppModelContainer {
    static var cloudContainerIdentifier: String {
        "iCloud.\(Bundle.main.bundleIdentifier ?? "com.example.Tsundoku")"
    }

    static let cloudTypes: [any PersistentModel.Type] = [
        ServerProfileRecord.self,
        PreferenceRecord.self,
        BookmarkRecord.self,
        HistoryRecord.self,
        TrackerLinkRecord.self
    ]

    static let localTypes: [any PersistentModel.Type] = [
        CachedSeriesRecord.self,
        CachedBookRecord.self,
        PendingProgressRecord.self,
        DownloadRecord.self,
        TrackerMutationRecord.self
    ]

    static func make(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema(cloudTypes + localTypes)
        if inMemory {
            return try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        }

        let cloudSchema = Schema(cloudTypes)
        let localSchema = Schema(localTypes)
        let cloud = ModelConfiguration(
            "Cloud",
            schema: cloudSchema,
            cloudKitDatabase: .automatic
        )
        let local = ModelConfiguration("Local", schema: localSchema, cloudKitDatabase: .none)
        // CloudKit-backed models retain a local store and remain usable while
        // offline or signed out. Do not silently replace this configuration with
        // a non-cloud store, because that makes cross-device sync appear enabled
        // while permanently disabling it for the launch.
        return try ModelContainer(for: schema, configurations: cloud, local)
    }
}
