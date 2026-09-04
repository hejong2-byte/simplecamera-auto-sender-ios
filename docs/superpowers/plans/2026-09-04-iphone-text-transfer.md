# SimpleCamera iPhone Text Transfer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove two fixed home descriptions and add Windows-compatible text send/receive, durable history, copy, TXT export, and deletion.

**Architecture:** Keep the Windows `simplecamera-text-v1` upload protocol unchanged. Add receiver-secret-scoped Worker read/ACK routes, then isolated Swift protocol, store, client, service, view model, and views. One root-owned text view model performs foreground polling and retains unread state across navigation.

**Tech Stack:** Swift 5, SwiftUI, Foundation, CryptoKit, XCTest/XCUITest, TypeScript, Cloudflare Workers/R2/D1, Vitest, GitHub Actions, SideStore IPA.

## Global Constraints

- Keep iOS 17.0 and bundle ID `com.hejong2byte.simplecameraautosender`.
- Use format `simplecamera-text-v1`, MIME `application/vnd.simplecamera.text+json`, and mailbox `53435458-0000-4000-8000-000000{6-digit code}`.
- JSON keys are exactly `format`, `id`, `sender`, `recipient`, `created_at`, and `text`.
- Accept only codes matching `^[1-9][0-9]{5}$`; permit at most 1 MiB of nonblank UTF-8 text without NUL.
- Atomically save received text before ACK; never ACK invalid or unsaved data.
- Never store `PC_RECEIVE_TOKEN` on iPhone. Reuse `receiverID` and `receiveSecret`.
- Preserve Simple Cam-only filtering, all existing ledgers/data/credentials, and the Windows client.
- Support foreground polling only; do not claim push or terminated-app receipt.
- Remove only the two approved fixed descriptions; retain operational status text.

---

### Task 1: Remove Fixed Home Descriptions

**Files:**
- Modify: `Tests/ProjectSmokeTests.swift`
- Modify: `UITests/ForegroundReceiveUITests.swift`
- Modify: `App/UI/ContentView.swift`

**Interfaces:**
- Consumes: Existing home accessibility identifiers.
- Produces: Compact home cards with operational status preserved.

- [ ] **Step 1: Add failing tests**

Add a source test that rejects the two exact strings and requires `model.automaticTransferMessage` plus `PCReceiveStatusView`. Add a UI test that rejects both static labels while requiring `manual-photo` and `open-receiver`.

```swift
XCTAssertFalse(source.contains("여러 개 선택 가능 · 큰 파일은 32MB씩 나눠 백그라운드 전송합니다. 카카오톡 파일 폴더는 처음 한 번 지정합니다."))
XCTAssertFalse(source.contains("PC에서 보낸 파일을 iPhone에 저장하거나 USB로 직접 저장"))
XCTAssertTrue(source.contains("model.automaticTransferMessage"))
XCTAssertTrue(source.contains("PCReceiveStatusView(status: receiverModel.receiveStatus"))
```

- [ ] **Step 2: Run `bash scripts/test-ios.sh` on CI**

Expected: the new source test fails only because both descriptions still exist.

- [ ] **Step 3: Delete only those two `Text` blocks**

Leave the buttons, code, progress, completion, error, and monitoring state unchanged.

- [ ] **Step 4: Run `bash scripts/test-ios.sh`**

Expected: the new source/UI tests and every existing test pass.

- [ ] **Step 5: Commit**

```bash
git add Tests/ProjectSmokeTests.swift UITests/ForegroundReceiveUITests.swift App/UI/ContentView.swift
git commit -m "ui: remove fixed home menu descriptions"
```

---

### Task 2: Add the Compatible Text Envelope

**Files:**
- Create: `App/Text/TextMessage.swift`
- Create: `Tests/TextMessageTests.swift`

**Interfaces:**
- Produces: `TextMessageEnvelope`, `TextTransferConstants`, `TextMailbox.identifier(for:)`, `TextDigest.hex(_:)`, and `TextDigest.contentID(_:)`.
- Consumers: Tasks 3 and 5.

- [ ] **Step 1: Add failing compatibility tests**

Pin a Windows JSON fixture containing leading and trailing spaces, newline, tab, Korean, and emoji. Assert exact mailbox UUID, SHA-256, deterministic content UUID, 1 MiB boundary, exact key set, recipient match, UUID v4, timezone-bearing date, blank rejection, and NUL rejection.

