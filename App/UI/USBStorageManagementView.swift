import SwiftUI
import UniformTypeIdentifiers

struct USBStorageManagementView: View {
    @ObservedObject var model: USBReceiverViewModel
    @ObservedObject var transferModel: ContentViewModel
    @ObservedObject var textModel: TextTransferViewModel
    @State private var isChoosingStorageRecipient = false
    @State private var recipientError: String?
    @State private var isConfirmingSelectedDeletion = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                destinationCard
                fileExplorerCard
                deletionCard
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("SD/USB 저장장치 관리")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await model.refresh()
            await textModel.refreshRecipients()
            if model.hasUSBDestination {
                await model.refreshStorageFiles()
            }
        }
        .sheet(isPresented: $isChoosingStorageRecipient) {
            StorageFileRecipientPicker(
                recipients: textModel.savedRecipients,
                onSelect: sendStorageFiles
            )
        }
        .alert(
            "전송할 컴퓨터 확인",
            isPresented: Binding(
                get: { recipientError != nil },
                set: { if !$0 { recipientError = nil } }
            )
        ) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(recipientError ?? "")
        }
        .fileImporter(
            isPresented: $model.isChoosingUSBFolder,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            guard case let .success(urls) = result, let url = urls.first else { return }
            Task { await model.selectDestination(url) }
        }
        .confirmationDialog(
            model.usbFolderDeletionConfirmationTitle,
            isPresented: Binding(
                get: { model.needsUSBFolderDeletionConfirmation },
                set: { _ in }
            ),
            titleVisibility: .visible
        ) {
            Button("취소", role: .cancel) {
                model.cancelUSBFolderDeletion()
            }
            Button("모든 파일 삭제", role: .destructive) {
                Task { await model.deleteConfirmedUSBFolderContents() }
            }
        } message: {
            Text(model.usbFolderDeletionConfirmationMessage)
        }
        .confirmationDialog(
            "선택한 항목을 삭제하시겠습니까?",
            isPresented: $isConfirmingSelectedDeletion,
            titleVisibility: .visible
        ) {
            Button("취소", role: .cancel) {}
            Button("삭제", role: .destructive) {
                Task { await model.deleteSelectedStorageFiles() }
            }
        } message: {
            Text("선택한 폴더 안의 모든 파일과 하위 폴더도 함께 삭제됩니다.")
        }
        .onChange(of: model.needsUSBFolderDeletionConfirmation) { _, showing in
            model.isShowingSettingsConfirmation = showing
        }
        .onDisappear {
            model.cancelUSBFolderDeletion()
            model.isShowingSettingsConfirmation = false
        }
    }

    private var fileExplorerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("저장장치 파일 탐색")
                    .font(.headline)
                Spacer()
                Button {
                    Task { await model.refreshStorageFiles() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("파일 목록 새로 고침")
                .disabled(!model.hasUSBDestination || isBusy)
            }

            Label(storagePathText, systemImage: "folder.fill")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if !model.storageRelativePath.isEmpty {
                Button {
                    Task { await model.openParentStorageDirectory() }
                } label: {
                    Label("상위 폴더", systemImage: "arrow.up.to.line")
                }
                .buttonStyle(.bordered)
                .disabled(isBusy)
            }

            if model.isLoadingStorageFiles {
                ProgressView("파일 목록 확인 중")
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 16)
            } else if !model.hasUSBDestination {
                Text("위에서 SD/USB 폴더를 먼저 선택하세요.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else if model.storageEntries.isEmpty && model.storageExplorerError == nil {
                Text("이 폴더에는 표시할 파일이 없습니다.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(model.storageEntries) { entry in
                        storageEntryRow(entry)
                        if entry.id != model.storageEntries.last?.id {
                            Divider()
                        }
                    }
                }
            }

            if let error = model.storageExplorerError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.red)
            }
            if let message = model.storageExplorerMessage {
                Label(message, systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.green)
            }

            Divider()
            HStack {
                Text("선택 \(model.selectedStorageFileCount)개")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(storageByteText(model.selectedStorageFileBytes))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button(model.areAllVisibleStorageEntriesSelected ? "선택 해제" : "모두 선택") {
                    model.toggleAllVisibleStorageEntries()
                }
                .buttonStyle(.bordered)
                .disabled(model.storageEntries.isEmpty || isBusy)

                Button {
                    chooseStorageRecipient()
                } label: {
                    Label("PC로 전송", systemImage: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("storage-file-send")
                .disabled(!model.hasSelectedStorageFilesForTransfer || isBusy)

                Button("삭제", role: .destructive) {
                    isConfirmingSelectedDeletion = true
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("storage-entry-delete")
                .disabled(!model.hasStorageFileSelection || isBusy)
            }

            if model.isSendingStorageFiles {
                ProgressView("선택 파일 전송 준비 중")
            } else if model.isDeletingStorageFiles {
                ProgressView("선택한 항목 삭제 중")
            } else if let message = transferModel.manualTransferMessage {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle((transferModel.lastManualSummary?.failed ?? 0) > 0 ? Color.red : Color.secondary)
            }
        }
        .cardStyle()
    }

    @ViewBuilder
    private func storageEntryRow(_ entry: USBStorageFileEntry) -> some View {
        HStack(spacing: 8) {
            Button {
                model.toggleStorageEntrySelection(entry.relativePath)
            } label: {
                Image(systemName: model.selectedStorageFilePaths.contains(entry.relativePath)
                    ? "checkmark.circle.fill"
                    : "circle")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 26)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(entry.name) 선택")

            Button {
                if entry.kind == .directory {
                    Task { await model.openStorageDirectory(entry) }
                } else {
                    model.toggleStorageEntrySelection(entry.relativePath)
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: entry.kind == .directory ? "folder.fill" : "doc.fill")
                        .foregroundStyle(entry.kind == .directory ? Color.cyan : Color.secondary)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.name)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text(entry.kind == .directory ? "폴더" : storageByteText(entry.size))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if entry.kind == .directory {
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 10)
        .accessibilityIdentifier("storage-entry-\(entry.relativePath)")
        .disabled(isBusy)
    }

    private var storagePathText: String {
        let root = model.usbDisplayName ?? "저장장치"
        return model.storageRelativePath.isEmpty
            ? root
            : "\(root) / \(model.storageRelativePath)"
    }

    private func storageByteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func chooseStorageRecipient() {
        guard !textModel.savedRecipients.isEmpty else {
            recipientError = "저장된 수신코드가 없습니다. 텍스트 송수신에서 컴퓨터 이름과 수신코드를 먼저 저장해 주세요."
            return
        }
        if let message = transferModel.fileTransferReadinessMessage {
            recipientError = message
            return
        }
        isChoosingStorageRecipient = true
    }

    private func sendStorageFiles(_ recipient: TextSavedRecipient) {
        Task {
            await textModel.selectRecipient(code: recipient.code)
            await model.sendSelectedStorageFiles(to: recipient.code) { urls, code in
                await transferModel.sendSelectedFiles(urls, recipientCode: code)
            }
        }
    }

    private var destinationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("선택한 저장장치 폴더")
                .font(.headline)
            Label(
                model.usbDisplayName ?? "USB 폴더 미선택",
                systemImage: model.isUSBAvailable == true
                    ? "externaldrive.fill.badge.checkmark"
                    : "externaldrive.badge.questionmark"
            )
            if let message = model.usbConnectionMessage {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(model.isUSBAvailable == false ? Color.orange : Color.secondary)
            }
            Label(
                "파일시스템(참고): \(model.usbFileSystemDescription ?? "저장장치가 형식 정보를 제공하지 않음")",
                systemImage: "info.circle"
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)

            HStack {
                Button(model.hasUSBDestination ? "폴더 다시 선택" : "USB 폴더 선택") {
                    model.isChoosingUSBFolder = true
                }
                .buttonStyle(.borderedProminent)

                if model.hasUSBDestination {
                    Button("선택 해제", role: .destructive) {
                        Task { await model.clearDestination() }
                    }
                    .buttonStyle(.bordered)
                }
            }
            .disabled(isBusy)
        }
        .cardStyle()
    }

    private var deletionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("저장장치 내용 삭제")
                .font(.headline)
            Text("SD 카드 전체를 비우려면 카드의 최상위 폴더를 선택하세요. 선택한 폴더 자체와 iPhone 원본은 유지됩니다.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button("선택한 저장장치 내용 전체 삭제", role: .destructive) {
                Task { await model.prepareUSBFolderDeletion() }
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("storage-delete-all")
            .disabled(!model.hasUSBDestination || isBusy)

            if model.isInspectingUSBFolderContents {
                ProgressView("삭제할 파일 확인 중")
            } else if model.isDeletingUSBFolderContents || model.usbFolderDeletionProgress != nil {
                FileDeletionProgressView(progress: model.usbFolderDeletionProgress, isRunning: model.isDeletingUSBFolderContents)
            }
            if let message = model.usbFolderDeletionMessage {
                Label(message, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            if let error = model.usbFolderDeletionError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            Text("삭제 전 파일·폴더 수와 용량을 다시 확인합니다. 확인 뒤 내용이나 저장장치가 바뀌면 삭제하지 않습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .cardStyle()
    }

    private var isBusy: Bool {
        model.isExportingToUSB
            || model.isPerformingReceive
            || model.isReceivingFile
            || model.isDeletingStoredFiles
            || model.isCleaningUSBFolder
            || model.isLoadingStorageFiles
            || model.isSendingStorageFiles
            || model.isDeletingStorageFiles
    }
}

private struct StorageFileRecipientPicker: View {
    let recipients: [TextSavedRecipient]
    let onSelect: (TextSavedRecipient) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(recipients) { recipient in
                Button {
                    onSelect(recipient)
                    dismiss()
                } label: {
                    HStack {
                        Image(systemName: "desktopcomputer")
                            .foregroundStyle(.cyan)
                        Text(recipient.name)
                        Spacer()
                        Text(recipient.code)
                            .font(.body.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.primary)
            }
            .navigationTitle("전송할 컴퓨터 선택")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                }
            }
        }
    }
}
