import ArgumentParser
import Foundation
import GatewayCore

/// Shared plumbing for the daemon-backed commands: find the daemon (port from config.json /
/// TGW_PORT), the admin token (login Keychain), and print replies.
enum Admin {
    static func client() throws -> GatewayClient {
        let paths = Paths.resolve()
        let config = try Config.load(paths: paths)
        let secrets = Secrets.resolve(config: config, paths: paths)
        guard let token = try Secrets.existingAdminToken(secrets) else {
            throw CLIError("""
                no admin token in \(secrets.description). The daemon creates it on first run: \
                install it with `tgw daemon install` or run GatewayDaemon once.
                """)
        }
        return GatewayClient(port: config.port, token: token)
    }

    /// Throws a readable error for a non-2xx reply.
    static func check(_ reply: GatewayClient.Reply) throws -> JSONValue {
        guard reply.isSuccess else {
            let code = reply.errorCode ?? "http_\(reply.status)"
            let message = reply.errorMessage ?? reply.json.serializedString()
            let id = reply.requestId.map { " (request \($0))" } ?? ""
            throw CLIError("\(code): \(message)\(id)")
        }
        return reply.json
    }

    /// Prints rows as aligned columns.
    static func table(_ header: [String], _ rows: [[String]]) {
        let all = [header] + rows
        var widths = header.map(\.count)
        for row in all {
            for (i, cell) in row.enumerated() where i < widths.count { widths[i] = max(widths[i], cell.count) }
        }
        for row in all {
            let line = row.enumerated().map { i, cell in
                i == row.count - 1 ? cell : cell.padding(toLength: widths[i], withPad: " ", startingAt: 0)
            }.joined(separator: "  ")
            print(line)
        }
    }

    static func short(_ date: JSONValue?) -> String {
        date?.stringValue ?? "-"
    }

    static func idList(_ value: JSONValue?) -> String {
        (value?.arrayValue ?? []).compactMap(\.stringValue).joined(separator: ",")
    }
}

/// `--json` on a command prints the raw reply instead of a table.
struct OutputOptions: ParsableArguments {
    @Flag(help: "Print the daemon's JSON reply instead of a table.")
    var json = false
}
