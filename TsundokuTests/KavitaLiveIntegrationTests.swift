import Foundation
import UIKit
import XCTest
@testable import Tsundoku

final class KavitaLiveIntegrationTests: XCTestCase {
    func testLiveCatalogEPUBAndProgressRoundTrip() async throws {
        let environment = ProcessInfo.processInfo.environment
        let bundled = Self.bundledCredentials()
        let urlValue = Self.firstCredential(
            environment["KAVITA_LIVE_URL"],
            environment["TEST_RUNNER_KAVITA_LIVE_URL"],
            bundled.url
        )
        let authKey = Self.firstCredential(
            environment["KAVITA_LIVE_AUTH_KEY"],
            environment["TEST_RUNNER_KAVITA_LIVE_AUTH_KEY"],
            bundled.authKey
        )
        guard let urlValue,
              let authKey,
              !urlValue.isEmpty,
              !authKey.isEmpty,
              !urlValue.contains("$("),
              !authKey.contains("$("),
              let url = URL(string: urlValue),
              url.scheme != nil else {
            throw XCTSkip("Live Kavita credentials were not supplied.")
        }
        let profile = ServerProfile(
            id: ServerID(),
            name: "Live Kavita",
            baseURL: url,
            userID: "",
            username: "",
            isActive: true,
            kind: .kavita
        )
        let client = KavitaClient(
            profile: profile,
            authKey: authKey,
            deviceID: "tsundoku-live-validation",
            userAgent: "Tsundoku-iOS/LiveValidation"
        )

        let connection = try await client.validateConnection()
        XCTAssertGreaterThanOrEqual(connection.version, KavitaClient.minimumVersion)
        let libraries = try await client.libraries()
        XCTAssertFalse(libraries.isEmpty)
        XCTAssertTrue(libraries.contains { $0.contentType == .manga })
        XCTAssertTrue(libraries.contains { $0.contentType == .other })
        let testLibrary = libraries.first(where: { $0.name.localizedCaseInsensitiveContains("light novel") })
            ?? libraries.first
        let page = try await client.series(page: 0, pageSize: 10, libraryID: testLibrary?.id)
        let firstSeries = try XCTUnwrap(page.content.first)
        let hydratedSeries = try await client.series(id: firstSeries.key.remoteID)
        XCTAssertFalse(hydratedSeries.title.isEmpty)
        let booksPage = try await client.books(seriesID: firstSeries.key.remoteID)
        let book = try XCTUnwrap(booksPage.content.first)
        XCTAssertEqual(book.contentKind, .epub)
        let poster = try await client.posterData(seriesID: firstSeries.key.remoteID)
        let search = try await client.series(search: hydratedSeries.title)
        XCTAssertFalse(poster.isEmpty)
        XCTAssertFalse(search.content.isEmpty)
        let volumeSearch = try await client.series(search: "We Never Learn")
        if let volumeSeries = volumeSearch.content.first(where: {
            $0.title.caseInsensitiveCompare("We Never Learn") == .orderedSame
        }) {
            XCTAssertEqual(volumeSeries.libraryContentType, .manga)
            let volumeBooks = try await client.books(seriesID: volumeSeries.key.remoteID).content
            XCTAssertEqual(volumeBooks.first?.displayTitle, "Volume 1")
            XCTAssertEqual(volumeBooks.first?.number, "1")
            XCTAssertEqual(volumeBooks.last?.displayTitle, "Volume 21")
            XCTAssertFalse(volumeBooks.contains { $0.displayTitle.contains("100000") || $0.number.contains("100000") })
            let firstVolume = try XCTUnwrap(volumeBooks.first)
            XCTAssertEqual(firstVolume.trackerProgressUnit, .volume)
            let imagePages = try await client.pages(book: firstVolume)
            XCTAssertEqual(imagePages.first?.number, 1)
            let firstPageRequest = try await client.pageRequest(book: firstVolume, zeroBasedPage: 0)
            let firstPageData = try await client.data(for: firstPageRequest)
            XCTAssertNotNil(UIImage(data: firstPageData))
        } else {
            XCTFail("The live whole-volume naming fixture was unavailable.")
        }
        if let comicLibrary = libraries.first(where: { $0.name.localizedCaseInsensitiveContains("comics") }) {
            XCTAssertEqual(comicLibrary.contentType, .other)
            let comicSeries = try await client.series(page: 0, pageSize: 10, libraryID: comicLibrary.id).content
            var comicBook: Book?
            for candidate in comicSeries where comicBook == nil {
                comicBook = try await client.books(seriesID: candidate.key.remoteID).content
                    .first(where: { $0.contentKind == .images })
            }
            let firstComic = try XCTUnwrap(comicBook)
            let comicPageRequest = try await client.pageRequest(book: firstComic, zeroBasedPage: 0)
            let comicPageData = try await client.data(for: comicPageRequest)
            XCTAssertNotNil(UIImage(data: comicPageData))
        } else {
            XCTFail("The live comics fixture was unavailable.")
        }
        let standaloneSearch = try await client.series(search: "Angels' Blood")
        if let standaloneSeries = standaloneSearch.content.first(where: {
            $0.title.caseInsensitiveCompare("Angels' Blood") == .orderedSame
        }) {
            let standaloneBooks = try await client.books(seriesID: standaloneSeries.key.remoteID).content
            let standaloneBook = try XCTUnwrap(standaloneBooks.first)
            XCTAssertEqual(standaloneBook.displayTitle, "Angels' Blood")
            XCTAssertEqual(standaloneBook.trackerProgressUnit, .chapter)
            XCTAssertFalse(standaloneBook.displayTitle.contains("100000"))
            let hydratedBook = try await client.book(id: standaloneBook.key.remoteID)
            XCTAssertEqual(hydratedBook.displayTitle, "Angels' Blood")
            XCTAssertFalse(hydratedBook.displayTitle.contains("100000"))
        } else {
            XCTFail("The live standalone-book naming fixture was unavailable.")
        }
        _ = try await client.updatedSeries(pageSize: 5, libraryID: libraries.first?.id)
        let collections = try await client.collections()
        if let collection = collections.content.first {
            _ = try await client.collectionSeries(collectionID: collection.id)
        }
        let readingLists = try await client.readLists()
        if let readingList = readingLists.content.first {
            _ = try await client.readListBooks(readListID: readingList.id)
        }

        let info = try await client.epubInfo(book: book)
        let toc = try await client.epubTableOfContents(book: book)
        let fragment = try await client.epubPage(book: book, index: 0)
        XCTAssertGreaterThan(info.pages, 0)
        XCTAssertFalse(toc.isEmpty)
        XCTAssertFalse(fragment.isEmpty)
        let prepared = EPUBDocumentBuilder.prepare(
            fragment: fragment,
            preferences: EPUBReaderPreferences(),
            baseURL: url
        )
        XCTAssertFalse(prepared.html.localizedCaseInsensitiveContains("apikey="))
        if let resource = prepared.resources.values.first {
            let resourceURL = try XCTUnwrap(URL(string: resource))
            XCTAssertNotEqual(EPUBDocumentBuilder.resourceMIMEType(for: resourceURL), "application/octet-stream")
            let request = try await client.epubResourceRequest(book: book, reference: resource)
            XCTAssertNil(request.url?.queryItems?.first(where: { $0.name.caseInsensitiveCompare("apiKey") == .orderedSame }))
            let resourceData = try await client.data(for: request)
            XCTAssertFalse(resourceData.isEmpty)
        }

        let original = try await client.remoteProgress(for: book)
        func restore() async throws {
            if original.completed {
                try await client.markRead(book: book)
            } else if let position = original.position {
                try await client.markProgress(
                    book: book,
                    position: position,
                    completed: false,
                    locator: original.epubLocator
                )
            } else {
                try await client.markUnread(book: book)
            }
        }

        do {
            let forwardPosition = min(max(2, original.position ?? 2), max(2, book.pageCount - 1))
            let locator = "//body/main[1]/p[1]"
            try await client.markProgress(book: book, position: forwardPosition, completed: false, locator: locator)
            let forward = try await client.remoteProgress(for: book)
            XCTAssertEqual(forward.position, forwardPosition)
            XCTAssertEqual(forward.epubLocator, locator)

            try await client.markProgress(book: book, position: 1, completed: false, locator: "//body/main[1]")
            let backward = try await client.remoteProgress(for: book)
            XCTAssertNil(backward.position)

            try await client.markRead(book: book)
            let markedRead = try await client.remoteProgress(for: book)
            XCTAssertTrue(markedRead.completed)
            try await client.markUnread(book: book)
            let markedUnread = try await client.remoteProgress(for: book)
            XCTAssertFalse(markedUnread.completed)
            XCTAssertNil(markedUnread.position)
        } catch {
            try? await restore()
            throw error
        }
        try await restore()
        let restored = try await client.remoteProgress(for: book)
        XCTAssertEqual(restored.completed, original.completed)
        XCTAssertEqual(restored.position, original.position)
        XCTAssertEqual(restored.epubLocator, original.epubLocator)
    }

