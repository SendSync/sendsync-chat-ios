import Foundation

/// How a request proves it may touch a chat.
enum ChatAuth {
    /// The per-chat token handed out when the chat started.
    case token(String)
    /// A verified signed-in user (works from any of their devices).
    case identity(ChatIdentity)

    func apply(to request: inout URLRequest) {
        switch self {
        case let .token(t):
            request.setValue(t, forHTTPHeaderField: "X-Chat-Token")
        case let .identity(i):
            request.setValue(i.userId, forHTTPHeaderField: "X-Chat-User-Id")
            request.setValue(i.signature, forHTTPHeaderField: "X-Chat-User-Signature")
        }
    }
}

/// Thin client for SendSync's public widget API (`/api/widget/v1`).
struct APIClient {
    let host: URL
    let widgetKey: String
    var session: URLSession = .shared

    private var base: URL { host.appendingPathComponent("api/widget/v1") }

    func config() async throws -> ChatWidgetConfig {
        try await send("GET", "widgets/\(widgetKey)")
    }

    func start(
        pipelineId: String?,
        body: String,
        name: String?,
        email: String?,
        identity: ChatIdentity?,
        client: [String: String]
    ) async throws -> StartResponse {
        var payload: [String: Any] = ["body": body, "client": client]
        if let pipelineId { payload["pipelineId"] = pipelineId }
        if let name, !name.isEmpty { payload["name"] = name }
        if let email, !email.isEmpty { payload["email"] = email }
        if let identity {
            var user: [String: Any] = ["id": identity.userId, "signature": identity.signature]
            if let n = identity.name { user["name"] = n }
            if let e = identity.email { user["email"] = e }
            payload["user"] = user
        }
        return try await send("POST", "widgets/\(widgetKey)/conversations", json: payload)
    }

    func messages(conversationId: String, after: Int, auth: ChatAuth) async throws -> ConversationView {
        try await send("GET", "conversations/\(conversationId)", query: ["after": String(after)], auth: auth)
    }

    func post(conversationId: String, body: String, after: Int, auth: ChatAuth) async throws -> ConversationView {
        try await send("POST", "conversations/\(conversationId)/messages", json: ["body": body, "after": after], auth: auth)
    }

    func myConversations(identity: ChatIdentity) async throws -> MyConversations {
        try await send("GET", "widgets/\(widgetKey)/my-conversations", auth: .identity(identity))
    }

    func registerDevice(conversationId: String, apnsToken: String, environment: String, auth: ChatAuth) async throws {
        let _: Empty = try await send(
            "POST", "conversations/\(conversationId)/devices",
            json: ["apnsToken": apnsToken, "environment": environment], auth: auth
        )
    }

    func unregisterDevice(conversationId: String, apnsToken: String, auth: ChatAuth) async throws {
        let _: Empty = try await send("DELETE", "conversations/\(conversationId)/devices/\(apnsToken)", auth: auth)
    }

    // MARK: - plumbing

    struct Empty: Decodable {}

    private func send<T: Decodable>(
        _ method: String,
        _ path: String,
        query: [String: String] = [:],
        json: [String: Any]? = nil,
        auth: ChatAuth? = nil
    ) async throws -> T {
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        auth?.apply(to: &request)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ChatError.network(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error ?? "Request failed (\(status))"
            throw ChatError.server(status: status, message: message)
        }
        if status == 204 || data.isEmpty, let empty = Empty() as? T { return empty }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
