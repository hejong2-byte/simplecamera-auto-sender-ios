import SwiftUI

struct ZIPContentsSelectionView: View {
    @ObservedObject var model: USBReceiverViewModel
    let file: IPhoneStoredFile

    var body: some View {
        NavigationStack {
            List {
                if model.isLoadingZIPContents {
                    ProgressView("ZIP 내용 확인 중")
                } else if let error = model.zipContentsError {
                    Text(error).foregroundStyle(.red)
                } else {
                    Section(file.name) {
                        Button("모두 선택") { model.selectAllZIPEntries() }
                            .accessibilityIdentifier("zip-contents-select-all")
                        ForEach(model.zipEntries) { entry in
                            Button { model.toggleZIPEntry(entry) } label: {
                                HStack {
                                    Image(systemName: model.selectedZIPPaths.contains(entry.path) ? "checkmark.circle.fill" : "circle")
                                    Image(systemName: entry.isDirectory ? "folder" : "doc")
                                    Text(entry.path).foregroundStyle(.primary)
                                    Spacer()
                                    if !entry.isDirectory {
                                        Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .accessibilityIdentifier("zip-entry-\(entry.path)")
                        }
                    }
                }
            }
            .navigationTitle("ZIP 내용 선택")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { model.zipContentsFile = nil }
                        .accessibilityIdentifier("zip-contents-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("USB로 추출") { Task { await model.exportSelectedZIPContents() } }
                        .disabled(model.isLoadingZIPContents || model.selectedZIPPaths.isEmpty)
                        .accessibilityIdentifier("zip-contents-export")
                }
            }
        }
    }
}
