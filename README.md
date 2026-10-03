# SendSync Chat for iOS

Add SendSync live chat to your iPhone/iPad app: a ready-made chat screen,
your team picker (Sales / Support / …), push notifications when an agent
replies, and chats that follow signed-in users across devices.

Requires iOS 15+, Swift 5.9+ (Xcode 15+).

## 1. Add the package

Xcode → **File → Add Package Dependencies…** → paste:

```
https://github.com/SendSync/sendsync-chat-ios
```

and add the **SendSyncChat** library to your app target.

## 2. Configure and show the chat

Copy your widget key from SendSync → **Live chat → your widget → Install → iOS app**.

```swift
import SendSyncChat

@main
struct MyApp: App {
    init() {
        SendSyncChat.configure(widgetKey: "chw_…")
    }
    var body: some Scene { WindowGroup { ContentView() } }
}

struct ContentView: View {
    @State private var showChat = false
    var body: some View {
        Button("Chat with us") { showChat = true }
            .sheet(isPresented: $showChat) { SendSyncChatView() }
    }
}
```

UIKit: `SendSyncChat.present(from: self)`.

If your SendSync runs somewhere other than sendsync.com, pass it:
`SendSyncChat.configure(widgetKey: "chw_…", host: URL(string: "https://support.example.com")!)`.

That's all you need for anonymous chat. Steps 3 and 4 are optional.

## 3. Signed-in users (recommended)

Turn on **Identify signed-in users** for the widget in SendSync and copy the
secret **to your server** (never into the app). Your server signs the user's
id, and the app passes that signature along:

```swift
// after your user signs in — `signature` comes from your server
SendSyncChat.identify(userId: user.id, signature: signature, name: user.name, email: user.email)

// when they sign out
SendSyncChat.logout()
```

Server side — `signature = hex(HMAC-SHA256(secret, userId))`:

```js
// Node
crypto.createHmac("sha256", process.env.SENDSYNC_CHAT_SECRET).update(user.id).digest("hex")
```
```python
# Python
hmac.new(os.environ["SENDSYNC_CHAT_SECRET"].encode(), user_id.encode(), hashlib.sha256).hexdigest()
```
```ruby
# Ruby
OpenSSL::HMAC.hexdigest("SHA256", ENV["SENDSYNC_CHAT_SECRET"], user.id.to_s)
```

Agents then see the user as verified, and their chat continues on any device
they sign in on.

## 4. Push notifications

1. In SendSync → your widget → **Install → iOS app → Push notifications**,
   upload your APNs key (`.p8`) with its Key ID, your Team ID and your app's
   bundle id.
2. In Xcode, add the **Push Notifications** capability.
3. Hand SendSync the device token and tapped notifications:

```swift
class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        SendSyncChat.requestPushPermission()   // or call it at a better moment
        return true
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        SendSyncChat.setDeviceToken(deviceToken)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        if SendSyncChat.handleNotification(response.notification.request.content.userInfo) {
            // open your chat screen (e.g. set showChat = true)
        }
    }
}
```

(SwiftUI apps: attach it with `@UIApplicationDelegateAdaptor(AppDelegate.self)`.)

Debug builds run from Xcode register with Apple's **sandbox**; TestFlight and
App Store builds use **production**. Choose the matching environment in
SendSync, or set `SendSyncChat.pushEnvironment` yourself.
