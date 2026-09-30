import ArgumentParser
import Foundation
import GatewayCore

struct RequestsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "requests",
        abstract: "List, approve or deny access requests from applications.",
        subcommands: [List.self, Approve.self, Deny.self],
        defaultSubcommand: List.self
    )

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Pending access requests (--all for resolved ones still retained).")

        @Flag(help: "Include approved, denied and expired requests still retained.")
        var all = false

        @OptionGroup var output: OutputOptions

        func run() async throws {
            let client = try Admin.client()
            let json = try Admin.check(try await client.get("/v1/admin/access-requests" + (all ? "?all=true" : "")))
            if output.json { print(json.pretty()); return }
            let requests = json["access_requests"]?.arrayValue ?? []
            if requests.isEmpty { print(all ? "no access requests" : "no pending access requests"); return }
            for r in requests {
                print("\(r["request_id"]?.stringValue ?? "")   \(r["status"]?.stringValue ?? "")   expires \(Admin.short(r["expires_at"]))")
                print("  \(r["name"]?.stringValue ?? "") — \(r["description"]?.stringValue ?? "")")
                print("  scopes: \((r["scopes"]?.arrayValue ?? []).compactMap(\.stringValue).joined(separator: " "))")
                if let status = r["requested_chats_status"]?.arrayValue {
                    for c in status {
                        print("  chat \(c["chat_id"]?.stringValue ?? "")  \(c["title"]?.stringValue ?? "(unknown)")  \(c["is_monitored"]?.boolValue == true ? "monitored" : "NOT monitored")")
                    }
                } else {
                    print("  chats: any")
                }
                if let url = r["webhook_url"]?.stringValue { print("  webhook: \(url)") }
            }
        }
    }

    struct Approve: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Approve a request for specific chats (or one folder), optionally narrowing the scopes.")

        @Argument(help: "The request id (req_…).")
        var id: String

        @Option(name: .customLong("chats"), parsing: .upToNextOption, help: "Chat ids to grant (must be monitored).")
        var chats: [String] = []

        @Option(help: "A folder id to grant instead of chats (must be monitored).")
        var folder: String?

        @Option(parsing: .upToNextOption, help: "Scopes to grant (default: the requested ones).")
        var scopes: [String] = []

        func validate() throws {
            if chats.isEmpty == (folder == nil) { throw ValidationError("give either --chats <id…> or --folder <id>") }
        }

        func run() async throws {
            let client = try Admin.client()
            var body: JSONObjectValue = [:]
            if let folder { body["folder_id"] = .string(folder) } else { body["chat_ids"] = .array(chats.map { .string($0) }) }
            if !scopes.isEmpty { body["scopes"] = .array(scopes.map { .string($0) }) }
            let grant = try Admin.check(try await client.post("/v1/admin/access-requests/\(id)/approve", .object(body)))
            print("approved: grant \(grant["id"]?.stringValue ?? "") for \(grant["app"]?["name"]?.stringValue ?? "")")
            print("scopes    \((grant["scopes"]?.arrayValue ?? []).compactMap(\.stringValue).joined(separator: " "))")
            print("effective \(Admin.idList(grant["effective_chat_ids"]))")
            print("The app receives its token on its next poll (within 10:00).")
        }
    }

    struct Deny: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Deny a request.")

        @Argument(help: "The request id (req_…).")
        var id: String

        @Option(help: "A reason shown to the app.")
        var reason: String?

        func run() async throws {
            let client = try Admin.client()
            _ = try Admin.check(try await client.post("/v1/admin/access-requests/\(id)/deny", ["reason": .optional(reason)]))
            print("denied \(id)")
        }
    }
}
