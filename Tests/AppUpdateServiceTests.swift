import XCTest
@testable import SimpleCameraAutoSender

final class AppUpdateServiceTests: XCTestCase {
    private let canonical = "https://github.com/hejong2-byte/simplecamera-auto-sender-ios/releases/download/v0.3.51/com.hejong2byte.simplecameraautosender.ipa"

    private func release(tag: String = "v0.3.51", draft: Bool = false,
                         prerelease: Bool = false, asset: String? = nil) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "tag_name": tag, "draft": draft, "prerelease": prerelease,
            "html_url": "https://github.com/hejong2-byte/simplecamera-auto-sender-ios/releases/tag/\(tag)",
            "assets": [["name": "com.hejong2byte.simplecameraautosender.ipa",
                         "browser_download_url": asset ?? canonical]],
            "body": "sidestore://install?url=https://evil.example/token.ipa"
        ])
    }

    func testNewerStableReleaseBuildsLocalSideStoreLink() throws {
        let update = try XCTUnwrap(AppUpdateService.parse(release(), currentVersion: "0.3.50"))
        XCTAssertEqual(update.version, "0.3.51")
        let link = try XCTUnwrap(URLComponents(url: update.installationURL, resolvingAgainstBaseURL: false))
        XCTAssertEqual(link.scheme, "sidestore")
        XCTAssertEqual(link.host, "install")
        XCTAssertEqual(link.queryItems, [URLQueryItem(name: "url", value: "https://github.com/hejong2-byte/simplecamera-auto-sender-ios/releases/latest/download/com.hejong2byte.simplecameraautosender.ipa")])
    }

    func testNumericVersionComparisonDoesNotCompareLexically() throws {
        XCTAssertNotNil(try AppUpdateService.parse(release(tag: "v0.3.51"), currentVersion: "0.3.9"))
        XCTAssertNil(try AppUpdateService.parse(release(), currentVersion: "0.3.51"))
        XCTAssertNil(try AppUpdateService.parse(release(), currentVersion: "0.4.0"))
    }

    func testDraftAndPrereleaseNeverOfferInstallation() throws {
        XCTAssertThrowsError(try AppUpdateService.parse(release(draft: true), currentVersion: "0.3.50")) {
            XCTAssertEqual($0 as? AppUpdateError, .invalidRelease)
        }
        XCTAssertThrowsError(try AppUpdateService.parse(release(prerelease: true), currentVersion: "0.3.50")) {
            XCTAssertEqual($0 as? AppUpdateError, .invalidRelease)
        }
    }

    func testMalformedReleaseAndVersionAreRejected() throws {
        for data in [Data("not json".utf8), try release(tag: "v0.3.51-beta"), try release(tag: "0.3"), try release(tag: "v999999999999999999999.3.51")] {
            XCTAssertThrowsError(try AppUpdateService.parse(data, currentVersion: "0.3.50")) {
                XCTAssertEqual($0 as? AppUpdateError, .invalidRelease)
            }
        }
        for current in ["0.3", "0.3.51-beta", "999999999999999999999.0.0", "invalid"] {
            XCTAssertThrowsError(try AppUpdateService.parse(release(), currentVersion: current)) {
                XCTAssertEqual($0 as? AppUpdateError, .invalidRelease)
            }
        }
    }

    func testHostileAssetCannotBecomeInstallRoute() throws {
        for url in ["https://evil.example/com.hejong2byte.simplecameraautosender.ipa",
                    canonical + "?token=secret", canonical.replacingOccurrences(of: "hejong2-byte", with: "attacker"),
                    canonical.replacingOccurrences(of: "v0.3.51", with: "v0.3.52"),
                    canonical.replacingOccurrences(of: "https:", with: "http:"),
                    canonical.replacingOccurrences(of: "github.com/", with: "github.com@evil.example/")] {
            XCTAssertThrowsError(try AppUpdateService.parse(release(asset: url), currentVersion: "0.3.50")) {
                XCTAssertEqual($0 as? AppUpdateError, .invalidRelease)
            }
        }
    }

    func testManualCheckUsesFixedRepositoryAndMapsHTTPFailure() async {
        let session = testSession { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.github.com/repos/hejong2-byte/simplecamera-auto-sender-ios/releases/latest")
            XCTAssertGreaterThan(request.timeoutInterval, 0)
            XCTAssertLessThanOrEqual(request.timeoutInterval, 30)
            return (503, Data())
        }
        defer { session.invalidateAndCancel() }
        do {
            _ = try await AppUpdateService(session: session).check(currentVersion: "0.3.50")
            XCTFail("HTTP failure must be visible")
        } catch { XCTAssertEqual(error as? AppUpdateError, .httpStatus(503)) }
    }

    func testTimeoutCanBeRetriedByAnotherExplicitCheck() async throws {
        var attempts = 0
        let data = try release()
        let session = testSession { _ in
            attempts += 1
            if attempts == 1 { throw URLError(.timedOut) }
            return (200, data)
        }
        defer { session.invalidateAndCancel() }
        do {
            _ = try await AppUpdateService(session: session).check(currentVersion: "0.3.50")
            XCTFail("Timeout must be visible")
        } catch { XCTAssertEqual(error as? AppUpdateError, .timeout) }
        let update = try await AppUpdateService(session: session).check(currentVersion: "0.3.50")
        XCTAssertEqual(update?.version, "0.3.51")
    }

    private func testSession(_ handler: @escaping (URLRequest) throws -> (Int, Data)) -> URLSession {
        UpdateURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class UpdateURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
