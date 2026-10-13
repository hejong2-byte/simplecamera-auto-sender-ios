import SwiftUI
import UIKit

struct AppSupportView: View {
    @ObservedObject var model: ContentViewModel
    @ObservedObject var receiverModel: USBReceiverViewModel
    @Environment(\.openURL) private var openURL
    @State private var isChecking = false
    @State private var update: AppUpdate?
    @State private var updateMessage: String?
    @State private var report: DiagnosticsReportFile?
    @State private var isSharing = false
    @State private var diagnosticsMessage: String?
    private let app = AppVersionInfo()
    private let diagnostics = DiagnosticsReportService()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("앱 정보").font(.headline)
            Text("버전 \(app.version) · 빌드 \(app.build)")
                .accessibilityIdentifier("app-version")
            HStack {
                Button(isChecking ? "확인 중…" : "업데이트 확인") {
                    Task { await checkUpdate() }
                }
                .disabled(isChecking)
                .accessibilityIdentifier("check-app-update")
                Button("진단 공유") { shareDiagnostics() }
                    .disabled(isSharing)
                    .accessibilityIdentifier("share-diagnostics")
            }
            .buttonStyle(.bordered)
            if let updateMessage {
                Text(updateMessage).font(.caption).foregroundStyle(.secondary)
            }
            if let update {
                Button("SideStore에서 \(update.version) 설치 열기") {
                    openURL(update.installationURL) { accepted in
                        updateMessage = accepted
                            ? "SideStore로 설치 요청을 열었습니다."
                            : "SideStore를 열지 못했습니다. 설치되어 있는지 확인해 주세요."
                    }
                }
                .buttonStyle(.bordered)
            }
            if let diagnosticsMessage {
                Text(diagnosticsMessage).font(.caption).foregroundStyle(.red)
            }
        }
        .cardStyle()
        .sheet(isPresented: $isSharing, onDismiss: cleanupReport) {
            if let report {
                DiagnosticsShareSheet(url: report.url) {
                    cleanupReport()
                    isSharing = false
                }
            }
        }
    }

    @MainActor
    private func checkUpdate() async {
        guard !isChecking else { return }
        isChecking = true
        update = nil
        updateMessage = nil
        defer { isChecking = false }
        do {
            update = try await AppUpdateService().check(currentVersion: app.version)
            updateMessage = update.map { "새 버전 \($0.version)을 사용할 수 있습니다." }
                ?? "현재 최신 버전입니다."
        } catch let error as AppUpdateError {
            switch error {
            case .timeout: updateMessage = "업데이트 확인 시간이 초과되었습니다. 다시 확인해 주세요."
            case .httpStatus(let status): updateMessage = "업데이트 서버 응답 오류 (\(status)). 다시 확인해 주세요."
            case .invalidRelease: updateMessage = "배포 정보를 검증하지 못했습니다. 다시 확인해 주세요."
            case .network: updateMessage = "네트워크 오류로 확인하지 못했습니다. 다시 확인해 주세요."
            }
        } catch {
            updateMessage = "업데이트를 확인하지 못했습니다. 다시 확인해 주세요."
        }
    }

    private func shareDiagnostics() {
        diagnosticsMessage = nil
        let snapshot = DiagnosticsSnapshot(app: app, receive: receiverModel.receiveProgress,
            manual: model.manualProgress, capturedAt: Date(),
            copy: receiverModel.usbExportProgress,
            copyCheckpointAt: receiverModel.usbExportLastUpdatedAt,
            receiveOutcomeAt: receiverModel.receiveOutcome?.occurredAt)
        do {
            report = try diagnostics.create(snapshot)
            isSharing = true
        } catch {
            diagnosticsMessage = "진단 파일을 만들지 못했습니다. 다시 시도해 주세요."
        }
    }

    private func cleanupReport() {
        guard let report else { return }
        do {
            try diagnostics.cleanup(report)
            self.report = nil
        } catch {
            diagnosticsMessage = "진단 임시파일을 정리하지 못했습니다."
        }
    }
}

private struct DiagnosticsShareSheet: UIViewControllerRepresentable {
    let url: URL
    let onFinish: @MainActor () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in
            Task { @MainActor in onFinish() }
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
