import CoreImage
import Foundation
import Testing
@testable import TelegramGateway

/// The `tg://login?token=…` link and its QR rendering.
@Suite("Login link and QR")
struct LoginLinkTests {
    let link = "tg://login?token=AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA"

    @Test("Token is extracted from a valid link")
    func token() {
        #expect(LoginLink.token(from: link) == "AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA")
        #expect(LoginLink.isValid(link))
        #expect(LoginLink.isValid("TG://LOGIN?token=abc_-="))
    }

    @Test("Anything else is rejected")
    func invalid() {
        #expect(LoginLink.token(from: "") == nil)
        #expect(LoginLink.token(from: "https://t.me/login?token=abc") == nil)
        #expect(LoginLink.token(from: "tg://resolve?domain=telegram") == nil)
        #expect(LoginLink.token(from: "tg://login") == nil)
        #expect(LoginLink.token(from: "tg://login?token=") == nil)
        #expect(LoginLink.token(from: "tg://login?token=has space") == nil)
        #expect(LoginLink.token(from: "tg://login?token=<script>") == nil)
    }

    @Test("A rotated token counts as a change; the same token does not")
    func change() {
        let rotated = "tg://login?token=IB8eHRwbGhkYFxYVFBMSERAPDg0MCwoJCAcGBQQDAgE"
        #expect(LoginLink.changed(from: link, to: rotated))
        #expect(!LoginLink.changed(from: link, to: link))
        #expect(LoginLink.changed(from: nil, to: link))
        #expect(LoginLink.changed(from: link, to: nil))
        #expect(!LoginLink.changed(from: nil, to: nil))
    }

    @Test("The QR image decodes back to the link")
    func qrRoundTrip() throws {
        let image = try #require(QRCodeImage.make(link, scale: 8))
        #expect(image.width >= 8 * 21)
        #expect(image.width == image.height)
        let detector = try #require(CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let features = detector.features(in: CIImage(cgImage: image))
        let qr = try #require(features.compactMap { $0 as? CIQRCodeFeature }.first)
        #expect(qr.messageString == link)
    }

    @Test("Empty and oversized strings produce no image")
    func qrLimits() {
        #expect(QRCodeImage.make("") == nil)
        #expect(QRCodeImage.make(String(repeating: "x", count: 5000)) == nil)
    }
}
