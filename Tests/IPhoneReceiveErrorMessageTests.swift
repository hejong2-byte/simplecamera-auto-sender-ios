import Foundation
import XCTest
@testable import SimpleCameraAutoSender

final class IPhoneReceiveErrorMessageTests: XCTestCase {
    func testUSBSizeMismatchIsNotPresentedAsSHAVerificationFailure() {
        let message = IPhoneReceiveErrorMessage.message(IPhoneUSBExportError.sizeMismatch)
        XCTAssertTrue(message.contains("파일 크기"))
        XCTAssertFalse(message.contains("무결성 검증"))
    }

    func testUnknownReceiveErrorKeepsItsDiagnosticCode() {
        let message = IPhoneReceiveErrorMessage.message(
            NSError(domain: NSCocoaErrorDomain, code: 260)
        )
        XCTAssertTrue(message.contains(NSCocoaErrorDomain))
        XCTAssertTrue(message.contains("260"))
    }

    func testLocalUSBCopyFailureDoesNotBlameTheNetwork() {
        let message = IPhoneReceiveErrorMessage.message(IPhoneUSBExportError.copyFailed)
        XCTAssertTrue(message.contains("USB 복사"))
        XCTAssertFalse(message.contains("네트워크"))
    }

    func testZIPExportErrorsExplainSafetyAndPreserveTheOriginal() {
        let unsafe = IPhoneReceiveErrorMessage.message(
            IPhoneUSBExportError.unsafeZIPArchive
        )
        let damaged = IPhoneReceiveErrorMessage.message(
            IPhoneUSBExportError.zipExtractionFailed
        )

        XCTAssertTrue(unsafe.contains("안전하지 않은 ZIP"))
        XCTAssertTrue(unsafe.contains("복사하지 않았습니다"))
        XCTAssertTrue(damaged.contains("압축 해제에 실패"))
        XCTAssertTrue(damaged.contains("원본은 유지"))
    }

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
