import Foundation

enum USBFolderAvailability {
    static func check(
        _ destination: USBBookmarkDestination,
        startAccessing: (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
        stopAccessing: (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }
    ) -> Bool {
        guard !destination.isStale, startAccessing(destination.url) else { return false }
        defer { stopAccessing(destination.url) }
        // Use a fresh metadata URL, inside the original URL's security scope.
        let url = URL(fileURLWithPath: destination.url.path, isDirectory: true)
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isReadableKey]) else {
            return false
        }
        return values.isDirectory == true && values.isReadable == true
    }
}
