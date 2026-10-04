import XCTest
@testable import SendSyncChat

/// What the SDK does when the integration around it is wrong: a signature the
/// server will not accept, and a widget whose push settings changed after
/// launch. Both used to fail silently, which is the worst way for an
/// integration problem to behave.
final class IdentityResilienceTests: XCTestCase {

    // MARK: - recognising a refused signature

    func testOnly401CountsAsASignatureRejection() {
        XCTAssertTrue(ChatSession.isSignatureRejection(ChatError.server(status: 401, message: "User signature didn't verify")))
        // A missing chat is not a bad signature, and must not drop the user to
        // anonymous — `refresh` already starts a fresh chat for that case.
        XCTAssertFalse(ChatSession.isSignatureRejection(ChatError.server(status: 404, message: "Not found")))
        XCTAssertFalse(ChatSession.isSignatureRejection(ChatError.server(status: 500, message: "Boom")))
        XCTAssertFalse(ChatSession.isSignatureRejection(ChatError.network("offline")))
        XCTAssertFalse(ChatSession.isSignatureRejection(ChatError.notConfigured))
    }

    // MARK: - falling back to anonymous

    @MainActor
    private func session(identified: Bool) -> ChatSession {
        let api = APIClient(host: URL(string: "https://example.com")!, widgetKey: "chw_" + String(repeating: "a", count: 32))
        let identity = identified
            ? ChatIdentity(userId: "u-1", signature: String(repeating: "a", count: 64))
            : nil
        return ChatSession(api: api, identity: identity)
    }

    @MainActor
    func testRejectionTurnsOffIdentitySoTheComposerComesBack() {
        let s = session(identified: true)
        XCTAssertTrue(s.isIdentified)
        XCTAssertFalse(s.identityRejected)

        s.rejectIdentity("User signature didn't verify")

        // The view hides the name and email fields while `isIdentified` — which
        // is exactly how a bad signature used to leave someone unable to send.
        XCTAssertFalse(s.isIdentified, "the visitor must be able to identify themselves by hand")
        XCTAssertTrue(s.identityRejected)
    }

    @MainActor
    func testRejectionIsNotRepeated() {
        let s = session(identified: true)
        s.rejectIdentity("first")
        s.rejectIdentity("second")
        // Still exactly one rejection: polling continues after a fallback, and
        // re-running this per poll would spam the console and reset state in a
        // loop.
        XCTAssertTrue(s.identityRejected)
        XCTAssertFalse(s.isIdentified)
    }

    @MainActor
    func testRejectionClearsUnreadAndOtherConversations() {
        let s = session(identified: true)
        s.rejectIdentity("nope")
        XCTAssertEqual(s.unreadCount, 0)
        XCTAssertTrue(s.otherOpenConversations.isEmpty)
    }

    @MainActor
    func testAnErrorIsOnlyHandledWhileIdentified() {
        let anonymous = session(identified: false)
        XCTAssertFalse(
            anonymous.handleIfSignatureRejected(ChatError.server(status: 401, message: "x")),
            "an anonymous session has no signature to be rejected"
        )

        let identified = session(identified: true)
        XCTAssertFalse(identified.handleIfSignatureRejected(ChatError.server(status: 404, message: "x")))
        XCTAssertTrue(identified.handleIfSignatureRejected(ChatError.server(status: 401, message: "x")))
        // Having fallen back, a second error changes nothing.
        XCTAssertFalse(identified.handleIfSignatureRejected(ChatError.server(status: 401, message: "x")))
    }

    @MainActor
    func testANewSignatureGetsAFreshChance() {
        let s = session(identified: true)
        s.rejectIdentity("stale secret")
        XCTAssertTrue(s.identityRejected)

        // The app rotated its secret and signed the user again.
        s.setIdentity(ChatIdentity(userId: "u-1", signature: String(repeating: "c", count: 64)))
        XCTAssertFalse(s.identityRejected, "a new signature deserves a new attempt")
        XCTAssertTrue(s.isIdentified)
    }

    // MARK: - not trusting a stale answer about push

    private func config(push: Bool?) -> ChatWidgetConfig {
        let features = push.map { "{\"identity\":true,\"push\":\($0)}" } ?? "null"
        let json = """
        {"title":"Acme","color":"#3B82F6","greeting":null,"offlineMessage":null,
         "online":true,"pipelines":[],"features":\(features)}
        """
        // Force-try: the fixture is a literal in this file, so a failure here is
        // a broken test rather than a condition worth handling.
        return try! JSONDecoder().decode(ChatWidgetConfig.self, from: Data(json.utf8))
    }

    func testRefetchesUnlessPushIsKnownToBeOn() {
        // Nothing loaded yet — the launch case.
        XCTAssertTrue(ChatSession.shouldRefetchConfigBeforeRegistering(nil))
        // The case this was written for: push was off at launch and the APNs
        // key has been added since. Believing the cached answer leaves the
        // phone unregistered until the app is force-quit.
        XCTAssertTrue(ChatSession.shouldRefetchConfigBeforeRegistering(config(push: false)))
        // An older server that does not report features at all.
        XCTAssertTrue(ChatSession.shouldRefetchConfigBeforeRegistering(config(push: nil)))
        // Only a confident yes is taken at face value.
        XCTAssertFalse(ChatSession.shouldRefetchConfigBeforeRegistering(config(push: true)))
    }

    @MainActor
    func testRegistrationErrorStartsEmpty() {
        XCTAssertNil(session(identified: true).pushRegistrationError)
        XCTAssertNil(session(identified: false).pushRegistrationError)
    }
}
