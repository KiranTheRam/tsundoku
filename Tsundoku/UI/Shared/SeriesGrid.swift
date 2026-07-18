import SwiftUI

struct SeriesGrid: View {
    let series: [Series]
    let onLoadMore: (() -> Void)?

    var body: some View {
        LazyVGrid(columns: SeriesGridMetrics.columns, alignment: .leading, spacing: 22) {
            ForEach(series) { item in
                NavigationLink(value: item) { SeriesCard(series: item) }
                    .buttonStyle(PressableCardButtonStyle())
                    .onAppear {
                        if item.id == series.last?.id { onLoadMore?() }
                    }
            }
        }
        .navigationDestination(for: Series.self) { SeriesDetailView(series: $0) }
    }
}

enum SeriesGridMetrics {
    static let columns = [
        GridItem(.adaptive(minimum: 132, maximum: 184), spacing: 14, alignment: .top)
    ]
}

struct SeriesCard: View {
    let series: Series

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { proxy in
                RemotePosterView(series: series)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipShape(.rect(cornerRadius: DesignTokens.cardCornerRadius))
                    .contentShape(.rect(cornerRadius: DesignTokens.cardCornerRadius))
                    .cardShadow()
                    .overlay(alignment: .bottomTrailing) {
                        if series.unreadCount > 0 {
                            Text("\(series.unreadCount)")
                                .font(.caption.bold()).padding(.horizontal, 7).padding(.vertical, 4)
                                .background(.tint, in: Capsule()).foregroundStyle(.white).padding(7)
                        }
                    }
                }
            .aspectRatio(SeriesCardMetrics.coverAspectRatio, contentMode: .fit)
            Text(series.title)
                .font(.headline)
                .lineLimit(2, reservesSpace: true)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }
}

enum SeriesCardMetrics {
    /// A consistent 2:3 silhouette matches common manga volumes while allowing
    /// unusually sized source artwork to be center-cropped inside the frame.
    static let coverAspectRatio: CGFloat = 2.0 / 3.0
}
