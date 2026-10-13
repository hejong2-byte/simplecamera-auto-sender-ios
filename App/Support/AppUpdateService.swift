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
    case invalidRelease
    case httpStatus(Int)
    case timeout
    case network
}

struct AppUpdateService {
    let session: URLSession
    init(session: URLSession = .shared) { self.session = session }
    func check(currentVersion: String) async throws -> AppUpdate? {
        let url = URL(string: "https://api.github.com/repos/hejong2-byte/simplecamera-auto-sender-ios/releases/latest")!
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw AppUpdateError.network }
            guard response.statusCode == 200 else { throw AppUpdateError.httpStatus(response.statusCode) }
            return try Self.parse(data, currentVersion: currentVersion)
        } catch let error as AppUpdateError {
            throw error
        } catch let error as URLError where error.code == .timedOut {
            throw AppUpdateError.timeout
        } catch {
            throw AppUpdateError.network
        }
    }
    static func parse(_ data: Data, currentVersion: String) throws -> AppUpdate? {
        struct Release: Decodable {
            struct Asset: Decodable { let name: String; let browser_download_url: String }
            let tag_name: String
            let draft: Bool
            let prerelease: Bool
            let assets: [Asset]
        }
        guard let release = try? JSONDecoder().decode(Release.self, from: data),
              !release.draft, !release.prerelease else { throw AppUpdateError.invalidRelease }
        let version = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
        guard let remote = components(version), let current = components(currentVersion) else {
            throw AppUpdateError.invalidRelease
        }
        let assetName = "com.hejong2byte.simplecameraautosender.ipa"
        let expected = "https://github.com/hejong2-byte/simplecamera-auto-sender-ios/releases/download/\(release.tag_name)/\(assetName)"
        guard release.assets.contains(where: { $0.name == assetName && $0.browser_download_url == expected }) else {
            throw AppUpdateError.invalidRelease
        }
        guard remote.lexicographicallyPrecedes(current) == false, remote != current else { return nil }
        var link = URLComponents()
        link.scheme = "sidestore"
        link.host = "install"
        link.queryItems = [URLQueryItem(name: "url", value: "https://github.com/hejong2-byte/simplecamera-auto-sender-ios/releases/latest/download/\(assetName)")]
        guard let url = link.url else { throw AppUpdateError.invalidRelease }
        return AppUpdate(version: version, installationURL: url)
    }

    private static func components(_ version: String) -> [Int]? {
        let pieces = version.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 3 else { return nil }
        var values: [Int] = []
        for piece in pieces {
            guard !piece.isEmpty, piece.utf8.allSatisfy({ (48...57).contains($0) }),
                  let value = Int(piece) else { return nil }
            values.append(value)
        }
        return values
    }
}
