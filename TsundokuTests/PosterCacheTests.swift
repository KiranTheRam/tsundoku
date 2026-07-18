import Foundation
import Testing
@testable import Tsundoku

struct PosterCacheTests {
    @Test
    func manualRefreshRemovesCachedArtworkButKeepsCacheUsable() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let cacheDirectory = root.appending(path: "PosterCache", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let staleCover = cacheDirectory.appending(path: "stale.img")
        try Data("old cover".utf8).write(to: staleCover)
        defer { try? FileManager.default.removeItem(at: root) }

        let cache = PosterCache(directory: root)
        #expect(FileManager.default.fileExists(atPath: staleCover.path))

        await cache.removeAll()

        #expect(!FileManager.default.fileExists(atPath: staleCover.path))
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: cacheDirectory.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }
}
