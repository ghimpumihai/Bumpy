import Foundation
import os
import UIKit

/// Automatic trips (D59, 01 §7 "Automatic trips"): watches for driving, warms the sensors up, starts
/// and stops the trip, and handles Cancel from the notification. Main thread.
///
/// Armed → (driving, or a significant location change while in the background) candidate: full GPS
/// and the warm-up checks → start when `AutoTripRules.shouldStart` → recording → stop when
/// `shouldStop` → armed.
@MainActor
final class AutoTripMonitor {
    enum State: Equatable {
        case off, armed, candidate
        case recording(sessionId: String)
    }

    private(set) var state: State = .off
    let notifications = TripNotifications()

    private unowned let app: AppModel
    private var rules = AutoTripRules()
    private var activitySubscription: UUID?
    private var warmup: PreflightModel?
    private var detectedAt: Date?
    private var notCandidateSince: TimeInterval?
    /// After a blocked start: no new candidate before this uptime (one notification, not one per fix).
    private var blockedUntil: TimeInterval = 0
    /// After a location wake that wasn't a drive: the next one may probe again after this uptime.
    private var probeAfter: TimeInterval = 0

    /// A candidate that stops looking like a drive for this long goes back to armed.
    static let candidateGiveUpSeconds: TimeInterval = 180
    static let blockedCooldownSeconds: TimeInterval = 600
    static let probeCooldownSeconds: TimeInterval = 300

    init(app: AppModel) {
        self.app = app
        notifications.onCancel = { [weak self] id in self?.cancel(sessionId: id) }
    }

    private var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    // MARK: Arming

    /// What's missing before automatic trips can be turned on, as Settings shows it.
    func missingRequirements(notificationsAllowed: Bool) -> [String] {
        var missing: [String] = []
        if !app.location.isAlways { missing.append("location set to Always") }
        if app.location.isAuthorized && !app.location.isFullAccuracy { missing.append("Precise Location") }
        if MotionPermission.status != .authorized { missing.append("Motion & Fitness") }
        if !ActivityHub.shared.isAvailable { missing.append("motion activity (not on this iPhone)") }
        if !notificationsAllowed { missing.append("notifications") }
        return missing
    }

    func armIfEnabled() {
        guard AutoStartSettings.enabled else { return }
        arm()
    }

    func arm() {
        guard state == .off else { return }
        state = .armed
        app.location.fixObserver = { [weak self] fix in self?.handleFix(fix) }
        app.location.startSignificantChanges()
        activitySubscription = ActivityHub.shared.subscribe { [weak self] a in
            DispatchQueue.main.async { self?.handleActivity(a) }
        }
        // Relaunched by a location change: the activity before the app was woken.
        ActivityHub.shared.recent(seconds: AutoTripRules.startWindowSeconds) { list in
            DispatchQueue.main.async { [weak self] in list.forEach { self?.handleActivity($0) } }
        }
    }

    /// An automatic trip that is recording keeps recording (it then ends with the 2 s hold).
    func disarm() {
        endCandidate()
        app.location.fixObserver = nil
        app.location.stopSignificantChanges()
        if let id = activitySubscription { ActivityHub.shared.unsubscribe(id) }
        activitySubscription = nil
        state = .off
    }

    // MARK: Inputs

    private func handleActivity(_ a: ActivitySample) {
        guard state != .off else { return }
        // On the uptime clock, from the activity's own start date (history arrives late).
        let age = Date().timeIntervalSince1970 - a.startUtcMs / 1000
        rules.addActivity(t: uptime - max(0, age), a)
        evaluate(wokenByLocation: false)
    }

    private func handleFix(_ fix: LocationSample) {
        guard state != .off, fix.hAcc >= 0 else { return }
        let wasWatching = app.location.isWatching || app.recording.map { !$0.isFinished } == true
        rules.addFix(t: uptime, speed: fix.speed)
        evaluate(wokenByLocation: !wasWatching)
    }

    // MARK: State machine

    private var manualTripRunning: Bool {
        guard let rec = app.recording, !rec.isFinished else { return false }
        if case .recording(let id) = state, rec.session.id.uuidString == id { return false }
        return true
    }

