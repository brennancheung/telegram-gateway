import Foundation
import Testing

@testable import TDLibClient

@Suite struct EnvelopeTests {
    @Test func decodesRoutingFields() {
        let envelope = Envelope.decode(#"{"@type":"ok","@client_id":3,"@extra":"3-abc-1"}"#)
        #expect(envelope?.clientId == 3)
        #expect(envelope?.extra == "3-abc-1")
        #expect(envelope?.type == "ok")
    }

    @Test func updateHasNoExtra() {
        let envelope = Envelope.decode(#"{"@type":"updateOption","@client_id":1,"name":"version","value":{"@type":"optionValueString","value":"1.8.67"}}"#)
        #expect(envelope?.extra == nil)
        #expect(envelope?.object.object("value")?.string("value") == "1.8.67")
    }

    @Test func rejectsMalformed() {
        #expect(Envelope.decode("not json") == nil)
        #expect(Envelope.decode(#"[1,2,3]"#) == nil)
        #expect(Envelope.decode(#"{"@client_id":1}"#) == nil, "missing @type")
        #expect(Envelope.decode(#"{"@type":"ok"}"#) == nil, "missing @client_id")
    }

    @Test func int64FieldsComeAsStringsOrNumbers() {
        let object: JSONObject = ["a": "9007199254740993", "b": 42, "c": NSNumber(value: Int64(-7))]
        #expect(object.int64("a") == 9_007_199_254_740_993)
        #expect(object.int64("b") == 42)
        #expect(object.int64("c") == -7)
        #expect(object.int64("missing") == nil)
    }

    @Test func requestEncodingIsDeterministic() throws {
        let encoded = try encodeRequest(["@type": "getChat", "chat_id": -1_001_234, "@extra": "x"])
        #expect(encoded == #"{"@extra":"x","@type":"getChat","chat_id":-1001234}"#)
    }
}
