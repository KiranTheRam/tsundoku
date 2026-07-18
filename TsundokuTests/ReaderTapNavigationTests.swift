import CoreGraphics
import Testing
@testable import Tsundoku

struct ReaderTapNavigationTests {
    @Test func verticalTapsNeverNavigate() {
        #expect(ReaderTapNavigation.action(mode: .verticalContinuous, x: 1, width: 400) == .toggleChrome)
        #expect(ReaderTapNavigation.action(mode: .verticalContinuous, x: 200, width: 400) == .toggleChrome)
        #expect(ReaderTapNavigation.action(mode: .verticalContinuous, x: 399, width: 400) == .toggleChrome)
    }

    @Test func leftToRightEdgesFollowPhysicalDirection() {
        #expect(ReaderTapNavigation.action(mode: .pagedLeftToRight, x: 1, width: 400) == .previousPage)
        #expect(ReaderTapNavigation.action(mode: .pagedLeftToRight, x: 399, width: 400) == .nextPage)
        #expect(ReaderTapNavigation.action(mode: .pagedLeftToRight, x: 200, width: 400) == .toggleChrome)
    }

    @Test func rightToLeftEdgesFollowPhysicalDirection() {
        #expect(ReaderTapNavigation.action(mode: .pagedRightToLeft, x: 1, width: 400) == .nextPage)
        #expect(ReaderTapNavigation.action(mode: .pagedRightToLeft, x: 399, width: 400) == .previousPage)
        #expect(ReaderTapNavigation.action(mode: .pagedRightToLeft, x: 200, width: 400) == .toggleChrome)
    }

    @Test func horizontalContentOffsetDoesNotTurnCenterTapIntoEdgeTap() {
        let viewportX = ReaderTapNavigation.viewportX(contentX: 1_400, boundsMinX: 1_200)
        #expect(viewportX == 200)
        #expect(ReaderTapNavigation.action(mode: .pagedRightToLeft, x: viewportX, width: 400) == .toggleChrome)
    }
}
