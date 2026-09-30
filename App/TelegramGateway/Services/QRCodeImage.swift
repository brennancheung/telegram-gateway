import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Renders a string as a QR code bitmap with CoreImage's `CIQRCodeGenerator`. Used for the
/// `tg://login?token=…` link the owner scans with the Telegram app on the phone.
enum QRCodeImage {
    /// A crisp (nearest-neighbour scaled) QR image, `scale` pixels per module, or nil when
    /// the string cannot be encoded (empty, or longer than a QR code can hold).
    static func make(_ string: String, scale: CGFloat = 8) -> CGImage? {
        guard !string.isEmpty, let data = string.data(using: .utf8) else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext(options: [.useSoftwareRenderer: false])
        return context.createCGImage(scaled, from: scaled.extent)
    }
}

/// The `tg://login?token=…` link Telegram uses for QR login (docs/api.md `GET /v1/admin/auth`).
/// The token is 32 random bytes in base64url; the link changes when Telegram rotates it.
enum LoginLink {
    /// The token part of a valid link, or nil for anything that is not a Telegram login link.
    static func token(from link: String) -> String? {
        guard let components = URLComponents(string: link),
              components.scheme?.lowercased() == "tg",
              components.host?.lowercased() == "login",
              let token = components.queryItems?.first(where: { $0.name == "token" })?.value,
              !token.isEmpty,
              token.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "=" })
        else { return nil }
        return token
    }

    static func isValid(_ link: String) -> Bool {
        token(from: link) != nil
    }

    /// Whether the daemon handed out a new link (the token changed), which is when the QR
    /// image must be redrawn.
    static func changed(from old: String?, to new: String?) -> Bool {
        guard let new else { return old != nil }
        guard let old else { return true }
        return token(from: old) != token(from: new)
    }
}
