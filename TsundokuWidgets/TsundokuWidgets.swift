import ActivityKit
import SwiftUI
import UIKit
import WidgetKit

struct TsundokuWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: TsundokuSystemSnapshot
}

struct TsundokuWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> TsundokuWidgetEntry {
        TsundokuWidgetEntry(date: .now, snapshot: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (TsundokuWidgetEntry) -> Void) {
        completion(TsundokuWidgetEntry(
            date: .now,
            snapshot: context.isPreview ? .preview : TsundokuSharedStore.loadSnapshot()
        ))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TsundokuWidgetEntry>) -> Void) {
        let entry = TsundokuWidgetEntry(date: .now, snapshot: TsundokuSharedStore.loadSnapshot())
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(30 * 60))))
    }
}

struct ContinueReadingWidget: Widget {
    let kind = "com.example.Tsundoku.continue-reading"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TsundokuWidgetProvider()) { entry in
            ContinueReadingWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Continue Reading")
        .description("Resume your most recently read books at the exact saved position.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

private struct ContinueReadingWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TsundokuWidgetEntry

    var body: some View {
        if let first = entry.snapshot.recentItems.first {
            switch family {
            case .systemSmall:
                SmallResumeView(item: first)
                    .widgetURL(first.resumeURL)
            case .systemLarge:
                ResumeListView(items: Array(entry.snapshot.recentItems.prefix(5)))
            default:
                ResumeListView(items: Array(entry.snapshot.recentItems.prefix(2)))
            }
        } else {
            ContentUnavailableView {
                Label("Nothing to resume", systemImage: "book.closed")
            } description: {
                Text("Start reading in Tsundoku")
            }
        }
    }
}

private struct SmallResumeView: View {
    let item: SystemResumeItem

    var body: some View {
        HStack(spacing: 10) {
            WidgetCover(item: item)
                .frame(width: 62)
                .frame(maxHeight: .infinity)
                .clipShape(.rect(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 5) {
                Text(item.seriesTitle)
                    .font(.caption.weight(.semibold))
                    .lineLimit(3)
                    .truncationMode(.tail)
                Text(progressLabel(item))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                ProgressView(value: item.progress)
                    .tint(.accentColor)
                Spacer(minLength: 0)
                Image(systemName: "play.fill")
                    .font(.body.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.accentColor, in: Circle())
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Resume \(item.seriesTitle), \(progressLabel(item))")
    }
}

private struct ResumeListView: View {
    let items: [SystemResumeItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Continue Reading", systemImage: "book.fill")
                .font(.headline)
            ForEach(items) { item in
                Link(destination: item.resumeURL) {
                    HStack(spacing: 8) {
                        WidgetCover(item: item)
                            .frame(width: 32, height: 48)
                            .clipShape(.rect(cornerRadius: 6))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.seriesTitle)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Text("\(item.bookTitle) · \(progressLabel(item))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            ProgressView(value: item.progress)
                                .tint(.accentColor)
                        }
                        Spacer(minLength: 4)
                        Image(systemName: "play.fill")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(Color.accentColor, in: Circle())
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
    }
}

private struct WidgetCover: View {
    let item: SystemResumeItem

    var body: some View {
        if let data = try? Data(contentsOf: item.coverURL), let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                Color.accentColor.opacity(0.16)
                Image(systemName: "book.closed.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
            }
        }
    }
}

struct ReadingStatisticsWidget: Widget {
    let kind = "com.example.Tsundoku.reading-statistics"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TsundokuWidgetProvider()) { entry in
            ReadingStatisticsWidgetView(statistics: entry.snapshot.statistics)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Reading Statistics")
        .description("See pages read today and this week across your devices.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct DownloadLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadLiveActivityAttributes.self) { context in
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text(context.attributes.seriesTitle)
                        .font(.headline)
                        .lineLimit(1)
                    Text(context.attributes.bookTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    ProgressView(value: context.state.progress)
                        .tint(Color.accentColor)
                }
                Text(progressPercent(context.state))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding()
            .activityBackgroundTint(.black.opacity(0.92))
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(.tint)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(progressPercent(context.state))
                        .font(.caption.monospacedDigit())
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text(context.attributes.seriesTitle)
                            .font(.headline)
                            .lineLimit(1)
                        Text(context.attributes.bookTitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 8) {
                        ProgressView(value: context.state.progress)
                            .tint(Color.accentColor)
                        Text(context.state.status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                Image(systemName: "arrow.down")
                    .foregroundStyle(.tint)
            } compactTrailing: {
                Text(progressPercent(context.state))
                    .font(.caption2.monospacedDigit())
            } minimal: {
                Image(systemName: "arrow.down")
                    .foregroundStyle(.tint)
            }
        }
    }

    private func progressPercent(_ state: DownloadLiveActivityAttributes.ContentState) -> String {
        state.status == "Paused" ? "Paused" : "\(Int((state.progress * 100).rounded()))%"
    }
}

private struct ReadingStatisticsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let statistics: ReadingStatistics

    var body: some View {
        VStack(alignment: .leading, spacing: family == .systemSmall ? 6 : 10) {
            HStack(alignment: .top, spacing: 8) {
                Label(family == .systemSmall ? "This Week" : "Reading This Week", systemImage: "chart.bar.fill")
                    .font(family == .systemSmall ? .caption.weight(.semibold) : .headline)
                    .lineLimit(1)
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 0) {
                    Text(statistics.pagesThisWeek.formatted())
                        .font(.system(family == .systemSmall ? .headline : .title2, design: .rounded, weight: .bold))
                        .foregroundStyle(.tint)
                    Text("pages")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(statistics.pagesThisWeek) pages this week")
            }
            WeeklyBarGraph(days: displayedWeek, compact: family == .systemSmall)
        }
        .padding(family == .systemSmall ? 10 : 14)
    }

    private var displayedWeek: [DailyReadingStatistics] {
        guard statistics.currentWeek.count == 7 else {
            let calendar = Calendar.autoupdatingCurrent
            let start = calendar.dateInterval(of: .weekOfYear, for: entryDate)?.start
                ?? calendar.startOfDay(for: entryDate)
            return (0..<7).compactMap { offset in
                calendar.date(byAdding: .day, value: offset, to: start).map {
                    DailyReadingStatistics(date: $0, pages: 0)
                }
            }
        }
        return statistics.currentWeek.sorted { $0.date < $1.date }
    }

    private var entryDate: Date { .now }
}

private struct WeeklyBarGraph: View {
    let days: [DailyReadingStatistics]
    let compact: Bool

    var body: some View {
        GeometryReader { geometry in
            let maximum = max(1, days.map(\.pages).max() ?? 0)
            let availableBarHeight = max(12, geometry.size.height - (compact ? 30 : 38))
            HStack(alignment: .bottom, spacing: compact ? 3 : 8) {
                ForEach(days) { day in
                    VStack(spacing: compact ? 2 : 4) {
                        Text(day.pages.formatted())
                            .font(.system(size: compact ? 8 : 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        RoundedRectangle(cornerRadius: compact ? 3 : 5, style: .continuous)
                            .fill(Color.accentColor.gradient)
                            .frame(height: max(4, availableBarHeight * CGFloat(day.pages) / CGFloat(maximum)))
                        Text(day.date.formatted(.dateTime.weekday(compact ? .narrow : .abbreviated)))
                            .font(.system(size: compact ? 8 : 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(day.date.formatted(.dateTime.weekday(.wide)))
                    .accessibilityValue("\(day.pages) pages")
                }
            }
        }
    }
}

private func progressLabel(_ item: SystemResumeItem) -> String {
    item.pageCount > 0 ? "Page \(item.page) of \(item.pageCount)" : "Page \(item.page)"
}

private extension TsundokuSystemSnapshot {
    static let preview: Self = {
        let item = SystemResumeItem(
            serverID: "preview",
            seriesID: "series",
            bookID: "book",
            seriesTitle: "We Never Learn",
            bookTitle: "Volume 7",
            page: 37,
            pageCount: 192,
            readAt: .now
        )
        return Self(
            series: [SystemSeriesSummary(serverID: "preview", seriesID: "series", title: "We Never Learn")],
            recentItems: [item],
            statistics: ReadingStatistics(
                pagesToday: 42,
                pagesThisWeek: 186,
                currentWeek: zip(0..<7, [18, 31, 22, 42, 37, 24, 12]).compactMap { offset, pages in
                    Calendar.current.date(byAdding: .day, value: offset - 6, to: .now).map {
                        DailyReadingStatistics(date: $0, pages: pages)
                    }
                }
            ),
            generatedAt: .now
        )
    }()
}

@main
struct TsundokuWidgetBundle: WidgetBundle {
    var body: some Widget {
        ContinueReadingWidget()
        ReadingStatisticsWidget()
        DownloadLiveActivity()
    }
}
