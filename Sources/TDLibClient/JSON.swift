import Foundation

/// A decoded TDLib JSON object, exactly as `JSONSerialization` produces it: `@type` names the
/// TDLib type, other keys are that type's fields (`Int`/`Double`/`String`/`Bool`/`[Any]`/
/// `[String: Any]`). TDLib's `int64` fields arrive as strings, `bytes` fields as base64 strings.
public typealias JSONObject = [String: Any]

/// `JSONObject` is not `Sendable` because of `Any`, but everything `JSONSerialization` returns
/// is an immutable value (numbers, strings, nested arrays/dictionaries), so sharing one between
/// isolation domains is safe as long as nobody mutates it. This box is how objects travel from
/// the receive thread to an actor and out of it.
public struct JSONBox: @unchecked Sendable {
    public let object: JSONObject

    public init(_ object: JSONObject) {
        self.object = object
    }
}

/// One object received from `td_receive`, split into the routing fields TDLib adds.
struct Envelope {
    /// `@client_id`: which client this object belongs to. `td_receive` is global across clients.
    let clientId: Int32
    /// `@extra`: echoed back from the request this object answers. Absent on updates.
    let extra: String?
    /// `@type`.
    let type: String
    let object: JSONObject

    /// Decodes one line of `td_receive` output. Returns nil for anything that is not a JSON
    /// object with `@type` and `@client_id`.
    static func decode(_ data: Data) -> Envelope? {
        guard let any = try? JSONSerialization.jsonObject(with: data),
              let object = any as? JSONObject,
              let type = object["@type"] as? String
        else { return nil }
        let clientId: Int32
        switch object["@client_id"] {
        case let n as Int: clientId = Int32(n)
        case let n as NSNumber: clientId = n.int32Value
        default: return nil
        }
        // We only ever send string extras; TDLib echoes whatever it got, so keep other
        // representations readable rather than dropping the response.
        let extra: String?
        switch object["@extra"] {
        case nil: extra = nil
        case let s as String: extra = s
        case let n as NSNumber: extra = n.stringValue
        case let other: extra = String(describing: other)
        }
        return Envelope(clientId: clientId, extra: extra, type: type, object: object)
    }

    static func decode(_ string: String) -> Envelope? {
        decode(Data(string.utf8))
    }
}

/// Encodes a request for `td_send`. Throws if the dictionary holds something
/// `JSONSerialization` cannot encode (which is a programming error, not a runtime condition).
func encodeRequest(_ request: JSONObject) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
    guard let string = String(data: data, encoding: .utf8) else {
        throw TDLibError(code: 400, message: "request is not valid UTF-8")
    }
    return string
}

extension Dictionary where Key == String, Value == Any {
    /// TDLib encodes `int53` fields as JSON numbers and `int64` fields as strings; this reads
    /// either so callers do not have to know which one a field is.
    public func int64(_ key: String) -> Int64? {
        switch self[key] {
        case let n as Int64: return n
        case let n as Int: return Int64(n)
        case let n as NSNumber: return n.int64Value
        case let s as String: return Int64(s)
        default: return nil
        }
    }

    public func int(_ key: String) -> Int? {
        int64(key).flatMap { Int(exactly: $0) }
    }

    public func string(_ key: String) -> String? {
        self[key] as? String
    }

    public func bool(_ key: String) -> Bool? {
        self[key] as? Bool
    }

    public func object(_ key: String) -> JSONObject? {
        self[key] as? JSONObject
    }

    public func array(_ key: String) -> [Any]? {
        self[key] as? [Any]
    }

    /// The `@type` field.
    public var type: String? {
        self["@type"] as? String
    }
}
