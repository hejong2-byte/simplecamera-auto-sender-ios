# Resolution and iPhone Marker Detection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the 0-photo result by selecting only new 6048×8064 images whose original camera metadata contains no `iPhone` marker.

**Architecture:** Keep the existing App Intent, PhotoKit scan, ledger, and background uploader. Replace the Software-name matcher with a pure dimension-and-model classifier and make PhotoKit inspect the true original resource first.

**Tech Stack:** Swift 5, PhotoKit, ImageIO, XCTest, XcodeGen, GitHub Actions, SideStore unsigned IPA.

## Global Constraints

- Deployment target remains iOS 17.0.
- Bundle identifier remains `com.hejong2byte.simplecameraautosender`.
- Existing `Simple Cam이 닫힐 때` automation remains unchanged.
- Only 6048×8064 or 8064×6048 originals without an `iPhone` camera/lens marker are eligible.
- Program names, TIFF Software, filename, location, and capture settings are ignored.
- Do not merge or cherry-pick `codex/all-new-photo-sender`.
- Relay, credential, ledger, and upload behavior remain unchanged.

---

### Task 1: Replace the name matcher with the approved two-value classifier

**Files:**
- Modify: `Tests/SimpleCameraMetadataMatcherTests.swift`
- Modify: `App/Photos/SimpleCameraMetadataMatcher.swift`

**Interfaces:**
- Produces: `SimpleCameraPhotoProperties(pixelWidth:pixelHeight:cameraModel:lensModel:)`.
- Produces: `SimpleCameraMetadataMatcher.matches(properties:) -> Bool`.
- Preserves: `SimpleCameraMetadataMatching.matches(fileURL:) -> Bool` used by `PhotoSyncService`.

- [ ] **Step 1: Write failing classifier tests**

```swift
import XCTest
@testable import SimpleCameraAutoSender

final class SimpleCameraMetadataMatcherTests: XCTestCase {
    private let matcher = SimpleCameraMetadataMatcher()

    func testAcceptsTargetResolutionWithoutIPhoneMarker() {
        XCTAssertTrue(matcher.matches(properties: fixture()))
        XCTAssertTrue(matcher.matches(properties: fixture(width: 8064, height: 6048)))
    }

    func testRejectsIPhoneCameraModelAtSameResolution() {
        XCTAssertFalse(matcher.matches(properties: fixture(cameraModel: "Apple iPhone 14")))
    }

    func testRejectsIPhoneLensModelAtSameResolutionIgnoringCase() {
        XCTAssertFalse(matcher.matches(properties: fixture(lensModel: "IPHONE 14 back camera")))
    }

    func testRejectsWrongResolution() {
        XCTAssertFalse(matcher.matches(properties: fixture(width: 4032, height: 3024)))
    }

    func testRejectsUnreadableFile() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        XCTAssertFalse(matcher.matches(fileURL: url))
    }

    private func fixture(
        width: Int = 6048,
        height: Int = 8064,
        cameraModel: String? = nil,
        lensModel: String? = nil
    ) -> SimpleCameraPhotoProperties {
        .init(
            pixelWidth: width,
            pixelHeight: height,
            cameraModel: cameraModel,
            lensModel: lensModel
        )
    }
}
```

- [ ] **Step 2: Commit and push tests only; verify RED in macOS CI**

```bash
git add Tests/SimpleCameraMetadataMatcherTests.swift
git commit -m "test: reproduce Simple Cam resolution detection"
git push -u origin codex/fix-simplecam-detection-v014
gh run watch --repo hejong2-byte/simplecamera-auto-sender-ios --exit-status
```

Expected: compile failure because `SimpleCameraPhotoProperties` and `matches(properties:)` do not exist.

- [ ] **Step 3: Implement minimal ImageIO extraction and classification**

```swift
import Foundation
import ImageIO

protocol SimpleCameraMetadataMatching: Sendable {
    func matches(fileURL: URL) -> Bool
}

struct SimpleCameraPhotoProperties: Sendable, Equatable {
    let pixelWidth: Int
    let pixelHeight: Int
    let cameraModel: String?
    let lensModel: String?
}

struct SimpleCameraMetadataMatcher: SimpleCameraMetadataMatching {
    func matches(fileURL: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let values = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = (values[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (values[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else {
            return false
        }
        let tiff = values[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = values[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        return matches(properties: .init(
            pixelWidth: width,
            pixelHeight: height,
            cameraModel: tiff[kCGImagePropertyTIFFModel] as? String,
            lensModel: exif[kCGImagePropertyExifLensModel] as? String
        ))
    }

    func matches(properties: SimpleCameraPhotoProperties) -> Bool {
        let targetResolution =
            (properties.pixelWidth == 6048 && properties.pixelHeight == 8064)
            || (properties.pixelWidth == 8064 && properties.pixelHeight == 6048)
        guard targetResolution else { return false }
        return !containsIPhone(properties.cameraModel)
            && !containsIPhone(properties.lensModel)
    }

    private func containsIPhone(_ value: String?) -> Bool {
        value?.localizedCaseInsensitiveContains("iphone") == true
    }
}
```

- [ ] **Step 4: Commit, push, and verify GREEN**

