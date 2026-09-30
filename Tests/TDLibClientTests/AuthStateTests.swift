import Foundation
import Testing

@testable import TDLibClient

@Suite struct AuthStateTests {
    private func decode(_ json: String) throws -> AuthState {
        let any = try JSONSerialization.jsonObject(with: Data(json.utf8))
        let object = try #require(any as? JSONObject)
        return AuthState(object: object)
    }

    @Test(arguments: [
        ("authorizationStateWaitTdlibParameters", AuthState.waitTdlibParameters),
        ("authorizationStateWaitPhoneNumber", .waitPhoneNumber),
        ("authorizationStateWaitPremiumPurchase", .waitPremiumPurchase),
        ("authorizationStateWaitEmailAddress", .waitEmailAddress),
        ("authorizationStateWaitEmailCode", .waitEmailCode),
        ("authorizationStateWaitCode", .waitCode),
        ("authorizationStateWaitRegistration", .waitRegistration),
        ("authorizationStateReady", .ready),
        ("authorizationStateLoggingOut", .loggingOut),
        ("authorizationStateClosing", .closing),
        ("authorizationStateClosed", .closed),
    ])
    func simpleStates(type: String, expected: AuthState) throws {
        #expect(try decode(#"{"@type":"\#(type)"}"#) == expected)
    }

    @Test func qrLinkIsCarried() throws {
        let state = try decode(#"{"@type":"authorizationStateWaitOtherDeviceConfirmation","link":"tg://login?token=abc"}"#)
        #expect(state == .waitOtherDeviceConfirmation(link: "tg://login?token=abc"))
    }

    @Test func passwordHintIsCarried() throws {
        let state = try decode(#"{"@type":"authorizationStateWaitPassword","password_hint":"pet","has_recovery_email_address":true}"#)
        #expect(state == .waitPassword(hint: "pet"))
        #expect(try decode(#"{"@type":"authorizationStateWaitPassword"}"#) == .waitPassword(hint: ""))
    }

    @Test func unknownStateKeepsItsName() throws {
        #expect(try decode(#"{"@type":"authorizationStateWaitSomethingNew"}"#) == .unknown("authorizationStateWaitSomethingNew"))
        #expect(AuthState.closed.isTerminal)
        #expect(!AuthState.ready.isTerminal)
    }

    @Test func parametersRequestUsesTDLibFieldNames() {
        var parameters = TDLibParameters(
            apiId: 12345,
            apiHash: "hash",
            databaseDirectory: "/tmp/db",
            filesDirectory: "/tmp/db/files",
            databaseEncryptionKey: Data([1, 2, 3]),
            applicationVersion: "0.1.0"
        )
        parameters.systemVersion = "macOS"
        let request = parameters.request
        #expect(request.type == "setTdlibParameters")
        #expect(request.int("api_id") == 12345)
        #expect(request.string("api_hash") == "hash")
        #expect(request.string("database_encryption_key") == "AQID")
        #expect(request.string("device_model") == "Telegram Gateway")
        #expect(request.string("system_language_code") == "en")
        #expect(request.bool("use_message_database") == true)
        #expect(request.bool("use_chat_info_database") == true)
        #expect(request.bool("use_file_database") == true)
        #expect(request.bool("use_secret_chats") == false)
        #expect(request.bool("use_test_dc") == false)
        #expect(request.string("system_version") == "macOS")
    }
}
