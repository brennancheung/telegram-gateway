import SwiftUI

/// The first tab: is it working, does anything need me, which apps are connected.
struct OverviewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PanelSize.gap) {
                HeroCard()

                if !model.needsYou.isEmpty {
                    LabeledSection("Needs you") {
                        RowCard(tone: .attention) {
                            ForEach(model.needsYou) { item in
                                NeedsRow(item: item)
                            }
                        }
                    }
                }

                LabeledSection("Apps") {
                    if model.grants.isEmpty {
                        Card {
                            Text("No apps have access yet.")
                                .font(TypeScale.body)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        RowCard {
                            ForEach(model.grants) { grant in
                                Button {
                                    model.tab = .apps
                                } label: {
                                    HStack {
                                        Text(grant.app.name)
                                            .font(TypeScale.rowTitle)
                                            .lineLimit(1)
                                        Spacer(minLength: 8)
                                        TrailingState(tone: grant.state.tone, text: grant.state.text)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                if let health = model.health {
                    Text("Gateway \(health.version) · \(Wording.uptime(since: health.startedAt))")
                        .font(TypeScale.secondary)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, PanelSize.margin)
            .padding(.bottom, PanelSize.margin)
        }
    }
}

/// One large state line, one secondary line, and the single action when something is wrong.
struct HeroCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let hero = model.hero
        Card(tone: hero.tone, padding: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(hero.title)
                    .font(TypeScale.hero)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = hero.detail {
                    Text(detail)
                        .font(TypeScale.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                switch hero.action {
                case .chooseChats:
                    Button("Choose chats") { model.tab = .chats }
                        .buttonStyle(.primary)
                        .padding(.top, 6)
                case .startGateway:
                    Button("Start gateway") { Task { await model.startGateway() } }
                        .buttonStyle(.primary)
                        .padding(.top, 6)
                case nil:
                    EmptyView()
                }
            }
        }
    }
}

/// One thing waiting for the owner, with its one action.
struct NeedsRow: View {
    @Environment(AppModel.self) private var model
    var item: NeedsItem

    var body: some View {
        HStack(spacing: 8) {
            switch item {
            case .request(let request):
                TitleAndDetail(title: "\(request.name) wants access", detail: Wording.timeLeft(until: request.expiresAt))
                Spacer(minLength: 8)
                Button("Review") {
                    Task {
                        if model.chats.isEmpty { await model.loadChats() }
                        model.beginApproval(request)
                    }
                }
                .controlSize(.small)
            case .webhook(let grant):
                let paused = grant.webhook?.state == .paused
                TitleAndDetail(
                    title: paused ? "\(grant.app.name): delivery paused" : "\(grant.app.name): delivery failing",
                    detail: grant.webhook?.lastError.map { paused ? $0.capitalizedFirst : "Retrying · \($0)" })
                Spacer(minLength: 8)
                if paused {
                    Button("Resume") { Task { await model.resumeWebhook(grant) } }
                        .controlSize(.small)
                } else {
                    Button("View") { model.overlay = .grant(grant.id) }
                        .controlSize(.small)
                }
            }
        }
    }
}

extension Grant {
    /// Its delivery stopped or is failing.
    var needsAttention: Bool { webhook?.state == .paused || webhook?.state == .retrying }

    /// The trailing state of an app in a list: quiet when fine, amber when it needs the owner.
    var state: (tone: Tone, text: String) {
        if let webhook {
            switch webhook.state {
            case .paused: return (.attention, "Paused")
            case .retrying: return (.attention, "Failing")
            case .active, .unknown:
                if let last = [webhook.lastDeliveryAt, lastSeenAt].compactMap({ $0 }).max() {
                    return (.ok, Wording.ago(last))
                }
                return (.neutral, "Nothing sent yet")
            }
        }
        if let lastSeenAt { return (.ok, Wording.ago(lastSeenAt)) }
        return (.neutral, "Not connected yet")
    }

    /// "2 chats · new messages, chat names", "Product folder · …", or "1 chat · 4 permissions"
    /// once naming them would wrap the row. The detail screen lists them in full.
    var summary: String {
        let place = chats.isFolder
            ? "\(chats.folderTitle ?? "A") folder"
            : Wording.count(chats.chatIds?.count ?? 0, "chat")
        let permissions = scopes.count <= 2 ? Permission.summary(scopes) : Wording.count(scopes.count, "permission")
        return "\(place) · \(permissions)"
    }
}

#Preview("Overview") {
    RootView().environment(AppModel.preview(.loggedIn))
}

#Preview("Overview, quiet") {
    RootView().environment(AppModel.preview(.loggedInQuiet))
}

#Preview("Overview, reconnecting") {
    RootView().environment(AppModel.preview(.reconnecting))
}
