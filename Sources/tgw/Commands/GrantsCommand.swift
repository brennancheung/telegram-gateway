import ArgumentParser
import Foundation
import GatewayCore

struct GrantsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "grants",
        abstract: "List applications' grants, revoke one, resume a paused webhook.",
        subcommands: [List.self, Show.self, Revoke.self, ResumeWebhook.self],
        defaultSubcommand: List.self
    )

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Current grants (--all includes revoked ones kept for 30 days).")

        @Flag(help: "Include revoked grants.")
        var all = false

        @OptionGroup var output: OutputOptions

        func run() async throws {
            let client = try Admin.client()
            let json = try Admin.check(try await client.get("/v1/admin/grants" + (all ? "?include_revoked=true" : "")))
            if output.json { print(json.pretty()); return }
            let grants = json["grants"]?.arrayValue ?? []
            if grants.isEmpty { print("no grants"); return }
            Admin.table(["id", "app", "scopes", "chats", "effective", "webhook", "last seen", "revoked"], grants.map { g in
                let chats: String = g["chats"]?["mode"] == "folder" ? "folder \(g["chats"]?["folder_title"]?.stringValue ?? g["chats"]?["folder_id"]?.stringValue ?? "")" : "\((g["chats"]?["chat_ids"]?.arrayValue ?? []).count) chats"
                let webhook = g["webhook"] == .null ? "-" : "\(g["webhook"]?["state"]?.stringValue ?? "") (\(g["webhook"]?["pending_events"]?.intValue ?? 0) pending)"
                return [
                    g["id"]?.stringValue ?? "", g["app"]?["name"]?.stringValue ?? "",
                    (g["scopes"]?.arrayValue ?? []).compactMap(\.stringValue).joined(separator: ","), chats,
                    String((g["effective_chat_ids"]?.arrayValue ?? []).count), webhook, Admin.short(g["last_seen_at"]), Admin.short(g["revoked_at"]),
                ]
            })
        }
    }

    struct Show: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "One grant with stats and recent webhook deliveries.")

        @Argument(help: "The grant id (grant_…).")
        var id: String

        func run() async throws {
            let client = try Admin.client()
            let json = try Admin.check(try await client.get("/v1/admin/grants/\(id)"))
            print(json.pretty())
            let deliveries = try Admin.check(try await client.get("/v1/admin/grants/\(id)/deliveries?limit=10"))
            let rows = deliveries["deliveries"]?.arrayValue ?? []
            if !rows.isEmpty {
                print("\nrecent deliveries:")
                Admin.table(["delivery", "seqs", "events", "attempt", "status", "http", "sent", "error"], rows.map { d in
                    [d["delivery_id"]?.stringValue ?? "", "\(d["first_seq"]?.intValue ?? 0)–\(d["last_seq"]?.intValue ?? 0)", String(d["event_count"]?.intValue ?? 0), String(d["attempt"]?.intValue ?? 0), d["status"]?.stringValue ?? "", d["http_status"]?.intValue.map(String.init) ?? "-", Admin.short(d["sent_at"]), d["error"]?.stringValue ?? ""]
                })
            }
        }
    }

    struct Revoke: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Revoke a grant. Immediate and permanent: the app must request access again.")

        @Argument(help: "The grant id (grant_…).")
        var id: String

        func run() async throws {
            let client = try Admin.client()
            _ = try Admin.check(try await client.delete("/v1/admin/grants/\(id)"))
            print("revoked \(id)")
        }
    }

    struct ResumeWebhook: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "resume-webhook", abstract: "Resume a paused webhook from its cursor.")

        @Argument(help: "The grant id (grant_…).")
        var id: String

        func run() async throws {
            let client = try Admin.client()
            let json = try Admin.check(try await client.post("/v1/admin/grants/\(id)/webhook/resume"))
            print("webhook \(json["state"]?.stringValue ?? "") from seq \(json["cursor_seq"]?.intValue ?? 0)")
        }
    }
}
