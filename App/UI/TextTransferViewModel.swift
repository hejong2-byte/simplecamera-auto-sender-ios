import Foundation
import SwiftUI

enum TextTransferActivity: Equatable {
    case idle
    case refreshing
    case sending
    case retrying
}

enum TextTransferFailureKind: Equatable {
    case registration
    case authentication
    case network
    case storage
    case validation
    case server
    case other
}

@MainActor
final class TextTransferViewModel: ObservableObject {
    typealias LoadOwnCode = @Sendable () throws -> String?
    typealias Receive = @Sendable () async throws -> TextReceiveSummary
    typealias LoadHistory = @Sendable () async throws -> [TextStoredMessage]
    typealias Send = @Sendable (String, String) async throws -> TextStoredMessage
    typealias Retry = @Sendable (UUID) async throws -> TextStoredMessage
    typealias MarkRead = @Sendable (TextMessageKey) async throws -> Void
    typealias Delete = @Sendable (TextMessageKey) async throws -> Void
    typealias LoadDraft = @Sendable () async throws -> TextDraft
    typealias SaveDraft = @Sendable (TextDraft) async throws -> Void
    typealias LoadRecipients = @Sendable () async throws -> TextSavedRecipientState
    typealias SaveRecipient = @Sendable (String, String) async throws -> TextSavedRecipientState
    typealias SelectRecipient = @Sendable (String) async throws -> TextSavedRecipientState
    typealias DeleteRecipient = @Sendable (String) async throws -> TextSavedRecipientState
    typealias Sleep = @Sendable (Duration) async throws -> Void

    @Published var recipient = ""
    @Published var text = ""
    @Published private(set) var ownCode: String?
    @Published private(set) var messages: [TextStoredMessage] = []
    @Published private(set) var lastSummary: TextReceiveSummary?
    @Published private(set) var activity: TextTransferActivity = .idle
    @Published private(set) var statusMessage: String?
    @Published private(set) var lastError: String?
    @Published private(set) var lastErrorKind: TextTransferFailureKind?
    @Published private(set) var isMonitoring = false
    @Published private(set) var savedRecipients: [TextSavedRecipient] = []
    @Published private(set) var selectedRecipientCode: String?

    var unreadCount: Int {
        messages.filter {
            $0.key.direction == .received && $0.readAt == nil
        }.count
    }

    var canSend: Bool {
        guard activity == .idle, let ownCode else { return false }
        return (try? TextMessageEnvelope.make(
            sender: ownCode,
            recipient: recipient,
            text: text
        )) != nil
    }

    private let loadOwnCode: LoadOwnCode
    private let receive: Receive
    private let loadHistory: LoadHistory
    private let sendMessage: Send
    private let retryMessage: Retry
    private let markMessageRead: MarkRead
    private let deleteMessage: Delete
    private let loadDraft: LoadDraft
    private let persistDraft: SaveDraft
    private let loadRecipients: LoadRecipients
    private let persistRecipient: SaveRecipient
    private let persistRecipientSelection: SelectRecipient
    private let removeRecipient: DeleteRecipient
    private let sleep: Sleep
    private let now: @Sendable () -> Date
    private var monitorTask: Task<Void, Never>?
    private var generation = UUID()
    private var requestID: UUID?
    private var didLoadDraft = false

    init(
        loadOwnCode: @escaping LoadOwnCode,
        receive: @escaping Receive,
        loadHistory: @escaping LoadHistory,
        send: @escaping Send,
        retry: @escaping Retry,
        markRead: @escaping MarkRead,
        delete: @escaping Delete,
        loadDraft: @escaping LoadDraft,
        saveDraft: @escaping SaveDraft,
        loadRecipients: @escaping LoadRecipients,
        saveRecipient: @escaping SaveRecipient,
        selectRecipient: @escaping SelectRecipient,
        deleteRecipient: @escaping DeleteRecipient,
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.loadOwnCode = loadOwnCode
        self.receive = receive
        self.loadHistory = loadHistory
        sendMessage = send
        retryMessage = retry
        markMessageRead = markRead
        deleteMessage = delete
        self.loadDraft = loadDraft
        persistDraft = saveDraft
        self.loadRecipients = loadRecipients
        persistRecipient = saveRecipient
        persistRecipientSelection = selectRecipient
        removeRecipient = deleteRecipient
        self.sleep = sleep
        self.now = now
    }

