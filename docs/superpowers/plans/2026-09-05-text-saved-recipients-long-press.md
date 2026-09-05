# Text Saved Recipients and Long-Press Actions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add up to five named text recipient codes to the iPhone app and expose copy, TXT export, share, and delete actions by long-pressing a text history row.

**Architecture:** A new actor owns a separate atomic JSON file containing named recipient shortcuts and the last selected code. `TextTransferViewModel` receives narrow load/save/select/delete closures and publishes the validated state to SwiftUI. The existing detail actions and new row context menu share one export helper so both paths use identical UTF-8 content and filenames.

**Tech Stack:** Swift 5, SwiftUI, Foundation, UIKit share sheet, XCTest/XCUITest, XcodeGen, GitHub Actions macOS runner.

## Global Constraints

- Store at most five named recipient codes; each code is exactly six ASCII digits and each trimmed name is non-empty.
- Saving an existing code updates only its name and keeps its list position.
- A saved row displays both name and code, for example `행정망 PC · 709592`.
- Preserve existing text message JSON, tombstones, draft, photo transfer ledger, PC file receive records, and credentials.
- Keep the current short-tap navigation to text details; add long-press actions without removing detail actions.
- Do not change the Windows client, server protocol, photo filtering, or automatic transfer behavior.
- Browser use is unnecessary; if it becomes necessary, use Google Chrome only.

---

### Task 1: Persist named text recipients independently

**Files:**
- Create: `App/Text/TextSavedRecipientStore.swift`
- Create: `Tests/TextSavedRecipientStoreTests.swift`

**Interfaces:**
- Produces: `TextSavedRecipient`, `TextSavedRecipientState`, `TextSavedRecipientStoreError`, and actor `TextSavedRecipientStore`.
- Produces methods: `load() throws -> TextSavedRecipientState`, `save(code:name:) throws -> TextSavedRecipientState`, `select(code:) throws -> TextSavedRecipientState`, and `delete(code:) throws -> TextSavedRecipientState`.

- [ ] **Step 1: Write failing persistence and validation tests**

Create focused tests using a unique temporary directory. Cover first save, five-entry limit, same-code rename without reorder, selection persistence, delete, invalid entries being filtered, and a failed write leaving the last good file intact.

```swift
func testSaveRenameSelectAndReload() async throws {
    let fileURL = temporaryRoot().appendingPathComponent("saved-recipients.json")
    let store = TextSavedRecipientStore(fileURL: fileURL)
    _ = try await store.save(code: "709592", name: " 행정망 PC ")
    _ = try await store.save(code: "123456", name: "아이폰")
    _ = try await store.select(code: "709592")
    _ = try await store.save(code: "709592", name: "행정망 업무 PC")

    let reloaded = try await TextSavedRecipientStore(fileURL: fileURL).load()
    XCTAssertEqual(reloaded.recipients.map(\.displayLabel), [
        "행정망 업무 PC · 709592", "아이폰 · 123456"
    ])
    XCTAssertEqual(reloaded.selectedCode, "709592")
}

func testSixthDistinctRecipientIsRejectedButExistingCodeCanBeRenamed() async throws {
    let store = TextSavedRecipientStore(fileURL: temporaryRoot().appendingPathComponent("saved-recipients.json"))
    for number in 100000..<100005 {
        _ = try await store.save(code: String(number), name: "기기 \(number)")
    }
    await XCTAssertThrowsErrorAsync(try await store.save(code: "100005", name: "여섯째")) {
        XCTAssertEqual($0 as? TextSavedRecipientStoreError, .limitReached)
    }
    let renamed = try await store.save(code: "100000", name: "첫 기기")
    XCTAssertEqual(renamed.recipients.count, 5)
    XCTAssertEqual(renamed.recipients[0].name, "첫 기기")
}
```

- [ ] **Step 2: Push the test-only commit and verify red CI**

Run:

```powershell
git add Tests/TextSavedRecipientStoreTests.swift
git commit -m "test: define saved text recipient behavior"
git push origin codex/foreground-receive-alert
gh run watch --repo hejong2byte/SimpleCameraAutoSender-iOS --exit-status
```

