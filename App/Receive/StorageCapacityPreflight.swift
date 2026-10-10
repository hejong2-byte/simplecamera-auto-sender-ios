import Foundation

struct StorageCapacityCheck: Codable, Sendable, Equatable {
    let requiredBytes: Int64
    let availableBytes: Int64?
    let destination: IPhoneReceiveDestination

    var displayText: String { "" }
}

struct StorageCapacityPreflight {
    typealias Query = @Sendable (URL) throws -> Int64?

    static func system(_ url: URL) throws -> Int64? { nil }
}
