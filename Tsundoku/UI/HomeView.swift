import SwiftData
import SwiftUI

struct HomeView: View {
    @Environment(AppState.self) private var appState
    @Query(sort: \HistoryRecord.readAt, order: .reverse) private var history: [HistoryRecord]
    @State private var pinnedSeries: [Series] = []
    @State private var recentlyUpdated: [Series] = []
    @State private var continueReading: [Series] = []
    @State private var isLoadingUpdates = false
    @State private var updateError: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                if !pinnedSeries.isEmpty {
                    HomeSeriesRail(title: "Pinned", symbol: "pin.fill", series: pinnedSeries) { item in
                        appState.setPinned(false, series: item)
                    }
                }

                if !continueReading.isEmpty {
                    HomeSeriesRail(title: "Continue Reading", symbol: "play.circle.fill", series: continueReading)
                }

                if !recentlyUpdated.isEmpty {
                    HomeSeriesRail(title: "Recently Updated", symbol: "sparkles", series: recentlyUpdated)
                } else if isLoadingUpdates {
                    sectionHeader("Recently Updated", symbol: "sparkles")
                    SeriesRailSkeleton()
                } else if let updateError {
                    LoadFailureView(title: "Recent updates unavailable", message: updateError) {
                        Task { await loadRecentlyUpdated() }
                    }
                    .frame(maxWidth: .infinity, minHeight: 180)
                }

