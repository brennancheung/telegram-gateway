import AppKit
import SwiftUI

/// The menu bar app. `LSUIElement` in Info.plist keeps it out of the Dock; `MenuBarExtra`
/// with the `.window` style gives a popover-like panel under the menu bar icon.
@main
struct TelegramGatewayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel

    init() {
        // Under `xcodebuild test` the app is only a host for the test bundle: no secrets file
        // reads, no polling, no launchd.
        let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
        var inert = isTestHost
        #if DEBUG
        if SnapshotRunner.requestedDirectory != nil { inert = true }
        #endif
        let model = inert ? AppModel.preview(.unreachable, credentials: false, token: false) : AppModel.live()
        _model = State(initialValue: model)
        if !inert { model.start() }
        AppDelegate.model = model
    }

    var body: some Scene {
        MenuBarExtra {
            RootView()
                .environment(model)
        } label: {
            Image(nsImage: MenuBarIcon.image(pending: model.pendingRequestCount))
        }
        .menuBarExtraStyle(.window)
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

    func applicationWillTerminate(_ notification: Notification) {
        // A daemon started with "Run in foreground" is a child of this process and must not
        // outlive it; the launchd agent is untouched.
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
