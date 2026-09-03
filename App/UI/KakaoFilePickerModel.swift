import Foundation

enum DocumentPickerRequest: Identifiable, Equatable {
    case folder(URL?)
    case files(URL)

    var id: String {
        switch self { case .folder: "folder"; case .files: "files" }
    }
    var directoryURL: URL? {
        switch self { case .folder(let url): url; case .files(let url): url }
    }
}

@MainActor
final class KakaoFilePickerModel: ObservableObject {
    @Published var request: DocumentPickerRequest?
    @Published var errorMessage: String?
    @Published private(set) var folderName: String?
    @Published private(set) var isDismissing = false
    private let store: KakaoFolderStore
    private var openFilesAfterFolder = false
    private var pendingDirectory: URL?

    init(store: KakaoFolderStore) {
        self.store = store
        folderName = (try? store.resolve())?.lastPathComponent
    }

    var isPresenting: Bool {
        request != nil || isDismissing || pendingDirectory != nil || errorMessage != nil
    }

    func beginFileSelection() {
        openFilesAfterFolder = true
        errorMessage = nil
        do {
            if let folder = try store.resolve() {
                folderName = folder.lastPathComponent
                request = .files(folder)
            } else {
                request = .folder(nil)
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func changeFolder() {
        openFilesAfterFolder = false
        errorMessage = nil
        request = .folder(try? store.resolve())
    }

    func reselectAfterError() {
        errorMessage = nil
        request = .folder(nil)
    }

    func accept(_ urls: [URL]) -> [URL] {
        guard let current = request else { return [] }
        guard !urls.isEmpty else { cancel(); return [] }
        request = nil
        isDismissing = true
        switch current {
        case .folder:
            do {
                let folder = urls[0]
                try store.save(folder)
                folderName = folder.lastPathComponent
                if openFilesAfterFolder { pendingDirectory = folder }
            } catch { errorMessage = error.localizedDescription }
            return []
        case .files:
            openFilesAfterFolder = false
            return urls
        }
    }

    func cancel() {
        isDismissing = request != nil
        request = nil
        pendingDirectory = nil
        openFilesAfterFolder = false
        errorMessage = nil
    }

    func didDismiss() {
        isDismissing = false
        if let folder = pendingDirectory {
            pendingDirectory = nil
            request = .files(folder)
        }
    }
}
