import SwiftUI
import UIKit
import UniformTypeIdentifiers

extension IPhoneStoredFile {
    var supportsDirectSharing: Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image) || type.conforms(to: .pdf) || type.conforms(to: .zip)
    }
}

struct StoredFileShareSheet: UIViewControllerRepresentable {
    let files: [IPhoneStoredFile]
    let onFinish: @MainActor (Error?) -> Void

    init(file: IPhoneStoredFile, onFinish: @escaping @MainActor (Error?) -> Void) {
        self.files = [file]
        self.onFinish = onFinish
    }

    init(files: [IPhoneStoredFile], onFinish: @escaping @MainActor (Error?) -> Void) {
        self.files = files
        self.onFinish = onFinish
    }

    func makeUIViewController(context: Context) -> UIActivityViewController {
        // Share the original URL without loading the file or extracting ZIP contents.
        let controller = UIActivityViewController(activityItems: files.map(\.url), applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, error in
            Task { @MainActor in onFinish(error) }
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
