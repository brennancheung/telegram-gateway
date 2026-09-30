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

/// Starts and stops the gateway. The normal route registers it with launchd through
/// `SMAppService` so it starts at login and outlives the app; the fallback runs it as a
/// child process of the app. Error strings are shown to the owner, so they say "gateway"
/// and never name launchd.
@MainActor
@Observable
final class DaemonManager {
    /// The LaunchAgent plist name inside the bundle (`Contents/Library/LaunchAgents/`). Its
    /// `Label` is the same string without `.plist`.
    static let agentLabel = "com.brennancheung.telegram-gateway.daemon"
    static let agentPlistName = agentLabel + ".plist"

    /// Whether macOS starts the gateway at login (what `SMAppService` reports).
    enum AgentState: Equatable, Sendable {
        case notRegistered
        case enabled
        case requiresApproval
        case notFound
        case unavailable(String)

        /// The value shown next to "Starts at login" in Gateway details.
        var startsAtLogin: String {
            switch self {
            case .notRegistered: "No"
            case .enabled: "Yes"
            case .requiresApproval: "Waiting for your approval"
            case .notFound: "Needs setting up again"
            case .unavailable: "Unknown"
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
    /// The child process when the gateway runs inside the app.
    private var child: Process?
    private let previewMode: Bool

    init(previewMode: Bool = false, agentState: AgentState = .notRegistered) {
        self.previewMode = previewMode
        self.agentState = agentState
    }

    var daemonURL: URL? { resolution.url }
    var isForegroundRunning: Bool { if case .running = foreground { return true }; return false }

    func clearError() { lastError = nil }

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
        @unknown default: agentState = .unavailable("unknown status")
        }
    }

    /// Records the gateway's program path for the launcher script, then registers it to
    /// start now and at every login.
    func register(config: GatewayConfig) {
        lastError = nil
        // Previews and tests never touch config.json or launchd.
        guard !previewMode else { agentState = .enabled; return }
        locate(config: config)
        guard let url = daemonURL else {
            lastError = "The gateway program is missing. Build it with swift build in the repository."
            return
        }
        do {
            try GatewayConfig.merge(["daemon_path": url.path])
        } catch {
            lastError = "Couldn't save the settings: \(error.localizedDescription)"
            return
        }
        do {
            try SMAppService.agent(plistName: Self.agentPlistName).register()
        } catch {
            lastError = "macOS didn't accept the gateway as a login item: \(error.localizedDescription)"
        }
        refreshAgentState()
    }

    /// Stops the gateway and stops starting it at login.
    func unregister() {
        lastError = nil
        guard !previewMode else { agentState = .notRegistered; return }
        do {
            try SMAppService.agent(plistName: Self.agentPlistName).unregister()
        } catch {
            lastError = "Couldn't remove the login item: \(error.localizedDescription)"
        }
        refreshAgentState()
    }

    /// System Settings → General → Login Items, where the owner allows the gateway.
    func openLoginItemsSettings() {
        guard !previewMode else { return }
        SMAppService.openSystemSettingsLoginItems()
    }

    /// `launchctl kickstart -k` for the registered gateway, or stop and start the child.
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
                lastError = "Couldn't restart the gateway: \(output.trimmingCharacters(in: .whitespacesAndNewlines))"
            }
        } catch {
            lastError = "Couldn't restart the gateway: \(error.localizedDescription)"
        }
    }

    /// The gateway as a child of the app. It stops when the app quits, so it is only the
    /// fallback when the login-item route is unavailable.
    func runInForeground(config: GatewayConfig) {
        lastError = nil
        guard !previewMode else { foreground = .running(pid: 4242); return }
        locate(config: config)
        guard let url = daemonURL else {
            lastError = "The gateway program is missing. Build it with swift build in the repository."
            return
        }
        stopForeground()
        let process = Process()
        process.executableURL = url
        process.environment = ProcessInfo.processInfo.environment
        do {
            try FileManager.default.createDirectory(at: GatewayConfig.logDirectory, withIntermediateDirectories: true)
            let logURL = Self.foregroundLogURL
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
            lastError = "Couldn't start the gateway: \(error.localizedDescription)"
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

    // MARK: Logs

    static var foregroundLogURL: URL { GatewayConfig.logDirectory.appending(path: "daemon-foreground.log") }
    static var agentLogURL: URL { GatewayConfig.logDirectory.appending(path: "daemon.log") }

    /// The log of whichever way the gateway is (or was last) run.
    var logURL: URL {
        switch foreground {
        case .running, .exited: Self.foregroundLogURL
        case .stopped: Self.agentLogURL
        }
    }

    /// The last non-empty line of the log, for the one-line reason when a start fails.
    func lastLogLine() -> String? {
        guard !previewMode, let handle = try? FileHandle(forReadingFrom: logURL) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 4096 ? size - 4096 : 0)
        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else { return nil }
        return text.split(separator: "\n").last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map(String.init)
    }
}
