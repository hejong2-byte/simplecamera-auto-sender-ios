#if DEBUG && targetEnvironment(simulator)
import Foundation

enum LiveStateCorruptionSimulation {
    static func seedIfRequested(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        fileManager: FileManager = .default
    ) {
        guard arguments.contains("--ui-test-corrupt-live-state"),
              let applicationSupport = try? fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
              ) else {
            return
        }
        let root = applicationSupport.appendingPathComponent(
            "SimpleCameraAutoSender",
            isDirectory: true
        )
        let receiver = root.appendingPathComponent("PCFileReceiver", isDirectory: true)
        let usb = root.appendingPathComponent("USBReceiver", isDirectory: true)
        let files = [
            root.appendingPathComponent("upload-ledger.json"),
            usb.appendingPathComponent("ledger.json"),
            receiver.appendingPathComponent("local-jobs.json"),
            receiver.appendingPathComponent("received-records.json"),
            receiver.appendingPathComponent("deletion-decisions.json")
        ]
        for fileURL in files {
            try? fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? Data("{not valid json".utf8).write(to: fileURL, options: .atomic)
        }
    }
}
#endif
