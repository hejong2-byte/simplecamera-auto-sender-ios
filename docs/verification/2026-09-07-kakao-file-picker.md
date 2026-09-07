# 카카오톡 다운로드 파일 선택 오류 0.3.14 검증 기록

## 원인과 변경 범위

- 저장된 기본 폴더가 없을 때 `카카오톡 파일전송`이 파일 선택기가 아니라 **폴더 전용 선택기**를 열고 있었다.
- 폴더 전용 선택기는 문서·사진을 선택 대상으로 인정하지 않으므로, 파일 앱에서 모든 파일이 흐리게 표시되고 눌러도 선택되지 않았다.
- `카카오톡 파일전송`은 이제 기본 폴더 설정 여부와 관계없이 곧바로 파일 선택 모드로 연다.
- 설정에서 지정한 카카오톡 기본 폴더는 파일 선택창의 시작 위치로만 사용한다.
- 여러 파일 선택, 원본 유지, 큰 파일 분할 및 백그라운드 전송 동작은 변경하지 않았다.

## 데이터 보존

- 이번 변경은 문서 선택기의 모드와 선택창 시작 위치 처리만 수정했다.
- 기존 사진·동영상·문서 전송 원장, 받은 파일, 텍스트 기록, 인증값, 기기 식별값 및 저장된 설정 구조는 변경하지 않았다.
- 기존 데이터를 유지하려면 앱을 삭제하지 않고 SideStore에서 업데이트해야 한다.

## 재현 및 테스트

- 재현 테스트 CI: [34095716709](https://github.com/hejong2-byte/simplecamera-auto-sender-ios/actions/runs/34095716709). 수정 전에는 요청이 `folder`로 열려 예상대로 실패했다.
- 수정 직후 CI: [34096983959](https://github.com/hejong2-byte/simplecamera-auto-sender-ios/actions/runs/34096983959). 저장 폴더 테스트가 새 선택기 URL의 선택형 타입을 반영하지 못해 컴파일 실패했고, 테스트만 좁게 수정했다.
- 수정 검증 CI: [34097208667](https://github.com/hejong2-byte/simplecamera-auto-sender-ios/actions/runs/34097208667), 성공.
- 릴리스 후보 CI: [34098428163](https://github.com/hejong2-byte/simplecamera-auto-sender-ios/actions/runs/34098428163), 성공.
- 정식 릴리스 CI: [34099253941](https://github.com/hejong2-byte/simplecamera-auto-sender-ios/actions/runs/34099253941), 소스 `66d66f4df6a820b081dc96c0865cbf2d8ecefe2a`, 성공.
- 정식 릴리스에서 로직 테스트 314개와 UI 테스트 13개를 실행했으며 실패는 0개였다.
- 실제 iPhone의 파일 터치와 SideStore 설치는 이 환경에서 직접 실행하지 않았으며, 시뮬레이터·자동 테스트·배포 패키지까지 검증했다.

## 설치물 검증

- 태그: `v0.3.14` (`66d66f4df6a820b081dc96c0865cbf2d8ecefe2a`)
- 릴리스: <https://github.com/hejong2-byte/simplecamera-auto-sender-ios/releases/tag/v0.3.14>
- IPA: 2,530,956바이트
- IPA SHA-256: `a345d59a9f157329b54893f575d2087c90c476f447255f56165aed720176ca61`
- IPA 내부 식별자: `com.hejong2byte.simplecameraautosender`
- IPA 내부 버전: `0.3.14` (`25`)
- ZIP 무결성, 파일 앱 공유 및 제자리 열기 설정을 확인했다.
- GitHub 최신 정식 릴리스가 `v0.3.14`이고 QR의 `releases/latest/download` 주소가 이 IPA를 가리키는 것을 확인했다.
- QR: 2,903바이트
- QR SHA-256: `95af9ce2cd019829f803cb8d495923e6f4d9007db990434758d688ab8c55505b`
- QR을 ZXing으로 직접 해독해 저장소의 SideStore 설치 URI와 일치함을 확인했다.
- 바탕화면 전달 폴더: `C:\Users\user\Desktop\SimpleCamera-iPhone-0.3.14`