    /// Local release validation may place the ignored credential file directly
    /// in the built test bundle. It is never a project resource or archive input.
    private static func bundledCredentials() -> (url: String?, authKey: String?) {
        let bundles = [Bundle(for: Self.self), .main] + Bundle.allBundles + Bundle.allFrameworks
        let bundleCandidates = bundles.lazy.compactMap { bundle in
            bundle.url(forResource: "kavita_creds", withExtension: "txt")
                ?? bundle.bundleURL.appending(path: "kavita_creds.txt")
        }
        let hostedTestCandidate = Bundle.main.builtInPlugInsURL?
            .appending(path: "TsundokuTests.xctest", directoryHint: .isDirectory)
            .appending(path: "kavita_creds.txt")
        let file = (Array(bundleCandidates) + [hostedTestCandidate].compactMap { $0 })
            .first { FileManager.default.fileExists(atPath: $0.path) }
        guard let file,
              let contents = try? String(contentsOf: file, encoding: .utf8) else {
            return (nil, nil)
        }
        var url: String?
        var authKey: String?
        for line in contents.split(whereSeparator: \.isNewline) {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = line[..<separator]
                .filter { !$0.isWhitespace }
                .lowercased()
            let value = String(line[line.index(after: separator)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if key == "url" { url = value }
            if key == "authkey" { authKey = value }
        }
        return (url, authKey)
    }

    private static func firstCredential(_ candidates: String?...) -> String? {
        candidates.first { value in
            guard let value else { return false }
            return !value.isEmpty && !value.contains("$(")
        } ?? nil
    }
}

private extension URL {
    var queryItems: [URLQueryItem]? {
        URLComponents(url: self, resolvingAgainstBaseURL: false)?.queryItems
    }
}
