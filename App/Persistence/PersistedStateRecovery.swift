import Foundation

enum PersistedStateRecovery {
    static func decodeOrRecover<Value: Decodable>(
        _ type: Value.Type,
        from fileURL: URL,
        fallback: @autoclosure () -> Value,
        fileManager: FileManager = .default
    ) -> Value {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return fallback()
        }
        do {
            return try JSONDecoder().decode(
                type,
                from: Data(contentsOf: fileURL)
            )
        } catch {
            quarantine(fileURL, fileManager: fileManager)
            return fallback()
        }
    }

    private static func quarantine(
        _ fileURL: URL,
        fileManager: FileManager
    ) {
        let suffix = "\(Int64(Date().timeIntervalSince1970 * 1_000))-\(UUID().uuidString)"
        let backupURL = fileURL.deletingLastPathComponent().appendingPathComponent(
            "\(fileURL.lastPathComponent).corrupt-\(suffix)"
        )
        do {
            try fileManager.moveItem(at: fileURL, to: backupURL)
        } catch {
            try? fileManager.copyItem(at: fileURL, to: backupURL)
        }
    }
}
