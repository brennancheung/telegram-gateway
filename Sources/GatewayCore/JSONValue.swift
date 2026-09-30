import Foundation

/// A JSON document as a Swift value. This is the shape everything crossing the API takes: the
/// models in `Models.swift` render themselves into it, the server serialises it, `tgw` parses
/// responses into it. Objects keep their key order so output is stable and readable; absent
/// optional values are written as explicit `null` (docs/api.md "JSON").
public indirect enum JSONValue: Sendable, Equatable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object(JSONObjectValue)

    // MARK: Reading

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var doubleValue: Double? {
        if case .number(let n) = self { return n }
        return nil
    }

    public var intValue: Int? {
        if case .number(let n) = self { return Int(exactly: n) }
        return nil
    }

    public var int64Value: Int64? {
        if case .number(let n) = self { return Int64(exactly: n) }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var objectValue: JSONObjectValue? {
        if case .object(let o) = self { return o }
        return nil
    }

    public var isNull: Bool { self == .null }

    public subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    public subscript(index: Int) -> JSONValue? {
        guard let array = arrayValue, array.indices.contains(index) else { return nil }
        return array[index]
    }

    // MARK: Parsing

    public static func parse(_ data: Data) throws -> JSONValue {
        let any = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return try convert(any)
    }

    public static func parse(_ string: String) throws -> JSONValue {
        try parse(Data(string.utf8))
    }

    /// Converts a `JSONSerialization` tree. Key order of objects is lost (Foundation gives
    /// dictionaries), which only matters for output, never for reading.
    public static func convert(_ any: Any) throws -> JSONValue {
        switch any {
        case is NSNull: return .null
        case let s as String: return .string(s)
        case let n as NSNumber:
            // JSONSerialization reports booleans as NSNumber with the boolean objCType.
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            return .number(n.doubleValue)
        case let a as [Any]: return .array(try a.map(convert))
        case let d as [String: Any]:
            var object = JSONObjectValue()
            for key in d.keys.sorted() {
                guard let value = d[key] else { continue }
                object[key] = try convert(value)
            }
            return .object(object)
        default:
            throw GatewayError.invalid("unsupported JSON value \(type(of: any))")
        }
    }

    // MARK: Serialising

    /// Compact serialisation, keys in insertion order, `null` for `.null`. Deterministic:
    /// signing a webhook body signs exactly these bytes.
    public func serialized() -> Data {
        var out = ""
        write(into: &out)
        return Data(out.utf8)
    }

    public func serializedString() -> String {
        var out = ""
        write(into: &out)
        return out
    }

    /// Indented serialisation for humans (`tgw` output, logs).
    public func pretty() -> String {
        var out = ""
        write(into: &out, indent: 0, pretty: true)
        return out
    }

    private func write(into out: inout String, indent: Int = 0, pretty: Bool = false) {
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let n): out += JSONValue.format(n)
        case .string(let s): JSONValue.writeString(s, into: &out)
        case .array(let items):
            if items.isEmpty { out += "[]"; return }
            out += "["
            for (i, item) in items.enumerated() {
                if i > 0 { out += "," }
                if pretty { out += "\n" + String(repeating: "  ", count: indent + 1) }
                item.write(into: &out, indent: indent + 1, pretty: pretty)
            }
            if pretty { out += "\n" + String(repeating: "  ", count: indent) }
            out += "]"
        case .object(let object):
            if object.isEmpty { out += "{}"; return }
            out += "{"
            for (i, (key, value)) in object.enumerated() {
                if i > 0 { out += "," }
                if pretty { out += "\n" + String(repeating: "  ", count: indent + 1) }
                JSONValue.writeString(key, into: &out)
                out += pretty ? ": " : ":"
                value.write(into: &out, indent: indent + 1, pretty: pretty)
            }
            if pretty { out += "\n" + String(repeating: "  ", count: indent) }
            out += "}"
        }
    }

    private static func format(_ n: Double) -> String {
        if n.isNaN || n.isInfinite { return "null" }
        if n == n.rounded(), abs(n) < 1e15 { return String(Int64(n)) }
        return String(n)
    }

    private static func writeString(_ s: String, into out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }
}

