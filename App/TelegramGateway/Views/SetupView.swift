import SwiftUI

/// First run: Telegram API credentials, then starting the gateway. Also shown whenever the
/// daemon stops answering, with the credentials section collapsed.
struct SetupView: View {
    @Environment(AppModel.self) private var model
    @State private var apiId = ""
    @State private var apiHash = ""
    @State private var editingCredentials = false
    @State private var saved = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                credentialsSection
                Divider()
                gatewaySection
                if model.showSetup, model.reachable {
                    Button("Done") { model.showSetup = false }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .padding(12)
        }
        .onAppear {
            apiId = model.config.apiId.map(String.init) ?? ""
            apiHash = model.config.apiHash ?? ""
            editingCredentials = !model.config.hasCredentials
            model.daemon.locate(config: model.config)
            model.daemon.refreshAgentState()
        }
    }

    // MARK: Credentials

    @ViewBuilder
    private var credentialsSection: some View {
        PanelSectionHeader(title: "1. Telegram API credentials", trailing: model.config.hasCredentials ? "Saved" : nil)
        if editingCredentials {
            Text("Telegram requires every client program to identify itself with an **api_id** (a number) and an **api_hash** (32 hex characters). Create them once at [my.telegram.org](https://my.telegram.org) → API development tools; any title, platform Desktop.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            LabeledContent("api_id") {
                TextField("12345", text: $apiId)
                    .textFieldStyle(.roundedBorder)
            }
            LabeledContent("api_hash") {
                TextField("0123abcd…", text: $apiHash)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
            }
            HStack {
                if model.config.hasCredentials {
                    Button("Cancel") { editingCredentials = false }
                }
                Spacer()
                Button("Save") {
                    model.saveCredentials(apiId: Int(apiId.trimmingCharacters(in: .whitespaces)) ?? 0, apiHash: apiHash.trimmingCharacters(in: .whitespaces).lowercased())
                    if model.config.hasCredentials {
                        editingCredentials = false
                        saved = true
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!inputLooksValid)
            }
            if !inputLooksValid, !apiId.isEmpty || !apiHash.isEmpty {
                Text("api_id is a positive number; api_hash is exactly 32 hex characters.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            HStack {
                Text("api_id \(model.config.apiId.map(String.init) ?? "—") · api_hash \(maskedHash)")
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Edit") { editingCredentials = true }
            }
        }
        if let error = model.configError {
            ErrorLine(message: error)
        }
        Text("Stored in \(GatewayConfig.fileURL.path)")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .textSelection(.enabled)
    }

    private var inputLooksValid: Bool {
        GatewayConfig(apiId: Int(apiId.trimmingCharacters(in: .whitespaces)), apiHash: apiHash.trimmingCharacters(in: .whitespaces)).hasCredentials
    }

    private var maskedHash: String {
        guard let hash = model.config.apiHash, hash.count >= 8 else { return "—" }
        return hash.prefix(4) + "…" + hash.suffix(4)
    }

    // MARK: Gateway

    @ViewBuilder
    private var gatewaySection: some View {
        PanelSectionHeader(title: "2. Gateway", trailing: model.reachable ? "Running" : "Not running")
        Text("The gateway is a background process (a launchd LaunchAgent) that holds the Telegram login and serves the local API. It starts at login and keeps running when this app quits.")
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)

        daemonBinaryRow

        VStack(alignment: .leading, spacing: 6) {
            Label(model.daemon.agentState.label, systemImage: agentSymbol)
                .font(.callout)
            if model.daemon.agentState == .requiresApproval {
                Text("macOS asks you to allow it once: System Settings → General → Login Items & Extensions, switch on \"Telegram Gateway\" under \"Allow in the Background\".")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        HStack {
            Button(model.daemon.agentState == .enabled ? "Re-register" : "Start gateway") { model.startGateway() }
                .disabled(!model.config.hasCredentials || model.daemon.daemonURL == nil)
                .keyboardShortcut(.defaultAction)
            if model.daemon.agentState == .requiresApproval {
                Button("Open Login Items settings") { model.daemon.openLoginItemsSettings() }
            }
            if model.daemon.agentState == .enabled {
                Button("Stop and unregister") { model.daemon.unregister() }
            }
        }

        foregroundRow

        if let error = model.daemon.lastError {
            ErrorLine(message: error)
        }
        if model.config.hasCredentials, !model.reachable, model.daemon.agentState == .enabled || model.daemon.isForegroundRunning {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Waiting for the gateway at \(model.config.baseURL.absoluteString)…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        if let error = model.lastError, !model.reachable {
            Text(error)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
    }

    private var agentSymbol: String {
        switch model.daemon.agentState {
        case .enabled: "checkmark.circle"
        case .requiresApproval: "hand.raised"
        case .notRegistered: "circle.dashed"
        case .notFound, .unavailable: "questionmark.circle"
        }
    }

    @ViewBuilder
    private var daemonBinaryRow: some View {
        if let url = model.daemon.daemonURL {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "terminal")
                    .foregroundStyle(.secondary)
                Text(url.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ErrorLine(message: "GatewayDaemon binary not found.")
                Text("Development: run `swift build` in the repository so `.build/debug/GatewayDaemon` exists, then reopen this panel. Looked in:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(model.daemon.resolution.candidates) { candidate in
                    Text("\(candidate.source): \(candidate.url.path)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    @ViewBuilder
    private var foregroundRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                switch model.daemon.foreground {
                case .running(let pid):
                    Label("Running in foreground (pid \(pid))", systemImage: "play.circle")
                        .font(.callout)
                    Spacer()
                    Button("Stop") { model.daemon.stopForeground() }
                case .exited(let code):
                    Label("Foreground daemon exited (code \(code))", systemImage: "xmark.circle")
                        .font(.callout)
                        .foregroundStyle(.red)
                    Spacer()
                    Button("Run again") { model.runInForeground() }
                case .stopped:
                    Button("Run in foreground") { model.runInForeground() }
                        .disabled(!model.config.hasCredentials || model.daemon.daemonURL == nil || model.daemon.agentState == .enabled)
                    Text("Development fallback: runs the daemon as a child of this app. It stops when the app quits.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if case .exited = model.daemon.foreground {
                Text("See \(DaemonManager.foregroundLogURL.path)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
        }
    }
}

/// The daemon answers but no admin token is stored.
struct TokenMissingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Admin token not found", systemImage: "key.slash")
                .font(.headline)
            Text(model.config.secretsSource == .keychain
                 ? "The gateway is running, but the login Keychain has no item with service **TelegramGateway** and account **admin-token** (config.json selects the Keychain). The daemon writes it the first time it starts; the app reads it to call the admin API."
                 : "The gateway is running, but **\(GatewayConfig.secretsURL.path)** has no **admin-token** entry. The daemon writes it the first time it starts; the app reads it to call the admin API.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Text("What to do")
                    .font(.subheadline.weight(.semibold))
                Text(model.config.secretsSource == .keychain
                     ? "1. If the daemon just started, wait a few seconds and click Retry.\n2. If a Keychain dialog asked whether TelegramGateway may use \"admin-token\", click Always Allow.\n3. Otherwise check the gateway log for a Keychain error, then Restart gateway from the menu."
                     : "1. If the daemon just started, wait a few seconds and click Retry.\n2. Check the gateway log (menu → Show gateway log) for an error writing secrets.json, then Restart gateway.\n3. If the daemon runs with another TGW_HOME, point the app at the same directory.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = model.tokenError {
                ErrorLine(message: error)
            }
            HStack {
                Spacer()
                Button("Retry") {
                    model.loadToken()
                    Task { await model.refresh() }
                }
                .keyboardShortcut(.defaultAction)
            }
            Spacer()
        }
        .padding(12)
    }
}

#Preview("Setup, first run") {
    RootView().environment(AppModel.preview(.unreachable, credentials: false, token: false))
}

#Preview("Setup, gateway down") {
    RootView().environment(AppModel.preview(.unreachable))
}

#Preview("Token missing") {
    RootView().environment(AppModel.preview(.loggedIn, token: false))
}
