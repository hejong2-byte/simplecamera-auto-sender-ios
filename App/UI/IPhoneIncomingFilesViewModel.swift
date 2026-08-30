import Foundation

struct IPhoneIncomingSnapshot: Sendable {
    let receiverID: UUID?
    let files: [IPhoneDelivery]
}

struct IPhoneIncomingBatch: Identifiable, Equatable {
    let id = UUID()
    let receiverID: UUID
    let files: [IPhoneDelivery]

    var totalBytes: Int64 {
        files.reduce(0) { total, file in
            let result = total.addingReportingOverflow(max(0, file.size))
            return result.overflow ? Int64.max : result.partialValue
        }
    }

    var title: String { "PC 파일 \(files.count)개가 도착했습니다" }
    var message: String {
        let names = files.prefix(3).map(\.fileName).joined(separator: "\n")
        let remaining = files.count > 3 ? "\n외 \(files.count - 3)개" : ""
        let size = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        return "\(names)\(remaining)\n총 \(size)\n저장할 위치를 선택하세요."
    }
}

@MainActor
final class IPhoneIncomingFilesViewModel: ObservableObject {
    typealias LoadPendingFiles = @Sendable () async throws -> IPhoneIncomingSnapshot
    typealias ApproveFiles = @Sendable (UUID, Set<UUID>, IPhoneReceiveDestination) throws -> Void

    @Published private(set) var pendingFiles: [IPhoneDelivery] = []
    @Published private(set) var prompt: IPhoneIncomingBatch?
    @Published private(set) var lastError: String?
    @Published private(set) var isMonitoring = false

    private let loadPendingFiles: LoadPendingFiles
    private let approveFiles: ApproveFiles
    private let sleep: @Sendable () async throws -> Void
    private var receiverID: UUID?
    private var offeredIDs: Set<UUID> = []
    private var acceptedIDs: Set<UUID> = []
    private var monitorTask: Task<Void, Never>?
    private var generation = UUID()
    private var requestID: UUID?

    init(
        loadPendingFiles: @escaping LoadPendingFiles,
        approveFiles: @escaping ApproveFiles,
        sleep: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(1)) }
    ) {
        self.loadPendingFiles = loadPendingFiles
        self.approveFiles = approveFiles
        self.sleep = sleep
    }

    deinit { monitorTask?.cancel() }

    func setActive(_ active: Bool) {
        guard active != isMonitoring else { return }
        isMonitoring = active
        generation = UUID()
        monitorTask?.cancel()
        monitorTask = nil
        requestID = nil
        if !active {
            if let prompt { offeredIDs.subtract(prompt.files.map(\.deliveryID)) }
            prompt = nil
            return
        }
        let current = generation
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.isMonitoring, self.generation == current else { return }
                await self.refresh()
                do { try await self.sleep() } catch { return }
            }
        }
    }

    func refresh() async {
        guard isMonitoring, requestID == nil else { return }
        let request = UUID()
        let current = generation
        requestID = request
        defer { if requestID == request { requestID = nil } }
        do {
            let snapshot = try await loadPendingFiles()
            guard isMonitoring, generation == current else { return }
            if snapshot.receiverID != receiverID {
                receiverID = snapshot.receiverID
                offeredIDs = []
                acceptedIDs = []
                prompt = nil
            }
            var unique: Set<UUID> = []
            pendingFiles = snapshot.receiverID == nil ? [] : snapshot.files.filter {
                [.available, .leased].contains($0.state)
                    && !acceptedIDs.contains($0.deliveryID)
                    && unique.insert($0.deliveryID).inserted
            }.sorted {
                if $0.createdAt == $1.createdAt { return $0.deliveryID.uuidString < $1.deliveryID.uuidString }
                return $0.createdAt < $1.createdAt
            }
            let pendingIDs = Set(pendingFiles.map(\.deliveryID))
            offeredIDs.formIntersection(pendingIDs)
            if let existing = prompt {
                let remaining = existing.files.filter { pendingIDs.contains($0.deliveryID) }
                if remaining.isEmpty { prompt = nil }
                else if remaining != existing.files {
                    prompt = IPhoneIncomingBatch(receiverID: existing.receiverID, files: remaining)
                }
            }
            lastError = nil
            offerUnseenFiles()
        } catch let error where IPhoneReceiveErrorMessage.isCancellation(error) {
            return
        } catch {
            guard isMonitoring, generation == current else { return }
            lastError = IPhoneReceiveErrorMessage.message(error)
        }
    }

    func showPendingFiles() {
        guard isMonitoring, let receiverID, !pendingFiles.isEmpty else { return }
        present(pendingFiles, receiverID: receiverID)
    }

    func postponePrompt() { prompt = nil }

    func accept(_ batch: IPhoneIncomingBatch, destination: IPhoneReceiveDestination) -> Bool {
        guard isMonitoring, receiverID == batch.receiverID else { return false }
        let pendingIDs = Set(pendingFiles.map(\.deliveryID))
        let ids = Set(batch.files.map(\.deliveryID)).intersection(pendingIDs)
        guard !ids.isEmpty else { return false }
        do {
            try approveFiles(batch.receiverID, ids, destination)
            acceptedIDs.formUnion(ids)
            pendingFiles.removeAll { ids.contains($0.deliveryID) }
            if prompt?.id == batch.id { prompt = nil }
            lastError = nil
            return true
        } catch {
            lastError = "저장 위치 선택을 저장하지 못했습니다. " + IPhoneReceiveErrorMessage.message(error)
            return false
        }
    }

    private func offerUnseenFiles() {
        guard prompt == nil, let receiverID else { return }
        let files = pendingFiles.filter { !offeredIDs.contains($0.deliveryID) }
        guard !files.isEmpty else { return }
        present(files, receiverID: receiverID)
    }

    private func present(_ files: [IPhoneDelivery], receiverID: UUID) {
        offeredIDs.formUnion(files.map(\.deliveryID))
        prompt = IPhoneIncomingBatch(receiverID: receiverID, files: files)
    }
}
