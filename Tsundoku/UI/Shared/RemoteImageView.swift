import SwiftUI

struct RemotePosterView: View {
    @Environment(AppState.self) private var appState
    let series: Series
    var contentMode: ContentMode = .fill
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
            } else {
                Image(systemName: "book.closed").font(.largeTitle).foregroundStyle(.secondary)
            }
        }
        .clipped()
        .task(id: "\(series.id):\(appState.activeClient == nil ? "pending" : "ready"):\(appState.posterCacheRevision)") {
            image = nil
            guard let client = appState.activeClient else { return }
            guard let data = try? await appState.posters.data(for: series, client: client) else { return }
            let decoded = await Task.detached(priority: .userInitiated) {
                ImageProcessor.thumbnail(from: data, maxPixelSize: 640)
            }.value
            guard !Task.isCancelled else { return }
            image = decoded
        }
        .accessibilityLabel("Cover for \(series.title)")
    }
}
