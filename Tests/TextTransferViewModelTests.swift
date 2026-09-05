import XCTest
@testable import SimpleCameraAutoSender

@MainActor
final class TextTransferViewModelTests: XCTestCase {
    func testActivationRefreshesImmediatelyRepeatsEveryFiveSecondsAndStops() async {
        let probe = TextViewModelProbe()
        let clock = TextPollClock()
        let model = makeModel(probe: probe, clock: clock)

        model.setActive(true)
        await waitUntil { await probe.receiveCount() == 1 }
        await clock.advance()
        await waitUntil { await probe.receiveCount() == 2 }
        model.setActive(false)
        await clock.advanceAll()
        for _ in 0..<10 { await Task.yield() }

        let durations = await clock.durations()
        let receiveCount = await probe.receiveCount()
        XCTAssertEqual(durations.first, .seconds(5))
        XCTAssertEqual(receiveCount, 2)
        XCTAssertFalse(model.isMonitoring)
    }

    func testRefreshNeverOverlapsAndLateInactiveResultIsIgnored() async {
        let probe = TextViewModelProbe(blocksReceive: true)
        let clock = TextPollClock()
        let model = makeModel(probe: probe, clock: clock)
        model.setActive(true)
        await waitUntil { await probe.receiveCount() == 1 }

        let manual = Task { await model.refresh() }
        for _ in 0..<10 { await Task.yield() }
        let receiveCount = await probe.receiveCount()
        let maximumConcurrentReceives = await probe.maximumConcurrentReceives()
        XCTAssertEqual(receiveCount, 1)
        XCTAssertEqual(maximumConcurrentReceives, 1)

        model.setActive(false)
        await probe.releaseReceive()
        await manual.value
        XCTAssertTrue(model.messages.isEmpty)
        XCTAssertNil(model.lastSummary)
    }

    func testUnreadCountRemainsUntilMarkReadSucceeds() async throws {
        let probe = TextViewModelProbe(history: [try receivedMessage(readAt: nil)])
        let model = makeModel(probe: probe)
        await model.refresh()
        XCTAssertEqual(model.unreadCount, 1)

        try await model.markRead(model.messages[0].key)

        XCTAssertEqual(model.unreadCount, 0)
        XCTAssertNotNil(model.messages[0].readAt)
    }

    func testDraftLoadsAndSavesExactly() async {
        let original = TextDraft(recipient: "123456", text: "  작성 중\n")
        let probe = TextViewModelProbe(draft: original)
        let model = makeModel(probe: probe)
        await model.refresh()
        XCTAssertEqual(model.recipient, original.recipient)
        XCTAssertEqual(model.text, original.text)

        model.recipient = "654321"
        model.text = "\t수정본\n"
        await model.saveDraft()

        let savedDraft = await probe.savedDraft()
        XCTAssertEqual(savedDraft, TextDraft(recipient: "654321", text: "\t수정본\n"))
    }

    func testSendAndRetryExposeBusyStatesAndRefreshHistory() async throws {
        let sendGate = TextOperationGate()
        let retryGate = TextOperationGate()
        let pending = try sentMessage(status: .pending)
        let probe = TextViewModelProbe(
            history: [pending],
            sendGate: sendGate,
            retryGate: retryGate
        )
        let model = makeModel(probe: probe)
        model.recipient = "123456"
        model.text = "보낼 본문"

        let sendTask = Task { await model.send() }
        await sendGate.waitUntilEntered()
        XCTAssertEqual(model.activity, .sending)
        await sendGate.release()
        await sendTask.value
        XCTAssertEqual(model.activity, .idle)
        XCTAssertEqual(model.statusMessage, "서버 전달 완료")

        await probe.replaceHistory([pending])
        let retryTask = Task { await model.retry(pending.envelope.id) }
        await retryGate.waitUntilEntered()
        XCTAssertEqual(model.activity, .retrying)
        await retryGate.release()
        await retryTask.value
        let retryCount = await probe.retryCount()
        XCTAssertEqual(model.activity, .idle)
        XCTAssertEqual(retryCount, 1)
    }

