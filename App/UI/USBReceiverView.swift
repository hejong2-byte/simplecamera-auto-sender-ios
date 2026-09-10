import SwiftUI
import UniformTypeIdentifiers

struct USBReceiverView: View {
    @ObservedObject var model: USBReceiverViewModel
    @ObservedObject var incomingModel: IPhoneIncomingFilesViewModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if !incomingModel.pendingFiles.isEmpty {
                    Button("수신 대기 \(incomingModel.pendingFiles.count)개 · 저장 위치 선택") {
                        incomingModel.showPendingFiles()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isExportingToUSB || model.isReceivingFile || model.isDeletingStoredFiles)
                }
                destinationCard
                progressCard
                storedFilesCard
            }
            .padding()
        }
        .refreshable { await model.refresh() }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("PC 파일 수신")
        .task {
            await model.refresh()
            updatePolling(for: scenePhase)
        }
        .onChange(of: scenePhase) { _, phase in
            updatePolling(for: phase)
            if phase == .active { Task { await model.refresh() } }
        }
        .onDisappear { model.stopForegroundPolling() }
        .sheet(item: $model.previewFile) { file in
            StoredFilePreview(file: file, onClose: { model.previewFile = nil })
        }
        .alert("임시파일을 정리할까요?", isPresented: Binding(
            get: { model.needsTemporaryCleanupConfirmation }, set: { _ in }
        )) {
            Button("임시파일 정리", role: .destructive) {
                Task { await model.cleanConfirmedTemporaryFiles() }
            }
            Button("취소", role: .cancel) { model.needsTemporaryCleanupConfirmation = false }
        } message: {
            Text("이 앱이 만든 임시 압축해제 파일·미완성 USB 복사본만 삭제합니다. 원본 ZIP·완료된 복사본·다른 파일은 유지합니다. SD/USB 임시파일을 정리하려면 다시 연결하고 폴더를 선택해 주세요.")
        }
        .alert("파일 열기 실패", isPresented: Binding(
            get: { model.storedFilePreviewError != nil },
            set: { if !$0 { model.storedFilePreviewError = nil } }
        )) {
            Button("확인", role: .cancel) { model.storedFilePreviewError = nil }
        } message: {
            Text(model.storedFilePreviewError ?? "")
        }
        .fileImporter(
            isPresented: $model.isChoosingUSBFolder,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            guard case let .success(urls) = result, let url = urls.first else { return }
            Task { await model.selectDestination(url) }
        }
        .alert(
            "USB가 연결되지 않았습니다. iPhone에 저장할까요?",
            isPresented: Binding(
                get: { model.needsLocalFallbackDecision },
                set: { _ in }
            )
        ) {
            Button("iPhone에 저장") { Task { await model.chooseLocalFallback() } }
            Button("서버에 대기", role: .cancel) {
                Task { await model.chooseServerWait() }
            }
        } message: {
            Text("현재 PC 대기 파일 묶음에 적용됩니다.")
        }
        .confirmationDialog(
            "USB 전송이 완료되었습니다. iPhone 원본을 삭제할까요?",
            isPresented: Binding(
                get: { model.needsDeletionDecision },
                set: { _ in }
            ),
            titleVisibility: .visible
        ) {
            Button("원본 유지(권장)", role: .cancel) {
                Task { await model.keepOriginals() }
            }
            Button("iPhone 원본 삭제", role: .destructive) {
                Task { await model.deleteOriginals() }
            }
        } message: {
            Text("USB 복사와 파일 크기 확인을 마쳤습니다. 정밀 SHA 검증은 선택 사항입니다. iPhone 원본을 삭제할까요? USB 복사본은 유지됩니다.")
        }
        .alert(
            "선택한 iPhone 파일 \(model.storedFilesPendingDeletion.count)개를 삭제할까요?",
            isPresented: Binding(
                get: { model.needsStoredFileDeletionConfirmation },
                set: { _ in }
            )
        ) {
            Button("취소", role: .cancel) { model.cancelStoredFileDeletion() }
            Button("삭제", role: .destructive) {
                Task { await model.deleteConfirmedStoredFiles() }
            }
        } message: {
            let names = model.storedFilesPendingDeletion.prefix(3).map(\.name).joined(separator: "\n")
            let remaining = model.storedFilesPendingDeletion.count - 3
            Text(names + (remaining > 0 ? "\n외 \(remaining)개" : "")
                + "\n\niPhone에 저장된 선택 파일만 삭제하며 되돌릴 수 없습니다. USB와 PC의 파일은 삭제하지 않습니다.")
        }
        .confirmationDialog(
            "ZIP 파일을 USB로 어떻게 복사할까요?",
            isPresented: Binding(
                get: { model.needsStoredZIPExportChoice },
                set: { _ in }
            ),
            titleVisibility: .visible
        ) {
            Button("압축 해제해서 복사") {
                Task { await model.confirmStoredZIPExport(.extract) }
            }
            Button("ZIP 그대로 복사") {
                Task { await model.confirmStoredZIPExport(.keepArchive) }
            }
            Button("취소", role: .cancel) { model.cancelStoredZIPExportChoice() }
        } message: {
            Text("선택한 \(model.storedZIPExportFilesPendingChoice.count)개 파일에 적용합니다. 복사가 끝난 뒤에도 iPhone 원본은 별도 확인 전까지 유지됩니다.")
        }
    }

    private var destinationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("선택한 수신 작업의 저장 위치").font(.headline)
            if model.selectedDestination == .iphoneLocal {
                Label("받은 파일 폴더에 저장", systemImage: "iphone.gen3")
                    .foregroundStyle(.green)
            } else {
                Label("USB에 직접 저장", systemImage: "externaldrive")
            }
            Label(
                model.usbDisplayName ?? "USB 폴더 미선택",
                systemImage: model.isUSBAvailable == true ? "externaldrive.fill.badge.checkmark" : "externaldrive.badge.questionmark"
            )
            .foregroundStyle(model.isUSBAvailable == true ? .green : .orange)
            if let message = model.usbConnectionMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(model.isUSBAvailable == false ? Color.orange : Color.secondary)
            }
            Button(model.hasUSBDestination ? "USB 폴더 다시 선택" : "USB 폴더 선택") {
                model.isChoosingUSBFolder = true
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isExportingToUSB || model.isReceivingFile || model.isDeletingStoredFiles)
        }
        .cardStyle()
    }

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(
                    model.receiveStatus.kind == .saved || model.receiveStatus.kind == .failed
                        ? "최근 PC 파일 수신 결과"
                        : "PC 새 파일 수신 상태"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Spacer()
                if model.isPolling {
                    Label(model.lastError == nil ? "감시 중" : "재확인 중", systemImage: "dot.radiowaves.left.and.right")
                        .font(.caption)
                        .foregroundStyle(model.lastError == nil ? .green : .orange)
                }
            }

            PCReceiveStatusView(status: model.receiveStatus,
                dismissAction: model.canDismissReceiveOutcome ? { model.dismissReceiveOutcome() } : nil,
                dismissalError: model.receiveOutcomeDismissalError)

            if model.receiveStatus.kind == .active,
               let progress = model.receiveProgress {
                if !model.receiveByteText.isEmpty {
                    Text(model.receiveByteText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if !model.receiveSpeedText.isEmpty {
                    HStack {
                        Text(model.receiveSpeedText)
                        Spacer()
                        Text(model.receiveETAText)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                if progress.totalCount > 0 {
                    Text("전체 \(progress.totalCount)개 · 저장 완료 \(progress.completedCount)개")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let expiresAt = progress.expiresAt {
                    Text("서버 보관 만료: \(expiresAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let error = model.lastError, model.receiveStatus.kind != .failed {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.red)
            }
            if let incomingError = incomingModel.lastError {
                Label("도착 확인 오류 · \(incomingError)", systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.red)
            }
        }
        .cardStyle()
    }

    private var storedFilesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("iPhone에 저장된 파일").font(.headline)
                Spacer()
                Text("\(model.storedFiles.count)개")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if model.storedFiles.isEmpty {
                Text("저장된 파일이 없습니다.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.storedFiles) { file in
                    HStack(spacing: 8) {
                        Button {
                            model.toggleStoredFileSelection(file.id)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: model.selectedStoredFileIDs.contains(file.id)
                                    ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(.cyan)
                                Image(systemName: "doc.fill")
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(file.name).lineLimit(2)
                                    Text("\(byteText(file.size)) · \(file.modifiedAt.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(model.isExportingToUSB || model.isDeletingStoredFiles)
                        .accessibilityIdentifier("stored-file-\(file.name)")
                        Button { model.openStoredFile(file) } label: {
                            Label("열기", systemImage: "eye")
                                .font(.caption)
                                .frame(minHeight: 44)
                        }
                        .buttonStyle(.borderless)
                        .disabled(model.isDeletingStoredFiles)
                        .accessibilityIdentifier("stored-file-open-\(file.name)")
                    }
                    Divider()
                }
            }
            HStack(alignment: .center, spacing: 8) {
                Button {
                    Task { await model.requestStoredFilesUSBExport() }
                } label: {
                    Text("USB 복사")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.hasStoredFileSelection || model.isExportingToUSB || model.isReceivingFile
                    || model.isDeletingStoredFiles || model.needsStoredZIPExportChoice)
                .accessibilityIdentifier("stored-files-export")
                .accessibilityLabel("선택 파일 USB로 복사")

                Button(role: .destructive) {
                    model.requestStoredFileDeletion()
                } label: {
                    Text("선택 삭제")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!model.canDeleteStoredFiles)
                .accessibilityIdentifier("stored-files-delete")
                .accessibilityLabel("선택 파일 삭제")

                Button { model.requestTemporaryCleanup() } label: {
                    Text("임시파일 삭제").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!model.canCleanTemporaryFiles)
                .accessibilityIdentifier("stored-files-clean-temp")
            }
            .font(.subheadline)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .controlSize(.regular)

            if model.isDeletingStoredFiles || model.storedFileDeletionProgress != nil {
                FileDeletionProgressView(progress: model.storedFileDeletionProgress, isRunning: model.isDeletingStoredFiles)
            }
            if model.isCleaningTemporaryFiles || model.temporaryCleanupProgress != nil {
                FileDeletionProgressView(progress: model.temporaryCleanupProgress, isRunning: model.isCleaningTemporaryFiles)
            }
            if let message = model.temporaryCleanupMessage {
                Text(message).font(.subheadline).foregroundStyle(.secondary)
            }
            if let error = model.temporaryCleanupError {
                Text(error).font(.subheadline).foregroundStyle(.red)
            }
            Button {
                Task { await model.verifySelectedUSBCopies() }
            } label: {
                Label("선택 파일의 USB 복사본 정밀 SHA 검증", systemImage: "checkmark.shield")
            }
            .buttonStyle(.bordered)
            .disabled(!model.hasStoredFileSelection || model.isExportingToUSB || model.isReceivingFile
                || model.isDeletingStoredFiles || model.isCleaningUSBFolder || model.needsStoredZIPExportChoice
                || model.needsDeletionDecision)
            .accessibilityIdentifier("stored-files-verify-usb")
            if let message = model.usbVerificationMessage {
                Label(message, systemImage: model.usbVerificationFailed ? "exclamationmark.triangle" : "checkmark.shield")
                    .font(.subheadline)
                    .foregroundStyle(model.usbVerificationFailed ? .orange : .green)
            }
            if let message = model.storedFileDeletionMessage {
                Label(message, systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.green)
            }
            if let error = model.storedFileDeletionError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.red)
            }

            if model.isExportingToUSB || model.usbExportProgress != nil || model.lastUSBExportError != nil {
                usbExportStatus
            }
            if let message = model.usbExportCompletionMessage {
                Label(message, systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.green)
            }
            if let error = model.lastOriginalCleanupError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.red)
            }
        }
        .cardStyle()
    }

    private var usbExportStatus: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            Text(model.usbExportStageTitle).font(.headline)
            if model.usbExportProgress?.stage == .paused {
                HStack(spacing: 8) {
                    Button("중단 지점부터 이어받기") {
                        Task { await model.resumeInterruptedUSBCopy() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canResumeInterruptedUSBCopy)
                    .accessibilityIdentifier("stored-files-resume-export")

                    Button("중단 기록 지우기", role: .destructive) {
                        model.dismissInterruptedUSBCopy()
                    }
                    .buttonStyle(.bordered)
                    .disabled(!model.canDismissInterruptedUSBCopy)
                    .accessibilityIdentifier("stored-files-dismiss-interrupted-export")
                }
                .font(.subheadline)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            }
            if model.isExportingToUSB && !model.isVerifyingUSBCopies {
                Button(model.isCancellingUSBCopy ? "취소 처리 대기 중" : "복사 취소", role: .destructive) {
                    model.cancelUSBCopy()
                }
                .buttonStyle(.bordered)
                .disabled(!model.canCancelUSBCopy)
                .accessibilityIdentifier("stored-files-cancel-export")
                if model.isCancellingUSBCopy {
                    Text("현재 SD/USB 작업이 반환되면 임시파일을 정리합니다. 운영체제의 쓰기 작업이 멈춘 동안에는 취소도 기다릴 수 있습니다.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            if let progress = model.visibleUSBExportProgress {
                if progress.stage != .failed && progress.stage != .cancelled, progress.totalBytes > 0 || progress.stage == .completed {
                    ProgressView(value: Double(model.usbExportDisplayedPercent), total: 100)
                        .tint(.cyan)
                    HStack {
                        Text("\(model.usbExportDisplayedPercent)%")
                            .font(.title3.monospacedDigit().bold())
                        Spacer()
                        Text(model.usbExportByteText)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                if progress.totalBytes == 0, model.isExportingToUSB {
                    ProgressView("작업량 확인 중").tint(.cyan)
                }
                if let detail = progress.detail {
                    Text(detail).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                }
                if model.isExportingToUSB, let updatedAt = model.usbExportLastUpdatedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        if let speed = model.usbExportSpeedText(at: context.date) {
                            Text(speed).font(.title3.monospacedDigit().bold()).foregroundStyle(.cyan)
                        }
                        if let remaining = model.usbExportRemainingTimeText(at: context.date) {
                            Text(remaining).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        let seconds = max(0, Int(context.date.timeIntervalSince(updatedAt)))
                        if seconds >= 3 {
                            Text("현재 작업의 진행 응답 대기 · 마지막 갱신 후 \(seconds)초")
                                .font(.caption.monospacedDigit()).foregroundStyle(.orange)
                        }
                    }
                }
                if let fileName = progress.fileName {
                    Label(fileName, systemImage: "doc.fill")
                        .font(.subheadline)
                        .lineLimit(2)
                }
                Text("전체 \(progress.totalCount)개 · USB 복사 완료 \(progress.completedCount)개")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if model.isExportingToUSB {
                ProgressView().tint(.cyan)
            }
            if let error = model.lastUSBExportError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.red)
                Text("복사에 실패한 파일의 원본은 자동 삭제하지 않습니다. 오류 원인을 확인한 뒤 선택된 파일을 다시 복사할 수 있습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func updatePolling(for phase: ScenePhase) {
        if phase == .active { model.startForegroundPolling() }
        else { model.stopForegroundPolling() }
    }

    private func byteText(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: max(0, bytes))
    }
}
