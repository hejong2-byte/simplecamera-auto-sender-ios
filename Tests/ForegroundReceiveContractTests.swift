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

    func testZIPChoicePrecedesDestinationAndCanBePostponed() throws {
        let root = try source("App/UI/ContentView.swift")
        XCTAssertTrue(root.contains("압축을 해제하시겠습니까?"))
        XCTAssertTrue(root.contains("압축 해제"))
        XCTAssertTrue(root.contains("ZIP 그대로 저장"))
        XCTAssertTrue(root.contains("수신 보류 · 앱을 다시 열면 다시 안내합니다."))
    }

    func testMultiplePendingFilesHaveAnExplicitPrioritySelectionSheet() throws {
        let root = try source("App/UI/ContentView.swift")
        let selection = try source("App/UI/PendingIncomingSelectionView.swift")

        XCTAssertTrue(root.contains("PendingIncomingSelectionView"))
        XCTAssertTrue(selection.contains("pending-file-selection"))
        XCTAssertTrue(selection.contains("pending-select-all"))
        XCTAssertTrue(selection.contains("pending-clear-selection"))
        XCTAssertTrue(selection.contains("pending-confirm-selection"))
        XCTAssertTrue(selection.contains("선택 파일 먼저 받기"))
        XCTAssertTrue(selection.contains("selectedPendingFileIDs"))
    }

    func testStoredZIPExportRequiresAnExplicitModeChoice() throws {
        let receiver = try source("App/UI/USBReceiverView.swift")
        XCTAssertTrue(receiver.contains("압축 해제해서 복사"))
        XCTAssertTrue(receiver.contains("ZIP 그대로 복사"))
        XCTAssertTrue(receiver.contains("confirmStoredZIPExport"))
    }

    func testSettingsUsesDedicatedStorageManagementScreen() throws {
        let settings = try source("App/UI/SettingsView.swift")
        let storage = try source("App/UI/USBStorageManagementView.swift")
        XCTAssertTrue(settings.contains("SD/USB 저장장치 관리"))
        XCTAssertTrue(storage.contains("선택한 저장장치 내용 전체 삭제"))
        XCTAssertTrue(storage.contains("파일시스템(참고)"))
        XCTAssertFalse(settings.contains("Button(\"SD/USB 전체 파일 삭제\""))
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }
}
