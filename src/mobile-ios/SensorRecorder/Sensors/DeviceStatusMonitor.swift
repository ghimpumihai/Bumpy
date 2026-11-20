import Foundation
import Network
import UIKit

/// Battery, thermal state, Low Power Mode, free disk and network reachability (D1–D5).
/// `currentStatus()` is cheap and thread-safe; UIKit battery values are cached from the main thread.
final class DeviceStatusMonitor: DeviceStatusSource {
    private let pathMonitor = NWPathMonitor()
    private let net = Locked<(status: String, type: String)>(("unknown", "none"))
    private let battery = Locked<(level: Float, state: String)>((-1, "unknown"))
    private let disk = Locked<(bytes: Int64, at: TimeInterval)>((-1, 0))
    private var observers: [NSObjectProtocol] = []

    init() {
        pathMonitor.pathUpdateHandler = { [net] path in
            let status: String
            switch path.status {
            case .satisfied: status = "satisfied"
            case .unsatisfied: status = "unsatisfied"
            case .requiresConnection: status = "requiresConnection"
            @unknown default: status = "unknown"
            }
            let type: String
            if path.usesInterfaceType(.wifi) { type = "wifi" }
            else if path.usesInterfaceType(.cellular) { type = "cellular" }
            else if path.usesInterfaceType(.wiredEthernet) { type = "wired" }
            else if path.status == .satisfied { type = "other" }
            else { type = "none" }
            net.withLock { $0 = (status, type) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "sensorrecorder.netmonitor", qos: .utility))

        let setup = { [weak self] in
            guard let self else { return }
            UIDevice.current.isBatteryMonitoringEnabled = true
            self.refreshBattery()
            let nc = NotificationCenter.default
            self.observers.append(nc.addObserver(forName: UIDevice.batteryLevelDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.refreshBattery() })
            self.observers.append(nc.addObserver(forName: UIDevice.batteryStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.refreshBattery() })
        }
        if Thread.isMainThread { setup() } else { DispatchQueue.main.async(execute: setup) }
    }

    deinit {
        pathMonitor.cancel()
        for o in observers { NotificationCenter.default.removeObserver(o) }
    }

    /// Must run on main (UIDevice).
    func refreshBattery() {
        let d = UIDevice.current
        let state: String
        switch d.batteryState {
        case .unplugged: state = "unplugged"
        case .charging: state = "charging"
        case .full: state = "full"
        default: state = "unknown"
        }
        battery.withLock { $0 = (d.batteryLevel, state) }
    }

    func currentStatus() -> DeviceStatus {
        let b = battery.current
        let n = net.current
        let info = ProcessInfo.processInfo
        return DeviceStatus(batteryLevel: b.level, batteryState: b.state,
                            thermal: ThermalLevel(info.thermalState),
                            lowPowerMode: info.isLowPowerModeEnabled,
                            freeDiskBytes: freeDisk(),
                            networkStatus: n.status, networkType: n.type)
    }

    /// Free-space queries hit the filesystem; cache for 2 s (dashboard refreshes at 8 Hz).
    private func freeDisk() -> Int64 {
        let now = ProcessInfo.processInfo.systemUptime
        let cached = disk.current
        if cached.bytes >= 0, now - cached.at < 2 { return cached.bytes }
        let v = FileManager.default.freeDiskBytes()
        disk.withLock { $0 = (v, now) }
        return v
    }
}
