import XCTest
@testable import Tsundoku

final class ProgressMergeTests: XCTestCase {
    private let book = BookKey(serverID: ServerID(UUID(uuidString: "11111111-1111-1111-1111-111111111111")!), remoteID: "book")

    func testOneBasedConversionAndCompletion() {
        let first = ReadingCheckpoint(book: book, zeroBasedPage: 0, pageCount: 10)
        XCTAssertEqual(first.page, 1)
        XCTAssertFalse(first.completed)
        let last = ReadingCheckpoint(book: book, zeroBasedPage: 9, pageCount: 10)
        XCTAssertEqual(last.page, 10)
        XCTAssertTrue(last.completed)
    }

    func testNewestCheckpointWinsEvenWhenItMovesBackward() {
        let policy = ProgressMergePolicy()
        let observedAt = Date(timeIntervalSince1970: 2_000)
        let local = ReadingCheckpoint(book: book, zeroBasedPage: 3, pageCount: 10, observedAt: observedAt)
        XCTAssertEqual(
            policy.resolve(local: local, remotePage: 9, remoteCompleted: false, remoteObservedAt: observedAt.addingTimeInterval(-10)),
            .pushRegression
        )
        XCTAssertEqual(
            policy.resolve(local: local, remotePage: 2, remoteCompleted: false, remoteObservedAt: observedAt.addingTimeInterval(-10)),
            .pushLocal
        )
        XCTAssertEqual(
            policy.resolve(local: local, remotePage: 8, remoteCompleted: false, remoteObservedAt: observedAt.addingTimeInterval(10)),
            .keepRemote
        )
    }

    func testIntentionalRegressionOverridesFurthestWins() {
        let local = ReadingCheckpoint(book: book, zeroBasedPage: 0, pageCount: 10, intentionalRegression: true)
        XCTAssertEqual(
            ProgressMergePolicy().resolve(local: local, remotePage: 9, remoteCompleted: true, remoteObservedAt: .distantFuture),
            .pushRegression
        )
    }
}
