import SwiftUI
import UniformTypeIdentifiers

struct USBReceiverView: View {
    @ObservedObject var model: USBReceiverViewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectingDestination = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                identityCard
                destinationCard
                progressCard
                storedFilesCard
                operationNotice
            }
            .padding()
        }
        .refreshable { await model.refresh() }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("PC 파일 수신")
        .task {
            await model.refresh()
            updatePolling(for: scenePhase)
        }
        .onChange(of: scenePhase) { _, phase in
            updatePolling(for: phase)
            if phase == .active { Task { await model.refresh() } }
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
        .alert(
            "USB가 연결되지 않았습니다. iPhone에 저장할까요?",
            isPresented: Binding(
                get: { model.needsLocalFallbackDecision },
                set: { _ in }
            )
        ) {
            Button("iPhone에 저장") { Task { await model.chooseLocalFallback() } }
            Button("서버에 대기", role: .cancel) {
                Task { await model.chooseServerWait() }
            }
        } message: {
            Text("현재 PC 대기 파일 묶음에 적용됩니다.")
        }
        .confirmationDialog(
            "USB 전송이 완료되었습니다. iPhone 원본을 삭제할까요?",
            isPresented: Binding(
                get: { model.needsDeletionDecision },
                set: { _ in }
            ),
            titleVisibility: .visible
        ) {
            Button("원본 유지(권장)", role: .cancel) {
                Task { await model.keepOriginals() }
            }
            Button("iPhone 원본 삭제", role: .destructive) {
                Task { await model.deleteOriginals() }
            }
        } message: {
            Text("USB에서 크기와 SHA-256 검증을 마친 파일만 대상입니다.")
        }
    }

    private var identityCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("수신 기기").font(.headline)
            if model.isRegistered {
                Label(model.deviceName ?? "iPhone", systemImage: "iphone")
                HStack {
                    Text("PC 입력 코드").foregroundStyle(.secondary)
                    Spacer()
                    Text(model.registrationCode ?? "------")
                        .font(.title2.monospacedDigit().bold())
                        .textSelection(.enabled)
                }
            } else {
                Label("수신 기기 등록이 필요합니다", systemImage: "iphone.badge.exclamationmark")
                    .foregroundStyle(.orange)
                Button("이 iPhone 등록") { Task { await model.registerDevice() } }
                    .buttonStyle(.borderedProminent)
            }
        }
        .cardStyle()
    }

    private var destinationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("PC에서 새로 받을 파일의 저장 위치").font(.headline)
            Picker(
                "저장 위치",
                selection: Binding(
                    get: { model.selectedDestination },
                    set: { model.setSelectedDestination($0) }
                )
            ) {
                Text("나의 iPhone").tag(IPhoneReceiveDestination.iphoneLocal)
                Text("USB 직접 저장").tag(IPhoneReceiveDestination.usb)
            }
            .pickerStyle(.segmented)
            .disabled(model.isExportingToUSB)

            if model.selectedDestination == .iphoneLocal {
                Label("받은 파일 폴더에 저장", systemImage: "iphone.gen3")
                    .foregroundStyle(.green)
                Text("시작된 다운로드는 다른 앱을 사용 중에도 iOS가 이어갈 수 있습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
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
                .disabled(model.isExportingToUSB)
            }
            Text("iPhone에 이미 저장된 파일은 아래 목록에서 선택해 USB로 복사하세요.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .cardStyle()
    }

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("PC 새 파일 수신 상태")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Text(model.receiveStageTitle).font(.headline)
                Spacer()
                if model.isPolling {
                    Label("감시 중", systemImage: "dot.radiowaves.left.and.right")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }

            if let progress = model.receiveProgress, progress.stage != .idle {
                if progress.stage == .discovering {
                    ProgressView().tint(.cyan)
                } else {
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
                    Label(fileName, systemImage: "doc.fill")
                        .font(.subheadline)
                        .lineLimit(2)
                }
                if progress.totalCount > 0 {
                    Text("전체 \(progress.totalCount)개 · 저장 완료 \(progress.completedCount)개")
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
            } else if model.receiveProgress == nil || model.receiveProgress?.stage == .idle {
                Text("PC에서 이 iPhone 코드로 파일을 보내면 앱을 열었을 때 확인합니다.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .cardStyle()
    }

    private var storedFilesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("iPhone에 저장된 파일").font(.headline)
                Spacer()
                Text("\(model.storedFiles.count)개")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if model.storedFiles.isEmpty {
                Text("저장된 파일이 없습니다.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text("파일을 눌러 선택한 뒤 아래 복사 버튼을 누르세요. 선택 \(model.selectedStoredFileIDs.count)개")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(model.storedFiles) { file in
                    Button {
                        model.toggleStoredFileSelection(file.id)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: model.selectedStoredFileIDs.contains(file.id)
                                ? "checkmark.circle.fill"
                                : "circle")
                                .foregroundStyle(.cyan)
                            Image(systemName: "doc.fill")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(file.name).lineLimit(2)
                                Text("\(byteText(file.size)) · \(file.modifiedAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isExportingToUSB)
                    Divider()
                }
            }
            Button("선택 파일 USB로 복사") {
                Task { await model.exportSelectedFilesToUSB() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.hasStoredFileSelection || model.isExportingToUSB)

            if model.isExportingToUSB || model.usbExportProgress != nil || model.lastUSBExportError != nil {
                usbExportStatus
            }
        }
        .cardStyle()
    }

    private var usbExportStatus: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            Text(model.usbExportStageTitle).font(.headline)
            if let progress = model.usbExportProgress {
                if progress.stage != .failed {
                    ProgressView(value: Double(progress.percent), total: 100)
                        .tint(.cyan)
                    HStack {
                        Text("\(progress.percent)%")
                            .font(.title3.monospacedDigit().bold())
                        Spacer()
                        Text(model.usbExportByteText)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                if let fileName = progress.fileName {
                    Label(fileName, systemImage: "doc.fill")
                        .font(.subheadline)
                        .lineLimit(2)
                }
                Text("전체 \(progress.totalCount)개 · USB 복사 완료 \(progress.completedCount)개")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if model.isExportingToUSB {
                ProgressView().tint(.cyan)
            }
            if let error = model.lastUSBExportError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.red)
                Text("복사에 실패한 파일의 원본은 자동 삭제하지 않습니다. 오류 원인을 확인한 뒤 선택된 파일을 다시 복사할 수 있습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var operationNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("안전한 저장 방식", systemImage: "checkmark.shield.fill")
                .font(.headline)
            Text("파일은 최종 크기와 SHA-256이 일치한 뒤에만 완료 처리합니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("USB 직접 저장과 USB 복사는 이 화면이 앞에 있을 때 진행됩니다. 전원 공급형 Lightning-USB 어댑터와 exFAT USB를 권장합니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .cardStyle()
    }

    private func updatePolling(for phase: ScenePhase) {
        if phase == .active { model.startForegroundPolling() }
        else { model.stopForegroundPolling() }
    }

    private func byteText(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: max(0, bytes))
    }
}
