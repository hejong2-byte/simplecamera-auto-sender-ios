import Foundation
import XCTest
@testable import SimpleCameraAutoSender

@MainActor
final class USBReceiverReceiveStatusTests: XCTestCase {
    private let receiverID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let otherReceiverID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private let fixedNow = Date(timeIntervalSince1970: 1_788_000_000)

    func testIdleDoesNotEraseLastSavedOutcome() async throws {
        let saved = outcome(receiverID: receiverID, kind: .saved)
        let context = try makeContext(outcome: saved)

        await context.model.refresh()
        context.progress.publish(.idle)
        await waitUntil { context.model.receiveProgress?.stage == .idle }

        XCTAssertEqual(context.model.receiveStatus.kind, .saved)
        XCTAssertEqual(context.model.receiveStatus.fileName, saved.fileName)
        XCTAssertEqual(context.outcomes.latest, saved)
    }

    func testActiveProgressTemporarilyOverridesSavedOutcome() async throws {
        let saved = outcome(receiverID: receiverID, kind: .saved)
        let context = try makeContext(outcome: saved)
        await context.model.refresh()
        XCTAssertEqual(context.model.receiveStatus.kind, .saved)

        context.progress.publish(progress(
            stage: .downloading,
            destination: .iphoneLocal,
            deliveryID: UUID(),
            fileName: "새 업무자료.zip",
            bytesReceived: 50,
            totalBytes: 100
        ))
        await waitUntil { context.model.receiveStatus.kind == .active }

        XCTAssertEqual(context.model.receiveStatus.title, "iPhone 저장 중 · 1/1")
        XCTAssertEqual(context.model.receiveStatus.fileName, "새 업무자료.zip")
        XCTAssertEqual(context.model.receiveStatus.percent, 50)
        XCTAssertEqual(context.outcomes.latest, saved)
    }

    func testCompletionPersistsFileDestinationCountAndTime() async throws {
        let context = try makeContext()
        await context.model.refresh()

        context.progress.publish(progress(
            stage: .completed,
            destination: .iphoneLocal,
            deliveryID: UUID(),
            fileName: "완료.zip",
            totalCount: 3,
            completedCount: 3,
            bytesReceived: 300,
            totalBytes: 300
        ))
        await waitUntil { context.model.receiveStatus.kind == .saved }

        let saved = try XCTUnwrap(context.outcomes.latest)
        XCTAssertEqual(saved.receiverID, receiverID)
        XCTAssertEqual(saved.destination, .iphoneLocal)
        XCTAssertEqual(saved.fileName, "완료.zip")
        XCTAssertEqual(saved.totalCount, 3)
        XCTAssertEqual(saved.completedCount, 3)
        XCTAssertEqual(saved.message, "iPhone 저장 완료")
        XCTAssertEqual(saved.occurredAt, fixedNow)
    }

    func testFailurePersistsCategorizedMessageAndTime() async throws {
        let context = try makeContext()
        await context.model.refresh()

        context.progress.publish(progress(
            stage: .failed,
            destination: .iphoneLocal,
            deliveryID: nil,
            fileName: nil,
            errorMessage: "서버 오류: 연결할 수 없습니다."
        ))
        await waitUntil { context.model.receiveStatus.title == "새 파일 확인 오류" }
        XCTAssertEqual(context.model.receiveStatus.message, "서버 오류: 연결할 수 없습니다.")
        XCTAssertEqual(context.outcomes.latest?.occurredAt, fixedNow)

        context.progress.publish(progress(
            stage: .failed,
            destination: .usb,
            deliveryID: UUID(),
            fileName: "보고서.pdf",
            errorMessage: "USB 저장 공간을 확인해 주세요."
        ))
        await waitUntil { context.model.receiveStatus.title == "USB 수신 오류" }
        XCTAssertEqual(context.outcomes.latest?.destination, .usb)
        XCTAssertEqual(context.outcomes.latest?.fileName, "보고서.pdf")
        XCTAssertEqual(context.outcomes.latest?.message, "USB 저장 공간을 확인해 주세요.")
    }

    func testLaterSuccessReplacesPersistedFailure() async throws {
        let context = try makeContext()
        await context.model.refresh()
        context.progress.publish(progress(
            stage: .failed,
            destination: .iphoneLocal,
            deliveryID: nil,
            fileName: nil,
            errorMessage: "서버 오류"
        ))
        await waitUntil { context.outcomes.latest?.kind == .failed }

        context.progress.publish(progress(
            stage: .completed,
            destination: .iphoneLocal,
            deliveryID: UUID(),
            fileName: "복구.zip",
            completedCount: 1,
            bytesReceived: 10,
            totalBytes: 10
        ))
        await waitUntil { context.outcomes.latest?.kind == .saved }

        XCTAssertEqual(context.model.receiveStatus.kind, .saved)
        XCTAssertEqual(context.outcomes.latest?.fileName, "복구.zip")
    }

