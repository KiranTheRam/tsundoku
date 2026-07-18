import Testing
@testable import Tsundoku

struct AppNavigationPreferencesTests {
    @Test func decodesCustomOrderAndAppendsMissingDestinations() {
        let order = AppNavigationPreferences.decodeOrder("settings,home")
        #expect(order == [.settings, .home, .library, .downloads])
    }

    @Test func ignoresSearchUnknownValuesAndDuplicates() {
        let order = AppNavigationPreferences.decodeOrder("downloads,search,nope,downloads,library")
        #expect(order == [.downloads, .library, .home, .settings])
        #expect(AppNavigationPreferences.encodeOrder(order) == "downloads,library,home,settings")
    }
}
