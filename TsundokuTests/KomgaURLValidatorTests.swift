import XCTest
@testable import Tsundoku

final class KomgaURLValidatorTests: XCTestCase {
    func testAllowsSecureAndLocalURLs() throws {
        XCTAssertEqual(try KomgaURLValidator.validate("https://komga.example.com/").absoluteString, "https://komga.example.com")
        XCTAssertNoThrow(try KomgaURLValidator.validate("http://192.168.1.20:25600"))
        XCTAssertNoThrow(try KomgaURLValidator.validate("http://komga.local"))
        XCTAssertNoThrow(try KomgaURLValidator.validate("http://komga"))
    }

    func testRejectsUnsafeURLs() {
        XCTAssertThrowsError(try KomgaURLValidator.validate("http://example.com"))
        XCTAssertThrowsError(try KomgaURLValidator.validate("ftp://192.168.1.20"))
        XCTAssertThrowsError(try KomgaURLValidator.validate("https://user:pass@example.com"))
    }

    func testPrivateRanges() {
        XCTAssertTrue(KomgaURLValidator.isLocalHost("10.0.0.1"))
        XCTAssertTrue(KomgaURLValidator.isLocalHost("172.31.255.1"))
        XCTAssertFalse(KomgaURLValidator.isLocalHost("172.32.0.1"))
        XCTAssertFalse(KomgaURLValidator.isLocalHost("8.8.8.8"))
    }
}
