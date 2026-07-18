import Foundation
import XCTest
@testable import Tsundoku

final class ProviderMigrationTests: XCTestCase {
    func testLegacyProfileDefaultsToKomgaWithoutChangingID() throws {
        let id = ServerID(UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
        let profile = ServerProfile(
            id: id,
            name: "Legacy",
            baseURL: URL(string: "https://example.com")!,
            userID: "user",
            username: "reader",
            isActive: true,
            kind: .kavita
        )
        let legacy = try removing(keys: ["kind"], from: JSONEncoder().encode(profile))
        let decoded = try JSONDecoder().decode(ServerProfile.self, from: legacy)
        XCTAssertEqual(decoded.id, id)
        XCTAssertEqual(decoded.kind, .komga)
    }

    func testLegacyBookGetsImageContentAndRemoteContext() throws {
        let serverID = ServerID(UUID(uuidString: "22222222-2222-2222-2222-222222222222")!)
        let book = Book(
            key: BookKey(serverID: serverID, remoteID: "book"),
            seriesKey: SeriesKey(serverID: serverID, remoteID: "series"),
            title: "Book",
            number: "1",
            numberSort: 1,
            sizeBytes: 100,
            fileHash: "revision",
            mediaType: "application/zip",
            pageCount: 10,
            readPage: 3,
            completed: false,
            readProgressModifiedAt: nil,
            lastModified: nil,
            contentKind: .epub
        )
        let legacy = try removing(
            keys: ["contentKind", "remoteContext", "contentRevision"],
            from: JSONEncoder().encode(book)
        )
        let decoded = try JSONDecoder().decode(Book.self, from: legacy)
        XCTAssertEqual(decoded.contentKind, .images)
        XCTAssertEqual(decoded.remoteContext.seriesID, "series")
        XCTAssertEqual(decoded.remoteContext.chapterID, "book")
        XCTAssertEqual(decoded.contentRevision, "revision")
    }

    func testLegacyCheckpointDecodesWithoutEPUBFields() throws {
        let checkpoint = ReadingCheckpoint(
            book: BookKey(serverID: ServerID(), remoteID: "book"),
            zeroBasedPage: 4,
            pageCount: 20
        )
        let legacy = try removing(keys: ["remoteContext", "epubLocator"], from: JSONEncoder().encode(checkpoint))
        let decoded = try JSONDecoder().decode(ReadingCheckpoint.self, from: legacy)
        XCTAssertEqual(decoded.page, 5)
        XCTAssertNil(decoded.remoteContext)
        XCTAssertNil(decoded.epubLocator)
    }

    private func removing(keys: [String], from data: Data) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        keys.forEach { object.removeValue(forKey: $0) }
        return try JSONSerialization.data(withJSONObject: object)
    }
}
