import XCTest
@testable import SimpleCameraAutoSender

final class IPhoneIncomingFilePolicyTests: XCTestCase {
    func testInProgressAndVerifiedLocalFilesDoNotAskForAnotherDestination() {
        let stages: [IPhoneLocalReceiveStage] = [
            .scheduled, .downloading, .downloaded, .verifying,
            .finalizing, .ackPending, .completed
        ]
        for stage in stages {
            XCTAssertFalse(IPhoneIncomingFilePolicy.needsNewDecision(
                localStage: stage, usbState: nil, hasStoredRecord: false
            ), "Already handled local stage: \(stage)")
        }
    }

    func testVerifiedUSBCopyWaitingForACKDoesNotAskToDownloadAgain() {
        for state: USBReceiveState in [.ackPending, .completed] {
            XCTAssertFalse(IPhoneIncomingFilePolicy.needsNewDecision(
                localStage: nil, usbState: state, hasStoredRecord: false
            ))
        }
    }

    func testCatalogRecordPreventsReofferEvenIfJobRecordIsUnavailable() {
        XCTAssertFalse(IPhoneIncomingFilePolicy.needsNewDecision(
            localStage: nil, usbState: nil, hasStoredRecord: true
        ))
    }

    func testNewAndFailedReceiptsRemainSelectable() {
        XCTAssertTrue(IPhoneIncomingFilePolicy.needsNewDecision(
            localStage: nil, usbState: nil, hasStoredRecord: false
        ))
        XCTAssertTrue(IPhoneIncomingFilePolicy.needsNewDecision(
            localStage: .failed, usbState: .failed, hasStoredRecord: false
        ))
        // Interrupted USB work still needs a usable destination on next launch.
        for state: USBReceiveState in [.downloading, .verifying, .finalizing] {
            XCTAssertTrue(IPhoneIncomingFilePolicy.needsNewDecision(
                localStage: nil, usbState: state, hasStoredRecord: false
            ))
        }
    }
}
