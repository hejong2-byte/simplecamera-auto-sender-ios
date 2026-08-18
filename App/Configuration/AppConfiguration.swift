import Foundation

enum AppConfiguration {
    static let relayEndpoint = URL(
        string: "https://simplecamera-work-photo-relay.simplecamera-work-photo-relay.workers.dev/api/shortcut/photos"
    )!
    static let keychainService = AppIdentity.bundleIdentifier + ".relay"
    static let keychainAccount = "upload-authorization"
    static let backgroundSessionIdentifier = AppIdentity.bundleIdentifier + ".background-upload"
}