```swift
let data = Data(#"{"format":"simplecamera-text-v1","id":"123e4567-e89b-42d3-a456-426614174111","sender":"123456","recipient":"654321","created_at":"2026-09-04T01:02:03+00:00","text":"  프롬프트\n\t한글🙂\n"}"#.utf8)
let message = try TextMessageEnvelope.decode(data, expectedRecipient: "654321")
XCTAssertEqual(message.text, "  프롬프트\n\t한글🙂\n")
XCTAssertEqual(try TextMailbox.identifier(for: "654321").uuidString.lowercased(), "53435458-0000-4000-8000-000000654321")
```

- [ ] **Step 2: Run `bash scripts/test-ios.sh` on CI**

Expected: compile failure naming the new envelope and mailbox types.

- [ ] **Step 3: Implement the protocol types**

```swift
enum TextTransferConstants {
    static let format = "simplecamera-text-v1"
    static let mime = "application/vnd.simplecamera.text+json"
    static let maxTextBytes = 1_048_576
    static let maxEnvelopeBytes = maxTextBytes * 6 + 2_048
}

struct TextMessageEnvelope: Codable, Equatable, Sendable, Identifiable {
    let format: String
    let id: UUID
    let sender: String
    let recipient: String
    let createdAt: Date
    let text: String

    enum CodingKeys: String, CodingKey {
        case format, id, sender, recipient, text
        case createdAt = "created_at"
    }

    static func make(sender: String, recipient: String, text: String, id: UUID = UUID(), now: Date = Date()) throws -> Self
    func encoded() throws -> Data
    static func decode(_ data: Data, expectedRecipient: String) throws -> Self
}
```

Use CryptoKit SHA-256. Validate raw keys before decoding. Accept ISO 8601 timestamps with or without fractional seconds.

- [ ] **Step 4: Run `bash scripts/test-ios.sh`**

Expected: all envelope and existing tests pass.

- [ ] **Step 5: Commit**

```bash
git add App/Text/TextMessage.swift Tests/TextMessageTests.swift
git commit -m "feat: add compatible text envelope"
```

---

### Task 3: Add Durable Per-Message Storage

**Files:**
- Create: `App/Text/TextMessageStore.swift`
- Create: `Tests/TextMessageStoreTests.swift`

**Interfaces:**
- Consumes: `TextMessageEnvelope` and `TextDigest.hex(_:)`.
- Produces: `TextMessageStore`, `TextStoredMessage`, `TextMessageKey`, and `TextDraft`.

- [ ] **Step 1: Add failing durability tests**

Test reopen after save, pending outgoing recovery, mark-delivered, exact draft text, duplicate receive, same-ID/different-body collision, deletion tombstone, and newest-first history.

```swift
let store = TextMessageStore(root: temporaryDirectory)
let message = try TextMessageEnvelope.make(sender: "123456", recipient: "654321", text: "  원문\n")
let body = try message.encoded()
XCTAssertEqual(try await store.saveReceived(message, body: body), .inserted)
let reopened = TextMessageStore(root: temporaryDirectory)
XCTAssertEqual(try await reopened.history().first?.envelope.text, "  원문\n")
try await reopened.delete(.init(direction: .received, id: message.id))
XCTAssertEqual(try await reopened.saveReceived(message, body: body), .previouslyDeleted)
```

- [ ] **Step 2: Run `bash scripts/test-ios.sh` on CI**

Expected: compile failure naming `TextMessageStore`.

- [ ] **Step 3: Implement the actor and record types**

```swift
enum TextMessageDirection: String, Codable, Sendable { case sent, received }
enum TextMessageDeliveryStatus: String, Codable, Sendable { case pending, serverDelivered, received }
struct TextMessageKey: Hashable, Codable, Sendable {
    let direction: TextMessageDirection
    let id: UUID
}
struct TextStoredMessage: Codable, Identifiable, Equatable, Sendable {
    let key: TextMessageKey
    var envelope: TextMessageEnvelope
    let bodySHA256: String
    var status: TextMessageDeliveryStatus
    var readAt: Date?
    var id: TextMessageKey { key }
}
struct TextDraft: Codable, Equatable, Sendable {
    var recipient: String
    var text: String
}
enum TextReceiveSaveResult: Equatable { case inserted, duplicate, previouslyDeleted }
```

