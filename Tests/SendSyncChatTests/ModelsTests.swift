import XCTest
@testable import SendSyncChat

/// The JSON here mirrors the server's real responses (routes/chat-widget.ts),
/// so a field renamed on either side fails here first.
final class ModelsTests: XCTestCase {
    func testWidgetConfigDecodes() throws {
        let json = """
        {"title":"Acme","organizationName":"Acme","name":"Sales","color":"#3B82F6",
         "greeting":"Hi!","offlineMessage":null,"online":true,
         "pipelines":[{"id":"chp_1","name":"Sales","color":"#10B981","online":true,"greeting":null,"offlineMessage":null},
                      {"id":"chp_2","name":"Support","color":"#8B5CF6","online":false,"greeting":"Support here","offlineMessage":"Away"}],
         "features":{"identity":true,"push":false}}
        """
        let c = try JSONDecoder().decode(ChatWidgetConfig.self, from: Data(json.utf8))
        XCTAssertEqual(c.title, "Acme")
        XCTAssertEqual(c.pipelines.map(\.name), ["Sales", "Support"])
        XCTAssertEqual(c.pipelines[1].online, false)
        XCTAssertEqual(c.features, .init(identity: true, push: false))
    }

    func testConfigWithoutFeaturesStillDecodes() throws {
        let json = #"{"title":"Acme","color":"#000000","greeting":null,"offlineMessage":null,"online":false,"pipelines":[]}"#
        let c = try JSONDecoder().decode(ChatWidgetConfig.self, from: Data(json.utf8))
        XCTAssertNil(c.features)
    }

    func testStartResponseAndMessages() throws {
        let json = """
        {"conversationId":"chc_abc","token":"\(String(repeating: "a", count: 64))","pipelineId":"chp_1","status":"open",
         "messages":[{"id":5,"sender":"visitor","authorName":null,"body":"Hi","createdAt":"2026-10-03T10:00:00.123Z"},
                     {"id":6,"sender":"agent","authorName":"Alice","body":"Hello!","createdAt":"2026-10-03T10:00:05Z"}]}
        """
        let r = try JSONDecoder().decode(StartResponse.self, from: Data(json.utf8))
        XCTAssertEqual(r.conversationId, "chc_abc")
        XCTAssertEqual(r.messages.map(\.sender), [.visitor, .agent])
        XCTAssertNotNil(r.messages[0].date, "fractional seconds")
        XCTAssertNotNil(r.messages[1].date, "no fractional seconds")
    }

    func testMyConversations() throws {
        let json = #"{"conversations":[{"conversationId":"chc_1","pipelineId":null,"status":"open","lastMessageAt":"2026-10-03T10:00:00.000Z"}]}"#
        let r = try JSONDecoder().decode(MyConversations.self, from: Data(json.utf8))
        XCTAssertEqual(r.conversations.first?.conversationId, "chc_1")
    }
}
