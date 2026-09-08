# SD/USB management, priority reception and stored ZIP export

## Approved intent

The Settings screen must expose removable-storage management as its own menu so
the user can select an SD/USB destination, inspect it and clear its contents
without entering the PC receive workflow. When two or more PC deliveries are
waiting, the user must be able to choose one or more files to receive first.
ZIP files already stored on the iPhone must offer a choice between extraction
and copying the original archive when later exported to SD/USB.

These changes preserve the existing safety boundary: no server file is leased
until the user approves it, no iPhone original is deleted automatically, and no
unrelated SD/USB item is modified outside the selected destination.

## Considered approaches

1. **Selection sheet plus dedicated storage menu (selected).** Present a
   checkbox list for two or more pending deliveries, approve only the chosen
   IDs, and move the removable-storage controls to a focused Settings child
   screen. This supports both one-file priority and small batches without a
   server-protocol change.
2. Put a **receive first** button on every pending row. This is simpler but
   forces one-at-a-time decisions and is cumbersome when several related files
   should share one destination.
3. Add drag-and-drop queue reordering. This exposes ordering rather than the
   actual approval boundary, adds unnecessary state, and remains ambiguous for
   mixed ZIP and non-ZIP files.

For stored ZIP export, one batch-level choice applies only to selected ZIP
files. Non-ZIP files in the same selection are always copied unchanged. A
per-ZIP choice was rejected because it would produce repeated dialogs and a
more error-prone workflow.

## SD/USB storage-management menu

Add **SD/USB 저장장치 관리** as a separate row on the Settings screen. Its child
screen shows the selected destination name and filesystem description, offers
**폴더 선택/다시 선택** and **선택 해제**, and contains the destructive
**선택한 저장장치 내용 전체 삭제** action.

The existing `USBFolderCleanupService` remains the only deletion engine. Before
confirmation it recursively counts regular files, hidden items and nested
folders and calculates their total byte size. The confirmation displays the
selected destination name, file count, folder count and total size. The delete
operation removes the selected folder's contents but preserves the selected
folder itself. To empty an entire card, the user must select the card's root in
the iOS document picker.

The action is available whenever the app is open except during a receive,
export or another deletion. A stale bookmark, disconnected/replaced volume, or
any content change between inspection and confirmation aborts deletion and
shows a specific error. The feature never formats the device, changes its
filesystem, deletes iPhone originals, or follows a different destination after
confirmation.

The PC receive settings card retains registration, cellular policy and a compact
summary/link to storage management. Duplicate folder-selection and deletion
controls are removed from that card so the destructive operation has one clear
home.

## Pending-delivery selection and priority

One pending delivery keeps the current direct archive/destination prompt. Two
or more deliveries open a selection sheet before any receive decision. Each row
shows filename, byte size, arrival time and server expiration time. Selection
starts empty; the primary **선택 파일 먼저 받기** button remains disabled until
at least one current delivery is checked. **전체 선택** and **선택 해제** are
provided in the sheet.

Submitting the sheet freezes only the selected IDs into the existing receive
prompt. If the selection contains ZIP files, archive handling is asked first;
otherwise destination handling is asked immediately. Choosing extraction sends
the selected batch to SD/USB, extracts selected ZIP files and copies selected
non-ZIP files unchanged. Choosing ZIP-as-is continues to the normal iPhone or
SD/USB destination choice.

Only the selected delivery IDs are written to `IPhoneReceiveApprovalStore`.
Unselected deliveries remain unleased and visible in the pending list. The
existing receive engines continue to process approved files one at a time; if
several are selected, they use the current stable oldest-first order. Selecting
one file therefore guarantees that file is approved ahead of every unselected
file.

The displayed candidate set is frozen while the sheet is open. New arrivals do
not become selected automatically. A delivery that disappears or completes
elsewhere is removed from the list and selection on refresh. If no selected
delivery remains, submission is disabled and nothing is approved. Closing the
sheet is postponement, not an error, and all unapproved files remain on the
server.

No relay API or Windows sender change is required because the existing approval
store and receiver clients already filter downloads by exact delivery ID.

## Stored ZIP export choice

When **선택 파일 USB로 복사** includes one or more `.zip` files, show a
confirmation dialog with:

- **압축 해제해서 복사**: safely extract every selected ZIP in app-private
  temporary storage, copy and verify its extracted tree on SD/USB, then remove
  only the temporary extraction data.
- **ZIP 그대로 복사**: copy and verify the original ZIP file as an ordinary
  file.
- **취소**: perform no copy and keep the selection.

Non-ZIP files in the same selection are copied unchanged for either ZIP option.
The existing `SafeZIPExtractor` traversal, symlink, encryption and corruption
checks remain mandatory. The SD/USB partial path is committed only after size
and SHA-256 verification. Failures clean only this attempt's temporary/partial
data and preserve the iPhone source.

Successful export never deletes the iPhone source automatically. The existing
verified **원본 유지/삭제** decision remains available after export. Filename
collisions continue to use an available non-overwriting name.

## User-visible status and error handling

- Pending selection always reports the number selected and the combined size.
- Download and export continue to show filename, per-file position, bytes and
  percentage through the existing progress model.
- Storage deletion reports inspection, deletion, success and exact failure
  states on the dedicated screen.
- Offline, expired, authorization, unsafe ZIP, insufficient storage and removed
  destination errors remain distinct and never turn an incomplete server file
  into a completed one.

## Verification

Write failing tests first and confirm their expected failures for:

- the Settings row and dedicated storage-management screen;
- deletion confirmation content and transfer-time disabling;
- a two-file arrival presenting an empty selection instead of approving both;
- approving only selected IDs while unselected IDs remain pending;
- new or disappeared deliveries not corrupting the frozen selection;
- a single pending file retaining the existing direct prompt;
- stored ZIP export in extract and keep-archive modes;
- mixed ZIP/non-ZIP export applying the mode only to ZIP files;
- failed extraction/copy preserving the original and cleaning temporary output.

Run focused unit tests, the complete logic test suite, UI simulations and the
iOS build. This feature build increments the app to `0.3.17` (28). Verify the
generated IPA metadata, ZIP integrity and SideStore install URI before any
release claim. Simulator and CI checks do not replace a final iPhone 14 Pro and
physical SD/USB adapter test.
