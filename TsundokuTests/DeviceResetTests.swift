import Foundation
import SwiftData
import Testing
@testable import Tsundoku

struct DeviceResetTests {
    @MainActor
    @Test func deviceResetDeletesLocalCatalogButPreservesCloudSetup() throws {
        let container = try AppModelContainer.make(inMemory: true)
        let serverID = ServerID()
        let profile = ServerProfile(
            id: serverID,
            name: "Synced server",
            baseURL: URL(string: "https://example.com")!,
            userID: "reader",
            username: "reader@example.com",
            isActive: true,
            kind: .komga
        )
        let series = Series(
            key: SeriesKey(serverID: serverID, remoteID: "series"),
            libraryID: "library",
            title: "Cached series",
            summary: "",
            status: "",
            readingDirection: "LEFT_TO_RIGHT",
            genres: [],
            tags: [],
            booksCount: 1,
            booksReadCount: 0,
            booksInProgressCount: 0,
            lastModified: nil
        )
        container.mainContext.insert(ServerProfileRecord(profile: profile))
        container.mainContext.insert(CachedSeriesRecord(series: series))
        try container.mainContext.save()

        try DeviceResetPolicy.deleteLocalRecords(in: container.mainContext)
        try container.mainContext.save()

        #expect(try container.mainContext.fetchCount(FetchDescriptor<CachedSeriesRecord>()) == 0)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<ServerProfileRecord>()) == 1)
    }

    @MainActor
    @Test func keychainSetupSnapshotRestoresAndDeletesServerProfiles() throws {
        let container = try AppModelContainer.make(inMemory: true)
        let profile = ServerProfile(
            id: ServerID(),
            name: "Restored server",
            baseURL: URL(string: "https://reader.example.com")!,
            userID: "42",
            username: "reader",
            isActive: true,
            kind: .kavita
        )
        let restored = ServerSetupSnapshot(profiles: [profile], modifiedAt: .now)

        #expect(try ServerSetupMirror.apply(restored, to: container.mainContext))
        try container.mainContext.save()
        let records = try container.mainContext.fetch(FetchDescriptor<ServerProfileRecord>())
        #expect(records.count == 1)
        #expect(records.first?.value == profile)

        let erased = ServerSetupSnapshot(profiles: [], modifiedAt: .now.addingTimeInterval(1))
        #expect(try ServerSetupMirror.apply(erased, to: container.mainContext))
        try container.mainContext.save()
        #expect(try container.mainContext.fetchCount(FetchDescriptor<ServerProfileRecord>()) == 0)
    }

    @Test func setupSnapshotRoundTripsWithoutDuplicatingProfiles() throws {
        let id = ServerID()
        let older = ServerProfile(
            id: id,
            name: "Old name",
            baseURL: URL(string: "https://old.example.com")!,
            userID: "1",
            username: "reader",
            isActive: false,
            kind: .komga
        )
        var newer = older
        newer.name = "New name"
        let snapshot = ServerSetupSnapshot(profiles: [older, newer], modifiedAt: .now)
        let decoded = try JSONDecoder().decode(
            ServerSetupSnapshot.self,
            from: JSONEncoder().encode(snapshot)
        )

        #expect(ServerSetupMirror.normalized(decoded.profiles) == [newer])
    }
}
