import XCTest
@testable import Tsundoku

final class DTOTests: XCTestCase {
    func testKomgaServerMessagesRedactAPIKeys() {
        XCTAssertEqual(
            KomgaClient.redact("Rejected secret-key", secret: "secret-key"),
            "Rejected [REDACTED]"
        )
    }

    func testBookDTOProgressDecoding() throws {
        let data = Data(#"{"id":"b1","seriesId":"s1","seriesTitle":"Series","name":"Book","fileHash":"hash","sizeBytes":123,"metadata":{"title":"Volume 1","number":"1","numberSort":1},"media":{"mediaType":"application/zip","pagesCount":12,"status":"READY"},"readProgress":{"page":4,"completed":false,"lastModified":"2026-01-01T12:00:00Z"},"lastModified":"2026-01-01T12:00:00Z"}"#.utf8)
        let dto = try JSONDecoder.komga.decode(KomgaBookDTO.self, from: data)
        let book = dto.domain(serverID: ServerID())
        XCTAssertEqual(book.pageCount, 12)
        XCTAssertEqual(book.readPage, 4)
        XCTAssertNotNil(book.readProgressModifiedAt)
        XCTAssertFalse(book.completed)
    }
}
