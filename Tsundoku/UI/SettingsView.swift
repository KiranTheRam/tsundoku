import SwiftData
import SwiftUI

struct SettingsView: View {
    private enum ResetScope {
        case device
        case synchronizedSetup

        var title: String {
            switch self {
            case .device: "Reset this device?"
            case .synchronizedSetup: "Erase synchronized setup everywhere?"
            }
        }

        var actionTitle: String {
            switch self {
            case .device: "Reset This Device"
            case .synchronizedSetup: "Erase Everywhere"
            }
        }

        var message: String {
            switch self {
            case .device:
                "Downloads, caches, pending work, and device preferences will be erased. Servers and tracker accounts stored in iCloud will restore automatically."
            case .synchronizedSetup:
                "Servers, tracker connections, OAuth configuration, and series links will be removed from iCloud and iCloud Keychain for every device. Reading history and bookmarks are not removed."
            }
        }
    }

    private struct ResetNotice: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    private static let allLibraries = "__all_libraries__"

    @Environment(AppState.self) private var appState
    @Query private var pending: [PendingProgressRecord]
    @State private var showsConnection = false
    @State private var removeCandidate: ServerProfile?
    @State private var libraries: [Library] = []
    @State private var defaultLibrarySelection = Self.allLibraries
    @State private var libraryLoadError: String?
    @State private var isRefreshingArtwork = false
    @State private var resetCandidate: ResetScope?
    @State private var resetNotice: ResetNotice?
    @State private var isResetting = false
    @AppStorage("downloadsWiFiOnly") private var downloadsWiFiOnly = false
    @AppStorage("iPadNavigationPlacement") private var iPadNavigationPlacement = AppNavigationPlacement.bottom.rawValue

