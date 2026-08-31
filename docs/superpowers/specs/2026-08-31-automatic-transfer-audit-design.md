# Automatic transfer audit and local-file deletion

## Approved scope and sequence

The user requested a full automatic-transfer audit and fixes, followed by manual
deletion of iPhone-stored files and removal of the “안전한 저장 방식” information
card. Proceed inline under the user's instruction to implement without repeated
questions. Do not create a new task, change the Windows receiver, or reset data.

## Automatic-transfer findings and design

1. Candidate preparation currently uses unfiltered library counts as transfer
   counts. Keep classification counts separate from confirmed matching files.
   A run with no eligible new files must say so, not “0장 전송 완료”.
2. Early exit after a quiet scan leaves rejected candidates unclassified in the
   ledger and can abandon another original whose metadata is still unavailable.
   Permanently reject only readable, nonmatching originals. Keep unreadable
   originals retryable and do not abandon known pending work after one success.
3. An interrupted direct upload leaves a queued record that every later run
   skips. A new, coalesced run may retry this orphan. An explicit retry must not
   sweep unrelated new library files.
4. A later scan error overwrites confirmed successes with zero. Preserve actual
   file outcomes on run interruption; do not invent a failed photo for a
   run-level error. Treat cancellation as interruption, not a network failure.
5. Removing an export file after a confirmed HTTP success must not turn that
   upload into failure.
6. Manual media progress and PC file receipt must remain separate from automatic
   photo progress. Verify their isolation, sequential uploads, concurrent
   invocation coalescing, and exactly-once ledger completion.

Retain the exact rule: 6048 x 8064 or 8064 x 6048, and no case-insensitive iPhone
marker in TIFF camera model or EXIF lens model. Keep the existing Shortcut type
and title, the saved baseline, credentials, and all user data.

## Local-file deletion

Reuse the existing multi-selection rather than add a new screen or hidden
swipe-only action. The alternatives require extra navigation or obscure batch
deletion. “선택 파일 삭제” opens a confirmation naming the selected files and
warning that only the iPhone copies will be permanently deleted.

Delete only the selection captured when confirmation opens. Revalidate every
file against the received-folder catalog and its size/modification identity;
reject directories, symlinks, out-of-folder paths, and changed files. Keep
unselected files, staging downloads, USB files, and transfer records intact.
Show actual successful and failed deletion counts and refresh the list
immediately, including partial failures. Disable deletion while receipt, USB
export, or another deletion is active. Cancel performs no filesystem mutation.

Remove the information card, not size/SHA-256 verification or the existing
post-USB-copy deletion confirmation.

## Verification and release

Run deterministic XCTest regressions against isolated temporary ledgers/files;
observe failures before fixes. Then run the entire iOS unit/integration/UI suite
on the macOS CI simulator and build a new unsigned SideStore IPA. Validate
bundle ID, version, archive contents, and SHA-256 after download and Desktop copy.
Do not claim physical iPhone/USB testing or production-PC arrival verification.
