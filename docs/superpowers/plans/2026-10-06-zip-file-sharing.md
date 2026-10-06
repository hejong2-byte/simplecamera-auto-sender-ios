# Received ZIP Sharing Plan

**Approved scope:** Extend the existing received photo/PDF sharing feature to ZIP archives. Reuse the existing original-URL iOS share sheet; do not extract, repackage, move, delete, or send the archive automatically. No new screens, settings, SDKs, or Windows changes.

**Execution:** This is one tightly coupled extension, implemented inline in the existing isolated `codex/received-file-sharing` worktree. The user's explicit ZIP request approves this existing design extension; no additional design choice is needed.

## Verification steps

- [x] RED: Extend the supported-type unit test to lower/upper-case ZIP; retain unsupported-file coverage. Test archive bytes, filename, selection, and catalog preservation after cancellation. Add an opt-in real ZIP simulator fixture and native share/cancel UI test. Run the focused macOS workflow against unchanged production sharing code.
- [ ] GREEN: Add ZIP to the existing UTType filter only. Keep original-URL sharing and all existing concurrency/file-validation guards. Run the complete native test suite, including photos/PDFs and ZIP.
- [ ] Release: Set iOS version 0.3.47/build 58 and matching smoke-test/documentation expectations. Publish through the existing tested SideStore release workflow; verify IPA identity/version/CRC/hash, latest download target, QR payload, and share-sheet screenshots.

## Verification boundary

The simulator verifies the ZIP share sheet and preserved local originals, not actual KakaoTalk conversation delivery. KakaoTalk's installed sharing extension controls whether it accepts a particular archive. No user data or messages will be sent during tests.

## Baseline

Tracked working tree clean at `10ce561`; existing release-artifact directories preserved. Local SideStore install-contract and QR-URI checks pass. Native Swift/iOS execution requires the existing macOS Actions environment because this host is Windows.

## RED evidence

Run [37393925412](https://github.com/hejong2-byte/simplecamera-auto-sender-ios/actions/runs/37393925412) at `3f4c138` built successfully. ZIP eligibility failed for both `.zip` and `.ZIP`, the ZIP sharing snapshot was nil, and the ZIP UI test failed at the missing share-button assertion. The other nine sharing unit tests, 16 deletion tests, and 20 project smoke tests passed. The existing photo/PDF UI test hit a simulator launch/background-assertion failure before its sharing assertions; it must pass in full GREEN verification too.

Implementation extends the existing UTType filter with `.zip` and does not change the share-sheet URL, receiver state machine, ZIP extraction, or USB copy paths. iOS-only release version prepared as 0.3.47/build 58; full native verification and published-artifact checks are pending.
