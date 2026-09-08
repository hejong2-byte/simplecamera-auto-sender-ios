import SwiftUI

struct PendingIncomingSelectionView: View {
    @ObservedObject var model: IPhoneIncomingFilesViewModel
    @Environment(\.dismiss) private var dismiss
    let onConfirm: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let batch = model.selectionBatch {
                    List(batch.files, id: \.deliveryID) { file in
                        fileRow(file)
                    }
                    .listStyle(.plain)

                    controls
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("받을 파일 선택")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("나중에") { dismiss() }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pending-file-selection")
        .presentationDetents([.medium, .large])
    }

    private func fileRow(_ file: IPhoneDelivery) -> some View {
        let selected = model.selectedPendingFileIDs.contains(file.deliveryID)
        return Button {
            model.togglePendingFileSelection(file.deliveryID)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? Color.cyan : Color.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(file.fileName)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text(byteText(file.size))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text("도착 \(file.createdAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("보관 만료 \(file.expiresAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("pending-file-\(file.deliveryID.uuidString.lowercased())")
    }

    private var controls: some View {
        VStack(spacing: 12) {
            HStack {
                Button("전체 선택") { model.selectAllPendingFiles() }
                    .accessibilityIdentifier("pending-select-all")
                Spacer()
                Button("선택 해제") { model.clearPendingFileSelection() }
                    .accessibilityIdentifier("pending-clear-selection")
            }
            .buttonStyle(.bordered)

            HStack {
                Text("선택 \(model.selectedPendingFileIDs.count)개")
                Spacer()
                Text(byteText(model.pendingSelectionBytes))
                    .monospacedDigit()
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            Button("선택 파일 먼저 받기") {
                onConfirm()
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .disabled(model.selectedPendingFileIDs.isEmpty)
            .accessibilityIdentifier("pending-confirm-selection")
        }
        .padding()
        .background(.bar)
    }

    private func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(
            fromByteCount: max(0, bytes),
            countStyle: .file
        )
    }
}