```bash
git add App/Photos/SimpleCameraMetadataMatcher.swift
git commit -m "fix: identify Simple Cam photos by dimensions"
git push
gh run watch --repo hejong2-byte/simplecamera-auto-sender-ios --exit-status
```

Expected: matcher tests, full iOS tests, and unsigned IPA smoke build pass.

---

### Task 2: Inspect the original PhotoKit resource

**Files:**
- Create: `Tests/PhotoAssetSourceTests.swift`
- Modify: `App/Photos/PhotoAssetSource.swift`

**Interfaces:**
- Produces: `PhotoAssetResourceSelection.preferredType(in:) -> PHAssetResourceType?`.

- [ ] **Step 1: Add failing priority tests**

```swift
import Photos
import XCTest
@testable import SimpleCameraAutoSender

final class PhotoAssetSourceTests: XCTestCase {
    func testPrefersOriginalPhoto() {
        XCTAssertEqual(
            PhotoAssetResourceSelection.preferredType(in: [.fullSizePhoto, .photo]),
            .photo
        )
    }

    func testFallsBackToFullSizePhoto() {
        XCTAssertEqual(
            PhotoAssetResourceSelection.preferredType(in: [.fullSizePhoto]),
            .fullSizePhoto
        )
    }
}
```

- [ ] **Step 2: Commit and push tests only; verify RED**

```bash
git add Tests/PhotoAssetSourceTests.swift
git commit -m "test: require original PhotoKit metadata"
git push
gh run watch --repo hejong2-byte/simplecamera-auto-sender-ios --exit-status
```

Expected: compile failure because `PhotoAssetResourceSelection` does not exist.

- [ ] **Step 3: Add selector and use it in `exportOriginal`**

```swift
enum PhotoAssetResourceSelection {
    static func preferredType(
        in types: [PHAssetResourceType]
    ) -> PHAssetResourceType? {
        if types.contains(.photo) { return .photo }
        if types.contains(.fullSizePhoto) { return .fullSizePhoto }
        return nil
    }
}
```

Select `resources.first(where: { $0.type == preferredType })` after calling the helper.

- [ ] **Step 4: Commit, push, and verify GREEN**

```bash
git add App/Photos/PhotoAssetSource.swift
git commit -m "fix: read original photo metadata"
git push
gh run watch --repo hejong2-byte/simplecamera-auto-sender-ios --exit-status
```

Expected: focused tests and full CI pass.

---

### Task 3: Document the rule and prepare v0.1.4

**Files:**
- Modify: `README.md`
- Modify: `project.yml`

- [ ] **Step 1: Replace the Software-name README bullet**

```markdown
- 새 사진의 원본 해상도가 `6048×8064`인지 확인합니다(회전 포함).
- 카메라·렌즈 모델 정보에 `iPhone`이 있는 기본 카메라 사진은 제외합니다.
- 앱 표시 이름이나 `Software` 메타데이터는 판별에 사용하지 않습니다.
```

- [ ] **Step 2: Set release version**

```yaml
CURRENT_PROJECT_VERSION: 2
MARKETING_VERSION: 0.1.4
```

- [ ] **Step 3: Verify and commit**

```bash
python scripts/generate-install-qr.py --check
git diff --check
git add README.md project.yml
git commit -m "build: prepare Simple Cam sender v0.1.4"
git push
gh run watch --repo hejong2-byte/simplecamera-auto-sender-ios --exit-status
```

Expected: SideStore URI is valid and CI passes tests plus IPA build.

---

### Task 4: Audit, release, and verify SideStore QR

- [ ] **Step 1: Confirm the diff contains no all-photo code**

```bash
git diff --stat main...HEAD
git diff main...HEAD -- App Tests project.yml README.md
rg -n "allPhotos|all-photo|PhotoLibraryMonitor" App Tests || true
```

Expected: only matcher, resource selection, focused tests, README, and version changes exist; the search returns nothing.

- [ ] **Step 2: Fast-forward main and verify main CI**

```bash
git checkout main
git merge --ff-only codex/fix-simplecam-detection-v014
git push origin main
gh run watch --repo hejong2-byte/simplecamera-auto-sender-ios --exit-status
```

- [ ] **Step 3: Publish v0.1.4**

```bash
git tag -a v0.1.4 -m "Simple Cam resolution detection v0.1.4"
git push origin v0.1.4
gh run watch --repo hejong2-byte/simplecamera-auto-sender-ios --exit-status
```

- [ ] **Step 4: Download and verify assets**

```bash
gh release view v0.1.4 --repo hejong2-byte/simplecamera-auto-sender-ios --json assets,tagName,url
gh release download v0.1.4 --repo hejong2-byte/simplecamera-auto-sender-ios --dir dist/v0.1.4 --clobber
python scripts/generate-install-qr.py --check
```

Verify GitHub's IPA digest, `unzip -t`, and nonempty `install-qr.png`.

- [ ] **Step 5: Device acceptance**

Install with the QR, keep the existing automation, take one new target-resolution Simple Cam photo and one iPhone Camera photo, then close Simple Cam. Only the photo without the `iPhone` marker must queue and reach the PC.

