import SwiftUI

struct ProgressSyncToast: View {
    let notice: ProgressSyncNotice

    var body: some View {
        HStack(spacing: 10) {
            symbol
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .foregroundStyle(foregroundColor)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay { Capsule().stroke(borderColor, lineWidth: 1) }
        .shadow(
            color: .black.opacity(DesignTokens.floatingShadowOpacity),
            radius: DesignTokens.floatingShadowRadius,
            y: DesignTokens.floatingShadowYOffset
        )
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("progress.syncToast")
    }

    @ViewBuilder private var symbol: some View {
        switch notice.state {
        case .syncing:
            ProgressView().controlSize(.small)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }

    private var title: String {
        switch notice.state {
        case .syncing:
            switch notice.operation {
            case .progress: "Saving reading progress…"
            case .markRead: "Marking as read…"
            case .markUnread: "Marking as unread…"
            }
        case .succeeded:
            switch notice.operation {
            case .progress: "Progress saved to \(notice.providerName)"
            case .markRead: "Marked read in \(notice.providerName)"
            case .markUnread: "Marked unread in \(notice.providerName)"
            }
        case .failed:
            switch notice.operation {
            case .progress: "Progress couldn't be saved"
            case .markRead: "Couldn't mark as read"
            case .markUnread: "Couldn't mark as unread"
            }
        }
    }

    private var detail: String {
        let subject: String
        switch notice.operation {
        case .progress(let page): subject = "Page \(page)"
        case .markRead(let title), .markUnread(let title): subject = title
        }
        switch notice.state {
        case .syncing, .succeeded: return subject
        case .failed(let message): return "\(subject) · \(message)"
        }
    }

    private var foregroundColor: Color { if case .failed = notice.state { .red } else { .primary } }
    private var borderColor: Color { if case .failed = notice.state { .red.opacity(0.35) } else { .primary.opacity(0.1) } }
}

/// Which haptic, if any, a sync notice should fire. Only manual Mark
/// Read/Unread outcomes give feedback; automatic progress saves (including the
/// reader-exit toast) and in-flight states stay silent.
enum ManualSyncFeedback: Equatable {
    case success
    case error

    static func forNotice(operation: ProgressSyncNotice.Operation, state: ProgressSyncNotice.State) -> ManualSyncFeedback? {
        switch operation {
        case .progress:
            return nil
        case .markRead, .markUnread:
            switch state {
            case .syncing: return nil
            case .succeeded: return .success
            case .failed: return .error
            }
        }
    }
}
