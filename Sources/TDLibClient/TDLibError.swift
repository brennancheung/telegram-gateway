import Foundation

/// A TDLib `error` object returned in place of a response. `code` follows HTTP conventions
/// loosely: 400 bad request, 401 unauthorized, 404 not found, 406 rejected, 429 flood wait,
/// 500 internal. `message` is TDLib's text, e.g. `PHONE_NUMBER_INVALID`.
public struct TDLibError: Error, Sendable, Equatable, CustomStringConvertible {
    public let code: Int
    public let message: String

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }

    /// Builds from a decoded `{"@type":"error",...}` object. Missing fields become 500/"".
    public init(object: JSONObject) {
        self.code = object.int("code") ?? 500
        self.message = object.string("message") ?? ""
    }

    public var description: String {
        "TDLib error \(code): \(message)"
    }

    /// The client was closed (or the process is shutting down) before a response arrived.
    public static let closed = TDLibError(code: 500, message: "client closed")
}