/// An ordered JSON object. Lookup is linear, which is fine for the small objects the API
/// carries; insertion order is what matters.
public struct JSONObjectValue: Sendable, Equatable, Hashable, Sequence {
    public private(set) var entries: [(key: String, value: JSONValue)] = []

    public init() {}

    public init(_ entries: [(key: String, value: JSONValue)]) {
        for (key, value) in entries { self[key] = value }
    }

    public var isEmpty: Bool { entries.isEmpty }
    public var keys: [String] { entries.map(\.key) }

    public subscript(key: String) -> JSONValue? {
        get { entries.first { $0.key == key }?.value }
        set {
            if let index = entries.firstIndex(where: { $0.key == key }) {
                if let newValue { entries[index].value = newValue } else { entries.remove(at: index) }
            } else if let newValue {
                entries.append((key, newValue))
            }
        }
    }

    public func makeIterator() -> IndexingIterator<[(key: String, value: JSONValue)]> {
        entries.makeIterator()
    }

    public static func == (lhs: JSONObjectValue, rhs: JSONObjectValue) -> Bool {
        lhs.entries.count == rhs.entries.count && lhs.entries.allSatisfy { rhs[$0.key] == $0.value }
    }

    public func hash(into hasher: inout Hasher) {
        for (key, value) in entries.sorted(by: { $0.key < $1.key }) {
            hasher.combine(key)
            hasher.combine(value)
        }
    }
}

extension JSONObjectValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self.init(elements.map { (key: $0.0, value: $0.1) })
    }
}

// MARK: Literals

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByNilLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(nilLiteral: ()) { self = .null }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(JSONObjectValue(elements.map { (key: $0.0, value: $0.1) }))
    }

    /// `.string(s)` or `.null`.
    public static func optional(_ s: String?) -> JSONValue { s.map { .string($0) } ?? .null }
    public static func optional(_ n: Int?) -> JSONValue { n.map { .number(Double($0)) } ?? .null }
    public static func optional(_ n: Int64?) -> JSONValue { n.map { .number(Double($0)) } ?? .null }
    /// Telegram identifiers are strings on the wire (docs/api.md "Identifiers are strings").
    public static func id(_ n: Int64) -> JSONValue { .string(String(n)) }
    public static func id(_ n: Int64?) -> JSONValue { n.map { .string(String($0)) } ?? .null }
    public static func date(_ d: Date?) -> JSONValue { d.map { .string(Timestamp.format($0)) } ?? .null }
}

// MARK: Codable (so models holding a JSONValue can be stored with JSONEncoder)

extension JSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let b = try? container.decode(Bool.self) { self = .bool(b); return }
        if let n = try? container.decode(Double.self) { self = .number(n); return }
        if let s = try? container.decode(String.self) { self = .string(s); return }
        if let a = try? container.decode([JSONValue].self) { self = .array(a); return }
        let d = try container.decode([String: JSONValue].self)
        var object = JSONObjectValue()
        for key in d.keys.sorted() { object[key] = d[key] }
        self = .object(object)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let b): try container.encode(b)
        case .number(let n): try container.encode(n)
        case .string(let s): try container.encode(s)
        case .array(let a): try container.encode(a)
        case .object(let o):
            var dict: [String: JSONValue] = [:]
            for (key, value) in o { dict[key] = value }
            try container.encode(dict)
        }
    }
}

/// RFC 3339 UTC timestamps (docs/api.md "Timestamps"): whole seconds for values from
/// Telegram, millisecond precision for values the gateway generates.
public enum Timestamp {
    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let whole = Date.ISO8601FormatStyle()

    /// Millisecond precision when the date has a fractional part, whole seconds otherwise.
    public static func format(_ date: Date) -> String {
        let milliseconds = Int64((date.timeIntervalSince1970 * 1000).rounded())
        let seconds = Date(timeIntervalSince1970: Double(milliseconds / 1000)).formatted(whole)
        let fraction = milliseconds % 1000
        if fraction == 0 { return seconds }
        // Insert the fraction ourselves: ISO8601FormatStyle truncates rather than rounds.
        return String(seconds.dropLast()) + String(format: ".%03dZ", fraction)
    }

    public static func parse(_ string: String) -> Date? {
        (try? Date(string, strategy: fractional)) ?? (try? Date(string, strategy: whole))
    }
}
