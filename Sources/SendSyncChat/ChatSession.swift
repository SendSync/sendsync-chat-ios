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

    let api: APIClient
    private(set) var identity: ChatIdentity?
    private var stored: StoredChat?
    private var lastId = 0
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
        if conversationId == nil, let identity {
            // Same signed-in user on a new phone or after reinstalling: pick up
            // their latest chat.
            if let latest = try? await api.myConversations(identity: identity).conversations.first {
                adopt(StoredChat(conversationId: latest.conversationId, token: nil, pipelineId: latest.pipelineId))
            }
        }
        await refresh()
        await registerDeviceIfPossible()
    }

    /// Call when the chat appears / disappears; polls quickly only while visible.
    public func setVisible(_ isVisible: Bool) {
        visible = isVisible
        pollTask?.cancel()
        guard isVisible else { return }
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
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Couldn't send"
        }
    }

    /// Forget the current chat (after it ended) so the visitor can start another.
    public func startNewChat() {
        reset()
    }

    // MARK: - identity & push (driven by SendSyncChat)

    func setIdentity(_ newValue: ChatIdentity?) {
        if newValue?.userId != identity?.userId {
            // A different person: never show them the previous user's chat.
            reset()
        }
        identity = newValue
    }

    func registerDeviceIfPossible() async {
        guard config?.features?.push == true,
              let token = SendSyncChat.deviceTokenHex,
              let id = conversationId, let auth else { return }
        try? await api.registerDevice(
            conversationId: id, apnsToken: token,
            environment: SendSyncChat.pushEnvironment.rawValue, auth: auth
        )
    }

    func unregisterDevice() async {
        guard let token = SendSyncChat.deviceTokenHex, let id = conversationId, let auth else { return }
        try? await api.unregisterDevice(conversationId: id, apnsToken: token, auth: auth)
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
        status = "open"
        errorMessage = nil
    }

    private func apply(_ view: ConversationView) {
        status = view.status
        let fresh = view.messages.filter { $0.id > lastId }
        guard !fresh.isEmpty else { return }
        messages.append(contentsOf: fresh)
        lastId = fresh.map(\.id).max() ?? lastId
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
