import Foundation
import Observation
import ServiceManagement

/// Finds the `GatewayDaemon` binary. In development it is `<repo>/.build/debug/GatewayDaemon`
/// (built by `swift build`); a shipped app would carry it inside its bundle. Candidates are
/// tried in order and the first existing executable wins.
enum DaemonLocator {
    struct Candidate: Identifiable, Hashable, Sendable {
        var source: String
        var url: URL
        var exists: Bool
        var id: String { url.path }
    }

    struct Resolution: Sendable {
        var candidates: [Candidate]
        var url: URL? { candidates.first(where: \.exists)?.url }
    }

    static func resolve(config: GatewayConfig, bundle: Bundle = .main, environment: [String: String] = ProcessInfo.processInfo.environment) -> Resolution {
        var candidates: [Candidate] = []
        func add(_ source: String, _ url: URL) {
            let url = url.standardizedFileURL
            guard !candidates.contains(where: { $0.url == url }) else { return }
            candidates.append(Candidate(source: source, url: url, exists: FileManager.default.isExecutableFile(atPath: url.path)))
        }

        if let path = environment["TGW_DAEMON_PATH"], !path.isEmpty {
            add("TGW_DAEMON_PATH", URL(fileURLWithPath: path))
        }
        if let path = config.daemonPath, !path.isEmpty {
            add("config.json daemon_path", URL(fileURLWithPath: path))
        }
        // Development: Info.plist carries $(SRCROOT)/.. from the build (App/Support/Info.plist).
        if let root = bundle.object(forInfoDictionaryKey: "TGWRepositoryRoot") as? String, !root.isEmpty, !root.contains("$(") {
            add("repository (from build)", URL(fileURLWithPath: root).appending(path: ".build/debug/GatewayDaemon"))
        }
        // Development: the app was built somewhere inside the repository (App/run.sh).
        var directory = bundle.bundleURL.deletingLastPathComponent()
        for _ in 0..<8 {
            if FileManager.default.fileExists(atPath: directory.appending(path: "Package.swift").path) {
                add("repository (from app location)", directory.appending(path: ".build/debug/GatewayDaemon"))
                break
            }
            let parent = directory.deletingLastPathComponent()
            if parent == directory { break }
            directory = parent
        }
        // Shipped build. TODO(bundling): add a build phase that copies the release daemon and
        // libtdjson.dylib into Contents/MacOS and update the launcher's fallback accordingly.
        add("app bundle", bundle.bundleURL.appending(path: "Contents/MacOS/GatewayDaemon"))
        return Resolution(candidates: candidates)
    }
}

/// Registers the daemon with launchd through `SMAppService` and, as a development fallback,
/// runs it as a child process of the app ("Run in foreground").
@MainActor
@Observable
final class DaemonManager {
    /// The LaunchAgent plist name inside the bundle (`Contents/Library/LaunchAgents/`). Its
    /// `Label` is the same string without `.plist`.
    static let agentLabel = "com.brennancheung.telegram-gateway.daemon"
    static let agentPlistName = agentLabel + ".plist"

    /// What launchd knows about the agent, in the app's own words.
    enum AgentState: Equatable, Sendable {
        case notRegistered
        case enabled
        case requiresApproval
        case notFound
        case unavailable(String)

        var label: String {
            switch self {
            case .notRegistered: "Not registered with launchd"
            case .enabled: "Registered with launchd (starts at login)"
            case .requiresApproval: "Waiting for approval in System Settings → Login Items"
            case .notFound: "Registered, but launchd cannot find the agent (rebuild the app)"
            case .unavailable(let reason): "launchd status unavailable: \(reason)"
            }
        }
    }

    enum ForegroundState: Equatable, Sendable {
        case stopped
        case running(pid: Int32)
        case exited(code: Int32)
    }

    private(set) var agentState: AgentState = .notRegistered
    private(set) var foreground: ForegroundState = .stopped
    private(set) var lastError: String?
    private(set) var resolution = DaemonLocator.Resolution(candidates: [])
    /// The child process when running in foreground. Not launchd's business.
    private var child: Process?
    private let previewMode: Bool

    init(previewMode: Bool = false) {
        self.previewMode = previewMode
        if previewMode { agentState = .notRegistered }
    }

    var daemonURL: URL? { resolution.url }
    var isForegroundRunning: Bool { if case .running = foreground { return true }; return false }

