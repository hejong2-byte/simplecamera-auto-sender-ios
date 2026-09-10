import Photos
import SwiftUI

struct ContentView: View {
    @StateObject private var model: ContentViewModel
    @StateObject private var receiverModel: USBReceiverViewModel
    @StateObject private var incomingModel: IPhoneIncomingFilesViewModel
    @StateObject private var filePickerModel: KakaoFilePickerModel
    @StateObject private var textModel: TextTransferViewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var navigationPath: [Destination] = []
    @State private var pickerKind: ManualMediaKind?
    @State private var readinessMessage: String?
    @State private var receiveNotice: String?
    @State private var isAdvancingIncomingPrompt = false

    private enum Destination: Hashable {
        case receiver
        case text
        case settings
    }

    init(
        model: ContentViewModel,
        receiverModel: USBReceiverViewModel,
        incomingModel: IPhoneIncomingFilesViewModel,
        filePickerModel: KakaoFilePickerModel,
        textModel: TextTransferViewModel
    ) {
        _model = StateObject(wrappedValue: model)
        _receiverModel = StateObject(wrappedValue: receiverModel)
        _incomingModel = StateObject(wrappedValue: incomingModel)
        _filePickerModel = StateObject(wrappedValue: filePickerModel)
        _textModel = StateObject(wrappedValue: textModel)
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ScrollView {
                VStack(spacing: 12) {
                    automaticStatusCard
                    manualTransferCard
                    if model.shouldShowManualStatus {
                        manualStatusCard
                    }
                    textTransferCard
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
                case .text:
                    TextTransferView(model: textModel)
                case .settings:
                    SettingsView(model: model, receiverModel: receiverModel, filePickerModel: filePickerModel)
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
            .sheet(item: $filePickerModel.request, onDismiss: filePickerModel.didDismiss) { request in
                DocumentFilePicker(
                    request: request,
                    onSelection: { urls in
                        let selected = filePickerModel.accept(urls)
                        if !selected.isEmpty { await model.sendSelectedFiles(selected) }
                    },
                    onCancel: filePickerModel.cancel
                )
                .ignoresSafeArea()
                .interactiveDismissDisabled()
            }
            .alert("파일 폴더 확인", isPresented: Binding(
                get: { filePickerModel.errorMessage != nil && !filePickerModel.isDismissing },
                set: { if !$0 { filePickerModel.errorMessage = nil } }
            )) {
                Button("폴더 다시 선택") { filePickerModel.reselectAfterError() }
                Button("취소", role: .cancel) { filePickerModel.cancel() }
            } message: {
                Text(filePickerModel.errorMessage ?? "")
            }
        }
        .task {
            let active = scenePhase == .active
            incomingModel.setActive(active)
            textModel.setActive(active)
            receiverModel.setAppActive(active)
        }
        .onChange(of: scenePhase) { _, phase in
            let active = phase == .active
            incomingModel.setActive(active)
            textModel.setActive(active)
            receiverModel.setAppActive(active)
        }
        .task(id: scenePhase) {
            if scenePhase == .active { await receiverModel.monitorUSBAvailability() }
        }
        .sheet(
            isPresented: Binding(
                get: {
                    incomingModel.needsPendingSelection && canPresentIncomingFiles
                },
                set: { presented in
                    if !presented, incomingModel.needsPendingSelection {
                        incomingModel.cancelPendingFileSelection()
                    }
                }
            ),
            onDismiss: incomingModel.cancelPendingFileSelection
        ) {
            PendingIncomingSelectionView(model: incomingModel) {
                _ = incomingModel.confirmPendingFileSelection()
            }
        }
        .confirmationDialog(
            incomingDialogTitle,
            isPresented: Binding(
                get: { incomingModel.prompt != nil && canPresentIncomingFiles },
                set: { presented in
                    if !presented,
                       incomingModel.prompt != nil,
                       canPresentIncomingFiles,
                       !isAdvancingIncomingPrompt {
                        postponeIncoming()
                    }
                }
            ),
            titleVisibility: .visible,
            presenting: incomingModel.prompt
        ) { prompt in
            switch prompt.stage {
            case .archiveChoice:
                Button("압축 해제") { acceptExtractedZIP(prompt) }
                    .accessibilityIdentifier("incoming-zip-extract")
                Button("ZIP 그대로 저장") { keepIncomingZIP(prompt) }
                    .accessibilityIdentifier("incoming-zip-keep")
                Button("나중에 받기", role: .cancel) { postponeIncoming() }
            case .destinationChoice:
                Button("iPhone에 저장") { acceptIncoming(prompt, destination: .iphoneLocal) }
                Button("USB에 저장") { acceptIncoming(prompt, destination: .usb) }
                Button("나중에 받기", role: .cancel) { postponeIncoming() }
            }
        } message: { prompt in
            Text(incomingDialogMessage(prompt))
        }
        .onDisappear {
            incomingModel.setActive(false)
            textModel.setActive(false)
        }
    }

    private var canPresentIncomingFiles: Bool {
        let receiverIsBusy = receiverModel.isReceivingFile
            || receiverModel.needsLocalFallbackDecision || receiverModel.needsDeletionDecision
        return scenePhase == .active && pickerKind == nil && readinessMessage == nil
            && !filePickerModel.isPresenting
            && !receiverModel.isChoosingUSBFolder && !receiverModel.isShowingSettingsConfirmation
            && !receiverModel.isDeletingStoredFiles && !receiverModel.needsStoredFileDeletionConfirmation
            && !receiverModel.needsStoredZIPExportChoice
            && !receiverModel.isCleaningUSBFolder
            && receiverModel.previewFile == nil && receiverModel.storedFilePreviewError == nil
            && !receiverModel.isExportingToUSB && !receiverIsBusy
    }

    private var incomingDialogTitle: String {
        guard let prompt = incomingModel.prompt else { return "PC 파일 도착" }
        switch prompt.stage {
        case .archiveChoice:
            return "압축을 해제하시겠습니까?"
        case .destinationChoice:
            return prompt.title
        }
    }

    private func incomingDialogMessage(_ prompt: IPhoneIncomingPrompt) -> String {
        switch prompt.stage {
        case .archiveChoice:
            let names = prompt.files.prefix(3).map(\.fileName).joined(separator: "\n")
            let remaining = prompt.files.count > 3 ? "\n외 \(prompt.files.count - 3)개" : ""
            let size = ByteCountFormatter.string(fromByteCount: prompt.totalBytes, countStyle: .file)
            return "\(names)\(remaining)\n총 \(size)\n압축 해제 시 iPhone 임시 공간을 거쳐 USB/SD에 저장합니다."
        case .destinationChoice:
            return prompt.message
        }
    }

    private func keepIncomingZIP(_ prompt: IPhoneIncomingPrompt) {
        receiveNotice = nil
        isAdvancingIncomingPrompt = true
        _ = incomingModel.chooseArchiveMode(prompt, mode: .keepArchive)
        DispatchQueue.main.async { isAdvancingIncomingPrompt = false }
    }

    private func acceptExtractedZIP(_ prompt: IPhoneIncomingPrompt) {
        receiveNotice = nil
        guard incomingModel.chooseArchiveMode(prompt, mode: .extract) else { return }
        routeIncoming(to: .usb)
    }

    private func acceptIncoming(_ prompt: IPhoneIncomingPrompt, destination: IPhoneReceiveDestination) {
        guard incomingModel.accept(prompt, destination: destination) else { return }
        receiveNotice = nil
        routeIncoming(to: destination)
    }

    private func routeIncoming(to destination: IPhoneReceiveDestination) {
        receiverModel.setSelectedDestination(destination)
        navigationPath = [.receiver]
        if destination == .usb, !receiverModel.hasUSBDestination {
            receiverModel.isChoosingUSBFolder = true
        }
    }

    private func postponeIncoming() {
        incomingModel.postponePrompt()
        receiveNotice = "수신 보류 · 앱을 다시 열면 다시 안내합니다."
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
        }
        .cardStyle()
    }

