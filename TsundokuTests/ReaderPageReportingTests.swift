import Testing
@testable import Tsundoku

struct ReaderPageReportingTests {
    @Test
    func restoredPageUpdatesUIWithoutSavingProgress() {
        var state = ReaderPageReportingState()

        let changes = state.changes(for: 3, settled: false)

        #expect(changes.visible == 3)
        #expect(changes.settled == nil)
    }

    @Test
    func visiblePageChangesAreImmediateWhileProgressWaitsForSettlement() {
        var state = ReaderPageReportingState()

        var changes = state.changes(for: 70, settled: false)
        #expect(changes.visible == 70)
        #expect(changes.settled == nil)

        changes = state.changes(for: 70, settled: false)
        #expect(changes.visible == nil)
        #expect(changes.settled == nil)

        changes = state.changes(for: 71, settled: false)
        #expect(changes.visible == 71)
        #expect(changes.settled == nil)

        changes = state.changes(for: 71, settled: true)
        #expect(changes.visible == nil)
        #expect(changes.settled == 71)

        changes = state.changes(for: 72, settled: true)
        #expect(changes.visible == 72)
        #expect(changes.settled == 72)
    }
}
