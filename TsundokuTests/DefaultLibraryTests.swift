import Foundation
import Testing
@testable import Tsundoku

struct DefaultLibraryTests {
    @MainActor
    @Test func defaultLibraryIsStoredPerServer() throws {
        let suiteName = "DefaultLibraryTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = AppState(modelContainer: try AppModelContainer.make(inMemory: true), defaults: defaults)
        let firstServer = ServerID()
        let secondServer = ServerID()

        state.setDefaultLibraryID("manga", for: firstServer)
        state.setDefaultLibraryID("comics", for: secondServer)

        #expect(state.defaultLibraryID(for: firstServer) == "manga")
        #expect(state.defaultLibraryID(for: secondServer) == "comics")

        state.setDefaultLibraryID(nil, for: firstServer)
        #expect(state.defaultLibraryID(for: firstServer) == nil)
        #expect(state.defaultLibraryID(for: secondServer) == "comics")
    }

    @MainActor
    @Test func libraryListCacheRoundTrips() throws {
        let suiteName = "LibraryCacheTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = AppState(modelContainer: try AppModelContainer.make(inMemory: true), defaults: defaults)
        let serverID = ServerID()
        let libraries = [
            Library(id: "manga", name: "Manga", unavailable: false),
            Library(id: "offline", name: "Unavailable", unavailable: true)
        ]

        state.cacheLibraries(libraries, for: serverID)

        #expect(state.cachedLibraries(for: serverID) == libraries)
    }

    @Test func startupConnectionErrorRequiresSustainedFailures() {
        #expect(StartupConnectionErrorPolicy.message(failureCount: 1, latestError: "Offline") == nil)
        #expect(StartupConnectionErrorPolicy.message(failureCount: 2, latestError: "Offline") == nil)
        #expect(StartupConnectionErrorPolicy.message(failureCount: 3, latestError: "Offline") == "Offline")
    }
}
