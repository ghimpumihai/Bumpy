import Foundation
import UserNotifications

/// Local notifications for automatic trips (D59): "started" with a Cancel action, and "couldn't
/// start". Never a Stop action: Stop stays a 2 s hold in the app.
final class TripNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let startedCategory = "trip.autoStarted"
    static let cancelAction = "trip.cancel"
    static let sessionIdKey = "sessionId"

    private let center = UNUserNotificationCenter.current()
    /// Called on the main thread with the session ID of the trip to cancel.
    var onCancel: ((String) -> Void)?

    override init() {
        super.init()
        // Unlock required: a pocket or a passenger's tap must not cancel a real trip.
        let cancel = UNNotificationAction(identifier: Self.cancelAction, title: "Cancel trip",
                                          options: [.destructive, .authenticationRequired])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.startedCategory, actions: [cancel], intentIdentifiers: [], options: []),
        ])
        // Must be set before the app finishes launching, or an action that relaunches the app is lost.
        center.delegate = self
    }

    func requestPermission(_ completion: @escaping (Bool) -> Void) {
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    func status(_ completion: @escaping (UNAuthorizationStatus) -> Void) {
        center.getNotificationSettings { s in DispatchQueue.main.async { completion(s.authorizationStatus) } }
    }

    func postStarted(sessionId: String) {
        let c = UNMutableNotificationContent()
        c.title = "Trip started automatically"
        c.body = "Recording your drive. Not a trip? Press and hold this, then Cancel trip."
        c.categoryIdentifier = Self.startedCategory
        c.userInfo = [Self.sessionIdKey: sessionId]
        center.add(UNNotificationRequest(identifier: "trip.started.\(sessionId)", content: c, trigger: nil))
    }

    func postBlocked(reason: String) {
        let c = UNMutableNotificationContent()
        c.title = "Trip not started"
        c.body = reason
        center.add(UNNotificationRequest(identifier: "trip.blocked", content: c, trigger: nil))
    }

    func removeStarted(sessionId: String) {
        center.removeDeliveredNotifications(withIdentifiers: ["trip.started.\(sessionId)"])
    }

    // MARK: UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo[Self.sessionIdKey] as? String
        DispatchQueue.main.async { [weak self] in
            if response.actionIdentifier == Self.cancelAction, let id { self?.onCancel?(id) }
            completionHandler()
        }
    }
}
