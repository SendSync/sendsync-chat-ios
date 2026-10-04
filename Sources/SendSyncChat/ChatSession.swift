import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// The state behind the chat screen: widget settings, the visitor's current
/// chat, its messages, and sending/polling. One shared instance per
/// configured widget (`SendSyncChat.session`).
@MainActor
public final class ChatSession: ObservableObject {
    @Published public private(set) var config: ChatWidgetConfig?
    @Published public private(set) var messages: [ChatMessage] = []
    @Published public private(set) var status: String = "open"
    @Published public private(set) var conversationId: String?
    /// The team the visitor picked (or the only one offered).
    @Published public var selectedPipelineId: String?
    @Published public private(set) var isSending = false
    @Published public private(set) var isLoading = false
    @Published public var errorMessage: String?
    /// Messages the user has not read, across every conversation they have.
    /// Host apps badge their own "Chat with us" button with this.
    @Published public private(set) var unreadCount = 0 {
        didSet {
            guard unreadCount != oldValue else { return }
            NotificationCenter.default.post(
                name: SendSyncChat.unreadCountDidChange,
                object: nil,
                userInfo: ["unreadCount": unreadCount]
            )
        }
    }
    /// Their other open conversations, when there is more than one. Empty in
    /// the ordinary case, so a host app can ignore it until it is not.
    @Published public private(set) var otherOpenConversations: [ChatConversationSummary] = []
    /// The server would not accept the signature, so the chat has fallen back
    /// to anonymous. Almost always a mismatched identity secret.
    @Published public private(set) var identityRejected = false
    /// Why the last device registration did not happen, if it did not.
    ///
    /// Push failing is otherwise completely silent: no notification arrives and
    /// nothing says why. Surfaced so a developer integrating the SDK can see it
    /// rather than discovering it from a customer.
    @Published public private(set) var pushRegistrationError: String?

    let api: APIClient
    private(set) var identity: ChatIdentity?
    private var stored: StoredChat?
    private var lastId = 0
    /// How far we have told the server the user has read, so a poll that
    /// brings nothing new does not spend a request saying so again.
    private var readUpTo = 0
    /// Unread messages in the conversation on screen, tracked separately so
    /// marking it read subtracts the right amount from the total.
    private var unreadInCurrent = 0
    private var pollTask: Task<Void, Never>?
    private var visible = false

    struct StoredChat: Codable {
        let conversationId: String
        let token: String?
        let pipelineId: String?
    }

    init(api: APIClient, identity: ChatIdentity? = nil) {
        self.api = api
        self.identity = identity
        self.stored = KeychainStore.load(StoredChat.self, account: Self.account(api.widgetKey))
        self.conversationId = stored?.conversationId
        self.selectedPipelineId = stored?.pipelineId
    }

    private static func account(_ widgetKey: String) -> String { "chat." + widgetKey }

    // MARK: - derived state

    public var pipelines: [ChatPipelineInfo] { config?.pipelines ?? [] }

    public var selectedPipeline: ChatPipelineInfo? {
        if let id = selectedPipelineId, let p = pipelines.first(where: { $0.id == id }) { return p }
        return pipelines.count == 1 ? pipelines.first : nil
    }

    /// True while the visitor still has to choose between several teams.
    public var needsPipelineChoice: Bool {
        conversationId == nil && selectedPipeline == nil && pipelines.count > 1
    }

    public var isOnline: Bool { selectedPipeline?.online ?? config?.online ?? false }
    public var isIdentified: Bool { identity != nil }
    public var hasEnded: Bool { conversationId != nil && status == "closed" }

    /// The text shown at the top of the conversation.
    public var introText: String {
        let c = config
        if needsPipelineChoice { return c?.greeting ?? "Hi! Who would you like to talk to?" }
        if isOnline { return selectedPipeline?.greeting ?? c?.greeting ?? "Hi! How can we help?" }
        return selectedPipeline?.offlineMessage ?? c?.offlineMessage
            ?? "Leave a message and we'll get back to you by email."
    }

