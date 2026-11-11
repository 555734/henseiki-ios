import XCTest

/// Takes the App Store screenshots in the simulator. Output directory: env SCREENSHOT_DIR (default /tmp/shots).
final class ScreenshotTests: XCTestCase {
    private func shot(_ name: String) {
        let dir = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] ?? "/tmp/shots"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try? png.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
    }

    func testScreens() {
        let app = XCUIApplication()
        app.launch()
        sleep(2)
        shot("01-terms")
        if app.buttons["同意して始める"].waitForExistence(timeout: 5) { app.buttons["同意して始める"].tap() }
        sleep(2)
        shot("02-home")
        if app.buttons["声を登録する"].waitForExistence(timeout: 3) {
            app.buttons["声を登録する"].tap()
            sleep(2)
            shot("03-voice")
            app.navigationBars.buttons.element(boundBy: 0).tap()
            sleep(1)
        }
        if app.buttons["設定"].waitForExistence(timeout: 3) {
            app.buttons["設定"].tap()
            sleep(2)
            shot("04-settings")
        }
    }
}
