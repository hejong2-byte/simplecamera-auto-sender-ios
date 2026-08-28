# Foreground PC file arrival and storage choice

## Approved scope

The user approved an in-app arrival prompt, then requested simulation, additional
bug fixes and a new IPA. This is foreground notification, not APNs or a promise
of alerts while the sender app is closed. No production file is used in tests.

## Behavior

- A single monitor owned by the root screen queries the existing authenticated
  delivery list while the app is active, including the main and settings screens.
- Check immediately on activation, then one second after each completed query.
  Never overlap requests or describe this as a guaranteed one-second delivery.
- Display an arrival prompt with count, filenames and total size, offering
  iPhone storage, USB storage, or postponement. Only available/leased items count;
  acknowledging/deleted items do not count as new files.
- Freeze the displayed batch. Files arriving while it is open need their own
  choice; they must not silently inherit the previous batch's destination.
- Keep postponed files accessible using a pending-files button. Do not repeatedly
  pop the same batch on each poll. A server error must not erase the last known
  pending count or be treated as an empty inbox.
- Ignore late responses after backgrounding; immediately check again on return.
- Selecting a destination navigates to PC file reception. Missing USB retains
  the files and uses the existing folder-selection/local-fallback flow.
- Do not download new files until their IDs and destination are durably approved.
  Both automatic engine restoration and receive-screen polling use filtered
  clients. Existing started jobs/checkpoints are resumable after updating.
- USB fallback applies only to the previously approved batch, never unrelated
  waiting files. Selecting a valid USB folder releases a prior server-wait state.
- Preserve original files and size/SHA verification. No changes to photo upload,
  receiver registration codes, bookmark paths, or server protocol.

## Structure

`IPhoneReceiveApprovalStore` persists receiver-scoped destination decisions using
an atomic file. `IPhoneReceiverClient` optionally filters its delivery list by
allowed IDs; the discovery client remains unfiltered. Production dependencies
provide separately filtered local/USB clients and include legacy job IDs.

`IPhoneIncomingFilesViewModel` owns one foreground polling task, pending files,
the immutable prompt batch, postponed IDs, and visible discovery errors. The
root `ContentView` owns it and routes accepted batches into `USBReceiverView`.

The existing local receive actor and USB actor acquire an in-flight guard before
their first suspension to prevent duplicate work during re-entrant discovery.

## Verification

Run XCTest on an iOS simulator in macOS CI with fake HTTP/scheduling boundaries
and real approval persistence, client decoding, view models and receive engines.
Cover pending detection, 10 files, duplicate polling, immutable batches,
postponement, stale responses, account changes, destination filtering, USB
fallback, concurrent discovery, network failures and existing USB integrity tests.
No production Worker deployment is necessary. Build version 0.3.4 (15), inspect
the IPA's version/bundle and ZIP integrity before handing it off.

## Limits

No new push service or paid account requirement. Closed-app arrival alerts and
physical Lightning/USB behavior are not established by simulator tests. USB
operations still require the receive screen to remain foreground.
