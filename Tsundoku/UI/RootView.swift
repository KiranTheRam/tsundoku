import SwiftUI

enum AppDestination: String, CaseIterable, Identifiable, Codable {
    case home, library, search, downloads, settings
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .home: "house"
        case .library: "books.vertical"
        case .search: "magnifyingglass"
        case .downloads: "arrow.down.circle"
        case .settings: "gearshape"
        }
    }

    static let navigationDestinations: [AppDestination] = [.home, .library, .downloads, .settings]
}

enum AppNavigationPlacement: String, CaseIterable, Identifiable {
    case top
    case bottom

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var edge: VerticalEdge { self == .top ? .top : .bottom }
}

enum AppNavigationPreferences {
    static let defaultOrder = AppDestination.navigationDestinations

    static func decodeOrder(_ value: String) -> [AppDestination] {
        var seen = Set<AppDestination>()
        let requested = value
            .split(separator: ",")
            .compactMap { AppDestination(rawValue: String($0)) }
            .filter { AppDestination.navigationDestinations.contains($0) && seen.insert($0).inserted }
        return requested + defaultOrder.filter { !seen.contains($0) }
    }

    static func encodeOrder(_ order: [AppDestination]) -> String {
        order.map(\.rawValue).joined(separator: ",")
    }
}

struct RootView: View {
    @Environment(AppState.self) private var appState
    @Environment(SystemNavigationRouter.self) private var systemNavigation

