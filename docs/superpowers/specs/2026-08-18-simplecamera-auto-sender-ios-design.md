# SimpleCamera Auto Sender for iOS — Design

## Goal

Build an iOS 17+ app that uploads every new photo created by **The Simple Camera** to the existing SimpleCamera Work Photo Relay without requiring the user to select photos or press a send button after each shoot.

The app is distributed as an unsigned IPA for SideStore. A stable QR code opens the latest GitHub Release IPA directly in SideStore.

## Confirmed user flow

1. Install the app from the SideStore QR code.
2. Open it once, grant full photo-library access, and save the existing relay upload credential.
3. Tap **Start automatic sending**. The app records a baseline so historical photos are not uploaded.
4. Create one personal automation on the iPhone:
   - Trigger: **The Simple Camera is closed**.
   - Action: the app-provided **Send New SimpleCamera Photos** App Intent.
   - Execution: **Run Immediately**.
5. Take any number of photos in The Simple Camera and leave the camera app.
6. The automation invokes the uploader. The uploader discovers all new matching photos, queues them for upload, and records only confirmed successes.

The app also exposes a **Send now** button as a recovery path. Normal use does not require opening the uploader.

## Platform constraint

iOS normally suspends apps soon after they enter the background. Photo-library changes are not a supported reason for continuous background execution, and scheduled background tasks do not have a guaranteed start time. The design therefore does not claim that a permanently resident process is possible.

The app-close personal automation is the deterministic trigger. It is intentionally limited to one app-provided action; all photo discovery, metadata inspection, deduplication, upload, and retry logic lives in native code.

## Considered approaches

### 1. App-close automation plus App Intent — selected

- Preserves The Simple Camera as the capture app.
- Requires only one simple personal automation.
- Can run without an execution confirmation.
- Native code owns the unreliable parts that previously existed in the shortcut.

### 2. Permanently resident background monitor — rejected

- iOS suspends ordinary background applications.
- Misusing audio or location background modes would drain battery, interfere with the device, and still would not provide a correctness guarantee.

### 3. Camera capture inside the uploader — rejected

- Would allow true capture-time upload.
- Violates the requirement to keep using The Simple Camera.

## Architecture

### SwiftUI application

The main screen provides:

- setup state and photo permission state;
- relay configuration, with the server URL prefilled;
- credential entry stored only in Keychain;
- automatic-sending baseline control;
- last scan and upload summary;
- pending and failed item counts;
- **Send now** and **Retry failed** controls;
- one-screen instructions for creating the personal automation.

The UI never displays the stored credential after it is saved.

### App Intent

`SendNewSimpleCameraPhotosIntent` is exposed to Shortcuts and personal automations. It does not require foreground UI. It starts a single-flight scan and upload enqueue operation, then returns a concise result count.

Concurrent invocations are coalesced so closing The Simple Camera repeatedly cannot queue duplicate work.

### Photo discovery

PhotoKit fetches image assets created after automatic sending was enabled, with a short look-back window to tolerate clock and save-order differences. A persistent ledger keyed by `PHAsset.localIdentifier` prevents duplicates and lets scans safely overlap.

On each trigger the scanner polls briefly for a stable set of new assets so a photo that is still being committed when The Simple Camera closes is not missed. Assets whose original data is temporarily unavailable remain pending for the next retry.

There is no app-defined maximum batch size.

### SimpleCamera identification

The app requests the original image resource and reads metadata with ImageIO before any upload. A photo qualifies only when the normalized TIFF `Software` field identifies **Simple Camera**. The currently observed value `Simple Camera 5.0.7` is accepted, and future version-number changes are accepted by matching the normalized `Simple Camera` product name rather than a fixed version.

Nonmatching photos are never uploaded. Their bytes are used only locally for metadata inspection.

### Upload queue

Each qualifying original resource is copied to an app-owned temporary file and queued through a background `URLSession` upload task.

Each request uses the existing relay contract:

