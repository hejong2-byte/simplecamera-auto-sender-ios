import Foundation

enum UploadConfigurationError: Error, Equatable {
    case missingCredential
    case authenticationBlocked
}

struct ManualMediaUploadMetadata: Sendable, Equatable {
    let fileName: String
    let contentType: String
    let capturedAt: Date?
}

struct RelayRequestFactory: Sendable {
    private struct ErrorBody: Decodable {
        let error: String?
    }

    func makeUploadRequest(credential: String) throws -> URLRequest {
        let value = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw UploadConfigurationError.missingCredential
        }

        var request = URLRequest(url: AppConfiguration.relayEndpoint)
        request.httpMethod = "POST"
        request.setValue(value, forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        return request
    }

    func makeManualMediaRequest(
        credential: String,
        fingerprint: UploadFileFingerprint,
        metadata: ManualMediaUploadMetadata,
        fileTransfer: Bool = false
    ) throws -> URLRequest {
        let value = try normalizedCredential(credential)
        var request = URLRequest(
            url: AppConfiguration.manualMediaEndpoint(id: fingerprint.remoteID, fileTransfer: fileTransfer)
        )
        request.httpMethod = "PUT"
        request.setValue(value, forHTTPHeaderField: "Authorization")
        request.setValue(metadata.contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(fingerprint.sha256, forHTTPHeaderField: "X-Content-SHA256")
        request.setValue(String(fingerprint.size), forHTTPHeaderField: "X-File-Size")
        request.setValue(
            Self.encodedFileName(metadata.fileName),
            forHTTPHeaderField: "X-File-Name"
        )
        if let capturedAt = metadata.capturedAt {
            request.setValue(
                ISO8601DateFormatter().string(from: capturedAt),
                forHTTPHeaderField: "X-Captured-At"
            )
        }
        return request
    }

    func makeMultipartStartRequest(
        credential: String,
        fingerprint: UploadFileFingerprint,
        metadata: ManualMediaUploadMetadata,
        fileTransfer: Bool = false
    ) throws -> URLRequest {
        var request = URLRequest(url: fileTransfer ? AppConfiguration.manualFileMultipartEndpoint : AppConfiguration.manualMultipartEndpoint)
        request.httpMethod = "POST"
        applyManualHeaders(
            to: &request,
            credential: try normalizedCredential(credential),
            fingerprint: fingerprint,
            metadata: metadata
        )
        return request
    }

    func makeMultipartPartRequest(
        credential: String,
        remoteID: String,
        uploadID: String,
        partNumber: Int,
        partSize: Int,
        fileTransfer: Bool = false
    ) throws -> URLRequest {
        var request = URLRequest(url: AppConfiguration.manualMultipartEndpoint(
            id: remoteID,
            suffix: ["parts", String(partNumber)],
            uploadID: uploadID,
            fileTransfer: fileTransfer
        ))
        request.httpMethod = "PUT"
        request.setValue(
            try normalizedCredential(credential),
            forHTTPHeaderField: "Authorization"
        )
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(String(partSize), forHTTPHeaderField: "X-Part-Size")
        return request
    }

    func makeMultipartCompleteRequest(
        credential: String,
        remoteID: String,
        uploadID: String,
        fileTransfer: Bool = false
    ) throws -> URLRequest {
        var request = URLRequest(url: AppConfiguration.manualMultipartEndpoint(
            id: remoteID,
            suffix: ["complete"],
            uploadID: uploadID,
            fileTransfer: fileTransfer
        ))
        request.httpMethod = "POST"
        request.setValue(
            try normalizedCredential(credential),
            forHTTPHeaderField: "Authorization"
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    func makeMultipartAbortRequest(
        credential: String,
        remoteID: String,
        uploadID: String,
        fileTransfer: Bool = false
    ) throws -> URLRequest {
        var request = URLRequest(url: AppConfiguration.manualMultipartEndpoint(
            id: remoteID,
            uploadID: uploadID,
            fileTransfer: fileTransfer
        ))
        request.httpMethod = "DELETE"
        request.setValue(
            try normalizedCredential(credential),
            forHTTPHeaderField: "Authorization"
        )
        return request
    }

    func decodeErrorCode(from data: Data) -> String? {
        try? JSONDecoder().decode(ErrorBody.self, from: data).error
    }

    private func applyManualHeaders(
        to request: inout URLRequest,
        credential: String,
        fingerprint: UploadFileFingerprint,
        metadata: ManualMediaUploadMetadata
    ) {
        request.setValue(credential, forHTTPHeaderField: "Authorization")
        request.setValue(metadata.contentType, forHTTPHeaderField: "X-Media-Type")
        request.setValue(fingerprint.sha256, forHTTPHeaderField: "X-Content-SHA256")
        request.setValue(String(fingerprint.size), forHTTPHeaderField: "X-File-Size")
        request.setValue(
            Self.encodedFileName(metadata.fileName),
            forHTTPHeaderField: "X-File-Name"
        )
        if let capturedAt = metadata.capturedAt {
            request.setValue(
                ISO8601DateFormatter().string(from: capturedAt),
                forHTTPHeaderField: "X-Captured-At"
            )
        }
    }

    private func normalizedCredential(_ credential: String) throws -> String {
        let value = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw UploadConfigurationError.missingCredential
        }
        return value
    }

    private static func encodedFileName(_ fileName: String) -> String {
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        )
        return fileName.addingPercentEncoding(withAllowedCharacters: allowed) ?? "media"
    }
}
