import XCTest

final class MobileUITests: XCTestCase {
    @MainActor
    func testOnboardingMatchesAndSettings() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-onboarding"]
        app.launch()
        XCTAssertTrue(app.buttons["Get started"].waitForExistence(timeout: 20))
        attach(app, name: "Onboarding")
        app.buttons["Get started"].tap()
        XCTAssertTrue(app.textFields["Search teams"].waitForExistence(timeout: 5))
        app.buttons["Continue"].tap()
        XCTAssertTrue(app.staticTexts["Keep the score close"].waitForExistence(timeout: 5))
        app.buttons["Continue"].tap()
        app.buttons["Show matches"].tap()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Quit"].exists)
        attach(app, name: "Matches")
        let pin = app.buttons["Pin to Lock Screen"].firstMatch
        XCTAssertTrue(pin.waitForExistence(timeout: 15))
        pin.tap()
        XCTAssertTrue(app.buttons["Unpin"].firstMatch.waitForExistence(timeout: 10))
        attach(app, name: "Pinned match")
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.buttons["Remove all pinned scores"].waitForExistence(timeout: 5))
        app.buttons["Remove all pinned scores"].tap()
        attach(app, name: "Settings")
        app.terminate()
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Get started"].exists)
    }

    @MainActor
    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
