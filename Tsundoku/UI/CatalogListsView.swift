import SwiftUI

struct CollectionsCatalogView: View {
    @Environment(AppState.self) private var appState
    let libraryID: String?
    @State private var values: [CatalogCollection] = []
    @State private var errorMessage: String?
    @State private var hasLoaded = false

    var body: some View {
        LazyVStack(spacing: 0) {
            if values.isEmpty && errorMessage == nil && !hasLoaded {
                CatalogRowSkeleton()
            } else if let errorMessage, values.isEmpty {
                LoadFailureView(title: "Couldn't load collections", message: errorMessage) {
                    Task { await load() }
                }
                .frame(minHeight: 300)
            } else if values.isEmpty {
                ContentUnavailableView("No collections", systemImage: "rectangle.stack", description: Text("This server has no collections."))
                    .frame(minHeight: 300)
            }
            ForEach(values) { collection in
                NavigationLink(value: collection) {
                    HStack(spacing: 14) {
                        Image(systemName: collection.ordered ? "rectangle.stack.badge.play" : "rectangle.stack")
                            .font(.title2).frame(width: 42, height: 56).background(.quaternary, in: .rect(cornerRadius: 9))
                        VStack(alignment: .leading) {
                            Text(collection.name).font(.headline)
                            Text("\(collection.itemCount) series").foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    .padding()
                }
                .buttonStyle(.plain)
                Divider().padding(.leading, 70)
            }
        }
        .navigationDestination(for: CatalogCollection.self) { CollectionDetailView(collection: $0) }
        .task(id: libraryID) { await load() }
    }

    private func load() async {
        guard let client = appState.activeClient else { return }
        do {
            values = try await client.collections(libraryID: libraryID).content
            errorMessage = nil
            hasLoaded = true
        } catch is CancellationError {
            return
        } catch { errorMessage = error.localizedDescription }
    }
}

private struct CollectionDetailView: View {
    @Environment(AppState.self) private var appState
    let collection: CatalogCollection
    @State private var series: [Series] = []
    @State private var errorMessage: String?
    @State private var hasLoaded = false

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            if series.isEmpty && errorMessage == nil && !hasLoaded {
                SeriesGridSkeleton().padding()
            } else if let errorMessage, series.isEmpty {
                LoadFailureView(title: "Couldn't load the collection", message: errorMessage) {
                    Task { await load() }
                }
                .frame(minHeight: 300)
            } else {
                SeriesGrid(series: series, onLoadMore: nil).padding()
            }
        }
        .navigationTitle(collection.name)
        .task { await load() }
    }

    private func load() async {
        guard let client = appState.activeClient else { return }
        do {
            series = try await client.collectionSeries(collectionID: collection.id).content
            errorMessage = nil
            hasLoaded = true
        } catch is CancellationError {
            return
        } catch { errorMessage = error.localizedDescription }
    }
}

struct ReadListsCatalogView: View {
    @Environment(AppState.self) private var appState
    let libraryID: String?
    @State private var values: [CatalogReadingList] = []
    @State private var errorMessage: String?
    @State private var hasLoaded = false

    var body: some View {
        LazyVStack(spacing: 0) {
            if values.isEmpty && errorMessage == nil && !hasLoaded {
                CatalogRowSkeleton()
            } else if let errorMessage, values.isEmpty {
                LoadFailureView(title: "Couldn't load readlists", message: errorMessage) {
                    Task { await load() }
                }
                .frame(minHeight: 300)
            } else if values.isEmpty {
                ContentUnavailableView("No readlists", systemImage: "list.bullet.rectangle", description: Text("This server has no reading lists."))
                    .frame(minHeight: 300)
            }
            ForEach(values) { readList in
                NavigationLink(value: readList) {
                    HStack(spacing: 14) {
                        Image(systemName: "list.bullet.rectangle").font(.title2).frame(width: 42, height: 56).background(.quaternary, in: .rect(cornerRadius: 9))
                        VStack(alignment: .leading) {
                            Text(readList.name).font(.headline)
                            if !readList.summary.isEmpty { Text(readList.summary).lineLimit(2).foregroundStyle(.secondary) }
                            Text("\(readList.itemCount) books").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    .padding()
                }
                .buttonStyle(.plain)
                Divider().padding(.leading, 70)
            }
        }
        .navigationDestination(for: CatalogReadingList.self) { ReadListDetailView(readList: $0) }
        .task(id: libraryID) { await load() }
    }

    private func load() async {
        guard let client = appState.activeClient else { return }
        do {
            values = try await client.readLists(libraryID: libraryID).content
            errorMessage = nil
            hasLoaded = true
        } catch is CancellationError {
            return
        } catch { errorMessage = error.localizedDescription }
    }
}

private struct ReadListDetailView: View {
    @Environment(AppState.self) private var appState
    let readList: CatalogReadingList
    @State private var books: [Book] = []
    @State private var selection: Book?
    @State private var errorMessage: String?

    var body: some View {
        List {
            if let errorMessage, books.isEmpty {
                LoadFailureView(title: "Couldn't load the readlist", message: errorMessage) {
                    Task { await reloadBooks() }
                }
                .listRowSeparator(.hidden)
            }
            ForEach(books) { book in
                Button { selection = book } label: {
                    HStack {
                        Image(systemName: book.completed ? "checkmark.circle.fill" : "book.closed")
                        VStack(alignment: .leading) {
                            Text(book.displayTitle)
                            Text("\(book.pageCount) pages").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .foregroundStyle(.primary)
            }
        }
        .navigationTitle(readList.name)
        .task { await reloadBooks() }
        .fullScreenCover(item: $selection, onDismiss: {
            Task { await reloadBooks() }
        }) { book in
            if book.contentKind == .epub {
                EPUBReaderScreen(book: book, seriesTitle: readList.name)
            } else {
                ReaderScreen(
                    book: book,
                    seriesTitle: readList.name,
                    seriesReadingDirection: book.remoteContext.readingDirection ?? "RIGHT_TO_LEFT",
                    seriesTags: []
                )
            }
        }
    }

    private func reloadBooks() async {
        guard let client = appState.activeClient else { return }
        do {
            books = try await client.readListBooks(readListID: readList.id).content
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch { errorMessage = error.localizedDescription }
    }
}
