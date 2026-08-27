import Foundation

enum AppConfiguration {
    static let relayAPIBaseURL = URL(
        string: "https://simplecamera-work-photo-relay.simplecamera-work-photo-relay.workers.dev/api"
    )!
    static let relayEndpoint = URL(
        string: "https://simplecamera-work-photo-relay.simplecamera-work-photo-relay.workers.dev/api/shortcut/photos"
    )!

    static func manualMediaEndpoint(id: String) -> URL {
        relayAPIBaseURL
            .appendingPathComponent("photos", isDirectory: false)
            .appendingPathComponent(id, isDirectory: false)
    }

    static var manualMultipartEndpoint: URL {
        relayAPIBaseURL
            .appendingPathComponent("media", isDirectory: false)
            .appendingPathComponent("multipart", isDirectory: false)
    }

    static func manualMultipartEndpoint(
        id: String,
        suffix: [String] = [],
        uploadID: String? = nil
    ) -> URL {
        var url = manualMultipartEndpoint
            .appendingPathComponent(id, isDirectory: false)
        for component in suffix {
            url.appendPathComponent(component, isDirectory: false)
        }
        guard let uploadID else { return url }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "uploadId", value: uploadID)]
        return components.url!
    }

    static let keychainService = AppIdentity.bundleIdentifier + ".relay"
    static let keychainAccount = "upload-authorization"
    static let receiveSecretKeychainAccount = "iphone-receiver-secret"
    static let receiverIdentityKeychainAccount = "iphone-receiver-identity"
    static let backgroundSessionIdentifier = AppIdentity.bundleIdentifier + ".background-upload"
    static let manualBackgroundSessionIdentifier = AppIdentity.bundleIdentifier
        + ".manual-background-upload"
    static let receiverBackgroundSessionIdentifier = AppIdentity.bundleIdentifier
        + ".pc-file-receive"
}
