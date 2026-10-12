import SwiftUI

struct ManualTransferHistoryView: View {
    @ObservedObject var model: ContentViewModel
    var savedRecipients: [TextSavedRecipient] = []

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if model.isLoadingManualTransferHistory {
                    ProgressView("기록 불러오는 중")
                }
                if let error = model.manualHistoryError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .cardStyle()
                }
                if model.isRetryingManualHistory {
                    ProgressView("재전송 준비 중")
                }
                if model.manualTransferHistory.isEmpty && !model.isLoadingManualTransferHistory {
                    ContentUnavailableView("전송 기록이 없습니다", systemImage: "clock")
                }
                ForEach(model.manualTransferHistory) { entry in
                    historyCard(entry)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("수동 전송 기록")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button {
                Task { await model.refreshManualTransferHistory() }
            } label: {
                Label("새로고침", systemImage: "arrow.clockwise")
            }
            .disabled(model.isLoadingManualTransferHistory || model.isRetryingManualHistory)
            .accessibilityIdentifier("manual-history-refresh")
        }
        .task { await model.refreshManualTransferHistory() }
        .onChange(of: model.isManualTransferWorking) { _, working in
            if !working { Task { await model.refreshManualTransferHistory() } }
        }
        .sheet(isPresented: Binding(
            get: { model.manualHistoryReselectionID != nil },
            set: { if !$0 { model.cancelManualHistoryReselection() } }
        )) {
            DocumentFilePicker(
                request: .files(nil),
                onSelection: { urls in
                    guard let id = model.manualHistoryReselectionID else { return nil }
                    model.cancelManualHistoryReselection()
                    guard urls.count == 1, let url = urls.first else {
                        model.manualHistoryError = "다시 보낼 원본 파일 한 개를 선택해 주세요."
                        return nil
                    }
                    return { await model.retryManualHistoryEntry(id: id, reselectedFileURL: url) }
                },
                onCancel: { model.cancelManualHistoryReselection() }
            )
            .interactiveDismissDisabled(model.isRetryingManualHistory)
        }
    }

    private func historyCard(_ entry: ManualTransferHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(entry.fileName, systemImage: entry.kind.systemImage)
                .font(.headline)
                .textSelection(.enabled)
            Text(recipientLabel(entry))
                .font(.subheadline)
            Text(entry.completedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
            if let failure = entry.failure {
                Label(failureLabel(failure), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                if entry.canRetry {
                    Button {
                        Task { await model.retryManualHistoryEntry(id: entry.id, reselectedFileURL: nil) }
                    } label: {
                        Label("재전송", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isRetryingManualHistory || model.isManualTransferWorking)
                    .accessibilityIdentifier("manual-history-retry-\(entry.id.uuidString)")
                } else {
                    Text("재전송 요청됨")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Label("전송 완료", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func recipientLabel(_ entry: ManualTransferHistoryEntry) -> String {
        guard let mailboxID = entry.recipientMailboxID else { return "기존 인증 수신처" }
        if let saved = savedRecipients.first(where: {
            (try? PCFileMailbox.identifier(for: $0.code)) == mailboxID
        }) { return saved.name }
        return "PC 수신처 · \(mailboxID.uuidString.prefix(8))"
    }

    private func failureLabel(_ failure: ManualTransferFailure) -> String {
        switch failure {
        case .network: return "네트워크 연결 오류"
        case .authentication: return "전송 인증 오류"
        case let .server(statusCode, _): return "서버 오류 (HTTP \(statusCode))"
        case .unsupported: return "지원하지 않는 파일 형식"
        case .tooLarge: return "전송 용량 제한 초과"
        case .fileAccess: return "원본 파일 접근 오류"
        case .storage: return "전송 준비 공간 부족"
        case .other: return "파일 전송 실패"
        }
    }
}
