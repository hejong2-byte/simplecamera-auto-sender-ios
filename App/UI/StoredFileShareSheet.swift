import SwiftUI
import UIKit
import UniformTypeIdentifiers

extension IPhoneStoredFile {
    var supportsDirectSharing: Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image) || type.conforms(to: .pdf)
    }
}

struct StoredFileShareSheet: UIViewControllerRepresentable {
    let file: IPhoneStoredFile
    let onFinish: @MainActor (Error?) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        // Keep the original name and bytes; don't load a whole photo/PDF into memory.
        let controller = UIActivityViewController(activityItems: [file.url], applicationActivities: nil)
        controller.view.accessibilityIdentifier = "stored-file-share-sheet"
        controller.completionWithItemsHandler = { _, _, _, error in
            Task { @MainActor in onFinish(error) }
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