Expose these actor methods:

```swift
actor TextMessageStore {
    init(root: URL)
    func queueOutgoing(sender: String, recipient: String, text: String) throws -> TextStoredMessage
    func markServerDelivered(id: UUID) throws
    func saveReceived(_ envelope: TextMessageEnvelope, body: Data) throws -> TextReceiveSaveResult
    func history() throws -> [TextStoredMessage]
    func markRead(_ key: TextMessageKey, at: Date = Date()) throws
    func delete(_ key: TextMessageKey) throws
    func saveDraft(_ draft: TextDraft) throws
    func loadDraft() throws -> TextDraft
}
```

Store records as `messages/sent-<uuid>.json` and `messages/received-<uuid>.json`, the draft as `draft.json`, and received deletion hashes as `deleted-received.json`. Write a same-directory temporary file and replace or move it atomically. Persist a received tombstone before deleting the message file.

- [ ] **Step 4: Run `bash scripts/test-ios.sh`**

Expected: all reopen, collision, deletion, and draft tests pass with no store regressions.

- [ ] **Step 5: Commit**

```bash
git add App/Text/TextMessageStore.swift Tests/TextMessageStoreTests.swift
git commit -m "feat: persist text history safely"
```

---

### Task 4: Add Scoped Worker Text Routes

**Files:**
- Modify: `C:/Users/user/Documents/김희종 개발 프로그램/SimpleCamera 업무사진 수신기/cloudflare/photo-relay/src/iphone_receiver.ts`
- Modify: `C:/Users/user/Documents/김희종 개발 프로그램/SimpleCamera 업무사진 수신기/cloudflare/photo-relay/test/iphone_receiver.test.ts`

**Interfaces:**
- Consumes: `iphone_receivers`, `receiverAuthorized`, and legacy R2 mailbox objects.
- Produces: list, download, and ACK routes under `/api/iphone-receivers/:receiverID/texts`.

- [ ] **Step 1: Add failing Worker tests**

Register two receivers. Put a Windows-format text object at `mailboxes/53435458-0000-4000-8000-000000{code}/files/{id}`. Assert that the matching receiver secret can list, download, and ACK it; the other secret gets 403; and a non-text object in the same prefix is never listed, downloaded, or deleted.

```typescript
const own = { Authorization: `Bearer ${receiver.receiveSecret}` };
const listURL = `https://relay/api/iphone-receivers/${receiver.receiverId}/texts`;
const itemURL = `${listURL}/${id}`;
expect((await SELF.fetch(listURL, { headers: own })).status).toBe(200);
expect((await SELF.fetch(itemURL, { headers: own })).status).toBe(200);
expect((await SELF.fetch(`${itemURL}/ack`, { method: "POST", headers: own })).status).toBe(204);
```

- [ ] **Step 2: Run `npm test` and `npm run typecheck`**

Working directory: `C:\Users\user\Documents\김희종 개발 프로그램\SimpleCamera 업무사진 수신기\cloudflare\photo-relay`.

Expected: the new route assertions get 404 before implementation; existing tests pass.

- [ ] **Step 3: Implement bounded handlers**

```typescript
const TEXT_MIME = "application/vnd.simplecamera.text+json";
const MAX_TEXT_ENVELOPE_BYTES = 1024 * 1024 * 6 + 2048;

