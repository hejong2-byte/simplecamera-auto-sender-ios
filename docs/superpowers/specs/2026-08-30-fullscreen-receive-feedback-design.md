# iPhone full-screen layout and PC receive feedback

## Approved scope

The user selected approach A: remove the top and bottom letterboxing, reduce
decorative space on the main screen, and keep one clear, durable PC receive
result. This change is limited to the iPhone app. It does not change the relay
protocol, Windows sender routing, Simple Cam photo matching, or USB copy
integrity rules.

## Root cause

- The generated application Info.plist has no launch-screen declaration. On the
  physical iPhone this presents the app in a vertically letterboxed area, which
  wastes substantial height before SwiftUI lays out its content.
- `ContentView` also repeats the navigation title with a large decorative arrow
  and explanatory header, consuming more of the reduced viewport.
- PC receive progress is held in an in-memory progress store. The detailed
  receiver screen can show it while the app is running, but the main screen does
  not expose the final receive state, and a relaunch loses USB completion and
  failure context. A stored iPhone file proves that a local save happened, but
  it does not provide a uniform result for USB saves and failures.

## Full-screen and main-screen layout

- Add the modern launch-screen declaration to the generated application
  Info.plist and verify that the built IPA contains it. Preserve the normal iOS
  safe areas; the app must not draw controls under the status indicator, Dynamic
  Island, or home indicator.
- Remove the large standalone arrow/header block. The navigation title remains
  the screen title, so no functional label is lost.
- Use compact vertical spacing for the status and action cards. Do not reduce
  button tap targets below the iOS recommended size and do not force a smaller
  accessibility font.
- Keep a ScrollView for accessibility text sizes and smaller supported screens,
  but on an iPhone 14 Pro at the default text size the usable screen must no
  longer be clipped by black letterbox bars. Scrolling should be caused only by
  actual content overflow, not by unused top or bottom space.
- Preserve the current order of automatic status, the three manual-send buttons,
  manual status, PC file receiver, and settings. No send action is removed.

## Durable PC receive outcome

Create a receiver-scoped local record for the most recent terminal PC receive
event. The record contains only:

- outcome: saved or failed;
- destination: iPhone or USB when known;
- file name and batch counts when known;
- a user-facing result or error message;
- completion/failure time;
- receiver identity used to prevent a result from another registration being
  shown after reset or re-registration.

Store the record atomically under the app's existing PC receiver application
support directory. Do not store authentication secrets, upload credentials,
USB bookmarks, or file contents in the status record. Corrupt or unreadable
status data fails closed and must not block receiving files.

The status is updated only from terminal receive progress:

- `completed` is recorded only after the existing size/SHA-256 validation,
  final save, and server acknowledgement path reports completion;
- `failed` records the existing categorized network, server, authentication,
  storage, USB, expiry, or integrity message;
- `idle` and discovery polling do not erase a terminal result;
- a new active receive temporarily takes visual priority over the prior result;
- a later successful receive replaces an earlier failure;
- resetting the iPhone receiver registration removes or hides its old result.

## Status presentation

The main screen's PC receiver card always shows exactly one current state:

- gray: waiting or registration required;
- blue: checking, downloading, verifying, or finalizing, with file name and
  percentage when available;
- green: saved, with destination, file name, count, and time;
- red: failed, with the concrete reason, time, and a button that opens the PC
  receive screen for retry or setup.

The detailed PC receive screen uses the same current-state source. It retains
the existing progress bar, byte count, speed, ETA, saved-file list, and USB
controls, while making the terminal result a visually explicit success or error
panel. A generic polling failure must not overwrite a verified file-save result,
and USB export errors remain separate from PC receive errors.

The existing foreground arrival dialog remains unchanged: iPhone save, USB
save, or receive later. This work does not claim push alerts while the app is
closed.

## Verification

- Add a failing project contract test for the launch-screen declaration, then
  verify the generated project and final IPA Info.plist.
- Add failing tests for terminal-result persistence, receiver scoping, corrupt
  data, `idle` preservation, failure replacement by success, and registration
  reset.
- Add view-model tests for active-progress priority and the gray/blue/green/red
  presentation states, including categorized error text and timestamps.
- Add or extend UI tests so the main screen exposes all three manual-send
  actions and the PC receive status entry on an iPhone 14 Pro simulator, and
  capture a screenshot for visual inspection.
- Run the full unit/integration/UI test suite and inspect the unsigned IPA for
  bundle identifier, version/build, launch-screen key, and ZIP integrity before
  publishing a SideStore update.

## Success criteria

1. A physical iPhone 14 Pro uses the full safe-area height without the current
   symmetric black top and bottom bars.
2. The main screen no longer repeats a large decorative header and retains all
   existing send and settings actions.
3. During a PC receive, progress is understandable from the main screen; after
   it ends, success or failure, file, destination, and time remain visible.
4. The latest result survives app relaunch for the same registered receiver and
   cannot leak across receiver registrations.
5. Existing photo transfer, manual transfer, USB verification, original-file
   protection, and foreground arrival behavior continue to pass their tests.

## Limits

- Closed-app APNs notifications are not added.
- The design does not guarantee that every accessibility text size fits without
  scrolling.
- Simulator tests cannot prove physical Lightning/USB adapter behavior; the
  final full-screen and hardware presentation still require one device check.
