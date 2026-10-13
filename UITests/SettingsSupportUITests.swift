import XCTest

final class SettingsSupportUITests: XCTestCase {
    func testSettingsShowsCurrentVersionAndManualUpdateCheck() {
        let app = openSettings()
        let version = app.staticTexts["app-version"]
        reveal(version, in: app)
        XCTAssertTrue(version.exists, "Settings must show the installed version and build")
        XCTAssertTrue(version.label.contains("빌드"))
        XCTAssertTrue(app.buttons["check-app-update"].exists)
    }

    func testDiagnosticsShareCanBeCancelledAndActionRemainsEnabled() {
        let app = openSettings()
        let share = app.buttons["share-diagnostics"]
        reveal(share, in: app)
        XCTAssertTrue(share.exists, "Settings must offer explicit privacy-safe diagnostics sharing")
        share.tap()
        let close = app.buttons["header.closeButton"]
        XCTAssertTrue(close.waitForExistence(timeout: 30))
        close.tap()
        XCTAssertTrue(share.waitForExistence(timeout: 5))
        XCTAssertTrue(share.isEnabled)
    }

    private func openSettings() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-incoming", "--ui-test-incoming-delay", "3600",
                               "--ui-test-shareable-files"]
        app.launch()
        addTeardownBlock { app.terminate() }
        let settings = app.buttons["open-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 20))
        reveal(settings, in: app)
        settings.tap()
        return app
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<10 {
            if element.isHittable { return }
            app.swipeUp()
        }
    }
}