    func testErrorsDistinguishRegistrationAuthenticationNetworkAndStorage() async {
        let cases: [(Error, TextTransferFailureKind)] = [
            (TextTransferServiceError.missingRegistration, .registration),
            (TextTransferServiceError.missingUploadCredential, .authentication),
            (URLError(.notConnectedToInternet), .network),
            (CocoaError(.fileWriteNoPermission), .storage)
        ]
        for (error, expected) in cases {
            let probe = TextViewModelProbe(receiveError: error)
            let model = makeModel(probe: probe)
            await model.refresh()
            XCTAssertEqual(model.lastErrorKind, expected)
            XCTAssertNotNil(model.lastError)
        }
    }

    func testSavedRecipientsLoadSelectRenameDeleteAndClearSelectionOnManualEdit() async {
        let saved = TextSavedRecipientState(
            recipients: [TextSavedRecipient(code: "709592", name: "행정망 PC")],
            selectedCode: "709592"
        )
        let probe = TextViewModelProbe(
            draft: TextDraft(recipient: "709592", text: ""),
            recipients: saved
        )
        let model = makeModel(probe: probe)

        await model.refresh()
        XCTAssertEqual(model.savedRecipients.map(\.displayLabel), ["행정망 PC · 709592"])
        XCTAssertEqual(model.selectedRecipientCode, "709592")

        await model.selectRecipient(code: "709592")
        XCTAssertEqual(model.recipient, "709592")
        XCTAssertEqual(model.selectedRecipientCode, "709592")

        model.recipient = "123456"
        model.recipientDidChange()
        XCTAssertNil(model.selectedRecipientCode)

        model.recipient = "709592"
        await model.saveRecipient(name: "행정망 업무 PC")
        XCTAssertEqual(model.savedRecipients.first?.displayLabel, "행정망 업무 PC · 709592")
        XCTAssertEqual(model.selectedRecipientCode, "709592")

        await model.deleteRecipient(code: "709592")
        XCTAssertTrue(model.savedRecipients.isEmpty)
        XCTAssertNil(model.selectedRecipientCode)
        XCTAssertEqual(model.recipient, "709592", "Deleting a shortcut must keep the draft code")
    }

    func testSelectingSavedRecipientPersistsTheDraft() async {
        let probe = TextViewModelProbe(recipients: TextSavedRecipientState(
            recipients: [TextSavedRecipient(code: "123456", name: "아이폰")],
            selectedCode: nil
        ))
        let model = makeModel(probe: probe)
        await model.refresh()

        await model.selectRecipient(code: "123456")

        let savedDraft = await probe.savedDraft()
        XCTAssertEqual(savedDraft.recipient, "123456")
        XCTAssertEqual(model.statusMessage, "수신코드 선택 완료")
    }

    func testRenamingSavedRecipientDoesNotChangeCurrentDraftRecipient() async {
        let probe = TextViewModelProbe(
            draft: TextDraft(recipient: "123456", text: "작성 중"),
            recipients: TextSavedRecipientState(
                recipients: [TextSavedRecipient(code: "709592", name: "행정망 PC")],
                selectedCode: nil
            )
        )
        let model = makeModel(probe: probe)
        await model.refresh()

        await model.renameRecipient(code: "709592", name: "행정망 업무 PC")

        XCTAssertEqual(model.recipient, "123456")
        XCTAssertNil(model.selectedRecipientCode)
        XCTAssertEqual(
            model.savedRecipients.map(\.displayLabel),
            ["행정망 업무 PC · 709592"]
        )
    }

    func testSavedRecipientsRemainVisibleWhenNetworkRefreshFails() async {
        let probe = TextViewModelProbe(
            receiveError: URLError(.notConnectedToInternet),
            recipients: TextSavedRecipientState(
                recipients: [TextSavedRecipient(code: "709592", name: "행정망 PC")],
                selectedCode: nil
            )
        )
        let model = makeModel(probe: probe)

        await model.refresh()

        XCTAssertEqual(model.savedRecipients.map(\.displayLabel), ["행정망 PC · 709592"])
        XCTAssertEqual(model.lastErrorKind, .network)
    }

