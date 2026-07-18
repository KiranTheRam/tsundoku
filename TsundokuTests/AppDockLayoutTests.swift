import CoreGraphics
import Testing
@testable import Tsundoku

struct AppDockLayoutTests {
    @Test
    func expandedLibraryDockUsesIconsOnCompactDevicesOnly() {
        #expect(AppDockLayout.usesCompactLibraryLayout(selection: .library, size: CGSize(width: 402, height: 874)))
        #expect(AppDockLayout.usesCompactLibraryLayout(selection: .library, size: CGSize(width: 1_133, height: 744)))
        #expect(!AppDockLayout.usesCompactLibraryLayout(selection: .library, size: CGSize(width: 1_194, height: 834)))
        #expect(!AppDockLayout.usesCompactLibraryLayout(selection: .home, size: CGSize(width: 744, height: 1_133)))
    }

    @Test func libraryScopeTrayUsesStableMaskedWidths() {
        #expect(AppDockLayout.libraryScopeTrayWidth(compact: true) == 270)
        #expect(AppDockLayout.libraryScopeTrayWidth(compact: false) == 288)
        #expect(AppDockLayout.labelWidth(for: .downloads) > AppDockLayout.labelWidth(for: .home))
    }
}