Expected: CI fails to compile because `TextSavedRecipientStore` and related types do not exist.

- [ ] **Step 3: Implement the minimal atomic store**

Implement validated, filtered state and atomic replacement without touching the message store.

```swift
struct TextSavedRecipient: Codable, Equatable, Identifiable, Sendable {
    let code: String
    var name: String
    var id: String { code }
    var displayLabel: String { "\(name) · \(code)" }
}

struct TextSavedRecipientState: Codable, Equatable, Sendable {
    var recipients: [TextSavedRecipient]
    var selectedCode: String?
    static let empty = Self(recipients: [], selectedCode: nil)
}

enum TextSavedRecipientStoreError: Error, Equatable {
    case invalidCode
    case emptyName
    case limitReached
    case recipientNotFound
}

actor TextSavedRecipientStore {
    static let limit = 5
    typealias Persistence = (Data, URL, FileManager) throws -> Void

    private let fileURL: URL
    private let fileManager: FileManager
    private let persistence: Persistence
    private var cachedState: TextSavedRecipientState?

    init(
        fileURL: URL,
        fileManager: FileManager = .default,
        persistence: @escaping Persistence = TextSavedRecipientStore.persistAtomically
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.persistence = persistence
    }

    func load() throws -> TextSavedRecipientState {
        if let cachedState { return cachedState }
        let decoded: TextSavedRecipientState
        if fileManager.fileExists(atPath: fileURL.path) {
            decoded = (try? JSONDecoder().decode(
                TextSavedRecipientState.self,
                from: Data(contentsOf: fileURL)
            )) ?? .empty
        } else {
            decoded = .empty
        }
        let state = Self.sanitized(decoded)
        cachedState = state
        return state
    }

    func save(code: String, name: String) throws -> TextSavedRecipientState {
        let code = try Self.validatedCode(code)
        let name = try Self.validatedName(name)
        var state = try load()
        if let index = state.recipients.firstIndex(where: { $0.code == code }) {
            state.recipients[index].name = name
        } else {
            guard state.recipients.count < Self.limit else {
                throw TextSavedRecipientStoreError.limitReached
            }
            state.recipients.append(TextSavedRecipient(code: code, name: name))
        }
        try persist(state)
        return state
    }

    func select(code: String) throws -> TextSavedRecipientState {
        let code = try Self.validatedCode(code)
        var state = try load()
        guard state.recipients.contains(where: { $0.code == code }) else {
            throw TextSavedRecipientStoreError.recipientNotFound
        }
        state.selectedCode = code
        try persist(state)
        return state
    }

    func delete(code: String) throws -> TextSavedRecipientState {
        let code = try Self.validatedCode(code)
        var state = try load()
        guard let index = state.recipients.firstIndex(where: { $0.code == code }) else {
            throw TextSavedRecipientStoreError.recipientNotFound
        }
        state.recipients.remove(at: index)
        if state.selectedCode == code { state.selectedCode = nil }
        try persist(state)
        return state
    }

    private func persist(_ state: TextSavedRecipientState) throws {
        let data = try JSONEncoder().encode(state)
        try persistence(data, fileURL, fileManager)
        cachedState = state
    }

    private static func sanitized(_ decoded: TextSavedRecipientState) -> TextSavedRecipientState {
        var seen = Set<String>()
        let recipients = decoded.recipients.compactMap { item -> TextSavedRecipient? in
            guard seen.count < limit,
                  let code = try? validatedCode(item.code),
                  let name = try? validatedName(item.name),
                  seen.insert(code).inserted else { return nil }
            return TextSavedRecipient(code: code, name: name)
        }
        let selected = decoded.selectedCode.flatMap { candidate in
            recipients.contains(where: { $0.code == candidate }) ? candidate : nil
        }
        return TextSavedRecipientState(recipients: recipients, selectedCode: selected)
    }

    private static func validatedCode(_ value: String) throws -> String {
        let code = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.count == 6,
              code.unicodeScalars.allSatisfy({ (48...57).contains(Int($0.value)) }) else {
            throw TextSavedRecipientStoreError.invalidCode
        }
        return code
    }

    private static func validatedName(_ value: String) throws -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw TextSavedRecipientStoreError.emptyName }
        return name
    }

    static func persistAtomically(_ data: Data, to fileURL: URL, fileManager: FileManager) throws {
        let parent = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let temporary = parent.appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporary)
            if fileManager.fileExists(atPath: fileURL.path) {
                _ = try fileManager.replaceItemAt(fileURL, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: fileURL)
            }
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }
}
```

