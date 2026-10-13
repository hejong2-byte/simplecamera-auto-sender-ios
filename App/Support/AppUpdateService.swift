import Foundation

struct AppVersionInfo: Equatable {
    let version: String
    let build: String
    init(version: String, build: String) { self.version = version; self.build = build }
    init(bundle: Bundle = .main) {
        version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }
}

struct AppUpdate: Equatable {
    let version: String
    let installationURL: URL
}

enum AppUpdateError: Error, Equatable {
    case unimplemented
    case invalidRelease
    case httpStatus(Int)
    case timeout
    case network
}

struct AppUpdateService {
    let session: URLSession
    init(session: URLSession = .shared) { self.session = session }
    func check(currentVersion: String) async throws -> AppUpdate? { throw AppUpdateError.unimplemented }
    static func parse(_ data: Data, currentVersion: String) throws -> AppUpdate? {
        throw AppUpdateError.unimplemented
    }
}