function textMailbox(code: string): string {
  return `53435458-0000-4000-8000-000000${code}`;
}
```

Resolve the registered code only after `receiverAuthorized` succeeds. List only exact text MIME objects whose size is within bounds. Download and ACK must repeat the MIME, size, UUID, and mailbox checks after `head`. A missing ACK target returns 204; a non-text target returns 404 and remains stored.

- [ ] **Step 4: Add route matching before the generic iPhone 404**

```typescript
const textList = path.match(/^\/api\/iphone-receivers\/([^/]+)\/texts$/);
const textItem = path.match(/^\/api\/iphone-receivers\/([^/]+)\/texts\/([^/]+)(?:\/(ack))?$/);
```

Allow only GET for list/download and POST for ACK. Reject other methods with 405.

- [ ] **Step 5: Run `npm test`, `npm run typecheck`, and `npx wrangler deploy --dry-run`**

Expected: all Worker tests pass, the cross-receiver request remains 403, and the non-text object remains in R2.

- [ ] **Step 6: Commit only the Worker directory**

From the root workspace, stage `SimpleCamera 업무사진 수신기/cloudflare/photo-relay` only, inspect `git diff --cached --check`, and commit with:

```bash
git commit -m "feat: authorize iPhone text mailbox reception"
```

Do not stage any other root-workspace changes.

---

### Task 5: Add the iPhone Client and Receive Service

**Files:**
- Create: `App/Text/TextTransferClient.swift`
- Create: `App/Text/TextTransferService.swift`
- Create: `Tests/TextTransferClientTests.swift`
- Create: `Tests/TextTransferServiceTests.swift`

**Interfaces:**
- Consumes: envelope, store, upload `CredentialStore`, receiver registration, and `IPhoneReceiverTransport`.
- Produces: `TextTransferServing`, `TextTransferClient`, `TextReceiveSummary`, and `TextTransferService`.

- [ ] **Step 1: Add failing client and service tests**

Assert upload requests use `Bearer upload` and `/api/mailboxes/{textMailbox}/files`, while list/download/ACK use `Bearer receive` and `/api/iphone-receivers/{receiverID}/texts`. With a deterministic fake transport, assert outgoing persistence precedes the first request, multipart response IDs and ETags are verified, received size/SHA-256 are verified, local save precedes ACK, and invalid or unsaved data is not ACKed.

```swift
XCTAssertEqual(start.url?.path, "/api/mailboxes/53435458-0000-4000-8000-000000654321/files/multipart")
XCTAssertEqual(start.value(forHTTPHeaderField: "Authorization"), "Bearer upload")
XCTAssertEqual(list.url?.path, "/api/iphone-receivers/bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb/texts")
XCTAssertEqual(list.value(forHTTPHeaderField: "Authorization"), "Bearer receive")
```

- [ ] **Step 2: Run `bash scripts/test-ios.sh` on CI**

Expected: compile failure naming the new request factory and service.

- [ ] **Step 3: Implement the network interfaces**

```swift
struct TextRemoteItem: Decodable, Equatable, Sendable {
    let id: UUID
    let name: String
    let contentType: String
    let size: Int
    let sha256: String
    let createdAt: Date
}

protocol TextTransferServing: Sendable {
    func send(_ message: TextMessageEnvelope, uploadCredential: String) async throws
    func list(receiverID: UUID, receiveSecret: String) async throws -> [TextRemoteItem]
    func download(receiverID: UUID, itemID: UUID, receiveSecret: String) async throws -> Data
    func acknowledge(receiverID: UUID, itemID: UUID, receiveSecret: String) async throws
}
```

Send one multipart part because the validated envelope is bounded. Verify start ID, upload ID, part number, ETag, and complete ID. Reject list rows with wrong MIME, invalid size/hash, or content ID not derived from SHA-256.

- [ ] **Step 4: Implement the service**

```swift
struct TextReceiveSummary: Equatable, Sendable {
    let received: Int
    let duplicates: Int
    let rejected: Int
    let pendingACK: Int
}