    var body: some View {
        Group {
            if appState.profiles.isEmpty {
                NavigationStack { ConnectionView() }
            } else {
                AdaptiveAppShell()
            }
        }
        .alert("Connection problem", isPresented: Binding(
            get: { appState.startupError != nil },
            set: { if !$0 { appState.startupError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(appState.startupError ?? "Unknown error")
        }
        .alert("Couldn't open item", isPresented: Binding(
            get: { systemNavigation.errorMessage != nil },
            set: { if !$0 { systemNavigation.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(systemNavigation.errorMessage ?? "Unknown error")
        }
        .overlay(alignment: .top) {
            if let notice = appState.progress.syncNotice {
                ProgressSyncToast(notice: notice)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.3), value: appState.progress.syncNotice)
        .sensoryFeedback(trigger: appState.progress.syncNotice) { _, notice in
            guard let notice,
                  let feedback = ManualSyncFeedback.forNotice(operation: notice.operation, state: notice.state) else { return nil }
            return feedback == .success ? .success : .error
        }
        .sensoryFeedback(.success, trigger: appState.downloads.completedDownloadEventCount) { old, new in
            new > old
        }
    }
}

private struct AdaptiveAppShell: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        if horizontalSizeClass == .regular {
            iPadBarShell()
        } else {
            TabShell()
        }
    }
}

private struct TabShell: View {
    @Environment(AppState.self) private var appState
    @Environment(SystemNavigationRouter.self) private var systemNavigation
    @State private var selection: AppDestination = .home
    @State private var libraryScope: LibraryCatalogScope = .series
    @State private var homePath = NavigationPath()
    @State private var libraryPath = NavigationPath()
    @State private var searchPath = NavigationPath()
    @State private var downloadsPath = NavigationPath()
    @State private var settingsPath = NavigationPath()
    @State private var searchActivationID = 0
    @State private var requestedSearchQuery: String?

    var body: some View {
        TabView(selection: directSelection) {
            Tab("Home", systemImage: "house", value: .home) {
                NavigationStack(path: $homePath) {
                    HomeView()
                        .navigationDestination(for: SeriesLaunchRequest.self) { launch in
                            SeriesDetailView(
                                series: launch.series,
                                preferredBookID: launch.preferredBookID,
                                resumesReading: launch.resumesReading
                            )
                            .id(launch.id)
                        }
                }
            }
            Tab("Library", systemImage: "books.vertical", value: .library) { NavigationStack(path: $libraryPath) { LibraryView(scope: $libraryScope) } }
            Tab("Search", systemImage: "magnifyingglass", value: .search, role: .search) {
                NavigationStack(path: $searchPath) {
                    SearchView(activationID: searchActivationID, requestedQuery: requestedSearchQuery)
                }
            }
            Tab("Downloads", systemImage: "arrow.down.circle", value: .downloads) {
                NavigationStack(path: $downloadsPath) { DownloadsView() }
            }
            .badge(appState.downloads.activeCount)
            Tab("Settings", systemImage: "gearshape", value: .settings) { NavigationStack(path: $settingsPath) { SettingsView() } }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .task(id: systemNavigation.pendingRequest?.id) {
            await handleSystemNavigation()
        }
    }

    private var directSelection: Binding<AppDestination> {
        Binding(
            get: { selection },
            set: { destination in
                resetPath(for: destination)
                selection = destination
            }
        )
    }

    private func resetPath(for destination: AppDestination) {
        switch destination {
        case .home: homePath = NavigationPath()
        case .library: libraryPath = NavigationPath()
        case .search: searchPath = NavigationPath()
        case .downloads: downloadsPath = NavigationPath()
        case .settings: settingsPath = NavigationPath()
        }
    }

    @MainActor
    private func handleSystemNavigation() async {
        guard let request = systemNavigation.pendingRequest else { return }
        do {
            switch request.kind {
            case .search:
                searchPath = NavigationPath()
                requestedSearchQuery = request.query ?? ""
                searchActivationID &+= 1
                selection = .search
            case .series:
                let launch = try await appState.resolveSeriesLaunch(request)
                homePath = NavigationPath()
                homePath.append(launch)
                selection = .home
            }
            systemNavigation.complete(request)
        } catch {
            systemNavigation.errorMessage = error.localizedDescription
            systemNavigation.complete(request)
        }
    }
}

private struct iPadBarShell: View {
    @State private var selection: AppDestination = .home
    @State private var libraryScope: LibraryCatalogScope = .series
    @State private var searchActivationID = 0
    @AppStorage("iPadNavigationPlacement") private var placementRaw = AppNavigationPlacement.bottom.rawValue
    @AppStorage("iPadNavigationOrder") private var orderRaw = AppNavigationPreferences.encodeOrder(AppNavigationPreferences.defaultOrder)

    var body: some View {
        iPadCustomBarShell(
            selection: $selection,
            libraryScope: $libraryScope,
            searchActivationID: $searchActivationID,
            destinations: AppNavigationPreferences.decodeOrder(orderRaw),
            edge: placement.edge
        )
    }

    private var placement: AppNavigationPlacement {
        AppNavigationPlacement(rawValue: placementRaw) ?? .bottom
    }
}

private struct iPadCustomBarShell: View {
    @Environment(AppState.self) private var appState
    @Environment(SystemNavigationRouter.self) private var systemNavigation
    @Binding var selection: AppDestination
    @Binding var libraryScope: LibraryCatalogScope
    @Binding var searchActivationID: Int
    let destinations: [AppDestination]
    let edge: VerticalEdge
    @State private var path = NavigationPath()
    @State private var requestedSearchQuery: String?

    var body: some View {
        GeometryReader { geometry in
            NavigationStack(path: $path) {
                iPadDestinationContent(
                    destination: selection,
                    libraryScope: $libraryScope,
                    searchActivationID: searchActivationID,
                    requestedSearchQuery: requestedSearchQuery
                )
                    .id(selection)
                    .navigationDestination(for: SeriesLaunchRequest.self) { launch in
                        SeriesDetailView(
                            series: launch.series,
                            preferredBookID: launch.preferredBookID,
                            resumesReading: launch.resumesReading
                        )
                        .id(launch.id)
                    }
            }
            .safeAreaBar(edge: edge, spacing: 0) {
                appDock(usesCompactLibraryLayout: AppDockLayout.usesCompactLibraryLayout(selection: selection, size: geometry.size))
            }
        }
        .task(id: systemNavigation.pendingRequest?.id) {
            await handleSystemNavigation()
        }
    }

    private func appDock(usesCompactLibraryLayout: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: DesignTokens.dockCornerRadius, style: .continuous)
        return HStack(spacing: usesCompactLibraryLayout ? 5 : 7) {
            ForEach(destinations) { destination in
                dockButton(destination, iconOnly: usesCompactLibraryLayout)
            }

            libraryScopeTray(compact: usesCompactLibraryLayout)

            Divider().frame(height: 30)

            Button {
                navigate(to: .search)
                searchActivationID &+= 1
            } label: {
                Image(systemName: AppDestination.search.symbol)
                    .font((usesCompactLibraryLayout ? Font.title3 : .body).weight(.semibold))
                    .frame(width: usesCompactLibraryLayout ? 48 : 44, height: 40)
                    .foregroundStyle(selection == .search ? .white : .accent)
                    .background(selection == .search ? Color.accentColor : Color.accentColor.opacity(0.12), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Search")
            .accessibilityIdentifier("navigation.search")
        }
        .padding(.horizontal, usesCompactLibraryLayout ? 9 : 12)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: shape)
        .overlay {
            shape
                .stroke(Color.primary.opacity(DesignTokens.hairlineOpacity), lineWidth: 1)
        }
        // The dock changes width while its contents morph. Clip the whole
        // animated composition so no label can render beyond the bar edge.
        .clipShape(shape)
        .contentShape(shape)
        .compositingGroup()
        .shadow(color: .black.opacity(0.12), radius: 12, y: edge == .top ? 4 : -4)
        .padding(.horizontal, usesCompactLibraryLayout ? 10 : 24)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .animation(AppDockLayout.morphAnimation, value: selection)
        .animation(AppDockLayout.morphAnimation, value: usesCompactLibraryLayout)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("App navigation")
    }

    private func dockButton(_ destination: AppDestination, iconOnly: Bool) -> some View {
        Button {
            navigate(to: destination)
        } label: {
            HStack(spacing: iconOnly ? 0 : 6) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: destination.symbol)
                        .font((iconOnly ? Font.title3 : .caption).weight(selection == destination ? .bold : .semibold))
                        .frame(width: iconOnly ? 48 : 26, height: 40)
                    if destination == .downloads, appState.downloads.activeCount > 0 {
                        ActiveDownloadBadge(count: appState.downloads.activeCount)
                            .offset(x: iconOnly ? 0 : 4, y: 1)
                    }
                }

                Text(destination.title)
                    .font(.caption.weight(selection == destination ? .semibold : .medium))
                    .fixedSize()
                    .frame(width: AppDockLayout.labelWidth(for: destination), alignment: .leading)
                    .frame(width: iconOnly ? 0 : AppDockLayout.labelWidth(for: destination), alignment: .leading)
                    .clipped()
            }
            .padding(.horizontal, iconOnly ? 0 : 10)
            .frame(minHeight: 40)
            .foregroundStyle(selection == destination ? .white : .primary)
            .background(selection == destination ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
            .clipped()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(destination.title)
        .accessibilityIdentifier("navigation.\(destination.rawValue)")
    }

    private func libraryScopeTray(compact: Bool) -> some View {
        let width = AppDockLayout.libraryScopeTrayWidth(compact: compact)
        return HStack(spacing: compact ? 5 : 7) {
            Divider().frame(height: 30)
            ForEach(LibraryCatalogScope.allCases) { scope in
                catalogButton(scope, compact: compact)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(width: width)
        // Keep the controls stationary and reveal them through an expanding
        // local viewport. Collapsing reverses the mask instead of sending the
        // controls toward an offscreen insertion/removal point.
        .frame(width: selection == .library ? width : 0, alignment: .leading)
        .clipped()
        .allowsHitTesting(selection == .library)
        .accessibilityHidden(selection != .library)
    }

    private func catalogButton(_ scope: LibraryCatalogScope, compact: Bool) -> some View {
        Button {
            path = NavigationPath()
            selection = .library
            libraryScope = scope
        } label: {
            Text(scope.title)
                .font(.caption.weight(libraryScope == scope ? .semibold : .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.88)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(libraryScope == scope ? Color.accentColor : .secondary)
                .padding(.horizontal, compact ? 7 : 9)
                .frame(minHeight: compact ? 40 : 36)
                .background(
                    libraryScope == scope ? Color.accentColor.opacity(0.13) : .clear,
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show \(scope.title)")
        .accessibilityAddTraits(libraryScope == scope ? .isSelected : [])
        .accessibilityIdentifier("library.scope.\(scope.rawValue)")
    }

    private func navigate(to destination: AppDestination) {
        withAnimation(AppDockLayout.morphAnimation) {
            path = NavigationPath()
            selection = destination
        }
    }

    @MainActor
    private func handleSystemNavigation() async {
        guard let request = systemNavigation.pendingRequest else { return }
        do {
            switch request.kind {
            case .search:
                path = NavigationPath()
                requestedSearchQuery = request.query ?? ""
                searchActivationID &+= 1
                selection = .search
            case .series:
                let launch = try await appState.resolveSeriesLaunch(request)
                path = NavigationPath()
                selection = .home
                path.append(launch)
            }
            systemNavigation.complete(request)
        } catch {
            systemNavigation.errorMessage = error.localizedDescription
            systemNavigation.complete(request)
        }
    }

}

private struct ActiveDownloadBadge: View {
    let count: Int

    var body: some View {
        Text(count.formatted())
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 4)
            .frame(minWidth: 17, minHeight: 17)
            .background(.red, in: Capsule())
            .accessibilityHidden(true)
    }
}

enum AppDockLayout {
    static let morphAnimation = Animation.snappy(duration: 0.34, extraBounce: 0.06)

    static func libraryScopeTrayWidth(compact: Bool) -> CGFloat {
        compact ? 270 : 288
    }

    static func labelWidth(for destination: AppDestination) -> CGFloat {
        switch destination {
        case .home: 34
        case .library: 42
        case .downloads: 62
        case .settings: 46
        case .search: 40
        }
    }

    static func usesCompactLibraryLayout(selection: AppDestination, size: CGSize) -> Bool {
        selection == .library && min(size.width, size.height) <= 760
    }
}

private struct iPadDestinationContent: View {
    let destination: AppDestination
    @Binding var libraryScope: LibraryCatalogScope
    let searchActivationID: Int
    let requestedSearchQuery: String?

    @ViewBuilder var body: some View {
        switch destination {
        case .home: HomeView()
        case .library: LibraryView(scope: $libraryScope, showsCatalogPicker: false)
        case .search: SearchView(activationID: searchActivationID, requestedQuery: requestedSearchQuery)
        case .downloads: DownloadsView()
        case .settings: SettingsView()
        }
    }
}
