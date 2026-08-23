# Background Manual Transfer Progress Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the production multipart HTTP 422 failure and give manually selected media persistent iOS background uploads with byte progress, percentages, and live completion/failure counts.

**Architecture:** Keep the existing automatic Simple Cam uploader unchanged. Add a separate persisted manual-transfer engine backed by one background `URLSession`, exact 32MiB chunk files, delegate-driven progress, and resumable R2 multipart state. Make the Worker verify a completed object with a fresh R2 `head()` and return distinct non-sensitive integrity error codes.

**Tech Stack:** Swift 5, SwiftUI, Foundation background URLSession, PhotoKit, CryptoKit, XCTest, Cloudflare Workers/R2, TypeScript 7, Vitest 4, GitHub Actions, SideStore unsigned IPA.

## Global Constraints

- iOS deployment target remains 17.0 and the bundle ID remains `com.hejong2byte.simplecameraautosender`.
- Automatic Simple Cam detection, App Intent, POST endpoint, Keychain identity, and automatic upload ledger remain backward compatible.
- Manual transfers process only picker-selected PhotoKit identifiers.
- Supported manual MIME types remain JPEG, PNG, HEIC, HEIF, QuickTime MOV, and MP4; maximum file size remains 2GiB.
- Multipart chunks are exactly 32MiB except the final smaller chunk; at most three chunk tasks run concurrently.
- Credentials never enter the job JSON, task descriptions, URLs, user messages, or logs.
- App switching, screen lock, and system termination are supported; user force-quit cancels iOS background tasks and resumes only after the next launch.
- Do not stage or remove the existing untracked `release-v0.1.7/` directory or unrelated receiver files.
- Publish version `0.1.8`, build `6`, only after Worker production deployment and real-device large-video verification.

---

### Task 1: Make Worker multipart completion verification truthful

**Repositories:**
- Receiver repository: `C:\Users\user\Documents\김희종 개발 프로그램`
- Worker directory: `SimpleCamera 업무사진 수신기/cloudflare/photo-relay`

**Files:**
- Modify: `SimpleCamera 업무사진 수신기/cloudflare/photo-relay/src/index.ts:440-476`
- Modify: `SimpleCamera 업무사진 수신기/cloudflare/photo-relay/test/index.test.ts`

**Interfaces:**
- Produces: `completionIntegrityError(object, expectedID, expectedSize) -> CompletionIntegrityCode | undefined`
- Produces HTTP 422 bodies shaped as `{ error: "metadata_missing" | "id_mismatch" | "size_mismatch" }`.
- Preserves successful HTTP 201 metadata response and all existing endpoints.

- [ ] **Step 1: Add failing pure integrity tests**

Export a pure helper from `src/index.ts` and add this table to `test/index.test.ts`:

```ts
import { authorized, completionIntegrityError } from "../src/index";

it.each([
  [undefined, "id-1", 12, "metadata_missing"],
  [{ id: "id-2", size: "12" }, "id-1", 12, "id_mismatch"],
  [{ id: "id-1", size: "13" }, "id-1", 12, "size_mismatch"],
  [{ id: "id-1", size: "12" }, "id-1", 12, undefined],
])("classifies completion integrity failures", (metadata, id, size, expected) => {
  expect(completionIntegrityError(metadata, id, size)).toBe(expected);
});
```

- [ ] **Step 2: Run Worker tests and verify RED**

Run from `SimpleCamera 업무사진 수신기/cloudflare/photo-relay`:

```powershell
npm test -- --run
```

Expected: FAIL because `completionIntegrityError` is not exported.

- [ ] **Step 3: Implement the pure classifier**

Add near the stored metadata helpers:

```ts
export type CompletionIntegrityCode =
  | "metadata_missing"
  | "id_mismatch"
  | "size_mismatch";

export function completionIntegrityError(
  metadata: Partial<StoredMetadata> | undefined,
  expectedID: string,
  actualSize: number
): CompletionIntegrityCode | undefined {
  if (!metadata || metadata.size === undefined) return "metadata_missing";
  if (metadata.id !== expectedID) return "id_mismatch";
  if (actualSize !== Number(metadata.size)) return "size_mismatch";
  return undefined;
}
```

