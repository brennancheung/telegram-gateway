import SwiftUI

/// Setup and sign-in: one centred column, no sidebar. Step 1 connects (the Telegram key, and
/// starting the gateway), step 2 signs in; step 3 (choosing chats) happens in the Chats
/// section once the sidebar appears.
struct SetupFlowView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch model.screen {
            case .connect:
                ConnectStep()
            case .login:
                LoginStep()
            default:
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Telegram Gateway")
    }
}

/// The width of a setup form. Narrow on purpose: one thing to read, one thing to do.
private let flowWidth: CGFloat = 380

// MARK: Step 1

/// The Telegram key. "Continue" saves it and starts the gateway; the user never sees how
/// the gateway is started. All plumbing lives in the Gateway section.
struct ConnectStep: View {
    @Environment(AppModel.self) private var model
    @State private var apiId = ""
    @State private var apiHash = ""
    @FocusState private var focus: Field?

    private enum Field { case id, hash }

    var body: some View {
        VStack(alignment: .leading, spacing: PanelSize.gap) {
            VStack(alignment: .leading, spacing: 6) {
                if !model.onboardingDone { StepIndicator(step: 1) }
                Text(model.editingKey ? "Change the Telegram key" : "Connect to Telegram")
                    .font(TypeScale.screenTitle)
                Text("Telegram asks each app that connects to it for its own key.")
                    .font(TypeScale.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Link("Get your key at my.telegram.org ↗", destination: URL(string: "https://my.telegram.org")!)
                    .font(TypeScale.body)
                Text("API development tools → create an app (any name, platform Desktop)")
                    .font(TypeScale.secondary)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 10) {
                field("API ID", text: $apiId, prompt: "12345678", problem: idProblem)
                    .focused($focus, equals: .id)
                field("API hash", text: $apiHash, prompt: "32 letters and digits", problem: hashProblem)
                    .focused($focus, equals: .hash)
            }
            if case .failed(let reason) = model.startPhase {
                StartFailureCard(reason: reason)
            }
            HStack(spacing: 8) {
                if model.startPhase == .starting {
                    ProgressView().controlSize(.small)
                    Text("Starting the gateway…")
                        .font(TypeScale.secondary)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.editingKey {
                    Button("Cancel") { model.cancelConnect() }
                        .keyboardShortcut(.cancelAction)
                }
                Button(isFailed ? "Try again" : "Continue", action: submit)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid || model.startPhase == .starting)
            }
        }
        .frame(width: flowWidth)
        .onAppear {
            apiId = model.config.apiId.map(String.init) ?? ""
            apiHash = model.config.apiHash ?? ""
            if apiId.isEmpty { focus = .id }
        }
    }

    private func field(_ label: String, text: Binding<String>, prompt: String, problem: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(TypeScale.sectionLabel)
                .foregroundStyle(.secondary)
            TextField("", text: text, prompt: Text(prompt))
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .onSubmit(submit)
            if let problem {
                Text(problem)
                    .font(TypeScale.secondary)
                    .foregroundStyle(Tone.failed.color)
            }
        }
    }

    private var trimmedId: String { apiId.trimmingCharacters(in: .whitespaces) }
    private var trimmedHash: String { apiHash.trimmingCharacters(in: .whitespaces).lowercased() }
    private var isValid: Bool { GatewayConfig(apiId: Int(trimmedId), apiHash: trimmedHash).hasCredentials }
    private var isFailed: Bool { if case .failed = model.startPhase { return true }; return false }

    private var idProblem: String? {
        guard !trimmedId.isEmpty, (Int(trimmedId) ?? 0) <= 0 else { return nil }
        return "The API ID is a number."
    }

    private var hashProblem: String? {
        guard !trimmedHash.isEmpty, trimmedHash.count != 32 || !trimmedHash.allSatisfy(\.isHexDigit) else { return nil }
        return "The API hash is 32 characters, digits and a–f only (\(trimmedHash.count) so far)."
    }

