import SwiftUI

/// Drives the Telegram login through `/v1/admin/auth/*`. QR code first; "Use phone number
/// instead" switches to phone → code → 2FA password. States that need typing (code,
/// password, e-mail) are shown whichever way the login started, because a QR scan on an
/// account with two-step verification still ends in `wait_password`.
struct LoginView: View {
    @Environment(AppModel.self) private var model
    @State private var usePhone = false
    @State private var phone = ""
    @State private var code = ""
    @State private var password = ""
    @State private var email = ""
    @State private var emailCode = ""
    @State private var qrImage: CGImage?
    @State private var qrToken: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                switch model.authState {
                case .waitPhoneNumber, .waitQRConfirmation:
                    if usePhone { phoneStep } else { qrStep }
                case .waitCode:
                    codeStep
                case .waitPassword:
                    passwordStep
                case .waitEmailAddress:
                    emailStep
                case .waitEmailCode:
                    emailCodeStep
                case .ready:
                    ProgressView("Logged in, loading…")
                case .loggingOut, .closed, .unknown:
                    otherStep
                }
                if let error = model.loginError {
                    ErrorLine(message: error)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: model.screen) {
            // docs/api.md: poll GET /v1/admin/auth every 2s while a QR code is displayed.
            while !Task.isCancelled {
                await model.refreshAuth()
                if !usePhone, model.authState == .waitPhoneNumber, !model.loginBusy {
                    await model.requestQR()
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .onAppear { refreshQR(model.auth?.qrLink) }
        .onChange(of: model.auth?.qrLink) { _, link in
            refreshQR(link)
        }
    }

    // MARK: QR

    @ViewBuilder
    private var qrStep: some View {
        Text("Scan with your phone")
            .font(.headline)
        Text("Open Telegram on your phone → Settings → Devices → Link Desktop Device, then point the camera at this code.")
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
        HStack {
            Spacer()
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.white)
                    .frame(width: 216, height: 216)
                if let qrImage {
                    Image(decorative: qrImage, scale: 1)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: 200, height: 200)
                        .accessibilityLabel("QR code for Telegram login")
                } else {
                    ProgressView()
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
            Spacer()
        }
        Text("The code renews itself every 30 seconds or so; keep this panel open until the phone confirms.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        if let link = model.auth?.qrLink {
            Text(link)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        HStack {
            Button("New code") { Task { await model.requestQR() } }
                .disabled(model.loginBusy)
            Spacer()
            Button("Use phone number instead") { usePhone = true }
        }
    }

    private func refreshQR(_ link: String?) {
        guard let link, LoginLink.isValid(link) else {
            qrImage = nil
            qrToken = nil
            return
        }
        let token = LoginLink.token(from: link)
        guard token != qrToken else { return }
        qrToken = token
        qrImage = QRCodeImage.make(link, scale: 8)
    }

    // MARK: Phone, code, password

    @ViewBuilder
    private var phoneStep: some View {
        Text("Log in with your phone number")
            .font(.headline)
        Text("Telegram sends a code to the Telegram app on another device, or by SMS.")
            .font(.callout)
        TextField("+15551234567", text: $phone)
            .textFieldStyle(.roundedBorder)
            .onSubmit { submitPhone() }
        HStack {
            Button("Use QR code instead") {
                usePhone = false
            }
            Spacer()
            Button("Send code") { submitPhone() }
                .keyboardShortcut(.defaultAction)
                .disabled(model.loginBusy || phone.trimmingCharacters(in: .whitespaces).count < 8)
        }
    }

    private func submitPhone() {
        Task { await model.submitPhone(phone) }
    }

    @ViewBuilder
    private var codeStep: some View {
        Text("Enter the login code")
            .font(.headline)
        Text(codeExplanation)
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
        TextField("12345", text: $code)
            .textFieldStyle(.roundedBorder)
            .font(.title3.monospaced())
            .onSubmit { submitCode() }
        HStack {
            Button("Start over") { Task { await model.requestQR(); usePhone = false } }
                .disabled(model.loginBusy)
            Spacer()
            Button("Continue") { submitCode() }
                .keyboardShortcut(.defaultAction)
                .disabled(model.loginBusy || code.trimmingCharacters(in: .whitespaces).count < 4)
        }
    }

    private var codeExplanation: String {
        var text = "Telegram sent a code"
        if let hint = model.auth?.phoneHint { text += " for \(hint)" }
        switch model.auth?.codeType {
        case "sms": text += " by SMS."
        case "call": text += " by phone call."
        case "telegram_message": text += " to the Telegram app on your other devices."
        default: text += " to your other Telegram devices or by SMS."
        }
        return text
    }

    private func submitCode() {
        Task { await model.submitCode(code) }
    }

    @ViewBuilder
    private var passwordStep: some View {
        Text("Two-step verification")
            .font(.headline)
        Text("This account has a two-step verification password (set in Telegram → Settings → Privacy and Security). It is sent to Telegram and never stored.")
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
        SecureField("Password", text: $password)
            .textFieldStyle(.roundedBorder)
            .onSubmit { submitPassword() }
        if let hint = model.auth?.passwordHint, !hint.isEmpty {
            Text("Hint: \(hint)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        HStack {
            Spacer()
            Button("Log in") { submitPassword() }
                .keyboardShortcut(.defaultAction)
                .disabled(model.loginBusy || password.isEmpty)
        }
    }

    private func submitPassword() {
        Task {
            await model.submitPassword(password)
            if model.loginError != nil { password = "" }
        }
    }

    // MARK: E-mail

    @ViewBuilder
    private var emailStep: some View {
        Text("Login e-mail")
            .font(.headline)
        Text("Telegram asks for the e-mail address that receives login codes for this account.")
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
        TextField("you@example.com", text: $email)
            .textFieldStyle(.roundedBorder)
            .onSubmit { Task { await model.submitEmail(email) } }
        HStack {
            Spacer()
            Button("Continue") { Task { await model.submitEmail(email) } }
                .keyboardShortcut(.defaultAction)
                .disabled(model.loginBusy || !email.contains("@"))
        }
    }

    @ViewBuilder
    private var emailCodeStep: some View {
        Text("E-mail code")
            .font(.headline)
        Text("Enter the code Telegram e-mailed you.")
            .font(.callout)
        TextField("Code", text: $emailCode)
            .textFieldStyle(.roundedBorder)
            .font(.title3.monospaced())
            .onSubmit { Task { await model.submitEmailCode(emailCode) } }
        HStack {
            Spacer()
            Button("Continue") { Task { await model.submitEmailCode(emailCode) } }
                .keyboardShortcut(.defaultAction)
                .disabled(model.loginBusy || emailCode.isEmpty)
        }
    }

    // MARK: Other

    @ViewBuilder
    private var otherStep: some View {
        Text(model.authState.label)
            .font(.headline)
        Text(model.authState == .loggingOut
             ? "The gateway is ending its Telegram session. This takes a few seconds."
             : "The gateway's Telegram client is in an unexpected state. Restarting the gateway usually clears it.")
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
        HStack {
            Spacer()
            Button("Restart gateway") { model.restartGateway() }
        }
    }
}

#Preview("QR") {
    RootView().environment(AppModel.preview(.waitingForQR))
}

#Preview("Phone: code sent") {
    RootView().environment(AppModel.preview(.waitingForCode))
}

#Preview("2FA password") {
    RootView().environment(AppModel.preview(.waitingForPassword))
}
