import Foundation

protocol UploadCoordinating: Sendable {
    func upload(assetID: String, fileURL: URL) async throws
    func upload(
        assetID: String,
        fileURL: URL,
        metadata: ManualMediaUploadMetadata
    ) async throws
    func authenticationBlocked() -> Bool
    func credentialDidChange()
}

extension UploadCoordinating {
    func upload(
        assetID: String,
        fileURL: URL,
        metadata: ManualMediaUploadMetadata
    ) async throws {
        try await upload(assetID: assetID, fileURL: fileURL)
    }
}

protocol HTTPFileUploading: Sendable {
    func upload(
        for request: URLRequest,
        fromFile fileURL: URL
    ) async throws -> (Data, URLResponse)
}

enum UploadHTTPError: Error, Equatable {
    case invalidResponse
    case server(statusCode: Int)
}

enum ManualMediaUploadError: Error, Equatable {
    case fileTooLarge(maxBytes: Int64)
}

enum ManualMediaUploadLimit {
    static let maxBytes: Int64 = 2 * 1024 * 1024 * 1024
    static let singleRequestMaxBytes: Int64 = 95 * 1024 * 1024
    static let multipartPartBytes = 32 * 1024 * 1024
}

struct ManualMediaUploadPolicy: Sendable, Equatable {
    let maxBytes: Int64
    let singleRequestMaxBytes: Int64
    let multipartPartBytes: Int

    static let production = ManualMediaUploadPolicy(
        maxBytes: ManualMediaUploadLimit.maxBytes,
        singleRequestMaxBytes: ManualMediaUploadLimit.singleRequestMaxBytes,
        multipartPartBytes: ManualMediaUploadLimit.multipartPartBytes
    )
}

private struct MultipartStartResponse: Decodable {
    let uploadId: String?
    let complete: Bool?
}

private struct MultipartUploadedPart: Codable {
    let partNumber: Int
    let etag: String
}

private struct MultipartCompleteBody: Encodable {
    let parts: [MultipartUploadedPart]
}

private struct URLSessionFileUploader: HTTPFileUploading, @unchecked Sendable {
    let session: URLSession

    func upload(
        for request: URLRequest,
        fromFile fileURL: URL
    ) async throws -> (Data, URLResponse) {
        try await session.upload(for: request, fromFile: fileURL)
    }
}

final class BackgroundUploadCoordinator: UploadCoordinating, @unchecked Sendable {
    static let shared: BackgroundUploadCoordinator = {
        do {
            let ledger = try UploadLedger(fileURL: UploadLedger.defaultFileURL())
            return BackgroundUploadCoordinator(
                ledger: ledger,
                credentialStore: KeychainCredentialStore()
            )
        } catch {
            fatalError("업로드 장부를 열 수 없습니다.")
        }
    }()

    let ledger: UploadLedger
    private let credentialStore: CredentialStore
    private let transport: HTTPFileUploading
    private let requestFactory = RelayRequestFactory()
    private let manualUploadPolicy: ManualMediaUploadPolicy
    private let lock = NSLock()
    private var authenticationBlockedValue = false

    init(
        ledger: UploadLedger,
        credentialStore: CredentialStore,
        transport: HTTPFileUploading? = nil,
        manualUploadPolicy: ManualMediaUploadPolicy = .production
    ) {
        self.ledger = ledger
        self.credentialStore = credentialStore
        self.transport = transport ?? Self.makeTransport()
        self.manualUploadPolicy = manualUploadPolicy
    }

    func upload(assetID: String, fileURL: URL) async throws {
        guard !authenticationBlocked() else {
            throw UploadConfigurationError.authenticationBlocked
        }
        guard let credential = try credentialStore.load() else {
            throw UploadConfigurationError.missingCredential
        }

        let request = try requestFactory.makeUploadRequest(credential: credential)
        try await performUpload(
            assetID: assetID,
            fileURL: fileURL,
            request: request
        )
    }

    func upload(
        assetID: String,
        fileURL: URL,
        metadata: ManualMediaUploadMetadata
    ) async throws {
        guard !authenticationBlocked() else {
            throw UploadConfigurationError.authenticationBlocked
        }
        guard let credential = try credentialStore.load() else {
            throw UploadConfigurationError.missingCredential
        }
        let fingerprint = try UploadFileFingerprinter.fingerprint(fileURL: fileURL)
        guard fingerprint.size <= manualUploadPolicy.maxBytes else {
            throw ManualMediaUploadError.fileTooLarge(
                maxBytes: manualUploadPolicy.maxBytes
            )
        }
        if fingerprint.size <= manualUploadPolicy.singleRequestMaxBytes {
            let request = try requestFactory.makeManualMediaRequest(
                credential: credential,
                fingerprint: fingerprint,
                metadata: metadata
            )
            try await performUpload(
                assetID: assetID,
                fileURL: fileURL,
                request: request
            )
        } else {
            try await performMultipartUpload(
                assetID: assetID,
                fileURL: fileURL,
                credential: credential,
                fingerprint: fingerprint,
                metadata: metadata
            )
        }
    }

