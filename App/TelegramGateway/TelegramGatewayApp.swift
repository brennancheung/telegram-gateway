import AppKit
import SwiftUI

/// Two surfaces. The menu bar popover (`MenuBarExtra`, `.window` style) is for a glance and
/// three actions. The main window (`Window` scene) is for everything with detail: setup,
/// sign-in, Overview, Chats, Apps, Gateway. `LSUIElement` in Info.plist keeps the app out of
/// the Dock until the window is open (see `WindowCoordinator`).
@main
struct TelegramGatewayApp: App {
    static let mainWindowID = "main"

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel

    init() {
        // Under `xcodebuild test` the app is only a host for the test bundle, and in a
        // snapshot run it only renders fixtures: no secrets file, no polling, no launchd.
        let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
        let inert = isTestHost || SnapshotFlags.isSnapshotRun
        let model = inert ? AppModel.preview(.unreachable, credentials: false, token: false) : AppModel.live()
        _model = State(initialValue: model)
        if !inert { model.start() }
        AppDelegate.model = model
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environment(model)
        } label: {
            MenuBarLabel()
                .environment(model)
        }
        .menuBarExtraStyle(.window)

        Window("Telegram Gateway", id: Self.mainWindowID) {
            MainWindowView()
                .environment(model)
        }
        .defaultSize(width: PanelSize.window.width, height: PanelSize.window.height)
        .windowResizability(.contentMinSize)
        // The window opens when the user asks for it, or when setup or sign-in is needed;
        // never just because the app launched.
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .commands { AppCommands(model: model) }
    }
}

/// The menu bar icon. It is always alive, so it is also where requests to show the main
/// window are carried out: `AppModel.requestWindow()` bumps a counter, this opens (or
/// re-focuses) the one window.
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(nsImage: MenuBarIcon.image(pending: model.pendingRequestCount))
            .onChange(of: model.windowRequests) { showWindow() }
            .task { if model.windowRequests > 0 { showWindow() } }
    }

    private func showWindow() {
        guard !SnapshotFlags.isSnapshotRun else { return }
        openWindow(id: TelegramGatewayApp.mainWindowID)
        WindowCoordinator.shared.focus()
    }
}

/// Cmd-, re-focuses the main window (there is no separate settings window), and there is no
/// "New Window": the app has exactly one.
struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Open Telegram Gateway…") { model.requestWindow() }
                .keyboardShortcut(",", modifiers: .command)
        }
        CommandGroup(replacing: .newItem) {}
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        MainActor.assumeIsolated {
            if let directory = SnapshotRunner.requestedDirectory {
                let live = SnapshotRunner.isLive
                Task { await SnapshotRunner.run(into: directory, live: live) }
            }
        }
        #endif
    }

    /// Closing the window never quits the app: it goes back to the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // A gateway run inside the app is a child of this process and must not outlive it;
        // a gateway registered to start at login is untouched.
        MainActor.assumeIsolated {
            Self.model?.daemon.stopForeground()
        }
    }
}

/// The menu bar icon: a template image so it follows the menu bar's light/dark appearance,
/// with a dot cut out at the top right when an access request is waiting.
enum MenuBarIcon {
    @MainActor
    static func image(pending: Int) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let symbol = NSImage(systemSymbolName: "paperplane.fill", accessibilityDescription: "Telegram Gateway")!
            .withSymbolConfiguration(configuration)!
        guard pending > 0 else {
            symbol.isTemplate = true
            return symbol
        }
        let size = NSSize(width: symbol.size.width + 3, height: symbol.size.height + 2)
        let image = NSImage(size: size, flipped: false) { rect in
            symbol.draw(at: NSPoint(x: 0, y: 0), from: .zero, operation: .sourceOver, fraction: 1)
            let dot = NSRect(x: rect.maxX - 6.5, y: rect.maxY - 6.5, width: 6, height: 6)
            guard let context = NSGraphicsContext.current?.cgContext else { return true }
            context.setBlendMode(.clear)
            NSBezierPath(ovalIn: dot.insetBy(dx: -1.5, dy: -1.5)).fill()
            context.setBlendMode(.normal)
            NSColor.black.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Telegram Gateway, \(pending) access request\(pending == 1 ? "" : "s") pending"
        return image
    }
}
