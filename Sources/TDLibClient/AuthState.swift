import Foundation

/// TDLib's `AuthorizationState`, one case per `authorizationState*` type in the TL schema
/// (vendor/tdlib/src/td/generate/scheme/td_api.tl). TDLib announces every change through the
/// `updateAuthorizationState` update; `TDLibClient` decodes it into this enum.
public enum AuthState: Sendable, Equatable {
    /// First state after creation: send `setTdlibParameters`.
    case waitTdlibParameters
    /// Send `setAuthenticationPhoneNumber` or `requestQrCodeAuthentication`.
    case waitPhoneNumber
    /// Telegram is asking for a Telegram Premium purchase to log in (rare, new accounts).
    case waitPremiumPurchase
    /// Send `setAuthenticationEmailAddress` (accounts that log in by email).
    case waitEmailAddress
    /// Send `checkAuthenticationEmailCode`.
    case waitEmailCode
    /// Send `checkAuthenticationCode` with the code Telegram sent to another device or SMS.
    case waitCode
    /// QR login: show `link` (a `tg://login?token=…` URL) as a QR code for the phone to scan.
    /// TDLib re-sends this state with a fresh link when the token expires.
    case waitOtherDeviceConfirmation(link: String)
    /// The phone number has no account; `registerUser` would create one.
    case waitRegistration
    /// Two-step verification: send `checkAuthenticationPassword`. `hint` is the owner's own hint.
    case waitPassword(hint: String)
    /// Logged in; the API is usable.
    case ready
    /// `logOut` in progress; `closed` follows and the local data is wiped.
    case loggingOut
    /// `close` in progress; `closed` follows.
    case closing
    /// The client is gone. Nothing more will be received for it.
    case closed
    /// A state this build does not know about. Carries the `@type` string.
    case unknown(String)

    /// Decodes an `AuthorizationState` object (the `authorization_state` field of
    /// `updateAuthorizationState`, or the result of `getAuthorizationState`).
    public init(object: JSONObject) {
        switch object.type {
        case "authorizationStateWaitTdlibParameters": self = .waitTdlibParameters
        case "authorizationStateWaitPhoneNumber": self = .waitPhoneNumber
        case "authorizationStateWaitPremiumPurchase": self = .waitPremiumPurchase
        case "authorizationStateWaitEmailAddress": self = .waitEmailAddress
        case "authorizationStateWaitEmailCode": self = .waitEmailCode
        case "authorizationStateWaitCode": self = .waitCode
        case "authorizationStateWaitOtherDeviceConfirmation":
            self = .waitOtherDeviceConfirmation(link: object.string("link") ?? "")
        case "authorizationStateWaitRegistration": self = .waitRegistration
        case "authorizationStateWaitPassword":
            self = .waitPassword(hint: object.string("password_hint") ?? "")
        case "authorizationStateReady": self = .ready
        case "authorizationStateLoggingOut": self = .loggingOut
        case "authorizationStateClosing": self = .closing
        case "authorizationStateClosed": self = .closed
        case let other: self = .unknown(other ?? "")
        }
    }

    /// True once the client will never produce another state.
    public var isTerminal: Bool {
        self == .closed
    }
}