- [ ] **Step 4: Add failing tests for fresh `head()` verification**

Import a not-yet-implemented `verifyCompletedManualObject` helper and exercise it with a minimal `head()` fake:

```ts
const bucket = {
  head: async () => ({
    size: 12,
    customMetadata: { id: "id-1", size: "12" },
  }),
} as unknown as Pick<R2Bucket, "head">;
const verified = await verifyCompletedManualObject(bucket, "pending/manual/id-1", "id-1");
expect(verified).toMatchObject({
  metadata: { id: "id-1", size: "12" },
  actualSize: 12,
});
```

Add separate fakes returning `null`, a different ID, and a different size. Run Vitest and expect RED because `verifyCompletedManualObject` is not exported.

- [ ] **Step 5: Replace completion-return-object validation with `head()` validation**

Implement this helper and use it from the completion path:

```ts
export async function verifyCompletedManualObject(
  bucket: Pick<R2Bucket, "head">,
  key: string,
  expectedID: string
): Promise<
  | { metadata: StoredMetadata; actualSize: number }
  | { error: CompletionIntegrityCode; declaredSize?: string; actualSize?: number }
> {
  const object = await bucket.head(key);
  if (!object) return { error: "metadata_missing" };
  const metadata = object.customMetadata as unknown as StoredMetadata | undefined;
  const error = completionIntegrityError(metadata, expectedID, object.size);
  return error
    ? { error, declaredSize: metadata?.size, actualSize: object.size }
    : { metadata: metadata!, actualSize: object.size };
}

const key = manualObjectKey(id);
const upload = env.PHOTO_BUCKET.resumeMultipartUpload(key, currentUploadID);
await upload.complete(parts);
const verified = await verifyCompletedManualObject(env.PHOTO_BUCKET, key, id);
if ("error" in verified) {
  console.warn("manual multipart integrity failure", {
    code: verified.error,
    declaredSize: verified.declaredSize ?? "missing",
    actualSize: verified.actualSize ?? "missing",
  });
  await env.PHOTO_BUCKET.delete(key);
  return json({ error: verified.error }, 422);
}
return json(publicMetadata(verified.metadata), 201);
```

Keep the catch response as `{ error: "multipart_completion_failed" }` with HTTP 409. Never log the ID, file name, upload ID, token, request headers, or body.

- [ ] **Step 6: Run Worker verification**

```powershell
npm test -- --run
npm run typecheck
git diff --check -- "SimpleCamera 업무사진 수신기/cloudflare/photo-relay"
```

Expected: all Worker tests pass, TypeScript exits 0, and diff check is empty.

- [ ] **Step 7: Commit only Worker files**

```powershell
git add -- "SimpleCamera 업무사진 수신기/cloudflare/photo-relay/src/index.ts" "SimpleCamera 업무사진 수신기/cloudflare/photo-relay/test/index.test.ts"
git commit -m "fix: verify completed manual media from R2"
```

---

### Task 2: Add a testable manual-transfer progress model

**Files:**
- Modify: `App/Media/ManualMediaPicker.swift:4`
- Create: `App/Media/ManualTransferProgress.swift`
- Create: `Tests/ManualTransferProgressTests.swift`

**Interfaces:**
- Produces: `ManualTransferStage`, `ManualTransferFailure`, and `ManualTransferProgress`.
- Produces: `ManualTransferProgress.percent: Int` and `displayedBytesSent: Int64`.
- Later tasks publish this model through `AsyncStream<ManualTransferProgress>`.

- [ ] **Step 1: Write failing progress calculation tests**

