import XCTest
@testable import Tsundoku

final class DownloadManagerTests: XCTestCase {
    func testBackgroundTaskIdentityIncludesServer() {
        let firstServer = ServerID(UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
        let secondServer = ServerID(UUID(uuidString: "22222222-2222-2222-2222-222222222222")!)
        let descriptor = DownloadTaskDescriptor(serverID: firstServer, bookID: "42", page: 0)

        XCTAssertTrue(descriptor.belongs(to: BookKey(serverID: firstServer, remoteID: "42")))
        XCTAssertFalse(descriptor.belongs(to: BookKey(serverID: secondServer, remoteID: "42")))
        XCTAssertFalse(descriptor.belongs(to: BookKey(serverID: firstServer, remoteID: "43")))
    }

    func testChangedImagePackageIsReplaced() {
        XCTAssertFalse(DownloadPackagePolicy.requiresReplacement(
            existingRevision: "same",
            newRevision: "same",
            existingPageCount: 10,
            newPageCount: 10
        ))
        XCTAssertTrue(DownloadPackagePolicy.requiresReplacement(
            existingRevision: "old",
            newRevision: "new",
            existingPageCount: 10,
            newPageCount: 10
        ))
        XCTAssertTrue(DownloadPackagePolicy.requiresReplacement(
            existingRevision: "same",
            newRevision: "same",
            existingPageCount: 10,
            newPageCount: 11
        ))
    }

    func testDownloadThroughputUsesBoundedParallelTransfers() {
        XCTAssertEqual(DownloadThroughputPolicy.maximumConnectionsPerHost, 6)
        XCTAssertEqual(DownloadThroughputPolicy.completedPageCount(current: 41, pageCount: 133), 42)
        XCTAssertEqual(DownloadThroughputPolicy.completedPageCount(current: 133, pageCount: 133), 133)
        XCTAssertEqual(DownloadThroughputPolicy.packageSize(current: 1_024, addingFileBytes: 2_048), 3_072)
    }

    func testLiveActivityVisibilityTracksActiveDownloadStates() {
        XCTAssertTrue(DownloadLiveActivityPolicy.isVisible(for: .queued))
        XCTAssertTrue(DownloadLiveActivityPolicy.isVisible(for: .downloading))
        XCTAssertTrue(DownloadLiveActivityPolicy.isVisible(for: .paused))
        XCTAssertFalse(DownloadLiveActivityPolicy.isVisible(for: .complete))
        XCTAssertFalse(DownloadLiveActivityPolicy.isVisible(for: .failed))
    }

    func testLiveActivityProgressIsClamped() {
        XCTAssertEqual(DownloadLiveActivityAttributes.ContentState(
            completedUnitCount: 3,
            totalUnitCount: 12,
            status: "Downloading"
        ).progress, 0.25)
        XCTAssertEqual(DownloadLiveActivityAttributes.ContentState(
            completedUnitCount: 20,
            totalUnitCount: 12,
            status: "Downloading"
        ).progress, 1)
    }

    func testDownloadRecordOwnsMetadataNeededToOpenOffline() throws {
        let serverID = ServerID(UUID(uuidString: "33333333-3333-3333-3333-333333333333")!)
        let book = Book(
            key: BookKey(serverID: serverID, remoteID: "book-10"),
            seriesKey: SeriesKey(serverID: serverID, remoteID: "series"),
            title: "Volume 10",
            number: "10",
            numberSort: 10,
            sizeBytes: 1_024,
            fileHash: "revision",
            mediaType: "application/zip",
            pageCount: 120,
            readPage: nil,
            completed: false,
            readProgressModifiedAt: nil,
            lastModified: nil
        )

        let record = DownloadRecord(
            book: book,
            seriesTitle: "We Never Learn",
            seriesReadingDirection: "LEFT_TO_RIGHT",
            seriesTags: ["Comedy"]
        )

        XCTAssertEqual(record.book, book)
        XCTAssertEqual(record.seriesReadingDirection, "LEFT_TO_RIGHT")
        XCTAssertEqual(record.seriesTags, ["Comedy"])
    }
}
