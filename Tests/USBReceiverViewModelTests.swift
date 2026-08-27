import Foundation
import XCTest
@testable import SimpleCameraAutoSender

@MainActor
final class USBReceiverViewModelTests: XCTestCase {
    func testFailedUSBCopyKeepsTheFailedFileSelectedForRetry() async throws {
        let file = try storedFile()
        let model = try exportModel(files: [file]) { _, _ in
            IPhoneUSBExportSummary(
                verified: [],
                failed: [IPhoneUSBExportFailure(
                    sourceID: file.id,
                    error: .destinationAccessDenied
                )]
            )
        }
        await model.refresh()
        model.toggleStoredFileSelection(file.id)

        await model.exportSelectedFilesToUSB()

        XCTAssertEqual(model.selectedStoredFileIDs, [file.id])
        XCTAssertFalse(model.needsDeletionDecision)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
    }

    func testSecondCopyPressCannotQueueADuplicateExport() async throws {
        let file = try storedFile()
        let calls = ReceiveCounter()
        let secondPress = ReceiveCounter()
        let gate = USBExportGate()
        let model = try exportModel(files: [file]) { _, _ in
            calls.increment()
            await gate.wait()
            return IPhoneUSBExportSummary(verified: [], failed: [])
        }
        await model.refresh()
        model.toggleStoredFileSelection(file.id)

        let first = Task { await model.exportSelectedFilesToUSB() }
        await waitUntil { calls.value == 1 }
        let second = Task {
            secondPress.increment()
            await model.exportSelectedFilesToUSB()
        }
        await waitUntil { secondPress.value == 1 }
        await gate.open()
        await first.value
        await second.value

        XCTAssertEqual(calls.value, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
    }

    func testReceiveDestinationDefaultsToIPhoneAndPersistsUSBChoice() {
        let suiteName = "USBReceiverViewModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = USBReceiverPreferences(defaults: defaults)
        XCTAssertEqual(first.selectedDestination, .iphoneLocal)
        first.selectedDestination = .usb

        XCTAssertEqual(
            USBReceiverPreferences(defaults: defaults).selectedDestination,
            .usb
        )
    }

    func testMissingUSBWithPendingDeliveryPromptsOnceAndLocalChoiceStartsReceive() async throws {
        let localCounter = ReceiveCounter()
        let pendingID = UUID()
        let preferences = isolatedPreferences()
        preferences.selectedDestination = .usb
        let model = USBReceiverViewModel(
            uploadCredentialStore: InMemoryCredentialStore(),
            registrationStore: IPhoneReceiverRegistrationStore(
                identityStore: InMemoryCredentialStore(),
                secretStore: InMemoryCredentialStore()
            ),
            bookmarkStore: USBBookmarkStore(
                fileURL: temporaryDirectory().appendingPathComponent("destination.json"),
                codec: ViewModelBookmarkCodec(url: temporaryDirectory())
            ),
            registrar: StubReceiverRegistrar(),
            receiveOnce: { throw USBReceiveServiceError.missingDestination },
            receiveLocalOnce: { localCounter.increment() },
            pendingDeliveryIDs: { [pendingID] },
            progressUpdates: { AsyncStream { $0.finish() } },
            defaultDeviceName: "iPhone",
            preferences: preferences
        )

        await model.pollOnce()
        XCTAssertEqual(model.selectedDestination, .usb)
        XCTAssertTrue(model.needsLocalFallbackDecision)

        await model.chooseLocalFallback()
        XCTAssertEqual(localCounter.value, 1)
        XCTAssertFalse(model.needsLocalFallbackDecision)

        await model.pollOnce()
        XCTAssertEqual(localCounter.value, 2)
        XCTAssertFalse(model.needsLocalFallbackDecision)
    }

    func testServerWaitDoesNotDownloadCurrentPendingSet() async throws {
        let usbCounter = ReceiveCounter()
        let localCounter = ReceiveCounter()
        let pendingID = UUID()
        let preferences = isolatedPreferences()
        preferences.selectedDestination = .usb
        let model = USBReceiverViewModel(
            uploadCredentialStore: InMemoryCredentialStore(),
            registrationStore: IPhoneReceiverRegistrationStore(
                identityStore: InMemoryCredentialStore(),
                secretStore: InMemoryCredentialStore()
            ),
            bookmarkStore: USBBookmarkStore(
                fileURL: temporaryDirectory().appendingPathComponent("destination.json"),
                codec: ViewModelBookmarkCodec(url: temporaryDirectory())
            ),
            registrar: StubReceiverRegistrar(),
            receiveOnce: {
                usbCounter.increment()
                throw USBReceiveServiceError.missingDestination
            },
            receiveLocalOnce: { localCounter.increment() },
            pendingDeliveryIDs: { [pendingID] },
            progressUpdates: { AsyncStream { $0.finish() } },
            defaultDeviceName: "iPhone",
            preferences: preferences
        )

        await model.pollOnce()
        await model.chooseServerWait()
        await model.pollOnce()

        XCTAssertEqual(usbCounter.value, 1)
        XCTAssertEqual(localCounter.value, 0)
        XCTAssertFalse(model.needsLocalFallbackDecision)
    }

    func testRegistrationDestinationAndProgressArePublishedWithoutPhotoPermission() async throws {
        let uploadCredential = InMemoryCredentialStore()
        try uploadCredential.save("Bearer upload")
        let registrationStore = IPhoneReceiverRegistrationStore(
            identityStore: InMemoryCredentialStore(),
            secretStore: InMemoryCredentialStore()
        )
        let directory = temporaryDirectory()
        let bookmarkStore = USBBookmarkStore(
            fileURL: temporaryDirectory().appendingPathComponent("destination.json"),
            codec: ViewModelBookmarkCodec(url: directory)
        )
        let progress = ReceiverProgressFeed()
        let model = USBReceiverViewModel(
            uploadCredentialStore: uploadCredential,
            registrationStore: registrationStore,
            bookmarkStore: bookmarkStore,
            registrar: StubReceiverRegistrar(),
            receiveOnce: { USBReceiveSummary(discovered: 0, completed: 0) },
            progressUpdates: { progress.stream },
            defaultDeviceName: "희종의 iPhone"
        )

        await model.refresh()
        XCTAssertEqual(model.receiveStageTitle, "PC 파일 수신 대기")
        XCTAssertFalse(model.isRegistered)
        XCTAssertFalse(model.hasUSBDestination)

        await model.registerDevice()
        XCTAssertEqual(model.registrationCode, "123456")
        XCTAssertEqual(model.deviceName, "희종의 iPhone")

        await model.selectDestination(directory)
        XCTAssertTrue(model.hasUSBDestination)
        XCTAssertEqual(model.usbDisplayName, directory.lastPathComponent)

        progress.yield(
            USBReceiveProgress(
                stage: .downloading,
                deliveryID: UUID(),
                fileName: "업무.zip",
                currentIndex: 1,
                totalCount: 2,
                completedCount: 0,
                bytesReceived: 50,
                totalBytes: 100,
                startedAt: Date().addingTimeInterval(-10),
                expiresAt: Date().addingTimeInterval(3_600),
                errorMessage: nil
            )
        )
        await waitUntil { model.receiveProgress?.percent == 50 }

        XCTAssertEqual(model.receiveStageTitle, "USB 저장 중 · 1/2")
        XCTAssertEqual(model.receivePercentText, "50%")
        XCTAssertTrue(model.receiveSpeedText.contains("/초"))

        progress.yield(
            USBReceiveProgress(
                stage: .verifying,
                deliveryID: UUID(),
                fileName: "업무.hwp",
                currentIndex: 1,
                totalCount: 2,
                completedCount: 0,
                bytesReceived: 100,
                totalBytes: 100,
                startedAt: Date().addingTimeInterval(-10),
                expiresAt: Date().addingTimeInterval(3_600),
                errorMessage: nil
            )
        )
        await waitUntil { model.receiveProgress?.stage == .verifying }
        XCTAssertEqual(model.receiveStageTitle, "파일·SHA 검증 중 · 1/2")
    }

    func testForegroundPollingStartsImmediatelyAndStopsCleanly() async throws {
        let counter = ReceiveCounter()
        let preferences = isolatedPreferences()
        preferences.selectedDestination = .usb
        let model = USBReceiverViewModel(
            uploadCredentialStore: InMemoryCredentialStore(),
            registrationStore: IPhoneReceiverRegistrationStore(
                identityStore: InMemoryCredentialStore(),
                secretStore: InMemoryCredentialStore()
            ),
            bookmarkStore: USBBookmarkStore(
                fileURL: temporaryDirectory().appendingPathComponent("destination.json"),
                codec: ViewModelBookmarkCodec(url: temporaryDirectory())
            ),
            registrar: StubReceiverRegistrar(),
            receiveOnce: {
                counter.increment()
                return USBReceiveSummary(discovered: 0, completed: 0)
            },
            progressUpdates: { AsyncStream { $0.finish() } },
            defaultDeviceName: "iPhone",
            preferences: preferences,
            sleep: { try await Task.sleep(for: .seconds(60)) }
        )

        model.startForegroundPolling()
        await waitUntil { counter.value > 0 }
        XCTAssertTrue(model.isPolling)

        model.stopForegroundPolling()
        XCTAssertFalse(model.isPolling)
    }

    private func storedFile() throws -> IPhoneStoredFile {
        let url = temporaryDirectory().appendingPathComponent("local.zip")
        let data = Data("unchanged-original".utf8)
        try data.write(to: url)
        return IPhoneStoredFile(
            id: url.path,
            url: url,
            name: url.lastPathComponent,
            size: Int64(data.count),
            modifiedAt: Date(),
            receivedRecord: nil
        )
    }

    private func exportModel(
        files: [IPhoneStoredFile],
        export: @escaping USBReceiverViewModel.ExportFiles
    ) throws -> USBReceiverViewModel {
        let usb = temporaryDirectory()
        let bookmarkStore = USBBookmarkStore(
            fileURL: temporaryDirectory().appendingPathComponent("destination.json"),
            codec: ViewModelBookmarkCodec(url: usb)
        )
        try bookmarkStore.save(folderURL: usb)
        return USBReceiverViewModel(
            uploadCredentialStore: InMemoryCredentialStore(),
            registrationStore: IPhoneReceiverRegistrationStore(
                identityStore: InMemoryCredentialStore(),
                secretStore: InMemoryCredentialStore()
            ),
            bookmarkStore: bookmarkStore,
            registrar: StubReceiverRegistrar(),
            receiveOnce: { USBReceiveSummary(discovered: 0, completed: 0) },
            storedFiles: { files },
            exportFiles: export,
            progressUpdates: { AsyncStream { $0.finish() } },
            defaultDeviceName: "iPhone",
            preferences: isolatedPreferences()
        )
    }

    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func isolatedPreferences() -> USBReceiverPreferences {
        let suiteName = "USBReceiverViewModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return USBReceiverPreferences(defaults: defaults)
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<300 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("수신 상태가 시간 안에 반영되지 않았습니다.")
    }
}

private actor USBExportGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

private actor StubReceiverRegistrar: IPhoneReceiverRegistering {
    func register(
        uploadCredential: String,
        deviceName: String
    ) async throws -> IPhoneReceiverRegistration {
        IPhoneReceiverRegistration(
            receiverID: UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!,
            code: "123456",
            receiveSecret: "receive-secret",
            deviceName: deviceName
        )
    }
}

private struct ViewModelBookmarkCodec: USBBookmarkCoding {
    let url: URL

    func makeBookmark(for url: URL) throws -> Data { Data("bookmark".utf8) }
    func resolve(_ data: Data) throws -> USBBookmarkResolution {
        USBBookmarkResolution(url: url, isStale: false)
    }
}

private final class ReceiverProgressFeed: @unchecked Sendable {
    let stream: AsyncStream<USBReceiveProgress>
    private let continuation: AsyncStream<USBReceiveProgress>.Continuation

    init() {
        let pair = AsyncStream.makeStream(of: USBReceiveProgress.self)
        stream = pair.stream
        continuation = pair.continuation
    }

    func yield(_ value: USBReceiveProgress) {
        continuation.yield(value)
    }
}

private final class ReceiveCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}