    private func performMultipartUpload(
        assetID: String,
        fileURL: URL,
        credential: String,
        fingerprint: UploadFileFingerprint,
        metadata: ManualMediaUploadMetadata
    ) async throws {
        try await ledger.markQueued(id: assetID, taskIdentifier: nil)
        let workingDirectory = fileURL.deletingLastPathComponent()
            .appendingPathComponent("Multipart-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workingDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: workingDirectory) }

        let emptyFile = workingDirectory.appendingPathComponent("empty")
        try Data().write(to: emptyFile)
        let startRequest = try requestFactory.makeMultipartStartRequest(
            credential: credential,
            fingerprint: fingerprint,
            metadata: metadata
        )
        let (startData, startResponse) = try await transport.upload(
            for: startRequest,
            fromFile: emptyFile
        )
        try validate(response: startResponse)
        let start = try JSONDecoder().decode(MultipartStartResponse.self, from: startData)
        if start.complete == true {
            try await ledger.markUploaded(id: assetID)
            try FileManager.default.removeItem(at: fileURL)
            return
        }
        guard let uploadID = start.uploadId, !uploadID.isEmpty else {
            throw UploadHTTPError.invalidResponse
        }

        do {
            let parts = try await uploadMultipartParts(
                fileURL: fileURL,
                workingDirectory: workingDirectory,
                credential: credential,
                fingerprint: fingerprint,
                uploadID: uploadID
            )
            let completeFile = workingDirectory.appendingPathComponent("complete.json")
            try JSONEncoder().encode(MultipartCompleteBody(parts: parts)).write(
                to: completeFile,
                options: .atomic
            )
            let completeRequest = try requestFactory.makeMultipartCompleteRequest(
                credential: credential,
                remoteID: fingerprint.remoteID,
                uploadID: uploadID
            )
            let (_, completeResponse) = try await transport.upload(
                for: completeRequest,
                fromFile: completeFile
            )
            try validate(response: completeResponse)
            try await ledger.markUploaded(id: assetID)
            try FileManager.default.removeItem(at: fileURL)
        } catch {
            await abortMultipartUpload(
                credential: credential,
                remoteID: fingerprint.remoteID,
                uploadID: uploadID,
                emptyFile: emptyFile
            )
            throw error
        }
    }

    private func uploadMultipartParts(
        fileURL: URL,
        workingDirectory: URL,
        credential: String,
        fingerprint: UploadFileFingerprint,
        uploadID: String
    ) async throws -> [MultipartUploadedPart] {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var partNumber = 1
        var parts: [MultipartUploadedPart] = []

        while true {
            let chunk = try handle.read(
                upToCount: manualUploadPolicy.multipartPartBytes
            ) ?? Data()
            guard !chunk.isEmpty else { break }
            let chunkFile = workingDirectory
                .appendingPathComponent("part-\(partNumber)")
            try chunk.write(to: chunkFile, options: .atomic)

            let request = try requestFactory.makeMultipartPartRequest(
                credential: credential,
                remoteID: fingerprint.remoteID,
                uploadID: uploadID,
                partNumber: partNumber,
                partSize: chunk.count
            )
            let (data, response) = try await transport.upload(
                for: request,
                fromFile: chunkFile
            )
            try validate(response: response)
            let part = try JSONDecoder().decode(MultipartUploadedPart.self, from: data)
            guard part.partNumber == partNumber, !part.etag.isEmpty else {
                throw UploadHTTPError.invalidResponse
            }
            parts.append(part)
            try? FileManager.default.removeItem(at: chunkFile)
            partNumber += 1
        }
        guard !parts.isEmpty else {
            throw UploadHTTPError.invalidResponse
        }
        return parts
    }

    private func abortMultipartUpload(
        credential: String,
        remoteID: String,
        uploadID: String,
        emptyFile: URL
    ) async {
        guard let request = try? requestFactory.makeMultipartAbortRequest(
            credential: credential,
            remoteID: remoteID,
            uploadID: uploadID
        ) else { return }
        _ = try? await transport.upload(for: request, fromFile: emptyFile)
    }

    private func performUpload(
        assetID: String,
        fileURL: URL,
        request: URLRequest
    ) async throws {
        try await ledger.markQueued(id: assetID, taskIdentifier: nil)
        let (_, response) = try await transport.upload(
            for: request,
            fromFile: fileURL
        )
        try validate(response: response)
        try await ledger.markUploaded(id: assetID)
        try FileManager.default.removeItem(at: fileURL)
    }

    private func validate(response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else {
            throw UploadHTTPError.invalidResponse
        }
        switch response.statusCode {
        case 200...299:
            return
        case 401, 403:
            lock.withLock { authenticationBlockedValue = true }
            throw UploadConfigurationError.authenticationBlocked
        default:
            throw UploadHTTPError.server(statusCode: response.statusCode)
        }
    }

    func authenticationBlocked() -> Bool {
        lock.withLock { authenticationBlockedValue }
    }

    func credentialDidChange() {
        lock.withLock { authenticationBlockedValue = false }
    }

    private static func makeTransport() -> HTTPFileUploading {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.httpMaximumConnectionsPerHost = 3
        return URLSessionFileUploader(
            session: URLSession(configuration: configuration)
        )
    }
}