    func testRecipientValidationErrorUsesSpecificMessageWithoutStoppingMonitoring() async {
        let probe = TextViewModelProbe(recipientMutationError: .limitReached)
        let model = makeModel(probe: probe)
        model.recipient = "123456"

        await model.saveRecipient(name: "여섯째")

        XCTAssertEqual(model.lastErrorKind, .validation)
        XCTAssertEqual(model.lastError, "수신코드는 최대 5개까지 저장할 수 있습니다.")
        model.setActive(true)
        XCTAssertTrue(model.isMonitoring)
        model.setActive(false)
    }

    private func makeModel(
        probe: TextViewModelProbe,
        clock: TextPollClock = TextPollClock()
    ) -> TextTransferViewModel {
        TextTransferViewModel(
            loadOwnCode: { "654321" },
            receive: { try await probe.receive() },
            loadHistory: { try await probe.loadHistory() },
            send: { recipient, text in try await probe.send(recipient: recipient, text: text) },
            retry: { id in try await probe.retry(id: id) },
            markRead: { key in try await probe.markRead(key) },
            delete: { key in try await probe.delete(key) },
            loadDraft: { try await probe.loadDraft() },
            saveDraft: { draft in try await probe.saveDraft(draft) },
            loadRecipients: { try await probe.loadRecipients() },
            saveRecipient: { code, name in
                try await probe.saveRecipient(code: code, name: name)
            },
            selectRecipient: { code in try await probe.selectRecipient(code: code) },
            deleteRecipient: { code in try await probe.deleteRecipient(code: code) },
            sleep: { duration in try await clock.sleep(for: duration) },
            now: { Date(timeIntervalSince1970: 1_778_115_723) }
        )
    }

    private func receivedMessage(readAt: Date?) throws -> TextStoredMessage {
        let envelope = try TextMessageEnvelope.make(
            sender: "123456",
            recipient: "654321",
            text: "받은 본문",
            id: UUID(uuidString: "123e4567-e89b-42d3-a456-426614174111")!,
            now: Date(timeIntervalSince1970: 1_778_115_723)
        )
        return TextStoredMessage(
            key: TextMessageKey(direction: .received, id: envelope.id),
            envelope: envelope,
            bodySHA256: TextDigest.hex(try envelope.encoded()),
            status: .received,
            readAt: readAt
        )
    }

    private func sentMessage(status: TextMessageDeliveryStatus) throws -> TextStoredMessage {
        let envelope = try TextMessageEnvelope.make(
            sender: "654321",
            recipient: "123456",
            text: "보낼 본문",
            id: UUID(uuidString: "123e4567-e89b-42d3-a456-426614174222")!,
            now: Date(timeIntervalSince1970: 1_778_115_723)
        )
        return TextStoredMessage(
            key: TextMessageKey(direction: .sent, id: envelope.id),
            envelope: envelope,
            bodySHA256: TextDigest.hex(try envelope.encoded()),
            status: status,
            readAt: nil
        )
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 2_000_000_000,
        _ condition: @escaping @Sendable () async -> Bool
    ) async {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out")
    }
}

