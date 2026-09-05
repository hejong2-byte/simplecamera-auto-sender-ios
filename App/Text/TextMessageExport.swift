import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum TextMessageExport {
    static func baseName(for message: TextStoredMessage) -> String {
        "SimpleCamera-text-\(message.envelope.id.uuidString.lowercased())"
    }

    static func makeTemporaryFile(
        for message: TextStoredMessage,
        in directory: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> URL {
        let targetDirectory = directory ?? fileManager.temporaryDirectory
            .appendingPathComponent("SimpleCameraTextShare", isDirectory: true)
        try fileManager.createDirectory(
            at: targetDirectory,
            withIntermediateDirectories: true
        )
        let url = targetDirectory.appendingPathComponent(
            "\(baseName(for: message)).txt"
        )
        try Data(message.envelope.text.utf8).write(to: url, options: .atomic)
        return url
    }
}

struct TextExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.text = text
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
