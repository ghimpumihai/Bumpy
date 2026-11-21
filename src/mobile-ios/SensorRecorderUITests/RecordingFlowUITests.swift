import XCTest

/// Drives the operator flow on the Simulator: Start → Recording → Recap, crash recovery, Settings.
/// Permissions should be pre-granted (see README: `xcrun simctl privacy … grant`); an interruption
/// monitor handles any system alert that still appears.
final class RecordingFlowUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // Real sensors. The Simulator has no motion/barometer hardware, so a check fails there and the
        // test takes the (recorded) override path. Uploads go to tools/mock_ingest_server.py if it is
        // running on :8765 (harmless otherwise).
        app.launchArguments = ["-uiTesting", "-uiTestingReset", "-upload.baseURL", "http://127.0.0.1:8765"]
        addUIInterruptionMonitor(withDescription: "System alerts") { alert in
            for title in ["Allow While Using App", "Allow Once", "Allow", "OK", "Keep Precise Location On"] {
                if alert.buttons[title].exists { alert.buttons[title].tap(); return true }
            }
            return false
        }
    }

    private func launch(_ extra: [String] = []) {
        app.launchArguments += extra
        app.launch()
    }

    private func startRecording() {
        // The silent checks include a 5 s motion test; Start is disabled ("Checking…") until they finish.
        let start = app.buttons["startTrip"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        let deadline = Date().addingTimeInterval(40)
        while Date() < deadline && !start.isEnabled {
            // Tap the status-bar band (never a control) so interruption monitors can fire.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01)).tap()
            usleep(500_000)
        }
        XCTAssertTrue(start.waitForEnabled(timeout: 5))
        start.tap()
        // Simulator: no motion hardware, so Start re-runs the 5 s motion check, then asks to override.
        let confirm = app.alerts.buttons["Start anyway"].firstMatch
        if confirm.waitForExistence(timeout: 12) { confirm.tap() }
        XCTAssertTrue(app.descendants(matching: .any)["holdToStop"].waitForExistence(timeout: 10), "recording visible")
    }

    func testFullRecordingFlow() throws {
        launch()
        startRecording()

        XCTAssertTrue(app.descendants(matching: .any)["statusLine"].exists)
        let elapsed = app.staticTexts["elapsed"]
        let t0 = elapsed.label
        sleep(2)
        XCTAssertNotEqual(elapsed.label, t0, "timer advances")

        // A short tap must NOT stop
        let stop = app.descendants(matching: .any)["holdToStop"]
        stop.tap()
        sleep(1)
        XCTAssertTrue(stop.exists, "short tap does not stop")

        // Hold 2 s to stop
        stop.press(forDuration: 2.6)
        let done = app.buttons["recapDone"]
        XCTAssertTrue(done.waitForExistence(timeout: 10), "recap visible")
        XCTAssertTrue(app.descendants(matching: .any)["dataQuality"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["uploadProgress"].exists)
        done.tap()
        XCTAssertTrue(app.buttons["startTrip"].waitForExistence(timeout: 5))
    }

    /// The app is killed mid-recording and relaunched: the trip must be kept and reported as
    /// recovered (spec §4 writer requirements).
    func testCrashRecovery() {
        launch()
        startRecording()
        sleep(3) // let some data land on disk

        app.terminate() // simulates a crash / force-quit while recording
        app.launchArguments = ["-uiTesting"]
        app.launch()
        let recovered = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'recovered'")).firstMatch
        XCTAssertTrue(recovered.waitForExistence(timeout: 10), "interrupted trip is recovered")
    }

    func testSettingsShowsUploadOffWhenEmpty() {
        launch(["-upload.baseURL", ""]) // later argument wins: no API URL
        openSettings()
        let status = app.descendants(matching: .any)["connectionStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertTrue(status.label.hasPrefix("Upload off"), status.label)
    }

    /// No audio (D48): Settings has no road-noise switch; Back returns to Start.
    func testSettingsHasNoRecordingSwitchAndGoesBack() {
        launch()
        openSettings()
        XCTAssertTrue(app.textFields["apiBaseURL"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.switches.count, 0, "nothing to switch on: the app never records audio")
        app.buttons["settingsBack"].tap()
        XCTAssertTrue(app.buttons["startTrip"].waitForHittable(timeout: 5))
    }

    private func openSettings() {
        let menu = app.buttons["menuButton"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.tap()
        let settings = app.buttons["settingsButton"]
        XCTAssertTrue(settings.waitForHittable(timeout: 5))
        settings.tap()
    }
}

extension XCUIElement {
    func waitForHittable(timeout: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if exists && isHittable { return true }; usleep(200_000) }
        return false
    }

    func waitForEnabled(timeout: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if exists && isEnabled { return true }; usleep(200_000) }
        return false
    }
}