    private var receiverCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            NavigationLink(value: Destination.receiver) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("PC 파일 수신", systemImage: "externaldrive.badge.icloud")
                        .font(.headline)
                    HStack {
                        Text(receiverModel.registrationCode.map { "코드 \($0)" } ?? "기기 등록 필요")
                        Spacer()
                        Image(systemName: "chevron.right")
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("open-receiver")

            if receiverModel.isExportingToUSB || receiverModel.usbExportProgress?.stage == .paused {
                HStack {
                    Text(receiverModel.usbExportStageTitle)
                    Spacer()
                    Text("\(receiverModel.usbExportDisplayedPercent)%")
                        .monospacedDigit()
                }
                .font(.subheadline)
                .foregroundStyle(.orange)
                .accessibilityIdentifier("usb-copy-home-status")
            }

            PCReceiveStatusView(status: receiverModel.receiveStatus, compact: true,
                dismissAction: receiverModel.canDismissReceiveOutcome ? { receiverModel.dismissReceiveOutcome() } : nil,
                dismissalError: receiverModel.receiveOutcomeDismissalError)

            if !incomingModel.pendingFiles.isEmpty {
                Button("수신 대기 \(incomingModel.pendingFiles.count)개 · 저장 위치 선택") {
                    incomingModel.showPendingFiles()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canPresentIncomingFiles)
                .accessibilityIdentifier("incoming-pending")
            } else {
                Text(incomingModel.isMonitoring ? "새 파일 도착 알림 감시 중" : "앱을 다시 열면 새 파일을 확인합니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = incomingModel.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
            }
            if let receiveNotice {
                Text(receiveNotice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .cardStyle()
        .task { await receiverModel.refresh() }
    }

    private var textTransferCard: some View {
        NavigationLink(value: Destination.text) {
            HStack(spacing: 10) {
                Label("텍스트 송수신", systemImage: "text.bubble.fill")
                    .font(.headline)
                Spacer()
                if textModel.unreadCount > 0 {
                    Text("\(textModel.unreadCount)")
                        .font(.caption.monospacedDigit().bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.cyan)
                        .clipShape(Capsule())
                }
                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("open-text-transfer")
        .cardStyle()
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
                case .uploading, .verifying, .completed, .failed, .paused:
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
        if kind == .file {
            if let message = model.fileTransferReadinessMessage {
                readinessMessage = message
            } else {
                filePickerModel.beginFileSelection()
            }
            return
        }
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
        case .paused: return .orange
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
