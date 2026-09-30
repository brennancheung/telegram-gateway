import SwiftUI

/// The Apps tab: requests waiting for a decision first, then the apps that have access.
struct AppsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PanelSize.gap) {
                ForEach(Array(model.requests.enumerated()), id: \.element.id) { index, request in
                    // One prominent button per screen: the oldest request's.
                    RequestCard(request: request, prominent: index == 0)
                }

                if !model.grants.isEmpty {
                    LabeledSection("Has access") {
                        RowCard {
                            ForEach(model.grants) { grant in
                                Button {
                                    model.overlay = .grant(grant.id)
                                } label: {
                                    HStack(spacing: 8) {
                                        TitleAndDetail(title: grant.app.name, detail: grant.summary)
                                        Spacer(minLength: 8)
                                        TrailingState(tone: grant.state.tone, text: grant.state.text)
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundStyle(.tertiary)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                if model.requests.isEmpty, model.grants.isEmpty {
                    VStack(spacing: 4) {
                        Text("No apps yet")
                            .font(TypeScale.screenTitle)
                        Text("When an app asks the gateway for access, it appears here for you to approve.")
                            .font(TypeScale.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 24)
                    .padding(.top, 110)
                }

                if let error = model.accessError {
                    Card(tone: .failed) {
                        Text(error)
                            .font(TypeScale.body)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.horizontal, PanelSize.margin)
            .padding(.bottom, PanelSize.margin)
        }
        .task {
            while !Task.isCancelled {
                await model.loadAccess()
                if model.chats.isEmpty { await model.loadChats() }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
}

/// A pending request: who, what it does, what it wants, where, and the decision.
struct RequestCard: View {
    @Environment(AppModel.self) private var model
    var request: AccessRequest
    var prominent: Bool

    var body: some View {
        Card(tone: .attention) {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(request.name)
                            .font(TypeScale.screenTitle)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(Wording.timeLeft(until: request.expiresAt))
                            .font(TypeScale.secondary)
                            .foregroundStyle(.secondary)
                    }
                    Text(request.description)
                        .font(TypeScale.body)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 5) {
                    FactRow("Wants") {
                        Text(Permission.sentence(request.scopes))
                            .fixedSize(horizontal: false, vertical: true)
                            .help(Permission.sorted(request.scopes).joined(separator: ", "))
                    }
                    FactRow("In") { requestedChats }
                    if let url = request.webhookUrl {
                        FactRow("Sends to") {
                            Text(Wording.host(of: url))
                                .lineLimit(1)
                                .help(url)
                        }
                    }
                }

                HStack(spacing: 8) {
                    Spacer()
                    Button("Deny") { Task { await model.deny(request) } }
                    if prominent {
                        Button("Review…", action: review)
                            .buttonStyle(.primary)
                    } else {
                        Button("Review…", action: review)
                    }
                }
            }
        }
    }

    private func review() {
        Task {
            if model.chats.isEmpty { await model.loadChats() }
            model.beginApproval(request)
        }
    }

    @ViewBuilder
    private var requestedChats: some View {
        let ids = request.requestedChats.chatIds
        if ids.isEmpty {
            Text("Any chats you choose")
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(ids, id: \.self) { id in
                    let status = request.requestedChatsStatus?.first { $0.chatId == id }
                    let monitored = model.chatsByID[id]?.isMonitored ?? status?.isMonitored ?? false
                    let title = Text(model.chatsByID[id]?.title ?? status?.title ?? id)
                    let note = Text("not monitored yet")
                        .font(TypeScale.secondary)
                        .foregroundStyle(Tone.attention.color)
                    if monitored {
                        title.lineLimit(1)
                    } else {
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                title.fixedSize()
                                note.fixedSize()
                            }
                            VStack(alignment: .leading, spacing: 0) {
                                title.lineLimit(1)
                                note
                            }
                        }
                    }
                }
            }
        }
    }
}

/// One app's access in full, with Resume when its delivery is paused and Revoke.
struct GrantDetailView: View {
    @Environment(AppModel.self) private var model
    var grantId: String
    @State private var confirmingRevoke = false

    var body: some View {
        if let grant = model.grant(id: grantId) {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: PanelSize.gap) {
                        VStack(alignment: .leading, spacing: 4) {
                            SubscreenHeader(title: grant.app.name) { model.overlay = nil }
                            Text(grant.app.description)
                                .font(TypeScale.body)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if grant.needsAttention { delivery(grant) }
                        LabeledSection("Can read") {
                            RowCard {
                                ForEach(Permission.sorted(grant.scopes), id: \.self) { scope in
                                    TitleAndDetail(title: Permission.name(scope), detail: Permission.meaning(scope))
                                        .help(scope)
                                }
                            }
                        }
                        LabeledSection(grant.chats.isFolder ? "Chats in the \(grant.chats.folderTitle ?? "") folder" : "Chats",
                                       footer: grant.chats.isFolder ? "Chats you add to the folder on your phone are included automatically." : nil) {
                            RowCard {
                                let ids = grant.chats.isFolder ? grant.effectiveChatIds : (grant.chats.chatIds ?? [])
                                if ids.isEmpty {
                                    Text("None right now")
                                        .font(TypeScale.body)
                                        .foregroundStyle(.secondary)
                                }
                                ForEach(ids, id: \.self) { id in
                                    let live = grant.effectiveChatIds.contains(id)
                                    TitleAndDetail(
                                        title: model.chatsByID[id]?.title ?? id,
                                        detail: live ? model.chatsByID[id].map(Wording.chatSubtitle) : "No longer monitored — nothing is sent",
                                        detailTone: live ? .neutral : .attention)
                                }
                            }
                        }
                        if !grant.needsAttention { delivery(grant) }
                        if let error = model.accessError {
                            Card(tone: .failed) {
                                Text(error).font(TypeScale.body).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(PanelSize.margin)
                }
                FooterBar {
                    Text("Access since \(grant.createdAt.formatted(.dateTime.month(.abbreviated).day()))")
                        .font(TypeScale.secondary)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(role: .destructive) { confirmingRevoke = true } label: {
                        Text("Revoke access…").foregroundStyle(Tone.failed.color)
                    }
                }
            }
            .task { if model.chats.isEmpty { await model.loadChats() } }
            .confirmationDialog("Revoke \(grant.app.name)'s access?", isPresented: $confirmingRevoke) {
                Button("Revoke", role: .destructive) { Task { await model.revoke(grant) } }
            } message: {
                Text("It stops receiving messages immediately. This can't be undone; the app has to ask for access again.")
            }
        } else {
            // Revoked (here or elsewhere) while open.
            Color.clear.onAppear { model.overlay = nil }
        }
    }

    @ViewBuilder
    private func delivery(_ grant: Grant) -> some View {
        if let webhook = grant.webhook {
            switch webhook.state {
            case .paused:
                Card(tone: .attention) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Delivery paused")
                            .font(TypeScale.rowTitle)
                        Text("\(Wording.host(of: webhook.url)) stopped answering\(webhook.lastError.map { " (\($0))" } ?? ""). \(Wording.count(webhook.pendingEvents, "message")) waiting; none are lost.")
                            .font(TypeScale.body)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Resume") { Task { await model.resumeWebhook(grant) } }
                            .buttonStyle(.primary)
                            .padding(.top, 4)
                    }
                }
            case .retrying:
                Card(tone: .attention) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Delivery failing")
                            .font(TypeScale.rowTitle)
                        Text("\(Wording.host(of: webhook.url)) isn't answering\(webhook.lastError.map { " (\($0))" } ?? ""). The gateway keeps retrying for a day, then pauses.")
                            .font(TypeScale.body)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            case .active, .unknown:
                LabeledSection("Delivery") {
                    RowCard {
                        ValueRow("Sends to") { Text(Wording.host(of: webhook.url)).lineLimit(1).help(webhook.url) }
                        ValueRow("Last delivery", webhook.lastDeliveryAt.map { Wording.ago($0) } ?? "Nothing sent yet")
                    }
                }
            }
        } else {
            LabeledSection("Delivery") {
                RowCard {
                    ValueRow("Connects", "Directly to the gateway")
                    ValueRow("Last seen", grant.lastSeenAt.map { Wording.ago($0) } ?? "Not connected yet")
                }
            }
        }
    }
}

/// Decide what one app gets: which chats, which permissions.
struct ApproveView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let draft = model.approval {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: PanelSize.gap) {
                        SubscreenHeader(title: "Give \(draft.request.name) access") { model.cancelApproval() }

                        LabeledSection(draft.followFolder ? "Folder" : "Chats",
                                       footer: draft.followFolder ? "The app sees whatever is in the folder, including chats you add later." : nil) {
                            if draft.followFolder { folderCard(draft) } else { chatsCard(draft) }
                        }

                        LabeledSection("Can read") {
                            RowCard(inset: 26) {
                                ForEach(Permission.sorted(draft.request.scopes), id: \.self) { scope in
                                    HStack(spacing: 10) {
                                        RowCheckbox(isOn: scopeBinding(scope))
                                        TitleAndDetail(title: Permission.name(scope), detail: Permission.meaning(scope))
                                        Spacer(minLength: 0)
                                    }
                                    .contentShape(Rectangle())
                                    .onTapGesture { scopeBinding(scope).wrappedValue.toggle() }
                                    .help(scope)
                                }
                            }
                        }

                        if let error = model.accessError {
                            Card(tone: .failed) {
                                Text(error).font(TypeScale.body).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(PanelSize.margin)
                }
                FooterBar {
                    Text(model.approvalSummary(draft))
                        .font(TypeScale.body)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Spacer()
                    Button("Cancel") { model.cancelApproval() }
                    Button(model.approving ? "Approving…" : "Approve") { Task { await model.approve() } }
                        .buttonStyle(.primary)
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.approving || !model.canApprove(draft))
                }
            }
            .task { if model.chats.isEmpty { await model.loadChats() } }
        }
    }

    private func chatsCard(_ draft: ApprovalDraft) -> some View {
        RowCard(inset: 64) {
            ForEach(model.approvalChatIds(draft), id: \.self) { id in
                let chat = model.chatsByID[id]
                let monitored = chat?.isMonitored ?? false
                HStack(spacing: 10) {
                    RowCheckbox(isOn: chatBinding(id))
                    IconTile(symbol: chat?.type.symbolName ?? "questionmark")
                    TitleAndDetail(
                        title: chat?.title ?? draft.request.requestedChatsStatus?.first { $0.chatId == id }?.title ?? id,
                        detail: monitored ? chat.map(Wording.chatSubtitle) : "Not monitored yet — approving starts monitoring it",
                        detailTone: monitored ? .neutral : .attention)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .onTapGesture { chatBinding(id).wrappedValue.toggle() }
            }
            if model.otherMonitoredCount(draft) > 0, !draft.showOtherChats {
                linkRow("Show \(Wording.count(model.otherMonitoredCount(draft), "other monitored chat"))") {
                    model.approval?.showOtherChats = true
                }
            }
            if model.approvalChatIds(draft).isEmpty {
                Text("Nothing is monitored yet. Pick chats in the Chats tab first.")
                    .font(TypeScale.body)
                    .foregroundStyle(.secondary)
            }
            linkRow("Follow a folder instead") {
                model.approval?.followFolder = true
                if model.approval?.folderId == nil {
                    model.approval?.folderId = model.folders.first(where: \.isMonitored)?.id
                }
            }
        }
    }

    private func folderCard(_ draft: ApprovalDraft) -> some View {
        RowCard(inset: 64) {
            let monitoredFolders = model.folders.filter(\.isMonitored)
            if monitoredFolders.isEmpty {
                Text("No folder is monitored. Tick one in the Chats tab first.")
                    .font(TypeScale.body)
                    .foregroundStyle(.secondary)
            }
            ForEach(monitoredFolders) { folder in
                HStack(spacing: 10) {
                    Image(systemName: draft.folderId == folder.id ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 14))
                        .foregroundStyle(draft.folderId == folder.id ? Color.accentColor : Color.secondary)
                        .frame(width: 16)
                    IconTile(symbol: "folder")
                    TitleAndDetail(title: folder.title, detail: Wording.count(folder.chatIds.count, "chat"))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .onTapGesture { model.approval?.folderId = folder.id }
                .accessibilityAddTraits(draft.folderId == folder.id ? .isSelected : [])
            }
            linkRow("Choose chats instead") { model.approval?.followFolder = false }
        }
    }

    private func linkRow(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).font(TypeScale.body)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            // Lines up with the titles above (past the checkbox and the icon).
            .padding(.leading, 64)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func chatBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { model.approval?.chatIds.contains(id) ?? false },
            set: { on in
                if on { model.approval?.chatIds.insert(id) } else { model.approval?.chatIds.remove(id) }
            })
    }

    private func scopeBinding(_ scope: String) -> Binding<Bool> {
        Binding(
            get: { model.approval?.scopes.contains(scope) ?? false },
            set: { on in
                if on { model.approval?.scopes.insert(scope) } else { model.approval?.scopes.remove(scope) }
            })
    }
}

#Preview("Apps") {
    let model = AppModel.preview(.loggedIn)
    model.tab = .apps
    return RootView().environment(model)
}

#Preview("Apps, empty") {
    let model = AppModel.preview(.loggedInEmpty)
    model.tab = .apps
    return RootView().environment(model)
}
