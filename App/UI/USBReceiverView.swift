import SwiftUI
import UniformTypeIdentifiers

struct USBReceiverView: View {
    @ObservedObject var model: USBReceiverViewModel
    @ObservedObject var incomingModel: IPhoneIncomingFilesViewModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                identityCard
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
            Text("USB에서 크기와 SHA-256 검증을 마친 파일만 대상입니다.")
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
    }

    private var identityCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("수신 기기").font(.headline)
            if model.isRegistered {
                Label(model.deviceName ?? "iPhone", systemImage: "iphone")
                HStack {
                    Text("PC 입력 코드").foregroundStyle(.secondary)
                    Spacer()
                    Text(model.registrationCode ?? "------")
                        .font(.title2.monospacedDigit().bold())
                        .textSelection(.enabled)
                }
            } else {
                Label("수신 기기 등록이 필요합니다", systemImage: "iphone.badge.exclamationmark")
                    .foregroundStyle(.orange)
                Button("이 iPhone 등록") { Task { await model.registerDevice() } }
                    .buttonStyle(.borderedProminent)
            }
        }
        .cardStyle()
    }

    private var destinationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("선택한 수신 작업의 저장 위치").font(.headline)
            if model.selectedDestination == .iphoneLocal {
                Label("받은 파일 폴더에 저장", systemImage: "iphone.gen3")
                    .foregroundStyle(.green)
                Text("시작된 다운로드는 다른 앱을 사용 중에도 iOS가 이어갈 수 있습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Label("USB에 직접 저장", systemImage: "externaldrive")
            }
            Label(
                model.usbDisplayName ?? "USB 폴더 미선택",
                systemImage: model.hasUSBDestination ? "externaldrive.fill.badge.checkmark" : "externaldrive.badge.questionmark"
            )
            .foregroundStyle(model.hasUSBDestination ? .green : .orange)
            Button(model.hasUSBDestination ? "USB 폴더 다시 선택" : "USB 폴더 선택") {
                model.isChoosingUSBFolder = true
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isExportingToUSB || model.isReceivingFile || model.isDeletingStoredFiles)
            Text("새 파일은 도착 안내에서 저장 위치를 선택한 뒤 받습니다. 이미 저장된 파일은 아래 목록에서 USB로 복사하세요.")
                .font(.caption)
                .foregroundStyle(.secondary)
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

            PCReceiveStatusView(status: model.receiveStatus)

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
                Text("파일을 선택한 뒤 USB로 복사하거나 삭제하세요. 선택 \(model.selectedStoredFileIDs.count)개")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(model.storedFiles) { file in
                    Button {
                        model.toggleStoredFileSelection(file.id)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: model.selectedStoredFileIDs.contains(file.id)
                                ? "checkmark.circle.fill"
                                : "circle")
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
                    Divider()
                }
            }
            Button("선택 파일 USB로 복사") {
                Task { await model.exportSelectedFilesToUSB() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.hasStoredFileSelection || model.isExportingToUSB || model.isReceivingFile || model.isDeletingStoredFiles)

            Button("선택 파일 삭제", role: .destructive) {
                model.requestStoredFileDeletion()
            }
            .buttonStyle(.bordered)
            .disabled(!model.canDeleteStoredFiles)
            .accessibilityIdentifier("stored-files-delete")

            if model.isDeletingStoredFiles {
                ProgressView("선택 파일 삭제 중…")
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
            if let progress = model.usbExportProgress {
                if progress.stage != .failed {
                    ProgressView(value: Double(progress.percent), total: 100)
                        .tint(.cyan)
                    HStack {
                        Text("\(progress.percent)%")
                            .font(.title3.monospacedDigit().bold())
                        Spacer()
                        Text(model.usbExportByteText)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
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
