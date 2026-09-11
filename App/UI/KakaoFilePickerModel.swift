import Foundation

enum DocumentPickerRequest: Identifiable, Equatable {
    case folder(URL?)
    case files(URL?)

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
    private var activeRequest: DocumentPickerRequest?
    private var sheetDidDismiss = false

    init(store: KakaoFolderStore) {
        self.store = store
        folderName = (try? store.resolve())?.lastPathComponent
    }

    var isPresenting: Bool {
        request != nil || activeRequest != nil || isDismissing
            || pendingDirectory != nil || errorMessage != nil
    }

    func beginFileSelection() {
        openFilesAfterFolder = true
        errorMessage = nil
        do {
            if let folder = try store.resolve() {
                folderName = folder.lastPathComponent
                present(.files(folder))
            } else {
                present(.files(nil))
            }
        } catch {
            activeRequest = nil
            request = nil
            errorMessage = error.localizedDescription
        }
    }

    func changeFolder() {
        openFilesAfterFolder = false
        errorMessage = nil
        present(.folder(try? store.resolve()))
    }

    func reselectAfterError() {
        errorMessage = nil
        present(.folder(nil))
    }

    func accept(_ urls: [URL]) -> [URL] {
        guard let current = activeRequest ?? request else { return [] }
        guard !urls.isEmpty else { cancel(); return [] }
        let wasDismissed = sheetDidDismiss
        request = nil
        activeRequest = nil
        sheetDidDismiss = false
        isDismissing = !wasDismissed
        switch current {
        case .folder:
            do {
                let folder = urls[0]
                try store.save(folder)
                folderName = folder.lastPathComponent
                if openFilesAfterFolder {
                    if wasDismissed {
                        present(.files(folder))
                    } else {
                        pendingDirectory = folder
                    }
                }
            } catch { errorMessage = error.localizedDescription }
            return []
        case .files:
            openFilesAfterFolder = false
            return urls
        }
    }

    func cancel() {
        isDismissing = request != nil || activeRequest != nil
        request = nil
        activeRequest = nil
        sheetDidDismiss = false
        pendingDirectory = nil
        openFilesAfterFolder = false
        errorMessage = nil
    }

    func didDismiss() {
        isDismissing = false
        if activeRequest != nil {
            sheetDidDismiss = true
            return
        }
        if let folder = pendingDirectory {
            pendingDirectory = nil
            present(.files(folder))
        }
    }

    private func present(_ request: DocumentPickerRequest) {
        activeRequest = request
        sheetDidDismiss = false
        self.request = request
    }
}
