import SwiftUI
import UniformTypeIdentifiers

struct USBReceiverView: View {
    @ObservedObject var model: USBReceiverViewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectingDestination = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                setupCard
                progressCard
                foregroundNotice
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("PC ZIP 수신")
        .task {
            await model.refresh()
            updatePolling(for: scenePhase)
        }
        .onChange(of: scenePhase) { _, phase in
            updatePolling(for: phase)
        }
        .onDisappear { model.stopForegroundPolling() }
        .fileImporter(
            isPresented: $selectingDestination,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            guard case let .success(urls) = result, let url = urls.first else { return }
            Task { await model.selectDestination(url) }
        }
    }

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("수신 준비").font(.headline)
            if model.isRegistered {
                Label(model.deviceName ?? "iPhone", systemImage: "iphone")
                HStack {
                    Text("PC 입력 코드")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(model.registrationCode ?? "------")
                        .font(.title2.monospacedDigit().bold())
                        .textSelection(.enabled)
                }
            } else {
                Label("수신 기기 등록이 필요합니다", systemImage: "iphone.badge.exclamationmark")
                    .foregroundStyle(.orange)
                Button("이 iPhone 등록") {
                    Task { await model.registerDevice() }
                }
                .buttonStyle(.borderedProminent)
            }

            Divider()

            Label(
                model.usbDisplayName ?? "USB 폴더를 선택해 주세요",
                systemImage: model.hasUSBDestination
                    ? "externaldrive.fill.badge.checkmark"
                    : "externaldrive.badge.questionmark"
            )
            .foregroundStyle(model.hasUSBDestination ? .green : .orange)
            Button(model.hasUSBDestination ? "USB 폴더 다시 선택" : "USB 폴더 선택") {
                selectingDestination = true
            }
            .buttonStyle(.borderedProminent)
        }
        .cardStyle()
    }

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(model.receiveStageTitle).font(.headline)
                Spacer()
                if model.isPolling {
                    Label("감시 중", systemImage: "dot.radiowaves.left.and.right")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }

            if let progress = model.receiveProgress {
                if progress.stage == .discovering {
                    ProgressView().tint(.cyan)
                } else if progress.totalBytes > 0 {
                    ProgressView(value: Double(progress.percent), total: 100)
                        .tint(progress.stage == .failed ? .red : .cyan)
                    HStack {
                        Text(model.receivePercentText)
                            .font(.title3.monospacedDigit().bold())
                        Spacer()
                        Text(model.receiveByteText)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text(model.receiveSpeedText)
                        Spacer()
                        Text(model.receiveETAText)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                if let fileName = progress.fileName {
                    Label(fileName, systemImage: "doc.zipper")
                        .font(.subheadline)
                        .lineLimit(2)
                }
                if progress.totalCount > 0 {
                    Text("전체 \(progress.totalCount)개 · USB 저장 완료 \(progress.completedCount)개")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let expiresAt = progress.expiresAt {
                    Text("서버 보관 만료: \(expiresAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let error = model.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.red)
            } else if model.receiveProgress == nil {
                Text("PC에서 이 iPhone 코드로 ZIP을 보내면 자동으로 확인합니다.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .cardStyle()
    }

    private var foregroundNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("앱을 이 화면에 열어 두세요", systemImage: "lock.open")
                .font(.headline)
            Text("USB 직접 저장은 이 수신 화면이 앞에 있을 때 진행됩니다. 잠금·다른 앱 사용 중에는 서버에 안전하게 보관하고 돌아오면 이어받습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("전원 공급형 Lightning-USB 어댑터와 exFAT USB 사용을 권장합니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .cardStyle()
    }

    private func updatePolling(for phase: ScenePhase) {
        if phase == .active {
            model.startForegroundPolling()
        } else {
            model.stopForegroundPolling()
        }
    }
}
