import Foundation
import SwiftData
import Testing
@testable import Tsundoku

struct PinnedSeriesTests {
    @MainActor
    @Test func pinsPersistInOrderAndCanBeRemoved() throws {
        let suiteName = "PinnedSeriesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let container = try AppModelContainer.make(inMemory: true)
        let state = AppState(modelContainer: container, defaults: defaults)
        let serverID = ServerID()
        let first = series(id: "1", title: "First", serverID: serverID)
        let second = series(id: "2", title: "Second", serverID: serverID)

        state.setPinned(true, series: first)
        state.setPinned(true, series: second)
        state.setPinned(true, series: first)
        #expect(state.pinnedSeriesKeys == [first.key, second.key])

        let relaunched = AppState(modelContainer: container, defaults: defaults)
        #expect(relaunched.pinnedSeriesKeys == [first.key, second.key])
        #expect(relaunched.isPinned(first))

        relaunched.setPinned(false, series: first)
        #expect(relaunched.pinnedSeriesKeys == [second.key])
        #expect(!relaunched.isPinned(first))
    }

    @MainActor
    @Test func continueReadingActivityPersistsAndMergesByNewestSeriesVisit() throws {
        let suiteName = "HomeActivityTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let container = try AppModelContainer.make(inMemory: true)
        let state = AppState(modelContainer: container, defaults: defaults)
        let serverID = ServerID()
        let series = series(id: "series", title: "Series", serverID: serverID)
        let book = Book(
            key: BookKey(serverID: serverID, remoteID: "book"),
            seriesKey: series.key,
            title: "Volume 1",
            number: "1",
            numberSort: 1,
            sizeBytes: 0,
            fileHash: "hash",
            mediaType: "application/zip",
            pageCount: 10,
            readPage: nil,
            completed: false,
            readProgressModifiedAt: nil,
            lastModified: nil
        )

        state.recordHistory(book: book, seriesTitle: series.title, page: 3)
        #expect(state.continueReadingActivities.map(\.seriesID) == ["series"])
        #expect(state.recentBookActivities.first?.bookID == "book")
        #expect(state.recentBookActivities.first?.page == 3)

        let relaunched = AppState(modelContainer: container, defaults: defaults)
        #expect(relaunched.continueReadingActivities.map(\.seriesID) == ["series"])
        #expect(relaunched.recentBookActivities.first?.page == 3)

        let older = HomeSeriesActivity(
            serverID: serverID.description,
            seriesID: "series",
            seriesTitle: "Old title",
            readAt: .distantPast
        )
        let merged = HomeSyncPolicy.mergeActivities(relaunched.continueReadingActivities, [older])
        #expect(merged.first?.seriesTitle == "Series")
    }

    @MainActor
    @Test func markUnreadRemovesExactResumeActivity() throws {
        let suiteName = "ClearReadingProgressTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let container = try AppModelContainer.make(inMemory: true)
        let state = AppState(modelContainer: container, defaults: defaults)
        let serverID = ServerID()
        let series = series(id: "series", title: "Series", serverID: serverID)
        let first = book(id: "volume-9", series: series, serverID: serverID)
        let reset = book(id: "volume-10", series: series, serverID: serverID)

        state.recordHistory(book: first, seriesTitle: series.title, page: 8)
        state.recordHistory(book: reset, seriesTitle: series.title, page: 1)
        state.clearReadingProgress(for: reset)

        #expect(state.recentBookActivities.map(\.bookID) == ["volume-9"])
        #expect(state.continueReadingActivities.map(\.seriesID) == ["series"])
        let history = try container.mainContext.fetch(FetchDescriptor<HistoryRecord>())
        #expect(history.map(\.bookID) == ["volume-9"])

        state.clearReadingProgress(for: first)
        #expect(state.recentBookActivities.isEmpty)
        #expect(state.continueReadingActivities.isEmpty)
    }

    @MainActor
    @Test func legacyPageOneResumeIsRemovedWhenServerReportsNoProgress() throws {
        let suiteName = "LegacyUnreadProgressTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let container = try AppModelContainer.make(inMemory: true)
        let state = AppState(modelContainer: container, defaults: defaults)
        let serverID = ServerID()
        let series = series(id: "series", title: "Series", serverID: serverID)
        let book = book(id: "volume-10", series: series, serverID: serverID)

        state.recordHistory(book: book, seriesTitle: series.title, page: 1)
        state.reconcileFinishedResumeActivities(with: [series])

        #expect(state.recentBookActivities.isEmpty)
        #expect(state.continueReadingActivities.isEmpty)
        #expect(try container.mainContext.fetch(FetchDescriptor<HistoryRecord>()).isEmpty)
    }

    @MainActor
    @Test func legacyPartialResumeIsRemovedWhenServerReportsBookCompleted() throws {
        let suiteName = "LegacyReadProgressTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let container = try AppModelContainer.make(inMemory: true)
        let state = AppState(modelContainer: container, defaults: defaults)
        let serverID = ServerID()
        let series = series(id: "series", title: "Series", serverID: serverID)
        let book = book(id: "volume-1", series: series, serverID: serverID)

        state.recordHistory(book: book, seriesTitle: series.title, page: 75)
        state.reconcileFinishedResumeActivities(with: [series])

        #expect(state.recentBookActivities.isEmpty)
        #expect(state.continueReadingActivities.isEmpty)
        #expect(try container.mainContext.fetch(FetchDescriptor<HistoryRecord>()).isEmpty)
    }

    private func series(id: String, title: String, serverID: ServerID) -> Series {
        Series(
            key: SeriesKey(serverID: serverID, remoteID: id),
            libraryID: "library",
            title: title,
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
    }

    private func book(id: String, series: Series, serverID: ServerID) -> Book {
        Book(
            key: BookKey(serverID: serverID, remoteID: id),
            seriesKey: series.key,
            title: id,
            number: "",
            numberSort: 0,
            sizeBytes: 0,
            fileHash: "hash",
            mediaType: "application/zip",
            pageCount: 10,
            readPage: nil,
            completed: false,
            readProgressModifiedAt: nil,
            lastModified: nil
        )
    }
}