```swift
final class ManualTransferProgressTests: XCTestCase {
    func testPercentUsesConfirmedAndCurrentTaskBytes() {
        let progress = ManualTransferProgress.fixture(
            totalBytes: 200,
            confirmedBytes: 100,
            taskBytesSent: 34
        )
        XCTAssertEqual(progress.displayedBytesSent, 134)
        XCTAssertEqual(progress.percent, 67)
    }

    func testPercentClampsAndZeroLengthIsZero() {
        XCTAssertEqual(ManualTransferProgress.fixture(totalBytes: 0).percent, 0)
        XCTAssertEqual(ManualTransferProgress.fixture(
            totalBytes: 10,
            confirmedBytes: 10,
            taskBytesSent: 5
        ).percent, 100)
    }

    func testFailureImmediatelyIncrementsBatchCount() {
        let failed = ManualTransferProgress.fixture(selected: 3, uploaded: 1, failed: 1)
        XCTAssertEqual(failed.completedCount, 2)
    }
}
```

Define the `fixture` helper in the test target, not production.

- [ ] **Step 2: Push the test-only commit and verify RED in macOS CI**

```powershell
git add -- Tests/ManualTransferProgressTests.swift
git commit -m "test: require truthful manual transfer progress"
git push -u origin codex/background-manual-transfer-progress
gh run list --branch codex/background-manual-transfer-progress --limit 1
```

Expected: CI fails to compile because the progress types do not exist. Record the run ID.

- [ ] **Step 3: Implement the minimal state model**

Create `App/Media/ManualTransferProgress.swift`:

```swift
import Foundation

enum ManualTransferStage: String, Codable, Sendable, Equatable {
    case idle, preparing, starting, uploading, retrying, verifying, completed, failed
}

enum ManualTransferFailure: Codable, Sendable, Equatable {
    case network
    case authentication
    case server(statusCode: Int, code: String?)
    case unsupported
    case tooLarge
    case other
}

struct ManualTransferProgress: Codable, Sendable, Equatable {
    let batchID: UUID
    let kind: ManualMediaKind
    let selectedCount: Int
    let currentIndex: Int
    let uploadedCount: Int
    let failedCount: Int
    let stage: ManualTransferStage
    let totalBytes: Int64
    let confirmedBytes: Int64
    let taskBytesSent: Int64
    let retryAttempt: Int
    let failure: ManualTransferFailure?

    var displayedBytesSent: Int64 {
        min(max(confirmedBytes + taskBytesSent, 0), max(totalBytes, 0))
    }

    var percent: Int {
        guard totalBytes > 0 else { return 0 }
        return min(100, max(0, Int((Double(displayedBytesSent) / Double(totalBytes) * 100).rounded(.down))))
    }

    var completedCount: Int { uploadedCount + failedCount }
}
```

Add `Codable` to the existing raw-value enum because progress and jobs persist the media kind:

```swift
enum ManualMediaKind: String, CaseIterable, Identifiable, Codable, Sendable {
```

- [ ] **Step 4: Push and verify GREEN in CI**

```powershell
git add -- App/Media/ManualTransferProgress.swift
git commit -m "feat: model manual transfer progress"
git push
```

Wait for the branch CI and confirm the new tests plus all existing tests pass.

---

### Task 3: Persist resumable jobs and create exact multipart files

**Files:**
- Create: `App/Media/ManualTransferJobStore.swift`
- Create: `App/Upload/ManualFileFingerprint.swift`
- Create: `App/Upload/ManualMultipartFiles.swift`
- Create: `App/Upload/ManualRetryPolicy.swift`
- Create: `Tests/ManualTransferJobStoreTests.swift`
- Create: `Tests/ManualMultipartFilesTests.swift`
- Create: `Tests/ManualRetryPolicyTests.swift`

**Interfaces:**
- Produces: `ManualTransferBatch`, `ManualTransferJob`, `ManualTransferPart`, `ManualTransferQueueState`, and actor `ManualTransferJobStore`.
- Moves `UploadFileFingerprint` and `UploadFileFingerprinter` into `ManualFileFingerprint.swift` without changing their hash/UUID behavior.
- Produces: `ManualMultipartFiles.makeParts(source:directory:partBytes:) -> [URL]`.
- Produces: `ManualRetryPolicy.shouldRetry(error:response:attempt:) -> Bool` and `delaySeconds(attempt:) -> UInt64`.

