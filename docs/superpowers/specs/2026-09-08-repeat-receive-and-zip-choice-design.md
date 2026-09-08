# Repeat incomplete PC reception and choose ZIP handling

## Approved intent

PC deliveries must remain visible until the app has downloaded, verified and
acknowledged them. Closing a prompt or leaving the app is postponement, not a
receive failure. The next transition from background to active, including a new
app launch, must offer every still-incomplete server delivery again.

For a batch containing ZIP files, archive handling is chosen before any storage
destination. The user confirmed that iPhone free space is sufficient and prefers
safe local staging over extracting directly on removable storage.

## Considered approaches

1. **Private iPhone staging, then verified USB copy (selected).** Download and
   verify the ZIP in app-private staging, safely extract it in another private
   temporary directory, copy the extracted tree to USB/SD and verify the copied
   files before removing temporary data. This uses more temporary iPhone space
   but avoids leaving an unverified partially extracted tree as a completed
   result.
2. Extract directly onto USB/SD. This uses less iPhone space but an unplugged or
   failed device can leave a mixture of partial and final files, so it is not
   selected.
3. Permanently save the ZIP in the user's iPhone received-files folder before
   exporting it. This creates an unnecessary extra retained copy and repeats the
   confusing storage choice, so it is not selected.

## Prompt flow

1. On every inactive-to-active transition, query the server immediately. Do not
   wait for the PC-file-receive screen to be opened.
2. If any available or leased delivery has not been acknowledged as safely
   stored, offer it again even when an earlier destination approval or resumable
   checkpoint exists. Suppress repeated pop-ups only during the same uninterrupted
   active session; the pending-files button can reopen the prompt during that
   session.
3. Freeze the displayed batch. A later arrival receives a separate decision and
   does not silently inherit the open batch's choices.
4. If the batch contains one or more `.zip` deliveries, first show
   **“압축을 해제하시겠습니까?”** with:
   - **압축 해제**: apply extraction to every ZIP in this frozen batch and use
     USB/SD as the final destination. Non-ZIP files in the same batch are copied
     normally to that USB/SD destination.
   - **ZIP 그대로 저장**: keep ZIP files intact, then show the normal iPhone or
     USB/SD destination choice for the whole batch.
   - **나중에 받기**: make no durable receive decision and leave every file on
     the server.
5. A non-ZIP batch goes directly to the iPhone or USB/SD destination choice.
6. Dismissing either dialog is equivalent to **나중에 받기**. It clears only
   transient UI state. It must not write an approval, start a lease, ACK a file,
   or publish a red receive-error result.

## Durable state and retry boundary

The current destination approval is written before a durable receive job exists,
and pending discovery filters every approved ID. This can hide a server file
after the user leaves the flow. In addition, the in-memory offered-ID set is not
reset when the app returns to active, so a postponed prompt can remain hidden.

Replace destination-only approval with a receiver-scoped receive decision that
contains both destination and ZIP handling. A decision authorizes a download but
does not mean completion. Server discovery must exclude only deliveries already
acknowledged/delivered, never merely decided deliveries. On activation, reset the
session-only offered and accepted sets so an incomplete delivery is offered
again. Existing v1 destination approvals have no explicit ZIP decision and are
treated as incomplete choices that must be asked again rather than silently
consumed.

Once a download has actually started, its checkpoint or local job remains the
resume source. Returning to the app shows the incomplete-delivery prompt again;
choosing the same or a new path atomically updates the decision before resuming.
A successful size/hash check followed by server ACK is the only terminal success.
Network, authentication, expiry, corrupt archive and storage errors remain real
errors and include a retry action when the server delivery still exists.

## ZIP extraction to USB/SD

For **압축 해제**, download the original ZIP to an app-private staging file and
verify its advertised byte size and SHA-256. Use the existing safe ZIP extractor
to reject traversal, links, malformed and encrypted archives. Extract into a
unique app-private temporary directory. Copy into a hidden unique partial folder
on the selected USB/SD, verify every output file's size and SHA-256, then rename
that folder to an available final name derived from the ZIP filename.

Only after the final USB/SD tree passes verification may the app ACK the server
delivery and remove the private ZIP and extracted temporary tree. On any failure,
remove only the partial USB/SD tree created by this attempt, keep resumable source
state where safe, and leave the server delivery unacknowledged. Never delete or
overwrite unrelated USB/SD contents.

## User-visible results

- Postponement: `수신 보류 · 앱을 다시 열면 다시 안내합니다.`
- Retryable incomplete reception: `수신하지 못한 파일이 있습니다.` with a
  visible `다시 받기` action.
- ZIP extraction progress distinguishes download, extraction, USB copy,
  verification and completion.
- A true expired/deleted server object says that it can no longer be downloaded;
  it is not described as a generic network error.

## Verification

Write failing tests before implementation and confirm the expected failures for:

- postponed prompts reappearing after inactive-to-active transition;
- destination-approved but unacknowledged files reappearing on the next launch;
- dismissing either ZIP or destination prompt producing no receive error;
- ZIP choice preceding destination and applying only to the frozen batch;
- ZIP-as-is retaining the archive and supporting both destinations;
- extraction using private staging and committing only a fully verified USB tree;
- interruption preserving a retryable server delivery and cleaning partial USB
  output;
- legacy approvals requiring a new explicit choice;
- multiple and mixed ZIP/non-ZIP deliveries.

Run the focused XCTest targets, all logic tests and UI tests in macOS CI. Build
version `0.3.16` (27), verify the IPA bundle version, ZIP integrity and SideStore
URI, then publish a new IPA and QR. Simulator and CI results do not prove the
physical iPhone 14 Pro, Lightning adapter and USB/SD combination; that final
hardware check remains explicit.
