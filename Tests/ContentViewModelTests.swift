import XCTest
@testable import SimpleCameraAutoSender

@MainActor
final class ContentViewModelTests: XCTestCase {
    func testDocumentTransferNeedsCredentialButNotPhotoAccessAndLeavesAutomaticLedgerAlone() async throws {
        let ledger = try UploadLedger(fileURL: temporaryLedgerURL())
        let baseline = Date(timeIntervalSince1970: 1_234)
        try await ledger.setBaseline(baseline)
        try await ledger.recordDiscovery(id: "existing-auto-photo", createdAt: baseline)
        let before = await ledger.allRecords()
        let url = URL(fileURLWithPath: "/synthetic/selected.pdf")
        let feed = ManualProgressFeed()
        let model = ContentViewModel(credentialStore: InMemoryCredentialStore(), ledger: ledger,
            uploader: NoOpUploader(), now: Date.init,
            send: { _ in XCTFail("Document input must not trigger automatic sync"); return .init(discovered: 0, matched: 0, uploaded: 0, failed: 0) },
            manualFileEnqueue: { urls in
                XCTAssertEqual(urls, [url])
                return .init(selected: 1, uploaded: 0, failed: 0, failureCategories: [])
            }, manualUpdates: { feed.stream }, photoAuthorizationStatus: .denied)
        XCTAssertNotNil(model.fileTransferReadinessMessage)
        try await model.saveCredential("Bearer synthetic-test")
        XCTAssertNil(model.fileTransferReadinessMessage)
        XCTAssertNotNil(model.manualTransferReadinessMessage)
        await model.sendSelectedFiles([url])
        XCTAssertTrue(model.isManualTransferWorking)
        feed.yield(progress(kind: .file, stage: .uploading, selected: 1, currentIndex: 1,
            totalBytes: 100, confirmedBytes: 20, taskBytesSent: 30))
        await waitUntil { model.manualProgress?.percent == 50 }
        XCTAssertEqual(model.manualProgress?.percent, 50)
        feed.yield(progress(kind: .file, stage: .completed, selected: 1, currentIndex: 1,
            uploaded: 1, totalBytes: 100, confirmedBytes: 100))
        await waitUntil { !model.isManualTransferWorking }
        XCTAssertEqual(model.lastManualSummary?.uploaded, 1)
        let after = await ledger.allRecords()
        let afterBaseline = try await ledger.baseline()
        XCTAssertEqual(after, before)
        XCTAssertEqual(afterBaseline, baseline)
    }

    func testCancelledFilePickerChangesNoCountersAndMissingCredentialNeverEnqueues() async throws {
        let model = ContentViewModel(credentialStore: InMemoryCredentialStore(),
            ledger: try UploadLedger(fileURL: temporaryLedgerURL()), uploader: NoOpUploader(), now: Date.init,
            send: { _ in .init(discovered: 0, matched: 0, uploaded: 0, failed: 0) },
            manualFileEnqueue: { _ in XCTFail("No enqueue expected"); return .empty },
            photoAuthorizationStatus: .denied)
        await model.sendSelectedFiles([])
        XCTAssertNil(model.lastManualSummary)
        XCTAssertNil(model.manualTransferMessage)
        await model.sendSelectedFiles([URL(fileURLWithPath: "/selected.pdf")])
        XCTAssertNil(model.lastManualSummary)
        XCTAssertTrue(model.manualTransferMessage?.contains("인증값") == true)
        XCTAssertFalse(model.isManualTransferWorking)
    }

    func testEnableAutomaticSendingRecordsCurrentBaseline() async throws {
        let ledger = try UploadLedger(fileURL: temporaryLedgerURL())
        let expected = Date(timeIntervalSince1970: 1_234)
        let model = ContentViewModel(
            credentialStore: InMemoryCredentialStore(),
            ledger: ledger,
            uploader: NoOpUploader(),
            now: { expected },
            send: { _ in SyncTransferSummary(discovered: 0, matched: 0, uploaded: 0, failed: 0) }
        )

        try await model.enableAutomaticSending()

        let baseline = try await ledger.baseline()
        XCTAssertEqual(baseline, expected)
    }

