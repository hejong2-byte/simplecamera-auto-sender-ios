import SwiftUI

struct PCReceiveStatusView: View {
    let status: IPhoneReceiveStatus
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: iconName)
                    .foregroundStyle(tint)
                Text(status.title)
                    .font(.headline)
                    .foregroundStyle(status.kind == .failed ? tint : .primary)
                Spacer(minLength: 8)
                if let percent = status.percent {
                    Text("\(percent)%")
                        .font(.subheadline.monospacedDigit().bold())
                        .foregroundStyle(tint)
                }
            }

            if status.kind == .active, let percent = status.percent {
                ProgressView(value: Double(percent), total: 100)
                    .tint(tint)
            } else if status.kind == .active {
                ProgressView().tint(tint)
            }

            if let fileName = status.fileName {
                Label(fileName, systemImage: "doc.fill")
                    .font(.subheadline)
                    .lineLimit(compact ? 1 : 2)
            }

            Text(status.message)
                .font(compact ? .caption : .subheadline)
                .foregroundStyle(status.kind == .failed ? tint : .secondary)
                .lineLimit(compact ? 2 : nil)

            if let occurredAt = status.occurredAt {
                Text(occurredAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(compact ? 10 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(resultIdentifier)
        .padding(1)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pc-receive-status")
    }

    private var iconName: String {
        switch status.kind {
        case .waiting: return "clock.fill"
        case .active: return "arrow.down.circle.fill"
        case .saved: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch status.kind {
        case .waiting: return .secondary
        case .active: return .cyan
        case .saved: return .green
        case .failed: return .red
        }
    }

    private var resultIdentifier: String {
        switch status.kind {
        case .saved: return "pc-receive-success"
        case .failed: return "pc-receive-error"
        case .waiting, .active: return "pc-receive-live"
        }
    }
}
