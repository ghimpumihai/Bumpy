import Foundation
import UIKit

enum AppInfo {
    /// `1.0.0 (1) 3f2a9c1` — marketing version, build, git commit stamped at build time.
    static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let v = info["CFBundleShortVersionString"] as? String ?? "?"
        let b = info["CFBundleVersion"] as? String ?? "?"
        let sha = info["GitCommit"] as? String ?? "unknown"
        return "\(v) (\(b)) \(sha)"
    }

    /// Hardware identifier, e.g. `iPhone15,2`.
    static var modelIdentifier: String {
        if let sim = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return sim }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    static var modelName: String {
        let known: [String: String] = [
            "iPhone15,2": "iPhone 14 Pro", "iPhone15,3": "iPhone 14 Pro Max",
            "iPhone14,7": "iPhone 14", "iPhone14,8": "iPhone 14 Plus",
            "iPhone15,4": "iPhone 15", "iPhone15,5": "iPhone 15 Plus",
            "iPhone16,1": "iPhone 15 Pro", "iPhone16,2": "iPhone 15 Pro Max",
            "iPhone17,1": "iPhone 16 Pro", "iPhone17,2": "iPhone 16 Pro Max",
            "iPhone17,3": "iPhone 16", "iPhone17,4": "iPhone 16 Plus",
        ]
        let id = modelIdentifier
        let name = known[id] ?? UIDevice.current.model
        return isSimulator ? "\(name) (Simulator)" : name
    }

    static var deviceInfo: SessionMetadata.Device {
        .init(model: modelIdentifier, name: modelName, iosVersion: UIDevice.current.systemVersion)
    }

    static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    static var arguments: [String] { ProcessInfo.processInfo.arguments }
    static var isUITesting: Bool { arguments.contains("-uiTesting") }
}
