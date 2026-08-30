import XCTest
@testable import SimpleCameraAutoSender

final class IPhoneReceiveOutcomeStoreTests: XCTestCase {
    func testSavedOutcomeSurvivesStoreRecreation() throws {
        let url = location()
        let receiverID = UUID()
        let outcome = sampleOutcome(receiverID: receiverID, kind: .saved)

        try IPhoneReceiveOutcomeStore(fileURL: url).save(outcome)

        XCTAssertEqual(
            IPhoneReceiveOutcomeStore(fileURL: url).load(receiverID: receiverID),
            outcome
        )
    }

    func testOutcomeIsHiddenFromAnotherReceiver() throws {
        let url = location()
        let receiverID = UUID()
        try IPhoneReceiveOutcomeStore(fileURL: url).save(
            sampleOutcome(receiverID: receiverID, kind: .saved)
        )

        XCTAssertNil(IPhoneReceiveOutcomeStore(fileURL: url).load(receiverID: UUID()))
    }

    func testLaterSuccessReplacesFailure() throws {
        let url = location()
        let receiverID = UUID()
        let store = IPhoneReceiveOutcomeStore(fileURL: url)
        try store.save(sampleOutcome(receiverID: receiverID, kind: .failed))
        let success = sampleOutcome(receiverID: receiverID, kind: .saved)

        try store.save(success)

        XCTAssertEqual(store.load(receiverID: receiverID), success)
    }

    func testCorruptStatusFailsClosed() throws {
        let url = location()
        try Data("corrupt outcome data".utf8).write(to: url)

        XCTAssertNil(IPhoneReceiveOutcomeStore(fileURL: url).load(receiverID: UUID()))
    }

    func testClearOnlyRemovesMatchingReceiverOutcome() throws {
        let url = location()
        let receiverID = UUID()
        let otherReceiverID = UUID()
        let store = IPhoneReceiveOutcomeStore(fileURL: url)
        let outcome = sampleOutcome(receiverID: receiverID, kind: .saved)
        try store.save(outcome)

        try store.clear(receiverID: otherReceiverID)
        XCTAssertEqual(store.load(receiverID: receiverID), outcome)

        try store.clear(receiverID: receiverID)
        XCTAssertNil(store.load(receiverID: receiverID))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    private func sampleOutcome(
        receiverID: UUID,
        kind: IPhoneReceiveOutcomeKind
    ) -> IPhoneReceiveOutcome {
        IPhoneReceiveOutcome(
            receiverID: receiverID,
            kind: kind,
            destination: kind == .saved ? .iphoneLocal : .usb,
            fileName: kind == .saved ? "업무자료.zip" : "보고서.pdf",
            totalCount: kind == .saved ? 2 : 1,
            completedCount: kind == .saved ? 2 : 0,
            message: kind == .saved ? "iPhone 저장 완료" : "서버 연결 실패",
            occurredAt: Date(timeIntervalSince1970: kind == .saved ? 1_787_990_400 : 1_787_990_300)
        )
    }

    private func location() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root.appendingPathComponent("latest-receive-outcome.json")
    }
}
