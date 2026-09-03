import XCTest

final class ForegroundReceiveUITests: XCTestCase {
    func testKakaoFolderPickerCancellationDoesNotRequestPhotoPermissionOrStartTransfer() {
        let app = launchSimulation(delay: 3_600)
        let files = app.buttons["manual-kakao-file"]
        XCTAssertTrue(files.waitForExistence(timeout: 20))
        reveal(files, in: app)
        files.tap()
        let cancel = app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "Cancel", "취소")).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 15), "Files input must open a folder picker, not photo permission")
        keepScreenshot("kakao-folder-picker", app: app)
        cancel.tap()
        XCTAssertTrue(files.waitForExistence(timeout: 10))
        XCTAssertTrue(files.isEnabled)
        XCTAssertFalse(app.staticTexts["파일 준비 중"].exists)
        XCTAssertFalse(app.staticTexts["전송 완료"].exists)
    }

    func testKakaoFileActionAppearsAfterVideoAndFolderIsConfigurable() {
        let app = launchSimulation(delay: 3_600)
        let files = app.buttons["manual-kakao-file"]
        XCTAssertTrue(files.waitForExistence(timeout: 20))
        reveal(files, in: app)
        XCTAssertTrue(files.isHittable)
        XCTAssertGreaterThan(files.frame.minY, app.buttons["manual-video"].frame.minY)
        keepScreenshot("main-kakao-file-action", app: app)

        let settings = app.buttons["open-settings"]
        reveal(settings, in: app)
        settings.tap()
        let folder = app.buttons["kakao-folder-select"]
        reveal(folder, in: app)
        XCTAssertTrue(folder.isHittable)
        keepScreenshot("settings-kakao-folder", app: app)
    }

    func testStoredFilePreviewPreservesSelectionAndReceiverCardIsRemoved() {
        let app = launchSimulation(delay: 3_600, withStoredFiles: true)
        let receiver = app.buttons["open-receiver"]
        XCTAssertTrue(receiver.waitForExistence(timeout: 20))
        receiver.tap()
        XCTAssertFalse(app.staticTexts["수신 기기"].exists)
        XCTAssertFalse(app.staticTexts["PC 입력 코드"].exists)

        let selected = app.buttons["stored-file-keep-me.txt"]
        reveal(selected, in: app)
        selected.tap()
        let delete = app.buttons["stored-files-delete"]
        XCTAssertTrue(delete.isEnabled)
        let open = app.buttons["stored-file-open-keep-me.txt"]
        XCTAssertTrue(open.isHittable)
        open.tap()

        let close = app.buttons["stored-preview-close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        let contents = app.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS %@ OR value CONTAINS %@", "simulated local file", "simulated local file"
        )).firstMatch
        XCTAssertTrue(contents.waitForExistence(timeout: 15), "Quick Look must display the stored file contents")
        keepScreenshot("stored-file-readonly-preview", app: app)
        close.tap()
        XCTAssertTrue(selected.waitForExistence(timeout: 5))
        XCTAssertTrue(delete.isEnabled, "Preview must preserve the USB/delete selection")
        XCTAssertTrue(app.buttons["stored-file-delete-me.txt"].exists)
        keepScreenshot("stored-file-preview-return", app: app)
    }

    func testLocalFileDeletionRequiresConfirmationAndPreservesUnselectedFile() {
        let app = launchSimulation(delay: 3_600, withStoredFiles: true)
        let receiver = app.buttons["open-receiver"]
        XCTAssertTrue(receiver.waitForExistence(timeout: 20))
        receiver.tap()
        let selected = app.buttons["stored-file-delete-me.txt"]
        reveal(selected, in: app)
        XCTAssertTrue(selected.isHittable)
        let delete = app.buttons["stored-files-delete"]
        XCTAssertTrue(delete.exists)
        XCTAssertFalse(delete.isEnabled, "No selection must leave deletion disabled")
        selected.tap()
        XCTAssertTrue(delete.isEnabled)
        selected.tap()
        XCTAssertFalse(delete.isEnabled)
        selected.tap()
        XCTAssertTrue(delete.isEnabled)
        reveal(delete, in: app)
        XCTAssertTrue(delete.isHittable)
        delete.tap()

        let cancel = app.alerts.buttons["취소"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        keepScreenshot("local-file-delete-confirmation", app: app)
        cancel.tap()
        XCTAssertTrue(selected.exists, "Cancel must retain the selected file")
        XCTAssertTrue(delete.isEnabled, "Cancel keeps the selection and enabled deletion button")
        delete.tap()
        let confirm = app.alerts.buttons["삭제"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()

        let removed = expectation(
            for: NSPredicate(format: "exists == false"),
            evaluatedWith: selected
        )
        wait(for: [removed], timeout: 10)
        XCTAssertTrue(app.buttons["stored-file-keep-me.txt"].exists)
        XCTAssertFalse(delete.isEnabled, "Deleting the only selected file clears the selection")
        XCTAssertTrue(app.staticTexts["iPhone 파일 1개 삭제 완료"].exists)
        XCTAssertFalse(app.staticTexts["안전한 저장 방식"].exists)
        keepScreenshot("local-file-delete-completed", app: app)
    }

    func testMainScreenCriticalActionsAreHittableWithoutInitialScroll() {
        let app = launchSimulation(delay: 60)

        for identifier in [
            "manual-photo",
            "manual-screenshot",
            "manual-video",
            "open-receiver"
        ] {
            let element = app.buttons[identifier]
            XCTAssertTrue(element.waitForExistence(timeout: 20), "Missing \(identifier)")
            XCTAssertTrue(element.isHittable, "\(identifier) must be visible without scrolling")
        }
        keepScreenshot("main-fullscreen-compact", app: app)
    }

    func testUSBChoiceOpensFolderPickerAndCancellationAllowsLocalFallback() {
        let app = launchSimulation()
        XCTAssertTrue(app.buttons["USB에 저장"].waitForExistence(timeout: 20))
        app.buttons["USB에 저장"].tap()
        let cancel = app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "Cancel", "취소")).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 15), "USB choice must open the system folder picker")
        keepScreenshot("usb-folder-picker", app: app)
        cancel.tap()
        XCTAssertTrue(app.buttons["서버에 대기"].waitForExistence(timeout: 10))
        keepScreenshot("usb-local-fallback-choice", app: app)
        app.buttons["iPhone에 저장"].tap()
        let destination = app.staticTexts["받은 파일 폴더에 저장"]
        reveal(destination, in: app)
        XCTAssertTrue(destination.isHittable)
        keepScreenshot("usb-fallback-iphone-destination", app: app)
    }

    func testMainScreenPresentsChoicesAndPostponedFilesCanBeReopened() {
        let app = launchSimulation()
        XCTAssertTrue(app.buttons["iPhone에 저장"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["USB에 저장"].exists)
        keepScreenshot("main-incoming-choice", app: app)
        app.buttons["나중에 받기"].tap()

        let pending = app.buttons["incoming-pending"]
        reveal(pending, in: app)
        XCTAssertTrue(pending.isHittable)
        pending.tap()
        XCTAssertTrue(app.buttons["iPhone에 저장"].waitForExistence(timeout: 5))
        app.buttons["iPhone에 저장"].tap()
        XCTAssertTrue(app.navigationBars["PC 파일 수신"].waitForExistence(timeout: 10))
        keepScreenshot("iphone-receive-screen", app: app)
    }

    func testArrivalWhileSettingsIsVisiblePresentsAChoiceAndRoutesToReceiver() {
        let app = launchSimulation(delay: 15)
        let settings = app.buttons["open-settings"]
        reveal(settings, in: app)
        XCTAssertTrue(settings.isHittable)
        settings.tap()
        XCTAssertTrue(app.navigationBars["설정"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["iPhone에 저장"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.navigationBars["설정"].exists)
        keepScreenshot("settings-incoming-choice", app: app)
        app.buttons["iPhone에 저장"].tap()
        XCTAssertTrue(app.navigationBars["PC 파일 수신"].waitForExistence(timeout: 10))
    }

    func testMainScreenShowsSavedPCReceiveOutcome() {
        let app = launchSimulation(delay: 60, outcome: "saved")

        XCTAssertTrue(app.otherElements["pc-receive-success"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["iPhone 저장 완료"].exists)
        keepScreenshot("main-receive-success", app: app)
    }

    func testMainScreenShowsCategorizedPCReceiveFailure() {
        let app = launchSimulation(delay: 60, outcome: "error")

        XCTAssertTrue(app.otherElements["pc-receive-error"].waitForExistence(timeout: 20))
        let serverError = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "서버 오류")
        ).firstMatch
        XCTAssertTrue(serverError.exists)
        keepScreenshot("main-receive-error", app: app)
    }

    private func launchSimulation(
        delay: Int = 0,
        outcome: String? = nil,
        withStoredFiles: Bool = false
    ) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-incoming", "--ui-test-incoming-delay", String(delay)]
        if let outcome {
            app.launchArguments += ["--ui-test-receive-outcome", outcome]
        }
        if withStoredFiles { app.launchArguments.append("--ui-test-stored-files") }
        app.launch()
        addTeardownBlock { app.terminate() }
        return app
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<6 {
            if element.isHittable { return }
            app.swipeUp()
        }
    }

    private func keepScreenshot(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
