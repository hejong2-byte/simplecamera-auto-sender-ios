import Foundation
import XCTest
@testable import SimpleCameraAutoSender

final class IPhoneReceiveErrorMessageTests: XCTestCase {
    func testServerAuthenticationAndExpiryAreDistinct() {
        XCTAssertTrue(IPhoneReceiveErrorMessage.message(
            IPhoneReceiverClientError.server(statusCode: 503, code: "unavailable")
        ).contains("서버 오류"))
        XCTAssertTrue(IPhoneReceiveErrorMessage.message(
            IPhoneReceiverClientError.server(statusCode: 401, code: "unauthorized")
        ).contains("인증 오류"))
        XCTAssertTrue(IPhoneReceiveErrorMessage.message(
            IPhoneReceiverClientError.server(statusCode: 410, code: "delivery_expired")
        ).contains("보관 기한"))
    }

    func testNetworkSpaceIntegrityAndRegistrationAreDistinct() {
        XCTAssertTrue(IPhoneReceiveErrorMessage.message(
            URLError(.notConnectedToInternet)
        ).contains("네트워크 오류"))
        XCTAssertTrue(IPhoneReceiveErrorMessage.message(
            CocoaError(.fileWriteOutOfSpace)
        ).contains("저장 공간"))
        XCTAssertTrue(IPhoneReceiveErrorMessage.message(
            IPhoneLocalReceiveError.shaMismatch
        ).contains("무결성"))
        XCTAssertTrue(IPhoneReceiveErrorMessage.message(
            IPhoneLocalReceiveError.receiverNotRegistered
        ).contains("수신 기기"))
    }
}