    private func submit() {
        guard isValid, model.startPhase != .starting, let id = Int(trimmedId) else { return }
        Task { await model.connect(apiId: id, apiHash: trimmedHash) }
    }
}

/// "The gateway didn't start", the reason in one line, and the way to the log.
struct StartFailureCard: View {
    @Environment(AppModel.self) private var model
    var reason: String

    var body: some View {
        Card(tone: .failed) {
            VStack(alignment: .leading, spacing: 4) {
                Text("The gateway didn't start")
                    .font(TypeScale.rowTitle)
                Text(reason)
                    .font(TypeScale.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
                Button("Show log") { showGatewayLog(model.daemon) }
                    .buttonStyle(.link)
                    .font(TypeScale.secondary)
            }
        }
    }
}

/// Opens the gateway's log, or its folder when no log exists yet.
@MainActor
func showGatewayLog(_ daemon: DaemonManager) {
    let url = daemon.logURL
    if FileManager.default.fileExists(atPath: url.path) {
        NSWorkspace.shared.open(url)
    } else {
        NSWorkspace.shared.activateFileViewerSelecting([GatewayConfig.logDirectory])
    }
}

// MARK: Step 2

/// Sign in to Telegram through `/v1/admin/auth/*`. The QR code is the screen; the phone
/// route is one link away. Code, password and e-mail steps are the same form whichever way
/// sign-in started, because a QR scan on an account with two-step verification still ends
/// at the password.
struct LoginStep: View {
    @Environment(AppModel.self) private var model
    @State private var phone = ""
    @State private var code = ""
    @State private var password = ""
    @State private var email = ""
    @State private var emailCode = ""
    @State private var qrImage: CGImage?
    @State private var qrToken: String?

    var body: some View {
        VStack(spacing: 0) {
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The way out when Telegram rejects the key from step 1.
            Button("Change the Telegram key…") { model.editingKey = true }
                .buttonStyle(.link)
                .font(TypeScale.secondary)
                .padding(.bottom, 14)
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

    /// The code on the left, what to do with it on the right: the window has the width.
    private var qrStep: some View {
        HStack(alignment: .center, spacing: 36) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.white)
                if let qrImage, model.loginError == nil {
                    Image(decorative: qrImage, scale: 1)
                        .resizable()
                        .interpolation(.none)
                        .padding(14)
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
                            .lineLimit(5)
                        Button("Refresh") { Task { await model.requestQR() } }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.loginBusy)
                    }
                    .padding(18)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 256, height: 256)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))

            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    if !model.onboardingDone { StepIndicator(step: 2) }
                    Text("Scan to sign in")
                        .font(TypeScale.screenTitle)
                }
                VStack(alignment: .leading, spacing: 6) {
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
            .fixedSize()
        }
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

    /// Why the last attempt to bring Telegram up failed, if one was made.
    private var stuckReason: String? {
        if case .failed(let reason) = model.startPhase { return reason }
        return nil
    }

    private var stuckStep: some View {
        LoginForm(
            title: "Telegram isn't running in the gateway",
            sentence: stuckReason ?? "The gateway has not started its Telegram connection.",
            hint: nil,
            button: model.startPhase == .starting ? "Starting…" : "Try again",
            canSubmit: model.startPhase != .starting,
            submit: { model.reviveTelegram() },
            back: nil
        ) {
            EmptyView()
        }
    }
}

/// One sign-in step: title, one sentence, the field, a hint (or the error) under it, the
/// button. Return submits.
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
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit || model.loginBusy)
            }
        }
        .frame(width: flowWidth - 40)
        .onAppear { focused = true }
    }
}

#Preview("Step 1") {
    MainWindowView()
        .environment(AppModel.preview(.unreachable, credentials: false, token: false, onboarded: false))
        .frame(width: 820, height: 560)
}

#Preview("Step 2") {
    MainWindowView()
        .environment(AppModel.preview(.waitingForQR, onboarded: false))
        .frame(width: 820, height: 560)
}