                if !history.isEmpty {
                    sectionHeader("Recent History", symbol: "clock.arrow.circlepath")
                    VStack(spacing: 10) {
                        ForEach(history.prefix(8)) { entry in
                            HStack {
                                Image(systemName: "book.pages").frame(width: 36).foregroundStyle(.tint)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.seriesTitle).font(.headline).lineLimit(1)
                                    Text("\(entry.bookTitle) · Page \(entry.page)").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Text(entry.readAt, style: .relative).font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .cardSurface()
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .padding(.horizontal)
                }

                if pinnedSeries.isEmpty && continueReading.isEmpty && recentlyUpdated.isEmpty
                    && history.isEmpty && !isLoadingUpdates && updateError == nil {
                    ContentUnavailableView("Your reading home", systemImage: "books.vertical", description: Text("Connect a content server and start reading to fill this page."))
                        .frame(maxWidth: .infinity, minHeight: 400)
                }
            }.padding(.vertical)
        }
        .navigationTitle("Home")
        .navigationDestination(for: Series.self) { SeriesDetailView(series: $0) }
        .refreshable { await refreshFromServer() }
        .task(id: pinnedSeriesTaskID) { await loadPinnedSeries() }
        .task(id: homeLoadTaskID) { await loadRecentlyUpdated() }
        .task(id: continueReadingTaskID) { await loadContinueReading() }
    }

    private func sectionHeader(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol).displayHeader().padding(.horizontal)
    }

    private var continueReadingTaskID: String {
        let profile = appState.activeProfile?.id.description ?? "none"
        let connection = appState.activeClient == nil ? "pending" : "ready"
        let seriesIDs = history.prefix(30).map(\.seriesID).joined(separator: ",")
        let syncedIDs = appState.continueReadingActivities.map { "\($0.id):\($0.readAt.timeIntervalSince1970)" }.joined(separator: ",")
        return "\(profile):\(connection):\(seriesIDs):\(syncedIDs)"
    }

    private var pinnedSeriesTaskID: String {
        let profile = appState.activeProfile?.id.description ?? "none"
        let connection = appState.activeClient == nil ? "pending" : "ready"
        let pins = appState.pinnedSeriesKeys.map(\.id).joined(separator: ",")
        return "\(profile):\(connection):\(pins)"
    }

    private var homeLoadTaskID: String {
        let profile = appState.activeProfile
        let defaultLibrary = profile.flatMap { appState.defaultLibraryID(for: $0.id) } ?? "all"
        return "\(profile?.id.description ?? "none"):\(appState.activeClient == nil ? "pending" : "ready"):\(defaultLibrary)"
    }

    private func loadRecentlyUpdated() async {
        let libraryID = appState.activeProfile.flatMap { appState.defaultLibraryID(for: $0.id) }
        let cached = cachedSeries(libraryID: libraryID).sorted {
            ($0.lastModified ?? .distantPast) > ($1.lastModified ?? .distantPast)
        }.prefix(24).map { $0 }
        recentlyUpdated = cached
        isLoadingUpdates = cached.isEmpty
        updateError = nil
        guard let client = appState.activeClient else { return }
        do {
            let values = try await client.updatedSeries(pageSize: 24, libraryID: libraryID).content
            recentlyUpdated = values
            cache(values)
        } catch is CancellationError {
            return
        } catch {
            if recentlyUpdated.isEmpty { updateError = error.localizedDescription }
        }
        isLoadingUpdates = false
    }

    private func refreshFromServer() async {
        await appState.refreshPosterArtwork()
        await loadPinnedSeries()
        await loadRecentlyUpdated()
        await loadContinueReading()
    }

    private func loadPinnedSeries() async {
        appState.refreshPinnedSeries()
        guard let activeServer = appState.activeProfile?.id else {
            pinnedSeries = []
            return
        }
        let keys = appState.pinnedSeriesKeys.filter { $0.serverID == activeServer }
        guard !keys.isEmpty else {
            pinnedSeries = []
            return
        }

        var resolved = Dictionary(
            cachedSeries(libraryID: nil).map { ($0.key, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        pinnedSeries = keys.compactMap { resolved[$0] }
        guard let client = appState.activeClient else { return }
        let fetched = await withTaskGroup(of: (Int, Series?).self, returning: [(Int, Series)].self) { group in
            for (index, key) in keys.enumerated() {
                group.addTask {
                    guard !Task.isCancelled else { return (index, nil) }
                    return (index, try? await client.series(id: key.remoteID))
                }
            }
            var values: [(Int, Series)] = []
            for await (index, series) in group {
                if let series { values.append((index, series)) }
            }
            return values.sorted { $0.0 < $1.0 }
        }
        guard !Task.isCancelled else { return }
        for (_, series) in fetched { resolved[series.key] = series }
        pinnedSeries = keys.compactMap { resolved[$0] }
        cache(fetched.map(\.1))
    }

    private func loadContinueReading() async {
        guard let activeServer = appState.activeProfile?.id.description else {
            continueReading = []
            return
        }
        appState.refreshContinueReadingActivities()
        let localActivities = history
            .filter { $0.serverID == activeServer }
            .map {
                HomeSeriesActivity(
                    serverID: $0.serverID,
                    seriesID: $0.seriesID,
                    seriesTitle: $0.seriesTitle,
                    readAt: $0.readAt
                )
            }
        let ids = HomeSyncPolicy.mergeActivities(
            appState.continueReadingActivities.filter { $0.serverID == activeServer },
            localActivities,
            limit: 12
        ).map(\.seriesID)

        let cachedByRemoteID = Dictionary(
            cachedSeries(libraryID: nil).map { ($0.key.remoteID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        continueReading = ids
            .compactMap { cachedByRemoteID[$0] }
            .filter { $0.booksInProgressCount > 0 }

        guard let client = appState.activeClient else { return }
        let fetched = await withTaskGroup(of: (Int, Series?).self, returning: [Series].self) { group in
            for (index, id) in ids.enumerated() {
                group.addTask {
                    guard !Task.isCancelled else { return (index, nil) }
                    return (index, try? await client.series(id: id))
                }
            }
            var values: [(Int, Series)] = []
            for await (index, series) in group {
                if let series { values.append((index, series)) }
            }
            return values.sorted { $0.0 < $1.0 }.map(\.1)
        }
        guard !Task.isCancelled else { return }
        appState.reconcileFinishedResumeActivities(with: fetched)
        let inProgress = fetched.filter { $0.booksInProgressCount > 0 }
        if !inProgress.isEmpty || continueReading.isEmpty { continueReading = inProgress }
        cache(fetched)
    }

    private func cache(_ seriesValues: [Series]) {
        appState.cacheSeriesForSystemIntegration(seriesValues)
    }

    private func cachedSeries(libraryID: String?) -> [Series] {
        guard let serverID = appState.activeProfile?.id.description else { return [] }
        let descriptor = FetchDescriptor<CachedSeriesRecord>(predicate: #Predicate { $0.serverID == serverID })
        return ((try? appState.modelContainer.mainContext.fetch(descriptor)) ?? [])
            .filter { libraryID == nil || $0.libraryID == libraryID }
            .compactMap { try? JSONDecoder().decode(Series.self, from: $0.payload) }
    }
}

private struct HomeSeriesRail: View {
    let title: String
    let symbol: String
    let series: [Series]
    let onUnpin: ((Series) -> Void)?

    init(title: String, symbol: String, series: [Series], onUnpin: ((Series) -> Void)? = nil) {
        self.title = title
        self.symbol = symbol
        self.series = series
        self.onUnpin = onUnpin
    }

    var body: some View {
        Label(title, systemImage: symbol).displayHeader().padding(.horizontal)
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 14) {
                ForEach(series) { item in
                    NavigationLink(value: item) {
                        SeriesCard(series: item).frame(width: 142)
                    }
                    .buttonStyle(PressableCardButtonStyle())
                    .contextMenu {
                        if let onUnpin {
                            Button("Unpin", systemImage: "pin.slash") { onUnpin(item) }
                        }
                    }
                }
            }
            .padding(.horizontal)
        }
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("home.\(title.lowercased().replacingOccurrences(of: " ", with: "-"))")
    }
}
