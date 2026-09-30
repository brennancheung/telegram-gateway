import SwiftUI

/// The panel under the menu bar icon: a header with one state phrase and the menu, then
/// whichever screen the model's facts call for.
struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar()
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: PanelSize.width, height: PanelSize.height)
        .onAppear { model.panelOpened() }
        .onDisappear { model.panelClosed() }
    }

    @ViewBuilder
    private var content: some View {
        if model.overlay == .details {
            GatewayDetailsView()
        } else {
            switch model.screen {
            case .loading:
                ProgressView().controlSize(.small)
            case .connect:
                ConnectView()
            case .gatewayDown:
                GatewayDownView()
            case .keyMissing:
                KeyMissingView()
            case .login:
                LoginView()
            case .main:
                switch model.overlay {
                case .approve where model.approval != nil:
                    ApproveView()
                case .grant(let id):
                    GrantDetailView(grantId: id)
                default:
                    MainTabs()
                }
            }
        }
    }
}

/// Overview · Chats · Apps.
struct MainTabs: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            TabBar()
                .padding(.horizontal, PanelSize.margin)
                .padding(.vertical, 8)
            switch model.tab {
            case .overview: OverviewView()
            case .chats: ChatsView()
            case .apps: AppsView()
            }
        }
    }
}

/// The three tabs, with an amber count on Apps while requests are waiting.
struct TabBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AppModel.Tab.allCases) { tab in
                let selected = model.tab == tab
                Button {
                    model.tab = tab
                } label: {
                    HStack(spacing: 5) {
                        Text(tab.title)
                            .font(selected ? TypeScale.rowTitle : TypeScale.body)
                            .foregroundStyle(selected ? .primary : .secondary)
                        if tab == .apps, model.pendingRequestCount > 0 {
                            Text("\(model.pendingRequestCount)")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Tone.attention.color, in: Capsule())
                                .accessibilityLabel("\(model.pendingRequestCount) waiting")
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background(selected ? AnyShapeStyle(Color.primary.opacity(0.1)) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// One dot, one phrase, and the menu.
struct HeaderBar: View {
    @Environment(AppModel.self) private var model
    @State private var confirmingLogout = false

    var body: some View {
        let headline = model.headline
        HStack(spacing: 8) {
            StatusDot(tone: headline.tone, size: 8)
            Text(headline.phrase)
                .font(TypeScale.rowTitle)
                .lineLimit(1)
            Spacer()
            Menu {
                Button("Refresh") { Task { await model.refresh() } }
                Button("Restart gateway") { model.restartGateway() }
                    .disabled(!model.reachable)
                Button("Gateway details…") { model.overlay = .details }
                if model.screen == .main {
                    Divider()
                    Button("Sign out of Telegram…") { confirmingLogout = true }
                }
                Divider()
                Button("Quit app") { NSApplication.shared.terminate(nil) }
                Text("The gateway keeps running after the app quits.")
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 14))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Menu")
        }
        .padding(.horizontal, PanelSize.margin)
        .padding(.vertical, 10)
        .confirmationDialog("Sign out of Telegram?", isPresented: $confirmingLogout) {
            Button("Sign out", role: .destructive) { Task { await model.logout() } }
        } message: {
            Text("Nothing new is collected until you sign in again. Chats, apps and collected messages are kept.")
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

#Preview("Overview") {
    RootView().environment(AppModel.preview(.loggedIn))
}

#Preview("Gateway not running") {
    RootView().environment(AppModel.preview(.unreachable))
}

#Preview("Sign in") {
    RootView().environment(AppModel.preview(.waitingForQR, onboarded: false))
}
