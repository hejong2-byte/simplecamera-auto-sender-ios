import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct TextTransferView: View {
    @ObservedObject var model: TextTransferViewModel
    @State private var recipientName = ""
    @State private var recipientToRename: TextSavedRecipient?
    @State private var showingRecipientNameAlert = false
    @State private var recipientToDelete: TextSavedRecipient?
    @State private var showingRecipientDeleteAlert = false
    @State private var exportMessage: TextStoredMessage?
    @State private var isExporting = false
    @State private var shareURL: URL?
    @State private var isSharing = false
    @State private var messageToDelete: TextStoredMessage?
    @State private var showingMessageDeleteAlert = false
    @State private var actionMessage: String?

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
        .task { await model.refresh() }
        .onChange(of: model.recipient) { _, value in
            let digits = String(value.filter { $0 >= "0" && $0 <= "9" }.prefix(6))
            if digits != value {
                model.recipient = digits
            } else {
                model.recipientDidChange()
            }
        }
        .onChange(of: TextDraft(recipient: model.recipient, text: model.text)) { _, _ in
            Task { await model.saveDraft() }
        }
        .fileExporter(
            isPresented: $isExporting,
            document: TextExportDocument(text: exportMessage?.envelope.text ?? ""),
            contentType: .plainText,
            defaultFilename: exportMessage.map { TextMessageExport.baseName(for: $0) }
                ?? "SimpleCamera-text"
        ) { result in
            switch result {
            case .success:
                actionMessage = "TXT 저장 완료"
            case let .failure(error):
                actionMessage = "TXT 저장 실패 · \(error.localizedDescription)"
            }
        }
        .sheet(isPresented: $isSharing, onDismiss: removeShareFile) {
            if let shareURL {
                TextMessageShareSheet(url: shareURL)
            }
        }
        .alert("수신코드 이름", isPresented: $showingRecipientNameAlert) {
            TextField("예: 행정망 PC, 아이폰", text: $recipientName)
            Button("취소", role: .cancel) {}
            Button(recipientToRename == nil ? "저장" : "변경") {
                let name = recipientName
                if let saved = recipientToRename {
                    Task { await model.renameRecipient(code: saved.code, name: name) }
                } else {
                    Task { await model.saveRecipient(name: name) }
                }
            }
            .disabled(recipientName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("목록에 표시할 이름을 입력하세요.")
        }
        .alert(
            "저장된 수신코드를 삭제할까요?",
            isPresented: $showingRecipientDeleteAlert,
            presenting: recipientToDelete
        ) { saved in
            Button("취소", role: .cancel) {}
            Button("삭제", role: .destructive) {
                Task { await model.deleteRecipient(code: saved.code) }
            }
        } message: { saved in
            Text("\(saved.displayLabel) 바로가기만 삭제하며 텍스트 기록은 유지합니다.")
        }
        .alert(
            "이 텍스트를 삭제할까요?",
            isPresented: $showingMessageDeleteAlert,
            presenting: messageToDelete
        ) { message in
            Button("취소", role: .cancel) {}
            Button("삭제", role: .destructive) {
                Task { await delete(message) }
            }
        } message: { _ in
            Text("iPhone에 저장된 이 기록만 삭제하며 되돌릴 수 없습니다.")
        }
        .onDisappear(perform: removeShareFile)
    }

    private var composeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("내 수신 코드")
                Spacer()
                Text(model.ownCode ?? "설정 필요")
                    .font(.title3.monospacedDigit().bold())
            }

            HStack(spacing: 8) {
                TextField("받는 코드 6자리", text: $model.recipient)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("text-recipient")

                Button("저장") {
                    beginSavingRecipient()
                }
                .buttonStyle(.bordered)
                .disabled(model.recipient.count != 6)
                .accessibilityIdentifier("text-save-recipient")
            }

            HStack {
                Text("저장된 수신코드")
                    .font(.subheadline.bold())
                Spacer()
                Text("\(model.savedRecipients.count)/5")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if model.savedRecipients.isEmpty {
                Text("자주 쓰는 코드를 이름과 함께 저장할 수 있습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.savedRecipients) { saved in
                    savedRecipientRow(saved)
                    if saved.id != model.savedRecipients.last?.id { Divider() }
                }
            }

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
                if let actionMessage {
                    Text(actionMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(model.messages) { message in
                    NavigationLink {
                        TextMessageDetailView(model: model, key: message.key)
                    } label: {
                        messageRow(message)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(messageIdentifier(message))
                    .contextMenu {
                        Button {
                            copy(message)
                        } label: {
                            Label("전체 복사", systemImage: "doc.on.doc")
                        }
                        Button {
                            exportMessage = message
                            isExporting = true
                        } label: {
                            Label("TXT로 저장", systemImage: "doc.badge.arrow.up")
                        }
                        Button {
                            beginSharing(message)
                        } label: {
                            Label("공유", systemImage: "square.and.arrow.up")
                        }
                        Button(role: .destructive) {
                            messageToDelete = message
                            showingMessageDeleteAlert = true
                        } label: {
                            Label("삭제", systemImage: "trash")
                        }
                    }
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

    private func savedRecipientRow(_ saved: TextSavedRecipient) -> some View {
        Button {
            Task { await model.selectRecipient(code: saved.code) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: model.selectedRecipientCode == saved.code
                    ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(model.selectedRecipientCode == saved.code ? .cyan : .secondary)
                Text(saved.name)
                    .font(.subheadline.bold())
                    .foregroundStyle(.primary)
                Spacer()
                Text(saved.code)
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(saved.displayLabel)
        .accessibilityIdentifier("text-saved-recipient-\(saved.code)")
        .contextMenu {
            Button("이름 변경", systemImage: "pencil") {
                recipientToRename = saved
                recipientName = saved.name
                showingRecipientNameAlert = true
            }
            Button("삭제", systemImage: "trash", role: .destructive) {
                recipientToDelete = saved
                showingRecipientDeleteAlert = true
            }
        }
    }

    private func beginSavingRecipient() {
        recipientToRename = nil
        recipientName = model.savedRecipients.first {
            $0.code == model.recipient
        }?.name ?? ""
        showingRecipientNameAlert = true
    }

    private func copy(_ message: TextStoredMessage) {
        UIPasteboard.general.string = message.envelope.text
        actionMessage = "전체 복사 완료"
    }

    private func beginSharing(_ message: TextStoredMessage) {
        removeShareFile()
        do {
            shareURL = try TextMessageExport.makeTemporaryFile(for: message)
            isSharing = true
        } catch {
            actionMessage = "공유 준비 실패 · \(error.localizedDescription)"
        }
    }

    private func removeShareFile() {
        if let shareURL { try? FileManager.default.removeItem(at: shareURL) }
        shareURL = nil
    }

    private func delete(_ message: TextStoredMessage) async {
        do {
            try await model.delete(message.key)
            actionMessage = "텍스트 삭제 완료"
        } catch {
            actionMessage = "삭제하지 못했습니다."
        }
    }
}

private struct TextMessageShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(
        _ uiViewController: UIActivityViewController,
        context: Context
    ) {}
}
