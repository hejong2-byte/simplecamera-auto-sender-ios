# iPhone 텍스트 송수신 0.3.11 검증 기록

## 범위

- Windows와 iPhone이 사용하는 `simplecamera-text-v1` 봉투 형식
- iPhone 텍스트 작성, 전송, 전면 수신 감시, 내역 보존, 복사, TXT 저장, 공유, 재시도, 삭제
- 수신기 ID와 수신 비밀값으로 제한된 Worker 목록·다운로드·ACK 경로
- 기존 Simple Cam 전용 자동 사진 판별과 전송 원장 보존

## 구현 검증

- iOS 기능 CI: `33838158159` 성공
- iOS 0.3.11 릴리스 후보 CI: `33844225024` 성공 (`7e61694dc2cd30a4f7d0cae2bbdf387c2b06db9c`)
- Worker 로컬 테스트: 30개 성공
- Worker TypeScript 검사와 배포 드라이런 성공
- Windows 호환 고정 fixture SHA-256: `0f1512181ec6da46e59def7c7b4f57fe216265d718e44b6f42a4e4fef768381c`
- 고정 fixture 콘텐츠 ID: `0f151218-1ec6-4a46-a59d-ef7c7b4f57fe`

## 실제 Worker 배포 및 격리 스모크 테스트

- Worker URL: `https://simplecamera-work-photo-relay.simplecamera-work-photo-relay.workers.dev`
- Worker 버전 ID: `5c6467be-5667-4e02-b755-a4cc8e084290`
- R2 multipart 완료 후 저장 객체를 다시 조회하는 운영 환경 수정: `872497b`
- 테스트 봉투: 197바이트
- 테스트 봉투 SHA-256: `c9c6aafbb06a4df1dcfa5e29156dc5bb7aa18672117d38ce73e982c615cb62d9`
- multipart 시작 `201`, 조각 전송 `200`, 완료 `201`
- 다른 수신기의 비밀값으로 목록 접근 `403`
- 대상 수신기 목록 `200`, 다운로드 `200`, 원문 바이트 및 SHA-256 일치
- 첫 ACK `204`, 같은 ACK 재호출 `204`, 이후 테스트 항목 목록에서 제거 확인
- 스모크 테스트용 수신기 5개를 정확한 ID로 삭제한 뒤 잔여 `0` 확인

## 설치물

0.3.11 release workflow와 IPA 및 QR 해시는 릴리스 직후 이 문서에 추가한다.
