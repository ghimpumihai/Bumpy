import CoreLocation
import Foundation
import Observation

/// One CLLocationManager for the app (created on the main thread, so delegate callbacks arrive on
/// main). Serves both the preflight screen (live fix / permission state) and the recorder.
@Observable
final class LocationService: NSObject, LocationSource, CLLocationManagerDelegate {
    private(set) var authorization: CLAuthorizationStatus = .notDetermined
    private(set) var accuracyAuthorization: CLAccuracyAuthorization = .reducedAccuracy
    private(set) var latest: LocationSample?
    private(set) var latestFixUptime: TimeInterval?
    private(set) var lastError: String?

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var recordingCallbacks: LocationCallbacks?
    @ObservationIgnored private var previewActive = false
    /// Auto-start (D59): every fix, in any mode (significant changes included), also goes here (main thread).
    @ObservationIgnored var fixObserver: ((LocationSample) -> Void)?
    @ObservationIgnored private var watchActive = false
    @ObservationIgnored private(set) var significantChangesActive = false

    override init() {
        super.init()
        manager.delegate = self
        // Spec §3.2 L1 settings
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .automotiveNavigation
        manager.pausesLocationUpdatesAutomatically = false
        manager.headingFilter = kCLHeadingFilterNone
        authorization = manager.authorizationStatus
        accuracyAuthorization = manager.accuracyAuthorization
    }

    var isAuthorized: Bool { authorization == .authorizedWhenInUse || authorization == .authorizedAlways }
    var isFullAccuracy: Bool { accuracyAuthorization == .fullAccuracy }
    var isAlways: Bool { authorization == .authorizedAlways }

    static let alwaysAskedKey = "location.alwaysAsked"

    /// iOS shows the "Always" prompt once; after that only the Settings app can change it.
    var canAskForAlways: Bool {
        authorization == .notDetermined
            || (authorization == .authorizedWhenInUse && !UserDefaults.standard.bool(forKey: Self.alwaysAskedKey))
    }

    /// Asks for "Always" (auto-start, D59). From "not determined" iOS first offers While Using and
    /// upgrades later; from While Using it shows the upgrade prompt once.
    func requestAlways() {
        UserDefaults.standard.set(manager.authorizationStatus == .authorizedWhenInUse, forKey: Self.alwaysAskedKey)
        manager.requestAlwaysAuthorization()
    }

