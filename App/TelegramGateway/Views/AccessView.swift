import SwiftUI

/// Pending access requests with Approve / Deny, and the existing grants with Revoke. Polls
/// every 5s while shown (`model.refresh` also keeps the pending count for the badge).
struct AccessView: View {
    @Environment(AppModel.self) private var model
    @State private var revoking: Grant?

    var body: some View {
        List {
            Section {
                if model.requests.isEmpty {
                    Text("No pending requests. Applications ask for access with POST /v1/access-requests and appear here.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.requests) { request in
                        RequestCard(request: request)
                    }
                }
            } header: {
                Text("Requests")
            }
            Section {
                if model.grants.isEmpty {
                    Text("No application has access yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.grants) { grant in
                        GrantCard(grant: grant, revoke: { revoking = grant })
                    }
                }
            } header: {
                Text("Grants")
            }
            if let error = model.accessError {
                ErrorLine(message: error)
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .task {
            while !Task.isCancelled {
                await model.loadAccess()
                if model.chats.isEmpty { await model.loadChats() }
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .confirmationDialog("Revoke access for \(revoking?.app.name ?? "")?", isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }), presenting: revoking) { grant in
            Button("Revoke", role: .destructive) { Task { await model.revoke(grant) } }
        } message: { _ in
            Text("Its token stops working immediately and permanently. The application must request access again.")
        }
    }
}

/// One pending request as the owner sees it (docs/grants.md "what the owner sees").
struct RequestCard: View {
    @Environment(AppModel.self) private var model
    var request: AccessRequest
    @State private var denying = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(request.name)
                    .font(.headline)
                Spacer()
                Text("expires \(request.expiresAt.relativeDescription)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("“\(request.description)”")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            ChipRow {
                ForEach(request.scopes, id: \.self) { ScopeChip(scope: $0) }
            }
            requestedChats
            if let url = request.webhookUrl {
                Label(url, systemImage: "arrow.up.right.square")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack {
                Spacer()
                Button("Deny") { denying = true }
                Button("Approve…") { model.approving = request }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 4)
        .confirmationDialog("Deny \(request.name)?", isPresented: $denying) {
            Button("Deny", role: .destructive) { Task { await model.deny(request) } }
        } message: {
            Text("The application is told its request was denied. It can ask again.")
        }
    }

    @ViewBuilder
    private var requestedChats: some View {
        switch request.requestedChats {
        case .any:
            Label("Any chats you choose", systemImage: "bubble.left.and.bubble.right")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .list:
            VStack(alignment: .leading, spacing: 2) {
                ForEach(request.requestedChatsStatus ?? request.requestedChats.chatIds.map { RequestedChatStatus(chatId: $0, title: model.chatsByID[$0]?.title ?? $0, isMonitored: model.chatsByID[$0]?.isMonitored ?? false) }, id: \.chatId) { status in
                    HStack(spacing: 6) {
                        Image(systemName: status.isMonitored ? "eye" : "eye.slash")
                            .foregroundStyle(status.isMonitored ? Color.secondary : Color.orange)
                            .frame(width: 14)
                        Text(status.title)
                            .lineLimit(1)
                        Text(status.isMonitored ? "monitored" : "not monitored")
                            .foregroundStyle(status.isMonitored ? Color.secondary : Color.orange)
                    }
                    .font(.caption)
                }
            }
        }
    }
}

/// One grant: scopes, chats, webhook state, last activity, Revoke.
struct GrantCard: View {
    @Environment(AppModel.self) private var model
    var grant: Grant
    var revoke: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(grant.app.name)
                    .font(.headline)
                Spacer()
                Text(grant.lastSeenAt.map { "seen \($0.relativeDescription)" } ?? "never connected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ChipRow {
                ForEach(grant.scopes, id: \.self) { ScopeChip(scope: $0) }
            }
            Label(chatsSummary, systemImage: grant.chats.isFolder ? "folder" : "bubble.left.and.bubble.right")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            webhookLine
            HStack {
                Spacer()
                if grant.webhook?.state == .paused {
                    Button("Resume webhook") { Task { await model.resumeWebhook(grant) } }
                }
                Button("Revoke", role: .destructive, action: revoke)
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 4)
    }

    private var chatsSummary: String {
        let effective = grant.effectiveChatIds.count
        if grant.chats.isFolder {
            return "Folder “\(grant.chats.folderTitle ?? grant.chats.folderId ?? "?")” · \(effective) chats in effect"
        }
        let titles = (grant.chats.chatIds ?? []).map { model.chatsByID[$0]?.title ?? $0 }
        let granted = titles.count
        let list = titles.prefix(3).joined(separator: ", ") + (granted > 3 ? ", +\(granted - 3)" : "")
        return effective < granted ? "\(list) · \(effective) of \(granted) monitored" : list
    }

    @ViewBuilder
    private var webhookLine: some View {
        if let webhook = grant.webhook {
            HStack(spacing: 6) {
                StatusDot(tone: webhook.state == .active ? .ok : webhook.state == .retrying ? .waiting : .failed)
                Text(webhookText(webhook))
                    .lineLimit(2)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .help(webhook.url)
        } else {
            HStack(spacing: 6) {
                StatusDot(tone: .off)
                Text("No webhook (WebSocket only)")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func webhookText(_ webhook: WebhookStatus) -> String {
        let last = webhook.lastDeliveryAt.map { "last delivery \($0.relativeDescription)" } ?? "no delivery yet"
        switch webhook.state {
        case .active:
            return "Webhook ok · \(last)"
        case .retrying:
            return "Webhook retrying (\(webhook.pendingEvents) queued) · \(webhook.lastError ?? "failing") · \(last)"
        case .paused:
            return "Webhook paused: \(webhook.lastError ?? "failed for 24 hours") · \(webhook.pendingEvents) events waiting"
        case .unknown:
            return "Webhook state unknown · \(last)"
        }
    }
}

/// The approval screen: narrow the chats (monitored ones only, or one monitored folder) and
/// the scopes (subset of what was requested), then approve.
struct ApproveView: View {
    @Environment(AppModel.self) private var model
    var request: AccessRequest
    @State private var mode: Mode = .chats
    @State private var selectedChats: Set<String> = []
    @State private var alsoMonitor: Set<String> = []
    @State private var selectedFolder: String?
    @State private var selectedScopes: Set<String> = []
    @State private var busy = false

    enum Mode: String, CaseIterable, Identifiable {
        case chats, folder
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { model.approving = nil } label: { Label("Back", systemImage: "chevron.left") }
                    .buttonStyle(.borderless)
                Spacer()
                Text("Approve \(request.name)")
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Color.clear.frame(width: 50, height: 1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            // Outside the List: a segmented picker in a list row makes AppKit's row sizing and
            // the picker's intrinsic size chase each other (AttributeGraph cycle warnings).
            Picker("Grant", selection: $mode) {
                Text("Chats").tag(Mode.chats)
                Text("Folder").tag(Mode.folder)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            List {
                Section {
                    if mode == .chats { chatRows } else { folderRows }
                    Text("Only monitored chats can be granted: a grant never exceeds what the gateway monitors.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } header: {
                    Text("Chats to grant")
                }
                Section("Scopes to grant") {
                    ForEach(request.scopes, id: \.self) { scope in
                        Toggle(isOn: binding(scope, in: $selectedScopes)) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(scope).font(.body.monospaced())
                                Text(Scope.explanation(scope)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                if let error = model.accessError {
                    ErrorLine(message: error)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            Divider()
            HStack {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                Button("Cancel") { model.approving = nil }
                Button(busy ? "Approving…" : "Approve") { Task { await approve() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || !canApprove)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .task {
            if model.chats.isEmpty { await model.loadChats() }
            preselect()
        }
    }

    // MARK: Rows

    @ViewBuilder
    private var chatRows: some View {
        let monitored = model.chats.filter(\.isMonitored)
        if monitored.isEmpty {
            Text("Nothing is monitored yet. Pick chats in the Chats tab, or tick a requested chat below to monitor it as part of this approval.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        ForEach(monitored) { chat in
            Toggle(isOn: binding(chat.id, in: $selectedChats)) {
                ChatLabel(chat: chat)
            }
            .toggleStyle(.checkbox)
        }
        let unmonitoredRequested = request.requestedChats.chatIds.filter { id in !(model.chatsByID[id]?.isMonitored ?? false) }
        if !unmonitoredRequested.isEmpty {
            Text("Requested but not monitored")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            ForEach(unmonitoredRequested, id: \.self) { id in
                Toggle(isOn: binding(id, in: $alsoMonitor)) {
                    if let chat = model.chatsByID[id] {
                        ChatLabel(chat: chat)
                    } else {
                        Text(request.requestedChatsStatus?.first(where: { $0.chatId == id })?.title ?? id)
                    }
                    Text("Monitor and include")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                .toggleStyle(.checkbox)
            }
        }
    }

    @ViewBuilder
    private var folderRows: some View {
        let monitoredFolders = model.folders.filter(\.isMonitored)
        if monitoredFolders.isEmpty {
            Text("No folder is monitored. Tick a folder in the Chats tab first.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        Picker("Folder", selection: $selectedFolder) {
            Text("Choose a folder").tag(String?.none)
            ForEach(monitoredFolders) { folder in
                Text("\(folder.title) (\(folder.chatIds.count) chats)").tag(String?.some(folder.id))
            }
        }
        Text("The grant follows the folder: chats you add to it on your phone become visible to the application without a new approval.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Logic

    private func preselect() {
        let requested = Set(request.requestedChats.chatIds)
        let monitored = Set(model.chats.filter(\.isMonitored).map(\.id))
        selectedChats = requested.isEmpty ? monitored : requested.intersection(monitored)
        alsoMonitor = requested.subtracting(monitored)
        selectedScopes = Set(request.scopes).subtracting(["messages:send"])
    }

    private var canApprove: Bool {
        guard !selectedScopes.isEmpty else { return false }
        switch mode {
        case .chats: return !selectedChats.isEmpty || !alsoMonitor.isEmpty
        case .folder: return selectedFolder != nil
        }
    }

    private var summary: String {
        let scopes = "\(selectedScopes.count) of \(request.scopes.count) scopes"
        switch mode {
        case .chats:
            let extra = alsoMonitor.isEmpty ? "" : " (+\(alsoMonitor.count) to monitor)"
            return "\(selectedChats.count + alsoMonitor.count) chats\(extra) · \(scopes)"
        case .folder:
            let title = model.folders.first { $0.id == selectedFolder }?.title ?? "no folder"
            return "Folder \(title) · \(scopes)"
        }
    }

    private func approve() async {
        busy = true
        defer { busy = false }
        let selection: GrantChatSelection
        let toMonitor: [String]
        switch mode {
        case .chats:
            selection = .chats(selectedChats.union(alsoMonitor).sorted())
            // Only chats that are still unmonitored need the extra PUT.
            toMonitor = alsoMonitor.filter { !(model.chatsByID[$0]?.isMonitored ?? false) }.sorted()
        case .folder:
            guard let folder = selectedFolder else { return }
            selection = .folder(folder)
            toMonitor = []
        }
        let scopes = request.scopes.filter { selectedScopes.contains($0) }
        _ = await model.approve(request, selection: selection, scopes: scopes, alsoMonitor: toMonitor)
    }

    private func binding(_ id: String, in set: Binding<Set<String>>) -> Binding<Bool> {
        Binding(
            get: { set.wrappedValue.contains(id) },
            set: { on in if on { set.wrappedValue.insert(id) } else { set.wrappedValue.remove(id) } })
    }
}

#Preview("Access") {
    let model = AppModel.preview(.loggedIn)
    model.tab = .access
    return RootView().environment(model)
}

#Preview("Approve") {
    let model = AppModel.preview(.loggedIn)
    model.tab = .access
    model.approving = Fixtures.requests[0]
    return RootView().environment(model)
}
