#if DEBUG
import AppKit
import SwiftUI

/// Development only: `TelegramGateway --snapshot <directory>` renders every screen with the
/// fake gateway into PNG files and quits; add `--live` to drive the real HTTP client against
/// whatever answers on the configured port (the daemon, or a stand-in) through a scripted
/// login → chats → access flow. Used to check the UI where nobody can click the menu bar.
@MainActor
enum SnapshotRunner {
    static var requestedDirectory: URL? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count else { return nil }
        return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
    }

    static var isLive: Bool { CommandLine.arguments.contains("--live") }

    static func run(into directory: URL, live: Bool) async {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
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

    // MARK: Fake gateway: one image per screen

    private static func runFake(into directory: URL) async throws {
        let cases: [(String, () -> AppModel)] = [
            ("01-setup-first-run", { AppModel.preview(.unreachable, credentials: false, token: false) }),
            ("02-setup-gateway-down", { AppModel.preview(.unreachable) }),
            ("03-token-missing", { AppModel.preview(.loggedIn, token: false) }),
            ("04-login-qr", { AppModel.preview(.waitingForQR) }),
            ("05-login-code", { AppModel.preview(.waitingForCode) }),
            ("06-login-password", { AppModel.preview(.waitingForPassword) }),
            ("07-status", { AppModel.preview(.loggedIn) }),
            ("08-chats", { let m = AppModel.preview(.loggedIn); m.tab = .chats; return m }),
            ("09-chats-empty", { let m = AppModel.preview(.loggedInEmpty); m.tab = .chats; return m }),
            ("10-access", { let m = AppModel.preview(.loggedIn); m.tab = .access; return m }),
            ("11-approve", { let m = AppModel.preview(.loggedIn); m.tab = .access; m.approving = Fixtures.requests[0]; return m }),
        ]
        // `--only <prefix>` renders a subset, e.g. `--only 11`.
        let only: String? = {
            let arguments = CommandLine.arguments
            guard let index = arguments.firstIndex(of: "--only"), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }()
        for (name, make) in cases where only == nil || name.hasPrefix(only!) {
            let model = make()
            await model.refresh()
            try await capture(model, to: directory.appending(path: "\(name).png"))
            for appearance in [NSAppearance.Name.darkAqua] {
                try await capture(model, to: directory.appending(path: "\(name)-dark.png"), appearance: appearance)
            }
        }
    }

    // MARK: Live: scripted flow through HTTPAPIClient

    private static func runLive(into directory: URL) async throws {
        let model = AppModel.live()
        var step = 0
        func shot(_ name: String) async throws {
            step += 1
            try await capture(model, to: directory.appending(path: String(format: "live-%02d-%@.png", step, name)))
        }
        await model.refresh()
        print("live: screen \(model.screen), reachable \(model.reachable), auth \(model.authState.rawValue), token \(model.token != nil)")
        try await shot("initial")
        guard model.screen == .login || model.screen == .main else {
            print("live: not at login/main, stopping (lastError: \(model.lastError ?? "-"), tokenError: \(model.tokenError ?? "-"))")
            return
        }
        if model.screen == .login {
            await model.requestQR()
            await model.refreshAuth()
            print("live: qr link \(model.auth?.qrLink ?? "none")")
            try await shot("qr")
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
        try await shot("status")
        model.tab = .chats
        await model.loadChats()
        print("live: \(model.chats.count) chats, \(model.folders.count) folders, monitored \(model.monitoredCount)")
        try await shot("chats")
        let saved = await model.saveMonitored(chatIds: ["-1001234567890", "-1001987654321"], folderIds: ["3"])
        print("live: save monitored → \(saved) effective \(model.monitored?.effectiveChatIds ?? []) error \(model.chatsError ?? "-")")
        model.tab = .access
        await model.loadAccess()
        print("live: \(model.requests.count) requests, \(model.grants.count) grants")
        try await shot("access")
        if let request = model.requests.first {
            model.approving = request
            try await shot("approve")
            let ok = await model.approve(request, selection: .chats(["-1001234567890"]), scopes: ["messages:read", "chats:read"], alsoMonitor: [])
            print("live: approve → \(ok) error \(model.accessError ?? "-") grants \(model.grants.count)")
            try await shot("after-approve")
            if let grant = model.grants.first {
                await model.revoke(grant)
                print("live: revoke → grants \(model.grants.count) error \(model.accessError ?? "-")")
            }
        }
        await model.logout()
        print("live: logout → \(model.authState.rawValue) screen \(model.screen)")
        try await shot("after-logout")
    }

    // MARK: Rendering

    private static func capture(_ model: AppModel, to url: URL, appearance: NSAppearance.Name = .aqua) async throws {
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: PanelSize.width, height: PanelSize.height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.isReleasedWhenClosed = false
        // The MenuBarExtra panel supplies its own background; a bare hosting view is transparent.
        let host = NSHostingView(rootView: RootView().environment(model).background(Color(nsColor: .windowBackgroundColor)))
        host.frame = NSRect(origin: .zero, size: NSSize(width: PanelSize.width, height: PanelSize.height))
        window.contentView = host
        window.orderFrontRegardless()
        // Let .task and .onAppear loaders run and the layout settle.
        try await Task.sleep(for: .milliseconds(900))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw SnapshotError.noBitmap }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw SnapshotError.noPNG }
        try png.write(to: url)
        window.orderOut(nil)
        window.contentView = nil
        model.panelClosed()
    }

    enum SnapshotError: Error { case noBitmap, noPNG }
}
#endif