    /// Runs `daemonPath` before every action and lets the Setup screen show what was found.
    func locate(config: GatewayConfig) {
        resolution = DaemonLocator.resolve(config: config)
    }

    func refreshAgentState() {
        guard !previewMode else { return }
        switch SMAppService.agent(plistName: Self.agentPlistName).status {
        case .notRegistered: agentState = .notRegistered
        case .enabled: agentState = .enabled
        case .requiresApproval: agentState = .requiresApproval
        case .notFound: agentState = .notFound
        @unknown default: agentState = .unavailable("unknown SMAppService status")
        }
    }

    /// "Start gateway": records the daemon path for the launcher script, then registers the
    /// LaunchAgent. launchd starts it at once (RunAtLoad) and at every login.
    func register(config: GatewayConfig) {
        lastError = nil
        locate(config: config)
        guard let url = daemonURL else {
            lastError = "No GatewayDaemon binary found. Run `swift build` in the repository first."
            return
        }
        do {
            try GatewayConfig.merge(["daemon_path": url.path])
        } catch {
            lastError = "Could not write config.json: \(error.localizedDescription)"
            return
        }
        guard !previewMode else { agentState = .enabled; return }
        do {
            try SMAppService.agent(plistName: Self.agentPlistName).register()
        } catch {
            lastError = "launchd registration failed: \(error.localizedDescription)"
        }
        refreshAgentState()
    }

    /// Removes the LaunchAgent; launchd stops the daemon.
    func unregister() {
        lastError = nil
        guard !previewMode else { agentState = .notRegistered; return }
        do {
            try SMAppService.agent(plistName: Self.agentPlistName).unregister()
        } catch {
            lastError = "launchd unregister failed: \(error.localizedDescription)"
        }
        refreshAgentState()
    }

    /// System Settings → General → Login Items, where the owner approves the agent.
    func openLoginItemsSettings() {
        guard !previewMode else { return }
        SMAppService.openSystemSettingsLoginItems()
    }

    /// "Restart gateway": `launchctl kickstart -k` for the launchd agent, or stop and start
    /// the foreground child.
    func restart(config: GatewayConfig) {
        lastError = nil
        if isForegroundRunning {
            stopForeground()
            runInForeground(config: config)
            return
        }
        guard !previewMode else { return }
        let target = "gui/\(getuid())/\(Self.agentLabel)"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["kickstart", "-k", target]
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                lastError = "launchctl kickstart failed (\(process.terminationStatus)): \(output.trimmingCharacters(in: .whitespacesAndNewlines))"
            }
        } catch {
            lastError = "Could not run launchctl: \(error.localizedDescription)"
        }
    }

    /// Development fallback: the daemon as a child of the app. It dies with the app, so this
    /// never satisfies goal #1 ("closing the menu bar app does not stop it").
    func runInForeground(config: GatewayConfig) {
        lastError = nil
        locate(config: config)
        guard let url = daemonURL else {
            lastError = "No GatewayDaemon binary found. Run `swift build` in the repository first."
            return
        }
        guard !previewMode else { foreground = .running(pid: 4242); return }
        stopForeground()
        let process = Process()
        process.executableURL = url
        process.environment = ProcessInfo.processInfo.environment
        do {
            try FileManager.default.createDirectory(at: GatewayConfig.logDirectory, withIntermediateDirectories: true)
            let logURL = GatewayConfig.logDirectory.appending(path: "daemon-foreground.log")
            if !FileManager.default.fileExists(atPath: logURL.path) {
                FileManager.default.createFile(atPath: logURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: logURL)
            handle.seekToEndOfFile()
            process.standardOutput = handle
            process.standardError = handle
            process.terminationHandler = { finished in
                let code = finished.terminationStatus
                Task { @MainActor [weak self] in
                    guard let self, self.child === finished else { return }
                    self.foreground = .exited(code: code)
                    self.child = nil
                }
            }
            try process.run()
            child = process
            foreground = .running(pid: process.processIdentifier)
        } catch {
            lastError = "Could not start the daemon: \(error.localizedDescription)"
            foreground = .stopped
        }
    }

    func stopForeground() {
        guard let child else { return }
        child.terminationHandler = nil
        if child.isRunning { child.terminate() }
        self.child = nil
        foreground = .stopped
    }

    static var foregroundLogURL: URL { GatewayConfig.logDirectory.appending(path: "daemon-foreground.log") }
    static var agentLogURL: URL { GatewayConfig.logDirectory.appending(path: "daemon.log") }
}