    func testSaveCredentialNeverPublishesStoredValue() async throws {
        let ledger = try UploadLedger(fileURL: temporaryLedgerURL())
        let model = ContentViewModel(
            credentialStore: InMemoryCredentialStore(),
            ledger: ledger,
            uploader: NoOpUploader(),
            now: Date.init,
            send: { _ in SyncTransferSummary(discovered: 0, matched: 0, uploaded: 0, failed: 0) }
        )

        try await model.saveCredential("secret-value")

        XCTAssertTrue(model.hasCredential)
        XCTAssertFalse(String(describing: model).contains("secret-value"))
    }

    func testManualProgressPublishesPercentCountersAndStableFailureMessage() async throws {
        let ledger = try UploadLedger(fileURL: temporaryLedgerURL())
        let credentials = InMemoryCredentialStore()
        try credentials.save("Bearer test")
        let feed = ManualProgressFeed()
        let model = ContentViewModel(
            credentialStore: credentials,
            ledger: ledger,
            uploader: NoOpUploader(),
            now: Date.init,
            send: { _ in SyncTransferSummary(discovered: 0, matched: 0, uploaded: 0, failed: 0) },
            manualEnqueue: { selection, kind in
                XCTAssertEqual(selection.assetIdentifiers, ["a", "b"])
                XCTAssertEqual(kind, .video)
                return ManualMediaTransferSummary(
                    selected: 2,
                    uploaded: 0,
                    failed: 0,
                    failureCategories: []
                )
            },
            manualUpdates: { feed.stream },
            photoAuthorizationStatus: .authorized
        )
        try await model.saveCredential("Bearer test")

        await model.sendSelectedMedia(
            selection: ManualMediaSelection(
                assetIdentifiers: ["a", "b"],
                unavailableCount: 0
            ),
            kind: .video
        )
        XCTAssertTrue(model.isManualTransferWorking)

        feed.yield(progress(
            stage: .preparing,
            selected: 2,
            currentIndex: 1
        ))
        await waitUntil { model.manualProgress?.stage == .preparing }

        feed.yield(progress(
            stage: .uploading,
            selected: 2,
            currentIndex: 1,
            totalBytes: 200,
            confirmedBytes: 100,
            taskBytesSent: 34
        ))
        await waitUntil { model.manualProgress?.percent == 67 }
        XCTAssertEqual(model.manualProgress?.percent, 67)
        XCTAssertEqual(model.manualByteProgressText, "134바이트 / 200바이트")

        feed.yield(progress(
            stage: .retrying,
            selected: 2,
            currentIndex: 1,
            totalBytes: 200,
            confirmedBytes: 100,
            retryAttempt: 1
        ))
        await waitUntil { model.manualProgress?.stage == .retrying }
        XCTAssertTrue(model.isManualTransferWorking)

        feed.yield(progress(
            stage: .failed,
            selected: 2,
            currentIndex: 2,
            uploaded: 1,
            failed: 1,
            totalBytes: 200,
            confirmedBytes: 100,
            failure: .server(statusCode: 422, code: "size_mismatch")
        ))
        await waitUntil { model.manualProgress?.stage == .failed }

        XCTAssertEqual(model.manualProgress?.uploadedCount, 1)
        XCTAssertEqual(model.manualProgress?.failedCount, 1)
        XCTAssertEqual(
            model.manualTransferMessage,
            "동영상 전송 실패 · 서버 크기 검증 실패 (HTTP 422)"
        )
        XCTAssertFalse(model.isManualTransferWorking)
    }

    func testCompletedProgressEndsManualWorkingState() async throws {
        let ledger = try UploadLedger(fileURL: temporaryLedgerURL())
        let credentials = InMemoryCredentialStore()
        try credentials.save("Bearer test")
        let feed = ManualProgressFeed()
        let model = ContentViewModel(
            credentialStore: credentials,
            ledger: ledger,
            uploader: NoOpUploader(),
            now: Date.init,
            send: { _ in SyncTransferSummary(discovered: 0, matched: 0, uploaded: 0, failed: 0) },
            manualEnqueue: { _, _ in
                .init(selected: 1, uploaded: 0, failed: 0, failureCategories: [])
            },
            manualUpdates: { feed.stream },
            photoAuthorizationStatus: .authorized
        )
        try await model.saveCredential("Bearer test")
        await model.sendSelectedMedia(
            selection: .init(assetIdentifiers: ["a"], unavailableCount: 0),
            kind: .photo
        )

        feed.yield(progress(
            kind: .photo,
            stage: .completed,
            selected: 1,
            currentIndex: 1,
            uploaded: 1,
            totalBytes: 10,
            confirmedBytes: 10
        ))
        await waitUntil { model.manualProgress?.stage == .completed }

        XCTAssertFalse(model.isManualTransferWorking)
        XCTAssertEqual(model.manualTransferMessage, "사진 전송 완료 · 1개")
    }

