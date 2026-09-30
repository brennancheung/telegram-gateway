#if DEBUG
import AppKit
import SwiftUI

/// Development only: `TelegramGateway --snapshot <directory>` renders every screen and state
/// with the fake gateway into PNG files (light and dark) and quits; add `--live` to drive the
/// real HTTP client against whatever answers on the configured port through a scripted
/// sign-in → chats → apps flow. Used to check the UI where nobody can click the menu bar.
/// Snapshot runs never read the Keychain and never persist anything to the app's defaults.
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

    // MARK: Fake gateway: one image per screen and state

    /// Every screen and state, in the order the owner meets them.
    static let cases: [(String, @MainActor () async -> AppModel)] = [
        ("01-connect", {
            AppModel.preview(.unreachable, credentials: false, token: false, onboarded: false)
        }),
        ("02-connect-didnt-start", {
            let model = AppModel.preview(.unreachable, onboarded: false)
            model.startPhase = .failed("Address already in use: another program is using port 41414.")
            return model
        }),
        ("03-signin-qr", {
            AppModel.preview(.waitingForQR, onboarded: false)
        }),
        ("04-signin-qr-failed", {
            let model = AppModel.preview(.loggedOut, onboarded: false)
            model.loginError = "Telegram didn't answer. Check the internet connection."
            return model
        }),
        ("05-signin-phone", {
            let model = AppModel.preview(.waitingForQR, onboarded: false)
            model.loginMode = .phone
            return model
        }),
        ("06-signin-code", {
            AppModel.preview(.waitingForCode, onboarded: false)
        }),
        ("07-signin-password", {
            AppModel.preview(.waitingForPassword, onboarded: false)
        }),
        ("08-signin-password-wrong", {
            let model = AppModel.preview(.waitingForPassword, onboarded: false)
            await model.refresh()
            await model.refreshAuth()
            await model.submitPassword("wrong")
            return model
        }),
        ("09-chats-first-run", {
            let model = AppModel.preview(.loggedInEmpty, onboarded: false)
            model.tab = .chats
            return model
        }),
        ("10-overview", {
            AppModel.preview(.loggedIn)
        }),
        ("11-overview-quiet", {
            AppModel.preview(.loggedInQuiet)
        }),
        ("12-overview-reconnecting", {
            AppModel.preview(.reconnecting)
        }),
        ("13-overview-no-chats", {
            AppModel.preview(.loggedInEmpty)
        }),
        ("14-gateway-down", {
            AppModel.preview(.unreachable)
        }),
        ("15-gateway-down-didnt-start", {
            let model = AppModel.preview(.unreachable)
            model.startPhase = .failed("The gateway program is missing. Build it with swift build in the repository.")
            return model
        }),
        ("16-key-missing", {
            AppModel.preview(.loggedIn, token: false)
        }),
        ("17-chats", {
            let model = AppModel.preview(.loggedIn)
            model.tab = .chats
            return model
        }),
        ("18-chats-unsaved", {
            let model = AppModel.preview(.loggedIn)
            model.tab = .chats
            await model.refresh()
            await model.loadChats()
            model.setChat("-1002222222222", monitored: true)
            model.setFolder("5", monitored: true)
            return model
        }),
        ("19-apps", {
            let model = AppModel.preview(.loggedIn)
            model.tab = .apps
            return model
        }),
        ("20-apps-empty", {
            let model = AppModel.preview(.loggedInEmpty)
            model.tab = .apps
            return model
        }),
        ("21-approve", {
            let model = AppModel.preview(.loggedIn)
            model.tab = .apps
            await model.refresh()
            await model.loadChats()
            await model.loadAccess()
            model.beginApproval(model.requests[0])
            return model
        }),
        ("22-approve-folder", {
            let model = AppModel.preview(.loggedIn)
            model.tab = .apps
            await model.refresh()
            await model.loadChats()
            await model.loadAccess()
            model.beginApproval(model.requests[0])
            model.approval?.followFolder = true
            model.approval?.folderId = "3"
            return model
        }),
        ("23-app-detail", {
            let model = AppModel.preview(.loggedIn)
            model.tab = .apps
            await model.refresh()
            await model.loadChats()
            await model.loadAccess()
            model.overlay = .grant(Fixtures.grants[0].id)
            return model
        }),
        ("24-app-detail-paused", {
            let model = AppModel.preview(.loggedIn)
            model.tab = .apps
            await model.refresh()
            await model.loadChats()
            await model.loadAccess()
            model.overlay = .grant(Fixtures.grants[1].id)
            return model
        }),
        ("25-gateway-details", {
            let model = AppModel.preview(.loggedIn)
            model.overlay = .details
            return model
        }),
    ]

    private static func runFake(into directory: URL) async throws {
        // `--only <prefix>` renders a subset, e.g. `--only 21`.
        let only: String? = {
            let arguments = CommandLine.arguments
            guard let index = arguments.firstIndex(of: "--only"), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }()
        for (name, make) in cases where only == nil || name.hasPrefix(only!) {
            for (suffix, appearance) in [("", NSAppearance.Name.aqua), ("-dark", NSAppearance.Name.darkAqua)] {
                let model = await make()
                await model.refresh()
                try await capture(model, to: directory.appending(path: "\(name)\(suffix).png"), appearance: appearance)
            }
        }
    }

    // MARK: Live: scripted flow through HTTPAPIClient

    private static func runLive(into directory: URL) async throws {
        let model = AppModel.live(persistOnboarding: false)
        var step = 0
        func shot(_ name: String) async throws {
            step += 1
            try await capture(model, to: directory.appending(path: String(format: "live-%02d-%@.png", step, name)))
        }
        await model.refresh()
        print("live: screen \(model.screen), reachable \(model.reachable), auth \(model.authState.rawValue), token \(model.token != nil), headline \(model.headline.phrase)")
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
        model.tab = .overview
        try await shot("overview")
        model.tab = .chats
        await model.loadChats()
        print("live: \(model.chats.count) chats, \(model.folders.count) folders, monitored \(model.monitoredCount)")
        try await shot("chats")
        if let first = model.chats.first {
            model.setChat(first.id, monitored: true)
            let saved = await model.saveDraft()
            print("live: save monitored → \(saved) effective \(model.monitored?.effectiveChatIds ?? []) error \(model.chatsError ?? "-")")
        }
        model.tab = .apps
        await model.loadAccess()
        print("live: \(model.requests.count) requests, \(model.grants.count) grants")
        try await shot("apps")
        if let request = model.requests.first {
            model.beginApproval(request)
            try await shot("approve")
            let ok = await model.approve()
            print("live: approve → \(ok) error \(model.accessError ?? "-") grants \(model.grants.count)")
            try await shot("after-approve")
            if let grant = model.grants.first {
                model.overlay = .grant(grant.id)
                try await shot("app-detail")
                await model.revoke(grant)
                print("live: revoke → grants \(model.grants.count) error \(model.accessError ?? "-")")
            }
        }
        await model.logout()
        print("live: sign out → \(model.authState.rawValue) screen \(model.screen)")
        try await shot("after-sign-out")
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
