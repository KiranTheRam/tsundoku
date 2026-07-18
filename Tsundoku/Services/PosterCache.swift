import Foundation
import WidgetKit

actor PosterCache {
    private let memory = NSCache<NSString, NSData>()
    private let directory: URL
    private var inFlight: [String: Task<Data, Error>] = [:]
    private var generation = 0

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory.appending(path: "PosterCache", directoryHint: .isDirectory)
        } else {
            self.directory = TsundokuSharedStore.coverDirectory
        }
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var cacheDirectory = self.directory
        try? cacheDirectory.setResourceValues(values)
        memory.countLimit = 240
        memory.totalCostLimit = 80 * 1_024 * 1_024
    }

    func data(for series: Series, client: ServerClient) async throws -> Data {
        let key = series.id
        if let cached = memory.object(forKey: key as NSString) {
            return cached as Data
        }

        let fileURL = fileURL(for: key)
        if let data = try? Data(contentsOf: fileURL), !data.isEmpty {
            memory.setObject(data as NSData, forKey: key as NSString, cost: data.count)
            return data
        }

        if let task = inFlight[key] {
            return try await task.value
        }

        let remoteID = series.key.remoteID
        let requestGeneration = generation
        let task = Task { try await client.posterData(seriesID: remoteID) }
        inFlight[key] = task
        do {
            let data = try await task.value
            inFlight[key] = nil
            guard requestGeneration == generation else { throw CancellationError() }
            memory.setObject(data as NSData, forKey: key as NSString, cost: data.count)
            try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            WidgetCenter.shared.reloadTimelines(ofKind: "com.example.Tsundoku.continue-reading")
            return data
        } catch {
            inFlight[key] = nil
            throw error
        }
    }

    func removeAll() {
        generation &+= 1
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
        memory.removeAllObjects()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func fileURL(for key: String) -> URL {
        let safeName = key.map { character in
            character.isLetter || character.isNumber || character == "-" ? character : "_"
        }
        return directory.appending(path: String(safeName) + ".img")
    }
}
