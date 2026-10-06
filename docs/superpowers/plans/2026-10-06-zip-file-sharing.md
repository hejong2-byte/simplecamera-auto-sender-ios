# Received ZIP Sharing Plan

**Approved scope:** Extend the existing received photo/PDF sharing feature to ZIP archives. Reuse the existing original-URL iOS share sheet; do not extract, repackage, move, delete, or send the archive automatically. No new screens, settings, SDKs, or Windows changes.

**Execution:** This is one tightly coupled extension, implemented inline in the existing isolated `codex/received-file-sharing` worktree. The user's explicit ZIP request approves this existing design extension; no additional design choice is needed.

## Verification steps

- [x] RED: Extend the supported-type unit test to lower/upper-case ZIP; retain unsupported-file coverage. Test archive bytes, filename, selection, and catalog preservation after cancellation. Add an opt-in real ZIP simulator fixture and native share/cancel UI test. Run the focused macOS workflow against unchanged production sharing code.
- [x] GREEN: Add ZIP to the existing UTType filter only. Keep original-URL sharing and all existing concurrency/file-validation guards. Run the complete native test suite, including photos/PDFs and ZIP.
- [x] Release: Set iOS version 0.3.47/build 58 and matching smoke-test/documentation expectations. Publish through the existing tested SideStore release workflow; verify IPA identity/version/CRC/hash, latest download target, QR payload, and share-sheet screenshots.

## Verification boundary

The simulator verifies the ZIP share sheet and preserved local originals, not actual KakaoTalk conversation delivery. KakaoTalk's installed sharing extension controls whether it accepts a particular archive. No user data or messages will be sent during tests.

## Baseline

Tracked working tree clean at `10ce561`; existing release-artifact directories preserved. Local SideStore install-contract and QR-URI checks pass. Native Swift/iOS execution requires the existing macOS Actions environment because this host is Windows.

## RED evidence

Run [37393925412](https://github.com/hejong2-byte/simplecamera-auto-sender-ios/actions/runs/37393925412) at `3f4c138` built successfully. ZIP eligibility failed for both `.zip` and `.ZIP`, the ZIP sharing snapshot was nil, and the ZIP UI test failed at the missing share-button assertion. The other nine sharing unit tests, 16 deletion tests, and 20 project smoke tests passed. The existing photo/PDF UI test hit a simulator launch/background-assertion failure before its sharing assertions; it must pass in full GREEN verification too.

Implementation extends the existing UTType filter with `.zip` and does not change the share-sheet URL, receiver state machine, ZIP extraction, or USB copy paths. iOS-only release version is 0.3.47/build 58.

## GREEN evidence

Release run [37394652812](https://github.com/hejong2-byte/simplecamera-auto-sender-ios/actions/runs/37394652812) at `db85b364f54f947817ff30bb69588ac26179633f` passed all 488 unit tests and 29 UI tests, including ZIP sharing/cancellation and existing photo/PDF sharing. The IPA build and publication also succeeded (21m02s).

Inspected the ZIP UI screenshots exported from that run: the native share header displays `받은 자료` as a 157-byte `ZIP Archive`; closing it returns to the original `받은 자료.zip` row with selection retained and its share action available. These are synthetic fixtures, not user files. Screenshot evidence is under `release-v0.3.47-verify/release-ui/`.

## Published artifact verification

- [v0.3.47](https://github.com/hejong2-byte/simplecamera-auto-sender-ios/releases/tag/v0.3.47) published 2026-10-06 at 00:54:46 UTC.
- Downloaded canonical IPA, legacy alias, and the QR's fresh `releases/latest` target. All contain version `0.3.47`, build `58`, bundle ID `com.hejong2byte.simplecameraautosender`.
- All three IPA copies match the release API SHA-256: `62d050b40461a27516317ef6458b4f4f587d5d1c19f02fd9a8533a3bd21780ad`. Canonical IPA ZIP CRC and Files visibility checks pass.
- Published QR SHA-256: `5dd07fed72388309ef0b8e3d505af216d8a5199a6235b9c7312796e323d8b568`. Pixels match a newly generated QR for the validated canonical SideStore install URI.
- GitHub CLI and PowerShell artifact downloads initially hit transport timeouts/resets. An IPv4 HTTPS curl download succeeded for all assets and the latest target, without changing system settings or disabling certificate checks. The underlying transient network cause was not established.
- Originals/settings were not deleted; no user file or KakaoTalk message was sent. Actual KakaoTalk conversation delivery and its device-side attachment limits remain outside simulator verification.
