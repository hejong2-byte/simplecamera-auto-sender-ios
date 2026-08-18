import Foundation

enum UploadConfigurationError: Error, Equatable {
    case missingCredential
    case authenticationBlocked
}

struct RelayRequestFactory: Sendable {
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
}
