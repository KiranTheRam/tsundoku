import Foundation
import WebKit
import XCTest
@testable import Tsundoku

final class EPUBTests: XCTestCase {
    func testHTMLWrappingRemovesScriptsCredentialsAndRewritesResources() throws {
        let fragment = """
        <script>alert('bad')</script>
        <p onclick="bad()">Hello</p>
        <img src="https://kavita.example.com/api/Book/5/book-resources?apiKey=secret&file=Images%2Fcover.jpg">
        """
        let prepared = EPUBDocumentBuilder.prepare(
            fragment: fragment,
            preferences: EPUBReaderPreferences(),
            baseURL: URL(string: "https://kavita.example.com")!
        )
        XCTAssertFalse(prepared.html.localizedCaseInsensitiveContains("<script"))
        XCTAssertFalse(prepared.html.contains("onclick"))
        XCTAssertFalse(prepared.html.contains("secret"))
        XCTAssertTrue(prepared.html.contains("tsundoku-resource://remote/"))
        XCTAssertTrue(prepared.html.contains("Content-Security-Policy"))
        let remote = try XCTUnwrap(prepared.resources.values.first)
        XCTAssertFalse(remote.localizedCaseInsensitiveContains("apikey"))
        let components = try XCTUnwrap(URLComponents(string: remote))
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "file" })?.value, "Images/cover.jpg")
    }

    func testPagedLayoutOwnsViewportGeometryDespitePublisherCSS() throws {
        let fragment = """
        <style>body{width:61px;padding:33px}.book-content{width:72px;padding:19px}</style>
        <p>Reader content</p>
        """
        let prepared = EPUBDocumentBuilder.prepare(
            fragment: fragment,
            preferences: EPUBReaderPreferences(horizontalMargin: 24),
            baseURL: URL(string: "https://kavita.example.com")!
        )
        XCTAssertTrue(prepared.html.contains("width:100vw!important"))
        XCTAssertTrue(prepared.html.contains("padding:0 24.0px!important"))
        XCTAssertTrue(prepared.html.contains("column-width:calc(100vw - 48.0px)!important"))
        XCTAssertTrue(prepared.html.contains("column-gap:48.0px!important"))
    }

    @MainActor
    func testPagedColumnsUseWholeViewportOffsets() async throws {
        let paragraphs = (0..<180)
            .map { "<p>Paragraph \($0) contains enough words to exercise EPUB pagination consistently.</p>" }
            .joined()
        let prepared = EPUBDocumentBuilder.prepare(
            fragment: paragraphs,
            preferences: EPUBReaderPreferences(horizontalMargin: 24),
            baseURL: URL(string: "https://kavita.example.com")!
        )
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        let loaded = expectation(description: "EPUB HTML loaded")
        let delegate = EPUBTestNavigationDelegate { loaded.fulfill() }
        webView.navigationDelegate = delegate
        webView.loadHTMLString(prepared.html, baseURL: URL(string: "about:blank"))
        await fulfillment(of: [loaded], timeout: 3)

        let result = try await webView.evaluateJavaScript(
            """
            (() => {
              const viewport = document.documentElement.clientWidth;
              const positions = Array.from(document.querySelectorAll('p'))
                .map(node => node.getBoundingClientRect().left)
                .sort((a, b) => a - b)
                .filter((value, index, values) => index === 0 || Math.abs(value - values[index - 1]) > 1);
              return [viewport, document.documentElement.scrollWidth, positions[0], positions[1]];
            })()
            """
        )
        let metrics = try XCTUnwrap(result as? [NSNumber])
        let viewportWidth = metrics[0].doubleValue
        let scrollWidth = metrics[1].doubleValue
        XCTAssertGreaterThan(scrollWidth, viewportWidth)
        XCTAssertEqual(metrics[2].doubleValue, 24, accuracy: 1)
        XCTAssertEqual(metrics[3].doubleValue - metrics[2].doubleValue, viewportWidth, accuracy: 1)
        XCTAssertGreaterThan(Int(ceil(scrollWidth / viewportWidth)), 1)

        let secondPage = try await webView.evaluateJavaScript(
            """
            (() => {
              const root = document.scrollingElement;
              root.scrollTo({left:root.clientWidth,behavior:'auto'});
              return Math.round(root.scrollLeft / root.clientWidth) + 1;
            })()
            """
        )
        XCTAssertEqual((secondPage as? NSNumber)?.intValue, 2)
    }

    func testEPUBReaderModeUsesUserFacingLayoutNames() {
        XCTAssertEqual(EPUBReaderMode.paged.title, "Paged")
        XCTAssertEqual(EPUBReaderMode.scrolling.title, "Vertical scroll")
    }

    func testSectionSelectionChecksOnlyOneEntryWhenSpinesAreShared() throws {
        let first = EPUBTableOfContentsItem(title: "Chapter One", part: "//body/h1[1]", page: 0)
        let second = EPUBTableOfContentsItem(title: "Chapter Two", part: "//body/h1[2]", page: 0)
        let selected = EPUBSectionSelection.selectedID(
            in: [first, second],
            currentSpine: 0,
            currentLocator: nil
        )

        XCTAssertEqual(selected, first.id)
        XCTAssertNotEqual(selected, second.id)
    }

    func testSectionSelectionPrefersExactLocatorIncludingNestedEntries() throws {
        let child = EPUBTableOfContentsItem(title: "Nested", part: "//body/h2[1]", page: 0)
        let parent = EPUBTableOfContentsItem(
            title: "Parent",
            part: "//body/h1[1]",
            page: 0,
            children: [child]
        )

        XCTAssertEqual(
            EPUBSectionSelection.selectedID(
                in: [parent],
                currentSpine: 0,
                currentLocator: "//body/h2[1]"
            ),
            child.id
        )
    }

    func testBookmarkLocationHasUsableFallbackBeforeWebViewReports() {
        XCTAssertEqual(EPUBBookmarkLocation.normalized(nil), "//body")
        XCTAssertEqual(EPUBBookmarkLocation.normalized(""), "//body")
        XCTAssertEqual(EPUBBookmarkLocation.normalized("//body/p[3]"), "//body/p[3]")
    }

    func testSectionScrubCommitClampsToValidSpineIndexes() {
        XCTAssertEqual(EPUBSectionScrub.commitTarget(value: 3, spineCount: 10), 3)
        XCTAssertEqual(EPUBSectionScrub.commitTarget(value: -2, spineCount: 10), 0)
        XCTAssertEqual(EPUBSectionScrub.commitTarget(value: 25, spineCount: 10), 9)
        XCTAssertEqual(EPUBSectionScrub.commitTarget(value: 9.6, spineCount: 10), 9)
        XCTAssertEqual(EPUBSectionScrub.commitTarget(value: 5, spineCount: 0), 0)
    }

    func testCustomResourceURLRoundTripsWithoutCredential() throws {
        let remote = URL(string: "https://kavita.example.com/api/Book/5/book-resources?file=font.woff2")!
        let custom = EPUBDocumentBuilder.customResourceURL(for: remote)
        XCTAssertEqual(EPUBDocumentBuilder.remoteURL(from: custom), remote)
    }

    func testResourceSanitizerRejectsCrossOriginAndExecutableURLs() {
        let baseURL = URL(string: "https://kavita.example.com")!
        XCTAssertNil(EPUBResourceReference.sanitized("https://evil.example.com/payload.js", relativeTo: baseURL))
        XCTAssertNil(EPUBResourceReference.sanitized("javascript:alert(1)", relativeTo: baseURL))
        let safe = EPUBResourceReference.sanitized(
            "/api/Book/5/book-resources?apiKey=secret&file=style.css",
            relativeTo: baseURL
        )
        XCTAssertEqual(safe?.query, "file=style.css")

        let kavitaPath = EPUBResourceReference.sanitized(
            "//kavita.example.com/api/book/156/book-resources?apiKey=secret&file=..%2FImages%2FCover.jpg",
            relativeTo: baseURL
        )
        XCTAssertEqual(
            kavitaPath.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedQuery },
            "file=..%2FImages%2FCover.jpg"
        )
    }

    func testResourceMIMETypeUsesKavitaFileQuery() throws {
        let remote = try XCTUnwrap(URL(
            string: "https://kavita.example.com/api/book/156/book-resources?file=..%2FImages%2FCover.jpg"
        ))
        XCTAssertEqual(EPUBDocumentBuilder.resourceMIMEType(for: remote), "image/jpeg")

        let font = try XCTUnwrap(URL(
            string: "https://kavita.example.com/api/book/156/book-resources?file=Fonts%2Freader.woff2"
        ))
        XCTAssertEqual(EPUBDocumentBuilder.resourceMIMEType(for: font), "font/woff2")
    }

    func testLegacyBackgroundDescriptorDefaultsToImagePage() throws {
        let serverID = ServerID()
        let current = DownloadTaskDescriptor(serverID: serverID, bookID: "book", page: 4)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any]
        )
        object.removeValue(forKey: "kind")
        object.removeValue(forKey: "resourceURL")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let descriptor = try JSONDecoder().decode(DownloadTaskDescriptor.self, from: legacy)
        XCTAssertEqual(descriptor.kind, .imagePage)
        XCTAssertEqual(descriptor.page, 4)
        XCTAssertNil(descriptor.resourceURL)
    }

    func testEPUBDownloadDescriptorsRoundTripAsBackgroundTaskKinds() throws {
        let serverID = ServerID()
        let spine = DownloadTaskDescriptor(serverID: serverID, bookID: "book", spine: 7)
        let resource = DownloadTaskDescriptor(
            serverID: serverID,
            bookID: "book",
            resourceURL: "https://kavita.example.com/api/book/1/book-resources?file=cover.jpg"
        )
        let decodedSpine = try JSONDecoder().decode(
            DownloadTaskDescriptor.self,
            from: JSONEncoder().encode(spine)
        )
        let decodedResource = try JSONDecoder().decode(
            DownloadTaskDescriptor.self,
            from: JSONEncoder().encode(resource)
        )
        XCTAssertEqual(decodedSpine.kind, .epubSpine)
        XCTAssertEqual(decodedSpine.page, 7)
        XCTAssertEqual(decodedResource.kind, .epubResource)
        XCTAssertNotNil(decodedResource.resourceURL)
        XCTAssertFalse(BackgroundDownloadCoordinator.sessionIdentifier.isEmpty)
    }

    func testOfflineManifestRequiresAllSpinesAndResources() {
        var manifest = EPUBPackageManifest(
            bookID: "book",
            contentRevision: "revision",
            spineCount: 2,
            tableOfContents: [],
            resourceFiles: ["https://example.com/resource": "resource"],
            completedSpineIndexes: [0],
            completedResourceURLs: []
        )
        XCTAssertFalse(manifest.isComplete)
        manifest.completedSpineIndexes.insert(1)
        XCTAssertFalse(manifest.isComplete)
        manifest.completedResourceURLs.insert("https://example.com/resource")
        XCTAssertTrue(manifest.isComplete)
    }

    func testEPUBLocatorRoundTripsThroughCheckpoint() throws {
        let book = Book(
            key: BookKey(serverID: ServerID(), remoteID: "chapter"),
            seriesKey: SeriesKey(serverID: ServerID(), remoteID: "series"),
            title: "EPUB",
            number: "1",
            numberSort: 1,
            sizeBytes: 0,
            fileHash: "revision",
            mediaType: "application/epub+zip",
            pageCount: 5,
            readPage: nil,
            completed: false,
            readProgressModifiedAt: nil,
            lastModified: nil,
            contentKind: .epub
        )
        let checkpoint = ReadingCheckpoint(book: book, zeroBasedPage: 2, epubLocator: "//body/main[1]/p[4]")
        let decoded = try JSONDecoder().decode(ReadingCheckpoint.self, from: JSONEncoder().encode(checkpoint))
        XCTAssertEqual(decoded.page, 3)
        XCTAssertEqual(decoded.epubLocator, "//body/main[1]/p[4]")
    }
}

@MainActor
private final class EPUBTestNavigationDelegate: NSObject, WKNavigationDelegate {
    private let completion: () -> Void

    init(completion: @escaping () -> Void) {
        self.completion = completion
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        completion()
    }
}
