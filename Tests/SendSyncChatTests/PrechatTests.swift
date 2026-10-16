import XCTest
@testable import SendSyncChat

/// Details asked for before a chat starts. The rules mirror the server's
/// (`lib/chat-prechat.ts`); the server enforces them, these just say so first.
final class PrechatTests: XCTestCase {
    func testConfigDecodesPrechat() throws {
        let json = ##"""
        {"title":"Acme","color":"#000000","greeting":null,"offlineMessage":null,"online":true,"pipelines":[],
         "prechat":{"name":"required","email":"optional","phone":"off"}}
        """##
        let c = try JSONDecoder().decode(ChatWidgetConfig.self, from: Data(json.utf8))
        XCTAssertEqual(c.prechat, ChatPrechat(name: .required, email: .optional, phone: .off))
    }

    func testOlderServerHasNoPrechat() throws {
        let json = ##"{"title":"Acme","color":"#000000","greeting":null,"offlineMessage":null,"online":true,"pipelines":[]}"##
        let c = try JSONDecoder().decode(ChatWidgetConfig.self, from: Data(json.utf8))
        XCTAssertNil(c.prechat)
    }

    func testUnknownModeIsRequired() throws {
        let json = #"{"name":"sometimes","email":"off","phone":"optional"}"#
        let p = try JSONDecoder().decode(ChatPrechat.self, from: Data(json.utf8))
        XCTAssertEqual(p.name, .required)
    }

    func testRequiredFieldsMustBeFilled() {
        let p = ChatPrechat(name: .required, email: .required, phone: .required)
        let all: Set<ChatPrechat.Field> = [.name, .email, .phone]
        XCTAssertEqual(p.check(name: nil, email: "a@b.co", phone: "5550100199", asked: all, online: true)?.field, .name)
        XCTAssertEqual(p.check(name: "Ada", email: " ", phone: "5550100199", asked: all, online: true)?.field, .email)
        XCTAssertEqual(p.check(name: "Ada", email: "a@b.co", phone: nil, asked: all, online: true)?.field, .phone)
        XCTAssertNil(p.check(name: "Ada", email: "a@b.co", phone: "+1 (555) 010-0199", asked: all, online: true))
        // Only what is on screen is checked.
        XCTAssertNil(p.check(name: nil, email: nil, phone: nil, asked: [], online: true))
    }

    func testFormats() {
        let p = ChatPrechat(name: .optional, email: .optional, phone: .optional)
        let all: Set<ChatPrechat.Field> = [.name, .email, .phone]
        XCTAssertEqual(p.check(name: nil, email: "nope", phone: nil, asked: all, online: true)?.field, .email)
        XCTAssertEqual(p.check(name: nil, email: nil, phone: "call me", asked: all, online: true)?.field, .phone)
        XCTAssertEqual(p.check(name: nil, email: nil, phone: "123", asked: all, online: true)?.field, .phone)
        XCTAssertNil(p.check(name: nil, email: nil, phone: nil, asked: all, online: true))
    }

    func testOfflineNeedsEmailUnlessNeverAsked() {
        let p = ChatPrechat(name: .optional, email: .optional, phone: .off)
        XCTAssertEqual(p.check(name: nil, email: nil, phone: nil, asked: [.name, .email], online: false)?.field, .email)
        var off = p
        off.email = .off
        XCTAssertFalse(off.isRequired(.email, online: false))
    }

    func testMissingDetailErrorReadsAsItsMessage() {
        let e = ChatError.missingDetail(field: "phone", message: "Please enter your phone number")
        XCTAssertEqual(e.errorDescription, "Please enter your phone number")
    }
}