    func testRegistrationResetClearsTheMatchingOutcome() async throws {
        let context = try makeContext(outcome: outcome(receiverID: receiverID, kind: .saved))
        await context.model.refresh()
        XCTAssertEqual(context.model.receiveStatus.kind, .saved)

        await context.model.resetRegistration()

        XCTAssertNil(context.outcomes.latest)
        XCTAssertFalse(context.model.isRegistered)
        XCTAssertEqual(context.model.receiveStatus.kind, .waiting)
        XCTAssertEqual(context.model.receiveStatus.title, "수신 기기 등록 필요")
    }

    func testOutcomeFromAnotherReceiverIsNotPresented() async throws {
        let context = try makeContext(outcome: outcome(receiverID: otherReceiverID, kind: .failed))

        await context.model.refresh()

        XCTAssertEqual(context.outcomes.lastLoadedReceiverID, receiverID)
        XCTAssertEqual(context.model.receiveStatus.kind, .waiting)
        XCTAssertEqual(context.model.receiveStatus.title, "PC 파일 수신 대기")
    }

    private func makeContext(
        outcome: IPhoneReceiveOutcome? = nil
    ) throws -> (
        model: USBReceiverViewModel,
        progress: USBReceiveProgressStore,
        outcomes: ReceiveOutcomeHarness
    ) {
        let identityStore = InMemoryCredentialStore()
        let secretStore = InMemoryCredentialStore()
        let registrationStore = IPhoneReceiverRegistrationStore(
            identityStore: identityStore,
            secretStore: secretStore
        )
        try registrationStore.save(IPhoneReceiverRegistration(
            receiverID: receiverID,
            code: "123456",
            receiveSecret: "secret",
            deviceName: "테스트 iPhone"
        ))
        let progress = USBReceiveProgressStore()
        let outcomes = ReceiveOutcomeHarness(outcome)
        let directory = temporaryDirectory()
        let now = fixedNow
        let model = USBReceiverViewModel(
            uploadCredentialStore: InMemoryCredentialStore(),
            registrationStore: registrationStore,
            bookmarkStore: USBBookmarkStore(
                fileURL: directory.appendingPathComponent("destination.json")
            ),
            registrar: ReceiveStatusRegistrar(),
            receiveOnce: { USBReceiveSummary(discovered: 0, completed: 0) },
            progressUpdates: { progress.updates() },
            loadOutcome: { outcomes.load(receiverID: $0) },
            saveOutcome: { try outcomes.save($0) },
            clearOutcome: { try outcomes.clear(receiverID: $0) },
            now: { now },
            defaultDeviceName: "테스트 iPhone"
        )
        return (model, progress, outcomes)
    }

    private func outcome(
        receiverID: UUID,
        kind: IPhoneReceiveOutcomeKind
    ) -> IPhoneReceiveOutcome {
        IPhoneReceiveOutcome(
            receiverID: receiverID,
            kind: kind,
            destination: .iphoneLocal,
            fileName: "기존.zip",
            totalCount: 1,
            completedCount: kind == .saved ? 1 : 0,
            message: kind == .saved ? "iPhone 저장 완료" : "서버 오류",
            occurredAt: fixedNow.addingTimeInterval(-60)
        )
    }

    private func progress(
        stage: USBReceiveStage,
        destination: IPhoneReceiveDestination,
        deliveryID: UUID?,
        fileName: String?,
        totalCount: Int = 1,
        completedCount: Int = 0,
        bytesReceived: Int64 = 0,
        totalBytes: Int64 = 0,
        errorMessage: String? = nil
    ) -> USBReceiveProgress {
        USBReceiveProgress(
            stage: stage,
            destination: destination,
            deliveryID: deliveryID,
            fileName: fileName,
            currentIndex: totalCount > 0 ? 1 : 0,
            totalCount: totalCount,
            completedCount: completedCount,
            bytesReceived: bytesReceived,
            totalBytes: totalBytes,
            startedAt: fixedNow.addingTimeInterval(-10),
            expiresAt: fixedNow.addingTimeInterval(3_600),
            errorMessage: errorMessage
        )
    }

    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<300 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("수신 상태가 시간 안에 반영되지 않았습니다.")
    }
}

private actor ReceiveStatusRegistrar: IPhoneReceiverRegistering {
    func register(
        uploadCredential: String,
        deviceName: String
    ) async throws -> IPhoneReceiverRegistration {
        IPhoneReceiverRegistration(
            receiverID: UUID(),
            code: "654321",
            receiveSecret: "unused",
            deviceName: deviceName
        )
    }
}

private final class ReceiveOutcomeHarness: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: IPhoneReceiveOutcome?
    private var loadedReceiverID: UUID?

    init(_ outcome: IPhoneReceiveOutcome?) {
        self.outcome = outcome
    }

    var latest: IPhoneReceiveOutcome? {
        lock.withLock { outcome }
    }

    var lastLoadedReceiverID: UUID? {
        lock.withLock { loadedReceiverID }
    }

    func load(receiverID: UUID) -> IPhoneReceiveOutcome? {
        lock.withLock {
            loadedReceiverID = receiverID
            return outcome?.receiverID == receiverID ? outcome : nil
        }
    }

    func save(_ value: IPhoneReceiveOutcome) throws {
        lock.withLock { outcome = value }
    }

    func clear(receiverID: UUID) throws {
        lock.withLock {
            if outcome?.receiverID == receiverID { outcome = nil }
        }
    }
}
