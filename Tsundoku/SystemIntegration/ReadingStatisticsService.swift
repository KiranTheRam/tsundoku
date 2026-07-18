import AppIntents
import CoreSpotlight
import Foundation
import SwiftData
import WidgetKit

struct ReadingStatisticsBucket: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let day: Date
    let deviceID: String
    var pages: Int
    var modifiedAt: Date
}

struct ReadingStatisticsSyncSnapshot: Codable, Equatable, Sendable {
    var version = 1
    let buckets: [ReadingStatisticsBucket]
    let modifiedAt: Date
}

enum ReadingStatisticsPolicy {
    static let recordPrefix = "readingStatistics.v1."

    static func bucketID(day: Date, deviceID: String) -> String {
        "\(recordPrefix)\(Int(day.timeIntervalSince1970)).\(deviceID)"
    }

    static func merge(
        _ lhs: [ReadingStatisticsBucket],
        _ rhs: [ReadingStatisticsBucket],
        retainingDays: Int = 32,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [ReadingStatisticsBucket] {
        let cutoff = calendar.date(byAdding: .day, value: -retainingDays, to: calendar.startOfDay(for: now))
            ?? .distantPast
        var selected: [String: ReadingStatisticsBucket] = [:]
        for bucket in lhs + rhs where bucket.day >= cutoff {
            guard let existing = selected[bucket.id] else {
                selected[bucket.id] = bucket
                continue
            }
            if bucket.pages > existing.pages ||
                (bucket.pages == existing.pages && bucket.modifiedAt > existing.modifiedAt) {
                selected[bucket.id] = bucket
            }
        }
        return selected.values.sorted {
            if $0.day != $1.day { return $0.day > $1.day }
            return $0.deviceID < $1.deviceID
        }
    }

    static func statistics(
        from buckets: [ReadingStatisticsBucket],
        now: Date = .now,
        calendar: Calendar = .current
    ) -> ReadingStatistics {
        let today = calendar.startOfDay(for: now)
        let week = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? today
        let pagesByDay = Dictionary(grouping: buckets, by: { calendar.startOfDay(for: $0.day) })
            .mapValues { values in values.reduce(0) { $0 + $1.pages } }
        let currentWeek = (0..<7).compactMap { offset -> DailyReadingStatistics? in
            guard let day = calendar.date(byAdding: .day, value: offset, to: week) else { return nil }
            let normalizedDay = calendar.startOfDay(for: day)
            return DailyReadingStatistics(date: normalizedDay, pages: pagesByDay[normalizedDay] ?? 0)
        }
        return ReadingStatistics(
            pagesToday: buckets.lazy.filter { $0.day >= today }.reduce(0) { $0 + $1.pages },
            pagesThisWeek: currentWeek.reduce(0) { $0 + $1.pages },
            currentWeek: currentWeek
        )
    }
}

extension AppState {
    func cacheSeriesForSystemIntegration(_ values: [Series]) {
        let context = modelContainer.mainContext
        for series in values {
            let id = series.id
            let descriptor = FetchDescriptor<CachedSeriesRecord>(predicate: #Predicate { $0.id == id })
            if let record = try? context.fetch(descriptor).first {
                record.payload = (try? JSONEncoder().encode(series)) ?? record.payload
                record.libraryID = series.libraryID
                record.title = series.title
                record.cachedAt = .now
            } else {
                context.insert(CachedSeriesRecord(series: series))
            }
        }
        try? context.save()
        refreshSystemIntegrationSnapshot(reindexSeries: true)
    }

    func recordReadingAdvance(
        book: Book,
        seriesTitle: String,
        from previousPosition: Int,
        to position: Int,
        at date: Date = .now,
        calendar: Calendar = .current
    ) {
        let pages = position - previousPosition
        guard pages > 0 else { return }
        let day = calendar.startOfDay(for: date)
        let deviceID = installationDeviceID
        let id = ReadingStatisticsPolicy.bucketID(day: day, deviceID: deviceID)
        let context = modelContainer.mainContext
        let descriptor = FetchDescriptor<PreferenceRecord>(predicate: #Predicate { $0.id == id })
        let existingRecord = try? context.fetch(descriptor).first
        var bucket = existingRecord.flatMap {
            try? JSONDecoder().decode(ReadingStatisticsBucket.self, from: $0.encodedPreferences)
        } ?? ReadingStatisticsBucket(
            id: id,
            day: day,
            deviceID: deviceID,
            pages: 0,
            modifiedAt: date
        )
        bucket.pages += pages
        bucket.modifiedAt = date
        let encoded = (try? JSONEncoder().encode(bucket)) ?? Data()
        if let existingRecord {
            existingRecord.encodedPreferences = encoded
            existingRecord.modifiedAt = date
        } else {
            let record = PreferenceRecord(id: id, encodedValue: encoded)
            record.modifiedAt = date
            context.insert(record)
        }
        try? context.save()

        readingStatisticsBuckets = ReadingStatisticsPolicy.merge(
            readingStatisticsBuckets,
            [bucket],
            now: date,
            calendar: calendar
        )
        scheduleReadingStatisticsMirror()
        refreshSystemIntegrationSnapshot()
    }

    func readingStatistics(
        now: Date = .now,
        calendar: Calendar = .current
    ) -> ReadingStatistics {
        ReadingStatisticsPolicy.statistics(
            from: readingStatisticsBuckets,
            now: now,
            calendar: calendar
        )
    }

    func refreshReadingStatisticsBuckets() {
        let records = (try? modelContainer.mainContext.fetch(FetchDescriptor<PreferenceRecord>())) ?? []
        let buckets = records
            .filter { $0.id.hasPrefix(ReadingStatisticsPolicy.recordPrefix) }
            .compactMap { try? JSONDecoder().decode(ReadingStatisticsBucket.self, from: $0.encodedPreferences) }
        readingStatisticsBuckets = ReadingStatisticsPolicy.merge([], buckets)
    }

    func reconcileReadingStatisticsMirror() async {
        refreshReadingStatisticsBuckets()
        do {
            let remote: ReadingStatisticsSyncSnapshot? = try await credentials.value(
                kind: .readingStatistics,
                account: "default"
            )
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode(ReadingStatisticsSyncSnapshot.self, from: $0) }
            let merged = ReadingStatisticsPolicy.merge(
                readingStatisticsBuckets,
                remote?.buckets ?? []
            )
            applyReadingStatisticsBuckets(merged)
            let snapshot = ReadingStatisticsSyncSnapshot(buckets: merged, modifiedAt: .now)
            if snapshot.buckets != remote?.buckets {
                try await saveReadingStatisticsSnapshot(snapshot)
            }
        } catch {
            // CloudKit-backed preference buckets remain the source of truth.
        }
        refreshSystemIntegrationSnapshot()
    }

    func refreshSystemIntegrationSnapshot(reindexSeries: Bool = false) {
        guard !Self.isRunningUnitTests else { return }
        let context = modelContainer.mainContext
        let records = (try? context.fetch(
            FetchDescriptor<CachedSeriesRecord>(sortBy: [SortDescriptor(\.title)])
        )) ?? []
        var seriesByID = Dictionary(uniqueKeysWithValues: records.map {
            let summary = SystemSeriesSummary(serverID: $0.serverID, seriesID: $0.remoteID, title: $0.title)
            return (summary.id, summary)
        })
        let recordsByRemoteID = Dictionary(grouping: records, by: \.remoteID)
        let normalizedActivities = recentBookActivities.map { activity in
            let directID = "\(activity.serverID):series:\(activity.seriesID)"
            let uniqueLocalServerID = recordsByRemoteID[activity.seriesID]
                .flatMap { $0.count == 1 ? $0.first?.serverID : nil }
            return HomeBookActivity(
                serverID: seriesByID[directID] == nil ? uniqueLocalServerID ?? activity.serverID : activity.serverID,
                seriesID: activity.seriesID,
                bookID: activity.bookID,
                seriesTitle: activity.seriesTitle,
                bookTitle: activity.bookTitle,
                page: activity.page,
                pageCount: activity.pageCount,
                readAt: activity.readAt
            )
        }
        let recentActivities = HomeSyncPolicy.mergeBookActivities([], normalizedActivities)
        for activity in recentActivities where seriesByID["\(activity.serverID):series:\(activity.seriesID)"] == nil {
            let summary = SystemSeriesSummary(
                serverID: activity.serverID,
                seriesID: activity.seriesID,
                title: activity.seriesTitle
            )
            seriesByID[summary.id] = summary
        }
        let recent = recentActivities
            .filter { $0.pageCount <= 0 || $0.page < $0.pageCount }
            .map {
                SystemResumeItem(
                    serverID: $0.serverID,
                    seriesID: $0.seriesID,
                    bookID: $0.bookID,
                    seriesTitle: $0.seriesTitle,
                    bookTitle: $0.bookTitle,
                    page: $0.page,
                    pageCount: $0.pageCount,
                    readAt: $0.readAt
                )
            }
        let snapshot = TsundokuSystemSnapshot(
            series: seriesByID.values.sorted {
                $0.title.localizedStandardCompare($1.title) == .orderedAscending
            },
            recentItems: Array(recent.prefix(8)),
            statistics: readingStatistics(),
            generatedAt: .now
        )
        TsundokuSharedStore.saveSnapshot(snapshot)
        TsundokuAppShortcuts.updateAppShortcutParameters()
        WidgetCenter.shared.reloadAllTimelines()

        if reindexSeries {
            let entities = snapshot.series.map(SeriesAppEntity.init)
            Task {
                try? await CSSearchableIndex.default().deleteAppEntities(ofType: SeriesAppEntity.self)
                try? await CSSearchableIndex.default().indexAppEntities(entities)
            }
        }
    }

    private func scheduleReadingStatisticsMirror() {
        guard !Self.isRunningUnitTests else { return }
        Task { await saveReadingStatisticsMirror() }
    }

    private func saveReadingStatisticsMirror() async {
        do {
            let remote: ReadingStatisticsSyncSnapshot? = try await credentials.value(
                kind: .readingStatistics,
                account: "default"
            )
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode(ReadingStatisticsSyncSnapshot.self, from: $0) }
            let merged = ReadingStatisticsPolicy.merge(
                remote?.buckets ?? [],
                readingStatisticsBuckets
            )
            let snapshot = ReadingStatisticsSyncSnapshot(buckets: merged, modifiedAt: .now)
            if snapshot.buckets != remote?.buckets {
                try await saveReadingStatisticsSnapshot(snapshot)
            }
        } catch {
            // Best effort; foreground reconciliation retries it.
        }
    }

