import Foundation
import Testing
@testable import Tsundoku

@Suite("Reader preloading")
struct ReaderPreloadTests {
    @Test("LTR and vertical preload six ahead and two behind")
    func forwardPreloadWindow() {
        #expect(
            ReaderPreloadPlanner.displayIndexes(around: 10, unitCount: 30, mode: .pagedLeftToRight)
                == [11, 12, 13, 14, 15, 16, 9, 8]
        )
        #expect(
            ReaderPreloadPlanner.displayIndexes(around: 10, unitCount: 30, mode: .verticalContinuous)
                == [11, 12, 13, 14, 15, 16, 9, 8]
        )
    }

    @Test("RTL preloads toward decreasing display indexes")
    func rightToLeftPreloadWindow() {
        #expect(
            ReaderPreloadPlanner.displayIndexes(around: 10, unitCount: 30, mode: .pagedRightToLeft)
                == [9, 8, 7, 6, 5, 4, 11, 12]
        )
    }

    @Test("Preload window is clamped at book boundaries")
    func clampedPreloadWindow() {
        #expect(
            ReaderPreloadPlanner.displayIndexes(around: 0, unitCount: 4, mode: .pagedLeftToRight)
                == [1, 2, 3]
        )
        #expect(ReaderPreloadPlanner.displayIndexes(around: 0, unitCount: 0, mode: .pagedLeftToRight).isEmpty)
    }

    @Test("Byte progress handles known and unknown response lengths")
    func byteProgress() {
        #expect(PageLoadingProgress.fraction(totalBytesWritten: 25, expectedBytes: 100) == 0.25)
        #expect(PageLoadingProgress.fraction(totalBytesWritten: 125, expectedBytes: 100) == 1)
        #expect(PageLoadingProgress.fraction(totalBytesWritten: 25, expectedBytes: -1) == nil)
    }

    @Test("Visible page loads retry transient transport failures")
    func visiblePageRetryPolicy() {
        #expect(PageLoadRetryPolicy.shouldRetry(URLError(.timedOut), attempt: 1, priority: .visible))
        #expect(!PageLoadRetryPolicy.shouldRetry(URLError(.timedOut), attempt: 2, priority: .visible))
        #expect(!PageLoadRetryPolicy.shouldRetry(URLError(.timedOut), attempt: 1, priority: .prefetch))
        #expect(!PageLoadRetryPolicy.shouldRetry(URLError(.cancelled), attempt: 1, priority: .visible))
    }
}
