import XCTest
@testable import SimpleCameraAutoSender

final class ProjectSmokeTests: XCTestCase {
    func testBundleIdentifierContract() {
        XCTAssertEqual(AppIdentity.bundleIdentifier, "com.hejong2byte.simplecameraautosender")
    }

    func testAutomationOpensAppWithoutUserInteraction() {
        XCTAssertTrue(SendNewSimpleCameraPhotosIntent.openAppWhenRun)
    }

    func testReleaseVersionAndFilesVisibilityContract() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let project = try String(
            contentsOf: repository.appendingPathComponent("project.yml"),
            encoding: .utf8
        )

        XCTAssertTrue(project.contains("CURRENT_PROJECT_VERSION: 30"))
        XCTAssertTrue(project.contains("MARKETING_VERSION: 0.3.19"))
        XCTAssertTrue(project.contains("exactVersion: 0.9.20"))
        XCTAssertTrue(project.contains("UIFileSharingEnabled: true"))
        XCTAssertTrue(
            project.contains("INFOPLIST_KEY_LSSupportsOpeningDocumentsInPlace: YES")
        )
    }

    func testReleaseDocumentsRepeatPromptAndDirectZIPExtraction() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let main = try String(
            contentsOf: repository.appendingPathComponent("App/UI/ContentView.swift"),
            encoding: .utf8
        )
        let install = try String(
            contentsOf: repository.appendingPathComponent("docs/install.md"),
            encoding: .utf8
        )
        let readme = try String(
            contentsOf: repository.appendingPathComponent("README.md"),
            encoding: .utf8
        )

        XCTAssertTrue(main.contains("압축을 해제하시겠습니까?"))
        XCTAssertTrue(main.contains("압축 해제"))
        XCTAssertTrue(main.contains("ZIP 그대로 저장"))
        XCTAssertTrue(install.contains("앱이 다시 활성화될 때마다"))
        XCTAssertTrue(install.contains("iPhone 내부 임시공간"))
        XCTAssertTrue(install.contains("검증된 압축 해제 폴더"))
        XCTAssertTrue(readme.contains("현재 버전은 0.3.19(빌드 30)"))
    }

    func testReleaseDocumentsPriorityReceiveStoredZIPAndStorageManagement() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let pending = try String(
            contentsOf: repository.appendingPathComponent("App/UI/PendingIncomingSelectionView.swift"),
            encoding: .utf8
        )
        let receiver = try String(
            contentsOf: repository.appendingPathComponent("App/UI/USBReceiverView.swift"),
            encoding: .utf8
        )
        let settings = try String(
            contentsOf: repository.appendingPathComponent("App/UI/SettingsView.swift"),
            encoding: .utf8
        )
        let install = try String(
            contentsOf: repository.appendingPathComponent("docs/install.md"),
            encoding: .utf8
        )
        let readme = try String(
            contentsOf: repository.appendingPathComponent("README.md"),
            encoding: .utf8
        )

        XCTAssertTrue(pending.contains("선택 파일 먼저 받기"))
        XCTAssertTrue(receiver.contains("압축 해제해서 복사"))
        XCTAssertTrue(receiver.contains("ZIP 그대로 복사"))
        XCTAssertTrue(settings.contains("SD/USB 저장장치 관리"))
        XCTAssertTrue(install.contains("선택하지 않은 파일은 서버에 그대로 남"))
        XCTAssertTrue(install.contains("ZIP 그대로 복사"))
        XCTAssertTrue(readme.contains("선택 파일 먼저 받기"))
        XCTAssertTrue(readme.contains("설정 → SD/USB 저장장치 관리"))
    }

    func testReleaseDeclaresModernLaunchScreen() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let project = try String(
            contentsOf: repository.appendingPathComponent("project.yml"),
            encoding: .utf8
        )

        XCTAssertTrue(project.contains("UILaunchScreen: {}"))
    }

    func testAppIconMasterIsUnifiedOpaqueRGB1024() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let master = try Data(
            contentsOf: repository.appendingPathComponent("design/icon-base.png")
        )
        let appIcon = try Data(
            contentsOf: repository.appendingPathComponent(
                "App/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"
            )
        )

        XCTAssertEqual(master, appIcon)
        XCTAssertGreaterThanOrEqual(appIcon.count, 26)
        XCTAssertEqual(Array(appIcon.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
        XCTAssertEqual(
            appIcon[16..<20].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) },
            1024
        )
        XCTAssertEqual(
            appIcon[20..<24].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) },
            1024
        )
        XCTAssertEqual(appIcon[24], 8)
        XCTAssertEqual(appIcon[25], 2)
    }

    func testAppIconGeneratorDoesNotReintroduceLegacyBadge() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let generator = try String(
            contentsOf: repository.appendingPathComponent("scripts/generate-app-icon.py"),
            encoding: .utf8
        )

        XCTAssertFalse(generator.contains("자동전송"))
        XCTAssertFalse(generator.contains("ADD-ON"))
        XCTAssertFalse(generator.contains("ImageDraw"))
        XCTAssertFalse(generator.contains("ImageFont"))
    }

    func testMainScreenDoesNotKeepTheRedundantDecorativeHeader() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repository.appendingPathComponent("App/UI/ContentView.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(source.contains("private var header: some View"))
        XCTAssertFalse(source.contains("                    header\n"))
    }

    func testMainScreenRemovesFixedDescriptionsButKeepsOperationalStatus() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repository.appendingPathComponent("App/UI/ContentView.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(source.contains("여러 개 선택 가능 · 큰 파일은 32MB씩 나눠 백그라운드 전송합니다. 카카오톡 파일 폴더는 처음 한 번 지정합니다."))
        XCTAssertFalse(source.contains("PC에서 보낸 파일을 iPhone에 저장하거나 USB로 직접 저장"))
        XCTAssertTrue(source.contains("model.automaticTransferMessage"))
        XCTAssertTrue(source.contains("PCReceiveStatusView(status: receiverModel.receiveStatus"))
    }

    func testMainScreenLinksToTheTextTransferInterface() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repository.appendingPathComponent("App/UI/ContentView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("case text"))
        XCTAssertTrue(source.contains("TextTransferView(model: textModel)"))
        XCTAssertTrue(source.contains("open-text-transfer"))
        XCTAssertFalse(source.contains("여러 개 선택 가능 · 큰 파일은 32MB씩 나눠 백그라운드 전송합니다. 카카오톡 파일 폴더는 처음 한 번 지정합니다."))
        XCTAssertFalse(source.contains("PC에서 보낸 파일을 iPhone에 저장하거나 USB로 직접 저장"))
    }

    func testReceiverDoesNotKeepTheRedundantSafetyInformationCard() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repository.appendingPathComponent("App/UI/USBReceiverView.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(source.contains("안전한 저장 방식"))
        XCTAssertFalse(source.contains("operationNotice"))
    }

    func testSettingsExposeReferenceFileSystemAndConfirmedFolderCleanup() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let settings = try String(
            contentsOf: repository.appendingPathComponent("App/UI/SettingsView.swift"),
            encoding: .utf8
        )
        let storage = try String(
            contentsOf: repository.appendingPathComponent("App/UI/USBStorageManagementView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(settings.contains("SD/USB 저장장치 관리"))
        XCTAssertTrue(storage.contains("파일시스템(참고)"))
        XCTAssertTrue(storage.contains("선택한 저장장치 내용 전체 삭제"))
        XCTAssertTrue(storage.contains("선택한 폴더 자체와 iPhone 원본은 유지"))
        XCTAssertFalse(storage.contains("FAT32 포맷"))
    }

    func testReceiverReplacesIdentityCardWithSeparateLocalPreviewAction() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repository.appendingPathComponent("App/UI/USBReceiverView.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(source.contains("identityCard"))
        XCTAssertTrue(source.contains("model.openStoredFile(file)"))
        XCTAssertTrue(source.contains("stored-file-open-"))
        XCTAssertTrue(source.contains("StoredFilePreview("))
    }

    func testManualFilePickerDoesNotUseThePhotoLibrary() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repository.appendingPathComponent("App/UI/ContentView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("DocumentFilePicker("))
        XCTAssertTrue(source.contains("model.sendSelectedFiles("))
        XCTAssertTrue(source.contains("model.fileTransferReadinessMessage"))
    }

    func testPCReceiverCardAppearsBelowManualTransferStatus() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repository.appendingPathComponent("App/UI/ContentView.swift"),
            encoding: .utf8
        )
        let body = try XCTUnwrap(source.range(of: "VStack(spacing: 12)"))
        let manual = try XCTUnwrap(
            source.range(of: "manualStatusCard", range: body.upperBound..<source.endIndex)
        )
        let receiver = try XCTUnwrap(
            source.range(of: "receiverCard", range: body.upperBound..<source.endIndex)
        )

        XCTAssertLessThan(manual.lowerBound, receiver.lowerBound)
    }

    func testExistingUSBBookmarkAndLedgerPathsRemainStable() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repository.appendingPathComponent(
                "App/Application/USBReceiverDependencies.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains(".appendingPathComponent(\"USBReceiver\", isDirectory: true)"))
        XCTAssertTrue(source.contains("fileURL: usbStateDirectory.appendingPathComponent(\"destination.json\")"))
        XCTAssertTrue(source.contains("fileURL: usbStateDirectory.appendingPathComponent(\"ledger.json\")"))
    }

    func testMainAndReceiverScreensShareThePCReceiveStatusView() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let main = try String(
            contentsOf: repository.appendingPathComponent("App/UI/ContentView.swift"),
            encoding: .utf8
        )
        let receiver = try String(
            contentsOf: repository.appendingPathComponent("App/UI/USBReceiverView.swift"),
            encoding: .utf8
        )
        let shared = try String(
            contentsOf: repository.appendingPathComponent("App/UI/PCReceiveStatusView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(main.contains("PCReceiveStatusView(status: receiverModel.receiveStatus"))
        XCTAssertTrue(receiver.contains("PCReceiveStatusView(status: model.receiveStatus"))
        XCTAssertTrue(shared.contains("pc-receive-success"))
        XCTAssertTrue(shared.contains("pc-receive-error"))
    }
}

