import XCTest
@testable import SendSyncChat

/// The behaviour that lets a conversation the customer did not start reach
/// them: picking it up on launch, counting what they have not read, and
/// attributing a message to whoever actually wrote it.
///
/// As in `ModelsTests`, the JSON mirrors the server's real responses, so a
/// field renamed on either side fails here first.
final class StaffStartedTests: XCTestCase {

    // MARK: - my-conversations

    private func decode(_ json: String) throws -> MyConversations {
        try JSONDecoder().decode(MyConversations.self, from: Data(json.utf8))
    }

    func testUnreadAndPreviewDecode() throws {
        let json = #"""
        {"conversations":[
          {"conversationId":"chc_1","pipelineId":"chp_1","status":"open",
           "lastMessageAt":"2026-10-03T10:00:00.000Z","unreadCount":2,
           "lastMessagePreview":"Your 9am moved to 10am"}]}
        """#
        let item = try XCTUnwrap(decode(json).conversations.first)
        XCTAssertEqual(item.unread, 2)
        XCTAssertEqual(item.lastMessagePreview, "Your 9am moved to 10am")
        XCTAssertTrue(item.isOpen)
    }

    /// A server that predates the unread endpoints omits both fields. The SDK
    /// has to keep working against it rather than failing to decode and
    /// breaking chat entirely.
    func testOlderServerWithoutUnreadStillDecodes() throws {
        let json = #"{"conversations":[{"conversationId":"chc_1","pipelineId":null,"status":"open","lastMessageAt":"2026-10-03T10:00:00.000Z"}]}"#
        let item = try XCTUnwrap(decode(json).conversations.first)
        XCTAssertNil(item.unreadCount)
        XCTAssertEqual(item.unread, 0, "absent means nothing unread, not a crash")
        XCTAssertNil(item.lastMessagePreview)
    }

    func testOpenConversationsAreNewestFirstAndExcludeClosed() throws {
        let json = #"""
        {"conversations":[
          {"conversationId":"chc_old","pipelineId":null,"status":"open",
           "lastMessageAt":"2026-10-01T10:00:00.000Z","unreadCount":0,"lastMessagePreview":"old"},
          {"conversationId":"chc_closed","pipelineId":null,"status":"closed",
           "lastMessageAt":"2026-10-05T10:00:00.000Z","unreadCount":0,"lastMessagePreview":"done"},
          {"conversationId":"chc_new","pipelineId":null,"status":"open",
           "lastMessageAt":"2026-10-04T10:00:00.000Z","unreadCount":1,"lastMessagePreview":"new"}]}
        """#
        let open = try decode(json).openConversations
        XCTAssertEqual(open.map(\.conversationId), ["chc_new", "chc_old"])
        XCTAssertFalse(
            open.contains { $0.conversationId == "chc_closed" },
            "a closed chat is not somewhere to put a reply, however recent"
        )
    }

    /// The server sorts already; the SDK sorting too means its behaviour does
    /// not quietly depend on that staying true.
    func testOrderingDoesNotDependOnServerOrder() throws {
        let json = #"""
        {"conversations":[
          {"conversationId":"chc_a","pipelineId":null,"status":"open",
           "lastMessageAt":"2026-01-01T00:00:00.000Z","unreadCount":0,"lastMessagePreview":null},
          {"conversationId":"chc_b","pipelineId":null,"status":"open",
           "lastMessageAt":"2026-12-31T00:00:00.000Z","unreadCount":0,"lastMessagePreview":null}]}
        """#
        XCTAssertEqual(try decode(json).openConversations.map(\.conversationId), ["chc_b", "chc_a"])
    }

    func testSummaryCarriesWhatAHostAppNeeds() throws {
        let json = #"""
        {"conversations":[{"conversationId":"chc_1","pipelineId":"chp_9","status":"open",
          "lastMessageAt":"2026-10-03T10:00:00.000Z","unreadCount":3,"lastMessagePreview":"Gate B12"}]}
        """#
        let summary = ChatConversationSummary(try XCTUnwrap(decode(json).conversations.first))
        XCTAssertEqual(summary.id, "chc_1")
        XCTAssertEqual(summary.pipelineId, "chp_9")
        XCTAssertEqual(summary.unreadCount, 3)
        XCTAssertEqual(summary.lastMessagePreview, "Gate B12")
        XCTAssertNotNil(summary.lastMessageAt)
    }

    // MARK: - identity

    func testIdentityCarriesAttributes() throws {
        let identity = ChatIdentity(
            userId: "u-1", signature: String(repeating: "a", count: 64),
            name: "Ada", email: "ada@example.com",
            attributes: ["Next trip": "AUS→DAL Oct 8"]
        )
        XCTAssertEqual(identity.attributes?["Next trip"], "AUS→DAL Oct 8")

        // Still codable, since it is persisted alongside the rest.
        let round = try JSONDecoder().decode(
            ChatIdentity.self, from: try JSONEncoder().encode(identity)
        )
        XCTAssertEqual(round, identity)
    }

    func testIdentityWithoutAttributesIsUnchanged() {
        let identity = ChatIdentity(userId: "u-1", signature: "sig")
        XCTAssertNil(identity.attributes, "attributes are optional, not empty-by-default")
    }

    // MARK: - who wrote it

    private func message(_ id: Int, _ sender: ChatMessage.Sender, _ author: String?) throws -> ChatMessage {
        let authorJSON = author.map { "\"\($0)\"" } ?? "null"
        let json = """
        {"id":\(id),"sender":"\(sender.rawValue)","authorName":\(authorJSON),
         "body":"x","createdAt":"2026-10-03T10:00:00.000Z"}
        """
        return try JSONDecoder().decode(ChatMessage.self, from: Data(json.utf8))
    }

    func testNameShownOncePerRun() throws {
        let messages = [
            try message(1, .agent, "Ada"),
            try message(2, .agent, "Ada"),
        ]
        XCTAssertTrue(ChatMessage.showsAuthor(in: messages, at: 0))
        XCTAssertFalse(ChatMessage.showsAuthor(in: messages, at: 1), "same person, same run")
    }

    /// The case this was written for: a booking system posting under its own
    /// name after an agent has been talking must not look like the agent.
    func testNameShownAgainWhenTheAuthorChanges() throws {
        let messages = [
            try message(1, .agent, "Ada"),
            try message(2, .agent, "Bookings"),
        ]
        XCTAssertTrue(ChatMessage.showsAuthor(in: messages, at: 1))
    }

    func testVisitorAndUnnamedMessagesAreNeverLabelled() throws {
        let messages = [
            try message(1, .visitor, nil),
            try message(2, .agent, nil),
            try message(3, .system, ""),
        ]
        for index in messages.indices {
            XCTAssertFalse(
                ChatMessage.showsAuthor(in: messages, at: index),
                "index \(index) has no name worth showing"
            )
        }
    }

    func testSystemMessagesAreLabelledWhenNamed() throws {
        let messages = [try message(1, .system, "Bookings")]
        XCTAssertTrue(ChatMessage.showsAuthor(in: messages, at: 0))
    }

    func testAnOutOfRangeIndexIsNotACrash() throws {
        XCTAssertFalse(ChatMessage.showsAuthor(in: [], at: 0))
        XCTAssertFalse(ChatMessage.showsAuthor(in: [try message(1, .agent, "Ada")], at: 9))
    }
}
