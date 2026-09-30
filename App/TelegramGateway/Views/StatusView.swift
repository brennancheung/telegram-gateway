import SwiftUI

/// The top of the panel once logged in: daemon, Telegram, account, events, and one line per
/// grant with its last delivery.
struct StatusView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                PanelSectionHeader(title: "Gateway")
                InfoRow("Daemon") {
                    HStack(spacing: 6) {
                        StatusDot(tone: model.reachable ? .ok : .failed)
                        Text(model.reachable ? "Reachable at \(model.config.baseURL.host() ?? "127.0.0.1"):\(model.config.baseURL.port ?? GatewayConfig.defaultPort)" : "Not reachable")
                    }
                }
                if let health = model.health {
                    InfoRow("Version", health.version)
                    InfoRow("Up since", health.startedAt.formatted(date: .abbreviated, time: .shortened))
                    InfoRow("launchd", model.daemon.isForegroundRunning ? "Foreground (child of this app)" : shortAgentState)
                }

                PanelSectionHeader(title: "Telegram")
                if let health = model.health {
                    InfoRow("Login") {
                        HStack(spacing: 6) {
                            StatusDot(tone: health.tdlib.authState.isLoggedIn ? .ok : .waiting)
                            Text(health.tdlib.authState.label)
                        }
                    }
                    InfoRow("Connection") {
                        HStack(spacing: 6) {
                            StatusDot(tone: health.tdlib.connectionState == .ready ? .ok : .waiting)
                            Text(health.tdlib.connectionState.label)
                        }
                    }
                }
                if let account = model.status?.account {
                    InfoRow("Account") {
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(account.displayName)
                            if let username = account.username {
                                Text("@\(username)").foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                PanelSectionHeader(title: "Activity")
                if let status = model.status {
                    if let today = status.eventsToday {
                        InfoRow("Events today", today.formatted())
                    }
                    InfoRow("Events last hour", status.eventsLastHour.formatted())
                    InfoRow("Events total", status.headSeq.formatted())
                    InfoRow("Monitored chats", status.monitoredChatCount.formatted())
                    InfoRow("Webhooks", webhookSummary(status.webhooks))
                    if status.backfill.inProgress {
                        InfoRow("Backfill", "\(status.backfill.chatsPending) chats pending")
                    }
                } else if let health = model.health {
                    InfoRow("Events total", health.headSeq.formatted())
                }

                if !model.grants.isEmpty {
                    PanelSectionHeader(title: "Grants", trailing: "\(model.grants.count)")
                    ForEach(model.grants) { grant in
                        InfoRow(grant.app.name) {
                            HStack(spacing: 6) {
                                if let webhook = grant.webhook {
                                    StatusDot(tone: webhook.state == .active ? .ok : webhook.state == .retrying ? .waiting : .failed)
                                    Text(webhook.lastDeliveryAt.map { "delivered \($0.relativeDescription)" } ?? (webhook.state == .paused ? "paused" : "no delivery yet"))
                                } else {
                                    StatusDot(tone: grant.lastSeenAt == nil ? .off : .ok)
                                    Text(grant.lastSeenAt.map { "seen \($0.relativeDescription)" } ?? "never connected")
                                }
                            }
                            .foregroundStyle(.secondary)
                        }
                    }
                }

                if let error = model.lastError, model.reachable {
                    ErrorLine(message: error)
                }
                if let refreshed = model.lastRefresh {
                    Text("Updated \(refreshed.formatted(date: .omitted, time: .standard))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 4)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .task {
            if model.grants.isEmpty, let grants = try? await model.client.grants() { model.grants = grants }
        }
    }

    private var shortAgentState: String {
        switch model.daemon.agentState {
        case .enabled: "Registered"
        case .requiresApproval: "Needs approval in Login Items"
        case .notRegistered: "Not registered"
        case .notFound: "Registered, plist not found"
        case .unavailable: "Unknown"
        }
    }

    private func webhookSummary(_ counts: WebhookCounts) -> String {
        var parts: [String] = []
        if counts.active > 0 { parts.append("\(counts.active) ok") }
        if counts.retrying > 0 { parts.append("\(counts.retrying) retrying") }
        if counts.paused > 0 { parts.append("\(counts.paused) paused") }
        return parts.isEmpty ? "none" : parts.joined(separator: " · ")
    }
}

#Preview("Status") {
    RootView().environment(AppModel.preview(.loggedIn))
}
