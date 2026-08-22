import Photos
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: ContentViewModel
    @State private var credential = ""
    @State private var showingResetConfirmation = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                photoAccessCard
                credentialCard
                monitoringCard
                automationCard
                statusCard
                recoveryCard
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("설정")
        .confirmationDialog(
            "자동 전송 기록을 초기화할까요?",
            isPresented: $showingResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("초기화", role: .destructive) {
                Task { await model.resetMonitoring() }
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("초기화한 시점 이전 사진은 다시 전송되지 않습니다.")
        }
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
            Text("인증값은 이 아이폰의 보안 저장소에만 보관됩니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var monitoringCard: some View {
        setupCard(number: 3, title: "자동 전송 시작") {
            Label(
                model.isMonitoringEnabled ? "새 사진 감시 시작됨" : "아직 시작하지 않음",
                systemImage: model.isMonitoringEnabled ? "checkmark.circle.fill" : "record.circle"
            )
            Text("이 버튼을 누른 시점 이후 Simple Cam으로 찍은 사진만 자동 전송 대상입니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
            Text("사진을 고르는 단축키는 만들 필요가 없습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("자동 전송 상태").font(.headline)
            HStack {
                statusValue("대기", model.queuedCount)
                statusValue("완료", model.uploadedCount)
                statusValue("실패", model.failedCount)
            }
            if let summary = model.lastSummary {
                Text("최근 실행: \(summary.matched)장 확인, \(summary.uploaded)장 전송 완료")
                    .font(.caption)
            }
            if let error = model.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .cardStyle()
    }

    private var recoveryCard: some View {
        VStack(spacing: 10) {
            Text("아래 기능은 자동화 오류 복구용입니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("지금 전송") {
                Task { await model.sendNow() }
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)
            .disabled(model.isWorking)
            Button("실패 사진 재시도") {
                Task { await model.retryFailed() }
            }
            .buttonStyle(.bordered)
            .disabled(model.isWorking || model.failedCount == 0)
            Button("자동 전송 초기화", role: .destructive) {
                showingResetConfirmation = true
            }
        }
        .cardStyle()
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

    private func statusValue(_ title: String, _ value: Int) -> some View {
        VStack {
            Text("\(value)").font(.title2.bold())
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
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