- [ ] **Step 1: Write failing job-store tests**

Tests must save, reopen, and compare a queue state containing its batch counters plus a job with exported file metadata, upload ID, completed part ETags, retries, and progress stage. Include one preparation failure in `batch.failedCount` so restoration proves that failures without an upload job are retained. Add this secret scan:

```swift
let bytes = try Data(contentsOf: storeURL)
let text = String(decoding: bytes, as: UTF8.self)
XCTAssertFalse(text.localizedCaseInsensitiveContains("authorization"))
XCTAssertFalse(text.localizedCaseInsensitiveContains("bearer"))
XCTAssertFalse(text.contains("test-secret"))
```

Also verify `save` uses a replacement file by loading valid JSON after two consecutive writes.

- [ ] **Step 2: Write failing exact-chunk tests**

Use `partBytes: 4` in tests:

```swift
let parts = try ManualMultipartFiles.makeParts(
    source: sourceURL,
    directory: partsDirectory,
    partBytes: 4
)
XCTAssertEqual(try parts.map(fileSize), [4, 4, 2])
XCTAssertEqual(try parts.flatMap { try Data(contentsOf: $0) }, Array(sourceBytes))
```

Add an empty-file rejection test and a test proving intermediate short reads are filled; inject a reader closure that returns at most two bytes per call.

- [ ] **Step 3: Write failing retry-policy tests**

Cover `URLError.timedOut`, HTTP 408/425/429/500, HTTP 401/403, HTTP 422, and attempt 4. Assert delays `[1, 3, 9]`.

- [ ] **Step 4: Push test-only changes and verify RED in CI**

Commit only the three test files, push, and confirm the CI compile fails for the missing production types.

- [ ] **Step 5: Implement the Codable job store**

Use these persisted shapes:

```swift
struct ManualTransferBatch: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    let kind: ManualMediaKind
    let selectedCount: Int
    var preparedCount: Int
    var uploadedCount: Int
    var failedCount: Int
}

struct ManualTransferPart: Codable, Sendable, Equatable {
    let number: Int
    let fileURL: URL
    let size: Int64
    var etag: String?
    var retryAttempt: Int
}

struct ManualTransferJob: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    let batchID: UUID
    let assetIdentifier: String
    let kind: ManualMediaKind
    let selectedCount: Int
    let currentIndex: Int
    let exportedFileURL: URL
    let originalFileName: String
    let contentType: String
    let capturedAt: Date?
    let sha256: String
    let remoteID: String
    let totalBytes: Int64
    var stage: ManualTransferStage
    var uploadID: String?
    var parts: [ManualTransferPart]
    var failure: ManualTransferFailure?
}

struct ManualTransferQueueState: Codable, Sendable, Equatable {
    var batches: [ManualTransferBatch]
    var jobs: [ManualTransferJob]
}

actor ManualTransferJobStore {
    init(fileURL: URL)
    func load() throws -> ManualTransferQueueState
    func replace(_ state: ManualTransferQueueState) throws
    func upsertBatch(_ batch: ManualTransferBatch) throws
    func upsertJob(_ job: ManualTransferJob) throws
    func removeJob(id: UUID) throws
}
```

Write encoded data to a sibling temporary file and replace the destination atomically. Create only the parent directory, never a broad directory.

- [ ] **Step 6: Implement exact file chunking and retry policy**

Move the existing streaming SHA-256 and deterministic UUID implementation out of `BackgroundUploadCoordinator.swift` into `ManualFileFingerprint.swift`; keep the existing fingerprint regression test unchanged.

`ManualMultipartFiles` must loop reads until the requested non-final chunk is full or true EOF occurs. It must never treat one short `FileHandle.read(upToCount:)` result as a complete non-final part. File names are `part-00001.bin`, `part-00002.bin`, and so on.

