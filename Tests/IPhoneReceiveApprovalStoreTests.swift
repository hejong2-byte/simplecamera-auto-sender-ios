import XCTest
@testable import SimpleCameraAutoSender

final class IPhoneReceiveApprovalStoreTests: XCTestCase {
    func testUnseenFilesAreNotApproved() throws {
        let store = IPhoneReceiveApprovalStore(fileURL: location())
        XCTAssertTrue(try store.destinations(receiverID: UUID()).isEmpty)
    }

    func testApprovedBatchAndDestinationSurviveReopening() throws {
        let url = location()
        let receiver = UUID()
        let ids = Set((0..<10).map { _ in UUID() })
        let store = IPhoneReceiveApprovalStore(fileURL: url)
        try store.approve(ids, receiverID: receiver, destination: .usb)

        let reopened = IPhoneReceiveApprovalStore(fileURL: url)
        XCTAssertEqual(try reopened.destinations(receiverID: receiver), Dictionary(uniqueKeysWithValues: ids.map { ($0, IPhoneReceiveDestination.usb) }))
    }

    func testChoicesDoNotCrossReceiversOrUnrelatedFiles() throws {
        let store = IPhoneReceiveApprovalStore(fileURL: location())
        let first = UUID()
        let second = UUID()
        let localID = UUID()
        let usbID = UUID()
        try store.approve([localID], receiverID: first, destination: .iphoneLocal)
        try store.approve([usbID], receiverID: first, destination: .usb)
        try store.approve([localID], receiverID: second, destination: .usb)

        XCTAssertEqual(try store.destinations(receiverID: first), [localID: .iphoneLocal, usbID: .usb])
        XCTAssertEqual(try store.destinations(receiverID: second), [localID: .usb])
        XCTAssertNil(try store.destinations(receiverID: first)[UUID()])
    }

    func testExplicitFallbackChangesOnlyTheChosenUSBIDs() throws {
        let store = IPhoneReceiveApprovalStore(fileURL: location())
        let receiver = UUID()
        let ids = [UUID(), UUID()]
        try store.approve(Set(ids), receiverID: receiver, destination: .usb)
        try store.approve([ids[0]], receiverID: receiver, destination: .iphoneLocal)

        XCTAssertEqual(try store.destinations(receiverID: receiver), [ids[0]: .iphoneLocal, ids[1]: .usb])
    }

    func testCorruptApprovalFileFailsClosedAndIsNotOverwritten() throws {
        let url = location()
        let broken = Data("corrupt approval data".utf8)
        try broken.write(to: url)
        let store = IPhoneReceiveApprovalStore(fileURL: url)

        XCTAssertThrowsError(try store.destinations(receiverID: UUID()))
        XCTAssertThrowsError(try store.approve([UUID()], receiverID: UUID(), destination: .usb))
        XCTAssertEqual(try Data(contentsOf: url), broken)
    }

    func testExplicitDestinationOverridesLegacyResumeIDs() throws {
        let store = IPhoneReceiveApprovalStore(fileURL: location())
        let receiver = UUID()
        let moved = UUID()
        let legacy = UUID()
        try store.approve([moved], receiverID: receiver, destination: .iphoneLocal)

        XCTAssertEqual(try store.allowedDeliveryIDs(receiverID: receiver, destination: .usb, resuming: [moved, legacy]), [legacy])
        XCTAssertEqual(try store.allowedDeliveryIDs(receiverID: receiver, destination: .iphoneLocal), [moved])
    }

    func testFailedPersistenceDoesNotApproveInMemory() throws {
        let root = location()
        try Data("not a directory".utf8).write(to: root)
        let store = IPhoneReceiveApprovalStore(fileURL: root.appendingPathComponent("approvals.json"))
        let receiver = UUID()
        XCTAssertTrue(try store.destinations(receiverID: receiver).isEmpty)

        XCTAssertThrowsError(try store.approve([UUID()], receiverID: receiver, destination: .usb))
        XCTAssertTrue(try store.destinations(receiverID: receiver).isEmpty)
    }

    private func location() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root.appendingPathComponent("approvals.json")
    }
}
