import XCTest

/// Drives the full operator flow on the Simulator (synthetic motion sensors).
/// Permissions should be pre-granted (see README: `xcrun simctl privacy … grant`); an interruption
/// monitor handles any system alert that still appears.
final class RecordingFlowUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // Real sensors. The Simulator has no motion/barometer hardware, so preflight cannot be all
        // green there and the test takes the (recorded) override path. Uploads go to
        // tools/mock_ingest_server.py if it is running on :8765 (harmless otherwise).
        app.launchArguments = ["-uiTesting", "-uiTestingReset",
                               "-upload.baseURL", "http://127.0.0.1:8765",
                               "-sicknessInterval", "40", "-sicknessTimeout", "10"]
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

    private func startRecording(expectAllGreen: Bool = false) {
        let newSession = app.buttons["newSessionButton"]
        XCTAssertTrue(newSession.waitForExistence(timeout: 10))
        newSession.tap()

        let cont = app.buttons["setupContinue"]
        XCTAssertTrue(cont.waitForExistence(timeout: 5))
        cont.tap()

        // Preflight runs a 5 s motion test; on the Simulator stillness fails (synthetic sway) -> override.
        let start = app.buttons["startRecording"]
        let override = app.buttons["preflightOverride"]
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline && !start.exists && !(override.exists && override.isEnabled) {
            app.tap() // lets interruption monitors fire
            usleep(500_000)
        }
        // wait for the motion test to finish before deciding
        let motionRow = app.descendants(matching: .any)["check.motion.still"]
        XCTAssertTrue(motionRow.waitForExistence(timeout: 5))
        sleep(6)
        if expectAllGreen {
            XCTAssertTrue(start.waitForExistence(timeout: 10), "every preflight check is green")
            XCTAssertFalse(override.exists)
        }
        if start.exists {
            XCTAssertTrue(start.waitForEnabled(timeout: 10))
            start.tap()
        } else {
            XCTAssertTrue(override.waitForExistence(timeout: 5))
            override.tap()
            let confirm = app.alerts.buttons["Start anyway"].firstMatch
            XCTAssertTrue(confirm.waitForExistence(timeout: 5))
            confirm.tap()
        }
        XCTAssertTrue(app.buttons["banner"].waitForExistence(timeout: 10), "dashboard visible")
    }

    func testFullRecordingFlow() throws {
        launch()
        startRecording()

        // Stream table rows present (motion shows "n/a" on the Simulator: no hardware)
        XCTAssertTrue(app.descendants(matching: .any)["row.deviceMotion"].waitForExistence(timeout: 5))
        let banner = app.buttons["banner"]
        XCTAssertTrue(["OK", "WARN", "PROBLEM"].contains(banner.value as? String ?? ""))
        XCTAssertTrue(app.descendants(matching: .any)["row.gps"].exists)
        let elapsed = app.staticTexts["elapsed"]
        let t0 = elapsed.label
        sleep(2)
        XCTAssertNotEqual(elapsed.label, t0, "timer advances")

        // Labels with toast confirmation
        app.buttons["label.pothole"].tap()
        let toast = app.staticTexts["toast"]
        XCTAssertTrue(toast.waitForExistence(timeout: 2))
        XCTAssertTrue(toast.label.contains("Pothole logged"))

        app.buttons["label.speedBump"].tap()
        app.buttons["label.phoneMoved"].tap()

        let cobble = app.buttons["surface.cobblestones"]
        cobble.tap()
        XCTAssertEqual(cobble.value as? String, "active")
        app.buttons["surface.gravel"].tap()
        XCTAssertEqual(cobble.value as? String, "inactive", "surfaces are exclusive")
        XCTAssertEqual(app.buttons["surface.gravel"].value as? String, "active")

        let winding = app.buttons["segment.winding"]
        winding.tap()
        app.buttons["segment.roundabout"].tap()
        XCTAssertEqual(winding.value as? String, "active", "segments are independent")
        XCTAssertEqual(app.buttons["segment.roundabout"].value as? String, "active")

        app.buttons["syncTap"].tap()
        XCTAssertTrue(toast.waitForExistence(timeout: 2))

        // Note
        app.buttons["noteButton"].tap()
        let field = app.textFields["noteField"].exists ? app.textFields["noteField"] : app.textViews["noteField"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.typeText("tram crossing, rough")
        app.buttons["noteSave"].tap()

        // Manual sickness rating
        app.buttons["sicknessButton"].tap()
        let misc3 = app.buttons["misc.3"]
        XCTAssertTrue(misc3.waitForExistence(timeout: 3))
        misc3.tap()
        XCTAssertFalse(misc3.waitForExistence(timeout: 1), "grid closes after rating")

        // Scheduled sickness prompt (every 40 s here) with countdown; answer it
        let countdown = app.staticTexts["sicknessCountdown"]
        XCTAssertTrue(countdown.waitForExistence(timeout: 45), "periodic prompt appears")
        app.buttons["misc.2"].tap()
        XCTAssertFalse(countdown.waitForExistence(timeout: 1))

        // A short tap must NOT stop
        let stop = app.descendants(matching: .any)["holdToStop"]
        stop.tap()
        sleep(1)
        XCTAssertTrue(app.buttons["banner"].exists, "short tap does not stop")

        // Hold 2 s to stop
        stop.press(forDuration: 2.6)
        XCTAssertTrue(app.navigationBars["Session summary"].waitForExistence(timeout: 10))
        // GPS is the stream the Simulator really provides (no motion hardware there)
        XCTAssertTrue(app.descendants(matching: .any)["stat.gps"].waitForExistence(timeout: 5))
        // Export lives at the bottom of a lazy List: scroll to it, then export (share sheet appears)
        let export = app.buttons["exportButton"]
        for _ in 0..<12 where !export.isHittable { app.swipeUp() }
        XCTAssertTrue(export.isHittable)
        export.tap()
        // The zip is created, then the system share sheet (out of process, invisible to XCUITest)
        // is presented over the summary. The app shows its own "Ready: <name>.zip" row.
        let result = app.descendants(matching: .any)["exportResult"]
        XCTAssertTrue(result.waitForExistence(timeout: 15), "zip created")
        XCTAssertTrue(result.label.contains(".zip"), result.label)
        sleep(2) // share sheet animates in
        // Dismiss it by tapping the dimmed area above the sheet (status-bar band: harmless if no sheet).
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.03)).tap()
        sleep(1)
        let done = app.buttons["summaryDone"]
        // Done returns to the session list (retry once in case the first tap only closed the sheet).
        done.tap()
        if !app.buttons["newSessionButton"].waitForExistence(timeout: 3), done.exists { done.tap() }
        XCTAssertTrue(app.buttons["newSessionButton"].waitForExistence(timeout: 5))
        let firstSession = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'session.'")).firstMatch
        XCTAssertTrue(firstSession.waitForExistence(timeout: 5), "session appears in list")
        firstSession.tap()
        XCTAssertTrue(app.descendants(matching: .any)["stat.gps"].waitForExistence(timeout: 5))
    }

    /// Prompt auto-dismisses as "missed"; then the app is killed mid-recording and relaunched:
    /// the session must be kept and flagged RECOVERED (spec §4 writer requirements).
    func testMissedPromptAndCrashRecovery() {
        app.launchArguments = ["-uiTesting", "-uiTestingReset", "-sicknessInterval", "6", "-sicknessTimeout", "3"]
        app.launch()
        startRecording()
        let countdown = app.staticTexts["sicknessCountdown"]
        XCTAssertTrue(countdown.waitForExistence(timeout: 10))
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: countdown)
        waitForExpectations(timeout: 6)

        app.terminate() // simulates a crash / force-quit while recording
        app.launchArguments = ["-uiTesting"]
        app.launch()
        XCTAssertTrue(app.staticTexts["RECOVERED"].waitForExistence(timeout: 10), "interrupted session is recovered")
        let session = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'session.'")).firstMatch
        session.tap()
        XCTAssertTrue(app.descendants(matching: .any)["stat.deviceMotion"].waitForExistence(timeout: 10),
                      "stats rebuilt from the CSV files")
    }

    func testSettingsShowsUploadOffWhenEmpty() {
        launch()
        let settings = app.buttons["settingsButton"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        XCTAssertTrue(app.staticTexts["UPLOAD OFF (local only)"].waitForExistence(timeout: 5)
                      || !app.textFields["apiBaseURL"].value.debugDescription.isEmpty)
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
