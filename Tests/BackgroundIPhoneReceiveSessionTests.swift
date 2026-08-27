import Foundation
import XCTest
@testable import SimpleCameraAutoSender

final class BackgroundIPhoneReceiveSessionTests: XCTestCase {
    func testDescriptorRoundTripKeepsDeliveryIdentity() throws {
        let descriptor = IPhoneReceiveTaskDescriptor(deliveryID: UUID())

        XCTAssertEqual(
            try IPhoneReceiveTaskDescriptor(
                taskDescription: descriptor.encodedTaskDescription()
            ),
            descriptor
        )
    }

    func testCompletionRegistryFinishesOnlyMatchingSession() {
        let registry = BackgroundSessionCompletionRegistry()
        var manual = 0
        var receive = 0
        registry.store(identifier: "manual") { manual += 1 }
        registry.store(identifier: "receive") { receive += 1 }

        registry.finish(identifier: "receive")

        XCTAssertEqual(manual, 0)
        XCTAssertEqual(receive, 1)
        registry.finish(identifier: "receive")
        XCTAssertEqual(receive, 1)
        registry.finish(identifier: "manual")
        XCTAssertEqual(manual, 1)
    }

    func testReceiveBackgroundIdentifierIsDistinctFromManualUpload() {
        XCTAssertNotEqual(
            AppConfiguration.receiverBackgroundSessionIdentifier,
            AppConfiguration.manualBackgroundSessionIdentifier
        )
    }
}