`ManualRetryPolicy` retries only temporary URL errors and the approved status codes while `attempt < 3`; authentication and integrity failures return false.

- [ ] **Step 7: Push and verify GREEN in CI**

Commit production files, push, and confirm all new and existing iOS tests pass.

---

### Task 4: Add the background URLSession transport and resumable engine

**Files:**
- Create: `App/Upload/BackgroundManualUploadSession.swift`
- Create: `App/Upload/ManualBackgroundTransferEngine.swift`
- Create: `App/Application/BackgroundSessionAppDelegate.swift`
- Modify: `App/Application/SimpleCameraAutoSenderApp.swift:7-13`
- Modify: `App/Configuration/AppConfiguration.swift`
- Modify: `App/Upload/RelayRequestFactory.swift`
- Create: `Tests/ManualBackgroundTransferEngineTests.swift`
- Modify: `Tests/RelayRequestFactoryTests.swift`

**Interfaces:**
- Produces: `ManualUploadTaskDescriptor` encoded into `URLSessionTask.taskDescription` without secrets.
- Produces protocol `ManualUploadTaskScheduling` for deterministic tests.
- Produces actor `ManualBackgroundTransferEngine` with `enqueue`, `restore`, and `updates`.
- Produces `BackgroundSessionCompletionRegistry` used by the app delegate and session delegate.

- [ ] **Step 1: Write failing task-description and request tests**

Test that a descriptor round-trips batch ID, job ID, operation, and part number, and that its JSON contains no URL, token, upload ID, or file name.

Add request-factory tests for stable error-body decoding and existing multipart URLs. Preserve `Authorization` only in request headers.

- [ ] **Step 2: Write failing engine tests against a fake scheduler**

Define in the test target:

```swift
actor FakeManualUploadScheduler: ManualUploadTaskScheduling {
    private(set) var scheduled: [(ManualUploadTaskDescriptor, URLRequest, URL)] = []
    private(set) var canceledJobIDs: [UUID] = []
    func schedule(_ descriptor: ManualUploadTaskDescriptor, request: URLRequest, fileURL: URL) async throws {
        scheduled.append((descriptor, request, fileURL))
    }
    func existingDescriptors() async -> Set<ManualUploadTaskDescriptor> {
        Set(scheduled.map(\.0))
    }
    func cancel(jobID: UUID) async {
        canceledJobIDs.append(jobID)
    }
}
```

Cover these observable behaviors one at a time:

- restoring persisted jobs schedules only missing operations;
- successful parts persist ETags and confirmed bytes;
- a failed part retries only that part and keeps other ETags;
- all parts schedule completion exactly once;
- 422 creates the correct failure, increments failure count immediately, and schedules abort;
- a canceled task caused by force quit stays resumable and does not abort;
- updates emit progress after `didSendBodyData` input.

- [ ] **Step 3: Push test-only changes and verify RED in CI**

Commit and push the tests. Expected CI result: compile failure for missing background transport/engine types.

- [ ] **Step 4: Implement the scheduling abstraction**

Use these production interfaces:

```swift
enum ManualUploadOperation: Codable, Sendable, Equatable, Hashable {
    case single, start, part(number: Int), complete, abort
}

struct ManualUploadTaskDescriptor: Codable, Sendable, Equatable, Hashable {
    let batchID: UUID
    let jobID: UUID
    let operation: ManualUploadOperation
}

protocol ManualUploadTaskScheduling: Sendable {
    func schedule(
        _ descriptor: ManualUploadTaskDescriptor,
        request: URLRequest,
        fileURL: URL
    ) async throws
    func existingDescriptors() async -> Set<ManualUploadTaskDescriptor>
    func cancel(jobID: UUID) async
}
```

`BackgroundManualUploadSession` owns exactly one session configured as follows:

```swift
let configuration = URLSessionConfiguration.background(
    withIdentifier: AppConfiguration.manualBackgroundSessionIdentifier
)
configuration.sessionSendsLaunchEvents = true
configuration.isDiscretionary = false
configuration.waitsForConnectivity = true
configuration.httpMaximumConnectionsPerHost = 3
```

