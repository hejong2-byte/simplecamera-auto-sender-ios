# 선택 파일 삭제 버튼 상태 수정 검증

## 원인 및 변경 범위

- 빈 서버 확인마다 `pollOnce()`가 `isPerformingReceive`를 켰다가 끄는데, 이 값을 삭제 버튼 활성화 조건에도 사용해 선택 상태에서 빨간색/회색이 반복됐다.
- 버튼은 선택 유무와 실제 삭제 처리 중 여부만 따른다. 주기적인 서버 확인은 버튼을 비활성화하지 않는다.
- 실제 수신/USB 복사 중에는 삭제 요청 및 최종 확인 시점에서 파일을 보호하고 이유를 표시한다. 선택은 유지한다.
- 삭제 확인 중 새 수신이 시작되는 경우와 중복 삭제도 차단한다. 기존 파일 범위 검증, 수신 이력, 인증값, 저장 경로, 자동 사진 판별 조건은 변경하지 않았다.

## 테스트 및 빌드

- 재현: [CI 33377859732](https://github.com/hejong2-byte/simplecamera-auto-sender-ios/actions/runs/33377859732), 소스 `a81f52740109745996ee03c4dca3d31fc9203b6f`. 선택된 버튼이 빈 확인 중 비활성화되고 그동안 삭제 확인 요청도 차단되는 것을 실제 XCTest 실패로 확인했다.
- 수정 후 [CI 33378644232](https://github.com/hejong2-byte/simplecamera-auto-sender-ios/actions/runs/33378644232)에서 수동 삭제 테스트 9개와 UI 테스트 7개는 통과했다. 새 버전과 맞추지 못한 버전 검사 2개 단언만 실패해 기대값을 0.3.8/19로 갱신했다.
- 최종: [CI 33379353794](https://github.com/hejong2-byte/simplecamera-auto-sender-ios/actions/runs/33379353794), 소스 `b438bceabf1473eb9fe11520bc3876ec2b5a0597`.
- 로직 244개 + UI 7개 = 251개, 실패 0건. iPhoneOS Release IPA 빌드 성공.
- 반복된 빈 확인(iPhone/USB 목적지 각각 3회), 확인 중 선택/해제 및 삭제, 실제 수신 중 보호, 확인 후 수신 시작, 중복 삭제를 검증했다.
- UI에서 선택/해제, 확인창 취소 후 선택 유지, 삭제 후 선택 해제와 비선택 파일 보존을 확인했다. 같은 앱 코드인 33378644232의 iPhone 16 Pro 시뮬레이터 캡처에서 선택된 빨간 버튼과 삭제 후 회색 버튼을 직접 확인했다.

## 전달 파일

- 버전 0.3.8, 빌드 19. 기존 앱 식별자 `com.hejong2byte.simplecameraautosender` 유지.
- 바탕화면: `C:/Users/user/Desktop/SimpleCameraAutoSender-v0.3.8-build19.ipa`.
- 크기: 1,741,569바이트.
- SHA-256: `CFBDA72128BD7D25E46DDA4812957FCEFB3AE970FFBA3AA27A3D274053B64D80`.
- ZIP 무결성, arm64, iPhoneOS, 최소 iOS 17.0, 버전, 파일 앱 표시, launch screen, 사진 접근 설명, 시뮬레이터 전용 코드 제외를 검사했다. 내려받은 IPA와 바탕화면 사본의 해시가 일치한다.
- 이번 전달은 CI에서 빌드한 unsigned IPA이며 SideStore가 서명한다. 공개 릴리스 태그 및 기존 QR 링크는 변경하지 않았다.
- 실제 iPhone/USB 하드웨어에서는 직접 시험하지 않았다. 기존 저장 파일을 유지하려면 앱 삭제 없이 SideStore에서 업데이트 설치한다.
