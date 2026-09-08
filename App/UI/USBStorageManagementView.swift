import SwiftUI
import UniformTypeIdentifiers

struct USBStorageManagementView: View {
    @ObservedObject var model: USBReceiverViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                destinationCard
                deletionCard
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("SD/USB 저장장치 관리")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.refresh() }
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
        .onChange(of: model.needsUSBFolderDeletionConfirmation) { _, showing in
            model.isShowingSettingsConfirmation = showing
        }
        .onDisappear {
            model.cancelUSBFolderDeletion()
            model.isShowingSettingsConfirmation = false
        }
    }

    private var destinationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("선택한 저장장치 폴더")
                .font(.headline)
            Label(
                model.usbDisplayName ?? "USB 폴더 미선택",
                systemImage: model.hasUSBDestination
                    ? "externaldrive.fill.badge.checkmark"
                    : "externaldrive.badge.questionmark"
            )
            Label(
                "파일시스템(참고): \(model.usbFileSystemDescription ?? "확인 불가")",
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
            } else if model.isDeletingUSBFolderContents {
                ProgressView("SD/USB 파일 삭제 중")
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
    }
}
