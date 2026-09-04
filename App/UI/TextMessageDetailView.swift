import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct TextMessageDetailView: View {
    @ObservedObject var model: TextTransferViewModel
    let key: TextMessageKey

    @Environment(\.dismiss) private var dismiss
    @State private var isExporting = false
    @State private var confirmDelete = false
    @State private var shareURL: URL?
    @State private var actionMessage: String?

    private var message: TextStoredMessage? {
        model.messages.first { $0.key == key }
    }

    var body: some View {
        ScrollView {
            if let message {
                VStack(spacing: 12) {
                    metadataCard(message)
                    bodyCard(message)
                    actionsCard(message)
                    if let actionMessage {
                        Text(actionMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .cardStyle()
                    }
                    if let error = model.lastError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .cardStyle()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            } else {
                ContentUnavailableView(
                    "텍스트를 찾을 수 없습니다",
                    systemImage: "text.page.slash"
                )
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(key.direction == .received ? "받은 텍스트" : "보낸 텍스트")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: key) {
            guard let message else { return }
            if message.key.direction == .received && message.readAt == nil {
                try? await model.markRead(message.key)
            }
            shareURL = try? Self.makeShareFile(message)
        }
        .onDisappear {
            if let shareURL { try? FileManager.default.removeItem(at: shareURL) }
        }
        .fileExporter(
            isPresented: $isExporting,
            document: TextExportDocument(text: message?.envelope.text ?? ""),
            contentType: .plainText,
            defaultFilename: exportBaseName
        ) { result in
            switch result {
            case .success:
                actionMessage = "TXT 저장 완료"
            case let .failure(error):
                actionMessage = "TXT 저장 실패 · \(error.localizedDescription)"
            }
        }
        .alert("이 텍스트를 삭제할까요?", isPresented: $confirmDelete) {
            Button("취소", role: .cancel) {}
            Button("삭제", role: .destructive) {
                Task {
                    do {
                        try await model.delete(key)
                        dismiss()
                    } catch {
                        actionMessage = "삭제하지 못했습니다."
                    }
                }
            }
        } message: {
            Text("iPhone에 저장된 이 기록만 삭제하며 되돌릴 수 없습니다.")
        }
    }

    private func metadataCard(_ message: TextStoredMessage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                message.key.direction == .received
                    ? "보낸 코드 \(message.envelope.sender)"
                    : "받는 코드 \(message.envelope.recipient)",
                systemImage: message.key.direction == .received
                    ? "arrow.down.message.fill" : "arrow.up.message.fill"
            )
            .font(.headline)
            Text(message.envelope.createdAt.formatted(date: .long, time: .standard))
                .font(.caption)
                .foregroundStyle(.secondary)
            if message.status == .pending {
                Label("서버 전달 대기", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .cardStyle()
    }

    private func bodyCard(_ message: TextStoredMessage) -> some View {
        Text(message.envelope.text)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("text-detail-body")
            .cardStyle()
    }

    private func actionsCard(_ message: TextStoredMessage) -> some View {
        VStack(spacing: 10) {
            if message.status == .pending && message.key.direction == .sent {
                Button {
                    Task { await model.retry(message.envelope.id) }
                } label: {
                    Label("재전송", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.activity != .idle)
                .accessibilityIdentifier("text-retry")
            }

            Button {
                UIPasteboard.general.string = message.envelope.text
                actionMessage = "전체 복사 완료"
            } label: {
                Label("전체 복사", systemImage: "doc.on.doc")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("text-copy")

            Button {
                isExporting = true
            } label: {
                Label("TXT로 저장", systemImage: "doc.badge.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("text-export")

            if let shareURL {
                ShareLink(item: shareURL) {
                    Label("공유", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("text-share")
            } else {
                Button {
                    shareURL = try? Self.makeShareFile(message)
                } label: {
                    Label("공유 준비 중", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(true)
                .accessibilityIdentifier("text-share")
            }

            Button("삭제", role: .destructive) {
                confirmDelete = true
            }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("text-delete")
        }
        .cardStyle()
    }

    private var exportBaseName: String {
        "SimpleCamera-text-\(key.id.uuidString.lowercased())"
    }

    private static func makeShareFile(_ message: TextStoredMessage) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SimpleCameraTextShare", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let url = directory.appendingPathComponent(
            "SimpleCamera-text-\(message.envelope.id.uuidString.lowercased()).txt"
        )
        try Data(message.envelope.text.utf8).write(to: url, options: .atomic)
        return url
    }
}

struct TextExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.text = text
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
