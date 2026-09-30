import SwiftUI

/// Step 1 of setup: the Telegram key. "Continue" saves it and starts the gateway; the owner
/// never sees how the gateway is started. All plumbing lives in Gateway details.
struct ConnectView: View {
    @Environment(AppModel.self) private var model
    @State private var apiId = ""
    @State private var apiHash = ""
    @FocusState private var focus: Field?

    private enum Field { case id, hash }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
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
                        field("API hash", text: $apiHash, prompt: "32 letters and digits", problem: hashProblem, monospaced: true)
                            .focused($focus, equals: .hash)
                    }
                    if case .failed(let reason) = model.startPhase {
                        StartFailureCard(reason: reason)
                    }
                }
                .padding(PanelSize.margin)
                .padding(.top, 4)
            }
            FooterBar {
                if model.startPhase == .starting {
                    ProgressView().controlSize(.small)
                    Text("Starting the gateway…")
                        .font(TypeScale.secondary)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.editingKey {
                    Button("Cancel") { model.editingKey = false }
                }
                Button(isFailed ? "Try again" : "Continue", action: submit)
                    .buttonStyle(.primary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid || model.startPhase == .starting)
            }
        }
        .onAppear {
            apiId = model.config.apiId.map(String.init) ?? ""
            apiHash = model.config.apiHash ?? ""
            if apiId.isEmpty { focus = .id }
        }
    }

    private func field(_ label: String, text: Binding<String>, prompt: String, problem: String?, monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(TypeScale.sectionLabel)
                .foregroundStyle(.secondary)
            TextField("", text: text, prompt: Text(prompt).font(TypeScale.body))
                .textFieldStyle(.roundedBorder)
                .font(monospaced ? .system(size: 13, design: .monospaced) : TypeScale.body)
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

/// Set up before, but the gateway is not answering: say so, offer the one action.
struct GatewayDownView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: PanelSize.gap) {
            Spacer()
            switch model.startPhase {
            case .failed(let reason):
                StartFailureCard(reason: reason)
                startButton("Try again")
            case .starting:
                Card(tone: .attention) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Starting the gateway…")
                            .font(TypeScale.rowTitle)
                    }
                }
            case .idle:
                let hero = model.hero
                Card(tone: hero.tone) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(hero.title)
                            .font(TypeScale.hero)
                        if let detail = hero.detail {
                            Text(detail)
                                .font(TypeScale.body)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                startButton("Start gateway")
            }
            Spacer()
            Spacer()
        }
        .padding(PanelSize.margin)
    }

    private func startButton(_ title: String) -> some View {
        Button(title) { Task { await model.startGateway() } }
            .buttonStyle(.primary)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
    }
}

/// The gateway answers, but the app cannot read the key that lets it control the gateway.
struct KeyMissingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: PanelSize.gap) {
            Spacer()
            Card(tone: .failed) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Can't control the gateway")
                        .font(TypeScale.screenTitle)
                    Text("The gateway is running, but the app can't read its access key. Restarting the gateway writes a new one.")
                        .font(TypeScale.body)
                        .fixedSize(horizontal: false, vertical: true)
                    if let error = model.tokenError {
                        Text(error)
                            .font(TypeScale.secondary)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            HStack(spacing: 12) {
                Button("Check again") {
                    Task { await model.refresh() }
                }
                Button("Restart gateway") { model.restartGateway() }
                    .buttonStyle(.primary)
                    .keyboardShortcut(.defaultAction)
            }
            Spacer()
            Spacer()
        }
        .padding(PanelSize.margin)
    }
}

#Preview("Step 1") {
    RootView().environment(AppModel.preview(.unreachable, credentials: false, token: false, onboarded: false))
}

#Preview("Gateway down") {
    RootView().environment(AppModel.preview(.unreachable))
}

#Preview("Key missing") {
    RootView().environment(AppModel.preview(.loggedIn, token: false))
}
