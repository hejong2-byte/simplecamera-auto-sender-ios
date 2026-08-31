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

        XCTAssertTrue(project.contains("CURRENT_PROJECT_VERSION: 18"))
        XCTAssertTrue(project.contains("MARKETING_VERSION: 0.3.7"))
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

