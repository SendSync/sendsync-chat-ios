import Foundation

/// Widget settings as served by `GET /api/widget/v1/widgets/{key}`.
public struct ChatWidgetConfig: Decodable, Equatable {
    public let title: String
    public let color: String
    public let greeting: String?
    public let offlineMessage: String?
    public let online: Bool
    public let pipelines: [ChatPipelineInfo]
    public let features: Features?

    public struct Features: Decodable, Equatable {
        public let identity: Bool
        public let push: Bool
    }
}

/// One team a visitor can chat with ("Sales", "Support").
public struct ChatPipelineInfo: Decodable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let color: String
    public let online: Bool
    public let greeting: String?
    public let offlineMessage: String?
}

public struct ChatMessage: Decodable, Equatable, Identifiable {
    public enum Sender: String, Decodable { case visitor, agent, system }
    public let id: Int
    public let sender: Sender
    /// Agent's first name; nil for visitor and system messages.
    public let authorName: String?
    public let body: String
    public let createdAt: String

    public var date: Date? { ChatMessage.parseDate(createdAt) }

    static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

struct ConversationView: Decodable {
    let status: String
    let messages: [ChatMessage]
}

struct StartResponse: Decodable {
    let conversationId: String
    let token: String
    let pipelineId: String?
    let status: String
    let messages: [ChatMessage]
}

struct MyConversations: Decodable {
    struct Item: Decodable {
        let conversationId: String
        let pipelineId: String?
        let status: String
        let lastMessageAt: String
    }
    let conversations: [Item]
}

struct ErrorBody: Decodable { let error: String }

/// A signed-in user, vouched for by the app's own server.
public struct ChatIdentity: Equatable, Codable {
    public let userId: String
    /// hex(HMAC-SHA256(widget identity secret, userId)) — computed on YOUR server.
    public let signature: String
    public let name: String?
    public let email: String?

    public init(userId: String, signature: String, name: String? = nil, email: String? = nil) {
        self.userId = userId
        self.signature = signature
        self.name = name
        self.email = email
    }
}

public enum ChatError: LocalizedError, Equatable {
    case notConfigured
    case server(status: Int, message: String)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "SendSyncChat.configure(widgetKey:) hasn't been called."
        case let .server(_, message): return message
        case let .network(message): return message
        }
    }
}
