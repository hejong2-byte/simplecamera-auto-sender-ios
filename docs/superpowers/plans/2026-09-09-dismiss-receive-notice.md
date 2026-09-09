# Dismiss PC receive notice implementation plan

Approved design: add a visible `확인·닫기` action to a terminal PC receive result on both home and receiver screens. Remove only the matching receiver's saved outcome. Preserve local files, USB files, transfer jobs, ACK retry and incoming-file monitoring. Active transfers cannot be dismissed. A newly reported result remains visible.

1. Add a UI regression that opens a receive error, closes the notice and expects the waiting state. Run against the unchanged application and confirm the missing-button failure.
2. Add `canDismissReceiveOutcome` and `dismissReceiveOutcome()` to `USBReceiverViewModel`. Clear durable outcome first, then visible result and matching error. Retain result and show a dismissal error if persistence fails. Use the existing receiver-scoped outcome store, with no file or job mutation.
3. Extend `PCReceiveStatusView` with an optional dismissal callback and error text. Wire both `ContentView` and `USBReceiverView` to the same model. Add tests for terminal warning dismissal, store reload, new errors, active-transfer guard and persistence failure. Verify local file bytes are unchanged.
4. Run all simulator tests and build version 0.3.24 (35). Verify IPA bundle version, ZIP integrity, release digest and decoded SideStore QR before delivering. No physical iPhone execution claim.
