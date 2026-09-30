#if DEBUG
import AppKit
import SwiftUI

/// Development only: `TelegramGateway --snapshot <directory>` renders every state of both
/// surfaces — the menu bar popover (`p…` files) and the main window (`w…` files) — with the
/// fake gateway into PNG files, light and dark, and quits. Used to check the UI where nobody
/// can click.
///
/// - `--only <prefix>` renders a subset (`--only w1`, `--only p`).
/// - `--key` makes each snapshot window the key window of an active app, so native controls
///   (prominent buttons, checkboxes, selection) are drawn in the accent colour as the owner
///   sees them. It takes keyboard focus for the duration of the run; without it those
///   controls are drawn grey, the way AppKit draws any inactive window.
/// - `--shoot` leaves the main-window states to be photographed from outside: for each one
///   the app writes `<directory>/.shoot` ("<window number> <file name>") and waits until the
///   file is removed. `App/snapshot.sh` does the photographing with `screencapture -l`. This
///   is how the window is captured, because an in-process render cannot see the sidebar
///   (macOS draws it in a separate layer).
/// - `--live` drives the real HTTP client against whatever answers on the configured port
///   through a scripted sign-in → chats → apps flow instead of rendering fixtures.
///
/// Snapshot runs never read the Keychain, never register anything with launchd, never write
/// `config.json` and never persist to the app's defaults.
@MainActor
enum SnapshotRunner {
    enum Surface { case popover, window, sheet }

    struct Case {
        var name: String
        var surface: Surface
        var make: @MainActor () async -> AppModel
    }

