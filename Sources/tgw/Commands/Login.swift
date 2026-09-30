import ArgumentParser
import Foundation
import QRCode
import TDLibClient

struct Login: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Log in to Telegram (QR code by default, or --phone for number + code + password)."
    )

    @OptionGroup var credentials: CredentialOptions

    @Option(help: "Phone number in international format (+15551234567). Uses code/password login instead of QR.")
    var phone: String?

    @Flag(help: "Draw the QR code with full-size blocks (two characters per module) instead of half-blocks.")
    var largeQr = false

    func run() async throws {
        let creds = try credentials.resolve()
        let phone = phone
        let largeQr = largeQr
        try await Session.run(credentials: creds, command: "login") { session in
            try await LoginFlow(session: session, phone: phone, largeQr: largeQr).drive()
        }
    }
}

/// Walks the authorization states until `ready`, answering each one.
struct LoginFlow: Sendable {
    let session: Session
    let phone: String?
    let largeQr: Bool

    func drive() async throws {
        let client = session.client
        var seen = 0
        var qrShown = 0
        while true {
            let (state, version) = try await client.nextAuthState(after: seen)
            seen = version
            switch state {
            case .waitTdlibParameters:
                _ = try await client.send(session.parameters.request)

            case .waitPhoneNumber:
                if let phone {
                    print("Requesting a login code for \(phone)…")
                    _ = try await client.send("setAuthenticationPhoneNumber", ["phone_number": phone])
                } else {
                    _ = try await client.send("requestQrCodeAuthentication", ["other_user_ids": [Int64]()])
                }

            case .waitOtherDeviceConfirmation(let link):
                qrShown += 1
                print(qrShown == 1
                    ? "\nScan this with Telegram on your phone: Settings → Devices → Link Desktop Device"
                    : "\nThe previous code expired; here is a fresh one:")
                print()
                let qr = try QRCode.encode(link)
                for line in qr.terminalLines(compact: !largeQr) { print(line) }
                print("\nLink: \(link)")
                print("Waiting for confirmation… (Ctrl-C to abort)")

            case .waitCode:
                try await retrying("checkAuthenticationCode") {
                    ["code": try Prompt.line("Code from Telegram (SMS or another device): ")]
                }

            case .waitPassword(let hint):
                let label = hint.isEmpty
                    ? "Two-step verification password: "
                    : "Two-step verification password (hint: \(hint)): "
                try await retrying("checkAuthenticationPassword") {
                    ["password": try Prompt.secret(label)]
                }

            case .waitEmailAddress:
                try await retrying("setAuthenticationEmailAddress") {
                    ["email_address": try Prompt.line("Login email address: ")]
                }

            case .waitEmailCode:
                try await retrying("checkAuthenticationEmailCode") {
                    ["code": ["@type": "emailAddressAuthenticationCode", "code": try Prompt.line("Code from the email: ")]]
                }

            case .waitRegistration:
                throw CLIError("this phone number has no Telegram account; create one on a phone first")

            case .waitPremiumPurchase:
                throw CLIError("Telegram asks for a Premium purchase to log in this account; not supported here")

            case .ready:
                try await session.goOffline()
                let me = try await client.send("getMe")
                print("\nLogged in as \(Describe.user(me))")
                print("Data: \(session.paths.tdlib.path)")
                return

            case .loggingOut, .closing, .closed:
                throw CLIError("TDLib is shutting down (\(state))")

            case .unknown(let type):
                throw CLIError("unexpected authorization state \(type)")
            }
        }
    }

    /// Prompts and sends until TDLib accepts the answer. A wrong code or password comes back
    /// as an error without a new authorization state, so this loops instead of hanging.
    private func retrying(_ type: String, _ fields: () throws -> JSONObject) async throws {
        while true {
            let request = try fields()
            do {
                _ = try await session.client.send(type, request)
                return
            } catch let error as TDLibError {
                warn("Rejected: \(error.message). Try again.")
            }
        }
    }
}
