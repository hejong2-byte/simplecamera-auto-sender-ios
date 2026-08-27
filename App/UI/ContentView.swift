import Photos
import SwiftUI

struct ContentView: View {
    @StateObject private var model: ContentViewModel
    @StateObject private var receiverModel: USBReceiverViewModel
    @State private var pickerKind: ManualMediaKind?
    @State private var readinessMessage: String?

    init(model: ContentViewModel, receiverModel: USBReceiverViewModel) {
        _model = StateObject(wrappedValue: model)
        _receiverModel = StateObject(wrappedValue: receiverModel)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    header
                    automaticStatusCard
                    manualTransferCard
                    manualStatusCard
                    receiverCard
                    NavigationLink {
                        SettingsView(model: model, receiverModel: receiverModel)
                    } label: {
                        Label("설정", systemImage: "gearshape.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("업무사진 전송")
            .task { await model.refresh() }
            .sheet(item: $pickerKind) { kind in
                ManualMediaPicker(
                    kind: kind,
                    onSelection: { selection in
                        pickerKind = nil
                        Task {
                            await model.sendSelectedMedia(
                                selection: selection,
                                kind: kind
                            )
                        }
                    },
                    onCancel: { pickerKind = nil }
                )
                .ignoresSafeArea()
            }
            .alert(
                "전송 설정 필요",
                isPresented: Binding(
                    get: { readinessMessage != nil },
                    set: { if !$0 { readinessMessage = nil } }
                )
            ) {
                Button("확인", role: .cancel) {}
            } message: {
                Text(readinessMessage ?? "")
            }
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.cyan, .black)
            Text("사진·스크린샷·동영상 전송")
                .font(.headline)
            Text("보낼 항목을 직접 고르면 선택한 파일만 PC로 전송합니다.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private var manualTransferCard: some View {
        VStack(spacing: 12) {
            ForEach(ManualMediaKind.allCases) { kind in
                Button {
                    openPicker(kind)
                } label: {
                    Label(kind.title, systemImage: kind.systemImage)
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isManualTransferWorking)
            }
            Text("여러 개를 한 번에 선택할 수 있습니다. 큰 동영상은 32MB 단위로 나눠 백그라운드에서 전송합니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .cardStyle()
    }

    private var receiverCard: some View {
        NavigationLink {
            USBReceiverView(model: receiverModel)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Label("PC 파일 수신", systemImage: "externaldrive.badge.icloud")
                    .font(.headline)
                Text("PC에서 보낸 파일을 iPhone에 저장하거나 USB로 직접 저장")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack {
                    Text(receiverModel.registrationCode.map { "코드 \($0)" } ?? "기기 등록 필요")
                    Spacer()
                    Image(systemName: "chevron.right")
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            .cardStyle()
        }
        .buttonStyle(.plain)
        .task { await receiverModel.refresh() }
    }

    private var automaticStatusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.automaticStageTitle)
                .font(.headline)

            if let progress = model.automaticProgress {
                switch progress.stage {
                case .scanning, .preparing:
                    ProgressView()
                        .tint(.cyan)
                case .uploading, .verifying, .completed, .failed:
                    if progress.totalBytes > 0 {
                        ProgressView(
                            value: Double(progress.percent),
                            total: 100
                        )
                        .tint(automaticTint(for: progress.stage))
                        HStack {
                            Text("\(progress.percent)%")
                                .font(.title3.monospacedDigit().bold())
                            Spacer()
                            Text(model.automaticByteProgressText)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                case .idle:
                    EmptyView()
                }

                if progress.totalCount > 0
                    || progress.uploadedCount > 0
                    || progress.failedCount > 0 {
                    HStack {
                        statusValue("전체", progress.totalCount)
                        statusValue("완료", progress.uploadedCount)
                        statusValue("실패", progress.failedCount)
                    }
                }
            }

            Text(model.automaticTransferMessage)
                .font(.subheadline)
                .foregroundStyle(
                    model.automaticProgress?.stage == .failed
                        ? Color.red
                        : Color.secondary
                )

            if model.automaticProgress?.stage != .failed,
               let failure = model.automaticFailureMessage {
                Text("재시도 대기 · \(failure)")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .cardStyle()
    }

    private var manualStatusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.manualStageTitle).font(.headline)
            if let progress = model.manualProgress, progress.stage != .idle {
                if progress.totalBytes > 0 {
                    ProgressView(value: Double(progress.percent), total: 100)
                        .tint(progress.stage == .failed ? .red : .cyan)
                    HStack {
                        Text("\(progress.percent)%")
                            .font(.title3.monospacedDigit().bold())
                        Spacer()
                        Text(model.manualByteProgressText)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                } else if model.isManualTransferWorking {
                    ProgressView()
                }
            }
            Text(model.manualTransferMessage ?? "전송할 종류를 선택하세요.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let summary = model.lastManualSummary {
                HStack {
                    statusValue("선택", summary.selected)
                    statusValue("완료", summary.uploaded)
                    statusValue("실패", summary.failed)
                }
            }
        }
        .cardStyle()
    }

    private func openPicker(_ kind: ManualMediaKind) {
        if let message = model.manualTransferReadinessMessage {
            readinessMessage = message
            return
        }
        pickerKind = kind
    }

    private func statusValue(_ title: String, _ value: Int) -> some View {
        VStack {
            Text("\(value)").font(.title2.bold())
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func automaticTint(for stage: AutomaticTransferStage) -> Color {
        switch stage {
        case .completed: return .green
        case .failed: return .red
        default: return .cyan
        }
    }
}

extension View {
    func cardStyle() -> some View {
        self
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}
