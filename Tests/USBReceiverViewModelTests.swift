import Foundation
import XCTest
@testable import SimpleCameraAutoSender

@MainActor
final class USBReceiverViewModelTests: XCTestCase {
    func testChoosingUSBFolderDoesNotStartReceiveOrFallback() async throws {
        let model = fallbackModel(pending: { [UUID()] }, receiveLocal: {}, approve: { _ in })
        model.isChoosingUSBFolder = true
        await model.pollOnce()
        XCTAssertFalse(model.isPerformingReceive)
        XCTAssertFalse(model.needsLocalFallbackDecision)
        XCTAssertNil(model.lastError)
    }

    func testOldUSBProgressDoesNotReportAnActiveReceiveAfterLeavingTheScreen() async throws {
        let progress = USBReceiveProgressStore()
        let model = try exportModel(files: [], receiveProgressStore: progress) { _, _ in
            IPhoneUSBExportSummary(verified: [], failed: [])
        }
        progress.publish(testProgress(stage: .downloading, name: "paused.zip", bytes: 50))
        await waitUntil { model.receiveProgress?.stage == .downloading }
        XCTAssertFalse(model.isReceivingFile, "A paused USB progress snapshot is not a running operation")
    }

    func testFallbackApprovalKeepsTheDisplayedBatchFrozen() async throws {
        let receiver = UUID()
        let first = UUID()
        let next = UUID()
        let pending = PendingReceiveIDs([first])
        let store = IPhoneReceiveApprovalStore(fileURL: temporaryDirectory().appendingPathComponent("approvals.json"))
        let localCalls = ReceiveCounter()
        let model = fallbackModel(pending: { pending.value }, receiveLocal: { localCalls.increment() }, approve: {
            try store.approve($0, receiverID: receiver, destination: .iphoneLocal)
        })
        await model.pollOnce()
        XCTAssertTrue(model.needsLocalFallbackDecision)
        pending.value = [first, next]
        await model.pollOnce()
        await model.chooseLocalFallback()

        XCTAssertEqual(try store.destinations(receiverID: receiver), [first: .iphoneLocal])
        XCTAssertEqual(localCalls.value, 1)
        XCTAssertEqual(model.selectedDestination, .iphoneLocal, "The screen must show the fallback destination actually chosen")
    }

    func testFailedFallbackApprovalCannotStartTheLocalReceiver() async throws {
        let localCalls = ReceiveCounter()
        let model = fallbackModel(pending: { [UUID()] }, receiveLocal: { localCalls.increment() }, approve: { _ in
            throw CocoaError(.fileWriteNoPermission)
        })
        await model.pollOnce()
        await model.chooseLocalFallback()

        XCTAssertEqual(localCalls.value, 0)
        XCTAssertTrue(model.needsLocalFallbackDecision)
        XCTAssertNotNil(model.lastError)
    }

    func testCompletedLocalReceiveImmediatelyRefreshesSavedFiles() async throws {
        let file = try storedFile()
        let progress = USBReceiveProgressStore()
        let model = try exportModel(files: [file], receiveProgressStore: progress) { _, _ in
            IPhoneUSBExportSummary(verified: [], failed: [])
        }
        XCTAssertTrue(model.storedFiles.isEmpty)
        progress.publish(USBReceiveProgress(
            stage: .completed, destination: .iphoneLocal, deliveryID: UUID(), fileName: file.name,
            currentIndex: 1, totalCount: 1, completedCount: 1,
            bytesReceived: file.size, totalBytes: file.size, startedAt: nil, expiresAt: nil, errorMessage: nil
        ))
        await waitUntil { model.storedFiles.count == 1 }
        XCTAssertEqual(model.storedFiles.map(\.id), [file.id])
    }