    private var auth: ChatAuth? {
        if let token = stored?.token { return .token(token) }
        if let identity { return .identity(identity) }
        return nil
    }

    // MARK: - lifecycle

    /// Load settings and the visitor's existing chat. Safe to call repeatedly.
    public func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            config = try await api.config()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Couldn't load chat"
            return
        }
        if let identity {
            await adoptLatestConversation(identity: identity)
        }
        await refresh()
        await registerDeviceIfPossible()
        await markReadIfVisible()
    }

    /// Pick up the conversation a signed-in user should be looking at.
    ///
    /// Three cases, and only the first used to work: a new phone or a fresh
    /// install, where there is nothing stored; a staff- or server-started
    /// conversation that arrived while this phone had an older one open; and
    /// several open at once, where the SDK keeps the newest and hands the rest
    /// to the host app rather than guessing.
    private func adoptLatestConversation(identity: ChatIdentity) async {
        let mine: MyConversations
        do {
            mine = try await api.myConversations(identity: identity)
        } catch {
            handleIfSignatureRejected(error)
            return
        }
        let open = mine.openConversations
        unreadCount = mine.conversations.reduce(0) { $0 + $1.unread }
        otherOpenConversations = open
            .filter { $0.conversationId != conversationId }
            .map(ChatConversationSummary.init)

        guard let latest = open.first else { return }
        if latest.conversationId == conversationId { return }

        // Only move to something strictly newer than what is on screen. A
        // conversation the user is in the middle of must not be yanked away by
        // an older one surfacing.
        if conversationId != nil {
            let currentAt = mine.conversations
                .first { $0.conversationId == conversationId }?.date
            if let currentAt, let latestAt = latest.date, latestAt <= currentAt { return }
        }
        adopt(StoredChat(conversationId: latest.conversationId, token: nil, pipelineId: latest.pipelineId))
        otherOpenConversations = open
            .filter { $0.conversationId != latest.conversationId }
            .map(ChatConversationSummary.init)
    }

    /// Switch to one of `otherOpenConversations`.
    public func select(conversationId id: String) {
        guard id != conversationId, identity != nil else { return }
        adopt(StoredChat(conversationId: id, token: nil, pipelineId: nil))
        Task {
            await refresh()
            await markReadIfVisible()
        }
    }

    /// Call when the chat appears / disappears; polls quickly only while visible.
    public func setVisible(_ isVisible: Bool) {
        visible = isVisible
        pollTask?.cancel()
        guard isVisible else { return }
        // Looking at it is reading it.
        Task { await markReadIfVisible() }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self, !Task.isCancelled else { return }
                if self.conversationId != nil && self.status != "closed" {
                    await self.refresh()
                } else if self.conversationId == nil {
                    // Keep "online / away" honest while the visitor decides.
                    if let c = try? await self.api.config() { self.config = c }
                }
            }
        }
    }

    /// Fetch new messages for the current chat.
    public func refresh() async {
        guard let id = conversationId, let auth else { return }
        do {
            let view = try await api.messages(conversationId: id, after: lastId, auth: auth)
            apply(view)
        } catch ChatError.server(let status, _) where status == 404 {
            // Chat gone or no longer ours (e.g. identity turned off): start fresh.
            reset()
        } catch {
            if handleIfSignatureRejected(error) { return }
            // Transient; the next poll retries.
        }
    }

    // MARK: - actions

    public func send(_ text: String, name: String? = nil, email: String? = nil) async {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, !isSending else { return }
        isSending = true
        errorMessage = nil
        defer { isSending = false }
        do {
            if let id = conversationId, let auth {
                apply(try await api.post(conversationId: id, body: body, after: lastId, auth: auth))
            } else {
                let started = try await api.start(
                    pipelineId: selectedPipeline?.id,
                    body: body,
                    name: name ?? identity?.name,
                    email: email ?? identity?.email,
                    identity: identity,
                    client: Self.clientInfo()
                )
                adopt(StoredChat(conversationId: started.conversationId, token: started.token, pipelineId: started.pipelineId))
                apply(ConversationView(status: started.status, messages: started.messages))
                await registerDeviceIfPossible()
            }
        } catch {
            if handleIfSignatureRejected(error) {
                // Anonymous now, and the composer will ask for a name and email.
                // What they typed is not lost; the caller still holds it.
                errorMessage = nil
                return
            }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Couldn't send"
        }
    }

    /// Forget the current chat (after it ended) so the visitor can start another.
    public func startNewChat() {
        reset()
    }

    // MARK: - identity & push (driven by SendSyncChat)

    /**
     Whether to ask the server again before concluding push is off.

     Any answer other than a confident "push is on" is treated as stale. A
     cached `false` is an answer from launch, and the APNs key may have been
     added since — believing it would leave the phone unregistered until the
     app was force-quit.
     */
    nonisolated static func shouldRefetchConfigBeforeRegistering(_ config: ChatWidgetConfig?) -> Bool {
        config?.features?.push != true
    }

    /// A 401 on an identity-authenticated call means one thing: the signature
    /// did not verify.
    nonisolated static func isSignatureRejection(_ error: Error) -> Bool {
        guard let chatError = error as? ChatError else { return false }
        if case .server(let status, _) = chatError { return status == 401 }
        return false
    }

    /**
     Fall back to anonymous after the server refuses the signature.

     Without this the chat is simply stuck: the composer hides the name and
     email fields for an identified user, and every send fails, so the person
     trying to ask a question has no way to ask it. A mismatched identity
     secret is the app's problem to fix, not theirs to be blocked by.

     A conversation adopted by signature has no token of its own and is no
     longer reachable, so it goes; one started anonymously still has its token
     and survives untouched.
     */
    func rejectIdentity(_ reason: String) {
        guard !identityRejected else { return }
        identityRejected = true
        identity = nil
        SendSyncChat.warn(
            "the user signature was rejected (\(reason)). Check that it is "
                + "hex(HMAC-SHA256(identity secret, userId)) and that the secret matches this "
                + "widget's. Falling back to anonymous chat."
        )
        if stored?.token == nil {
            reset()
        }
        errorMessage = nil
        unreadCount = 0
        otherOpenConversations = []
    }

    /// Returns true when the error was an identity rejection and was handled.
    @discardableResult
    func handleIfSignatureRejected(_ error: Error) -> Bool {
        guard identity != nil, Self.isSignatureRejection(error) else { return false }
        rejectIdentity((error as? LocalizedError)?.errorDescription ?? "401")
        return true
    }

    func setIdentity(_ newValue: ChatIdentity?) {
        if newValue?.userId != identity?.userId {
            // A different person: never show them the previous user's chat.
            reset()
        }
        // A new signature deserves a new attempt, even if the last was refused.
        if newValue != nil { identityRejected = false }
        identity = newValue
    }

    /// Tell the server this phone may be notified.
    ///
    /// A signed-in user registers against themselves, which works with no
    /// conversation open at all — that is the only way a staff-started chat
    /// can reach them, since there is nothing yet to register against.
    /// Anonymous visitors keep the per-conversation registration, having no
    /// user id to hang a device on.
    func registerDeviceIfPossible() async {
        guard let token = SendSyncChat.deviceTokenHex else { return }

        // Re-fetch whenever the config we hold does not say push is on — not
        // only when we hold none.
        //
        // `identify` and `setDeviceToken` both land here at launch, long before
        // anything shows the chat. A cached "push is off" is an answer from
        // that moment: if the APNs key was missing then and added since, the
        // old answer would keep this phone unregistered until the app was
        // force-quit, which is exactly the silence this is meant to prevent.
        if Self.shouldRefetchConfigBeforeRegistering(config) {
            do {
                config = try await api.config()
            } catch {
                pushRegistrationError = "Couldn't load the widget settings: \(error.localizedDescription)"
                SendSyncChat.warn("could not load widget settings to register for push — \(error)")
                return
            }
        }
        guard config?.features?.push == true else {
            pushRegistrationError = "Push notifications are not set up for this widget."
            return
        }

        do {
            if let identity {
                try await api.registerUserDevice(
                    identity: identity, apnsToken: token,
                    environment: SendSyncChat.pushEnvironment.rawValue
                )
            } else if let id = conversationId, let auth {
                try await api.registerDevice(
                    conversationId: id, apnsToken: token,
                    environment: SendSyncChat.pushEnvironment.rawValue, auth: auth
                )
            } else {
                // Anonymous with no chat yet: nothing to register against, and
                // nothing wrong.
                return
            }
            pushRegistrationError = nil
        } catch {
            if handleIfSignatureRejected(error) { return }
            pushRegistrationError = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            SendSyncChat.warn("could not register this device for push — \(error)")
        }
    }

    func unregisterDevice() async {
        guard let token = SendSyncChat.deviceTokenHex else { return }
        if let identity {
            try? await api.unregisterUserDevice(identity: identity, apnsToken: token)
            return
        }
        guard let id = conversationId, let auth else { return }
        try? await api.unregisterDevice(conversationId: id, apnsToken: token, auth: auth)
    }

    /// Mark what is on screen as read, and drop the badge to match.
    ///
    /// Only while visible: a background poll that cleared the badge would mean
    /// a customer loses the one signal that they have not looked yet.
    func markReadIfVisible() async {
        guard visible, let id = conversationId, let auth, lastId > 0 else { return }
        guard lastId > readUpTo else { return }
        try? await api.markRead(conversationId: id, upToId: lastId, auth: auth)
        readUpTo = lastId
        unreadCount = max(0, unreadCount - unreadInCurrent)
        unreadInCurrent = 0
    }

    /// A tapped push for this widget: make sure that chat is the one shown.
    func open(conversationId id: String) {
        guard id != conversationId else { return }
        if identity != nil {
            adopt(StoredChat(conversationId: id, token: nil, pipelineId: nil))
        }
    }

    // MARK: - internals

    private func adopt(_ chat: StoredChat) {
        stored = chat
        conversationId = chat.conversationId
        selectedPipelineId = chat.pipelineId ?? selectedPipelineId
        messages = []
        lastId = 0
        readUpTo = 0
        unreadInCurrent = 0
        status = "open"
        if chat.token != nil {
            KeychainStore.save(chat, account: Self.account(api.widgetKey))
        }
    }

    func reset() {
        KeychainStore.delete(account: Self.account(api.widgetKey))
        stored = nil
        conversationId = nil
        selectedPipelineId = nil
        messages = []
        lastId = 0
        readUpTo = 0
        unreadInCurrent = 0
        unreadCount = 0
        otherOpenConversations = []
        status = "open"
        errorMessage = nil
    }

    private func apply(_ view: ConversationView) {
        status = view.status
        let fresh = view.messages.filter { $0.id > lastId }
        guard !fresh.isEmpty else { return }
        messages.append(contentsOf: fresh)
        lastId = fresh.map(\.id).max() ?? lastId
        // Their own messages are read by definition.
        let theirs = fresh.filter { $0.sender != .visitor }.count
        if theirs > 0 {
            unreadInCurrent += theirs
            unreadCount += theirs
        }
        if visible { Task { await markReadIfVisible() } }
    }

    static func clientInfo() -> [String: String] {
        var info: [String: String] = ["platform": "ios", "sdkVersion": SendSyncChat.sdkVersion]
        let bundle = Bundle.main
        if let v = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String { info["appVersion"] = v }
        #if canImport(UIKit)
        info["osVersion"] = UIDevice.current.systemVersion
        #endif
        var system = utsname()
        uname(&system)
        let model = withUnsafePointer(to: &system.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        if !model.isEmpty { info["deviceModel"] = model }
        return info
    }
}