private actor TextViewModelProbe {
    private var storedHistory: [TextStoredMessage]
    private var storedDraft: TextDraft
    private let receiveError: Error?
    private let blocksReceive: Bool
    private let sendGate: TextOperationGate?
    private let retryGate: TextOperationGate?
    private var recipientState: TextSavedRecipientState
    private let recipientMutationError: TextSavedRecipientStoreError?
    private var receiveCalls = 0
    private var activeReceives = 0
    private var maximumReceives = 0
    private var receiveContinuation: CheckedContinuation<Void, Never>?
    private var retries = 0

    init(
        history: [TextStoredMessage] = [],
        draft: TextDraft = .empty,
        receiveError: Error? = nil,
        blocksReceive: Bool = false,
        sendGate: TextOperationGate? = nil,
        retryGate: TextOperationGate? = nil,
        recipients: TextSavedRecipientState = .empty,
        recipientMutationError: TextSavedRecipientStoreError? = nil
    ) {
        storedHistory = history
        storedDraft = draft
        self.receiveError = receiveError
        self.blocksReceive = blocksReceive
        self.sendGate = sendGate
        self.retryGate = retryGate
        recipientState = recipients
        self.recipientMutationError = recipientMutationError
    }

    func receive() async throws -> TextReceiveSummary {
        receiveCalls += 1
        activeReceives += 1
        maximumReceives = max(maximumReceives, activeReceives)
        defer { activeReceives -= 1 }
        if blocksReceive {
            await withCheckedContinuation { receiveContinuation = $0 }
        }
        if let receiveError { throw receiveError }
        return TextReceiveSummary(received: 0, duplicates: 0, rejected: 0, pendingACK: 0)
    }

    func releaseReceive() { receiveContinuation?.resume(); receiveContinuation = nil }
    func receiveCount() -> Int { receiveCalls }
    func maximumConcurrentReceives() -> Int { maximumReceives }
    func loadHistory() throws -> [TextStoredMessage] { storedHistory }
    func replaceHistory(_ messages: [TextStoredMessage]) { storedHistory = messages }
    func loadDraft() throws -> TextDraft { storedDraft }
    func savedDraft() -> TextDraft { storedDraft }
    func saveDraft(_ draft: TextDraft) throws { storedDraft = draft }

    func loadRecipients() throws -> TextSavedRecipientState { recipientState }

    func saveRecipient(code: String, name: String) throws -> TextSavedRecipientState {
        if let recipientMutationError { throw recipientMutationError }
        if let index = recipientState.recipients.firstIndex(where: { $0.code == code }) {
            recipientState.recipients[index].name = name
        } else {
            recipientState.recipients.append(TextSavedRecipient(code: code, name: name))
        }
        return recipientState
    }

    func selectRecipient(code: String) throws -> TextSavedRecipientState {
        if let recipientMutationError { throw recipientMutationError }
        recipientState.selectedCode = code
        return recipientState
    }

    func deleteRecipient(code: String) throws -> TextSavedRecipientState {
        if let recipientMutationError { throw recipientMutationError }
        recipientState.recipients.removeAll { $0.code == code }
        if recipientState.selectedCode == code { recipientState.selectedCode = nil }
        return recipientState
    }

    func send(recipient: String, text: String) async throws -> TextStoredMessage {
        if let sendGate { await sendGate.enter() }
        let envelope = try TextMessageEnvelope.make(
            sender: "654321",
            recipient: recipient,
            text: text,
            now: Date(timeIntervalSince1970: 1_778_115_723)
        )
        let message = TextStoredMessage(
            key: TextMessageKey(direction: .sent, id: envelope.id),
            envelope: envelope,
            bodySHA256: TextDigest.hex(try envelope.encoded()),
            status: .serverDelivered,
            readAt: nil
        )
        storedHistory.insert(message, at: 0)
        return message
    }

    func retry(id: UUID) async throws -> TextStoredMessage {
        retries += 1
        if let retryGate { await retryGate.enter() }
        guard let index = storedHistory.firstIndex(where: { $0.envelope.id == id }) else {
            throw TextTransferServiceError.messageNotFound
        }
        storedHistory[index].status = .serverDelivered
        return storedHistory[index]
    }

    func retryCount() -> Int { retries }

    func markRead(_ key: TextMessageKey) throws {
        guard let index = storedHistory.firstIndex(where: { $0.key == key }) else {
            throw TextTransferServiceError.messageNotFound
        }
        storedHistory[index].readAt = Date(timeIntervalSince1970: 1_778_115_723)
    }

    func delete(_ key: TextMessageKey) throws {
        storedHistory.removeAll { $0.key == key }
    }
}

private actor TextPollClock {
    private var recordedDurations: [Duration] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var permits = 0

    func sleep(for duration: Duration) async throws {
        recordedDurations.append(duration)
        if permits > 0 {
            permits -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
        try Task.checkCancellation()
    }

    func advance() {
        guard !waiters.isEmpty else {
            permits += 1
            return
        }
        waiters.removeFirst().resume()
    }

    func advanceAll() {
        let current = waiters
        waiters.removeAll()
        current.forEach { $0.resume() }
    }

    func durations() -> [Duration] { recordedDurations }
}

private actor TextOperationGate {
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?

    func enter() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilEntered() async {
        while !entered { await Task.yield() }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
