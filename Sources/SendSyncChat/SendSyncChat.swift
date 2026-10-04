import Foundation
#if canImport(UIKit)
import UIKit
import UserNotifications
#endif

/// SendSync live chat for iOS apps.
///
/// ```swift
/// // 1. At launch
/// SendSyncChat.configure(widgetKey: "chw_…")
///
/// // 2. Show the chat (SwiftUI)
/// .sheet(isPresented: $showChat) { SendSyncChatView() }
/// //    …or UIKit
/// SendSyncChat.present(from: self)
///
/// // 3. Optional: signed-in users (signature comes from YOUR server)
/// SendSyncChat.identify(userId: user.id, signature: sig, name: user.name, email: user.email)
/// SendSyncChat.logout()
///
/// // 4. Optional: push notifications
/// SendSyncChat.setDeviceToken(deviceToken)            // in didRegisterForRemoteNotificationsWithDeviceToken
/// SendSyncChat.handleNotification(userInfo)           // when a notification is tapped
/// ```
@MainActor
public enum SendSyncChat {
    public static let sdkVersion = "1.0.0"

    /// Which APNs environment this build's device token belongs to. Debug
    /// builds run from Xcode use the sandbox; TestFlight and App Store builds
    /// use production. Set explicitly if your setup differs.
    public enum PushEnvironment: String { case production, sandbox }

    #if DEBUG
    public static var pushEnvironment: PushEnvironment = .sandbox
    #else
    public static var pushEnvironment: PushEnvironment = .production
    #endif

    /// The configured session; nil until `configure` is called.
    public private(set) static var session: ChatSession?

    static var deviceTokenHex: String?
    /// Kept here too so `identify` works before or after `configure`.
    private static var identity: ChatIdentity?

    /// Set up chat for one widget. `host` is where SendSync runs for you
    /// (defaults to https://sendsync.com).
    public static func configure(widgetKey: String, host: URL = URL(string: "https://sendsync.com")!) {
        precondition(widgetKey.hasPrefix("chw_"), "SendSyncChat: widgetKey should start with chw_ (copy it from Live chat → your widget → Install → iOS app)")
        if session?.api.widgetKey == widgetKey && session?.api.host == host { return }
        session = ChatSession(api: APIClient(host: host, widgetKey: widgetKey), identity: identity)
    }

    /// Tell SendSync who the signed-in user is. `signature` is
    /// hex(HMAC-SHA256(identity secret, userId)), computed on your server —
    /// never put the secret in the app. Their chats then follow them across
    /// devices, and agents see them as verified.
    /// `attributes` are display-only facts for the agent to see, e.g.
    /// ["Next trip": "AUS→DAL Oct 8"]. They are never trusted for anything —
    /// only `signature` proves who this is.
    public static func identify(
        userId: String,
        signature: String,
        name: String? = nil,
        email: String? = nil,
        attributes: [String: String]? = nil
    ) {
        let newIdentity = ChatIdentity(
            userId: userId, signature: signature,
            name: name, email: email, attributes: attributes
        )
        identity = newIdentity
        session?.setIdentity(newIdentity)
        // Registering here, rather than only when a chat is open, is what lets
        // staff start a conversation and have it reach the phone.
        if let session, deviceTokenHex != nil {
            Task { await session.registerDeviceIfPossible() }
        }
    }

    /// Messages the signed-in user has not read, across all their chats.
    /// Badge your own "Chat with us" button with this, and observe
    /// ``unreadCountDidChange`` (or `session`, which is `ObservableObject`)
    /// to keep it current.
    public static var unreadCount: Int { session?.unreadCount ?? 0 }

    /// Posted when ``unreadCount`` changes. `userInfo["unreadCount"]` is the
    /// new value.
    public static let unreadCountDidChange = Notification.Name("SendSyncChat.unreadCountDidChange")

    /// Call when the user signs out: stops push to this phone for their chats
    /// and clears the chat from this device.
    public static func logout() {
        identity = nil
        guard let session else { return }
        Task {
            await session.unregisterDevice()
            session.setIdentity(nil)
            session.reset()
        }
    }

    /// Pass the token from `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`.
    public static func setDeviceToken(_ token: Data) {
        deviceTokenHex = token.map { String(format: "%02x", $0) }.joined()
        // Registers against the signed-in user when there is one, so it works
        // with no conversation open — which is the case that matters, because
        // a staff-started chat has nothing to register against yet.
        if let session { Task { await session.registerDeviceIfPossible() } }
    }

    /// Ask for notification permission and register with APNs. Call at a
    /// moment that makes sense to your users (e.g. after their first message).
    public static func requestPushPermission() {
        #if canImport(UIKit)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() }
        }
        #endif
    }

    /// True if this notification came from SendSync chat. When it does, the
    /// chat it belongs to becomes the current one — show `SendSyncChatView`
    /// (or call `present(from:)`) to open it.
    @discardableResult
    public static func handleNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard let payload = userInfo["sendsync"] as? [String: Any],
              let conversationId = payload["conversationId"] as? String else { return false }
        if let widgetKey = payload["widgetKey"] as? String, widgetKey != session?.api.widgetKey { return false }
        session?.open(conversationId: conversationId)
        return true
    }
}
