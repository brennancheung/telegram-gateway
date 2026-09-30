import Darwin
import Foundation

/// The single-instance guard for TDLib's directory. Whoever owns TDLib (the daemon, or a
/// `tgw` command that opens TDLib directly) takes an exclusive `flock` on `<home>/daemon.lock`
/// and writes its pid and role into it. A second process finds the lock held and refuses to
/// start with a message naming the holder. The lock is released when the descriptor closes,
/// including when the process dies, so a crash never leaves a stale lock.
public final class InstanceLock: Sendable {
    public let path: URL
    private let descriptor: Int32

    private init(path: URL, descriptor: Int32) {
        self.path = path
        self.descriptor = descriptor
    }

    /// Takes the lock or throws `GatewayError.locked` describing who holds it.
    public static func acquire(paths: Paths, role: String) throws -> InstanceLock {
        try FileManager.default.createDirectory(at: paths.home, withIntermediateDirectories: true)
        let fd = open(paths.lock.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw GatewayError.locked("cannot open \(paths.lock.path): \(String(cString: strerror(errno)))")
        }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let holder = describeHolder(paths: paths, requester: role)
            close(fd)
            throw GatewayError.locked(holder)
        }
        ftruncate(fd, 0)
        let content = "\(getpid()) \(role)\n"
        _ = content.withCString { write(fd, $0, strlen($0)) }
        return InstanceLock(path: paths.lock, descriptor: fd)
    }

    /// Who holds the lock, if anyone: `(pid, role)` read from the file when the lock cannot be
    /// taken. `nil` when the lock is free.
    public static func holder(paths: Paths) -> (pid: Int32, role: String)? {
        let fd = open(paths.lock.path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return nil
        }
        return readHolder(paths: paths)
    }

    private static func readHolder(paths: Paths) -> (pid: Int32, role: String)? {
        guard let content = try? String(contentsOf: paths.lock, encoding: .utf8) else { return nil }
        let parts = content.split(separator: " ", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard parts.count == 2, let pid = Int32(parts[0]) else { return nil }
        return (pid, parts[1])
    }

    private static func describeHolder(paths: Paths, requester: String) -> String {
        guard let (pid, role) = readHolder(paths: paths) else {
            return "another process holds \(paths.lock.path)"
        }
        switch role {
        case "daemon" where requester == "daemon":
            return "another gateway daemon (pid \(pid)) is already running for \(paths.home.path); stop it first (`tgw daemon uninstall`, or kill \(pid))."
        case "daemon":
            return """
                the gateway daemon (pid \(pid)) is running and owns TDLib. Direct TDLib commands \
                cannot run at the same time; use the daemon-backed equivalents (`tgw health`, \
                `tgw monitor`, `tgw requests`, `tgw grants`, `tgw events tail`) or stop the daemon \
                first (`tgw daemon uninstall`, or `launchctl bootout gui/$(id -u)/local.telegram-gateway`).
                """
        default:
            return "another tgw command (pid \(pid), \(role)) has TDLib open; wait for it to finish or stop it."
        }
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
