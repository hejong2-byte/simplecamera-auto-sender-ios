import Foundation

struct StorageCapacityCheck: Codable, Sendable, Equatable {
    let requiredBytes: Int64
    let availableBytes: Int64?
    let destination: IPhoneReceiveDestination

    var displayText: String {
        let location = destination == .usb ? "USB" : "iPhone"
        let required = Self.megabytes(requiredBytes)
        guard let availableBytes else { return "\(location) 필요 \(required) MB · 용량 정보 확인 불가" }
        return "\(location) 필요 \(required) MB · 사용 가능 \(Self.megabytes(availableBytes)) MB"
    }

    private static func megabytes(_ bytes: Int64) -> String {
        String(format: "%.2f", Double(max(0, bytes)) / 1_048_576)
    }
}

struct StorageCapacityInsufficient: LocalizedError {
    let check: StorageCapacityCheck
    var errorDescription: String? { "저장 공간이 부족합니다. \(check.displayText)" }
}

struct StorageCapacityPreflight {
    typealias Query = @Sendable (URL) throws -> Int64?

    static func system(_ url: URL) throws -> Int64? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
    }

    static func check(at url: URL, requiredBytes: Int64, destination: IPhoneReceiveDestination,
                      query: Query, report: (StorageCapacityCheck) -> Void) throws {
        let available = (try? query(url)).flatMap { $0 >= 0 ? $0 : nil }
        let check = StorageCapacityCheck(requiredBytes: max(0, requiredBytes), availableBytes: available,
                                         destination: destination)
        report(check)
        if let available, available < check.requiredBytes { throw StorageCapacityInsufficient(check: check) }
    }
}
