import Foundation
import XCTest
@testable import SimpleCameraAutoSender

@MainActor
final class USBReceiverViewModelTests: XCTestCase {
    func testBackgroundExpirationKeeps70PercentVisibleUntilWorkerCleanupFinishes() async throws {
        let file = try storedFile()
        let store = USBReceiveProgressStore()
        let started = expectation(description: "copy started")
        let model = try exportModel(files: [file], exportProgressStore: store) { _, _, _ in
            store.publish(USBReceiveProgress(stage: .copyingToUSB, deliveryID: nil, fileName: file.name,
                currentIndex: 1, totalCount: 1, completedCount: 0, bytesReceived: 70,
                totalBytes: 100, startedAt: Date(), expiresAt: nil, errorMessage: nil))
            started.fulfill()
            try? await Task.sleep(for: .seconds(5))
            let cancelled = Task.isCancelled
            await Task.detached { try? await Task.sleep(for: .milliseconds(80)) }.value
            return IPhoneUSBExportSummary(verified: [], failed: [], cancelled: cancelled)
        }
        await model.refresh()
        model.toggleStoredFileSelection(file.id)
        let task = Task { await model.exportSelectedFilesToUSB() }
        await fulfillment(of: [started], timeout: 2)
        await waitUntil { model.usbExportProgress?.percent == 70 }
        model.expireUSBCopyBackgroundTime()
        XCTAssertTrue(model.isExportingToUSB, "Don't allow cleanup while the worker still owns USB I/O")
        await task.value
        await waitUntil { model.usbExportProgress?.stage == .paused }
        XCTAssertEqual(model.usbExportDisplayedPercent, 70)
        XCTAssertTrue(model.usbExportStageTitle.contains("중단"))
        XCTAssertFalse(model.isExportingToUSB)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
    }

    func testCleanupAvailabilityIgnoresDiscoveryButBlocksActualDownload() async throws {
        let store = USBReceiveProgressStore()
        let model = try exportModel(files: [], receiveProgressStore: store) { _, _, _ in
            IPhoneUSBExportSummary(verified: [], failed: [])
        }
        func publish(_ stage: USBReceiveStage) {
            store.publish(USBReceiveProgress(stage: stage, destination: .iphoneLocal,
                deliveryID: nil, fileName: nil, currentIndex: 0, totalCount: 0,
                completedCount: 0, bytesReceived: 0, totalBytes: 0,
                startedAt: nil, expiresAt: nil, errorMessage: nil))
        }
        publish(.discovering)
        await waitUntil { model.receiveProgress?.stage == .discovering }
        XCTAssertTrue(model.canCleanTemporaryFiles)
        publish(.downloading)
        await waitUntil { model.receiveProgress?.stage == .downloading }
        XCTAssertFalse(model.canCleanTemporaryFiles)
    }

    func testTemporaryCleanupButtonStaysEnabledDuringEmptyMailboxPolling() async throws {
        let started = expectation(description: "poll started")
        let preferences = isolatedPreferences()
        preferences.selectedDestination = .iphoneLocal
        let model = USBReceiverViewModel(
            uploadCredentialStore: InMemoryCredentialStore(),
            registrationStore: IPhoneReceiverRegistrationStore(identityStore: InMemoryCredentialStore(), secretStore: InMemoryCredentialStore()),
            bookmarkStore: USBBookmarkStore(fileURL: temporaryDirectory().appendingPathComponent("bookmark.json")),
            registrar: StubReceiverRegistrar(),
            receiveOnce: { USBReceiveSummary(discovered: 0, completed: 0) },
            receiveLocalOnce: {
                started.fulfill()
                try await Task.sleep(for: .milliseconds(250))
            },
            progressUpdates: { AsyncStream { $0.finish() } },
            defaultDeviceName: "iPhone", preferences: preferences)
        XCTAssertTrue(model.canCleanTemporaryFiles)
        let poll = Task { await model.pollOnce() }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(model.isPerformingReceive)
        XCTAssertTrue(model.canCleanTemporaryFiles, "Empty mailbox polling must not flash the cleanup button")
        await poll.value
        XCTAssertTrue(model.canCleanTemporaryFiles)
    }

