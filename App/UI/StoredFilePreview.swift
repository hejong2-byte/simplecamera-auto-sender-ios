import QuickLook
import SwiftUI

struct StoredFilePreview: UIViewControllerRepresentable {
    let file: IPhoneStoredFile
    let onClose: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(url: file.url, onClose: onClose) }

    func makeUIViewController(context: Context) -> UINavigationController {
        let preview = QLPreviewController()
        preview.dataSource = context.coordinator
        preview.delegate = context.coordinator
        let close = UIBarButtonItem(title: "닫기", style: .done, target: context.coordinator, action: #selector(Coordinator.close))
        close.accessibilityIdentifier = "stored-preview-close"
        preview.navigationItem.rightBarButtonItem = close
        return UINavigationController(rootViewController: preview)
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {}

    final class Coordinator: NSObject, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
        private let url: URL
        private let onClose: () -> Void

        init(url: URL, onClose: @escaping () -> Void) {
            self.url = url
            self.onClose = onClose
        }

        @objc func close() { onClose() }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
        func previewController(_ controller: QLPreviewController, editingModeFor previewItem: QLPreviewItem) -> QLPreviewItemEditingMode {
            .disabled
        }
    }
}
