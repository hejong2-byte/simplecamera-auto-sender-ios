import Photos
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: ContentViewModel
    @ObservedObject var receiverModel: USBReceiverViewModel
    @ObservedObject var filePickerModel: KakaoFilePickerModel
    @ObservedObject var textModel: TextTransferViewModel
    @State private var credential = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                photoAccessCard
                credentialCard
                kakaoFolderCard
                monitoringCard
                automationCard
                receiverSettingsCard
                storageManagementCard
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("설정")
    }

    private var kakaoFolderCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("파일 전송 기본 폴더").font(.headline)
            Label(filePickerModel.folderName ?? "폴더 미선택", systemImage: "folder")
            Button(filePickerModel.folderName == nil ? "폴더 선택" : "폴더 다시 선택") {
                filePickerModel.changeFolder()
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("kakao-folder-select")
        }
        .cardStyle()
    }

    private var receiverSettingsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("PC 파일 수신").font(.headline)
            if receiverModel.isRegistered {
                Label(
                    "\(receiverModel.deviceName ?? "iPhone") · 코드 \(receiverModel.registrationCode ?? "------")",
                    systemImage: "iphone.gen3"
                )
                Button("수신 기기 등록 초기화", role: .destructive) {
                    Task { await receiverModel.resetRegistration() }
                }
                .buttonStyle(.bordered)
            } else {
                Button("이 iPhone 수신 기기 등록") {
                    Task { await receiverModel.registerDevice() }
                }
                .buttonStyle(.borderedProminent)
            }

            Toggle(
                "셀룰러에서도 파일 수신",
                isOn: Binding(
                    get: { receiverModel.allowsCellular },
                    set: { receiverModel.setAllowsCellular($0) }
                )
            )
        }
        .cardStyle()
        .task { await receiverModel.refresh() }
    }

    private var storageManagementCard: some View {
        NavigationLink {
            USBStorageManagementView(
                model: receiverModel,
                transferModel: model,
                textModel: textModel
            )
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("SD/USB 저장장치 관리", systemImage: "externaldrive.fill")
                        .font(.headline)
                    Text(receiverModel.usbDisplayName ?? "저장장치 폴더 미선택")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("storage-management")
        .cardStyle()
    }

    private var photoAccessCard: some View {
        setupCard(number: 1, title: "사진 접근") {
            Label(
                photoAccessText,
                systemImage: model.hasFullPhotoAccess
                    ? "checkmark.circle.fill"
                    : "photo.badge.exclamationmark"
            )
            .foregroundStyle(model.hasFullPhotoAccess ? .green : .orange)
            if !model.hasFullPhotoAccess {
                Button("사진 전체 접근 허용") {
                    Task { await model.requestPhotoAccess() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var credentialCard: some View {
        setupCard(number: 2, title: "전송 인증 설정") {
            Label(
                model.hasCredential ? "인증값 저장됨" : "인증값 필요",
                systemImage: model.hasCredential ? "checkmark.shield.fill" : "key.fill"
            )
            SecureField("인증값", text: $credential)
                .textContentType(.password)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
            Button("인증값 저장") {
                let value = credential
                Task {
                    try? await model.saveCredential(value)
                    credential = ""
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var monitoringCard: some View {
        setupCard(number: 3, title: "자동 전송 시작") {
            Label(
                model.isMonitoringEnabled ? "새 사진 감시 시작됨" : "아직 시작하지 않음",
                systemImage: model.isMonitoringEnabled ? "checkmark.circle.fill" : "record.circle"
            )
            Button("이 시점부터 자동 전송") {
                Task { try? await model.enableAutomaticSending() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isMonitoringEnabled)
        }
    }

    private var automationCard: some View {
        setupCard(number: 4, title: "아이폰 자동화 1회 설정") {
            Text("단축어 앱 → 자동화 → 앱 → Simple Cam → 닫힐 때 → 즉시 실행 → 새 SimpleCamera 사진 전송")
                .font(.subheadline)
        }
    }

    private func setupCard<Content: View>(
        number: Int,
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(number). \(title)").font(.headline)
            content()
        }
        .cardStyle()
    }

    private var photoAccessText: String {
        switch model.photoAuthorizationStatus {
        case .authorized: "사진 전체 접근 허용됨"
        case .limited: "일부 사진만 허용됨 — 전체 접근이 필요합니다"
        case .denied, .restricted: "사진 접근이 차단됨"
        case .notDetermined: "사진 접근 허용이 필요합니다"
        @unknown default: "사진 접근 상태를 확인해 주세요"
        }
    }
}
