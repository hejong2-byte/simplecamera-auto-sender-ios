# Dismiss PC receive notice implementation plan

Approved design: add a visible `확인·닫기` action to a terminal PC receive result on both home and receiver screens. Remove only the matching receiver's saved outcome. Preserve local files, USB files, transfer jobs, ACK retry and incoming-file monitoring. Active transfers cannot be dismissed. A newly reported result remains visible.

1. Add a UI regression that opens a receive error, closes the notice and expects the waiting state. Run against the unchanged application and confirm the missing-button failure.
2. Add `canDismissReceiveOutcome` and `dismissReceiveOutcome()` to `USBReceiverViewModel`. Clear durable outcome first, then visible result and matching error. Retain result and show a dismissal error if persistence fails. Use the existing receiver-scoped outcome store, with no file or job mutation.
3. Extend `PCReceiveStatusView` with an optional dismissal callback and error text. Wire both `ContentView` and `USBReceiverView` to the same model. Add tests for terminal warning dismissal, store reload, new errors, active-transfer guard and persistence failure. Verify local file bytes are unchanged.
4. Run all simulator tests and build version 0.3.24 (35). Verify IPA bundle version, ZIP integrity, release digest and decoded SideStore QR before delivering. No physical iPhone execution claim.

User additions: show estimated time remaining for the current USB copy phase using bytes and phase elapsed time. Show calculating before sufficient progress, recalculating while responses are stale, and finalizing instead of zero seconds at the write boundary. Do not claim the estimate includes later files or extraction. Remove the long `진행률은 용량 기준입니다...` paragraph and its spacing. Keep filename, counts and speed.

Further user additions: add cooperative USB export cancellation. Check task cancellation between chunks, ZIP entries, inventory entries and before final rename. Cancellation must stop later files, retain originals and already completed files, and clean only current export partial/extraction roots. Do not promise interruption of an OS-blocked write. Show cancel requested/cleaning until the worker returns. Add manual cleanup for legacy `extract-<UUID>` directories in the app's ZIP working root and `export-<UUID>.partial` under the selected USB's app partial directory. Validate name, containment and no symlinks; keep all other files and resumable network downloads. When USB is missing clean iPhone temps and explain USB was not checked. Manual cleanup requires confirmation and is unavailable during file operations. Increase copy speed text size. Preserve CRC checks.
# 추가 승인: iPhone 저장 ZIP의 USB 최종 경로

- iPhone 내부 해제 임시폴더는 유지한다. USB 최종 위치에 ZIP 이름 래퍼를 만들지 않는다.
- 압축의 유일한 최상위 폴더가 `SD_CARD_ROOT`이면 그 내용으로 USB 루트를 구성한다. 일반 ZIP의 다른 하위 폴더 구조는 유지한다.
- USB 루트에 같은 최상위 이름이 이미 있으면 덮어쓰기·임의 이름 변경 없이 충돌을 알린다. 원본과 기존 USB 내용은 유지한다.
- 쓰기·크기 확인을 마친 임시 복사 내용만 루트로 확정한다. 중간 오류가 있으면 완료로 표시하지 않는다.
- 검증: 일반 ZIP 루트 배치, SD_CARD_ROOT 제거, 원본 보존, 기존 MAP 충돌, 선택 SHA 검증과 임시파일 정리 회귀.
