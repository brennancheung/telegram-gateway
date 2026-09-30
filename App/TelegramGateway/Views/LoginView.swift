import SwiftUI

/// Step 2: sign in to Telegram through `/v1/admin/auth/*`. The QR code is the screen; the
/// phone route is one link away. Code, password and e-mail steps are the same centred form
/// whichever way sign-in started, because a QR scan on an account with two-step
/// verification still ends at the password.
struct LoginView: View {
    @Environment(AppModel.self) private var model
    @State private var phone = ""
    @State private var code = ""
    @State private var password = ""
    @State private var email = ""
    @State private var emailCode = ""
    @State private var qrImage: CGImage?
    @State private var qrToken: String?

    var body: some View {
        Group {
            switch model.authState {
            case .waitPhoneNumber, .waitQRConfirmation:
                if model.loginMode == .phone { phoneStep } else { qrStep }
            case .waitCode:
                codeStep
            case .waitPassword:
                passwordStep
            case .waitEmailAddress:
                emailStep
            case .waitEmailCode:
                emailCodeStep
            case .waitRegistration:
                registrationStep
            case .ready, .loggingOut:
                ProgressView().controlSize(.small)
            case .closed, .unknown:
                stuckStep
            }
        }
        .task(id: model.screen) {
            // docs/api.md: poll GET /v1/admin/auth every 2s while a QR code is displayed.
            while !Task.isCancelled {
                await model.refreshAuth()
                // Ask for a code once per attempt; after a failure wait for Refresh instead
                // of retrying every 2s.
                if model.loginMode == .qr, model.authState == .waitPhoneNumber, !model.loginBusy, model.loginError == nil {
                    await model.requestQR()
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .onAppear { refreshQR(model.auth?.qrLink) }
        .onChange(of: model.auth?.qrLink) { _, link in refreshQR(link) }
    }

    // MARK: QR

    private var qrStep: some View {
        VStack(spacing: 14) {
            VStack(spacing: 4) {
                if !model.onboardingDone { StepIndicator(step: 2) }
                Text("Scan to sign in")
                    .font(TypeScale.screenTitle)
            }
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.white)
                if let qrImage, model.loginError == nil {
                    Image(decorative: qrImage, scale: 1)
                        .resizable()
                        .interpolation(.none)
                        .padding(12)
                        .accessibilityLabel("QR code for Telegram sign-in")
                } else if let error = model.loginError {
                    VStack(spacing: 8) {
                        Text("Couldn't get a code")
                            .font(TypeScale.rowTitle)
                            .foregroundStyle(.black)
                        Text(error)
                            .font(TypeScale.secondary)
                            .foregroundStyle(.black.opacity(0.6))
                            .multilineTextAlignment(.center)
                            .lineLimit(4)
                        Button("Refresh") { Task { await model.requestQR() } }
                            .buttonStyle(.primary)
                            .disabled(model.loginBusy)
                    }
                    .padding(16)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 224, height: 224)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))

            VStack(alignment: .leading, spacing: 5) {
                numbered(1, "Open Telegram on your phone")
                numbered(2, "Settings → Devices → Link Desktop Device")
                numbered(3, "Point it at this code")
            }

            Button("Use phone number instead") {
                model.loginError = nil
                model.loginMode = .phone
            }
            .buttonStyle(.link)
            .font(TypeScale.body)
        }
        .padding(PanelSize.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func numbered(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number)")
                .font(TypeScale.sectionLabel)
                .foregroundStyle(.secondary)
                .frame(width: 10, alignment: .trailing)
            Text(text)
                .font(TypeScale.body)
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

    // MARK: Forms

    private var phoneStep: some View {
        LoginForm(
            title: "Sign in with your phone number",
            sentence: "Telegram sends a login code to this number.",
            hint: "Include the country code.",
            button: "Send code",
            canSubmit: phone.trimmingCharacters(in: .whitespaces).count >= 8,
            submit: { Task { await model.submitPhone(phone) } },
            back: ("Use QR code instead", { model.loginError = nil; model.loginMode = .qr })
        ) {
            TextField("", text: $phone, prompt: Text("+1 555 123 4567"))
        }
    }

    private var codeStep: some View {
        LoginForm(
            title: "Enter the code",
            sentence: "Telegram just sent you a login code.",
            hint: Wording.codeDestination(type: model.auth?.codeType, phone: model.auth?.phoneHint),
            button: "Continue",
            canSubmit: code.trimmingCharacters(in: .whitespaces).count >= 4,
            submit: { Task { await model.submitCode(code) } },
            back: ("Back", { Task { await model.restartLogin(mode: .phone) } })
        ) {
            TextField("", text: $code, prompt: Text("12345"))
        }
    }

    private var passwordStep: some View {
        LoginForm(
            title: "Enter your password",
            sentence: "This account has two-step verification turned on.",
            hint: model.auth?.passwordHint.flatMap { $0.isEmpty ? nil : "Hint: \($0)" },
            button: "Sign in",
            canSubmit: !password.isEmpty,
            submit: {
                Task {
                    await model.submitPassword(password)
                    if model.loginError != nil { password = "" }
                }
            },
            back: ("Start over", { Task { await model.restartLogin(mode: .qr) } })
        ) {
            SecureField("", text: $password, prompt: Text("Password"))
        }
    }

    private var emailStep: some View {
        LoginForm(
            title: "Enter your login email",
            sentence: "Telegram sends this account's login codes by email.",
            hint: nil,
            button: "Continue",
            canSubmit: email.contains("@"),
            submit: { Task { await model.submitEmail(email) } },
            back: ("Start over", { Task { await model.restartLogin(mode: .qr) } })
        ) {
            TextField("", text: $email, prompt: Text("you@example.com"))
        }
    }

    private var emailCodeStep: some View {
        LoginForm(
            title: "Enter the email code",
            sentence: "Telegram just emailed you a login code.",
            hint: nil,
            button: "Continue",
            canSubmit: !emailCode.trimmingCharacters(in: .whitespaces).isEmpty,
            submit: { Task { await model.submitEmailCode(emailCode) } },
            back: ("Start over", { Task { await model.restartLogin(mode: .qr) } })
        ) {
            TextField("", text: $emailCode, prompt: Text("Code"))
        }
    }

    private var registrationStep: some View {
        LoginForm(
            title: "No Telegram account for this number",
            sentence: "The gateway only signs in to an account that already exists.",
            hint: nil,
            button: "Try another number",
            canSubmit: true,
            submit: { Task { await model.restartLogin(mode: .phone) } },
            back: ("Use QR code instead", { Task { await model.restartLogin(mode: .qr) } })
        ) {
            EmptyView()
        }
    }

    private var stuckStep: some View {
        LoginForm(
            title: "Telegram isn't responding",
            sentence: "Restarting the gateway reconnects it.",
            hint: nil,
            button: "Restart gateway",
            canSubmit: true,
            submit: { model.restartGateway() },
            back: nil
        ) {
            EmptyView()
        }
    }
}

/// One sign-in step: title, one sentence, the field, a hint under it, the button. Vertically
/// centred so there is no blank half-panel under a top-anchored form. Return submits.
struct LoginForm<Field: View>: View {
    @Environment(AppModel.self) private var model
    var title: String
    var sentence: String
    var hint: String?
    var button: String
    var canSubmit: Bool
    var submit: () -> Void
    var back: (title: String, action: () -> Void)?
    @ViewBuilder var field: Field
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                if !model.onboardingDone { StepIndicator(step: 2) }
                Text(title)
                    .font(TypeScale.screenTitle)
                Text(sentence)
                    .font(TypeScale.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 4) {
                field
                    .textFieldStyle(.roundedBorder)
                    .font(TypeScale.body)
                    .controlSize(.large)
                    .focused($focused)
                    .onSubmit { if canSubmit, !model.loginBusy { submit() } }
                if let error = model.loginError {
                    Text(error)
                        .font(TypeScale.secondary)
                        .foregroundStyle(Tone.failed.color)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let hint {
                    Text(hint)
                        .font(TypeScale.secondary)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                if let back {
                    Button(back.title, action: back.action)
                        .buttonStyle(.link)
                        .font(TypeScale.body)
                }
                Spacer()
                if model.loginBusy { ProgressView().controlSize(.small) }
                Button(button, action: submit)
                    .buttonStyle(.primary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit || model.loginBusy)
            }
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .offset(y: -24)
        .onAppear { focused = true }
    }
}

#Preview("QR") {
    RootView().environment(AppModel.preview(.waitingForQR, onboarded: false))
}

#Preview("Code") {
    RootView().environment(AppModel.preview(.waitingForCode, onboarded: false))
}

#Preview("Password") {
    RootView().environment(AppModel.preview(.waitingForPassword, onboarded: false))
}