    /// Relaunches a suspended or terminated app after ~500 m of movement (not after a force-quit).
    func startSignificantChanges() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard isAlways, CLLocationManager.significantLocationChangeMonitoringAvailable() else { return }
        significantChangesActive = true
        manager.startMonitoringSignificantLocationChanges()
    }

    func stopSignificantChanges() {
        dispatchPrecondition(condition: .onQueue(.main))
        significantChangesActive = false
        manager.stopMonitoringSignificantLocationChanges()
    }

    /// Full-rate GPS for the auto-start monitor, kept running in the background.
    func startWatch() {
        dispatchPrecondition(condition: .onQueue(.main))
        watchActive = true
        if isAuthorized {
            manager.allowsBackgroundLocationUpdates = true
            manager.showsBackgroundLocationIndicator = true
        }
        startUpdates()
    }

    func stopWatch() {
        dispatchPrecondition(condition: .onQueue(.main))
        watchActive = false
        if recordingCallbacks == nil {
            if isAuthorized { manager.allowsBackgroundLocationUpdates = false }
            if !previewActive { stopUpdates() }
        }
    }

    var isWatching: Bool { watchActive }

    func requestPermission() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            requestFullAccuracyIfNeeded()
        default:
            break
        }
    }

    private func requestFullAccuracyIfNeeded() {
        guard manager.accuracyAuthorization == .reducedAccuracy else { return }
        manager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: "RoadMapping") { [weak self] _ in
            DispatchQueue.main.async { self?.refreshAuthorization() }
        }
    }

    private func refreshAuthorization() {
        authorization = manager.authorizationStatus
        accuracyAuthorization = manager.accuracyAuthorization
    }

    /// Live updates for the preflight screen (GPS fix check).
    func startPreview() {
        previewActive = true
        startUpdates()
    }

    func stopPreview() {
        previewActive = false
        if recordingCallbacks == nil && !watchActive { stopUpdates() }
    }

    func startRecording(_ callbacks: LocationCallbacks) {
        dispatchPrecondition(condition: .onQueue(.main))
        recordingCallbacks = callbacks
        if isAuthorized {
            // Requires UIBackgroundModes=location; keeps GPS (and the app) alive in the background.
            manager.allowsBackgroundLocationUpdates = true
            manager.showsBackgroundLocationIndicator = true
        }
        startUpdates()
        if CLLocationManager.headingAvailable() { manager.startUpdatingHeading() }
    }

    func stopRecording() {
        dispatchPrecondition(condition: .onQueue(.main))
        recordingCallbacks = nil
        manager.stopUpdatingHeading()
        if !watchActive {
            if isAuthorized { manager.allowsBackgroundLocationUpdates = false }
            if !previewActive { stopUpdates() }
        }
    }

    private func startUpdates() {
        guard isAuthorized else { return }
        manager.startUpdatingLocation()
    }

    private func stopUpdates() {
        manager.stopUpdatingLocation()
    }

    // MARK: CLLocationManagerDelegate (main thread)

    /// While recording: why location data is degraded (shown as PROBLEM on the dashboard).
    var degradedReason: String? {
        guard recordingCallbacks != nil else { return nil }
        if !isAuthorized { return "Location permission revoked: Settings → Bumpy → Location" }
        if !isFullAccuracy { return "Precise Location is OFF: GPS is approximate" }
        return nil
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let before = (authorization, accuracyAuthorization)
        refreshAuthorization()
        if recordingCallbacks != nil, before != (authorization, accuracyAuthorization) {
            recordingCallbacks?.error("location authorization changed: status \(authorization.rawValue), " +
                                      (isFullAccuracy ? "precise" : "APPROXIMATE"))
        }
        if isAuthorized {
            requestFullAccuracyIfNeeded()
            if previewActive || recordingCallbacks != nil || watchActive {
                if recordingCallbacks != nil || watchActive {
                    manager.allowsBackgroundLocationUpdates = true
                    manager.showsBackgroundLocationIndicator = true
                }
                startUpdates()
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let now = ProcessInfo.processInfo.systemUptime
        for loc in locations {
            let s = Self.sample(from: loc)
            recordingCallbacks?.location(s)
            fixObserver?(s)
            // Freshness is based on the fix's own timestamp: the first delivery is often a cached,
            // minutes-old fix. Invalid fixes (hAcc < 0) don't count as a fix.
            if loc.horizontalAccuracy >= 0 {
                latest = s
                latestFixUptime = now - max(0, Date().timeIntervalSince(loc.timestamp))
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        recordingCallbacks?.heading(HeadingSample(
            utcMs: newHeading.timestamp.timeIntervalSince1970 * 1000,
            magneticHeading: newHeading.magneticHeading, trueHeading: newHeading.trueHeading,
            accuracy: newHeading.headingAccuracy,
            raw: Vec3(x: newHeading.x, y: newHeading.y, z: newHeading.z)))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // kCLErrorLocationUnknown is transient ("no fix yet") — keep going.
        if let e = error as? CLError, e.code == .locationUnknown { return }
        lastError = error.localizedDescription
        recordingCallbacks?.error("location: \(error.localizedDescription)")
    }

    func locationManagerShouldDisplayHeadingCalibration(_ manager: CLLocationManager) -> Bool { false }

    static func sample(from loc: CLLocation) -> LocationSample {
        LocationSample(
            utcMs: loc.timestamp.timeIntervalSince1970 * 1000,
            lat: loc.coordinate.latitude, lon: loc.coordinate.longitude,
            alt: loc.altitude, ellAlt: loc.ellipsoidalAltitude,
            hAcc: loc.horizontalAccuracy, vAcc: loc.verticalAccuracy,
            speed: loc.speed, speedAcc: loc.speedAccuracy,
            course: loc.course, courseAcc: loc.courseAccuracy,
            isSimulated: loc.sourceInformation?.isSimulatedBySoftware)
    }
}