    static var requestedDirectory: URL? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count else { return nil }
        return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
    }

    static var isLive: Bool { CommandLine.arguments.contains("--live") }
    static var usesKeyWindow: Bool { CommandLine.arguments.contains("--key") }
    static var shootsExternally: Bool { CommandLine.arguments.contains("--shoot") }

    static func run(into directory: URL, live: Bool) async {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if usesKeyWindow {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
            }
            if live {
                try await runLive(into: directory)
            } else {
                try await runFake(into: directory)
            }
            print("snapshots written to \(directory.path)")
            exit(0)
        } catch {
            print("snapshot failed: \(error)")
            exit(1)
        }
    }

    // MARK: Cases

    private static func signedIn(_ scenario: FakeAPIClient.Scenario = .loggedIn, section: AppModel.Section, onboarded: Bool = true) async -> AppModel {
        let model = AppModel.preview(scenario, onboarded: onboarded)
        model.section = section
        await model.refresh()
        await model.loadChats()
        await model.loadAccess()
        return model
    }

    /// Every state of both surfaces, in the order the owner meets them.
    static let cases: [Case] = [
        // The menu bar popover.
        Case(name: "p01-popover-healthy", surface: .popover) { AppModel.preview(.loggedInQuiet) },
        Case(name: "p02-popover-needs-you", surface: .popover) { AppModel.preview(.loggedIn) },
        Case(name: "p03-popover-reconnecting", surface: .popover) { AppModel.preview(.reconnecting) },
        Case(name: "p04-popover-no-chats", surface: .popover) { AppModel.preview(.loggedInEmpty) },
        Case(name: "p05-popover-not-set-up", surface: .popover) { AppModel.preview(.unreachable, credentials: false, token: false, onboarded: false) },
        Case(name: "p06-popover-not-signed-in", surface: .popover) { AppModel.preview(.waitingForQR) },
        Case(name: "p07-popover-gateway-down", surface: .popover) { AppModel.preview(.unreachable) },
        Case(name: "p08-popover-key-missing", surface: .popover) { AppModel.preview(.loggedIn, token: false) },

        // The main window: setup and sign-in.
        Case(name: "w01-setup-connect", surface: .window) { AppModel.preview(.unreachable, credentials: false, token: false, onboarded: false) },
        Case(name: "w02-setup-connect-didnt-start", surface: .window) {
            let model = AppModel.preview(.unreachable, onboarded: false)
            model.startPhase = .failed("Address already in use: another program is using port 41414.")
            return model
        },
        Case(name: "w03-signin-qr", surface: .window) { AppModel.preview(.waitingForQR, onboarded: false) },
        Case(name: "w04-signin-qr-failed", surface: .window) {
            let model = AppModel.preview(.loggedOut, onboarded: false)
            model.loginError = "Telegram didn't answer. Check the internet connection."
            return model
        },
        Case(name: "w05-signin-phone", surface: .window) {
            let model = AppModel.preview(.waitingForQR, onboarded: false)
            model.loginMode = .phone
            return model
        },
        Case(name: "w06-signin-code", surface: .window) { AppModel.preview(.waitingForCode, onboarded: false) },
        Case(name: "w07-signin-password", surface: .window) { AppModel.preview(.waitingForPassword, onboarded: false) },
        Case(name: "w08-signin-password-wrong", surface: .window) {
            let model = AppModel.preview(.waitingForPassword, onboarded: false)
            await model.refresh()
            await model.refreshAuth()
            await model.submitPassword("wrong")
            return model
        },
        Case(name: "w09-chats-first-run", surface: .window) { await signedIn(.loggedInEmpty, section: .chats, onboarded: false) },

        // Overview.
        Case(name: "w10-overview", surface: .window) { await signedIn(section: .overview) },
        Case(name: "w11-overview-quiet", surface: .window) { await signedIn(.loggedInQuiet, section: .overview) },
        Case(name: "w12-overview-reconnecting", surface: .window) { await signedIn(.reconnecting, section: .overview) },
        Case(name: "w13-overview-no-chats", surface: .window) { await signedIn(.loggedInEmpty, section: .overview) },
        Case(name: "w14-overview-gateway-down", surface: .window) { AppModel.preview(.unreachable) },
        Case(name: "w15-overview-gateway-didnt-start", surface: .window) {
            let model = AppModel.preview(.unreachable)
            model.startPhase = .failed("The gateway program is missing. Build it with swift build in the repository.")
            return model
        },
        Case(name: "w16-overview-key-missing", surface: .window) { AppModel.preview(.loggedIn, token: false) },

        // Chats.
        Case(name: "w17-chats", surface: .window) { await signedIn(section: .chats) },
        Case(name: "w18-chats-monitored", surface: .window) {
            let model = await signedIn(section: .chats)
            model.chatScope = .monitored
            return model
        },
        Case(name: "w19-chats-folders", surface: .window) {
            let model = await signedIn(section: .chats)
            model.chatScope = .folders
            return model
        },
        Case(name: "w20-chats-unsaved", surface: .window) {
            let model = await signedIn(section: .chats)
            model.setChat("-1002222222222", monitored: true)
            model.setFolder("5", monitored: true)
            return model
        },
        Case(name: "w21-chats-search", surface: .window) {
            let model = await signedIn(section: .chats)
            model.chatSearch = "acme"
            return model
        },
        Case(name: "w22-chats-gateway-down", surface: .window) {
            let model = AppModel.preview(.unreachable)
            model.section = .chats
            return model
        },

        // Apps.
        Case(name: "w23-apps-request", surface: .window) {
            let model = await signedIn(section: .apps)
            model.normalizeAppSelection()
            return model
        },
        Case(name: "w24-apps-app", surface: .window) {
            let model = await signedIn(section: .apps)
            model.selectedApp = .grant(Fixtures.grants[0].id)
            return model
        },
        Case(name: "w25-apps-app-paused", surface: .window) {
            let model = await signedIn(section: .apps)
            model.selectedApp = .grant(Fixtures.grants[1].id)
            return model
        },
        Case(name: "w26-apps-empty", surface: .window) { await signedIn(.loggedInEmpty, section: .apps) },
        Case(name: "w27-review-sheet", surface: .sheet) {
            let model = await signedIn(section: .apps)
            model.beginApproval(model.requests[0])
            return model
        },
        Case(name: "w28-review-sheet-folder", surface: .sheet) {
            let model = await signedIn(section: .apps)
            model.beginApproval(model.requests[0])
            model.approval?.followFolder = true
            model.approval?.folderId = "3"
            return model
        },

        // Gateway.
        Case(name: "w29-gateway", surface: .window) { await signedIn(section: .gateway) },
        Case(name: "w30-gateway-down", surface: .window) {
            let model = AppModel.preview(.unreachable)
            model.section = .gateway
            return model
        },
    ]

    private static func runFake(into directory: URL) async throws {
        let only: String? = {
            let arguments = CommandLine.arguments
            guard let index = arguments.firstIndex(of: "--only"), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }()
        for item in cases where only == nil || item.name.hasPrefix(only!) {
            for (suffix, appearance) in [("", NSAppearance.Name.aqua), ("-dark", NSAppearance.Name.darkAqua)] {
                let model = await item.make()
                await model.refresh()
                // The review sheet is captured on its own; the window behind it is not needed.
                let sheetDraft = model.approval
                if item.surface == .window { model.approval = nil }
                defer { model.approval = sheetDraft }
                try await capture(item.surface, model, to: directory.appending(path: "\(item.name)\(suffix).png"), appearance: appearance)
            }
        }
    }

    // MARK: Live: scripted flow through HTTPAPIClient

    private static func runLive(into directory: URL) async throws {
        let model = AppModel.live(persistOnboarding: false)
        var step = 0
        func shot(_ name: String, _ surface: Surface = .window) async throws {
            step += 1
            try await capture(surface, model, to: directory.appending(path: String(format: "live-%02d-%@.png", step, name)))
        }
        await model.refresh()
        print("live: screen \(model.screen), reachable \(model.reachable), auth \(model.authState.rawValue), token \(model.token != nil), hero \(model.hero.title), window requests \(model.windowRequests)")
        try await shot("popover", .popover)
        try await shot("initial")
        guard model.screen == .login || model.screen == .main else {
            print("live: not at sign-in or main, stopping (lastError: \(model.lastError ?? "-"), tokenError: \(model.tokenError ?? "-"))")
            return
        }
        if model.screen == .login {
            await model.requestQR()
            await model.refreshAuth()
            print("live: qr link \(model.auth?.qrLink ?? "none") error \(model.loginError ?? "-")")
            try await shot("qr")
            model.loginMode = .phone
            await model.submitPhone("+15551234567")
            print("live: after phone → \(model.authState.rawValue) hint \(model.auth?.phoneHint ?? "-") error \(model.loginError ?? "-")")
            try await shot("code")
            await model.submitCode("00000")
            print("live: wrong code → error \(model.loginError ?? "-")")
            await model.submitCode("12345")
            print("live: after code → \(model.authState.rawValue)")
            await model.submitPassword("wrong")
            print("live: wrong password → error \(model.loginError ?? "-") hint \(model.auth?.passwordHint ?? "-")")
            try await shot("password")
            await model.submitPassword("hunter2")
            await model.refresh()
            print("live: after password → \(model.authState.rawValue), screen \(model.screen)")
        }
        guard model.screen == .main else {
            print("live: not signed in, stopping at \(model.screen)")
            return
        }
        model.section = .overview
        try await shot("overview")
        model.section = .chats
        await model.loadChats()
        print("live: \(model.chats.count) chats, \(model.folders.count) folders, monitored \(model.monitoredCount)")
        try await shot("chats")
        if let first = model.chats.first {
            model.setChat(first.id, monitored: true)
            let saved = await model.saveDraft()
            print("live: save monitored → \(saved) effective \(model.monitored?.effectiveChatIds ?? []) error \(model.chatsError ?? "-")")
        }
        model.section = .apps
        await model.loadAccess()
        model.normalizeAppSelection()
        print("live: \(model.requests.count) requests, \(model.grants.count) grants")
        try await shot("apps")
        if let request = model.requests.first {
            model.beginApproval(request)
            try await shot("review", .sheet)
            let ok = await model.approve()
            print("live: approve → \(ok) error \(model.accessError ?? "-") grants \(model.grants.count)")
            try await shot("after-approve")
            if let grant = model.grants.first {
                await model.revoke(grant)
                print("live: revoke → grants \(model.grants.count) error \(model.accessError ?? "-")")
            }
        }
        model.section = .gateway
        try await shot("gateway")
        await model.logout()
        print("live: sign out → \(model.authState.rawValue) screen \(model.screen)")
        try await shot("after-sign-out")
    }

    // MARK: Rendering

    private static func capture(_ surface: Surface, _ model: AppModel, to url: URL, appearance name: NSAppearance.Name = .aqua) async throws {
        let appearance = NSAppearance(named: name)!
        let window: NSWindow
        let target: NSView
        switch surface {
        case .popover, .sheet:
            // The popover panel and a sheet supply their own background; a bare hosting view
            // is transparent.
            let root: AnyView = surface == .popover
                ? AnyView(PopoverView().environment(model).background(Color(nsColor: .windowBackgroundColor)))
                : AnyView(ApproveSheet().environment(model).background(Color(nsColor: .windowBackgroundColor)))
            let host = NSHostingView(rootView: root)
            let size = surface == .popover ? host.fittingSize : NSSize(width: PanelSize.sheet.width, height: PanelSize.sheet.height)
            host.frame = NSRect(origin: .zero, size: size)
            window = KeyableWindow(contentRect: NSRect(origin: NSPoint(x: 40, y: 40), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            target = host
        case .window:
            let controller = NSHostingController(rootView: MainWindowView().environment(model))
            // Toolbar items, the search field and the title go to the real NSWindow.
            controller.sceneBridgingOptions = [.toolbars, .title]
            window = KeyableWindow(
                contentRect: NSRect(origin: NSPoint(x: 40, y: 40), size: NSSize(width: PanelSize.window.width, height: PanelSize.window.height)),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.contentViewController = controller
            window.setContentSize(NSSize(width: PanelSize.window.width, height: PanelSize.window.height))
            // The frame view includes the title bar and toolbar.
            target = window.contentView?.superview ?? controller.view
        }
        window.appearance = appearance
        window.isReleasedWhenClosed = false
        if usesKeyWindow {
            // Activation only takes once the app has a window to bring forward.
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            window.orderFrontRegardless()
        }
        // Let .task and .onAppear loaders run and the layout settle.
        try await Task.sleep(for: .milliseconds(1100))
        target.layoutSubtreeIfNeeded()
        if surface == .window, shootsExternally {
            let marker = url.deletingLastPathComponent().appending(path: ".shoot")
            try "\(window.windowNumber) \(url.lastPathComponent)\n".write(to: marker, atomically: true, encoding: .utf8)
            let deadline = ContinuousClock.now + .seconds(20)
            while FileManager.default.fileExists(atPath: marker.path) {
                if ContinuousClock.now > deadline { throw SnapshotError.nobodyShot }
                try await Task.sleep(for: .milliseconds(40))
            }
            window.orderOut(nil)
            window.contentViewController = nil
            model.panelClosed()
            model.windowClosed()
            return
        }
        guard let rep = target.bitmapImageRepForCachingDisplay(in: target.bounds) else { throw SnapshotError.noBitmap }
        target.cacheDisplay(in: target.bounds, to: rep)

        // Sidebar and title bar materials are translucent: put the window colour behind them.
        let image = NSImage(size: target.bounds.size)
        image.lockFocus()
        appearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            NSRect(origin: .zero, size: target.bounds.size).fill()
        }
        rep.draw(in: NSRect(origin: .zero, size: target.bounds.size))
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let flattened = NSBitmapImageRep(data: tiff),
              let png = flattened.representation(using: .png, properties: [:])
        else { throw SnapshotError.noPNG }
        try png.write(to: url)
        window.orderOut(nil)
        window.contentViewController = nil
        window.contentView = nil
        model.panelClosed()
        model.windowClosed()
    }

    enum SnapshotError: Error { case noBitmap, noPNG, nobodyShot }
}

/// A snapshot window that may become key when `--key` asks for it.
private final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
#endif
