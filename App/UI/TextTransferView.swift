import SwiftUI

struct TextTransferView: View {
    @ObservedObject var model: TextTransferViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                composeCard
                statusCard
                historyCard
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("텍스트 송수신")
        .navigationDestination(for: TextMessageKey.self) { key in
            TextMessageDetailView(model: model, key: key)
        }
        .task { await model.refresh() }
        .onChange(of: model.recipient) { _, value in
            let digits = String(value.filter { $0 >= "0" && $0 <= "9" }.prefix(6))
            if digits != value { model.recipient = digits }
        }
        .onChange(of: TextDraft(recipient: model.recipient, text: model.text)) { _, _ in
            Task { await model.saveDraft() }
        }
    }

    private var composeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("내 수신 코드")
                Spacer()
                Text(model.ownCode ?? "설정 필요")
                    .font(.title3.monospacedDigit().bold())
            }

            TextField("받는 코드 6자리", text: $model.recipient)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("text-recipient")

            ZStack(alignment: .topLeading) {
                TextEditor(text: $model.text)
                    .frame(minHeight: 140)
                    .padding(4)
                    .scrollContentBackground(.hidden)
                    .background(Color(.tertiarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .accessibilityIdentifier("text-body")
                if model.text.isEmpty {
                    Text("보낼 텍스트")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
            }

            Button {
                Task { await model.send() }
            } label: {
                if model.activity == .sending {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Label("보내기", systemImage: "paperplane.fill")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canSend)
            .accessibilityIdentifier("text-send")
        }
        .cardStyle()
    }

    private var statusCard: some View {
        HStack(spacing: 10) {
            if model.activity == .refreshing {
                ProgressView()
            } else if model.lastError != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            } else {
                Image(systemName: model.unreadCount > 0 ? "text.bubble.fill" : "checkmark.circle.fill")
                    .foregroundStyle(model.unreadCount > 0 ? .cyan : .green)
            }

            VStack(alignment: .leading, spacing: 3) {
                if let error = model.lastError {
                    Text(error).foregroundStyle(.red)
                } else {
                    Text(model.statusMessage ?? "수신 대기")
                }
                if model.unreadCount > 0 {
                    Text("읽지 않은 텍스트 \(model.unreadCount)개")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                Task { await model.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 32, height: 32)
            }
            .disabled(model.activity != .idle)
            .accessibilityLabel("새로고침")
            .accessibilityIdentifier("text-refresh")
        }
        .cardStyle()
    }

    private var historyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("기록").font(.headline)
                Spacer()
                Text("\(model.messages.count)개")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if model.messages.isEmpty {
                Text("저장된 텍스트가 없습니다.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.messages) { message in
                    NavigationLink(value: message.key) {
                        messageRow(message)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(messageIdentifier(message))
                    if message.key != model.messages.last?.key { Divider() }
                }
            }
        }
        .cardStyle()
    }

    private func messageRow(_ message: TextStoredMessage) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: message.key.direction == .received
                ? "arrow.down.message.fill" : "arrow.up.message.fill")
                .foregroundStyle(message.key.direction == .received ? .green : .cyan)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(message.key.direction == .received
                        ? "받음 · \(message.envelope.sender)"
                        : "보냄 · \(message.envelope.recipient)")
                        .font(.subheadline.bold())
                    if message.key.direction == .received && message.readAt == nil {
                        Circle().fill(.cyan).frame(width: 7, height: 7)
                    }
                }
                Text(message.envelope.text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                HStack {
                    Text(message.envelope.createdAt.formatted(date: .abbreviated, time: .shortened))
                    if message.status == .pending { Text("재전송 대기").foregroundStyle(.orange) }
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    private func messageIdentifier(_ message: TextStoredMessage) -> String {
        "text-message-\(message.key.direction.rawValue)-\(message.envelope.id.uuidString.lowercased())"
    }
}
