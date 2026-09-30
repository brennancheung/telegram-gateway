import SwiftUI

/// The panel under the menu bar icon: a header with the gateway's state and the menu, then
/// whichever screen the model's facts call for.
struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HeaderBar()
            Divider()
            Group {
                switch model.screen {
                case .loading:
                    ProgressView("Contacting the gateway…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .setup:
                    SetupView()
                case .tokenMissing:
                    TokenMissingView()
                case .login:
                    LoginView()
                case .main:
                    if let request = model.approving {
                        ApproveView(request: request)
                    } else {
                        MainTabs(tab: $model.tab)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: PanelSize.width, height: PanelSize.height)
        .onAppear { model.panelOpened() }
        .onDisappear { model.panelClosed() }
    }
}

/// Status | Chats | Access, with a badge on Access when a request is pending.
struct MainTabs: View {
    @Environment(AppModel.self) private var model
    @Binding var tab: AppModel.Tab

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $tab) {
                ForEach(AppModel.Tab.allCases) { tab in
                    Text(tab == .access && model.pendingRequestCount > 0 ? "\(tab.title) (\(model.pendingRequestCount))" : tab.title)
                        .tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            switch tab {
            case .status: StatusView()
            case .chats: ChatsView()
            case .access: AccessView()
            }
        }
    }
}

/// Title, one-line state, and the app menu.
struct HeaderBar: View {
    @Environment(AppModel.self) private var model
    @State private var confirmingLogout = false

    var body: some View {
        HStack(spacing: 10) {
            StatusDot(tone: tone)
            VStack(alignment: .leading, spacing: 1) {
                Text("Telegram Gateway")
                    .font(.headline)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Menu {
                Button("Refresh") { Task { await model.refresh() } }
                Divider()
                Button("Restart gateway") { model.restartGateway() }
                    .disabled(!model.reachable && !model.daemon.isForegroundRunning)
                Button("Gateway setup…") { model.showSetup = true }
                Button("Open Login Items settings") { model.daemon.openLoginItemsSettings() }
                Button("Show gateway log") { showLog() }
                if model.authState.isLoggedIn {
                    Divider()
                    Button("Log out of Telegram…") { confirmingLogout = true }
                }
                Divider()
                Button("Quit app") { NSApplication.shared.terminate(nil) }
                Text("The gateway keeps running after the app quits.")
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("App menu")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .confirmationDialog("Log out of Telegram on this gateway?", isPresented: $confirmingLogout) {
            Button("Log out", role: .destructive) { Task { await model.logout() } }
        } message: {
            Text("The event log, grants and monitored chats are kept, but nothing new arrives until you log in again.")
        }
    }

    private var tone: StatusDot.Tone {
        guard model.reachable, let health = model.health else { return .failed }
        if health.tdlib.authState.isLoggedIn && health.tdlib.connectionState == .ready { return .ok }
        return .waiting
    }

    private var summary: String {
        guard model.reachable, let health = model.health else {
            return model.initialised ? "Gateway not running" : "Contacting the gateway…"
        }
        var parts = [health.tdlib.authState.label]
        if health.tdlib.authState.isLoggedIn {
            parts.append(health.tdlib.connectionState.label)
            if let account = model.status?.account {
                parts.append(account.username.map { "@\($0)" } ?? account.displayName)
            }
        }
        return parts.joined(separator: " · ")
    }

    private func showLog() {
        let url = model.daemon.isForegroundRunning ? DaemonManager.foregroundLogURL : DaemonManager.agentLogURL
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([GatewayConfig.logDirectory])
        }
    }
}

#Preview("Main, logged in") {
    RootView().environment(AppModel.preview(.loggedIn))
}

#Preview("Gateway not running") {
    RootView().environment(AppModel.preview(.unreachable))
}

#Preview("Login (QR)") {
    RootView().environment(AppModel.preview(.waitingForQR))
}
