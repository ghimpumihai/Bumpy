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

    private func startRecording() {
        let newSession = app.buttons["newSessionButton"]
        XCTAssertTrue(newSession.waitForExistence(timeout: 10))
        newSession.tap()

        let cont = app.buttons["setupContinue"]
        XCTAssertTrue(cont.waitForExistence(timeout: 5))
        cont.tap()

        // Preflight runs a 5 s motion test. The Simulator has no motion hardware, so the motion
        // checks fail and the (recorded) override path is used; Start/Override wait for all checks.
        let start = app.buttons["startRecording"]
        let override = app.buttons["preflightOverride"]
        let deadline = Date().addingTimeInterval(40)
        while Date() < deadline && !(start.exists && start.isEnabled) && !(override.exists && override.isEnabled) {
            // Tap the status-bar band (never a control) so interruption monitors can fire.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01)).tap()
            usleep(500_000)
        }
        XCTAssertTrue(app.descendants(matching: .any)["check.motion.still"].exists)
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
        XCTAssertTrue(misc3.waitForNonExistence(timeout: 3), "grid closes after rating")

        // Scheduled sickness prompt (every 40 s here) with countdown; answer it
        let countdown = app.staticTexts["sicknessCountdown"]
        XCTAssertTrue(countdown.waitForExistence(timeout: 45), "periodic prompt appears")
        app.buttons["misc.2"].tap()
        XCTAssertTrue(countdown.waitForNonExistence(timeout: 3), "prompt closes after rating")

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
        // The share was dismissed, not completed: it does not count as an export, so Done asks first.
        // (Retry once in case the first tap only closed the sheet.)
        let closeAnyway = app.buttons["closeWithoutExport"].firstMatch
        done.tap()
        if !closeAnyway.waitForExistence(timeout: 3), done.exists { done.tap() }
        XCTAssertTrue(closeAnyway.waitForExistence(timeout: 5), "a cancelled share is not an export")
        closeAnyway.tap()
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
        XCTAssertTrue(countdown.waitForNonExistence(timeout: 6), "unanswered prompt auto-dismisses (missed)")
        // Next prompt: Skip must close it without a rating
        XCTAssertTrue(countdown.waitForExistence(timeout: 10))
        app.buttons["sicknessSkip"].tap()
        XCTAssertTrue(countdown.waitForNonExistence(timeout: 3))
        sleep(2) // let some GPS fixes land on disk

        app.terminate() // simulates a crash / force-quit while recording
        app.launchArguments = ["-uiTesting"]
        app.launch()
        XCTAssertTrue(app.staticTexts["RECOVERED"].waitForExistence(timeout: 10), "interrupted session is recovered")
        let session = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'session.'")).firstMatch
        session.tap()
        // Assert on data this test itself created (labels: prompt, missed, prompt, skipped), not on
        // environment-dependent streams (the Simulator has no motion hardware and its simulated
        // location is cleared on reboot).
        let labels = app.descendants(matching: .any)["stat.labelsCount"]
        for _ in 0..<8 where !labels.exists { app.swipeUp() }
        XCTAssertTrue(labels.waitForExistence(timeout: 5), "stats rebuilt from the CSV files")
        let count = Int(labels.value as? String ?? "") ?? 0
        XCTAssertGreaterThanOrEqual(count, 4, "labels recorded before the kill survived recovery: \(labels.value ?? "nil")")
    }

    func testSettingsShowsUploadOffWhenEmpty() {
        launch(["-upload.baseURL", ""]) // later argument wins: no API URL
        let settings = app.buttons["settingsButton"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        XCTAssertTrue(app.staticTexts["UPLOAD OFF (local only)"].waitForExistence(timeout: 5))
    }

    /// Spec §3.5/§3.8: choosing bus/tram turns audio recording OFF by default and asks for the line.
    func testPublicTransportDefaultsAudioOffAndAsksForLine() {
        launch()
        let newSession = app.buttons["newSessionButton"]
        XCTAssertTrue(newSession.waitForExistence(timeout: 10))
        newSession.tap()
        let audio = app.switches["audioToggle"]
        for _ in 0..<6 where !audio.exists { app.swipeUp() }
        XCTAssertEqual(audio.value as? String, "1", "car: audio on")
        for _ in 0..<6 { app.swipeDown() }
        let typePicker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Type'")).firstMatch
        XCTAssertTrue(typePicker.waitForExistence(timeout: 5))
        typePicker.tap()
        let bus = app.buttons["bus"].firstMatch
        XCTAssertTrue(bus.waitForExistence(timeout: 5))
        bus.tap()
        XCTAssertTrue(app.textFields["vehicleLine"].waitForExistence(timeout: 3), "line number field for bus")
        for _ in 0..<6 where !audio.isHittable { app.swipeUp() }
        XCTAssertEqual(audio.value as? String, "0", "bus: audio recording OFF by default (GDPR)")
    }
}

extension XCUIElement {
    func waitForHittable(timeout: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if exists && isHittable { return true }; usleep(200_000) }
        return false
    }

    /// Polls until the element is gone (XCTAssertFalse(waitForExistence) passes instantly while an
    /// element is still animating out).
    func waitForNonExistence(timeout: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if !exists { return true }; usleep(100_000) }
        return !exists
    }

    func waitForEnabled(timeout: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if exists && isEnabled { return true }; usleep(200_000) }
        return false
    }
}
