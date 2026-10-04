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
        /// Whether this widget lets customers send images. Absent on a server
        /// older than this SDK, which is the same as off.
        public var attachments: Bool? = nil
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

/// An image attached to a message.
public struct ChatAttachment: Decodable, Equatable, Identifiable {
    public let id: Int
    public let fileName: String
    public let contentType: String
    public let byteSize: Int
    /// A signed link that expires in minutes — fetch it when you show it, not
    /// ahead of time. Nil when the server could not sign one, in which case
    /// show the file name rather than a broken image.
    public let url: String?
}

/// What image bytes actually are.
///
/// The server decides by the bytes rather than by what an upload claims, and
/// refuses one where the two disagree — so the SDK has to label a photo
/// correctly rather than assume. A picture out of the photo library is as
/// often HEIC as it is JPEG.
enum ChatImageType {
    static func of(_ data: Data) -> String? {
        let b = [UInt8](data.prefix(12))
        guard b.count >= 12 else { return nil }
        if b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return "image/jpeg" }
        if b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47,
           b[4] == 0x0D, b[5] == 0x0A, b[6] == 0x1A, b[7] == 0x0A { return "image/png" }
        if b[0] == 0x47, b[1] == 0x49, b[2] == 0x46 { return "image/gif" }
        if b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46,
           b[8] == 0x57, b[9] == 0x45, b[10] == 0x42, b[11] == 0x50 { return "image/webp" }
        // An ISO base media container with an `ftyp` box; HEIC brands vary.
        if b[4] == 0x66, b[5] == 0x74, b[6] == 0x79, b[7] == 0x70 { return "image/heic" }
        return nil
    }

    static func fileExtension(_ contentType: String) -> String {
        switch contentType {
        case "image/jpeg": return "jpg"
        case "image/png": return "png"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        case "image/heic": return "heic"
        default: return "img"
        }
    }
}

public struct ChatMessage: Decodable, Equatable, Identifiable {
    public enum Sender: String, Decodable { case visitor, agent, system }
    public let id: Int
    public let sender: Sender
    /// Agent's first name; nil for visitor and system messages.
    public let authorName: String?
    /// Their photo, when the widget shows one. Nil otherwise.
    public let authorAvatarUrl: String?
    public let body: String
    public let createdAt: String
    public let attachments: [ChatAttachment]

    private enum CodingKeys: String, CodingKey {
        case id, sender, authorName, authorAvatarUrl, body, createdAt, attachments
    }

    /// Hand-written so that a server older than this SDK — one that sends no
    /// `attachments` and no avatar — decodes rather than throwing.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        sender = try c.decode(Sender.self, forKey: .sender)
        authorName = try c.decodeIfPresent(String.self, forKey: .authorName)
        authorAvatarUrl = try c.decodeIfPresent(String.self, forKey: .authorAvatarUrl)
        body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
        createdAt = try c.decode(String.self, forKey: .createdAt)
        attachments = try c.decodeIfPresent([ChatAttachment].self, forKey: .attachments) ?? []
    }

    public var date: Date? { ChatMessage.parseDate(createdAt) }

    /// Whether this message should be labelled with who wrote it.
    ///
    /// The first of a run, and again whenever the name changes — so a booking
    /// system's "Bookings" following an agent's "Ada" is not silently
    /// attributed to Ada. Visitor messages are never labelled; the reader
    /// wrote them.
    ///
    /// Lives here rather than on the view because it is a fact about the
    /// messages, and because the view only exists where UIKit does — which
    /// would put it out of reach of the tests.
    public static func showsAuthor(in messages: [ChatMessage], at index: Int) -> Bool {
        guard messages.indices.contains(index) else { return false }
        let m = messages[index]
        guard m.sender != .visitor, let name = m.authorName, !name.isEmpty else { return false }
        guard index > 0 else { return true }
        let previous = messages[index - 1]
        if previous.sender != m.sender { return true }
        return previous.authorName != name
    }

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
        /// Messages the user has not read. Optional: a server older than the
        /// unread endpoints omits it, and an SDK that refused to decode that
        /// would break chat for everyone on it.
        let unreadCount: Int?
        /// The newest message, for a host app showing a list.
        let lastMessagePreview: String?

        var date: Date? { ChatMessage.parseDate(lastMessageAt) }
        var isOpen: Bool { status == "open" }
        var unread: Int { unreadCount ?? 0 }
    }
    let conversations: [Item]

    /// Open conversations, newest first. The server already sorts, but the
    /// SDK's behaviour should not depend on that staying true.
    var openConversations: [Item] {
        conversations
            .filter(\.isOpen)
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    /// Every conversation this customer has, newest first, whatever its
    /// status.
    ///
    /// Closed ones belong here: an agent ending a chat does not unsay what
    /// was said in it, and a customer whose conversations have all been
    /// closed would otherwise open the app to a blank new chat with no way
    /// back to any of them. `openConversations` stays for the places that
    /// genuinely mean "still running".
    var allConversations: [Item] {
        conversations.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }
}

/// One of the user's conversations, for a host app (or the SDK's own list)
/// to show when more than one is open at a time.
public struct ChatConversationSummary: Identifiable, Equatable {
    public let id: String
    public let pipelineId: String?
    public let unreadCount: Int
    public let lastMessagePreview: String?
    public let lastMessageAt: Date?
    /// "open" or "closed". A list that shows both has to be able to say which.
    public let status: String

    public var isOpen: Bool { status == "open" }

    init(_ item: MyConversations.Item) {
        self.id = item.conversationId
        self.pipelineId = item.pipelineId
        self.unreadCount = item.unread
        self.lastMessagePreview = item.lastMessagePreview
        self.lastMessageAt = item.date
        self.status = item.status
    }
}

struct ErrorBody: Decodable { let error: String }

/// A signed-in user, vouched for by the app's own server.
public struct ChatIdentity: Equatable, Codable {
    public let userId: String
    /// hex(HMAC-SHA256(widget identity secret, userId)) — computed on YOUR server.
    public let signature: String
    public let name: String?
    public let email: String?
    /// Display-only facts for the agent to see, e.g. ["Next trip": "AUS→DAL Oct 8"].
    /// Never trusted for anything: only `signature` proves who this is.
    public let attributes: [String: String]?

    public init(
        userId: String,
        signature: String,
        name: String? = nil,
        email: String? = nil,
        attributes: [String: String]? = nil
    ) {
        self.userId = userId
        self.signature = signature
        self.name = name
        self.email = email
        self.attributes = attributes
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
