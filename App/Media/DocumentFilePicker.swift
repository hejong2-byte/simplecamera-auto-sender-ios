import SwiftUI
import UniformTypeIdentifiers

struct DocumentFilePicker: UIViewControllerRepresentable {
    let request: DocumentPickerRequest
    let onSelection: ([URL]) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let folderOnly: Bool
        switch request { case .folder: folderOnly = true; case .files: folderOnly = false }
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: folderOnly ? [.folder] : [.item], asCopy: false
        )
        picker.allowsMultipleSelection = !folderOnly
        picker.directoryURL = request.directoryURL
        picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIDocumentPickerViewController, context: Context) {}

    static func dismantleUIViewController(_ picker: UIDocumentPickerViewController, coordinator: Coordinator) {
        coordinator.endAccess()
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let parent: DocumentFilePicker
        private var scopedDirectory: URL?

        init(parent: DocumentFilePicker) {
            self.parent = parent
            if let url = parent.request.directoryURL, url.startAccessingSecurityScopedResource() {
                scopedDirectory = url
            }
        }

        deinit { scopedDirectory?.stopAccessingSecurityScopedResource() }
        func endAccess() {
            scopedDirectory?.stopAccessingSecurityScopedResource()
            scopedDirectory = nil
        }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            parent.onSelection(urls)
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { parent.onCancel() }
    }
}
