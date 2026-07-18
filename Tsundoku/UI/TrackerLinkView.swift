import SwiftData
import SwiftUI

struct TrackerLinkView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let series: Series
    @State private var service: TrackerService = .aniList
    @State private var query: String
    @State private var results: [TrackerMedia] = []
    @State private var selected: TrackerMedia?
    @State private var ruleKind = 0
    @State private var offset = 0
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var savedMessage: String?

    init(series: Series) {
        self.series = series
        _query = State(initialValue: series.title)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Linked trackers") {
                    ForEach(TrackerService.allCases) { tracker in
                        LabeledContent(tracker.title, value: appState.trackers.linkedMediaTitle(for: series, service: tracker) ?? "Not linked")
                    }
                    Text("Signing in connects the account. Link this series to its matching entry on each tracker once; the links then sync to your other devices.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Picker("Service", selection: $service) {
                    ForEach(TrackerService.allCases) { Text($0.title).tag($0) }
                }
                Section("Find entry") {
                    TextField("Title", text: $query)
                    Button("Search", systemImage: "magnifyingglass") { search() }
                        .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || isSearching)
                    if isSearching { ProgressView() }
                    ForEach(results) { media in
                        Button { selected = media } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(media.title).foregroundStyle(.primary)
                                    if let alternate = media.alternateTitle { Text(alternate).font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer()
                                if let total = media.total { Text("\(total)").foregroundStyle(.secondary) }
                                if selected?.id == media.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
                            }
                        }
                    }
                }
                if let selected {
                    Section("Progress rule") {
                        Picker("Formula", selection: $ruleKind) {
                            Text("Highest book number").tag(0)
                            Text("Completed book count").tag(1)
                        }
                        Stepper("Offset: \(offset)", value: $offset, in: -100...100)
                        LabeledContent("Preview", value: "\(previewProgress)")
                        Text("\(selected.title) will receive chapter progress \(previewProgress). You can revise this mapping later.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if let savedMessage {
                    Section {
                        Label(savedMessage, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
            }
            .navigationTitle("Link Tracker")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(selected == nil)
                }
            }
            .onChange(of: service) {
                selected = nil
                results = []
                savedMessage = nil
            }
            .alert("Tracker link error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
        }
        .presentationDetents([.large])
    }

    private var rule: TrackerProgressRule {
        ruleKind == 0 ? .bookNumber(offset: offset) : .completedBookCount(offset: offset)
    }

    private var previewProgress: Int {
        let records = (try? appState.modelContainer.mainContext.fetch(FetchDescriptor<CachedBookRecord>())) ?? []
        let books = records.compactMap { try? JSONDecoder().decode(Book.self, from: $0.payload) }
            .filter { $0.seriesKey == series.key }
            .map { TrackerBookProgress(bookID: $0.key.remoteID, numberSort: $0.numberSort, completed: $0.completed) }
        return rule.progress(completedBooks: books)
    }

    private func search() {
        guard appState.trackers.connected.contains(service) else {
            errorMessage = "Connect \(service.title) in Settings first."
            return
        }
        isSearching = true
        Task {
            do { results = try await appState.trackers.search(service, title: query) }
            catch { errorMessage = error.localizedDescription }
            isSearching = false
        }
    }

    private func save() {
        guard let selected else { return }
        do {
            try appState.trackers.link(series: series, service: service, media: selected, rule: rule)
            savedMessage = "\(service.title) linked to \(selected.title). Existing completed volumes are syncing now."
            self.selected = nil
        } catch { errorMessage = error.localizedDescription }
    }
}