Persist through a sibling temporary file and `replaceItemAt`/`moveItem`; update `cachedState` only after disk persistence succeeds. A completely undecodable file yields an empty in-memory state but is not rewritten until the user performs an explicit successful mutation.

- [ ] **Step 4: Push and verify green store tests**

Run the CI workflow through a normal branch push. Expected: all existing tests plus `TextSavedRecipientStoreTests` pass and the unsigned IPA build completes.

- [ ] **Step 5: Commit**

```powershell
git add App/Text/TextSavedRecipientStore.swift Tests/TextSavedRecipientStoreTests.swift
git commit -m "feat: persist named text recipients"
```

---

### Task 2: Integrate recipient state into the text view model

**Files:**
- Modify: `App/Application/TextTransferDependencies.swift`
- Modify: `App/UI/TextTransferViewModel.swift`
- Modify: `App/Testing/ForegroundReceiveSimulation.swift`
- Modify: `Tests/TextTransferViewModelTests.swift`

**Interfaces:**
- Consumes: Task 1 store methods and `TextSavedRecipientState`.
- Produces view-model methods: `saveRecipient(name:) async`, `selectRecipient(code:) async`, `deleteRecipient(code:) async`, and `recipientDidChange()`.
- Produces published values: `savedRecipients: [TextSavedRecipient]` and `selectedRecipientCode: String?`.

- [ ] **Step 1: Write failing view-model tests**

Extend the probe with recipient state and mutations, then assert load, selection, direct-edit deselection, rename, delete, and user-facing errors.

```swift
func testSavedRecipientsLoadSelectRenameDeleteAndClearSelectionOnManualEdit() async {
    let probe = TextViewModelProbe(recipients: .init(
        recipients: [.init(code: "709592", name: "행정망 PC")],
        selectedCode: "709592"
    ))
    let model = makeModel(probe: probe)
    await model.refresh()
    XCTAssertEqual(model.savedRecipients.first?.displayLabel, "행정망 PC · 709592")

    await model.selectRecipient(code: "709592")
    XCTAssertEqual(model.recipient, "709592")
    XCTAssertEqual(model.selectedRecipientCode, "709592")

    model.recipient = "123456"
    model.recipientDidChange()
    XCTAssertNil(model.selectedRecipientCode)

    model.recipient = "709592"
    await model.saveRecipient(name: "행정망 업무 PC")
    XCTAssertEqual(model.savedRecipients.first?.name, "행정망 업무 PC")
    await model.deleteRecipient(code: "709592")
    XCTAssertTrue(model.savedRecipients.isEmpty)
}
```

- [ ] **Step 2: Push test-only changes and verify red CI**

Expected: compilation fails because the view-model recipient API is not implemented.

- [ ] **Step 3: Add narrow dependencies and behavior**

Add four closure types to `TextTransferViewModel` and load shortcuts with draft/history before the network receive call, so saved shortcuts remain visible during a network error.

```swift
typealias LoadRecipients = @Sendable () async throws -> TextSavedRecipientState
typealias SaveRecipient = @Sendable (String, String) async throws -> TextSavedRecipientState
typealias SelectRecipient = @Sendable (String) async throws -> TextSavedRecipientState
typealias DeleteRecipient = @Sendable (String) async throws -> TextSavedRecipientState

@Published private(set) var savedRecipients: [TextSavedRecipient] = []
@Published private(set) var selectedRecipientCode: String?

func recipientDidChange() {
    if recipient != selectedRecipientCode { selectedRecipientCode = nil }
}
```

`saveRecipient(name:)` saves the current six-digit `recipient`, `selectRecipient(code:)` applies and persists the code and draft, and `deleteRecipient(code:)` removes only the shortcut. Map validation failures to specific Korean messages and Cocoa write errors to the existing storage category.

