import SwiftUI

/// Overview: is it working, does anything need me, which apps are connected. The hero runs
/// across the top; "Needs you" and "Apps" sit side by side when the window is wide enough.
struct OverviewSection: View {
    @Environment(AppModel.self) private var model
    @State private var width: CGFloat = 0
    /// Below this, two columns would truncate the rows.
    private let twoColumnWidth: CGFloat = 700

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PanelSize.gap) {
                HeroPanel()
                if model.screen == .main {
                    let needs = model.appNeeds
                    if width >= twoColumnWidth, !needs.isEmpty {
                        HStack(alignment: .top, spacing: PanelSize.gap) {
                            needsSection(needs)
                            appsSection
                        }
                    } else {
                        if !needs.isEmpty { needsSection(needs) }
                        appsSection
                    }
                }
                if let health = model.health {
                    Text("Gateway \(health.version) · \(Wording.uptime(since: health.startedAt))")
                        .font(TypeScale.secondary)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(PanelSize.windowMargin)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    private func needsSection(_ needs: [NeedsItem]) -> some View {
        LabeledSection("Needs you") {
            RowCard(tone: .attention) {
                ForEach(needs) { item in
                    HStack(spacing: 8) {
                        TitleAndDetail(title: item.title, detail: item.detail)
                        Spacer(minLength: 8)
                        switch item {
                        case .request:
                            Button("Review…") { model.open(item) }
                        case .webhook(let grant):
                            if grant.webhook?.state == .paused {
                                Button("Resume") { Task { await model.resumeWebhook(grant) } }
                            } else {
                                Button("View") { model.open(item) }
                            }
                        default:
                            EmptyView()
                        }
                    }
                }
            }
        }
    }

    private var appsSection: some View {
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
                            model.section = .apps
                            model.selectedApp = .grant(grant.id)
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
    }
}

/// One large state line and one secondary line; when something is wrong, the card is tinted
/// and carries the one action that fixes it.
struct HeroPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let hero = model.hero
        Card(tone: hero.tone, padding: 16) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(failureReason == nil ? hero.title : "The gateway didn't start")
                        .font(TypeScale.hero)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail = failureReason ?? hero.detail {
                        Text(detail)
                            .font(TypeScale.body)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    if failureReason != nil {
                        Button("Show log") { showGatewayLog(model.daemon) }
                            .buttonStyle(.link)
                            .font(TypeScale.body)
                    }
                    if model.screen == .keyMissing, let error = model.tokenError {
                        Text(error)
                            .font(TypeScale.secondary)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                Spacer(minLength: 8)
                actions(hero)
            }
        }
    }

    @ViewBuilder
    private func actions(_ hero: AppModel.Hero) -> some View {
        if model.startPhase == .starting {
            ProgressView().controlSize(.small)
        } else if model.screen == .keyMissing {
            Button("Check again") { Task { await model.refresh() } }
            Button("Restart gateway") { model.restartGateway() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        } else {
            switch hero.action {
            case .chooseChats:
                Button("Choose chats") { model.section = .chats }
                    .buttonStyle(.borderedProminent)
            case .startGateway:
                Button(isFailed ? "Try again" : "Start gateway") { Task { await model.startGateway() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            case nil:
                EmptyView()
            }
        }
    }

    private var isFailed: Bool { failureReason != nil }

    /// Why the last start failed, while the gateway is still down.
    private var failureReason: String? {
        if case .failed(let reason) = model.startPhase, model.screen == .gatewayDown { return reason }
        return nil
    }
}

#Preview("Overview") {
    MainWindowView().environment(AppModel.preview(.loggedIn)).frame(width: 820, height: 560)
}

#Preview("Overview, gateway down") {
    MainWindowView().environment(AppModel.preview(.unreachable)).frame(width: 820, height: 560)
}
