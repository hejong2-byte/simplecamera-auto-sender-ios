import XCTest

final class ForegroundReceiveUITests: XCTestCase {
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
        XCTAssertTrue(app.staticTexts["받은 파일 폴더에 저장"].waitForExistence(timeout: 5))
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

    private func launchSimulation(delay: Int = 0) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-incoming", "--ui-test-incoming-delay", String(delay)]
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
