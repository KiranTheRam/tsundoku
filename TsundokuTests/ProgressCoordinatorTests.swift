import Foundation
import Testing
@testable import Tsundoku

@MainActor
struct ProgressCoordinatorTests {
    @Test("Cancelled replacement requests do not surface as sync failures")
    func cancelledRequestsAreNotReported() {
        #expect(!ProgressSyncFailurePolicy.shouldReport(CancellationError()))
        #expect(!ProgressSyncFailurePolicy.shouldReport(URLError(.cancelled)))
        #expect(ProgressSyncFailurePolicy.shouldReport(URLError(.timedOut)))
    }

    @Test("Only manual mark read/unread outcomes trigger haptic feedback")
    func manualSyncFeedbackIsLimitedToManualOutcomes() {
        #expect(ManualSyncFeedback.forNotice(operation: .markRead(title: "Vol 1"), state: .succeeded) == .success)
        #expect(ManualSyncFeedback.forNotice(operation: .markUnread(title: "Vol 1"), state: .failed("offline")) == .error)
        #expect(ManualSyncFeedback.forNotice(operation: .markRead(title: "Vol 1"), state: .syncing) == nil)
        #expect(ManualSyncFeedback.forNotice(operation: .progress(page: 12), state: .succeeded) == nil)
        #expect(ManualSyncFeedback.forNotice(operation: .progress(page: 12), state: .failed("offline")) == nil)
    }

    @Test("A newer lower page replaces an older pending page")
    func newestPendingCheckpointReplacesFurthestPage() throws {
        let container = try AppModelContainer.make(inMemory: true)
        let coordinator = ProgressCoordinator(modelContainer: container)
        let serverID = ServerID(UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
        let book = BookKey(serverID: serverID, remoteID: "book")
        let profile = ServerProfile(
            id: serverID,
            name: "Test",
            baseURL: URL(string: "https://example.com")!,
            userID: "user",
            username: "user@example.com",
            isActive: true
        )
        let komga = KomgaClient(profile: profile, apiKey: "test")
        let client = ServerClient(komga: komga, profile: profile)

        coordinator.record(
            ReadingCheckpoint(book: book, zeroBasedPage: 293, pageCount: 353, observedAt: Date(timeIntervalSince1970: 1_000)),
            client: client
        )
        coordinator.record(
            ReadingCheckpoint(book: book, zeroBasedPage: 3, pageCount: 353, observedAt: Date(timeIntervalSince1970: 2_000)),
            client: client
        )

        #expect(coordinator.pendingCheckpoint(for: book)?.page == 4)
    }

    @Test("Offline reading checkpoints remain pending for the next connection")
    func offlineCheckpointIsDurable() throws {
        let container = try AppModelContainer.make(inMemory: true)
        let coordinator = ProgressCoordinator(modelContainer: container)
        let serverID = ServerID(UUID(uuidString: "44444444-4444-4444-4444-444444444444")!)
        let book = BookKey(serverID: serverID, remoteID: "downloaded-book")

        coordinator.recordOffline(
            ReadingCheckpoint(book: book, zeroBasedPage: 24, pageCount: 100)
        )

        #expect(coordinator.pendingCheckpoint(for: book)?.page == 25)
    }

    @Test("Progress retries use bounded exponential backoff")
    func retryBackoffIsBounded() {
        #expect(ProgressRetryPolicy.delay(attempts: 0) == 5)
        #expect(ProgressRetryPolicy.delay(attempts: 1) == 10)
        #expect(ProgressRetryPolicy.delay(attempts: 4) == 80)
        #expect(ProgressRetryPolicy.delay(attempts: 20) == 3_600)
    }
}