In `TextTransferDependencies`, create `TextSavedRecipientStore` at `TextMessages/saved-recipients.json` and pass its four methods. Create the same isolated store inside `ForegroundReceiveSimulation`.

- [ ] **Step 4: Run all tests and confirm no text-transfer regression**

Expected: view-model tests pass; draft, send, retry, receive polling, and unread-count tests remain green.

- [ ] **Step 5: Commit**

```powershell
git add App/Application/TextTransferDependencies.swift App/UI/TextTransferViewModel.swift App/Testing/ForegroundReceiveSimulation.swift Tests/TextTransferViewModelTests.swift
git commit -m "feat: manage saved recipients in text transfer"
```

---

### Task 3: Show named shortcuts and long-press history actions

**Files:**
- Create: `App/Text/TextMessageExport.swift`
- Modify: `App/UI/TextTransferView.swift`
- Modify: `App/UI/TextMessageDetailView.swift`
- Modify: `App/Testing/ForegroundReceiveSimulation.swift`
- Modify: `UITests/ForegroundReceiveUITests.swift`
- Create: `Tests/TextMessageExportTests.swift`

**Interfaces:**
- Consumes: Task 2 published recipient state and methods.
- Produces: `TextMessageExport.baseName(for:)` and `TextMessageExport.makeTemporaryFile(for:)` shared by detail and context-menu actions.

- [ ] **Step 1: Add failing export and UI tests**

Seed `행정망 PC · 709592` in the simulator fixture. Assert the label and code are visible, tapping applies `709592`, and long-pressing the seeded message reveals four actions while short tap still opens details.

```swift
func testTextRecipientShortcutAndHistoryContextMenu() {
    let app = launchIncomingApp(withTextMessage: true, withSavedTextRecipient: true)
    app.buttons["text-transfer-menu"].tap()

    let shortcut = app.buttons["text-saved-recipient-709592"]
    XCTAssertTrue(shortcut.waitForExistence(timeout: 10))
    XCTAssertTrue(shortcut.label.contains("행정망 PC"))
    XCTAssertTrue(shortcut.label.contains("709592"))
    shortcut.tap()
    XCTAssertEqual(app.textFields["text-recipient"].value as? String, "709592")

    let row = app.buttons["text-message-received-123e4567-e89b-42d3-a456-426614174333"]
    row.press(forDuration: 1.2)
    for title in ["전체 복사", "TXT로 저장", "공유", "삭제"] {
        XCTAssertTrue(app.buttons[title].waitForExistence(timeout: 3), "Missing \(title)")
    }
}
```

Add unit coverage proving the shared temporary file uses the existing filename and exact UTF-8 bytes.

- [ ] **Step 2: Push tests and verify red CI**

Expected: UI fixture parameter or accessibility identifiers are missing and the new export helper test fails to compile.

- [ ] **Step 3: Implement the saved-recipient rows**

Keep the current code field, add a trailing `저장` button, and show all saved items below it. Each row uses the exact label and a checkmark for the selected code.

```swift
ForEach(model.savedRecipients) { saved in
    Button {
        Task { await model.selectRecipient(code: saved.code) }
    } label: {
        HStack {
            Image(systemName: model.selectedRecipientCode == saved.code
                ? "checkmark.circle.fill" : "circle")
            Text(saved.name).font(.subheadline.bold())
            Spacer()
            Text(saved.code).font(.body.monospacedDigit())
        }
    }
    .contextMenu {
        Button("이름 변경") { beginRename(saved) }
        Button("삭제", role: .destructive) { pendingRecipientDeletion = saved }
    }
    .accessibilityIdentifier("text-saved-recipient-\(saved.code)")
}
```

Use an alert text field for initial naming/rename and a separate destructive confirmation alert for deletion.

- [ ] **Step 4: Implement shared record actions**

Move `TextExportDocument` and temporary-file naming/writing into `TextMessageExport.swift`. Apply a `.contextMenu` to each existing `NavigationLink` row:

