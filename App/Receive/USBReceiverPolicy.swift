import Foundation

final class USBReceiverPreferences: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "usbReceiver.allowsCellular"
    private let destinationKey = "iphoneReceiver.destination"
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var allowsCellular: Bool {
        get { lock.withLock { defaults.bool(forKey: key) } }
        set { lock.withLock { defaults.set(newValue, forKey: key) } }
    }

    var selectedDestination: IPhoneReceiveDestination {
        get {
            lock.withLock {
                guard let value = defaults.string(forKey: destinationKey),
                      let destination = IPhoneReceiveDestination(rawValue: value) else {
                    return .iphoneLocal
                }
                return destination
            }
        }
        set {
            lock.withLock { defaults.set(newValue.rawValue, forKey: destinationKey) }
        }
    }
}

enum USBReceiverNetworkPolicy {
    static func configuration(allowsCellular: Bool) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.allowsCellularAccess = allowsCellular
        configuration.allowsExpensiveNetworkAccess = allowsCellular
        configuration.allowsConstrainedNetworkAccess = true
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = 300
        return configuration
    }
}

final class PolicyIPhoneReceiverTransport: IPhoneReceiverTransport, @unchecked Sendable {
    private let preferences: USBReceiverPreferences
    private let wifiOnlySession: URLSession
    private let cellularSession: URLSession

    init(preferences: USBReceiverPreferences) {
        self.preferences = preferences
        wifiOnlySession = URLSession(
            configuration: USBReceiverNetworkPolicy.configuration(
                allowsCellular: false
            )
        )
        cellularSession = URLSession(
            configuration: USBReceiverNetworkPolicy.configuration(
                allowsCellular: true
            )
        )
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let session = preferences.allowsCellular ? cellularSession : wifiOnlySession
        return try await session.data(for: request)
    }
}

enum USBVolumePolicy {
    static func validate(fileSize: Int64, formatDescription: String?) throws {
        let format = formatDescription?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        let isFAT32 = format.contains("fat32")
            || format.contains("ms-dos")
            || format == "fat"
        if isFAT32 && fileSize > Int64(UInt32.max) {
            throw USBReceiveServiceError.fat32FileTooLarge
        }
    }
}
