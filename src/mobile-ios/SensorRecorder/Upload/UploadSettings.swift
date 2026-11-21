import Foundation
import Security
import UIKit

/// Upload configuration entered at runtime (spec §6: never hard-coded in the repo).
/// Base URL lives in UserDefaults; the device key lives in the Keychain.
struct UploadConfig: Equatable, Sendable {
    var baseURL: URL?
    var deviceKey: String

    var isEnabled: Bool { baseURL != nil }

    /// Spec §6: the ingest route, relative to the base URL.
    static let ingestPath = "api/ingest"

    var ingestURL: URL? { baseURL?.appendingPathComponent(Self.ingestPath) }
    /// Spec §6.1: `PUT {API}/api/ingest/sessions/{sessionId}`.
    func sessionURL(_ sessionId: String) -> URL? {
        baseURL?.appendingPathComponent(Self.ingestPath).appendingPathComponent("sessions").appendingPathComponent(sessionId)
    }

    static let disabled = UploadConfig(baseURL: nil, deviceKey: "")

    /// Accepts `https://host[:port][/path]` (trailing slash ignored). Empty / invalid -> nil (= upload off).
    /// A pasted full endpoint (`…/api/ingest`) is reduced to its base, because `ingestURL` and
    /// `sessionURL` append `api/ingest` themselves (otherwise every request would 404).
    static func parseBaseURL(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        let endpointPath = "/" + ingestPath
        if let pasted = URL(string: s), pasted.query == nil, pasted.fragment == nil,
           pasted.path.lowercased().hasSuffix(endpointPath), s.lowercased().hasSuffix(endpointPath) {
            s.removeLast(endpointPath.count)
            while s.hasSuffix("/") { s.removeLast() }
        }
        guard !s.isEmpty, let url = URL(string: s),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil,          // no credentials in the URL
              url.query == nil, url.fragment == nil else { return nil }
        // Plain http would send x-device-key in cleartext: allow it only for local test servers.
        if scheme == "http" && !isLocalHost(host) { return nil }
        return url
    }

    /// localhost, loopback, RFC 1918 private IPv4, link-local, or mDNS `.local` names.
    /// IPv4 must be an exact dotted quad: `192.168.1.1.attacker.com` or `+10.0.0.1` are NOT local.
    static func isLocalHost(_ host: String) -> Bool {
        let h = host.lowercased()
        if h == "localhost" || h == "::1" || h == "[::1]" { return true }
        if h.hasSuffix(".local"), h.count > ".local".count,
           h.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." }) { return true }
        let labels = h.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count == 4 else { return false }
        var octets: [Int] = []
        for l in labels {
            // digits only, no sign/whitespace/leading zeros (octal ambiguity), 0...255
            guard !l.isEmpty, l.count <= 3, l.allSatisfy({ $0.isASCII && $0.isNumber }),
                  l == "0" || !l.hasPrefix("0"), let v = Int(l), v <= 255 else { return false }
            octets.append(v)
        }
        switch (octets[0], octets[1]) {
        case (127, _), (10, _), (192, 168), (169, 254): return true
        case (172, let b) where (16...31).contains(b): return true
        default: return false
        }
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

    /// Raw road-noise audio kept on the phone. Off by default (GDPR: other people in the vehicle).
    static let roadNoiseKey = "recording.roadNoise"
    static var recordRoadNoise: Bool {
        get { UserDefaults.standard.bool(forKey: roadNoiseKey) }
        set { UserDefaults.standard.set(newValue, forKey: roadNoiseKey) }
    }

    /// Web dashboard address for the menu and recap links; links are hidden while it is unset.
    /// Settable with the launch argument `-dashboard.baseURL <url>`.
    // HACKATHON: hard-code the `dashboard_url` Terraform output here once it is stable.
    static var dashboardURL: URL? {
        guard let s = UserDefaults.standard.string(forKey: "dashboard.baseURL"), !s.isEmpty else { return nil }
        return URL(string: s)
    }

    /// Stable per-install id (identifierForVendor, persisted so it never changes mid-session).
    /// Stable per-install, per-device id. Kept in the Keychain as *ThisDeviceOnly*, so restoring a
    /// backup onto another phone can't give two phones the same id (UserDefaults would be copied).
    static var deviceId: String {
        if let s = Keychain.read(service: keychainService, account: deviceIdKey) { return s }
        // Migrate an id written by an older version, otherwise create one.
        let id = UserDefaults.standard.string(forKey: deviceIdKey)
            ?? (UIDevice.current.identifierForVendor ?? UUID()).uuidString
        Keychain.write(id, service: keychainService, account: deviceIdKey)
        UserDefaults.standard.removeObject(forKey: deviceIdKey)
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
