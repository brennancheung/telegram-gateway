import CryptoKit
import Foundation

/// Generation and hashing of the gateway's own identifiers and secrets (docs/api.md
/// "Identifiers are strings", "Authentication"). Every random value comes from the system
/// CSPRNG; tokens are stored only as SHA-256 hashes.
public enum Identifiers {
    /// `tgw_` + 43 base64url characters (32 random bytes). An app or admin token.
    public static func token() -> String { "tgw_" + base64url(randomBytes(32)) }
    /// `whsec_` + 43 base64url characters. Signs webhook deliveries.
    public static func webhookSecret() -> String { "whsec_" + base64url(randomBytes(32)) }
    /// `req_` + 43 base64url characters. The only credential needed to poll an access request.
    public static func requestId() -> String { "req_" + base64url(randomBytes(32)) }
    /// `grant_` + 16 base64url characters (12 random bytes).
    public static func grantId() -> String { "grant_" + base64url(randomBytes(12)) }
    /// `dlv_` + 16 base64url characters.
    public static func deliveryId() -> String { "dlv_" + base64url(randomBytes(12)) }
    /// A per-response request id for `X-TGW-Request-Id`.
    public static func requestTraceId() -> String { base64url(randomBytes(9)) }

    /// `med_` + 32 base64url characters derived from TDLib's `remoteFile.unique_id`, so the
    /// same Telegram file always has the same media id, whichever message references it.
    public static func mediaId(uniqueId: String) -> String {
        let digest = SHA256.hash(data: Data(uniqueId.utf8))
        return "med_" + base64url(Data(digest.prefix(24)))
    }

    /// Lowercase hex SHA-256 of a token; what the store keeps.
    public static func hash(_ secret: String) -> String {
        SHA256.hash(data: Data(secret.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// True when `value` has the shape of a token: prefix + 43 base64url characters.
    public static func looksLikeToken(_ value: String) -> Bool {
        guard value.hasPrefix("tgw_"), value.count == 47 else { return false }
        return value.dropFirst(4).allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    public static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return Data(bytes)
    }

    public static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Message id conversion (docs/api.md "Message ids"). TDLib's internal message id is the
/// public one (the number in t.me links and the Bot API) shifted left by 20 bits; the low
/// bits distinguish local, scheduled and yet-unsent messages. The gateway converts at the
/// boundary and consumers never see the internal form.
public enum MessageId {
    public static func toPublic(_ internalId: Int64) -> Int64 { internalId >> 20 }
    public static func toInternal(_ publicId: Int64) -> Int64 { publicId << 20 }
}

/// HMAC-SHA256 signatures for webhook deliveries (docs/api.md "What the gateway sends").
public enum WebhookSignature {
    /// `sha256=` + lowercase hex of HMAC-SHA256(key = secret, message = body).
    public static func header(secret: String, body: Data) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: body, using: key)
        return "sha256=" + mac.map { String(format: "%02x", $0) }.joined()
    }
}
