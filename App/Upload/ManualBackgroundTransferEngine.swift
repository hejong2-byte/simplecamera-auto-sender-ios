import Foundation

private struct ManualMultipartStartResponse: Decodable {
    let uploadId: String?
    let complete: Bool?
}

private struct ManualMultipartPartResponse: Codable {
    let partNumber: Int
    let etag: String
}

private struct ManualMultipartCompleteRequestBody: Encodable {
    let parts: [ManualMultipartPartResponse]
}

protocol ManualTransferQueueing: Sendable {
    func enqueue(_ jobs: [ManualTransferJob]) async throws
    func updates() async -> AsyncStream<ManualTransferProgress>
}

actor ManualBackgroundTransferEngine: ManualTransferQueueing {
    typealias Sleeper = @Sendable (UInt64) async -> Void

    private let scheduler: ManualUploadTaskScheduling
    private let jobStore: ManualTransferJobStore
    private let credentialStore: CredentialStore
    private let requestFactory: RelayRequestFactory
    private let retryPolicy: ManualRetryPolicy
    private let sleep: Sleeper
    private var continuations: [UUID: AsyncStream<ManualTransferProgress>.Continuation] = [:]
    private var activeTaskBytes: [ManualUploadTaskDescriptor: Int64] = [:]
    private var transientRetryAttempts: [ManualUploadTaskDescriptor: Int] = [:]

    init(
        scheduler: ManualUploadTaskScheduling,
        jobStore: ManualTransferJobStore,
        credentialStore: CredentialStore,
        requestFactory: RelayRequestFactory = RelayRequestFactory(),
        retryPolicy: ManualRetryPolicy = ManualRetryPolicy(),
        sleep: @escaping Sleeper = { seconds in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
        }
    ) {
        self.scheduler = scheduler
        self.jobStore = jobStore
        self.credentialStore = credentialStore
        self.requestFactory = requestFactory
        self.retryPolicy = retryPolicy
        self.sleep = sleep
    }

    func enqueue(_ jobs: [ManualTransferJob]) async throws {
        guard !jobs.isEmpty else { return }
        var state = try await jobStore.load()
        for job in jobs {
            if !state.batches.contains(where: { $0.id == job.batchID }) {
                state.batches.append(ManualTransferBatch(
                    id: job.batchID,
                    kind: job.kind,
                    selectedCount: job.selectedCount,
                    preparedCount: 1,
                    uploadedCount: 0,
                    failedCount: 0
                ))
            }
            if let index = state.jobs.firstIndex(where: { $0.id == job.id }) {
                state.jobs[index] = job
            } else {
                state.jobs.append(job)
            }
        }
        try await jobStore.replace(state)
        for job in jobs {
            await scheduleNeededOperations(jobID: job.id)
        }
    }

    func restore() async {
        guard let state = try? await jobStore.load() else { return }
        for job in state.jobs {
            switch job.stage {
            case .completed:
                await cleanupAndRemove(job)
            case .failed where job.uploadID == nil:
                await cleanupAndRemove(job)
            default:
                await scheduleNeededOperations(jobID: job.id)
            }
        }
    }

    func updates() async -> AsyncStream<ManualTransferProgress> {
        let id = UUID()
        let pair = AsyncStream.makeStream(of: ManualTransferProgress.self)
        continuations[id] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id) }
        }
        return pair.stream
    }

    func taskProgress(
        _ descriptor: ManualUploadTaskDescriptor,
        sent: Int64,
        expected: Int64
    ) async {
        let upperBound = expected > 0 ? expected : sent
        activeTaskBytes[descriptor] = min(max(sent, 0), max(upperBound, 0))
        guard let state = try? await jobStore.load(),
              let job = state.jobs.first(where: { $0.id == descriptor.jobID }) else {
            return
        }
        publish(progress(for: job, in: state, stage: .uploading))
    }

    func taskCompleted(
        _ descriptor: ManualUploadTaskDescriptor,
        response: HTTPURLResponse?,
        body: Data,
        error: Error?
    ) async {
        activeTaskBytes.removeValue(forKey: descriptor)
        if (error as? URLError)?.code == .cancelled {
            return
        }
        guard let state = try? await jobStore.load(),
              let job = state.jobs.first(where: { $0.id == descriptor.jobID }) else {
            return
        }
        if descriptor.operation == .abort {
            await cleanupAndRemove(job)
            return
        }
        guard let response, (200...299).contains(response.statusCode), error == nil else {
            await handleFailure(
                descriptor,
                job: job,
                response: response,
                body: body,
                error: error
            )
            return
        }
        transientRetryAttempts.removeValue(forKey: descriptor)

        switch descriptor.operation {
        case .single, .complete:
            await finishSuccessfully(jobID: job.id)
        case .start:
            guard let start = try? JSONDecoder().decode(
                ManualMultipartStartResponse.self,
                from: body
            ) else {
                await markFailed(jobID: job.id, failure: .other)
                return
            }
            if start.complete == true {
                await finishSuccessfully(jobID: job.id)
                return
            }
            guard let uploadID = start.uploadId, !uploadID.isEmpty else {
                await markFailed(jobID: job.id, failure: .other)
                return
            }
            await storeUploadID(uploadID, jobID: job.id)
            await scheduleNeededOperations(jobID: job.id)
        case let .part(number):
            guard let uploaded = try? JSONDecoder().decode(
                ManualMultipartPartResponse.self,
                from: body
            ), uploaded.partNumber == number, !uploaded.etag.isEmpty else {
                await markFailed(jobID: job.id, failure: .other)
                return
            }
            await storeCompletedPart(uploaded, jobID: job.id)
            await scheduleNeededOperations(jobID: job.id)
        case .abort:
            break
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private func scheduleNeededOperations(jobID: UUID) async {
        guard let state = try? await jobStore.load(),
              let job = state.jobs.first(where: { $0.id == jobID }) else {
            return
        }
        let existing = await scheduler.existingDescriptors()
        for operation in neededOperations(for: job) {
            let descriptor = ManualUploadTaskDescriptor(
                batchID: job.batchID,
                jobID: job.id,
                operation: operation
            )
            guard !existing.contains(descriptor) else { continue }
            await schedule(descriptor, avoidDuplicateCheck: false)
        }
    }

    private func neededOperations(for job: ManualTransferJob) -> [ManualUploadOperation] {
        if job.stage == .completed { return [] }
        if job.stage == .failed {
            return job.uploadID == nil ? [] : [.abort]
        }
        guard job.uploadID != nil else {
            return job.totalBytes <= ManualMediaUploadLimit.singleRequestMaxBytes
                ? [.single]
                : [.start]
        }
        let missing = job.parts
            .filter { $0.etag == nil }
            .sorted { $0.number < $1.number }
            .map { ManualUploadOperation.part(number: $0.number) }
        return missing.isEmpty ? [.complete] : missing
    }

    private func schedule(
        _ descriptor: ManualUploadTaskDescriptor,
        avoidDuplicateCheck: Bool
    ) async {
        if avoidDuplicateCheck,
           await scheduler.existingDescriptors().contains(descriptor) {
            return
        }
        guard var state = try? await jobStore.load(),
              let index = state.jobs.firstIndex(where: { $0.id == descriptor.jobID }) else {
            return
        }
        let job = state.jobs[index]
        do {
            let (request, fileURL) = try requestAndFile(
                descriptor: descriptor,
                job: job
            )
            if job.stage != .failed {
                state.jobs[index].stage = stage(for: descriptor.operation)
                try await jobStore.replace(state)
                publish(progress(for: state.jobs[index], in: state))
            }
            try await scheduler.schedule(
                descriptor,
                request: request,
                fileURL: fileURL
            )
        } catch {
            if descriptor.operation == .abort {
                await cleanupAndRemove(job)
            } else {
                await handleFailure(
                    descriptor,
                    job: job,
                    response: nil,
                    body: Data(),
                    error: error
                )
            }
        }
    }

    private func requestAndFile(
        descriptor: ManualUploadTaskDescriptor,
        job: ManualTransferJob
    ) throws -> (URLRequest, URL) {
        guard let credential = try credentialStore.load() else {
            throw UploadConfigurationError.missingCredential
        }
        let fingerprint = UploadFileFingerprint(
            sha256: job.sha256,
            size: job.totalBytes,
            remoteID: job.remoteID
        )
        let metadata = ManualMediaUploadMetadata(
            fileName: job.originalFileName,
            contentType: job.contentType,
            capturedAt: job.capturedAt
        )
        let controlDirectory = controlDirectory(for: job)
        try FileManager.default.createDirectory(
            at: controlDirectory,
            withIntermediateDirectories: true
        )
        let emptyFile = controlDirectory.appendingPathComponent("empty")
        if !FileManager.default.fileExists(atPath: emptyFile.path) {
            try Data().write(to: emptyFile, options: .atomic)
        }

        switch descriptor.operation {
        case .single:
            return (
                try requestFactory.makeManualMediaRequest(
                    credential: credential,
                    fingerprint: fingerprint,
                    metadata: metadata
                ),
                job.exportedFileURL
            )
        case .start:
            return (
                try requestFactory.makeMultipartStartRequest(
                    credential: credential,
                    fingerprint: fingerprint,
                    metadata: metadata
                ),
                emptyFile
            )
        case let .part(number):
            guard let uploadID = job.uploadID,
                  let part = job.parts.first(where: { $0.number == number }) else {
                throw UploadHTTPError.invalidResponse
            }
            return (
                try requestFactory.makeMultipartPartRequest(
                    credential: credential,
                    remoteID: job.remoteID,
                    uploadID: uploadID,
                    partNumber: number,
                    partSize: Int(part.size)
                ),
                part.fileURL
            )
        case .complete:
            guard let uploadID = job.uploadID else {
                throw UploadHTTPError.invalidResponse
            }
            let uploadedParts = try job.parts
                .sorted { $0.number < $1.number }
                .map { part -> ManualMultipartPartResponse in
                    guard let etag = part.etag else {
                        throw UploadHTTPError.invalidResponse
                    }
                    return .init(partNumber: part.number, etag: etag)
                }
            let bodyFile = controlDirectory.appendingPathComponent("complete.json")
            try JSONEncoder().encode(
                ManualMultipartCompleteRequestBody(parts: uploadedParts)
            ).write(to: bodyFile, options: .atomic)
            return (
                try requestFactory.makeMultipartCompleteRequest(
                    credential: credential,
                    remoteID: job.remoteID,
                    uploadID: uploadID
                ),
                bodyFile
            )
        case .abort:
            guard let uploadID = job.uploadID else {
                throw UploadHTTPError.invalidResponse
            }
            return (
                try requestFactory.makeMultipartAbortRequest(
                    credential: credential,
                    remoteID: job.remoteID,
                    uploadID: uploadID
                ),
                emptyFile
            )
        }
    }

    private func handleFailure(
        _ descriptor: ManualUploadTaskDescriptor,
        job: ManualTransferJob,
        response: HTTPURLResponse?,
        body: Data,
        error: Error?
    ) async {
        let attempt = retryAttempt(for: descriptor, in: job)
        if retryPolicy.shouldRetry(error: error, response: response, attempt: attempt) {
            let nextAttempt = attempt + 1
            await persistRetry(
                descriptor: descriptor,
                jobID: job.id,
                attempt: nextAttempt
            )
            await sleep(retryPolicy.delaySeconds(attempt: attempt))
            await schedule(descriptor, avoidDuplicateCheck: false)
            return
        }
        await markFailed(
            jobID: job.id,
            failure: failure(response: response, body: body, error: error)
        )
    }

    private func retryAttempt(
        for descriptor: ManualUploadTaskDescriptor,
        in job: ManualTransferJob
    ) -> Int {
        if case let .part(number) = descriptor.operation {
            return job.parts.first(where: { $0.number == number })?.retryAttempt ?? 0
        }
        return transientRetryAttempts[descriptor] ?? 0
    }

    private func persistRetry(
        descriptor: ManualUploadTaskDescriptor,
        jobID: UUID,
        attempt: Int
    ) async {
        guard var state = try? await jobStore.load(),
              let jobIndex = state.jobs.firstIndex(where: { $0.id == jobID }) else {
            return
        }
        state.jobs[jobIndex].stage = .retrying
        if case let .part(number) = descriptor.operation,
           let partIndex = state.jobs[jobIndex].parts.firstIndex(where: { $0.number == number }) {
            state.jobs[jobIndex].parts[partIndex].retryAttempt = attempt
        } else {
            transientRetryAttempts[descriptor] = attempt
        }
        try? await jobStore.replace(state)
        publish(progress(
            for: state.jobs[jobIndex],
            in: state,
            stage: .retrying,
            retryAttempt: attempt
        ))
    }

    private func storeUploadID(_ uploadID: String, jobID: UUID) async {
        guard var state = try? await jobStore.load(),
              let index = state.jobs.firstIndex(where: { $0.id == jobID }) else {
            return
        }
        guard state.jobs[index].uploadID == nil else { return }
        state.jobs[index].uploadID = uploadID
        state.jobs[index].stage = .uploading
        try? await jobStore.replace(state)
        publish(progress(for: state.jobs[index], in: state))
    }

    private func storeCompletedPart(
        _ uploaded: ManualMultipartPartResponse,
        jobID: UUID
    ) async {
        guard var state = try? await jobStore.load(),
              let jobIndex = state.jobs.firstIndex(where: { $0.id == jobID }),
              let partIndex = state.jobs[jobIndex].parts.firstIndex(where: {
                  $0.number == uploaded.partNumber
              }) else {
            return
        }
        if state.jobs[jobIndex].parts[partIndex].etag == uploaded.etag {
            return
        }
        state.jobs[jobIndex].parts[partIndex].etag = uploaded.etag
        state.jobs[jobIndex].parts[partIndex].retryAttempt = 0
        state.jobs[jobIndex].stage = .uploading
        try? await jobStore.replace(state)
        publish(progress(for: state.jobs[jobIndex], in: state))
    }

    private func finishSuccessfully(jobID: UUID) async {
        guard var state = try? await jobStore.load(),
              let jobIndex = state.jobs.firstIndex(where: { $0.id == jobID }),
              let batchIndex = state.batches.firstIndex(where: {
                  $0.id == state.jobs[jobIndex].batchID
              }) else {
            return
        }
        if state.jobs[jobIndex].stage != .completed {
            state.jobs[jobIndex].stage = .completed
            state.batches[batchIndex].uploadedCount += 1
            try? await jobStore.replace(state)
            publish(progress(for: state.jobs[jobIndex], in: state, stage: .completed))
        }
        await cleanupAndRemove(state.jobs[jobIndex])
    }

    private func markFailed(jobID: UUID, failure: ManualTransferFailure) async {
        guard var state = try? await jobStore.load(),
              let jobIndex = state.jobs.firstIndex(where: { $0.id == jobID }),
              let batchIndex = state.batches.firstIndex(where: {
                  $0.id == state.jobs[jobIndex].batchID
              }) else {
            return
        }
        if state.jobs[jobIndex].stage != .failed {
            state.jobs[jobIndex].stage = .failed
            state.jobs[jobIndex].failure = failure
            state.batches[batchIndex].failedCount += 1
            try? await jobStore.replace(state)
            publish(progress(for: state.jobs[jobIndex], in: state, stage: .failed))
            await scheduler.cancel(jobID: jobID)
        }
        if state.jobs[jobIndex].uploadID == nil {
            await cleanupAndRemove(state.jobs[jobIndex])
        } else {
            await scheduleNeededOperations(jobID: jobID)
        }
    }

    private func cleanupAndRemove(_ job: ManualTransferJob) async {
        activeTaskBytes = activeTaskBytes.filter { $0.key.jobID != job.id }
        try? FileManager.default.removeItem(at: job.exportedFileURL)
        for part in job.parts {
            try? FileManager.default.removeItem(at: part.fileURL)
        }
        try? FileManager.default.removeItem(at: controlDirectory(for: job))
        try? await jobStore.removeJob(id: job.id)
    }

    private func controlDirectory(for job: ManualTransferJob) -> URL {
        job.exportedFileURL.deletingLastPathComponent()
            .appendingPathComponent("Background-\(job.id.uuidString)", isDirectory: true)
    }

    private func stage(for operation: ManualUploadOperation) -> ManualTransferStage {
        switch operation {
        case .start: .starting
        case .complete: .verifying
        case .single, .part: .uploading
        case .abort: .failed
        }
    }

    private func failure(
        response: HTTPURLResponse?,
        body: Data,
        error: Error?
    ) -> ManualTransferFailure {
        if let statusCode = response?.statusCode {
            if statusCode == 401 || statusCode == 403 {
                return .authentication
            }
            return .server(
                statusCode: statusCode,
                code: requestFactory.decodeErrorCode(from: body)
            )
        }
        if error is URLError { return .network }
        if error is UploadConfigurationError { return .authentication }
        return .other
    }

    private func progress(
        for job: ManualTransferJob,
        in state: ManualTransferQueueState,
        stage: ManualTransferStage? = nil,
        retryAttempt: Int? = nil
    ) -> ManualTransferProgress {
        let batch = state.batches.first(where: { $0.id == job.batchID })
        let confirmed = job.parts
            .filter { $0.etag != nil }
            .reduce(Int64(0)) { $0 + $1.size }
        let active = activeTaskBytes
            .filter { $0.key.jobID == job.id }
            .values
            .reduce(Int64(0), +)
        return ManualTransferProgress(
            batchID: job.batchID,
            kind: job.kind,
            selectedCount: batch?.selectedCount ?? job.selectedCount,
            currentIndex: job.currentIndex,
            uploadedCount: batch?.uploadedCount ?? 0,
            failedCount: batch?.failedCount ?? 0,
            stage: stage ?? job.stage,
            totalBytes: job.totalBytes,
            confirmedBytes: confirmed,
            taskBytesSent: active,
            retryAttempt: retryAttempt ?? 0,
            failure: job.failure
        )
    }

    private func publish(_ progress: ManualTransferProgress) {
        for continuation in continuations.values {
            continuation.yield(progress)
        }
    }
}
