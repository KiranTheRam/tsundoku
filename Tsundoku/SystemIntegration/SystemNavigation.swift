import Foundation
import SwiftData

struct SeriesLaunchRequest: Hashable {
    let id = UUID()
    let series: Series
    let preferredBookID: String?
    let resumesReading: Bool
}

extension AppState {
    func resolveSeriesLaunch(_ request: SystemNavigationRequest) async throws -> SeriesLaunchRequest {
        guard request.kind == .series,
              let serverValue = request.serverID,
              let requestedServerID = ServerID(string: serverValue),
              let seriesID = request.seriesID else {
            throw ServerClientError.unsupported("Tsundoku couldn't identify that series.")
        }
        let matchingCachedSeries = try? modelContainer.mainContext.fetch(
            FetchDescriptor<CachedSeriesRecord>(predicate: #Predicate { $0.remoteID == seriesID })
        )
        let configuredServerIDs = Set(profiles.map(\.id))
        let localCachedSeries = matchingCachedSeries?.first { record in
            guard let serverID = ServerID(string: record.serverID) else { return false }
            return configuredServerIDs.contains(serverID)
        }
        let serverID = profiles.contains(where: { $0.id == requestedServerID })
            ? requestedServerID
            : localCachedSeries.flatMap { ServerID(string: $0.serverID) }

        guard let serverID else {
            throw ServerClientError.unsupported("The server for this series is not configured on this device yet.")
        }
        if activeProfile?.id != serverID {
            guard let profile = profiles.first(where: { $0.id == serverID }) else {
                throw ServerClientError.unsupported("The server for this series is not configured on this device yet.")
            }
            await activate(profile)
        }
        guard let client = activeClient, client.profile.id == serverID else {
            throw ServerClientError.unsupported("Tsundoku couldn't connect to the server for this series.")
        }
        let cachedID = SeriesKey(serverID: serverID, remoteID: seriesID).id
        let descriptor = FetchDescriptor<CachedSeriesRecord>(predicate: #Predicate { $0.id == cachedID })
        let cached = (try? modelContainer.mainContext.fetch(descriptor).first)
            .flatMap { try? JSONDecoder().decode(Series.self, from: $0.payload) }
        let series: Series
        if let cached {
            series = cached
        } else {
            series = try await client.series(id: seriesID)
            cacheSeriesForSystemIntegration([series])
        }
        let mirroredBook = recentBookActivities.first {
            $0.seriesID == seriesID &&
                ($0.pageCount <= 0 || $0.page < $0.pageCount)
        }?.bookID
        return SeriesLaunchRequest(
            series: series,
            preferredBookID: request.bookID ?? mirroredBook,
            resumesReading: true
        )
    }
}
