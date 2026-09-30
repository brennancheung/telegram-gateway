import Foundation
import TDLibClient

/// The one way GatewayCore talks to TDLib: send a request object, get the response object.
/// `TDLibClient` is the real implementation; tests use a fake that answers from fixtures.
/// Keeping the surface this narrow is what makes everything above it testable without an
/// account.
public protocol TDLibRequesting: Sendable {
    /// Sends `request` (which carries `@type`) and returns the response. Throws `TDLibError`
    /// when TDLib answers with an `error` object.
    func request(_ request: JSONBox) async throws -> JSONBox
}

extension TDLibRequesting {
    /// `request(["@type": type] + fields)`.
    public func request(_ type: String, _ fields: JSONObject = [:]) async throws -> JSONBox {
        var object = fields
        object["@type"] = type
        return try await request(JSONBox(object))
    }
}

extension TDLibClient: TDLibRequesting {
    public func request(_ request: JSONBox) async throws -> JSONBox {
        JSONBox(try await send(request.object))
    }
}

/// TDLib's `ConnectionState` as the API reports it (docs/api.md "Health").
public enum ConnectionState: String, Sendable, Equatable {
    case waitingForNetwork = "waiting_for_network"
    case connecting
    case updating
    case ready

    /// Decodes a `connectionState*` object; unknown types map to `connecting`.
    public init(object: JSONObject) {
        switch object.type {
        case "connectionStateWaitingForNetwork": self = .waitingForNetwork
        case "connectionStateConnecting", "connectionStateConnectingToProxy": self = .connecting
        case "connectionStateUpdating": self = .updating
        case "connectionStateReady": self = .ready
        default: self = .connecting
        }
    }
}

extension AuthState {
    /// The `tdlib.auth_state` string (docs/api.md "Health").
    public var apiName: String {
        switch self {
        case .waitPhoneNumber, .waitPremiumPurchase: "wait_phone_number"
        case .waitEmailAddress: "wait_email_address"
        case .waitEmailCode: "wait_email_code"
        case .waitRegistration: "wait_registration"
        case .waitOtherDeviceConfirmation: "wait_qr_confirmation"
        case .waitCode: "wait_code"
        case .waitPassword: "wait_password"
        case .ready: "ready"
        case .loggingOut: "logging_out"
        case .closing, .closed: "closed"
        case .waitTdlibParameters, .unknown: "unknown"
        }
    }
}

/// Chat id arithmetic TDLib uses (td/telegram/DialogId.cpp): a supergroup or channel with
/// `supergroup_id` S has chat id `-1000000000000 - S`; a basic group with id B has `-B`; a
/// private chat's id is the user id.
public enum ChatIdArithmetic {
    public static let zeroChannelId: Int64 = -1_000_000_000_000

    public static func chatId(supergroupId: Int64) -> Int64 { zeroChannelId - supergroupId }
    public static func chatId(basicGroupId: Int64) -> Int64 { -basicGroupId }
    public static func chatId(userId: Int64) -> Int64 { userId }
}
