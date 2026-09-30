import CoreGraphics
import CoreImage
import Foundation
import Testing

@testable import QRCode

@Suite struct QRCodeTests {
    /// Renders the symbol to a bitmap and decodes it with CoreImage's QR detector, so the
    /// whole encoder (tables, Reed-Solomon, placement, masking, format bits) is verified
    /// against an independent implementation.
    private func decode(_ qr: QRCode) throws -> String {
        let scale = 6
        let quiet = 4
        let side = (qr.size + quiet * 2) * scale
        let context = try #require(CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.setFillColor(gray: 0, alpha: 1)
        for y in 0..<qr.size {
            for x in 0..<qr.size where qr.isDark(x: x, y: y) {
                // CGContext's origin is bottom-left; flip y so the image matches the grid.
                let rect = CGRect(
                    x: (x + quiet) * scale, y: side - (y + quiet + 1) * scale, width: scale, height: scale
                )
                context.fill(rect)
            }
        }
        let image = try #require(context.makeImage())
        let detector = try #require(CIDetector(
            ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
        ))
        let features = detector.features(in: CIImage(cgImage: image))
        let feature = try #require(features.first as? CIQRCodeFeature)
        return try #require(feature.messageString)
    }

    @Test(arguments: [
        "A",
        "tg://login?token=AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA",
        "https://example.com/some/longer/path?with=query&and=more&parameters=1234567890",
        String(repeating: "Telegram Gateway ", count: 20),
        String(repeating: "0123456789", count: 60),
    ])
    func roundTripsThroughCoreImage(text: String) throws {
        let qr = try QRCode.encode(text)
        #expect(try decode(qr) == text)
    }

    @Test(arguments: QRCode.ErrorCorrection.allCases)
    func everyErrorCorrectionLevelDecodes(level: QRCode.ErrorCorrection) throws {
        let text = "tg://login?token=" + String(repeating: "x", count: 40)
        let qr = try QRCode.encode(text, errorCorrection: level)
        #expect(qr.errorCorrection == level)
        #expect(try decode(qr) == text)
    }

    @Test func picksTheSmallestVersion() throws {
        // Version 1 at level M holds 14 data bytes: 4 + 8 count bits + 8×14 = 124 ≤ 128.
        #expect(try QRCode.encode(String(repeating: "a", count: 14)).version == 1)
        #expect(try QRCode.encode(String(repeating: "a", count: 15)).version == 2)
        // A typical tg://login link (about 60 bytes) needs version 4 at level M.
        let link = "tg://login?token=" + String(repeating: "x", count: 43)
        let qr = try QRCode.encode(link)
        #expect(qr.version == 4)
        #expect(qr.size == 33)
    }

    @Test func largePayloadUsesHighVersionAndStillDecodes() throws {
        let text = String(repeating: "abcdefghij", count: 100)
        let qr = try QRCode.encode(text)
        #expect(qr.version >= 20)
        #expect(try decode(qr) == text)
    }

    @Test func tooLongIsAnError() {
        #expect(throws: QRCode.EncodingError.tooLong) {
            try QRCode.encode([UInt8](repeating: 0x41, count: 3000))
        }
    }

    @Test func finderPatternsAreInTheCorners() throws {
        let qr = try QRCode.encode("hello")
        let n = qr.size
        for (cx, cy) in [(3, 3), (n - 4, 3), (3, n - 4)] {
            #expect(qr.isDark(x: cx, y: cy))
            #expect(!qr.isDark(x: cx - 2, y: cy - 2))
            #expect(qr.isDark(x: cx - 3, y: cy - 3))
        }
        #expect(qr.isDark(x: 8, y: n - 8), "the always-dark module")
    }

    @Test func terminalRenderingHasTheExpectedShape() throws {
        let qr = try QRCode.encode("hello")
        let compact = qr.terminalLines(compact: true)
        let large = qr.terminalLines(compact: false)
        #expect(compact.count == (qr.size + 8 + 1) / 2)
        #expect(large.count == qr.size + 8)
        #expect(compact.allSatisfy { $0.hasSuffix("\u{1b}[0m") })
    }
}