    func testRelaunchRestoresStoredFilesEvenWhenServerRefreshFails() async throws {
        let file = try storedFile()
        let registrationStore = IPhoneReceiverRegistrationStore(
            identityStore: InMemoryCredentialStore(),
            secretStore: InMemoryCredentialStore()
        )
        try registrationStore.save(IPhoneReceiverRegistration(
            receiverID: UUID(),
            code: "123456",
            receiveSecret: "receive-secret",
            deviceName: "테스트 iPhone"
        ))
        let model = USBReceiverViewModel(
            uploadCredentialStore: InMemoryCredentialStore(),
            registrationStore: registrationStore,
            bookmarkStore: USBBookmarkStore(
                fileURL: temporaryDirectory().appendingPathComponent("destination.json")
            ),
            registrar: StubReceiverRegistrar(),
            receiveOnce: { USBReceiveSummary(discovered: 0, completed: 0) },
            storedFiles: { [file] },
            refreshFeatures: { throw URLError(.cannotConnectToHost) },
            progressUpdates: { AsyncStream { $0.finish() } },
            defaultDeviceName: "iPhone",
            preferences: isolatedPreferences()
        )

        await model.refresh()

        XCTAssertEqual(model.storedFiles.map(\.id), [file.id])
        XCTAssertNotNil(model.lastError, "The server failure must remain visible without hiding local files")
    }

    func testRelaunchRestoresStoredFilesEvenWhenUSBBookmarkCannotResolve() async throws {
        let file = try storedFile()
        let bookmarkStore = USBBookmarkStore(
            fileURL: temporaryDirectory().appendingPathComponent("destination.json"),
            codec: FailingResolutionBookmarkCodec()
        )
        try bookmarkStore.save(
            folderURL: URL(fileURLWithPath: "/Volumes/UNPLUGGED", isDirectory: true),
            volumeID: "removed-volume",
            displayName: "REMOVED USB"
        )
        let model = USBReceiverViewModel(
            uploadCredentialStore: InMemoryCredentialStore(),
            registrationStore: IPhoneReceiverRegistrationStore(
                identityStore: InMemoryCredentialStore(),
                secretStore: InMemoryCredentialStore()
            ),
            bookmarkStore: bookmarkStore,
            registrar: StubReceiverRegistrar(),
            receiveOnce: { USBReceiveSummary(discovered: 0, completed: 0) },
            storedFiles: { [file] },
            progressUpdates: { AsyncStream { $0.finish() } },
            defaultDeviceName: "iPhone",
            preferences: isolatedPreferences()
        )

        await model.refresh()

        XCTAssertEqual(model.storedFiles.map(\.id), [file.id])
        XCTAssertNotNil(model.lastError, "The invalid USB bookmark must not hide local files")
    }

    func testCancelledServerRefreshDoesNotReportNetworkFailureOrHideStoredFiles() async throws {
        let file = try storedFile()
        let registrationStore = IPhoneReceiverRegistrationStore(
            identityStore: InMemoryCredentialStore(),
            secretStore: InMemoryCredentialStore()
        )
        try registrationStore.save(IPhoneReceiverRegistration(
            receiverID: UUID(),
            code: "123456",
            receiveSecret: "receive-secret",
            deviceName: "테스트 iPhone"
        ))
        let model = USBReceiverViewModel(
            uploadCredentialStore: InMemoryCredentialStore(),
            registrationStore: registrationStore,
            bookmarkStore: USBBookmarkStore(
                fileURL: temporaryDirectory().appendingPathComponent("destination.json")
            ),
            registrar: StubReceiverRegistrar(),
            receiveOnce: { USBReceiveSummary(discovered: 0, completed: 0) },
            storedFiles: { [file] },
            refreshFeatures: { throw URLError(.cancelled) },
            progressUpdates: { AsyncStream { $0.finish() } },
            defaultDeviceName: "iPhone",
            preferences: isolatedPreferences()
        )

        await model.refresh()

        XCTAssertEqual(model.storedFiles.map(\.id), [file.id])
        XCTAssertNil(model.lastError)
    }