```swift
.contextMenu {
    Button { copy(message) } label: { Label("전체 복사", systemImage: "doc.on.doc") }
    Button { beginExport(message) } label: { Label("TXT로 저장", systemImage: "doc.badge.arrow.up") }
    Button { beginShare(message) } label: { Label("공유", systemImage: "square.and.arrow.up") }
    Button(role: .destructive) { pendingMessageDeletion = message } label: {
        Label("삭제", systemImage: "trash")
    }
}
```

Use the parent view's `fileExporter`, a small `UIActivityViewController` representable, and the existing delete confirmation wording. Remove temporary share files after dismissal. Refactor `TextMessageDetailView` only enough to call the same export helper; retain every existing detail action and accessibility identifier.

- [ ] **Step 5: Run the complete simulator suite**

Run through CI:

```powershell
git push origin codex/foreground-receive-alert
gh run watch --repo hejong2byte/SimpleCameraAutoSender-iOS --exit-status
```

Expected: unit and UI tests pass, UI screenshots export, and unsigned IPA build succeeds.

- [ ] **Step 6: Commit**

```powershell
git add App/Text/TextMessageExport.swift App/UI/TextTransferView.swift App/UI/TextMessageDetailView.swift App/Testing/ForegroundReceiveSimulation.swift Tests/TextMessageExportTests.swift UITests/ForegroundReceiveUITests.swift
git commit -m "feat: add named text shortcuts and row actions"
```

---

### Task 4: Documentation, versioning, and SideStore release

**Files:**
- Modify: `docs/install.md`
- Modify: `project.yml`
- Modify: `Tests/ProjectSmokeTests.swift`
- Create: `docs/verification/2026-09-05-text-saved-recipients.md`

**Interfaces:**
- Consumes: complete tested feature from Tasks 1-3.
- Produces: version `0.3.13`, build `24`, release tag `v0.3.13`, IPA, and install QR.

- [ ] **Step 1: Document the exact user flow and data boundary**

Add concise instructions for saving/selecting/renaming/deleting up to five codes and using long-press history actions. State that shortcut deletion never deletes text records.

- [ ] **Step 2: Bump and test version assertions**

Set:

```yaml
CURRENT_PROJECT_VERSION: 24
MARKETING_VERSION: 0.3.13
```

Update smoke assertions to the same values, commit, push, and require green CI.

- [ ] **Step 3: Record verification without private receiver values**

The verification record includes test run URL, commit, file counts, version/build, bundle ID, IPA SHA-256, and data-isolation checks. It must not include actual saved codes, names, credentials, device IDs, message bodies, or server tokens.

- [ ] **Step 4: Tag and build the release**

```powershell
git tag v0.3.13
git push origin codex/foreground-receive-alert
git push origin v0.3.13
gh run watch --repo hejong2byte/SimpleCameraAutoSender-iOS --exit-status
```

Expected: Release SideStore IPA workflow passes tests, builds the unsigned IPA, validates QR generation, and publishes both assets.

- [ ] **Step 5: Download and independently verify desktop artifacts**

Download release assets to `C:\Users\user\Desktop\SimpleCamera-iPhone-0.3.13`, then verify:

```powershell
python scripts/verify-ipa.py 'C:\Users\user\Desktop\SimpleCamera-iPhone-0.3.13\SimpleCameraAutoSender.ipa'
Get-FileHash -Algorithm SHA256 'C:\Users\user\Desktop\SimpleCamera-iPhone-0.3.13\SimpleCameraAutoSender.ipa'
```

Also inspect `Info.plist` inside the IPA for bundle ID `com.hejong2byte.simplecameraautosender`, version `0.3.13`, build `24`; decode `install-qr.png` and confirm its payload exactly matches the permanent SideStore install URL; compare the GitHub release asset hash with the downloaded desktop file.

- [ ] **Step 6: Final commit and status check**

```powershell
git add docs/install.md project.yml Tests/ProjectSmokeTests.swift docs/verification/2026-09-05-text-saved-recipients.md
git commit -m "release: prepare SideStore 0.3.13"
git status --short --branch
```

Expected: branch and tag point to the verified release commit, the worktree is clean, and no operational/private data is tracked.