    func testRefreshPublishesAutomaticServerFailureMessage() async throws {
        let ledger = try UploadLedger(fileURL: temporaryLedgerURL())
        try await ledger.recordDiscovery(id: "server-photo", createdAt: .now)
        try await ledger.markFailed(id: "server-photo", category: .server)
        let model = ContentViewModel(
            credentialStore: InMemoryCredentialStore(),
            ledger: ledger,
            uploader: NoOpUploader(),
            now: Date.init,
            send: { _ in SyncTransferSummary(discovered: 0, matched: 0, uploaded: 0, failed: 0) },
            photoAuthorizationStatus: .authorized
        )

        await model.refresh()

        XCTAssertEqual(model.automaticFailureMessage, "서버 오류")
    }

    func testAutomaticProgressReplaysByteStatusAndServerFailure() async throws {
        let ledger = try UploadLedger(fileURL: temporaryLedgerURL())
        let progressStore = AutomaticTransferProgressStore()
        progressStore.publish(AutomaticTransferProgress(
            runID: UUID(),
            stage: .uploading,
            currentIndex: 2,
            totalCount: 3,
            uploadedCount: 1,
            failedCount: 0,
            totalBytes: 1_000,
            completedBytes: 400,
            currentBytesSent: 250,
            currentBytesTotal: 300,
            failureCategories: []
        ))
        let model = ContentViewModel(
            credentialStore: InMemoryCredentialStore(),
            ledger: ledger,
            uploader: NoOpUploader(),
            now: Date.init,
            send: { _ in
                SyncTransferSummary(
                    discovered: 0,
                    matched: 0,
                    uploaded: 0,
                    failed: 0
                )
            },
            automaticUpdates: { progressStore.updates() },
            photoAuthorizationStatus: .authorized
        )

        await waitUntil { model.automaticProgress?.percent == 65 }

        XCTAssertEqual(model.automaticStageTitle, "PC로 자동전송 중 · 2/3장")
        XCTAssertEqual(
            model.automaticByteProgressText,
            "650바이트 / 1000바이트"
        )

        progressStore.publish(AutomaticTransferProgress(
            runID: UUID(),
            stage: .failed,
            currentIndex: 3,
            totalCount: 3,
            uploadedCount: 2,
            failedCount: 1,
            totalBytes: 1_000,
            completedBytes: 700,
            currentBytesSent: 0,
            currentBytesTotal: 0,
            failureCategories: [.server]
        ))
        await waitUntil { model.automaticProgress?.stage == .failed }

        XCTAssertEqual(
            model.automaticTransferMessage,
            "자동전송 실패 포함 · 서버 오류"
        )
    }

    func testEmptyAutomaticRunDoesNotClaimZeroPhotoCompletion() async throws {
        let ledger = try UploadLedger(fileURL: temporaryLedgerURL())
        let store = AutomaticTransferProgressStore()
        var empty = AutomaticTransferProgress.idle()
        empty.stage = .completed
        store.publish(empty)
        let model = ContentViewModel(
            credentialStore: InMemoryCredentialStore(), ledger: ledger,
            uploader: NoOpUploader(), now: Date.init,
            send: { _ in .init(discovered: 0, matched: 0, uploaded: 0, failed: 0) },
            automaticUpdates: { store.updates() }
        )
        await waitUntil { model.automaticProgress?.stage == .completed }

        XCTAssertEqual(model.automaticStageTitle, "전송할 새 사진 없음")
        XCTAssertEqual(model.automaticTransferMessage, "전송할 새 Simple Cam 사진이 없습니다.")
    }

