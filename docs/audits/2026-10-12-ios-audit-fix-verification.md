# iOS audit fixes — verification record

Released: **v0.3.50 / build 61**, based on `e949db50`.
Verified release commit: `32686ed72c8248c8e5a1008f6d042392c169ffd4`.

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
- Final release run [38219230463](https://github.com/hejong2-byte/simplecamera-auto-sender-ios/actions/runs/38219230463) passed **591 unit tests and all 35 UI tests: 626 tests, zero failures**, including the corrected multi-file test. The test suite completed at 07:57:25 UTC; the unsigned IPA build succeeded at 07:58:59 UTC on 2026-10-12.
- [v0.3.50](https://github.com/hejong2-byte/simplecamera-auto-sender-ios/releases/tag/v0.3.50) published at 07:59:06 UTC. Downloaded canonical, legacy alias and public latest IPA are byte-identical: **3,304,083 bytes**, SHA-256 `4334eee275323f9559979d9b5dbfdcc946db9dbdf0547c557501901f9dc2d64b`. IPA ZIP CRC, real Info.plist bundle ID/version/build, Files integration flags, icon assets and privacy API reasons passed verification.
- Downloaded 924x924 installation QR matches the validated SideStore installation URI pixel-for-pixel and was visually inspected. Its latest-version target resolves to the same verified IPA. Delivery artifacts are in `release-v0.3.50-verify/`.
- Final simulator screenshots confirm both originals in the multi-file share sheet and all four compact action buttons without clipping. These are simulator checks, not physical-device delivery tests.
- Final visual inspection found the fourth action label truncated after adding multi-file sharing. Shortened its visible title to `임시 정리` while retaining `임시파일 삭제` for accessibility and the existing confirmation behavior. The unpublished v0.3.49 release run `38218875720` was cancelled; its tag is retained unchanged. Final candidate is v0.3.50/build 61, with no transfer-logic changes after the 591-test pass.
- Xcode emitted an AppIntents metadata parsing diagnostic despite successful tests/build. The same diagnostic is present in successful v0.3.48 run `38099610117`; it is not a new regression in this change.

## Limits

This Windows host cannot run Xcode locally. Native tests use GitHub's macOS iOS simulator; no physical iPhone/USB reader, real background suspension, Settings permission change, USB throughput or KakaoTalk recipient delivery has been measured here. Cache tests establish that repeated progress processing survives without rereading disk; they are not a hardware speed benchmark.
