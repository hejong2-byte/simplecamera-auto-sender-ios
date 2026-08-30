import XCTest

final class ForegroundReceiveUITests: XCTestCase {
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
        outcome: String? = nil
    ) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-incoming", "--ui-test-incoming-delay", String(delay)]
        if let outcome {
            app.launchArguments += ["--ui-test-receive-outcome", outcome]
        }
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
