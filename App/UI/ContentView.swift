import Photos
import SwiftUI

struct ContentView: View {
    @StateObject private var model: ContentViewModel
    @StateObject private var receiverModel: USBReceiverViewModel
    @StateObject private var incomingModel: IPhoneIncomingFilesViewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var navigationPath: [Destination] = []
    @State private var pickerKind: ManualMediaKind?
    @State private var readinessMessage: String?

    private enum Destination: Hashable { case receiver, settings }

    init(model: ContentViewModel, receiverModel: USBReceiverViewModel, incomingModel: IPhoneIncomingFilesViewModel) {
        _model = StateObject(wrappedValue: model)
        _receiverModel = StateObject(wrappedValue: receiverModel)
        _incomingModel = StateObject(wrappedValue: incomingModel)
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ScrollView {
                VStack(spacing: 12) {
                    automaticStatusCard
                    manualTransferCard
                    if model.manualProgress != nil || model.lastManualSummary != nil {
                        manualStatusCard
                    }
                    receiverCard
                    NavigationLink(value: Destination.settings) {
                        Label("설정", systemImage: "gearshape.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .accessibilityIdentifier("open-settings")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("업무사진 전송")
            .task { await model.refresh() }
            .navigationDestination(for: Destination.self) { destination in
                switch destination {
                case .receiver:
                    USBReceiverView(model: receiverModel, incomingModel: incomingModel)
                case .settings:
                    SettingsView(model: model, receiverModel: receiverModel)
                }
            }
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
        .task { incomingModel.setActive(scenePhase == .active) }
        .onChange(of: scenePhase) { _, phase in
            incomingModel.setActive(phase == .active)
        }
        .confirmationDialog(
            incomingModel.prompt?.title ?? "PC 파일 도착",
            isPresented: Binding(
                get: { incomingModel.prompt != nil && canPresentIncomingFiles },
                set: { if !$0, canPresentIncomingFiles { incomingModel.postponePrompt() } }
            ),
            titleVisibility: .visible,
            presenting: incomingModel.prompt
        ) { batch in
            Button("iPhone에 저장") { acceptIncoming(batch, destination: .iphoneLocal) }
            Button("USB에 저장") { acceptIncoming(batch, destination: .usb) }
            Button("나중에 받기", role: .cancel) { incomingModel.postponePrompt() }
        } message: { batch in
            Text(batch.message)
        }
        .onDisappear { incomingModel.setActive(false) }
    }

    private var canPresentIncomingFiles: Bool {
        let receiverIsBusy = navigationPath.last == .receiver
            && (receiverModel.isReceivingFile || receiverModel.needsLocalFallbackDecision || receiverModel.needsDeletionDecision)
        return scenePhase == .active && pickerKind == nil && readinessMessage == nil
            && !receiverModel.isChoosingUSBFolder && !receiverModel.isShowingSettingsConfirmation
            && !receiverModel.isExportingToUSB && !receiverIsBusy
    }

    private func acceptIncoming(_ batch: IPhoneIncomingBatch, destination: IPhoneReceiveDestination) {
        guard incomingModel.accept(batch, destination: destination) else { return }
        receiverModel.setSelectedDestination(destination)
        navigationPath = [.receiver]
        if destination == .usb, !receiverModel.hasUSBDestination {
            receiverModel.isChoosingUSBFolder = true
        }
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
                .accessibilityIdentifier("manual-\(kind.rawValue)")
                .disabled(model.isManualTransferWorking)
            }
            Text("여러 개를 한 번에 선택할 수 있습니다. 큰 동영상은 32MB 단위로 나눠 백그라운드에서 전송합니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .cardStyle()
    }

    private var receiverCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            NavigationLink(value: Destination.receiver) {
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
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("open-receiver")
            if !incomingModel.pendingFiles.isEmpty {
                Button("수신 대기 \(incomingModel.pendingFiles.count)개 · 저장 위치 선택") {
                    incomingModel.showPendingFiles()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canPresentIncomingFiles)
                .accessibilityIdentifier("incoming-pending")
            } else {
                Text(incomingModel.isMonitoring ? "앱을 열어둔 동안 새 파일 도착을 확인합니다." : "앱을 다시 열면 새 파일을 확인합니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = incomingModel.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
            }
        }
        .cardStyle()
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
