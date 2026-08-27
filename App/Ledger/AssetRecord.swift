import Foundation

enum AssetState: String, Codable, Sendable {
    case discovered
    case ignored
    case queued
    case uploaded
    case failed
}

enum UploadErrorCategory: String, Codable, Sendable, Hashable {
    case network
    case authentication
    case server
    case unreadable
    case unknown
}

extension Set where Element == UploadErrorCategory {
    var uploadFailureDescription: String? {
        let labels: [(UploadErrorCategory, String)] = [
            (.authentication, "인증 오류"),
            (.server, "서버 오류"),
            (.network, "네트워크 오류"),
            (.unreadable, "원본 읽기 오류"),
            (.unknown, "알 수 없는 오류"),
        ]
        let descriptions = labels.compactMap { category, label in
            contains(category) ? label : nil
        }
        return descriptions.isEmpty ? nil : descriptions.joined(separator: " · ")
    }
}

struct AssetRecord: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let createdAt: Date
    var state: AssetState
    var taskIdentifier: Int?
    var retryCount: Int
    var lastError: UploadErrorCategory?
}
