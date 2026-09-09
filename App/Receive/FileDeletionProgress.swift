import Foundation

struct FileDeletionProgress: Sendable, Equatable {
    let totalCount: Int
    let processedCount: Int
    let failedCount: Int
    let currentName: String?

    var percent: Int {
        guard totalCount > 0 else { return 0 }
        return min(100, max(0, Int(Double(processedCount) / Double(totalCount) * 100)))
    }
}