    var body: some View {
        Form {
            Section("Content servers") {
                ForEach(appState.profiles) { profile in
                    Button { Task { await appState.activate(profile) } } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(profile.name).foregroundStyle(.primary)
                                Text("\(profile.kind.title) · \(profile.baseURL.absoluteString)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if profile.id == appState.activeProfile?.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
                        }
                    }
                    .swipeActions {
                        Button("Remove", systemImage: "trash", role: .destructive) { removeCandidate = profile }
                    }
                }
                Button("Add server", systemImage: "plus") { showsConnection = true }
            }

            Section("Library") {
                Picker("Default library", selection: $defaultLibrarySelection) {
                    Text("All Libraries").tag(Self.allLibraries)
                    ForEach(libraries.filter { !$0.unavailable }) { library in
                        Text(library.name).tag(library.id)
                    }
                }
                .disabled(appState.activeProfile == nil)
                .accessibilityIdentifier("settings.defaultLibrary")

                Text("Home and Library open with this selection. You can still switch libraries from the Library screen.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if let libraryLoadError, libraries.isEmpty {
                    Label(libraryLoadError, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }

            Section("Synchronization") {
                LabeledContent("\(appState.activeProfile?.kind.title ?? "Server") progress", value: "Source of truth")
                LabeledContent("Setup") {
                    Label(setupSyncTitle, systemImage: setupSyncSymbol)
                        .foregroundStyle(appState.setupSyncStatus == .ready ? .green : .secondary)
                }
                LabeledContent("iCloud metadata") {
                    Label(cloudStatusTitle, systemImage: cloudStatusSymbol)
                        .foregroundStyle(cloudStatusColor)
                }
                NavigationLink { SyncProblemsView() } label: {
                    LabeledContent("Sync problems", value: "\(pending.filter { $0.lastError != nil }.count)")
                }
                NavigationLink { TrackerSettingsView() } label: {
                    Label("AniList & MyAnimeList", systemImage: "arrow.triangle.2.circlepath")
                }
            }

            Section("Reading Statistics") {
                LabeledContent("Pages today", value: appState.readingStatistics().pagesToday.formatted())
                LabeledContent("Pages this week", value: appState.readingStatistics().pagesThisWeek.formatted())
                Text("Counts settled forward reading across your devices. Restores, scrubbing, and moving backward do not add pages; EPUBs use normalized sections because rendered pages vary by device and typography.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("iPad Navigation") {
                Picker("Navigation bar position", selection: $iPadNavigationPlacement) {
                    ForEach(AppNavigationPlacement.allCases) { placement in
                        Text(placement.title).tag(placement.rawValue)
                    }
                }
                NavigationLink {
                    AppNavigationOrderView()
                } label: {
                    Label("Customize button order", systemImage: "arrow.up.arrow.down")
                }
                Text("The same Reader Dock is used at the top or bottom. Library catalog options join the dock while Library is selected, and Search remains a separate action.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Storage") {
                Toggle("Downloads on Wi-Fi only", isOn: $downloadsWiFiOnly)
                LabeledContent("Catalog cache", value: "On")
                LabeledContent("Downloads", value: "Device only")
                Button {
                    Task { await refreshCoverArtwork() }
                } label: {
                    if isRefreshingArtwork {
                        Label("Refreshing cover artwork…", systemImage: "arrow.clockwise")
                    } else {
                        Label("Refresh cover artwork", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(isRefreshingArtwork || appState.activeClient == nil)
                .accessibilityIdentifier("settings.refreshCoverArtwork")
                Text("Clears cached covers and fetches current artwork from the active server. Downloads and reading data are not removed.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("Downloaded pages use complete file protection, are excluded from backup, and remain on this device.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section("Reset") {
                Button("Reset This Device", systemImage: "iphone.slash", role: .destructive) {
                    resetCandidate = .device
                }
                .disabled(isResetting)
                .accessibilityIdentifier("settings.resetDevice")

                Button("Erase Synced Setup Everywhere", systemImage: "icloud.slash", role: .destructive) {
                    resetCandidate = .synchronizedSetup
                }
                .disabled(isResetting)
                .accessibilityIdentifier("settings.eraseSyncedSetup")

                if isResetting {
                    HStack {
                        ProgressView()
                        Text("Resetting Tsundoku…")
                    }
                }

                Text("Use Reset This Device for normal troubleshooting. To test first-time setup syncing, erase synchronized setup once, reset the second device, then configure one device.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("About") {
                LabeledContent("App", value: "Tsundoku")
                LabeledContent("Requires", value: "iOS 26 · Komga 1.25+ · Kavita 0.9.0.2+")
                Text("HTTP is allowed only for local addresses. Local HTTP exposes credentials and reading activity to the LAN; use HTTPS when possible.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
        .task(id: libraryTaskID) {
            async let librariesTask: Void = loadLibraries()
            async let cloudTask: Void = appState.refreshCloudSyncStatus()
            _ = await (librariesTask, cloudTask)
        }
        .onChange(of: defaultLibrarySelection) { _, selection in
            guard let serverID = appState.activeProfile?.id else { return }
            appState.setDefaultLibraryID(selection == Self.allLibraries ? nil : selection, for: serverID)
        }
        .sheet(isPresented: $showsConnection) { NavigationStack { ConnectionView() } }
        .confirmationDialog("Remove this server?", isPresented: Binding(get: { removeCandidate != nil }, set: { if !$0 { removeCandidate = nil } }), titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                guard let profile = removeCandidate else { return }
                Task { try? await appState.remove(profile); removeCandidate = nil }
            }
            Button("Cancel", role: .cancel) { removeCandidate = nil }
        }
        .confirmationDialog(
            resetCandidate?.title ?? "Reset Tsundoku?",
            isPresented: Binding(
                get: { resetCandidate != nil },
                set: { if !$0 { resetCandidate = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let resetCandidate {
                Button(resetCandidate.actionTitle, role: .destructive) {
                    performReset(resetCandidate)
                }
            }
            Button("Cancel", role: .cancel) { resetCandidate = nil }
        } message: {
            Text(resetCandidate?.message ?? "")
        }
        .alert(item: $resetNotice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private var libraryTaskID: String {
        "\(appState.activeProfile?.id.description ?? "none"):\(appState.activeClient == nil ? "pending" : "ready")"
    }

    private var cloudStatusTitle: String {
        switch appState.cloudSyncStatus {
        case .checking: "Checking…"
        case .available: "Available"
        case .noAccount: "Sign in to iCloud"
        case .restricted: "Restricted"
        case .temporarilyUnavailable: "Temporarily unavailable"
        case .failed: "Unavailable"
        }
    }

    private var setupSyncTitle: String {
        switch appState.setupSyncStatus {
        case .checking: "Checking iCloud…"
        case .waitingForCredentials: "Waiting for Keychain…"
        case .ready: "Up to date"
        }
    }

    private var setupSyncSymbol: String {
        switch appState.setupSyncStatus {
        case .checking: "arrow.triangle.2.circlepath.icloud"
        case .waitingForCredentials: "key.icloud"
        case .ready: "checkmark.icloud.fill"
        }
    }

    private var cloudStatusSymbol: String {
        switch appState.cloudSyncStatus {
        case .checking: "arrow.triangle.2.circlepath.icloud"
        case .available: "checkmark.icloud.fill"
        case .noAccount, .restricted, .temporarilyUnavailable, .failed: "exclamationmark.icloud"
        }
    }

    private var cloudStatusColor: Color {
        appState.cloudSyncStatus == .available ? .green : .secondary
    }

    private func refreshCoverArtwork() async {
        guard !isRefreshingArtwork else { return }
        isRefreshingArtwork = true
        await appState.refreshPosterArtwork()
        isRefreshingArtwork = false
    }

    private func performReset(_ scope: ResetScope) {
        resetCandidate = nil
        isResetting = true
        Task {
            defer { isResetting = false }
            do {
                switch scope {
                case .device:
                    try await appState.resetThisDevice()
                    resetNotice = ResetNotice(
                        title: "Device Reset Complete",
                        message: "Device-only data was erased. Tsundoku is now checking iCloud for your synchronized setup."
                    )
                case .synchronizedSetup:
                    try await appState.eraseSyncedSetupEverywhere()
                    resetNotice = ResetNotice(
                        title: "Synchronized Setup Erased",
                        message: "Server and tracker setup was removed from iCloud and this device was reset. Other devices will update when they next synchronize."
                    )
                }
            } catch {
                resetNotice = ResetNotice(title: "Reset Failed", message: error.localizedDescription)
            }
        }
    }

    private func loadLibraries() async {
        guard let profile = appState.activeProfile else {
            libraries = []
            defaultLibrarySelection = Self.allLibraries
            return
        }

        libraries = appState.cachedLibraries(for: profile.id)
        defaultLibrarySelection = appState.defaultLibraryID(for: profile.id) ?? Self.allLibraries
        libraryLoadError = nil

        guard let client = appState.activeClient else { return }
        do {
            let refreshed = try await client.libraries()
            libraries = refreshed
            appState.cacheLibraries(refreshed, for: profile.id)
            if defaultLibrarySelection != Self.allLibraries,
               !refreshed.contains(where: { $0.id == defaultLibrarySelection && !$0.unavailable }) {
                defaultLibrarySelection = Self.allLibraries
            }
        } catch is CancellationError {
            return
        } catch {
            libraryLoadError = error.localizedDescription
        }
    }
}

private struct AppNavigationOrderView: View {
    @AppStorage("iPadNavigationOrder") private var storedOrder = AppNavigationPreferences.encodeOrder(AppNavigationPreferences.defaultOrder)
    @State private var order: [AppDestination] = AppNavigationPreferences.defaultOrder

    var body: some View {
        List {
            Section {
                ForEach(order) { destination in
                    Label(destination.title, systemImage: destination.symbol)
                }
                .onMove { indices, destination in
                    order.move(fromOffsets: indices, toOffset: destination)
                    storedOrder = AppNavigationPreferences.encodeOrder(order)
                }
            } footer: {
                Text("Drag destinations into your preferred order. Search is always kept separate at the end of the bar.")
            }
        }
        .navigationTitle("Button Order")
        .toolbar { EditButton() }
        .onAppear { order = AppNavigationPreferences.decodeOrder(storedOrder) }
    }
}

struct SyncProblemsView: View {
    @Environment(AppState.self) private var appState
    @Query(sort: \PendingProgressRecord.nextAttemptAt) private var pending: [PendingProgressRecord]

    var body: some View {
        List {
            if pending.isEmpty {
                ContentUnavailableView("Everything is synced", systemImage: "checkmark.icloud")
            } else {
                ForEach(pending) { item in
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Book \(item.bookID)").font(.headline)
                        Text(item.lastError ?? "Waiting to sync")
                            .foregroundStyle(item.lastError == nil ? Color.secondary : Color.red)
                        Text("Attempt \(item.attempts + 1) · next \(item.nextAttemptAt.formatted(.relative(presentation: .named)))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Sync Problems")
        .toolbar {
            Button("Retry All") {
                guard let client = appState.activeClient else { return }
                Task { await appState.progress.retryAll(client: client) }
            }
            .disabled(pending.isEmpty)
        }
    }
}
