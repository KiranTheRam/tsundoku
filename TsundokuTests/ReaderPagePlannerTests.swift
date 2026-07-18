import CoreGraphics
import XCTest
@testable import Tsundoku

final class ReaderPagePlannerTests: XCTestCase {
    private let pages = [
        BookPage(number: 1, fileName: "cover.jpg", mediaType: "image/jpeg", width: 1000, height: 1500, sizeBytes: nil),
        BookPage(number: 2, fileName: "spread.jpg", mediaType: "image/jpeg", width: 2000, height: 1000, sizeBytes: nil),
        BookPage(number: 3, fileName: "page.jpg", mediaType: "image/jpeg", width: 1000, height: 1500, sizeBytes: nil)
    ]

    func testRTLWidePageSplitOrder() {
        var preferences = ReaderPreferences()
        preferences.mode = .pagedRightToLeft
        preferences.spreadMode = .single
        preferences.widePagePolicy = .split
        let units = ReaderPagePlanner.units(pages: pages, preferences: preferences, landscape: false)
        XCTAssertEqual(units.count, 4)
        XCTAssertEqual(units[1].segments[0].normalizedCrop.minX, 0.5)
        XCTAssertEqual(units[2].segments[0].normalizedCrop.minX, 0)
    }

    func testCoverStaysSingleInSpreadMode() {
        var preferences = ReaderPreferences()
        preferences.widePagePolicy = .fit
        preferences.spreadMode = .double
        let units = ReaderPagePlanner.units(pages: pages, preferences: preferences, landscape: true)
        XCTAssertEqual(units.first?.segments.count, 1)
        XCTAssertEqual(units.dropFirst().first?.segments.count, 2)
    }

    func testReaderChromeDoesNotCreateSliderWithoutMultiplePages() {
        XCTAssertNil(ReaderChromeMetrics.pageSliderRange(pageCount: 0))
        XCTAssertNil(ReaderChromeMetrics.pageSliderRange(pageCount: 1))
        XCTAssertEqual(ReaderChromeMetrics.pageSliderRange(pageCount: 2), 0...1)
        XCTAssertEqual(ReaderChromeMetrics.pageSliderRange(pageCount: 500), 0...499)
    }

    func testReaderBottomChromeUsesCompactPaddingWithoutShrinkingControls() {
        XCTAssertEqual(ReaderChromeMetrics.bottomPanelSpacing, 6)
        XCTAssertEqual(ReaderChromeMetrics.bottomPanelHorizontalPadding, 12)
        XCTAssertEqual(ReaderChromeMetrics.bottomPanelVerticalPadding, 8)
        XCTAssertEqual(ReaderChromeMetrics.bottomPanelOuterPadding, 6)
    }

    func testReaderTopChromeUsesLargerTargetsAtRegularWidth() {
        XCTAssertEqual(ReaderChromeMetrics.topControlSize(isRegularWidth: false), 44)
        XCTAssertEqual(ReaderChromeMetrics.topControlSize(isRegularWidth: true), 56)
    }

    func testRTLCollectionOrderKeepsPageIdentityExplicit() {
        let preferences = ReaderPreferences()
        let units = ReaderPagePlanner.units(pages: pages, preferences: preferences, landscape: false)
        let chronologicalPages = units.map(\.firstPage)

        XCTAssertEqual(ReaderCollectionOrder.displayUnits(units, mode: .pagedRightToLeft).map(\.firstPage), Array(chronologicalPages.reversed()))
        XCTAssertEqual(ReaderCollectionOrder.displayUnits(units, mode: .pagedLeftToRight).map(\.firstPage), chronologicalPages)
        XCTAssertEqual(ReaderCollectionOrder.displayUnits(units, mode: .verticalContinuous).map(\.firstPage), chronologicalPages)
    }

    func testRTLInitialPositionFindsRequestedPageAfterOrderReversal() {
        let units = (0..<5).map { page in
            ReaderDisplayUnit(segments: [PageSegment(pageIndex: page, normalizedCrop: CGRect(x: 0, y: 0, width: 1, height: 1))])
        }
        let rtl = ReaderCollectionOrder.displayUnits(units, mode: .pagedRightToLeft)
        XCTAssertEqual(ReaderInitialPosition.displayIndex(for: 1, in: rtl), 3)
        XCTAssertEqual(rtl[3].firstPage, 1)
    }

    func testVerticalVisiblePageUsesReadingLineNearTop() {
        let point = ReaderVisiblePageReference.point(
            bounds: CGRect(x: 0, y: 0, width: 390, height: 800),
            contentOffset: CGPoint(x: 0, y: 1_000),
            mode: .verticalContinuous
        )

        XCTAssertEqual(point.x, 195)
        XCTAssertEqual(point.y, 1_120)
    }

    func testPagedVisiblePageUsesViewportCenter() {
        let point = ReaderVisiblePageReference.point(
            bounds: CGRect(x: 0, y: 0, width: 390, height: 800),
            contentOffset: CGPoint(x: 390, y: 0),
            mode: .pagedLeftToRight
        )

        XCTAssertEqual(point.x, 585)
        XCTAssertEqual(point.y, 400)
    }
}