    deinit { monitorTask?.cancel() }

    func setActive(_ active: Bool) {
        guard active != isMonitoring else { return }
        isMonitoring = active
        generation = UUID()
        monitorTask?.cancel()
        monitorTask = nil
        requestID = nil
        guard active else { return }

        let current = generation
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self,
                      self.isMonitoring,
                      self.generation == current else { return }
                await self.refresh(expectedGeneration: current)
                do {
                    try await self.sleep(.seconds(5))
                } catch {
                    return
                }
            }
        }
    }

    func refresh() async {
        await refresh(expectedGeneration: nil)
    }

    func send() async {
        guard activity == .idle else { return }
        activity = .sending
        clearError()
        let draft = TextDraft(recipient: recipient, text: text)
        do {
            try await persistDraft(draft)
            _ = try await sendMessage(draft.recipient, draft.text)
            messages = try await loadHistory()
            text = ""
            try await persistDraft(TextDraft(recipient: recipient, text: ""))
            statusMessage = "서버 전달 완료"
        } catch {
            record(error)
        }
        activity = .idle
    }

    func retry(_ id: UUID) async {
        guard activity == .idle else { return }
        activity = .retrying
        clearError()
        do {
            _ = try await retryMessage(id)
            messages = try await loadHistory()
            statusMessage = "재전송 완료"
        } catch {
            record(error)
        }
        activity = .idle
    }

    func markRead(_ key: TextMessageKey) async throws {
        do {
            try await markMessageRead(key)
            if let index = messages.firstIndex(where: { $0.key == key }) {
                messages[index].readAt = now()
            }
            clearError()
        } catch {
            record(error)
            throw error
        }
    }

    func delete(_ key: TextMessageKey) async throws {
        do {
            try await deleteMessage(key)
            messages.removeAll { $0.key == key }
            clearError()
        } catch {
            record(error)
            throw error
        }
    }

    func saveDraft() async {
        do {
            try await persistDraft(TextDraft(recipient: recipient, text: text))
            clearError()
        } catch {
            record(error)
        }
    }

    func recipientDidChange() {
        if recipient != selectedRecipientCode {
            selectedRecipientCode = nil
        }
    }

    func saveRecipient(name: String) async {
        clearError()
        do {
            let savedState = try await persistRecipient(recipient, name)
            applyRecipientState(savedState)
            let selectedState = try await persistRecipientSelection(recipient)
            applyRecipientState(selectedState)
            try await persistDraft(TextDraft(recipient: recipient, text: text))
            statusMessage = "수신코드 저장 완료"
        } catch {
            record(error)
        }
    }

    func selectRecipient(code: String) async {
        clearError()
        do {
            let state = try await persistRecipientSelection(code)
            recipient = code
            applyRecipientState(state)
            try await persistDraft(TextDraft(recipient: recipient, text: text))
            statusMessage = "수신코드 선택 완료"
        } catch {
            record(error)
        }
    }

    func deleteRecipient(code: String) async {
        clearError()
        do {
            let state = try await removeRecipient(code)
            applyRecipientState(state)
            statusMessage = "수신코드 삭제 완료"
        } catch {
            record(error)
        }
    }

    private func refresh(expectedGeneration: UUID?) async {
        guard activity == .idle, requestID == nil,
              isCurrent(expectedGeneration) else { return }
        let request = UUID()
        requestID = request
        activity = .refreshing
        defer {
            if requestID == request { requestID = nil }
            if activity == .refreshing { activity = .idle }
        }

        do {
            let code = try loadOwnCode()
            let draft = didLoadDraft ? nil : try await loadDraft()
            let localHistory = try await loadHistory()
            let recipientState = try await loadRecipients()
            guard isCurrent(expectedGeneration) else { return }
            ownCode = code
            if let draft {
                recipient = draft.recipient
                text = draft.text
                didLoadDraft = true
            }
            if recipient.isEmpty, let selectedCode = recipientState.selectedCode {
                recipient = selectedCode
            }
            applyRecipientState(recipientState)
            messages = localHistory

            let summary = try await receive()
            let refreshedHistory = try await loadHistory()
            guard isCurrent(expectedGeneration) else { return }
            messages = refreshedHistory
            lastSummary = summary
            statusMessage = receiveStatus(summary)
            clearError()
        } catch let error where error is CancellationError {
            return
        } catch {
            guard isCurrent(expectedGeneration) else { return }
            record(error)
        }
    }

    private func isCurrent(_ expectedGeneration: UUID?) -> Bool {
        guard let expectedGeneration else { return true }
        return isMonitoring && generation == expectedGeneration
    }

    private func receiveStatus(_ summary: TextReceiveSummary) -> String {
        if summary.received > 0 { return "새 텍스트 \(summary.received)개 수신" }
        if summary.pendingACK > 0 { return "저장 완료 · 서버 확인 대기 \(summary.pendingACK)개" }
        if summary.rejected > 0 { return "확인할 수 없는 텍스트 \(summary.rejected)개" }
        return "새 텍스트 없음"
    }

    private func clearError() {
        lastError = nil
        lastErrorKind = nil
    }

    private func applyRecipientState(_ state: TextSavedRecipientState) {
        savedRecipients = state.recipients
        selectedRecipientCode = state.selectedCode == recipient ? state.selectedCode : nil
    }

    private func record(_ error: Error) {
        let result = Self.describe(error)
        statusMessage = nil
        lastErrorKind = result.kind
        lastError = result.message
    }

    private static func describe(_ error: Error) -> (kind: TextTransferFailureKind, message: String) {
        if let serviceError = error as? TextTransferServiceError {
            switch serviceError {
            case .missingRegistration:
                return (.registration, "수신 코드 등록이 필요합니다.")
            case .missingUploadCredential:
                return (.authentication, "전송 인증 설정이 필요합니다.")
            case .messageNotFound:
                return (.storage, "저장된 텍스트를 찾지 못했습니다.")
            case .messageNotRetryable:
                return (.validation, "재전송 대기 중인 텍스트가 아닙니다.")
            case .senderChanged:
                return (.registration, "현재 수신 코드와 보낸 코드가 다릅니다.")
            }
        }
        if error is CredentialStoreError {
            return (.authentication, "인증 정보를 읽지 못했습니다.")
        }
        if error is TextMessageStoreError || (error as NSError).domain == NSCocoaErrorDomain {
            return (.storage, "텍스트를 iPhone에 저장하지 못했습니다.")
        }
        if error is URLError || (error as NSError).domain == NSURLErrorDomain {
            return (.network, "네트워크 연결을 확인해 주세요.")
        }
        if let clientError = error as? TextTransferClientError {
            switch clientError {
            case .emptyCredential:
                return (.authentication, "전송 인증 설정이 필요합니다.")
            case let .server(statusCode, _) where statusCode == 401 || statusCode == 403:
                return (.authentication, "서버 인증에 실패했습니다.")
            case let .server(statusCode, code):
                let suffix = code.map { " (\($0))" } ?? ""
                return (.server, "서버 오류 \(statusCode)\(suffix)")
            case .invalidResponse, .invalidRemoteItem, .protocolMismatch:
                return (.server, "서버 응답을 확인할 수 없습니다.")
            }
        }
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription {
            return (.validation, description)
        }
        return (.other, "텍스트 작업에 실패했습니다. \(error.localizedDescription)")
    }
}