- method: `POST`;
- endpoint: `/api/shortcut/photos`;
- body: original photo bytes;
- `Authorization`: credential loaded from Keychain;
- `Content-Type`: `application/octet-stream`.

HTTP success records the asset as uploaded and removes its temporary file. Network failure, timeout, app termination, or non-success HTTP status leaves the item pending or failed. Background URLSession retry behavior is used where applicable, and a later automation run retries remaining work.

### Persistent state

The app stores:

- monitoring baseline;
- per-asset state: discovered, ignored, queued, uploaded, or failed;
- retry count and last error category;
- background upload task mapping;
- recent aggregate status for the UI.

No relay credential is stored in this database. The credential lives only in Keychain.

## First-run and reset behavior

When automatic sending is enabled for the first time, the current time becomes the baseline. Existing historical SimpleCamera photos are not uploaded.

Resetting automatic sending requires an explicit confirmation. Reset clears the ledger and creates a new baseline; it does not delete photos from the Photos library or from the PC.

## Error behavior

- Missing or limited photo permission: the intent reports setup required and queues nothing.
- Missing credential: the intent reports setup required and queues nothing.
- No network: discovered matching photos stay pending.
- Authentication rejection: uploads stop, the app records an authentication error, and the credential is not logged.
- One corrupt or unreadable photo: that item fails without blocking other photos.
- Duplicate automation trigger: the existing scan continues; no duplicate upload is created.

Logs contain only asset counts, state transitions, HTTP status classes, and redacted error categories. They never contain credentials or authorization headers.

## SideStore distribution

Repository name: `simplecamera-auto-sender-ios` under GitHub account `hejong2-byte`.

GitHub Actions on a macOS runner will:

1. run unit tests on an iOS simulator;
2. build the application with code signing disabled;
3. package `Payload/SimpleCameraAutoSender.app` as `SimpleCameraAutoSender.ipa`;
4. attach the IPA to a GitHub Release;
5. validate that the release asset is downloadable;
6. generate a QR code for:

   `sidestore://install?url=https%3A%2F%2Fgithub.com%2Fhejong2-byte%2Fsimplecamera-auto-sender-ios%2Freleases%2Flatest%2Fdownload%2FSimpleCameraAutoSender.ipa`

The QR code is published in the README and as a release asset. The repository, IPA, workflow logs, and QR code contain no relay credential.

SideStore performs the device-specific signing and the user's normal seven-day refresh.

## Project configuration

- Product name: `SimpleCameraAutoSender`
- Display name: `SimpleCamera 업무사진 전송`
- Bundle identifier: `com.hejong2byte.simplecameraautosender`
- Minimum deployment target: iOS 17.0
- UI framework: SwiftUI
- Photo access: PhotoKit with full-library authorization
- Metadata: ImageIO
- Networking: background URLSession
- Automation surface: App Intents
- Project generation: XcodeGen, with the generated Xcode project also committed for direct builds

No paid Apple-only entitlement is required by the design.

## Testing and acceptance criteria

Automated tests cover:

- Simple Camera metadata matching across case and version changes;
- rejection of ordinary Camera, screenshots, and missing metadata;
- baseline and ledger deduplication;
- retry state transitions;
- request headers without exposing credential values;
- coalescing concurrent intent invocations;
- stable SideStore release URL and QR payload.

Device acceptance requires:

1. Enable automatic sending and configure the personal automation.
2. Take 1, then multiple, then a larger burst of photos in The Simple Camera.
3. Leave The Simple Camera after each batch.
4. Confirm every new SimpleCamera photo reaches the relay and then the PC receiver exactly once.
5. Create an ordinary Camera photo and a screenshot and confirm neither is uploaded.
6. Disable networking, take photos, leave The Simple Camera, restore networking, and confirm pending photos are eventually uploaded.
7. Scan the published QR code and confirm SideStore opens the install flow for the latest IPA.

Completion is not claimed until the GitHub Actions build succeeds and the device-side acceptance checklist is run on the user's iPhone.
