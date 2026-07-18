import Foundation
import Testing
@testable import Tsundoku

@Suite("System integration")
struct SystemIntegrationTests {
    @Test("Widget resume URLs round-trip into navigation requests")
    func resumeURLRoundTrip() throws {
        let item = SystemResumeItem(
            serverID: "server",
            seriesID: "series",
            bookID: "book",
            seriesTitle: "Series",
            bookTitle: "Volume 1",
            page: 37,
            pageCount: 100,
            readAt: .now
        )
        let request = try #require(SystemNavigationRequest(url: item.resumeURL))
        #expect(request.kind == .series)
        #expect(request.serverID == "server")
        #expect(request.seriesID == "series")
        #expect(request.bookID == "book")
        #expect(item.progress == 0.37)
    }

    @Test("Statistics merge independent devices without double counting stale buckets")
    func statisticsMerge() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        calendar.firstWeekday = 2
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 7, day: 17, hour: 12)))
        let today = calendar.startOfDay(for: now)
        let earlier = try #require(calendar.date(byAdding: .day, value: -2, to: today))
        let firstID = ReadingStatisticsPolicy.bucketID(day: today, deviceID: "phone")
        let stale = ReadingStatisticsBucket(id: firstID, day: today, deviceID: "phone", pages: 2, modifiedAt: .distantPast)
        let current = ReadingStatisticsBucket(id: firstID, day: today, deviceID: "phone", pages: 5, modifiedAt: now)
        let tablet = ReadingStatisticsBucket(
            id: ReadingStatisticsPolicy.bucketID(day: today, deviceID: "tablet"),
            day: today,
            deviceID: "tablet",
            pages: 3,
            modifiedAt: now
        )
        let priorDay = ReadingStatisticsBucket(
            id: ReadingStatisticsPolicy.bucketID(day: earlier, deviceID: "phone"),
            day: earlier,
            deviceID: "phone",
            pages: 4,
            modifiedAt: earlier
        )

        let merged = ReadingStatisticsPolicy.merge(
            [stale, priorDay],
            [current, tablet],
            now: now,
            calendar: calendar
        )
        let statistics = ReadingStatisticsPolicy.statistics(from: merged, now: now, calendar: calendar)
        #expect(merged.first(where: { $0.id == firstID })?.pages == 5)
        #expect(statistics.pagesToday == 8)
        #expect(statistics.pagesThisWeek == 12)
        #expect(statistics.currentWeek.count == 7)
        #expect(statistics.currentWeek.reduce(0) { $0 + $1.pages } == 12)
        #expect(statistics.currentWeek.first(where: { calendar.isDate($0.date, inSameDayAs: earlier) })?.pages == 4)
    }

    @Test("Older widget snapshots decode without daily statistics")
    func legacyStatisticsDecode() throws {
        let data = try #require(#"{"pagesToday":3,"pagesThisWeek":9}"#.data(using: .utf8))
        let statistics = try JSONDecoder().decode(ReadingStatistics.self, from: data)
        #expect(statistics.pagesToday == 3)
        #expect(statistics.pagesThisWeek == 9)
        #expect(statistics.currentWeek.isEmpty)
    }

    @MainActor
    @Test("Only forward settled positions add reading statistics")
    func forwardReadingOnly() throws {
        let suiteName = "SystemIntegrationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = AppState(modelContainer: try AppModelContainer.make(inMemory: true), defaults: defaults)
        let serverID = ServerID()
        let book = Book(
            key: BookKey(serverID: serverID, remoteID: "book"),
            seriesKey: SeriesKey(serverID: serverID, remoteID: "series"),
            title: "Volume 1",
            number: "1",
            numberSort: 1,
            sizeBytes: 0,
            fileHash: "hash",
            mediaType: "application/zip",
            pageCount: 100,
            readPage: nil,
            completed: false,
            readProgressModifiedAt: nil,
            lastModified: nil
        )

        state.recordReadingAdvance(book: book, seriesTitle: "Series", from: 10, to: 13)
        state.recordReadingAdvance(book: book, seriesTitle: "Series", from: 13, to: 8)
        #expect(state.readingStatistics().pagesToday == 3)
        #expect(state.readingStatistics().pagesThisWeek == 3)
    }

    @Test("Recent books merge by book and retain the newest checkpoint")
    func recentBookMerge() {
        let older = HomeBookActivity(
            serverID: "server",
            seriesID: "series",
            bookID: "book",
            seriesTitle: "Series",
            bookTitle: "Volume 1",
            page: 4,
            pageCount: 100,
            readAt: .distantPast
        )
        let newer = HomeBookActivity(
            serverID: "server",
            seriesID: "series",
            bookID: "book",
            seriesTitle: "Series",
            bookTitle: "Volume 1",
            page: 37,
            pageCount: 100,
            readAt: .now
        )
        let merged = HomeSyncPolicy.mergeBookActivities([older], [newer])
        #expect(merged.count == 1)
        #expect(merged.first?.page == 37)
    }

    @Test("Series suggestions tolerate several recent volumes from one series")
    func duplicateRecentSeriesSuggestions() {
        let ranks = SeriesAppEntityQuery.suggestionRanks(for: [
            "server:series:we-never-learn",
            "server:series:akira",
            "server:series:we-never-learn"
        ])
        #expect(ranks.count == 2)
        #expect(ranks["server:series:we-never-learn"] == 0)
        #expect(ranks["server:series:akira"] == 1)
    }
}