actor TextTransferService {
    init(store: TextMessageStore, client: any TextTransferServing, uploadCredentials: any CredentialStore, registrations: IPhoneReceiverRegistrationStore)
    func send(recipient: String, text: String) async throws -> TextStoredMessage
    func retry(id: UUID) async throws -> TextStoredMessage
    func receiveOnce() async throws -> TextReceiveSummary
    func history() async throws -> [TextStoredMessage]
    func markRead(_ key: TextMessageKey) async throws
    func delete(_ key: TextMessageKey) async throws
    func loadDraft() async throws -> TextDraft
    func saveDraft(_ draft: TextDraft) async throws
}
```

Queue outgoing text before network I/O. Decode incoming bodies against the registered iPhone code. ACK inserted, duplicate, or tombstoned valid messages only after the store returns successfully.

- [ ] **Step 5: Run `bash scripts/test-ios.sh`**

Expected: client and service tests pass, including the no-ACK-before-save case.

- [ ] **Step 6: Commit**

```bash
git add App/Text/TextTransferClient.swift App/Text/TextTransferService.swift Tests/TextTransferClientTests.swift Tests/TextTransferServiceTests.swift
git commit -m "feat: send and receive compatible text"
```

---

### Task 6: Add Foreground Monitoring and Dependencies

**Files:**
- Create: `App/Application/TextTransferDependencies.swift`
- Create: `App/UI/TextTransferViewModel.swift`
- Create: `Tests/TextTransferViewModelTests.swift`
- Modify: `App/Application/SimpleCameraAutoSenderApp.swift`
- Modify: `App/Testing/ForegroundReceiveSimulation.swift`

**Interfaces:**
- Consumes: `TextTransferService` and existing Keychain account names.
- Produces: one root-owned `TextTransferViewModel` with polling, history, draft, status, error, and unread count.

- [ ] **Step 1: Add failing view-model tests**

With injected closures, test immediate refresh on activation, no overlapping poll, cancellation on deactivation, five-second repeat interval, unread count until `markRead`, persistent draft, send/retry states, and distinct registration, authentication, network, and storage errors.

```swift
model.setActive(true)
await probe.waitForReceiveCalls(1)
XCTAssertEqual(model.unreadCount, 1)
await model.markRead(receivedUnreadRecord.key)
XCTAssertEqual(model.unreadCount, 0)
```

- [ ] **Step 2: Run `bash scripts/test-ios.sh` on CI**

Expected: compile failure naming `TextTransferViewModel`.

- [ ] **Step 3: Build live dependencies**

Create `Application Support/SimpleCameraAutoSender/TextMessages`. Instantiate `TextMessageStore`, `TextTransferClient`, `KeychainCredentialStore()` for upload authorization, and a new `IPhoneReceiverRegistrationStore` using the existing receiver identity and secret account names.

- [ ] **Step 4: Implement the main-actor view model**

Expose `setActive(_:)`, `refresh()`, `send()`, `retry(_:)`, `markRead(_:)`, `delete(_:)`, `saveDraft()`, and published state. Own one cancellable polling task and serialize refresh/send calls so list and ACK operations do not overlap.

- [ ] **Step 5: Wire app and simulation roots**

Add `textModel:` to `ContentView`. Pass the live model from `TextTransferDependencies.shared`; pass an in-memory simulation model from `ForegroundReceiveSimulation`, including an optional fixed incoming record for UI tests.

- [ ] **Step 6: Run `bash scripts/test-ios.sh`**

Expected: all view-model tests and existing foreground file-receive tests pass without a live network call.

- [ ] **Step 7: Commit**

```bash
git add App/Application/TextTransferDependencies.swift App/UI/TextTransferViewModel.swift App/Application/SimpleCameraAutoSenderApp.swift App/Testing/ForegroundReceiveSimulation.swift Tests/TextTransferViewModelTests.swift
git commit -m "feat: monitor text while app is active"
```

---

### Task 7: Build the Text UI and Record Actions

**Files:**
- Create: `App/UI/TextTransferView.swift`
- Create: `App/UI/TextMessageDetailView.swift`
- Modify: `App/UI/ContentView.swift`
- Modify: `UITests/ForegroundReceiveUITests.swift`
- Modify: `Tests/ProjectSmokeTests.swift`

**Interfaces:**
- Consumes: the root-owned `TextTransferViewModel`.
- Produces: `open-text-transfer`, send/refresh controls, persistent history, copy, TXT export, share, retry, and confirmed delete.

- [ ] **Step 1: Add failing UI tests**

Launch the simulation with one fixed received message. Assert the menu opens, own code and fields exist, and record detail exposes copy, export, share, and delete controls.

```swift
let app = launchSimulation(delay: 3_600, withTextMessage: true)
XCTAssertTrue(app.buttons["open-text-transfer"].waitForExistence(timeout: 20))
app.buttons["open-text-transfer"].tap()
XCTAssertTrue(app.textFields["text-recipient"].exists)
XCTAssertTrue(app.textViews["text-body"].exists)
XCTAssertTrue(app.buttons["text-send"].exists)
XCTAssertTrue(app.buttons["text-refresh"].exists)
```

Add a source contract requiring `Destination.text`, `TextTransferView`, and `open-text-transfer`, while still rejecting the two removed descriptions.

- [ ] **Step 2: Run `bash scripts/test-ios.sh` on CI**

Expected: the UI test fails because `open-text-transfer` is absent.

- [ ] **Step 3: Add the home navigation link**

Place `텍스트 송수신` after the manual file card and before PC file receive. Show unread count and a chevron without a fixed explanatory subtitle. Add `.text` to the navigation destination.

```swift
NavigationLink(value: Destination.text) {
    HStack {
        Label("텍스트 송수신", systemImage: "text.bubble.fill")
        Spacer()
        if textModel.unreadCount > 0 { Text("\(textModel.unreadCount)") }
        Image(systemName: "chevron.right")
    }
    .font(.headline)
}
.accessibilityIdentifier("open-text-transfer")
```

- [ ] **Step 4: Implement the send/history screen**

Show own code, six-digit numeric recipient field, multiline editor, Send, manual Refresh, status/error, and newest-first history. Disable Send unless code and text validate or while sending. Preserve the exact draft on every edit.

- [ ] **Step 5: Implement record detail actions**

Show exact untrimmed text. Only `전체 복사` writes to `UIPasteboard.general.string`. Use a UTF-8 `FileDocument` for `.fileExporter` and a temporary `.txt` URL for `ShareLink`. Require destructive confirmation before delete; retain the row if deletion fails.

- [ ] **Step 6: Run `bash scripts/test-ios.sh`**

Expected: the new screenshots contain no fixed descriptions, text controls are hittable, and every unit/UI test passes.

- [ ] **Step 7: Commit**

```bash
git add App/UI/TextTransferView.swift App/UI/TextMessageDetailView.swift App/UI/ContentView.swift UITests/ForegroundReceiveUITests.swift Tests/ProjectSmokeTests.swift
git commit -m "feat: add iPhone text transfer interface"
```

---

### Task 8: Deploy and Release SideStore Version 0.3.11

**Files:**
- Modify: `project.yml`
- Modify: `Tests/ProjectSmokeTests.swift`
- Modify: `docs/install.md`
- Create: `docs/verification/2026-09-04-iphone-text-transfer.md`
- Generate: `dist/SimpleCameraAutoSender.ipa`
- Generate: `docs/install-qr.png`

**Interfaces:**
- Consumes: green Worker and iOS suites.
- Produces: deployed scoped text routes and version 0.3.11 build 22 IPA/QR.

- [ ] **Step 1: Run the Worker release gate**

From the Worker directory run:

```powershell
npm test
npm run typecheck
npx wrangler deploy --dry-run
```

Expected: zero failed tests, zero type errors, and successful bundling without secret values in output.

- [ ] **Step 2: Deploy and smoke-test the Worker**

Run `npm run deploy`. With isolated test receivers and synthetic text only, verify upload, list, download, hash equality, ACK, and cross-receiver 403. Record status codes, IDs, byte counts, and hashes only; never record credentials.

- [ ] **Step 3: Bump the app version**

Set:

```yaml
CURRENT_PROJECT_VERSION: 22
MARKETING_VERSION: 0.3.11
```

Update the version smoke test, then run `bash scripts/test-ios.sh` through GitHub Actions. Inspect `main-without-fixed-descriptions` and the text-transfer screenshots.

- [ ] **Step 4: Verify Windows/iPhone compatibility**

Send an isolated fixture containing whitespace, Korean, emoji, newline, and tab in both directions. Compare exact text bytes and SHA-256 after persistence. Do not use or modify operational user messages.

- [ ] **Step 5: Commit and push release metadata**

```bash
git add project.yml Tests/ProjectSmokeTests.swift docs/install.md docs/verification/2026-09-04-iphone-text-transfer.md
git commit -m "release: prepare SideStore 0.3.11"
git push origin codex/foreground-receive-alert
```

- [ ] **Step 6: Create a new tag safely**

Check local tags, remote tags, and GitHub releases for `v0.3.11`. Only when absent:

```bash
git tag v0.3.11
git push origin v0.3.11
```

Require the release workflow's test, build, QR, and publish steps to succeed.

- [ ] **Step 7: Verify and deliver artifacts**

Download the IPA and QR into `C:\Users\user\Desktop\SimpleCamera-iPhone-0.3.11`. Verify IPA ZIP integrity, bundle ID, version/build, SHA-256, QR decode, and that the QR URL resolves to the same IPA hash. Display the QR directly and provide direct QR/IPA links.

- [ ] **Step 8: Record final evidence**

Write test counts, workflow run ID, Worker smoke statuses, hashes, and artifact paths to the verification document without credentials. Commit and push it with:

```bash
git commit -m "docs: record text transfer release verification"
```