Create tasks only with `uploadTask(with:fromFile:)`; use the delegate form without completion handlers. Collect small response bodies in memory by task identifier, pass status/body to the engine, and report `didSendBodyData` deltas.

- [ ] **Step 5: Implement the actor state machine**

`ManualBackgroundTransferEngine` owns the job store, request factory, Keychain credential store, scheduler, retry policy, and an `AsyncStream` continuation list.

Required public surface:

```swift
actor ManualBackgroundTransferEngine {
    func enqueue(_ jobs: [ManualTransferJob]) async throws
    func restore() async
    func updates() -> AsyncStream<ManualTransferProgress>
    func taskProgress(_ descriptor: ManualUploadTaskDescriptor, sent: Int64, expected: Int64) async
    func taskCompleted(
        _ descriptor: ManualUploadTaskDescriptor,
        response: HTTPURLResponse?,
        body: Data,
        error: Error?
    ) async
}
```

The state transition table is:

```text
queued -> single OR start
start 2xx -> create/schedule every missing part; URLSession limits active connections to 3
part 2xx -> persist ETag and confirmed bytes
all parts complete -> complete
complete 2xx -> completed -> cleanup
temporary failure -> retry same operation at 1/3/9 seconds
permanent failure -> cancel remaining tasks + failed count + abort when multipart is active -> next file
```

Every transition persists before scheduling the next network operation. A duplicate delegate callback must be idempotent.

When up to three parts are active, keep the most recent sent-byte count per task identifier. Publish `taskBytesSent` as the sum of all active part-task counts, and remove a task's entry when it succeeds, fails, or retries. This makes the displayed numerator match concurrent network work without counting the same retry twice.

Avoid a dependency-construction cycle by creating `BackgroundManualUploadSession` first, passing it into the engine as `ManualUploadTaskScheduling`, and then binding the engine as the session event sink:

```swift
let backgroundSession = BackgroundManualUploadSession(
    completionRegistry: backgroundCompletionRegistry
)
let manualTransferEngine = ManualBackgroundTransferEngine(
    scheduler: backgroundSession,
    jobStore: manualJobStore,
    credentialStore: credentialStore
)
backgroundSession.bind(engine: manualTransferEngine)
```

`BackgroundManualUploadSession` stores its weak engine reference behind an `NSLock`; delegate callbacks copy the reference under the lock and then call the actor in a new `Task`.

- [ ] **Step 6: Wire background relaunch callbacks**

Create `BackgroundSessionAppDelegate`:

```swift
final class BackgroundSessionAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == AppConfiguration.manualBackgroundSessionIdentifier else {
            completionHandler()
            return
        }
        AppDependencies.shared.backgroundCompletionRegistry.store(completionHandler)
        Task { await AppDependencies.shared.manualTransferEngine.restore() }
    }
}
```

Define the registry used above as a lock-protected one-shot callback holder:

```swift
final class BackgroundSessionCompletionRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (() -> Void)?

    func store(_ handler: @escaping () -> Void) {
        lock.withLock { self.handler = handler }
    }

    func finish() {
        let current = lock.withLock { () -> (() -> Void)? in
            defer { handler = nil }
            return handler
        }
        current?()
    }
}
```

Add `@UIApplicationDelegateAdaptor(BackgroundSessionAppDelegate.self)` to `SimpleCameraAutoSenderApp`. The background session delegate calls and clears the stored completion handler only from `urlSessionDidFinishEvents(forBackgroundURLSession:)`.

- [ ] **Step 7: Push and verify GREEN in CI**

Commit the transport, engine, lifecycle, configuration, request, and tests. Push and confirm the entire iOS test/build workflow passes.

---

### Task 5: Connect PhotoKit selection to the background queue and progress UI

