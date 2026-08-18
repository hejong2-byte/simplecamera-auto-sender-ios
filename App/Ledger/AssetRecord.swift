import Foundation

enum AssetState: String, Codable, Sendable {
    case discovered
    case ignored
    case queued
    case uploaded
    case failed
}

enum UploadErrorCategory: String, Codable, Sendable {
    case network
    case authentication
    case server
    case unreadable
    case unknown
}

struct AssetRecord: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let createdAt: Date
    var state: AssetState
    var taskIdentifier: Int?
    var retryCount: Int
    var lastError: UploadErrorCategory?
}
