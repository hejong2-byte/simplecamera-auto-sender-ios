import XCTest
@testable import SimpleCameraAutoSender

final class ForegroundReceiveContractTests: XCTestCase {
    func testRootOwnsArrivalMonitoringAndStorageChoice() throws {
        let root = try source("App/UI/ContentView.swift")
        XCTAssertTrue(root.contains("incomingModel.setActive"), "Arrival monitoring must not require opening the receiver screen")
        XCTAssertTrue(root.contains("incomingModel.accept"), "Arrival choices must explicitly approve their batch")
        XCTAssertTrue(root.contains("incomingModel.showPendingFiles"), "Postponed files must remain reachable")
        XCTAssertTrue(root.contains("iPhone에 저장"))
        XCTAssertTrue(root.contains("USB에 저장"))
        XCTAssertTrue(root.contains("나중에 받기"))
    }

    func testBothReceiveClientsRequireExplicitDeliveryApprovals() throws {
        let dependencies = try source("App/Application/USBReceiverDependencies.swift")
        XCTAssertTrue(dependencies.contains("allowedDeliveryIDs:"))
        XCTAssertTrue(dependencies.contains("client: localClient"))
        XCTAssertTrue(dependencies.contains("client: usbClient"))
        XCTAssertTrue(dependencies.contains("makeIncomingFilesViewModel"))
    }

    func testLocalFallbackHasAnExplicitApprovalBoundary() throws {
        let model = try source("App/UI/USBReceiverViewModel.swift")
        XCTAssertTrue(model.contains("approveLocalFallback"), "USB fallback may not consume unrelated unapproved files")
    }

    func testDestinationChoiceIsNotOverriddenByAnUnappliedPicker() throws {
        let receiver = try source("App/UI/USBReceiverView.swift")
        let settings = try source("App/UI/SettingsView.swift")
        XCTAssertFalse(receiver.contains("setSelectedDestination"))
        XCTAssertFalse(settings.contains("setSelectedDestination"))
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }
}