**Files:**
- Modify: `App/Media/ManualMediaTransferService.swift`
- Modify: `App/Application/AppDependencies.swift`
- Modify: `App/Upload/BackgroundUploadCoordinator.swift`
- Modify: `App/UI/ContentViewModel.swift`
- Modify: `App/UI/ContentView.swift:101-119`
- Modify: `Tests/ManualMediaTransferServiceTests.swift`
- Modify: `Tests/ContentViewModelTests.swift`

**Interfaces:**
- `ManualMediaTransferService` exports selected assets and enqueues persisted jobs instead of awaiting foreground uploads.
- `ContentViewModel` observes `AsyncStream<ManualTransferProgress>` and publishes `manualProgress`.
- `ContentView` renders the stage, current-file percentage, bytes, and live counters.

- [ ] **Step 1: Write failing service enqueue tests**

Replace the old recording uploader with a fake engine that records `ManualTransferJob`. Assert:

- only distinct selected identifiers are exported;
- each job contains the exact original metadata and fingerprint;
- unavailable/export failures increment live failure progress;
- the service returns after jobs are durably queued, not after network completion;
- selected files remain on disk after enqueue and are deleted only by engine success cleanup.

- [ ] **Step 2: Write failing view-model progress tests**

Feed an `AsyncStream` with preparing, uploading 67%, retrying, completed, and failed states. Assert after each yield:

```swift
XCTAssertEqual(model.manualProgress?.percent, 67)
XCTAssertEqual(model.manualProgress?.uploadedCount, 1)
XCTAssertEqual(model.manualProgress?.failedCount, 1)
XCTAssertEqual(model.manualTransferMessage, "동영상 전송 실패 · 서버 크기 검증 실패 (HTTP 422)")
```

Verify `isManualTransferWorking` derives from active stages and does not remain true after a terminal state.

- [ ] **Step 3: Push test-only changes and verify RED in CI**

Commit the test changes, push, and confirm failure is due to missing queue/progress behavior.

- [ ] **Step 4: Implement queue preparation**

Change `ManualMediaTransferring` to:

```swift
protocol ManualMediaTransferring: Sendable {
    func enqueue(
        selection: ManualMediaSelection,
        kind: ManualMediaKind
    ) async -> ManualMediaTransferSummary
    func updates() async -> AsyncStream<ManualTransferProgress>
}
```

For each selected identifier, export the original, fingerprint it, create exact chunks when needed, persist the job, and hand it to the engine. Keep the existing failure categories for preparation failures. Do not scan any non-selected assets.

Create and persist `ManualTransferBatch` before the first export. Increment `preparedCount` after each export attempt and increment `failedCount` immediately for unavailable, unsupported, unreadable, or oversized selections that never produce a job.

- [ ] **Step 5: Observe progress in `ContentViewModel`**

Add:

```swift
@Published private(set) var manualProgress: ManualTransferProgress?
private var manualProgressTask: Task<Void, Never>?
```

Start one observer task during initialization, update published properties on `MainActor`, and cancel it in `deinit`. Map stable Worker codes to Korean messages without exposing response bodies.

- [ ] **Step 6: Render a determinate progress card**

Replace the spinner-only block with:

```swift
if let progress = model.manualProgress, progress.stage != .idle {
    Text(model.manualStageTitle)
        .font(.subheadline.weight(.semibold))
    if progress.totalBytes > 0 {
        ProgressView(value: Double(progress.percent), total: 100)
            .tint(progress.stage == .failed ? .red : .accentColor)
        HStack {
            Text("\(progress.percent)%")
                .font(.title3.monospacedDigit().bold())
            Spacer()
            Text(model.manualByteProgressText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    } else {
        ProgressView()
    }
}
```

Keep the existing three selection buttons and disable them while one manual batch is active so two batches cannot compete for the single status card. Background network activity must not prevent opening settings, switching apps, locking the screen, or using the rest of the app.

- [ ] **Step 7: Push and verify GREEN in CI**

After the service uses `ManualBackgroundTransferEngine`, remove the obsolete metadata overload and foreground multipart implementation from `BackgroundUploadCoordinator`; preserve its existing automatic `upload(assetID:fileURL:)`, authentication blocking, and automatic tests. Move manual multipart expectations from `DirectUploadCoordinatorTests` to `ManualBackgroundTransferEngineTests` rather than deleting coverage.

