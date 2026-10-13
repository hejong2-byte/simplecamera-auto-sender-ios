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

enum DiagnosticsReportError: Error { case unimplemented }

struct DiagnosticsReportService {
    let temporaryRoot: URL
    init(temporaryRoot: URL = FileManager.default.temporaryDirectory) { self.temporaryRoot = temporaryRoot }
    func encode(_ snapshot: DiagnosticsSnapshot) throws -> Data { throw DiagnosticsReportError.unimplemented }
    func create(_ snapshot: DiagnosticsSnapshot) throws -> DiagnosticsReportFile { throw DiagnosticsReportError.unimplemented }
    func cleanup(_ report: DiagnosticsReportFile) throws { throw DiagnosticsReportError.unimplemented }
}
