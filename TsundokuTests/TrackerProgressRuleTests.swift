import XCTest
@testable import Tsundoku

final class TrackerProgressRuleTests: XCTestCase {
    let books = [
        TrackerBookProgress(bookID: "a", numberSort: 1, completed: true),
        TrackerBookProgress(bookID: "b", numberSort: 2.5, completed: true),
        TrackerBookProgress(bookID: "c", numberSort: 3, completed: false)
    ]

    func testRuleFormulas() {
        XCTAssertEqual(TrackerProgressRule.bookNumber(offset: 1).progress(completedBooks: books), 3)
        XCTAssertEqual(TrackerProgressRule.completedBookCount(offset: -1).progress(completedBooks: books), 1)
        XCTAssertEqual(TrackerProgressRule.manualPerBook(["a": 7, "b": 14]).progress(completedBooks: books), 14)
    }

    func testVolumeArchivesProduceTrackerVolumeProgress() {
        let volumes = [
            TrackerBookProgress(bookID: "v1", numberSort: 1, completed: true, trackerProgressUnit: .volume),
            TrackerBookProgress(bookID: "v2", numberSort: 2, completed: true, trackerProgressUnit: .volume),
            TrackerBookProgress(bookID: "v3", numberSort: 3, completed: false, trackerProgressUnit: .volume)
        ]
        let update = TrackerProgressCalculator.update(rule: .bookNumber(offset: 0), books: volumes)

        XCTAssertEqual(update.chapterProgress, 2)
        XCTAssertEqual(update.volumeProgress, 2)
        XCTAssertFalse(update.completed)
    }

    func testAutomaticMatchAcceptsExactAndAlternateTitles() {
        let candidates = [
            TrackerMedia(id: 1, title: "Bokutachi wa Benkyou ga Dekinai", alternateTitle: "We Never Learn", total: 187),
            TrackerMedia(id: 2, title: "We Never Learn: Bokuben", alternateTitle: nil, total: 10)
        ]

        XCTAssertEqual(
            TrackerMatchPolicy.confidentMatch(for: "We Never Learn!", in: candidates)?.id,
            1
        )
    }

    func testAutomaticMatchRejectsAmbiguousResults() {
        let candidates = [
            TrackerMedia(id: 1, title: "Blue Lock", alternateTitle: nil, total: 300),
            TrackerMedia(id: 2, title: "Blue Period", alternateTitle: nil, total: 70)
        ]

        XCTAssertNil(TrackerMatchPolicy.confidentMatch(for: "Blue", in: candidates))
    }

    func testAutomaticMatchRejectsDuplicateExactTitles() {
        let candidates = [
            TrackerMedia(id: 1, title: "Orange", alternateTitle: nil, total: 22),
            TrackerMedia(id: 2, title: "Orange", alternateTitle: nil, total: 6)
        ]

        XCTAssertNil(TrackerMatchPolicy.confidentMatch(for: "Orange", in: candidates))
    }

    func testPromptDecisionsMergeAndRespectResetTombstone() {
        let old = TrackerPromptDecision(seriesID: "server:one", handledAt: Date(timeIntervalSince1970: 10))
        let recent = TrackerPromptDecision(seriesID: "server:two", handledAt: Date(timeIntervalSince1970: 30))
        let merged = TrackerPromptSyncPolicy.merge(
            TrackerPromptState(decisions: [old], resetAt: nil),
            TrackerPromptState(decisions: [recent], resetAt: Date(timeIntervalSince1970: 20))
        )

        XCTAssertEqual(merged.decisions, [recent])
        XCTAssertEqual(merged.resetAt, Date(timeIntervalSince1970: 20))
    }
}
