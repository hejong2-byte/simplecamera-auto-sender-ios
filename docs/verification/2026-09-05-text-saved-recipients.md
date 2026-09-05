# 텍스트 수신코드 저장 및 기록 길게 누르기 0.3.13 검증 기록

## 변경 범위

- 텍스트 송신용 6자리 수신코드를 이름과 함께 최대 5개까지 저장한다.
- 저장 항목을 누르면 수신코드 입력란에 적용하고, 마지막 선택 항목을 앱 재실행 뒤에도 복원한다.
- 저장 항목의 이름 변경과 삭제를 지원한다. 동일 코드를 다시 저장하면 순서를 바꾸지 않고 이름만 갱신한다.
- 텍스트 기록을 짧게 누르면 기존 상세 화면을 열고, 길게 누르면 `전체 복사`, `TXT로 저장`, `공유`, `삭제` 메뉴를 바로 표시한다.
- TXT 저장과 공유는 동일한 UTF-8 원문과 파일명 생성 규칙을 사용한다.

## 데이터 보존 및 격리

- 새 설정은 앱 문서의 `TextMessages/saved-recipients.json`에 원자적으로 저장한다.
- 기존 텍스트 기록, 작성 중 초안, 사진·동영상 전송 원장, 받은 파일, 인증값 및 기기 식별값의 저장 구조는 변경하지 않았다.
- 저장 코드 삭제는 해당 바로가기만 삭제하며 텍스트 기록이나 초안은 삭제하지 않는다.
- 기존 앱을 삭제하지 않고 SideStore에서 업데이트해야 iPhone에 보관된 기존 데이터를 유지할 수 있다.

## 테스트 및 UI 검증

- 릴리스 후보 CI: [33950631818](https://github.com/hejong2-byte/simplecamera-auto-sender-ios/actions/runs/33950631818), 소스 `6544c3776ed71da565ecec4c9b2cbe802549e503`, 성공.
- 정식 릴리스 CI: [33950986252](https://github.com/hejong2-byte/simplecamera-auto-sender-ios/actions/runs/33950986252), 같은 소스, 성공.
- 정식 릴리스에서 로직 테스트 314개와 UI 테스트 13개를 실행했으며 실패는 0개였다.
- 저장 수 제한, ASCII 숫자 6자리 검증, 중복 코드 이름 갱신, 재실행 복원, 쓰기 실패 시 기존 상태 보존, 이름 변경·삭제, UTF-8 내보내기를 자동 테스트했다.
- UI 시뮬레이션에서 저장 바로가기 선택과 텍스트 기록 길게 누르기를 실행하고 네 가지 문맥 메뉴가 표시되는 스크린샷을 확인했다.
- 실제 iPhone의 터치와 SideStore 설치는 이 환경에서 직접 실행하지 않았으며, 시뮬레이터와 배포 패키지까지 검증했다.

## 설치물 검증

- 태그: `v0.3.13` (`6544c3776ed71da565ecec4c9b2cbe802549e503`)
- 릴리스: <https://github.com/hejong2-byte/simplecamera-auto-sender-ios/releases/tag/v0.3.13>
- IPA: 2,530,963바이트
- IPA SHA-256: `93402e3bf91b2c6c528e85808be46016b292ac8d1f78631d9fd4d15316d4774b`
- IPA 내부 식별자: `com.hejong2byte.simplecameraautosender`
- IPA 내부 버전: `0.3.13` (`24`)
- ZIP 무결성, 파일 앱 공유 및 제자리 열기 설정을 확인했다.
- GitHub `releases/latest/download`에서 다시 받은 IPA의 SHA-256이 바탕화면 전달본과 일치했다.
- QR: 2,903바이트
- QR SHA-256: `95af9ce2cd019829f803cb8d495923e6f4d9007db990434758d688ab8c55505b`
- QR을 ZXing으로 직접 해독해 저장소의 SideStore 설치 URI와 일치함을 확인했다.
- 바탕화면 전달 폴더: `C:\Users\user\Desktop\SimpleCamera-iPhone-0.3.13`
