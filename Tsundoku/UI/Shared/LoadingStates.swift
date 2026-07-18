import SwiftUI

/// A redacted stand-in matching SeriesCard's layout so grids keep their shape
/// while the first load is in flight.
struct SeriesCardPlaceholder: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { proxy in
                Rectangle()
                    .fill(.quaternary)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipShape(.rect(cornerRadius: DesignTokens.cardCornerRadius))
            }
            .aspectRatio(SeriesCardMetrics.coverAspectRatio, contentMode: .fit)
            Text("Series title")
                .font(.headline)
                .lineLimit(2, reservesSpace: true)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .redacted(reason: .placeholder)
        .skeletonPulse()
        .accessibilityHidden(true)
    }
}

/// Grid of card placeholders using SeriesGrid's column layout.
struct SeriesGridSkeleton: View {
    var count: Int = 8

    var body: some View {
        LazyVGrid(columns: SeriesGridMetrics.columns, alignment: .leading, spacing: 22) {
            ForEach(0..<count, id: \.self) { _ in
                SeriesCardPlaceholder()
            }
        }
        .accessibilityLabel("Loading")
    }
}

/// Horizontal rail of card placeholders matching Home's card rails.
struct SeriesRailSkeleton: View {
    var count: Int = 4

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 14) {
                ForEach(0..<count, id: \.self) { _ in
                    SeriesCardPlaceholder().frame(width: 142)
                }
            }
            .padding(.horizontal)
        }
        .scrollIndicators(.hidden)
        .disabled(true)
        .accessibilityLabel("Loading")
    }
}

/// Redacted stand-in for the collections/readlists catalog rows.
struct CatalogRowSkeleton: View {
    var count: Int = 5

    var body: some View {
        ForEach(0..<count, id: \.self) { _ in
            HStack(spacing: 14) {
                Rectangle()
                    .fill(.quaternary)
                    .frame(width: 42, height: 56)
                    .clipShape(.rect(cornerRadius: 9))
                VStack(alignment: .leading) {
                    Text("Catalog item").font(.headline)
                    Text("0 items").foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding()
            .redacted(reason: .placeholder)
            .skeletonPulse()
            Divider().padding(.leading, 70)
        }
        .accessibilityHidden(true)
    }
}

/// Inline load-failure state with a Retry action; replaces modal alerts on
/// catalog load paths. Action failures (downloads, mark read) keep their
/// alerts/toasts.
struct LoadFailureView: View {
    let title: String
    let message: String
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "wifi.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            Button("Retry", action: retry)
                .buttonStyle(.borderedProminent)
        }
        .accessibilityIdentifier("load.failure")
    }
}
