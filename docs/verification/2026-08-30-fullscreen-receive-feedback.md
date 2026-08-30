# 0.3.5 (16) stored-file restoration and receive-feedback verification

## Verified build

- Source commit: `e1166e5ae277bf8a7848afc44bdd78064d8ae154`.
- [Successful CI and test logs](https://github.com/hejong2-byte/simplecamera-auto-sender-ios/actions/runs/33286561327).
- Tests: **206 logic/integration tests + 6 UI tests, zero failures**.
- [SideStore release](https://github.com/hejong2-byte/simplecamera-auto-sender-ios/releases/tag/v0.3.5).
- Bundle: `com.hejong2byte.simplecameraautosender`; version `0.3.5`; build `16`; iPhoneOS; minimum iOS `17.0`.
- IPA size: `1715087` bytes. ZIP integrity and Files visibility keys passed.
- IPA SHA-256: `31fd05160d1946dc134d946be750a183dedb8d837955d7dfaece621ed7598fe7`.
- The anonymously downloaded `releases/latest/download/SimpleCameraAutoSender.ipa` matched the CI artifact byte-for-byte by size and SHA-256.
- The public release QR matched the local QR by SHA-256 (`95af9ce2cd019829f803cb8d495923e6f4d9007db990434758d688ab8c55505b`). ZXing independently decoded it to the exact URI in `install-url.txt`.
- Simulator fixture launch flags are absent from the Release executable.

## Stored-file restoration regression

- The failing regression was reproduced in [CI run 33285840206](https://github.com/hejong2-byte/simplecamera-auto-sender-ios/actions/runs/33285840206): a saved local file disappeared from the displayed list when server feature refresh failed during relaunch.
- Root cause: `USBReceiverViewModel.refresh()` requested server features before scanning the app's local receive directory. A network error exited the refresh path before the local scan.
- Fix: bookmark restoration and the local stored-file catalog now load before any server feature refresh. Server errors remain visible, but cannot hide locally saved files.
- The focused regression and full suite passed in [CI run 33286091826](https://github.com/hejong2-byte/simplecamera-auto-sender-ios/actions/runs/33286091826).
- The final release CI repeated the complete test and packaging checks successfully.

## UI and status paths exercised

1. The main screen fits its primary actions without the previous black launch bars or initial unnecessary scroll.
2. Waiting, active receive progress, iPhone-save completion and server-error states use one shared status model on the main and receiver screens.
3. The last terminal receive result is stored atomically per receiver and restored after relaunch.
4. Arrival choice, iPhone destination, USB picker cancellation and USB-to-iPhone fallback paths were exercised by UI tests.
5. Locally stored files are listed immediately after relaunch even when the relay is unavailable, so they remain selectable for later USB copying.

## Limits and rollout

- This release does not add receiver-code history; that request was cancelled.
- This is a foreground arrival dialog, not closed-app APNs/web push.
- No physical iPhone 14 Pro, Lightning adapter or USB media was attached to this test environment. Actual USB write and adapter power behavior still require a device check.
- No production Worker deployment, queue mutation or user-file deletion was performed.
- Update the existing SideStore app. Do not uninstall it when existing iPhone-stored files must be preserved.