    func testManualCompletionDoesNotResetActiveAutomaticProgressOrStartNewRun() async throws {
        let ledger = try UploadLedger(fileURL: temporaryLedgerURL())
        let store = AutomaticTransferProgressStore()
        let feed = ManualProgressFeed()
        var automatic = AutomaticTransferProgress.idle()
        automatic.stage = .uploading
        automatic.totalCount = 11
        automatic.currentIndex = 4
        automatic.uploadedCount = 3
        store.publish(automatic)
        let model = ContentViewModel(
            credentialStore: InMemoryCredentialStore(), ledger: ledger,
            uploader: NoOpUploader(), now: Date.init,
            send: { _ in
                XCTFail("Manual progress must not trigger automatic scanning.")
                return .init(discovered: 0, matched: 0, uploaded: 0, failed: 0)
            },
            manualUpdates: { feed.stream },
            automaticUpdates: { store.updates() }
        )
        await waitUntil { model.automaticProgress?.stage == .uploading }
        feed.yield(progress(
            stage: .completed, selected: 1, currentIndex: 1, uploaded: 1,
            totalBytes: 350_000_000, confirmedBytes: 350_000_000
        ))
        await waitUntil { model.manualProgress?.stage == .completed }
        await model.refresh()

        XCTAssertEqual(model.automaticProgress, automatic)
        XCTAssertEqual(model.automaticStageTitle, "PC로 자동전송 중 · 4/11장")
        XCTAssertEqual(model.manualProgress?.uploadedCount, 1)
    }

    func testAutomaticCompletionRefreshesStaleLedgerFailureMessage() async throws {
        let ledger = try UploadLedger(fileURL: temporaryLedgerURL())
        try await ledger.recordDiscovery(id: "recovered", createdAt: .now)
        try await ledger.markFailed(id: "recovered", category: .server)
        let store = AutomaticTransferProgressStore()
        let model = ContentViewModel(
            credentialStore: InMemoryCredentialStore(), ledger: ledger,
            uploader: NoOpUploader(), now: Date.init,
            send: { _ in .init(discovered: 0, matched: 0, uploaded: 0, failed: 0) },
            automaticUpdates: { store.updates() }
        )
        await model.refresh()
        XCTAssertEqual(model.automaticFailureMessage, "서버 오류")

        try await ledger.markUploaded(id: "recovered")
        var completed = AutomaticTransferProgress.idle()
        completed.stage = .completed
        completed.uploadedCount = 1
        completed.totalCount = 1
        store.publish(completed)
        await waitUntil {
            model.automaticProgress?.stage == .completed
                && model.automaticFailureMessage == nil
        }

        XCTAssertNil(model.automaticFailureMessage)
        XCTAssertEqual(model.failedCount, 0)
        XCTAssertEqual(model.uploadedCount, 1)
    }

    private func temporaryLedgerURL() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("ledger.json")
    }

    private func progress(
        kind: ManualMediaKind = .video,
        stage: ManualTransferStage,
        selected: Int,
        currentIndex: Int,
        uploaded: Int = 0,
        failed: Int = 0,
        totalBytes: Int64 = 0,
        confirmedBytes: Int64 = 0,
        taskBytesSent: Int64 = 0,
        retryAttempt: Int = 0,
        failure: ManualTransferFailure? = nil
    ) -> ManualTransferProgress {
        ManualTransferProgress(
            batchID: UUID(),
            kind: kind,
            selectedCount: selected,
            currentIndex: currentIndex,
            uploadedCount: uploaded,
            failedCount: failed,
            stage: stage,
            totalBytes: totalBytes,
            confirmedBytes: confirmedBytes,
            taskBytesSent: taskBytesSent,
            retryAttempt: retryAttempt,
            failure: failure
        )
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("진행률 이벤트가 시간 안에 반영되지 않았습니다.")
    }
}

private final class ManualProgressFeed: @unchecked Sendable {
    let stream: AsyncStream<ManualTransferProgress>
    private let continuation: AsyncStream<ManualTransferProgress>.Continuation

    init() {
        let pair = AsyncStream.makeStream(of: ManualTransferProgress.self)
        stream = pair.stream
        continuation = pair.continuation
    }

    func yield(_ progress: ManualTransferProgress) {
        continuation.yield(progress)
    }
}

private final class NoOpUploader: UploadCoordinating, @unchecked Sendable {
    func upload(
        assetID: String,
        fileURL: URL,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {}
    func authenticationBlocked() -> Bool { false }
    func credentialDidChange() {}
}
