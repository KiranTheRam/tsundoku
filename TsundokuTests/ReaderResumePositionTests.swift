import Foundation
import Testing
@testable import Tsundoku

struct ReaderResumePositionTests {
    @Test
    func liveKomgaProgressBeatsCloudHistoryRegardlessOfPageNumber() {
        #expect(ReaderResumePosition.zeroBasedPage(
            remoteOneBasedPage: 4,
            remoteModifiedAt: Date(timeIntervalSince1970: 2_000),
            pendingOneBasedPage: nil,
            pendingObservedAt: nil,
            historyOneBasedPage: 294,
            pageCount: 353
        ) == 3)
    }

    @Test
    func newerPendingCheckpointWinsUntilKomgaAcknowledgesIt() {
        #expect(ReaderResumePosition.zeroBasedPage(
            remoteOneBasedPage: 294,
            remoteModifiedAt: Date(timeIntervalSince1970: 1_000),
            pendingOneBasedPage: 4,
            pendingObservedAt: Date(timeIntervalSince1970: 2_000),
            historyOneBasedPage: 294,
            pageCount: 353
        ) == 3)
        #expect(ReaderResumePosition.zeroBasedPage(
            remoteOneBasedPage: 12,
            remoteModifiedAt: Date(timeIntervalSince1970: 3_000),
            pendingOneBasedPage: 4,
            pendingObservedAt: Date(timeIntervalSince1970: 2_000),
            historyOneBasedPage: 294,
            pageCount: 100
        ) == 11)
    }

    @Test
    func resumePositionUsesHistoryOnlyWithoutKomgaOrPendingProgressAndClamps() {
        #expect(ReaderResumePosition.zeroBasedPage(
            remoteOneBasedPage: nil,
            remoteModifiedAt: nil,
            pendingOneBasedPage: nil,
            pendingObservedAt: nil,
            historyOneBasedPage: 500,
            pageCount: 100
        ) == 99)
        #expect(ReaderResumePosition.zeroBasedPage(
            remoteOneBasedPage: nil,
            remoteModifiedAt: nil,
            pendingOneBasedPage: nil,
            pendingObservedAt: nil,
            historyOneBasedPage: nil,
            pageCount: 0
        ) == 0)
    }
}
