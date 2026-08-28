# 0.3.4 (15) foreground receive verification

## Verified build

- Source commit: `622132654d5f2302e864cb681dbfbe45c8af8804`
- [Successful CI and test logs](https://github.com/hejong2-byte/simplecamera-auto-sender-ios/actions/runs/33131959088)
- Tests: **190 logic/integration tests + 3 UI tests, zero failures**.
- [SideStore release](https://github.com/hejong2-byte/simplecamera-auto-sender-ios/releases/tag/v0.3.4)
- Bundle: `com.hejong2byte.simplecameraautosender`; version `0.3.4`; build `15`; iPhoneOS; minimum iOS `17.0`.
- IPA size: `1692957` bytes. ZIP CRC and Files visibility keys passed.
- IPA SHA-256: `25cb91aabd2f127cce8c4cc2c94c0895eef864e319ba7531c87d09e5141e28e8`.
- The publicly downloaded `releases/latest/download/SimpleCameraAutoSender.ipa` returned HTTP 200 and matched that hash.
- The generated QR was independently decoded with ZXing and matched `install-url.txt`. QR SHA-256: `95af9ce2cd019829f803cb8d495923e6f4d9007db990434758d688ab8c55505b`.
- Simulator fixture launch flags are absent from the Release executable.

## Actual UI paths exercised

1. Main screen receives an arrival dialog; postponing retains a pending button; reopening and choosing iPhone routes to the receiver.
2. While Settings is visible, an arrival dialog appears and the iPhone choice routes to the receiver.
3. USB choice opens the real system folder picker; cancelling opens the fallback choice; choosing iPhone changes the visible destination correctly.

UI tests use synthetic metadata, isolated in-memory registration and a temporary directory. They do not connect to the production relay or use real user files.

## Data and concurrency checks

- Discovery never leases/downloads an unapproved delivery, including startup restoration with an empty job history.
- Ten approved files are handled sequentially by the real local engine; an eleventh unapproved file is not scheduled or acknowledged.
- Explicit destination choices are persistent and receiver-scoped. A corrupt store or failed write does not grant a download approval.
- A displayed batch cannot acquire later arrivals, including the USB-to-iPhone fallback dialog.
- Overlapping local discovery and USB receive calls cannot start a second run.
- Postponed files remain reachable; offline checks do not erase the last known pending list; stale responses after backgrounding are ignored.
- A completed local receive refreshes saved files; selecting a valid USB folder releases server-wait; paused USB progress does not masquerade as an active operation.

## Reproduced and fixed defects

- Missing root-level arrival monitoring and explicit approval boundary.
- Re-entrant local/USB receive runs while the first request awaited the server.
- Fallback confirmation silently changing its file set on the next poll.
- Destination picker display changing without changing previously approved file destinations.
- USB-to-iPhone fallback leaving the screen labelled as USB storage.

## Limits and rollout

- This is a **foreground arrival dialog**, not closed-app APNs/web push.
- Existing iPhone background downloads remain subject to iOS scheduling; force-quitting can cancel them.
- Direct USB receiving and copying still require the receiver screen in the foreground.
- No physical iPhone 14 Pro, Lightning adapter or USB media was attached to this test environment. Actual USB write/power behavior must be checked on the device.
- No Worker deployment, production queue change, photo selection rule change or user-file deletion was performed.
- Update the existing SideStore app; do not uninstall it if local files must be preserved.