    func testRecoveryToIdleClearsThePreviousPCError() async throws {
        let progress = USBReceiveProgressStore()
        let model = try exportModel(files: [], receiveProgressStore: progress) { _, _ in
            IPhoneUSBExportSummary(verified: [], failed: [])
        }
        progress.publishFailure("previous network error")
        await waitUntil { model.receiveProgress?.stage == .failed }

        progress.publish(.idle)
        await waitUntil { model.receiveProgress?.stage == .idle }

        XCTAssertNil(model.lastError)
        XCTAssertEqual(model.receiveStageTitle, "PC 파일 수신 대기")
    }

    func testNewReceiveProgressClearsThePreviousPCError() async throws {
        let progress = USBReceiveProgressStore()
        let model = try exportModel(files: [], receiveProgressStore: progress) { _, _ in
            IPhoneUSBExportSummary(verified: [], failed: [])
        }
        progress.publishFailure("previous network error")
        await waitUntil { model.receiveProgress?.stage == .failed }

        progress.publish(testProgress(stage: .downloading, name: "new.txt", bytes: 25))
        await waitUntil { model.receiveProgress?.stage == .downloading }

        XCTAssertNil(model.lastError)
        XCTAssertEqual(model.receivePercentText, "25%")
    }

    func testDiscoveryErrorDoesNotShowZeroByteProgressOrCalculating() async throws {
        let progress = USBReceiveProgressStore()
        let model = try exportModel(files: [], receiveProgressStore: progress) { _, _ in
            IPhoneUSBExportSummary(verified: [], failed: [])
        }
        progress.publishFailure("current server error")
        await waitUntil { model.receiveProgress?.stage == .failed }

        XCTAssertEqual(model.receiveStageTitle, "새 파일 확인 오류")
        XCTAssertEqual(model.receivePercentText, "")
        XCTAssertEqual(model.receiveByteText, "")
        XCTAssertEqual(model.receiveSpeedText, "")
        XCTAssertEqual(model.receiveETAText, "")
        XCTAssertEqual(model.lastError, "current server error")
    }

    func testCompletedReceiveDoesNotKeepShowingRunningProgress() async throws {
        let progress = USBReceiveProgressStore()
        let model = try exportModel(files: [], receiveProgressStore: progress) { _, _ in
            IPhoneUSBExportSummary(verified: [], failed: [])
        }
        progress.publish(testProgress(stage: .completed, name: "done.txt", bytes: 100))
        await waitUntil { model.receiveProgress?.stage == .completed }

        XCTAssertEqual(model.receivePercentText, "")
        XCTAssertEqual(model.receiveSpeedText, "")
        XCTAssertEqual(model.receiveETAText, "")
    }

