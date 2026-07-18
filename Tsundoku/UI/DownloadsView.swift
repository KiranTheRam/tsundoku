import SwiftData
import SwiftUI

struct DownloadsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \DownloadRecord.updatedAt, order: .reverse) private var records: [DownloadRecord]
    @State private var errorMessage: String?
    @State private var readerSelection: DownloadedReaderSelection?

    var body: some View {
        List {
            if records.isEmpty {
                ContentUnavailableView("No downloads", systemImage: "arrow.down.circle", description: Text("Download books from a series to read without a connection."))
            } else {
                Section {
                    ForEach(records) { record in
                        Group {
                            if record.state == .complete {
                                Button { open(record) } label: {
                                    DownloadRow(record: record, showsDisclosure: true)
                                }
                                .buttonStyle(.plain)
                                .accessibilityHint("Opens the downloaded book")
                            } else {
                                DownloadRow(record: record, showsDisclosure: false)
                            }
                        }
                            .contextMenu {
                                if record.state == .paused {
                                    Button("Resume", systemImage: "play") { appState.downloads.resume(record) }
                                } else if record.state == .downloading || record.state == .queued {
                                    Button("Pause", systemImage: "pause") { appState.downloads.pause(record) }
                                }
                                Button("Remove", systemImage: "trash", role: .destructive) { remove(record) }
                            }
                            .swipeActions {
                                Button("Delete", systemImage: "trash", role: .destructive) { remove(record) }
                            }
                    }
                } header: {
                    Text("\(storageText) stored on this device")
                }
            }
        }
        .navigationTitle("Downloads")
        .toolbar {
            if !records.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Remove completed", systemImage: "trash") {
                            for record in records where record.state == .complete { remove(record) }
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
        }
        .alert("Download error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
        .task { appState.downloads.reconnect() }
        .fullScreenCover(item: $readerSelection) { selection in
            if selection.book.contentKind == .epub {
                EPUBReaderScreen(book: selection.book, seriesTitle: selection.seriesTitle)
            } else {
                ReaderScreen(
                    book: selection.book,
                    seriesTitle: selection.seriesTitle,
                    seriesReadingDirection: selection.seriesReadingDirection,
                    seriesTags: selection.seriesTags,
                    opensDownloadedPackage: true
                )
            }
        }
    }

    private var storageText: String {
        ByteCountFormatter.string(fromByteCount: records.reduce(0) { $0 + $1.sizeBytes }, countStyle: .file)
    }

    private func remove(_ record: DownloadRecord) {
        do { try appState.downloads.remove(record) }
        catch { errorMessage = error.localizedDescription }
    }

    private func open(_ record: DownloadRecord) {
        let book: Book?
        if let stored = record.book {
            book = stored
        } else {
            let id = record.id
            let descriptor = FetchDescriptor<CachedBookRecord>(predicate: #Predicate { $0.id == id })
            book = (try? modelContext.fetch(descriptor).first)
                .flatMap { try? JSONDecoder().decode(Book.self, from: $0.payload) }
            if let book {
                record.bookPayload = (try? JSONEncoder().encode(book)) ?? Data()
                try? modelContext.save()
            }
        }
        guard let book else {
            errorMessage = "This older download is missing its book metadata. Remove it and download it again while connected."
            return
        }
        readerSelection = DownloadedReaderSelection(
            book: book,
            seriesTitle: record.seriesTitle,
            seriesReadingDirection: record.seriesReadingDirection,
            seriesTags: record.seriesTags
        )
    }
}

private struct DownloadRow: View {
    let record: DownloadRecord
    let showsDisclosure: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 5) {
                Text(record.seriesTitle).font(.headline)
                Text(record.bookTitle).font(.subheadline).foregroundStyle(.secondary)
                ProgressView(value: Double(record.completedPages), total: Double(max(1, record.pageCount)))
                HStack {
                    Text(record.state.rawValue.capitalized)
                    Spacer()
                    Text("\(record.completedPages)/\(record.pageCount)")
                }.font(.caption).foregroundStyle(.secondary)
                if let error = record.lastError { Text(error).font(.caption).foregroundStyle(.red).lineLimit(2) }
            }
            if showsDisclosure {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 3)
    }

    private var symbol: String {
        switch record.state {
        case .complete: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .paused: "pause.circle.fill"
        case .queued: "clock.fill"
        case .downloading: "arrow.down.circle.fill"
        }
    }
    private var color: Color { record.state == .failed ? .red : record.state == .complete ? .green : .blue }
}

private struct DownloadedReaderSelection: Identifiable {
    let book: Book
    let seriesTitle: String
    let seriesReadingDirection: String
    let seriesTags: [String]

    var id: String { book.id }
}
