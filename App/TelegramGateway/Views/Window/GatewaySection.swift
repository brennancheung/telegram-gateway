import SwiftUI

/// Everything about how the gateway runs: state, address, whether it starts at login, the
/// manual controls, the Telegram account and key, and where its files are. No other screen
/// shows any of this.
struct GatewaySection: View {
    @Environment(AppModel.self) private var model
    @State private var confirmingSignOut = false
    @State private var width: CGFloat = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PanelSize.gap) {
                if let error = model.daemon.lastError {
                    Card(tone: .failed) {
                        Text(error)
                            .font(TypeScale.body)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                if width >= 600 {
                    HStack(alignment: .top, spacing: PanelSize.gap) {
                        VStack(alignment: .leading, spacing: PanelSize.gap) { state; controls }
                        VStack(alignment: .leading, spacing: PanelSize.gap) { telegram; files }
                    }
                } else {
                    state
                    controls
                    telegram
                    files
                }
            }
            .padding(PanelSize.windowMargin)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onAppear {
            model.daemon.locate(config: model.config)
            model.daemon.refreshAgentState()
        }
        .confirmationDialog("Sign out of Telegram?", isPresented: $confirmingSignOut) {
            Button("Sign out", role: .destructive) { Task { await model.logout() } }
        } message: {
            Text("Nothing new is collected until you sign in again. Chats, apps and collected messages are kept.")
        }
    }

    private var state: some View {
        LabeledSection("Gateway", footer: model.daemon.agentState == .requiresApproval ? "macOS is waiting for you to allow the gateway to start at login." : nil) {
            RowCard {
                ValueRow("Status") {
                    HStack(spacing: 5) {
                        StatusDot(tone: model.reachable ? .ok : .failed, size: 6)
                        Text(model.reachable ? "Running" : "Not running")
                    }
                }
                ValueRow("Address", Wording.address(model.config.baseURL))
                if let health = model.health {
                    ValueRow("Version", health.version)
                    ValueRow("Started", health.startedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                    ValueRow("Uptime", Wording.elapsed(since: health.startedAt))
                }
                ValueRow("Starts at login", model.daemon.isForegroundRunning ? "No, runs inside this app" : model.daemon.agentState.startsAtLogin)
            }
        }
    }

    private var controls: some View {
        LabeledSection("Controls") {
            RowCard {
                control("Restart", detail: nil, button: "Restart", enabled: model.reachable) { model.restartGateway() }
                if model.daemon.agentState == .requiresApproval {
                    control("Allow at login", detail: "Switch on Telegram Gateway under Allow in the Background.", button: "Open settings") {
                        model.daemon.openLoginItemsSettings()
                    }
                }
                if model.daemon.agentState == .enabled {
                    control("Start at login", detail: "Turning this off stops the gateway.", button: "Turn off") {
                        model.daemon.unregister()
                        Task { await model.refresh() }
                    }
                } else {
                    control("Start at login", detail: "Keeps the gateway running after this app quits.", button: "Turn on", enabled: !model.daemon.isForegroundRunning) {
                        model.daemon.register(config: model.config)
                        Task { await model.refresh() }
                    }
                }
                if model.daemon.isForegroundRunning {
                    control("Run inside this app", detail: "Stops when the app quits.", button: "Stop") {
                        model.daemon.stopForeground()
                        Task { await model.refresh() }
                    }
                } else if model.daemon.agentState != .enabled {
                    control("Run inside this app", detail: "Stops when the app quits.", button: "Run", enabled: !model.reachable) {
                        model.daemon.runInForeground(config: model.config)
                        Task { try? await Task.sleep(for: .seconds(1)); await model.refresh() }
                    }
                }
                control("Log", detail: nil, button: "Show log") { showGatewayLog(model.daemon) }
            }
        }
    }

    private var telegram: some View {
        LabeledSection("Telegram") {
            RowCard {
                if model.authState.isLoggedIn {
                    control("Account", detail: model.accountName ?? "Signed in", button: "Sign out…") { confirmingSignOut = true }
                } else {
                    ValueRow("Account", "Not signed in")
                }
                ValueRow("API ID", model.config.apiId.map { String($0) } ?? "Not set")
                control("API hash", detail: maskedHash, button: "Edit…") { model.editingKey = true }
            }
        }
    }

    private var files: some View {
        LabeledSection("Files") {
            RowCard {
                path("Program", model.daemon.daemonURL?.path ?? "Not found")
                path("Settings", GatewayConfig.fileURL.path)
                path("Log", model.daemon.logURL.path)
            }
        }
    }

    private var maskedHash: String {
        guard let hash = model.config.apiHash, hash.count >= 8 else { return "Not set" }
        return hash.prefix(4) + "…" + hash.suffix(4)
    }

    private func control(_ title: String, detail: String?, button: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            TitleAndDetail(title: title, detail: detail)
            Spacer(minLength: 8)
            Button(button, action: action)
                .disabled(!enabled)
        }
    }

    private func path(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(TypeScale.body)
                .foregroundStyle(.secondary)
            Text(value)
                .font(TypeScale.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}

#Preview("Gateway") {
    let model = AppModel.preview(.loggedIn)
    model.section = .gateway
    return MainWindowView().environment(model).frame(width: 820, height: 560)
}