    private func saveReadingStatisticsSnapshot(_ snapshot: ReadingStatisticsSyncSnapshot) async throws {
        let data = try JSONEncoder().encode(snapshot)
        guard let value = String(data: data, encoding: .utf8) else { return }
        try await credentials.save(value, kind: .readingStatistics, account: "default")
    }

    private func applyReadingStatisticsBuckets(_ buckets: [ReadingStatisticsBucket]) {
        let context = modelContainer.mainContext
        let records = (try? context.fetch(FetchDescriptor<PreferenceRecord>())) ?? []
        var recordsByID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        for bucket in buckets {
            let encoded = (try? JSONEncoder().encode(bucket)) ?? Data()
            if let record = recordsByID[bucket.id] {
                let local = try? JSONDecoder().decode(ReadingStatisticsBucket.self, from: record.encodedPreferences)
                if (local?.pages ?? -1) < bucket.pages {
                    record.encodedPreferences = encoded
                    record.modifiedAt = bucket.modifiedAt
                }
            } else {
                let record = PreferenceRecord(id: bucket.id, encodedValue: encoded)
                record.modifiedAt = bucket.modifiedAt
                context.insert(record)
                recordsByID[bucket.id] = record
            }
        }
        try? context.save()
        readingStatisticsBuckets = buckets
    }
}