Commit the service, dependencies, foreground-uploader cleanup, model, view, and tests. Push and require all iOS tests plus unsigned IPA build to succeed.

---

### Task 6: Version, deploy, and verify on the real path

**Files:**
- Modify: `project.yml`
- Modify: `README.md`
- Modify: `docs/install.md`
- Regenerate release asset: `docs/install-qr.png` through the release workflow only

**Interfaces:**
- Produces Worker version with corrected completion verification.
- Produces SideStore release `v0.1.8`, IPA `SimpleCameraAutoSender.ipa`, and `install-qr.png`.

- [ ] **Step 1: Bump and document exact behavior**

Set:

```yaml
CURRENT_PROJECT_VERSION: 6
MARKETING_VERSION: 0.1.8
```

Document the determinate progress UI, background app-switch/screen-lock support, persisted resume behavior, and force-quit limitation. Do not claim the app auto-closes.

- [ ] **Step 2: Run fresh local Worker and receiver regression tests**

```powershell
Set-Location "C:\Users\user\Documents\김희종 개발 프로그램\SimpleCamera 업무사진 수신기\cloudflare\photo-relay"
npm test -- --run
npm run typecheck

Set-Location "C:\Users\user\Documents\김희종 개발 프로그램\SimpleCamera 업무사진 수신기"
& .\.venv\Scripts\python.exe -m pytest
```

Expected: Worker tests and all receiver tests pass with zero failures.

- [ ] **Step 3: Push iOS branch and require green CI**

```powershell
git push origin codex/background-manual-transfer-progress
gh run list --branch codex/background-manual-transfer-progress --limit 1
$runID = gh run list --branch codex/background-manual-transfer-progress --limit 1 --json databaseId --jq '.[0].databaseId'
gh run watch $runID --exit-status
```

Expected: iOS tests pass, unsigned IPA builds, artifact uploads.

- [ ] **Step 4: Deploy Worker before publishing the app**

```powershell
Set-Location "C:\Users\user\Documents\김희종 개발 프로그램\SimpleCamera 업무사진 수신기\cloudflare\photo-relay"
$env:NODE_OPTIONS='--use-system-ca'
npx wrangler deploy
Invoke-WebRequest -UseBasicParsing -Uri "https://simplecamera-work-photo-relay.simplecamera-work-photo-relay.workers.dev/api/health"
```

Expected: deployment exits 0 and health returns HTTP 200 with `{"ok":true}`.

- [ ] **Step 5: Perform real-device acceptance tests before tagging**

Use the CI artifact on the iPhone and verify, in this order:

1. transfer one small photo and confirm PC save/ACK;
2. transfer one 100MB+ MOV and confirm percent moves and final PC size/hash;
3. transfer the reproduced roughly 300MB video while opening YouTube or Safari;
4. repeat while locking the screen;
5. interrupt Wi-Fi briefly and confirm only the active part retries;
6. reopen the app and confirm progress/terminal counts restore;
7. verify no unselected media appears on the PC.

Capture Worker tail only for method/status verification and stop it after the test. Do not output authorization headers, IDs, filenames, or upload IDs.

- [ ] **Step 6: Merge, tag, and publish**

After acceptance passes:

```powershell
git switch main
git merge --ff-only codex/background-manual-transfer-progress
git push origin main
git tag -a v0.1.8 -m "SimpleCamera Auto Sender v0.1.8"
git push origin v0.1.8
```

Watch the `Release SideStore IPA` workflow and verify both release assets exist.

- [ ] **Step 7: Verify the public IPA and QR**

```powershell
gh release view v0.1.8 --json assets,url,publishedAt
python scripts/generate-install-qr.py --check
```

HEAD-request the stable latest IPA URL and require HTTP 200. Download the QR asset, compare its SHA-256 to the GitHub release digest, and present the absolute local QR path and release link to the user.
