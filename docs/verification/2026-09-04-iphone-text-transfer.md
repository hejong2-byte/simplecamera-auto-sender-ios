# iPhone 텍스트 송수신 0.3.11 검증 기록

## 범위

- Windows와 iPhone이 사용하는 `simplecamera-text-v1` 봉투 형식
- iPhone 텍스트 작성, 전송, 전면 수신 감시, 내역 보존, 복사, TXT 저장, 공유, 재시도, 삭제
- 수신기 ID와 수신 비밀값으로 제한된 Worker 목록·다운로드·ACK 경로
- 기존 Simple Cam 전용 자동 사진 판별과 전송 원장 보존

## 구현 검증

- iOS 기능 CI: `33838158159` 성공
- Worker 로컬 테스트: 29개 성공
- Worker TypeScript 검사와 배포 드라이런 성공
- Windows 호환 고정 fixture SHA-256: `0f1512181ec6da46e59def7c7b4f57fe216265d718e44b6f42a4e4fef768381c`
- 고정 fixture 콘텐츠 ID: `0f151218-1ec6-4a46-a59d-ef7c7b4f57fe`

## 실제 배포 및 설치물

Worker 실제 배포, 격리 송수신 스모크 테스트, 0.3.11 release workflow, IPA 및 QR 해시는 배포 직후 이 문서에 추가한다.
