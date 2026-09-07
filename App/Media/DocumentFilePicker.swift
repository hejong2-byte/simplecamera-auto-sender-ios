import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct DocumentSelectionAccess {
    let startAccessing: (URL) -> Bool
    let stopAccessing: (URL) -> Void

    static let system = DocumentSelectionAccess(
        startAccessing: { $0.startAccessingSecurityScopedResource() },
        stopAccessing: { $0.stopAccessingSecurityScopedResource() }
    )

    func acquire(_ urls: [URL]) -> DocumentSelectionLease {
        DocumentSelectionLease(
            accessedURLs: urls.filter(startAccessing),
            stopAccessing: stopAccessing
        )
    }
}

@MainActor
final class DocumentSelectionLease {
    private var accessedURLs: [URL]
    private let stopAccessing: (URL) -> Void

    init(accessedURLs: [URL], stopAccessing: @escaping (URL) -> Void) {
        self.accessedURLs = accessedURLs
        self.stopAccessing = stopAccessing
    }

    func release() {
        accessedURLs.forEach(stopAccessing)
        accessedURLs.removeAll()
    }
}

struct DocumentFilePicker: UIViewControllerRepresentable {
    let request: DocumentPickerRequest
    let selectionAccess: DocumentSelectionAccess
    let onSelection: ([URL]) async -> Void
    let onCancel: () -> Void

    init(
        request: DocumentPickerRequest,
        selectionAccess: DocumentSelectionAccess = .system,
        onSelection: @escaping ([URL]) async -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.request = request
        self.selectionAccess = selectionAccess
        self.onSelection = onSelection
        self.onCancel = onCancel
    }

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
            let lease = parent.selectionAccess.acquire(urls)
            Task { @MainActor [parent] in
                defer { lease.release() }
                await parent.onSelection(urls)
            }
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { parent.onCancel() }
    }
}
