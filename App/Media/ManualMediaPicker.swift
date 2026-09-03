import PhotosUI
import SwiftUI

enum ManualMediaKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case photo
    case screenshot
    case video
    case file = "kakao-file"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .photo: "사진 전송"
        case .screenshot: "스크린샷 전송"
        case .video: "동영상 전송"
        case .file: "카카오톡 파일전송"
        }
    }

    var systemImage: String {
        switch self {
        case .photo: "photo.on.rectangle.angled"
        case .screenshot: "rectangle.inset.filled"
        case .video: "video.fill"
        case .file: "doc.fill"
        }
    }

    var pickerFilter: PHPickerFilter? {
        switch self {
        case .photo: .images
        case .screenshot: .screenshots
        case .video: .videos
        case .file: nil
        }
    }
}

struct ManualMediaSelection: Sendable, Equatable {
    let assetIdentifiers: [String]
    let unavailableCount: Int
}

struct ManualMediaPicker: UIViewControllerRepresentable {
    let kind: ManualMediaKind
    let onSelection: (ManualMediaSelection) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = kind.pickerFilter
        configuration.selectionLimit = 0
        configuration.selection = .ordered
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(
        _ uiViewController: PHPickerViewController,
        context: Context
    ) {}

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let parent: ManualMediaPicker

        init(parent: ManualMediaPicker) {
            self.parent = parent
        }

        func picker(
            _ picker: PHPickerViewController,
            didFinishPicking results: [PHPickerResult]
        ) {
            guard !results.isEmpty else {
                parent.onCancel()
                return
            }
            let identifiers = results.compactMap(\.assetIdentifier)
            parent.onSelection(ManualMediaSelection(
                assetIdentifiers: identifiers,
                unavailableCount: results.count - identifiers.count
            ))
        }
    }
}
