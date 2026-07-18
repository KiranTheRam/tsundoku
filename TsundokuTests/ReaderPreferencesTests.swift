import Foundation
import Testing
@testable import Tsundoku

struct ReaderPreferencesTests {
    @Test func decodesOlderPreferencesWithoutResettingSavedMode() throws {
        let data = Data(#"{"mode":"verticalContinuous","brightness":0.7}"#.utf8)
        let preferences = try JSONDecoder().decode(ReaderPreferences.self, from: data)

        #expect(preferences.mode == .verticalContinuous)
        #expect(preferences.brightness == 0.7)
        #expect(preferences.spreadMode == .automatic)
        #expect(preferences.keepsCoverSingle)
    }

    @MainActor
    @Test func appStatePersistsReaderPreferencesAcrossRelaunches() throws {
        let suiteName = "ReaderPreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let container = try AppModelContainer.make(inMemory: true)
        let firstState = AppState(modelContainer: container, credentials: CredentialStore(), defaults: defaults)
        let expected = ReaderPreferences(
            mode: .verticalContinuous,
            spreadMode: .single,
            widePagePolicy: .fit,
            cropPolicy: .automatic,
            pageGap: 19,
            showsStatusBar: true,
            keepsCoverSingle: false,
            brightness: 0.65
        )

        firstState.setReaderPreferences(expected)
        let relaunchedState = AppState(modelContainer: container, credentials: CredentialStore(), defaults: defaults)

        #expect(relaunchedState.readerPreferences() == expected)
    }
}
