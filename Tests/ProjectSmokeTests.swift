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

        XCTAssertTrue(project.contains("CURRENT_PROJECT_VERSION: 15"))
        XCTAssertTrue(project.contains("MARKETING_VERSION: 0.3.4"))
        XCTAssertTrue(project.contains("UIFileSharingEnabled: true"))
        XCTAssertTrue(
            project.contains("INFOPLIST_KEY_LSSupportsOpeningDocumentsInPlace: YES")
        )
    }

    func testPCReceiverCardAppearsBelowManualTransferStatus() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repository.appendingPathComponent("App/UI/ContentView.swift"),
            encoding: .utf8
        )
        let body = try XCTUnwrap(source.range(of: "VStack(spacing: 16)"))
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
}