    func testDeletingOriginalCollapsesFinishedUSBProgressAndRefreshesTheList() async throws {
        let context = try await completedExportContext()
        XCTAssertTrue(context.model.needsDeletionDecision)

        await context.model.deleteOriginals()
        await waitUntil { context.model.usbExportProgress == nil }

        XCTAssertFalse(context.model.needsDeletionDecision)
        XCTAssertTrue(context.model.storedFiles.isEmpty)
        XCTAssertTrue(context.model.selectedStoredFileIDs.isEmpty)
        XCTAssertTrue(context.model.usbExportStageTitle.contains("원본 1개 삭제"))
        XCTAssertNil(context.model.lastError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.file.url.path))
        var replay = context.exportProgress.updates().makeAsyncIterator()
        let latest = await replay.next()
        XCTAssertEqual(latest?.stage, .idle, "Reopening the screen must not replay old completion")
    }

    func testKeepingOriginalCollapsesUSBProgressWithoutHidingAPCError() async throws {
        let context = try await completedExportContext()
        context.pcProgress.publishFailure("current server failure")
        await waitUntil { context.model.lastError == "current server failure" }

        await context.model.keepOriginals()
        await waitUntil { context.model.usbExportProgress == nil }

        XCTAssertFalse(context.model.needsDeletionDecision)
        XCTAssertEqual(context.model.storedFiles.map(\.id), [context.file.id])
        XCTAssertTrue(context.model.usbExportStageTitle.contains("원본 1개 유지"))
        XCTAssertEqual(context.model.lastError, "current server failure")
        XCTAssertTrue(FileManager.default.fileExists(atPath: context.file.url.path))
        var replay = context.exportProgress.updates().makeAsyncIterator()
        let latest = await replay.next()
        XCTAssertEqual(latest?.stage, .idle)
    }

    func testChangedOriginalIsNotDeletedOrReportedAsAPCReceiveFailure() async throws {
        let context = try await completedExportContext()
        let changed = Data("changed after verified copy".utf8)
        try changed.write(to: context.file.url)

        await context.model.deleteOriginals()

        XCTAssertEqual(try Data(contentsOf: context.file.url), changed)
        XCTAssertTrue(context.model.needsDeletionDecision)
        XCTAssertNotNil(context.model.usbExportProgress)
        XCTAssertNil(context.model.lastError, "Original cleanup errors belong below the USB result")
        XCTAssertNil(context.model.lastUSBExportError, "The verified USB copy itself succeeded")
        XCTAssertTrue(context.model.lastOriginalCleanupError?.contains("원본 1개") == true)
        XCTAssertNil(context.model.usbExportCompletionMessage)
    }

    func testPCProgressCannotOverwriteAUSBExportFailure() async throws {
        let file = try storedFile()
        let pcProgress = USBReceiveProgressStore()
        let exportProgress = USBReceiveProgressStore()
        let model = try exportModel(
            files: [file],
            receiveProgressStore: pcProgress,
            exportProgressStore: exportProgress
        ) { _, _ in
            exportProgress.publishFailure("USB에 쓸 수 없습니다. 폴더 권한을 확인해 주세요.")
            return IPhoneUSBExportSummary(
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
        await waitUntil { model.usbExportProgress?.stage == .failed }
        let failure = model.lastUSBExportError

        pcProgress.publish(testProgress(stage: .downloading, name: "new-pc.txt", bytes: 25))
        await waitUntil { model.receiveProgress?.fileName == "new-pc.txt" }
        await model.pollOnce()

        XCTAssertEqual(model.lastUSBExportError, failure)
        XCTAssertTrue(model.lastUSBExportError?.contains("권한") == true)
        XCTAssertEqual(model.usbExportProgress?.stage, .failed)
        XCTAssertEqual(model.selectedStoredFileIDs, [file.id])
    }

    func testUSBExportProgressIsIndependentOfPCReceiveProgress() async throws {
        let pcProgress = USBReceiveProgressStore()
        let exportProgress = USBReceiveProgressStore()
        let model = try exportModel(
            files: [],
            receiveProgressStore: pcProgress,
            exportProgressStore: exportProgress
        ) { _, _ in IPhoneUSBExportSummary(verified: [], failed: []) }

        exportProgress.publish(testProgress(stage: .copyingToUSB, name: "local.zip", bytes: 50))
        pcProgress.publish(testProgress(stage: .downloading, name: "from-pc.txt", bytes: 25))
        await waitUntil {
            model.usbExportProgress?.percent == 50 && model.receiveProgress?.percent == 25
        }

        XCTAssertEqual(model.usbExportProgress?.fileName, "local.zip")
        XCTAssertEqual(model.usbExportStageTitle, "USB로 복사 중 · 1/1")
        XCTAssertEqual(model.receiveProgress?.fileName, "from-pc.txt")
    }

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

        await model.selectDestination(temporaryDirectory())
        await model.pollOnce()
        XCTAssertEqual(usbCounter.value, 2, "Choosing a new USB folder must release server-wait")
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

    private func fallbackModel(
        pending: @escaping USBReceiverViewModel.PendingDeliveryIDs,
        receiveLocal: @escaping USBReceiverViewModel.ReceiveLocalOnce,
        approve: @escaping USBReceiverViewModel.ApproveLocalFallback
    ) -> USBReceiverViewModel {
        let preferences = isolatedPreferences()
        preferences.selectedDestination = .usb
        return USBReceiverViewModel(
            uploadCredentialStore: InMemoryCredentialStore(),
            registrationStore: IPhoneReceiverRegistrationStore(identityStore: InMemoryCredentialStore(), secretStore: InMemoryCredentialStore()),
            bookmarkStore: USBBookmarkStore(fileURL: temporaryDirectory().appendingPathComponent("destination.json")),
            registrar: StubReceiverRegistrar(),
            receiveOnce: { throw USBReceiveServiceError.missingDestination },
            receiveLocalOnce: receiveLocal,
            pendingDeliveryIDs: pending,
            approveLocalFallback: approve,
            progressUpdates: { AsyncStream { $0.finish() } },
            defaultDeviceName: "iPhone",
            preferences: preferences
        )
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
        receiveProgressStore: USBReceiveProgressStore? = nil,
        exportProgressStore: USBReceiveProgressStore? = nil,
        pendingDeletionDecisions: @escaping USBReceiverViewModel.PendingDeletionDecisions = { [] },
        keepOriginals: @escaping USBReceiverViewModel.KeepOriginals = { _ in },
        deleteOriginals: @escaping USBReceiverViewModel.DeleteOriginals = { _ in
            IPhoneUSBDeletionSummary(deletedSourceIDs: [], failed: [])
        },
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
            storedFiles: { files.filter { FileManager.default.fileExists(atPath: $0.url.path) } },
            exportFiles: export,
            pendingDeletionDecisions: pendingDeletionDecisions,
            keepOriginals: keepOriginals,
            deleteOriginals: deleteOriginals,
            progressUpdates: {
                receiveProgressStore?.updates() ?? AsyncStream { $0.finish() }
            },
            exportProgressUpdates: {
                exportProgressStore?.updates() ?? AsyncStream { $0.finish() }
            },
            defaultDeviceName: "iPhone",
            preferences: isolatedPreferences()
        )
    }

    private func completedExportContext() async throws -> (
        model: USBReceiverViewModel,
        file: IPhoneStoredFile,
        exportProgress: USBReceiveProgressStore,
        pcProgress: USBReceiveProgressStore
    ) {
        let file = try storedFile()
        let decisions = try IPhoneUSBDeletionDecisionStore(
            fileURL: temporaryDirectory().appendingPathComponent("decisions.json")
        )
        let exportProgress = USBReceiveProgressStore()
        let pcProgress = USBReceiveProgressStore()
        let exporter = IPhoneUSBExportService(
            deletionStore: decisions,
            startAccessing: { _ in true },
            stopAccessing: { _ in },
            progressStore: exportProgress
        )
        let model = try exportModel(
            files: [file],
            receiveProgressStore: pcProgress,
            exportProgressStore: exportProgress,
            pendingDeletionDecisions: { decisions.pending() },
            keepOriginals: { try await exporter.keep(decisionIDs: $0) },
            deleteOriginals: { await exporter.delete(decisionIDs: $0) }
        ) { files, destination in
            await exporter.export(files, to: destination)
        }
        await model.refresh()
        model.toggleStoredFileSelection(file.id)
        await model.exportSelectedFilesToUSB()
        await waitUntil { model.usbExportProgress?.stage == .completed }
        XCTAssertNil(model.lastUSBExportError)
        return (model, file, exportProgress, pcProgress)
    }

    private func testProgress(stage: USBReceiveStage, name: String, bytes: Int64) -> USBReceiveProgress {
        USBReceiveProgress(
            stage: stage,
            deliveryID: UUID(),
            fileName: name,
            currentIndex: 1,
            totalCount: 1,
            completedCount: 0,
            bytesReceived: bytes,
            totalBytes: 100,
            startedAt: Date(),
            expiresAt: nil,
            errorMessage: nil
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

private struct FailingResolutionBookmarkCodec: USBBookmarkCoding {
    func makeBookmark(for url: URL) throws -> Data { Data("bookmark".utf8) }

    func resolve(_ data: Data) throws -> USBBookmarkResolution {
        throw CocoaError(.fileReadNoPermission)
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

private final class PendingReceiveIDs: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: Set<UUID>
    init(_ ids: Set<UUID>) { self.ids = ids }
    var value: Set<UUID> {
        get { lock.withLock { ids } }
        set { lock.withLock { ids = newValue } }
    }
}
