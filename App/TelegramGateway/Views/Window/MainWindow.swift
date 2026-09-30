import AppKit
import SwiftUI

/// The main window. Setup and sign-in are a focused, centred flow with no sidebar; once
/// signed in (or when a set-up gateway is down) it is a split view: Overview, Chats, Apps,
/// Gateway.
struct MainWindowView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.showsSidebar {
                SplitRoot()
            } else {
                SetupFlowView()
            }
        }
        .frame(minWidth: PanelSize.windowMinimum.width, minHeight: PanelSize.windowMinimum.height)
        .background(WindowAccessor())
        .sheet(isPresented: Binding(get: { model.approval != nil && model.showsSidebar }, set: { if !$0 { model.cancelApproval() } })) {
            ApproveSheet()
                .environment(model)
        }
        .onAppear { model.windowOpened() }
        .onDisappear { model.windowClosed() }
    }
}

/// Sidebar and the selected section.
struct SplitRoot: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationSplitView {
            List(selection: Binding<AppModel.Section?>(get: { model.section }, set: { if let section = $0 { model.section = section } })) {
                ForEach(AppModel.Section.allCases) { section in
                    Label(section.title, systemImage: section.symbol)
                        .badge(section == .apps ? model.pendingRequestCount : 0)
                        .tag(section)
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
            .safeAreaInset(edge: .bottom) { SidebarStatus() }
        } detail: {
            Group {
                switch model.section {
                case .overview: OverviewSection()
                case .chats: ChatsSection()
                case .apps: AppsSection()
                case .gateway: GatewaySection()
                }
            }
            .navigationTitle(model.section.title)
        }
    }
}

/// One dot and one phrase at the foot of the sidebar.
struct SidebarStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let headline = model.headline
        HStack(spacing: 6) {
            StatusDot(tone: headline.tone)
            Text(headline.phrase)
                .font(TypeScale.secondary)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

/// Shown in Chats and Apps while the gateway cannot serve them.
struct GatewayUnavailable: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ContentUnavailableView {
            Label(model.screen == .keyMissing ? "Can't control the gateway" : "Gateway not running", systemImage: "bolt.slash")
        } description: {
            Text("Overview has the way to fix it.")
        } actions: {
            Button("Go to Overview") { model.section = .overview }
        }
    }
}

// MARK: Window behaviour

/// An `LSUIElement` app has no Dock icon and no menu bar of its own. While the main window is
/// open the app becomes a regular app (Dock icon, Cmd-Tab, Edit and Window menus, so Cmd-V,
/// Cmd-W and Return work); when the window closes it goes back to living only in the menu bar.
/// Closing the window never quits the app.
@MainActor
final class WindowCoordinator {
    static let shared = WindowCoordinator()
    private weak var window: NSWindow?
    private var closeObserver: NSObjectProtocol?

    /// Called when the window's content is first placed in its `NSWindow`.
    func attach(_ window: NSWindow) {
        guard self.window !== window else { return }
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        self.window = window
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { WindowCoordinator.shared.windowClosed() }
        }
        focus()
    }

    /// Brings the window to the front, for a first open and for every re-open.
    func focus() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func windowClosed() {
        NSApp.setActivationPolicy(.accessory)
    }
}

/// Hands the hosting `NSWindow` to the coordinator.
struct WindowAccessor: NSViewRepresentable {
    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, !SnapshotFlags.isSnapshotRun else { return }
            MainActor.assumeIsolated { WindowCoordinator.shared.attach(window) }
        }
    }

    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ nsView: Probe, context: Context) {}
}

/// Whether this process was started to render snapshots (it then never changes its
/// activation policy or takes focus on its own).
enum SnapshotFlags {
    static let isSnapshotRun = CommandLine.arguments.contains("--snapshot")
}

#Preview("Window") {
    MainWindowView()
        .environment(AppModel.preview(.loggedIn))
        .frame(width: 820, height: 560)
}