    func testCopyCancellationKeepsBusyUntilWorkerReturnsAndPreservesOriginal() async throws {
        let file = try storedFile()
        let started = expectation(description: "copy started")
        let model = try exportModel(files: [file]) { _, _, _ in
            started.fulfill()
            try? await Task.sleep(for: .milliseconds(400))
            let cancelled = Task.isCancelled
            await Task.detached { try? await Task.sleep(for: .milliseconds(50)) }.value
            return IPhoneUSBExportSummary(verified: [], failed: [], cancelled: cancelled)
        }
        await model.refresh()
        model.toggleStoredFileSelection(file.id)
        let task = Task { await model.exportSelectedFilesToUSB() }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(model.canCancelUSBCopy)
        model.cancelUSBCopy()
        XCTAssertTrue(model.isCancellingUSBCopy)
        XCTAssertTrue(model.isExportingToUSB, "Do not claim cancellation before cleanup returns")
        await task.value
        XCTAssertFalse(model.isExportingToUSB)
        XCTAssertFalse(model.isCancellingUSBCopy)
        XCTAssertFalse(model.needsDeletionDecision)
        XCTAssertNil(model.lastUSBExportError)
        XCTAssertEqual(model.usbExportCompletionMessage, "USB 복사 취소 완료 · 원본 유지")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
    }

