# Stored-file preview and PC receiver screen cleanup

## Approved scope

The user selected approach A. Files already saved on the iPhone gain a separate
open control, while the existing row selection remains dedicated to USB copy and
manual deletion. The redundant receiver-device and PC input-code card is removed
from the PC file receive screen because registration details remain available in
Settings.

This change is limited to the iPhone PC file receive interface. It does not alter
file discovery, downloads, server acknowledgements, automatic photo transfer,
USB copying, deletion rules, receiver registration, credentials, or stored
receive records.

## Stored-file row behavior

Each file row keeps its current selection control and file information. A
separate trailing `열기` control with an eye icon opens that one file. Tapping
`열기` must not select or deselect the row, start a USB copy, delete the file,
acknowledge a server item, or modify any receive result.

The open control presents the file using the native iOS Quick Look viewer:

- photos open as an image viewer;
- videos, PDFs, text and common office files use the system preview when iOS
  supports their type;
- closing the preview returns to the same file list and preserves selections;
- unsupported or unreadable files produce a visible `파일 열기 실패` message
  without changing the original file.

Only the local URL already returned by `IPhoneReceivedFileCatalog` is used. No
temporary copy, conversion, recompression, rename, upload, or metadata rewrite is
allowed.

## Validation and error handling

Before presenting Quick Look, the view model verifies that the selected URL still
exists as a regular readable file inside the app's received-file directory. This
handles a file that was removed between catalog refresh and tapping `열기`.

If validation fails, the view model clears the pending preview, refreshes the
stored-file catalog, and exposes a dedicated preview error. The receive-progress
state and USB-copy result remain unchanged. The error is shown as an alert and is
cleared only when the user dismisses it or a later open request succeeds.

Quick Look is read-only from this feature's perspective. The source remains in
place after dismissal, and the app does not infer deletion or transfer completion
from a preview action.

## PC file receive screen cleanup

Remove the complete top card that currently shows:

- `수신 기기`;
- the iPhone/device name;
- `PC 입력 코드` and its six-digit value;
- registration guidance or registration action displayed in that card.

Do not remove or change the registration model. Settings remains the single place
for viewing the device name and PC input code, registering, resetting, and
checking registration status. All remaining PC receive content moves upward in
normal SwiftUI layout; no empty placeholder or spacer replaces the removed card.

The main screen's existing PC file receive entry is outside this cleanup and
remains unchanged.

## Component changes

- `USBReceiverView` removes `identityCard`, gives each stored-file row separate
  selection and open actions, presents Quick Look, and displays preview errors.
- `USBReceiverViewModel` owns the pending preview URL and preview error so file
  validation and state transitions can be unit tested independently of Quick
  Look's system UI.
- `IPhoneReceivedFileCatalog` remains the source of stored-file URLs and performs
  its existing refresh. Its persistence and enumeration rules do not change.
- `SettingsView` remains unchanged because it already exposes the registered
  device and PC input code.

No new persistent database, bookmark, credential, or file index is introduced.

## Verification

Implementation follows test-driven development:

1. Add failing model tests proving that an existing catalog file becomes the
   preview target, a missing file is rejected and refreshes the list, and opening
   does not change selection.
2. Add a failing source contract test proving the receive screen no longer
   contains the receiver identity card and does contain distinct preview wiring.
3. Add or extend a UI test fixture to verify that a stored-file row exposes both
   selection and `열기` controls without changing the selected state. Quick Look
   rendering itself is a system component and is not used as the sole automated
   proof.
4. Run the focused failing tests, implement the minimum production changes, then
   run all logic and UI tests plus the iOS build.

Tests use temporary directories and synthetic files only. They must not read,
delete, rename, or modify files saved by the user on the physical iPhone.

## Success criteria

1. Any file shown under `iPhone에 저장된 파일` has a separate `열기` action.
2. A stored photo opens in the native image preview and returns to the unchanged
   list when closed.
3. Opening a file never changes USB-copy/delete selection or file contents.
4. Missing or unsupported files produce an understandable error and do not alter
   receive or USB state.
5. The PC file receive screen no longer displays the receiver-device/input-code
   card or the empty space it occupied.
6. Device registration and the PC input code remain accessible in Settings.
7. Existing receive, USB copy, manual deletion, automatic transfer and data
   integrity tests continue to pass.

## Limits

- The feature previews files already stored inside the app; it is not a general
  Files app browser or editor.
- Preview support depends on the file formats supported by the installed iOS
  version.
- This design does not add sharing, editing, renaming, decompression, or opening
  files in an arbitrary third-party app.
- Publishing a new IPA or SideStore QR is separate from implementing and
  verifying this change.
