import Foundation
import Security
import UIKit

/// Upload configuration entered at runtime (spec §6: never hard-coded in the repo).
/// Base URL lives in UserDefaults; the device key lives in the Keychain.
struct UploadConfig: Equatable, Sendable {
    var baseURL: URL?
    var deviceKey: String

    var isEnabled: Bool { baseURL != nil }

    var ingestURL: URL? { baseURL?.appendingPathComponent("api/ingest") }
    var healthURL: URL? { baseURL?.appendingPathComponent("api/health") }

    static let disabled = UploadConfig(baseURL: nil, deviceKey: "")

    /// Accepts `https://host[:port][/path]` (trailing slash ignored). Empty / invalid -> nil (= upload off).
    static func parseBaseURL(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        guard !s.isEmpty, let url = URL(string: s),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }
}

enum AppSettings {
    private static let baseURLKey = "upload.baseURL"
    private static let deviceIdKey = "device.id"
    private static let keychainService = "com.chuds.sensorrecorder.upload"
    private static let keychainAccount = "deviceKey"

    static var baseURLString: String {
        get { UserDefaults.standard.string(forKey: baseURLKey) ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: baseURLKey) }
    }

    static var deviceKey: String {
        get { Keychain.read(service: keychainService, account: keychainAccount) ?? "" }
        set {
            let v = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if v.isEmpty { Keychain.delete(service: keychainService, account: keychainAccount) }
            else { Keychain.write(v, service: keychainService, account: keychainAccount) }
        }
    }

    static var uploadConfig: UploadConfig {
        UploadConfig(baseURL: UploadConfig.parseBaseURL(baseURLString), deviceKey: deviceKey)
    }

    /// Stable per-install id (identifierForVendor, persisted so it never changes mid-session).
    static var deviceId: String {
        if let s = UserDefaults.standard.string(forKey: deviceIdKey) { return s }
        let id = (UIDevice.current.identifierForVendor ?? UUID()).uuidString
        UserDefaults.standard.set(id, forKey: deviceIdKey)
        return id
    }
}

enum Keychain {
    static func read(service: String, account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    @discardableResult
    static func write(_ value: String, service: String, account: String) -> Bool {
        delete(service: service, account: account)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                // Readable while locked after first unlock: uploads continue with the screen off.
                                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                                kSecValueData as String: Data(value.utf8)]
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    static func delete(service: String, account: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
    }
}