    func testCopyAndOptionalVerificationResolveUSBOffTheMainThread() async throws {
        let file = try storedFile()
        let bookmark = USBBookmarkStore(fileURL: temporaryDirectory().appendingPathComponent("probe.json"),
                                        codec: MainQueueProbeBookmarkCodec())
        try bookmark.save(folderURL: temporaryDirectory())
        let model = USBReceiverViewModel(
            uploadCredentialStore: InMemoryCredentialStore(),
            registrationStore: IPhoneReceiverRegistrationStore(identityStore: InMemoryCredentialStore(), secretStore: InMemoryCredentialStore()),
            bookmarkStore: bookmark, registrar: StubReceiverRegistrar(),
            receiveOnce: { USBReceiveSummary(discovered: 0, completed: 0) },
            storedFiles: { [file] }, progressUpdates: { AsyncStream { $0.finish() } },
            defaultDeviceName: "iPhone", preferences: isolatedPreferences())
        await model.refresh()
        model.toggleStoredFileSelection(file.id)
        await model.exportSelectedFilesToUSB()
        XCTAssertNotNil(model.lastUSBExportError)
        await model.verifySelectedUSBCopies()
        XCTAssertTrue(model.usbVerificationFailed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
    }
    func testCopyPercentStaysBelow100UntilCompletionAndReportsPhaseSpeed() async throws {
        let store = USBReceiveProgressStore()
        let model = try exportModel(files: [], exportProgressStore: store) { _, _, _ in
            IPhoneUSBExportSummary(verified: [], failed: [])
        }
        let start = Date(timeIntervalSince1970: 100)
        store.publish(USBReceiveProgress(stage: .copyingToUSB, deliveryID: nil, fileName: "file.bin",
            currentIndex: 1, totalCount: 1, completedCount: 0, bytesReceived: 10_000_000,
            totalBytes: 10_000_000, startedAt: start, expiresAt: nil, errorMessage: nil))
        await waitUntil { model.usbExportProgress != nil }
        XCTAssertEqual(model.usbExportDisplayedPercent, 99)
        XCTAssertEqual(model.usbExportSpeedText(at: start.addingTimeInterval(2)), "현재 단계 평균 5.0 MB/s")
        store.publish(USBReceiveProgress(stage: .completed, deliveryID: nil, fileName: nil,
            currentIndex: 1, totalCount: 1, completedCount: 1, bytesReceived: 10_000_000,
            totalBytes: 10_000_000, startedAt: nil, expiresAt: nil, errorMessage: nil))
        await waitUntil { model.usbExportProgress?.stage == .completed }
        XCTAssertEqual(model.usbExportDisplayedPercent, 100)
    }

    func testUSBCopyETASeparatesCalculationCopyAndFinalization() async throws {
        let store = USBReceiveProgressStore()
        let model = try exportModel(files: [], exportProgressStore: store) { _, _, _ in
            IPhoneUSBExportSummary(verified: [], failed: [])
        }
        let start = Date(timeIntervalSince1970: 100)
        func publish(_ stage: USBReceiveStage, bytes: Int64, total: Int64) {
            store.publish(USBReceiveProgress(stage: stage, deliveryID: nil, fileName: "archive.zip",
                currentIndex: 1, totalCount: 2, completedCount: 0, bytesReceived: bytes,
                totalBytes: total, startedAt: start, expiresAt: nil, errorMessage: nil))
        }
        publish(.copyingToUSB, bytes: 0, total: 100)
        await waitUntil { model.usbExportProgress != nil }
        XCTAssertEqual(model.usbExportRemainingTimeText(at: start.addingTimeInterval(10)), "남은 시간 계산 중")
        publish(.copyingToUSB, bytes: 25, total: 100)
        await waitUntil { model.usbExportProgress?.bytesReceived == 25 }
        XCTAssertEqual(model.usbExportRemainingTimeText(at: start.addingTimeInterval(10)), "현재 복사 작업 · 약 30초 남음")
        XCTAssertEqual(model.usbExportRemainingTimeText(at: start.addingTimeInterval(100)), "현재 복사 작업 · 약 5분 남음")
        XCTAssertEqual(model.usbExportRemainingTimeText(at: start.addingTimeInterval(1_200)), "현재 복사 작업 · 약 1시간 0분 남음")
        XCTAssertEqual(model.usbExportRemainingTimeText(at: try XCTUnwrap(model.usbExportLastUpdatedAt).addingTimeInterval(10)), "진행 응답 대기 · 남은 시간 다시 계산 중")
        publish(.copyingToUSB, bytes: 100, total: 100)
        await waitUntil { model.usbExportProgress?.bytesReceived == 100 }
        XCTAssertEqual(model.usbExportRemainingTimeText(at: start.addingTimeInterval(10)), "파일 기록 마무리 중")
        for stage in [USBReceiveStage.extracting, .finalizing, .completed, .failed] {
            publish(stage, bytes: 100, total: 100)
            await waitUntil { model.usbExportProgress?.stage == stage }
            XCTAssertNil(model.usbExportRemainingTimeText(at: start.addingTimeInterval(10)))
        }
    }

    func testOptionalVerificationFailureDoesNotReplaceCopyOrReceiveResults() async throws {
        let file = try storedFile()
        let store = USBReceiveProgressStore()
        let model = try exportModel(files: [file], exportProgressStore: store,
            verifyCopies: { files, _, progress in
                progress(USBReceiveProgress(stage: .verifying, deliveryID: nil, fileName: files[0].name,
                    currentIndex: 1, totalCount: 1, completedCount: 0, bytesReceived: 1,
                    totalBytes: 2, startedAt: Date(), expiresAt: nil, errorMessage: nil))
                return IPhoneUSBExportSummary(verified: [], failed: [
                    IPhoneUSBExportFailure(sourceID: files[0].id, error: .shaMismatch)
                ])
            }) { _, _, _ in IPhoneUSBExportSummary(verified: [], failed: []) }
        await model.refresh()
        store.publish(testProgress(stage: .completed, name: file.name, bytes: 100))
        await waitUntil { model.usbExportProgress?.stage == .completed }
        let originalProgress = model.usbExportProgress
        let originalReceive = model.receiveStatus
        model.toggleStoredFileSelection(file.id)
        await model.verifySelectedUSBCopies()
        XCTAssertTrue(model.usbVerificationFailed)
        XCTAssertEqual(model.usbExportProgress, originalProgress)
        XCTAssertEqual(model.receiveStatus, originalReceive)
        XCTAssertNil(model.lastUSBExportError)
        XCTAssertFalse(model.isExportingToUSB)
        XCTAssertEqual(model.selectedStoredFileIDs, [file.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
    }
    func testStartupBookmarkLookupLeavesMainQueueResponsive() async throws {
        let bookmarkStore = USBBookmarkStore(
            fileURL: temporaryDirectory().appendingPathComponent("destination.json"),
            codec: MainQueueProbeBookmarkCodec()
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
            progressUpdates: { AsyncStream { $0.finish() } },
            defaultDeviceName: "iPhone",
            preferences: isolatedPreferences()
        )

        await model.refresh()

        XCTAssertNotNil(model.lastError, "Unavailable USB must remain an ordinary error")
    }

    func testUSBFolderCleanupRequiresInspectionAndConfirmationBeforeDeletion() async throws {
        let calls = USBFolderCleanupCallLog()
        let summary = USBFolderContentsSummary(
            folderName: "SD CARD",
            fileSystemDescription: "ExFAT",
            fileCount: 3,
            directoryCount: 1,
            totalBytes: 4_096,
            volumeID: "test-volume",
            folderPath: "/SD CARD",
            fingerprint: "confirmed"
        )
        let model = try exportModel(
            files: [],
            inspectUSBFolder: { _ in
                await calls.recordInspection()
                return summary
            },
            deleteUSBFolderContents: { _, receivedSummary, _ in
                await calls.recordDeletion(summary: receivedSummary)
                return USBFolderDeletionSummary(
                    deletedItemCount: receivedSummary.totalItemCount,
                    remainingItemCount: 0,
                    failures: []
                )
            }
        ) { _, _, _ in
            IPhoneUSBExportSummary(verified: [], failed: [])
        }
        await model.refresh()

        await model.prepareUSBFolderDeletion()

        XCTAssertTrue(model.needsUSBFolderDeletionConfirmation)
        XCTAssertEqual(model.usbFileSystemDescription, "ExFAT")
        XCTAssertTrue(model.usbFolderDeletionConfirmationMessage.contains("파일 3개"))
        let inspectionCount = await calls.inspectionCount()
        let deletionCountBeforeConfirmation = await calls.deletionCount()
        XCTAssertEqual(inspectionCount, 1)
        XCTAssertEqual(deletionCountBeforeConfirmation, 0)

        await model.deleteConfirmedUSBFolderContents()

        XCTAssertFalse(model.needsUSBFolderDeletionConfirmation)
        let deletionCountAfterConfirmation = await calls.deletionCount()
        XCTAssertEqual(deletionCountAfterConfirmation, 1)
        XCTAssertEqual(model.usbFolderDeletionMessage, "SD/USB 파일 4개 삭제 완료")
        XCTAssertNil(model.usbFolderDeletionError)
    }

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
        let model = try exportModel(files: [], receiveProgressStore: progress) { _, _, _ in
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
        let model = try exportModel(files: [file], receiveProgressStore: progress) { _, _, _ in
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
        let model = try exportModel(files: [], receiveProgressStore: progress) { _, _, _ in
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
        let model = try exportModel(files: [], receiveProgressStore: progress) { _, _, _ in
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
        let model = try exportModel(files: [], receiveProgressStore: progress) { _, _, _ in
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
        let model = try exportModel(files: [], receiveProgressStore: progress) { _, _, _ in
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
        ) { _, _, _ in
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
        ) { _, _, _ in IPhoneUSBExportSummary(verified: [], failed: []) }

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
        let model = try exportModel(files: [file]) { _, _, _ in
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

    func testStoredZIPWaitsForAnExplicitExportChoiceAndKeepsSelection() async throws {
        let file = try storedFile(name: "stored.zip")
        let modes = ArchiveModeLog()
        let model = try exportModel(files: [file]) { _, _, archiveMode in
            await modes.record(archiveMode)
            return IPhoneUSBExportSummary(verified: [], failed: [])
        }
        await model.refresh()
        model.toggleStoredFileSelection(file.id)

        await model.requestStoredFilesUSBExport()

        XCTAssertTrue(model.needsStoredZIPExportChoice)
        XCTAssertEqual(model.storedZIPExportFilesPendingChoice.map(\.id), [file.id])
        XCTAssertEqual(model.selectedStoredFileIDs, [file.id])
        let beforeChoice = await modes.values()
        XCTAssertEqual(beforeChoice, [])

        await model.confirmStoredZIPExport(.keepArchive)

        XCTAssertFalse(model.needsStoredZIPExportChoice)
        let afterChoice = await modes.values()
        XCTAssertEqual(afterChoice, [.keepArchive])
        XCTAssertEqual(model.selectedStoredFileIDs, [file.id])
    }

    func testStoredNonZIPStartsImmediatelyWithoutAnArchivePrompt() async throws {
        let file = try storedFile(name: "stored.txt")
        let modes = ArchiveModeLog()
        let model = try exportModel(files: [file]) { _, _, archiveMode in
            await modes.record(archiveMode)
            return IPhoneUSBExportSummary(verified: [], failed: [])
        }
        await model.refresh()
        model.toggleStoredFileSelection(file.id)

        await model.requestStoredFilesUSBExport()

        XCTAssertFalse(model.needsStoredZIPExportChoice)
        let recordedModes = await modes.values()
        XCTAssertEqual(recordedModes, [.keepArchive])
    }

    func testSecondCopyPressCannotQueueADuplicateExport() async throws {
        let file = try storedFile()
        let calls = ReceiveCounter()
        let secondPress = ReceiveCounter()
        let gate = USBExportGate()
        let model = try exportModel(files: [file]) { _, _, _ in
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

    private func storedFile(name: String = "local.bin") throws -> IPhoneStoredFile {
        let url = temporaryDirectory().appendingPathComponent(name)
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
        verifyCopies: @escaping USBReceiverViewModel.VerifyCopies = { _, _, _ in IPhoneUSBExportSummary(verified: [], failed: []) },
        keepOriginals: @escaping USBReceiverViewModel.KeepOriginals = { _ in },
        deleteOriginals: @escaping USBReceiverViewModel.DeleteOriginals = { _ in
            IPhoneUSBDeletionSummary(deletedSourceIDs: [], failed: [])
        },
        inspectUSBFolder: @escaping USBReceiverViewModel.InspectUSBFolder = { _ in
            throw CocoaError(.featureUnsupported)
        },
        deleteUSBFolderContents: @escaping USBReceiverViewModel.DeleteUSBFolderContents = { _, _, _ in
            throw CocoaError(.featureUnsupported)
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
            verifyCopies: verifyCopies,
            keepOriginals: keepOriginals,
            deleteOriginals: deleteOriginals,
            inspectUSBFolder: inspectUSBFolder,
            deleteUSBFolderContents: deleteUSBFolderContents,
            progressUpdates: {
                receiveProgressStore?.updates() ?? AsyncStream { $0.finish() }
            },
            exportProgressUpdates: {
                exportProgressStore?.updates() ?? AsyncStream { $0.finish() }
            },
            beginExportProgress: { name, count in exportProgressStore?.beginExport(fileName: name, totalCount: count) },
            interruptExportProgress: { exportProgressStore?.interruptExport() },
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
        ) { files, destination, archiveMode in
            await exporter.export(files, to: destination, archiveMode: archiveMode)
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

private actor USBFolderCleanupCallLog {
    private var inspections = 0
    private var deletions: [USBFolderContentsSummary] = []

    func recordInspection() { inspections += 1 }
    func recordDeletion(summary: USBFolderContentsSummary) { deletions.append(summary) }
    func inspectionCount() -> Int { inspections }
    func deletionCount() -> Int { deletions.count }
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

private actor ArchiveModeLog {
    private var recorded: [IPhoneReceiveArchiveMode] = []

    func record(_ mode: IPhoneReceiveArchiveMode) {
        recorded.append(mode)
    }

    func values() -> [IPhoneReceiveArchiveMode] {
        recorded
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

private struct MainQueueProbeBookmarkCodec: USBBookmarkCoding {
    func makeBookmark(for url: URL) throws -> Data { Data("bookmark".utf8) }

    func resolve(_ data: Data) throws -> USBBookmarkResolution {
        XCTAssertFalse(Thread.isMainThread, "External USB lookup must not run on the UI thread")
        let heartbeat = DispatchSemaphore(value: 0)
        DispatchQueue.main.async { heartbeat.signal() }
        XCTAssertEqual(
            heartbeat.wait(timeout: .now() + 2), .success,
            "The UI must process events while external bookmark lookup is waiting"
        )
        throw CocoaError(.fileReadNoSuchFile)
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
