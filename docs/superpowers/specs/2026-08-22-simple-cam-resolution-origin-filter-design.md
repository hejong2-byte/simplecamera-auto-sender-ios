# Simple Cam 해상도·촬영 앱 판별 설계

## 목표

기존 `Simple Cam이 닫힐 때` 개인용 자동화와 `새 SimpleCamera 사진 전송` App Intent를 유지하면서, Simple Cam으로 촬영한 새 사진만 업무사진 중계 서버로 전송한다. 일반 iPhone 카메라 사진, 스크린샷, 다운로드 이미지와 과거 사진은 전송하지 않는다.

이번 변경은 모든 새 사진 전송 모드나 별도 앱을 만들지 않는다. 기존 앱과 번들 식별자 `com.hejong2byte.simplecameraautosender`를 그대로 업그레이드한다.

## 확인된 현상

- 자동화는 `Simple Cam이 닫힐 때` 즉시 `새 SimpleCamera 사진 전송`을 실행하도록 올바르게 설정되어 있다.
- 확인한 Simple Cam 촬영 사진은 JPEG이고 픽셀 크기가 `6048 × 8064`이다.
- iPhone 기본 카메라 사진은 사진 정보에 `Apple / iPhone 14`와 같은 카메라 제조사·모델 표식이 나타나며, Simple Cam 사진 정보는 다르게 표시된다.
- 배포 버전 v0.1.3은 TIFF `Software` 값만 옛 이름인 `Simple Camera…`인지 검사한다. 현재 앱 이름·메타데이터가 `Simple Cam…`으로 바뀌면 사진을 발견해도 전부 0장으로 처리하고 마지막 검사에서 영구 `ignored` 상태로 만든다.
- 현재 원본 내보내기 코드는 `.fullSizePhoto`를 `.photo`보다 먼저 선택한다. 판별은 편집 표현보다 원본 `.photo` 리소스를 우선 사용해야 한다.

## 판별 규칙

이미지는 다음 조건을 모두 만족할 때만 전송한다.

1. 자동 전송 시작 시각 이후 생성됐고 아직 대기·완료·제외 처리되지 않은 새 이미지이다.
2. 원본 형식이 JPEG이다.
3. 원본 픽셀 크기가 `6048 × 8064` 또는 회전된 `8064 × 6048`이다.
4. 다음 둘 중 하나에 해당한다.
   - 정규화한 TIFF `Software` 값이 현재 이름 `Simple Cam` 또는 호환 이름 `Simple Camera`, `The Simple Camera`와 정확히 같거나 해당 이름 뒤에 공백과 버전이 이어진다.
   - TIFF `Software`, `Make`, `Model`이 모두 없거나 빈 값이다.

해상도가 일치해도 `Software`가 승인된 Simple Cam 이름이 아니면서 `Software`, `Make`, `Model` 중 하나라도 다른 값으로 존재하면 제외한다. 특히 `Apple` 또는 `iPhone` 기본 카메라 표식이 있으면 반드시 제외한다. 이 규칙은 일반 카메라의 48MP 사진이 같은 해상도인 경우와 다른 앱에서 만든 이미지를 막기 위한 것이다.

판독할 수 없거나 위 조건이 애매하면 전송하지 않는다. 잘못된 사진을 보내는 것보다 Simple Cam 사진 한 장을 보류하는 것을 우선하는 fail-closed 정책을 사용한다.

사진 정보의 위치, 파일 용량, ISO, 조리개, 초점거리와 일련번호 형식의 파일명은 판별에 사용하지 않는다. 값이 촬영마다 바뀌거나 개인정보가 될 수 있기 때문이다.

## 구현 구조

### 원본 선택

`PhotoKitAssetSource`는 `PHAssetResource` 중 `.photo`를 먼저 선택하고, 해당 리소스가 없을 때만 `.fullSizePhoto`로 대체한다. iCloud 원본 다운로드 허용과 기존 비동기 파일 내보내기 동작은 유지한다.

