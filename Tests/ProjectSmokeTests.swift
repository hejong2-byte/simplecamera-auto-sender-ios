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

        XCTAssertTrue(project.contains("CURRENT_PROJECT_VERSION: 21"))
        XCTAssertTrue(project.contains("MARKETING_VERSION: 0.3.10"))
        XCTAssertTrue(project.contains("UIFileSharingEnabled: true"))
        XCTAssertTrue(
            project.contains("INFOPLIST_KEY_LSSupportsOpeningDocumentsInPlace: YES")
        )
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

