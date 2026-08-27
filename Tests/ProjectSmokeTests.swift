import XCTest
@testable import SimpleCameraAutoSender

final class ProjectSmokeTests: XCTestCase {
    func testBundleIdentifierContract() {
        XCTAssertEqual(AppIdentity.bundleIdentifier, "com.hejong2byte.simplecameraautosender")
    }

    func testAutomationOpensAppWithoutUserInteraction() {
        XCTAssertTrue(SendNewSimpleCameraPhotosIntent.openAppWhenRun)
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
}