### 이미지 판별기

기존 판별기를 파일 형식, 해상도와 TIFF 정보를 함께 읽는 `SimpleCameraPhotoMatcher` 역할로 확장한다. ImageIO에서 원본 UTI, 픽셀 폭·높이, TIFF `Software`, `Make`, `Model`을 읽고 위 판별 규칙을 한 곳에서 적용한다.

`PhotoSyncService`의 검색, 중복 방지, 세 차례 재검색, 업로드 큐와 장부 상태 전이는 유지한다. 판별에 실패한 사진은 마지막 재검색 뒤에만 `ignored` 처리한다.

### 화면과 자동화

기존 화면과 App Intent 이름, 사용자가 이미 만든 개인용 자동화는 유지한다. 결과 문구는 기존처럼 확인·전송 시작 장수를 보여준다. 새 자동화나 사진 선택 단축어는 요구하지 않는다.

## 오류 처리

- 원본이 아직 저장 중이면 기존 재검색 간격에서 다시 시도한다.
- ImageIO가 파일 형식, 픽셀 크기 또는 판별 메타데이터를 읽지 못하면 해당 실행에서는 일치하지 않은 것으로 취급하되, 마지막 재검색 전에는 영구 제외하지 않는다.
- 사진 전체 접근, 인증값, 네트워크 및 서버 오류 처리는 기존 동작을 유지한다.
- v0.1.3에서 이미 `ignored` 처리된 사진은 자동으로 재전송하지 않는다. 업그레이드 뒤 새로 촬영한 사진으로 검증한다.

## 테스트

- `6048 × 8064`와 `8064 × 6048`을 모두 허용한다.
- 현재 이름 `Simple Cam`과 버전 문자열을 허용한다.
- 호환 이름 `Simple Camera`, `The Simple Camera`와 버전 문자열을 허용한다.
- 승인된 Simple Cam `Software`가 있으면 Apple/iPhone 모델 정보가 함께 있어도 허용한다.
- Simple Cam `Software`가 없고 `Software`, `Make`, `Model`이 모두 비어 있으면 목표 해상도 JPEG를 허용한다.
- 목표 해상도라도 Apple/iPhone 기본 카메라 표식이 있고 승인된 Simple Cam `Software`가 없으면 거부한다.
- 목표 해상도라도 다른 `Software`, `Make` 또는 `Model` 값이 있으면 거부한다.
- HEIC·PNG 등 JPEG가 아닌 파일, 다른 해상도, 손상된 파일, 픽셀 정보를 읽을 수 없는 파일은 거부한다.
- PhotoKit 리소스 우선순위가 `.photo` 다음 `.fullSizePhoto`인지 검증한다.
- 전체 단위 테스트, unsigned IPA 빌드와 IPA ZIP 무결성 검사를 통과해야 한다.

## 배포

- 버전을 v0.1.4로 올린다.
- 기존 GitHub Release 워크플로로 `SimpleCameraAutoSender.ipa`와 `install-qr.png`를 게시한다.
- QR은 기존 SideStore 최신 릴리스 주소를 유지해 사용자가 스캔하여 업그레이드 설치할 수 있게 한다.
- 기기 확인은 앱 업그레이드 후 새 Simple Cam 사진 1장과 새 기본 카메라 사진 1장을 촬영해, Simple Cam 사진만 전송되는지 확인한다.

## 범위 밖

- 사진함의 모든 새 이미지 전송
- 별도 번들 식별자의 두 번째 앱
- Simple Cam 열림 자동화 추가
- 일반 카메라·스크린샷·다운로드 이미지 업로드

## 변경 격리

구현 브랜치는 배포 코드 v0.1.3을 기준으로 새로 만든다. 폐기된 `codex/all-new-photo-sender` 브랜치의 테스트나 구현 커밋을 병합·체리픽하지 않는다. 승인된 설계 문서와 이번 판별 변경만 새 브랜치에 포함해 사진 대상이 넓어지는 데이터 오염을 방지한다.
