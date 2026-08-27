import Foundation
import XCTest
@testable import SimpleCameraAutoSender

final class ManualRetryPolicyTests: XCTestCase {
    private let policy = ManualRetryPolicy()

    func testRetriesTemporaryNetworkAndApprovedHTTPFailures() {
        XCTAssertTrue(policy.shouldRetry(error: URLError(.timedOut), response: nil, attempt: 0))
        for statusCode in [408, 425, 429, 500] {
            XCTAssertTrue(policy.shouldRetry(
                error: nil,
                response: response(statusCode),
                attempt: 0
            ))
        }
    }

    func testDoesNotRetryAuthenticationIntegrityOrExhaustedAttempts() {
        for statusCode in [401, 403, 422] {
            XCTAssertFalse(policy.shouldRetry(
                error: nil,
                response: response(statusCode),
                attempt: 0
            ))
        }
        XCTAssertFalse(policy.shouldRetry(
            error: URLError(.timedOut),
            response: nil,
            attempt: 3
        ))
        XCTAssertFalse(policy.shouldRetry(
            error: NSError(domain: "Permanent", code: 1),
            response: nil,
            attempt: 0
        ))
    }

    func testUsesOneThreeNineSecondBackoff() {
        XCTAssertEqual([0, 1, 2].map(policy.delaySeconds), [1, 3, 9])
    }

    private func response(_ statusCode: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://relay.example")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
    }
}
