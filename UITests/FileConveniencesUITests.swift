import XCTest

final class FileConveniencesUITests: XCTestCase {
    func testFilenameSearchTypeFilterResetAndOriginalSharing() {
        let app = launchSimulation()
        app.buttons["open-receiver"].tap()
        let search = app.textFields["stored-file-search"]
        reveal(search, in: app)
        XCTAssertTrue(search.waitForExistence(timeout: 5), "Received files need filename search")
        keepScreenshot("received-file-search-and-type-controls", app: app)
        search.tap()
        search.typeText("문서\n")
        XCTAssertTrue(app.buttons["stored-file-받은 문서.pdf"].exists)
        XCTAssertFalse(app.buttons["stored-file-받은 사진.png"].exists)
        XCTAssertTrue(app.staticTexts["1/3개"].exists)
        let document = app.buttons["stored-file-받은 문서.pdf"]
        reveal(document, in: app)
        document.tap()
        let clear = app.buttons["stored-file-search-clear"]
        reveal(clear, in: app)
        clear.tap()
        let type = app.buttons["stored-file-type-filter"]
        type.tap()
        app.buttons["사진"].tap()
        XCTAssertTrue(app.buttons["stored-file-받은 사진.png"].exists)
        XCTAssertFalse(app.buttons["stored-file-받은 문서.pdf"].exists)
        XCTAssertFalse(app.buttons["stored-files-delete"].isEnabled, "A hidden document must not remain selected for deletion")
        XCTAssertFalse(app.buttons["stored-files-export"].isEnabled, "A hidden document must not remain selected for USB copy")
        keepScreenshot("received-file-filter-hidden-selection-pruned", app: app)
        type.tap()
        app.buttons["전체"].tap()
        for name in ["받은 문서.pdf", "받은 사진.png", "받은 자료.zip"] {
            let share = app.buttons["stored-file-share-\(name)"]
            reveal(share, in: app)
            XCTAssertTrue(share.waitForExistence(timeout: 5))
            share.tap()
            let sheet = app.navigationBars["UIActivityContentView"]
            XCTAssertTrue(sheet.waitForExistence(timeout: 30))
            sheet.buttons["header.closeButton"].tap()
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: share)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
            XCTAssertTrue(app.buttons["stored-file-\(name)"].exists)
        }
    }

    func testNotificationOptInIsVisibleAndOffWithoutLaunchPermissionPrompt() {
        let app = launchSimulation()
        let settings = app.buttons["open-settings"]
        reveal(settings, in: app)
        settings.tap()
        let notifications = app.switches["transfer-notification-toggle"]
        reveal(notifications, in: app)
        XCTAssertTrue(notifications.waitForExistence(timeout: 5), "Settings need 수신·USB 복사 알림")
        XCTAssertEqual(notifications.value as? String, "0")
        XCTAssertFalse(app.alerts.firstMatch.exists)
        keepScreenshot("transfer-notification-setting-default-off", app: app)
    }

    private func launchSimulation() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-incoming", "--ui-test-incoming-delay", "3600",
                               "--ui-test-shareable-files", "--ui-test-shareable-zip"]
        app.launch()
        addTeardownBlock { app.terminate() }
        XCTAssertTrue(app.buttons["open-receiver"].waitForExistence(timeout: 20))
        return app
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 {
            if element.isHittable { return }
            app.swipeUp()
        }
        for _ in 0..<8 {
            if element.isHittable { return }
            app.swipeDown()
        }
    }

    private func keepScreenshot(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