    private func evaluate(wokenByLocation: Bool) {
        let now = uptime
        switch state {
        case .off:
            return
        case .armed:
            guard now >= blockedUntil, !manualTripRunning else { return }
            if rules.isCandidate(now: now) {
                beginCandidate()
            } else if wokenByLocation, now >= probeAfter, UIApplication.shared.applicationState != .active {
                // A significant location change woke the app; driving may not show in the activity yet.
                // In the foreground the Start screen's own GPS preview would trigger this every second.
                probeAfter = now + Self.probeCooldownSeconds
                beginCandidate()
            }
        case .candidate:
            if manualTripRunning {
                endCandidate()
                state = .armed
                return
            }
            if rules.isCandidate(now: now) {
                notCandidateSince = nil
            } else if notCandidateSince == nil {
                notCandidateSince = now
            }
            if let since = notCandidateSince, now - since > Self.candidateGiveUpSeconds {
                endCandidate()
                state = .armed
                return
            }
            guard let w = warmup, !w.busy else { return }
            if !w.autoBlockers.isEmpty {
                block(w.autoBlockers)
                return
            }
            if rules.shouldStart(now: now) { startTrip(w) }
        case .recording(let id):
            guard let rec = app.recording, rec.session.id.uuidString == id, !rec.isFinished else {
                state = .armed // stopped with the 2 s hold, or cancelled
                return
            }
            if rules.shouldStop(now: now) {
                rec.stop()
                rec.session.log(.info, "automatic trip stopped (D59)")
                state = .armed
                notifications.removeStarted(sessionId: id)
                closeIfUnseen()
            }
        }
    }

    private func beginCandidate() {
        state = .candidate
        notCandidateSince = nil
        detectedAt = Date()
        app.onLaunch() // a background relaunch: session recovery and the upload loop
        app.location.startWatch()
        let w = PreflightModel(app: app, auto: true)
        warmup = w
        w.onAppear()
    }

    private func endCandidate() {
        if let w = warmup {
            w.onDisappear()
            // onDisappear keeps the preview while a recording exists (a manual Start took over); the
            // recording keeps GPS on by itself, so the preview flag must not outlive it.
            app.location.stopPreview()
        }
        warmup = nil
        if app.location.isWatching { app.location.stopWatch() }
    }

    private func block(_ blockers: [PreflightModel.Check]) {
        let reason = blockers.map { "\($0.title): \($0.detail)" }.joined(separator: "\n")
        notifications.postBlocked(reason: reason)
        blockedUntil = uptime + Self.blockedCooldownSeconds
        endCandidate()
        state = .armed
    }

    private func startTrip(_ w: PreflightModel) {
        // A failing check doesn't stop the trip (a trip that never starts is lost): it is recorded.
        let result = w.result(overridden: !w.allRequiredPass)
        let detected = detectedAt ?? Date()
        endCandidate() // the recording takes over motion and location
        do {
            let session = try app.startAutoRecording(preflight: result, detectedAt: detected)
            rules.resetForTrip(startedAt: uptime)
            state = .recording(sessionId: session.id.uuidString)
            notifications.postStarted(sessionId: session.id.uuidString)
        } catch {
            appLogger.error("automatic trip could not start: \(error.localizedDescription, privacy: .public)")
            blockedUntil = uptime + 60 // recovery still running: try again shortly
            state = .armed
        }
    }

    /// Nobody saw the recap of a trip that ended in the background: don't let it block the next one.
    private func closeIfUnseen() {
        if UIApplication.shared.applicationState != .active { app.closeFinishedRecording() }
    }

    // MARK: Cancel

    /// From the notification. Within the upload hold the trip is deleted (nothing reached the cloud);
    /// after it, the trip is stopped and kept with `autoStart.cancelledAtUtc`.
    func cancel(sessionId: String) {
        let rec = app.recording.flatMap { $0.session.id.uuidString == sessionId ? $0 : nil }
        let queue = app.uploadQueue
        notifications.removeStarted(sessionId: sessionId)
        if case .recording(let id) = state, id == sessionId { state = .armed }

        if let left = queue.holdRemainingMs(sessionId: sessionId),
           left >= Int64(UploadQueue.discardMarginSeconds * 1000) {
            rec?.stop()
            if queue.discardHeldSession(sessionId: sessionId),
               let folder = rec?.session.folder ?? folder(of: sessionId) {
                app.deleteDiscardedAutoTrip(folder: folder, sessionId: sessionId)
                return
            }
            // The queue refused (something was acknowledged after all): the trip stays, uploads normally.
            rec?.session.log(.warn, "automatic trip cancelled, but part of it already reached the cloud: kept")
            closeIfUnseen()
            return
        }

        if let rec, !rec.isFinished {
            rec.session.markCancelled(at: Date())
            rec.stop()
        } else if let folder = folder(of: sessionId) {
            // Already stopped (or recovered after a relaunch): mark the local copy only.
            let url = folder.appendingPathComponent(SessionFileName.metadata)
            if var meta = try? SessionMetadata.load(from: url), meta.autoStart != nil {
                meta.autoStart?.cancelledAtUtc = ISO8601.string(Date())
                try? meta.write(to: url)
            }
        }
        closeIfUnseen()
    }

    private func folder(of sessionId: String) -> URL? {
        app.store.list().first { $0.metadata?.sessionId == sessionId }?.folder
    }
}
