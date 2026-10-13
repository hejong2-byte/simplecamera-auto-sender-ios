import Foundation

struct DiagnosticsSnapshot {
    let app: AppVersionInfo
    let receive: USBReceiveProgress?
    let manual: ManualTransferProgress?
    let capturedAt: Date
    let copy: USBReceiveProgress?
    let copyCheckpointAt: Date?
    let receiveOutcomeAt: Date?

    init(app: AppVersionInfo, receive: USBReceiveProgress?, manual: ManualTransferProgress?,
         capturedAt: Date, copy: USBReceiveProgress? = nil, copyCheckpointAt: Date? = nil,
         receiveOutcomeAt: Date? = nil) {
        self.app = app
        self.receive = receive
        self.manual = manual
        self.capturedAt = capturedAt
        self.copy = copy
        self.copyCheckpointAt = copyCheckpointAt
        self.receiveOutcomeAt = receiveOutcomeAt
    }
}

struct DiagnosticsReportFile {
    let url: URL
    let directory: URL
}

enum DiagnosticsReportError: Error { case invalidTemporaryReport }

struct DiagnosticsReportService {
    let temporaryRoot: URL
    init(temporaryRoot: URL = FileManager.default.temporaryDirectory) { self.temporaryRoot = temporaryRoot }
    func encode(_ snapshot: DiagnosticsSnapshot) throws -> Data {
        var operations: [[String: Any]] = []
        if let receive = snapshot.receive {
            var value = receiveValues(receive, operation: "receive")
            if let date = snapshot.receiveOutcomeAt { value["outcomeAt"] = date.timeIntervalSince1970 }
            operations.append(value)
        }
        if let copy = snapshot.copy {
            var value = receiveValues(copy, operation: "usbCopy")
            if let date = snapshot.copyCheckpointAt { value["checkpointAt"] = date.timeIntervalSince1970 }
            operations.append(value)
        }
        if let manual = snapshot.manual {
            var value: [String: Any] = ["operation": "manual", "stage": manual.stage.rawValue,
                "totalCount": manual.selectedCount, "currentIndex": manual.currentIndex,
                "completedCount": manual.uploadedCount, "failedCount": manual.failedCount,
                "bytesCompleted": manual.displayedBytesSent, "totalBytes": manual.totalBytes,
                "retryAttempt": manual.retryAttempt, "errorPresent": manual.failure != nil]
            if case .server(let status, _) = manual.failure, (100...599).contains(status) {
                value["httpStatus"] = status
            }
            operations.append(value)
        }
        return try JSONSerialization.data(withJSONObject: ["version": snapshot.app.version,
            "build": snapshot.app.build, "capturedAt": snapshot.capturedAt.timeIntervalSince1970,
            "operations": operations], options: [.prettyPrinted, .sortedKeys])
    }

    private func receiveValues(_ progress: USBReceiveProgress, operation: String) -> [String: Any] {
        var value: [String: Any] = ["operation": operation, "stage": progress.stage.rawValue,
            "currentIndex": progress.currentIndex, "totalCount": progress.totalCount,
            "completedCount": progress.completedCount, "bytesCompleted": progress.bytesReceived,
            "totalBytes": progress.totalBytes, "errorPresent": progress.errorMessage != nil]
        if let date = progress.startedAt { value["startedAt"] = date.timeIntervalSince1970 }
        if let message = progress.errorMessage, let safe = safeError(message) {
            value["errorDomain"] = safe.domain
            value["errorCode"] = safe.code
        }
        return value
    }

    private func safeError(_ message: String) -> (domain: String, code: Int)? {
        let provider = "저장 위치에 접근할 수 없습니다. USB·SD 연결을 확인하고 폴더를 다시 선택해 주세요. (NSFileProviderErrorDomain · -2001)"
        if message == provider { return ("NSFileProviderErrorDomain", -2001) }
        let networkPattern = "^네트워크 오류 · 인터넷 연결을 확인해 주세요\\. \\((-?[0-9]+)\\)$"
        if let code = errorCode(message, pattern: networkPattern) { return (NSURLErrorDomain, code) }
        let domains = ["NSURLErrorDomain", "NSCocoaErrorDomain", "NSPOSIXErrorDomain", "NSFileProviderErrorDomain"]
        for domain in domains {
            for pattern in ["^Error Domain=\(domain) Code=(-?[0-9]+)(?:\\s|$)",
                            "^\(domain) · (-?[0-9]+)$",
                            "^수신 오류 \\(\(domain) · (-?[0-9]+)\\) · 연결과 저장 위치를 확인해 주세요\\.$"] {
                if let code = errorCode(message, pattern: pattern) { return (domain, code) }
            }
        }
        return nil
    }

    private func errorCode(_ message: String, pattern: String) -> Int? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
              let range = Range(match.range(at: 1), in: message) else { return nil }
        return Int(message[range])
    }

    func create(_ snapshot: DiagnosticsSnapshot) throws -> DiagnosticsReportFile {
        let data = try encode(snapshot)
        let directory = temporaryRoot.appendingPathComponent("SimpleCamera-Diagnostics-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("diagnostics.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do { try data.write(to: url, options: .atomic) }
        catch { try? FileManager.default.removeItem(at: directory); throw error }
        return DiagnosticsReportFile(url: url, directory: directory)
    }

    func cleanup(_ report: DiagnosticsReportFile) throws {
        let root = temporaryRoot.standardizedFileURL.resolvingSymlinksInPath()
        let directory = report.directory.standardizedFileURL.resolvingSymlinksInPath()
        let prefix = "SimpleCamera-Diagnostics-"
        guard directory.deletingLastPathComponent() == root,
              directory.lastPathComponent.hasPrefix(prefix),
              UUID(uuidString: String(directory.lastPathComponent.dropFirst(prefix.count))) != nil,
              report.url.standardizedFileURL.resolvingSymlinksInPath() == directory.appendingPathComponent("diagnostics.json") else {
            throw DiagnosticsReportError.invalidTemporaryReport
        }
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }
}
