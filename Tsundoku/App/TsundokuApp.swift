import SwiftData
import SwiftUI

@main
struct TsundokuApp: App {
    private let container: ModelContainer
    @State private var appState: AppState
    @Environment(\.scenePhase) private var scenePhase

    init() {
        do {
            let container = try AppModelContainer.make()
            self.container = container
            _appState = State(initialValue: AppState(modelContainer: container))
        } catch {
            fatalError("Unable to initialize the data store: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                // iOS 26.5 ignores NSAccentColorName at runtime, so the asset
                // accent (with its dark variant) is applied explicitly.
                .tint(Color(.accent))
                .environment(appState)
                .environment(appState.progress)
                .environment(appState.downloads)
                .environment(SystemNavigationRouter.shared)
                .modelContainer(container)
                .onOpenURL { url in
                    guard let request = SystemNavigationRequest(url: url) else { return }
                    TsundokuSharedStore.savePendingRoute(request)
                    SystemNavigationRouter.shared.submit(request)
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        SystemNavigationRouter.shared.consumeStoredRequest()
                        appState.beginSetupReconciliation()
                    case .background:
                        appState.pauseSetupReconciliation()
                        if let client = appState.activeClient {
                            appState.progress.beginBackgroundFlush(client: client)
                        }
                    case .inactive:
                        break
                    @unknown default:
                        break
                    }
                }
        }
        .backgroundTask(.urlSession(BackgroundDownloadCoordinator.sessionIdentifier)) {
            await BackgroundDownloadCoordinator.shared.handleBackgroundEvents()
        }
    }
}
