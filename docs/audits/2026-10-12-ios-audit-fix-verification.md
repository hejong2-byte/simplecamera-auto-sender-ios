# iOS audit fixes — verification record

Candidate: **v0.3.49 / build 60**, based on `e949db50`.
Implementation under final native verification: `e0ff618143927a7a9695adc9fd6d6e64da3d437d`.

## Scope delivered in code

| Area | Change | Regression coverage |
| --- | --- | --- |
| ZIP resume | Durable completed-root and pending-install records; ambiguous moves are reprocessed, not inferred complete from file size | Existing same-size data, move-then-interrupt, changed subset, resumed capacity |
| Overwrite recovery | Preserve the remaining original backup when installation and rollback both fail; propagate recovery path through both receive paths | Injected install and rollback failures, cleanup, shared pipeline |
| Upload state | Atomic store transactions and cached state | Interleaved completion/enqueue, multipart ETags, 1,000 progress events, legacy decoding |
| Background completion | Drain delivered callbacks after durable processing; schedule backoff using background URLSession deadlines | Delayed callback, unrelated completion, system handler ordering, retry bounds |
| USB browser | Reset old path/selection on root re-selection; reject stale asynchronous results | Different roots, missing old child path, same-name files, late snapshots |
| Photo permission | Refresh authorization on foreground activation | Injected denied/limited-to-authorized transitions |
| Received-file catalog | Off-main-actor listing and coalesced refresh | Delayed catalog, newest snapshot, receive/export updates |
| Conveniences | Manual history/failed retry, multi-file sharing, ZIP contents/subset export, folder-first name/date/size sorting | Original recipient, document re-selection, URL validation, subset safety, UI access |

## Preserved behavior

- Existing bundle ID and Simple Cam-only automatic photo eligibility.
- ZIP CRC, write errors, file-size checks and explicit overwrite approval.
- No default whole-USB SHA reread. Optional precise verification remains user-initiated.
- Selected ZIP subsets do not create original-deletion decisions.
- Ordinary files inside ZIPs cannot collide with private resume/commit metadata.
- No real USB files were deleted during development tests; fault injection uses isolated fixtures.

## Evidence

- Native behavioral RED: runs `38213234809`, `38213346158`, `38214507723` and completed test output from cancelled run `38215645971`.
- Compile failures in `38214128852` and `38215281667` are recorded separately and are not behavioral RED evidence.
- Independent final code review found no remaining actionable P1/P2 in the changed A/B/C paths.
- Local install-contract, QR URI and whitespace checks pass.
- Focused run `38217294375` completed **591 unit tests with zero failures** (`unit-tests.log`, suite completion 2026-10-12 07:28:51 UTC). Previously failing ZIP finalization, callback drain and ZIP selection races now pass.
- Its selected UI suite passed 9 of 10 tests. The remaining failure was a wrong test locator: screenshot and accessibility hierarchy show `ActivityListView`, header `2 Documents` and `1 Image and 1 Document`, while the test expected a single-item header. The test now checks the observed multi-item sheet, both item types, activity list, close behavior and preserved selection. No production change followed this successful unit run.
- The final release run will repeat all unit tests and the complete UI suite (including the corrected multi-file test) before building or publishing an IPA; an additional duplicate focused run is unnecessary.
- Full release tests and downloaded IPA verification: **pending**.

## Limits

This Windows host cannot run Xcode locally. Native tests use GitHub's macOS iOS simulator; no physical iPhone/USB reader, real background suspension, Settings permission change, USB throughput or KakaoTalk recipient delivery has been measured here. Cache tests establish that repeated progress processing survives without rereading disk; they are not a hardware speed benchmark.
