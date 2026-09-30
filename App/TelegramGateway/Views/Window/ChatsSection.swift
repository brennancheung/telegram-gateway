import SwiftUI

/// One row of the Chats table: a folder or a chat.
struct ChatTableRow: Identifiable, Hashable {
    enum Kind: Hashable { case folder, chat }

    var id: String
    var kind: Kind
    /// The folder id or chat id.
    var rawId: String
    var title: String
    var symbol: String
    var type: String
    /// Sort key for Members: the member count, a folder's chat count, or -1 when unknown.
    var members: Int
    var membersText: String
    var username: String
    /// Sort key for Monitored: 0 when monitored (as saved), 1 otherwise.
    var rank: Int
}

/// The chat picker: a table of every chat and folder with a checkbox for what the gateway
/// monitors. Ticks are a draft until Save, because the gateway replaces the whole monitored
/// set at once.
struct ChatsSection: View {
    @Environment(AppModel.self) private var model
    @State private var sortOrder: [KeyPathComparator<ChatTableRow>] = []

    var body: some View {
        @Bindable var model = model
        if model.screen != .main {
            GatewayUnavailable()
        } else {
            VStack(spacing: 0) {
                if !model.onboardingDone { banner }
                table
                bottomBar
            }
            .task { await model.loadChats() }
            .searchable(text: $model.chatSearch, placement: .toolbar, prompt: "Search chats")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Show", selection: $model.chatScope) {
                        ForEach(AppModel.ChatScope.allCases) { scope in
                            Text(scope.title).tag(scope)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .help("Which chats the table lists")
                }
            }
        }
    }

    // MARK: Pieces

    /// Step 3 of first-run setup, shown once.
    private var banner: some View {
        Card {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    StepIndicator(step: 3)
                    Text("Pick the chats to monitor. Nothing else leaves the gateway.")
                        .font(TypeScale.body)
                }
                Spacer(minLength: 8)
                Button { model.onboardingDone = true } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(.horizontal, PanelSize.windowMargin)
        .padding(.vertical, 12)
    }

    private var table: some View {
        let rows = self.rows
        return Table(rows, sortOrder: $sortOrder) {
            TableColumn("Monitored", value: \.rank) { row in
                checkbox(row)
            }
            .width(70)
            TableColumn("Chat", value: \.title) { row in
                chatCell(row)
            }
            .width(min: 160, ideal: 230)
            TableColumn("Type", value: \.type) { row in
                Text(row.type).foregroundStyle(.secondary)
            }
            .width(min: 56, ideal: 70, max: 100)
            TableColumn("Members", value: \.members) { row in
                Text(row.membersText).foregroundStyle(.secondary).monospacedDigit()
            }
            .width(min: 64, ideal: 78, max: 110)
            TableColumn("Username", value: \.username) { row in
                Text(row.username.isEmpty ? "" : "@\(row.username)").foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 120)
        }
        .overlay {
            if model.chatsLoading, model.chats.isEmpty {
                ProgressView().controlSize(.small)
            } else if let error = model.chatsError, model.chats.isEmpty {
                ContentUnavailableView {
                    Label("Couldn't load your chats", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try again") { Task { await model.loadChats() } }
                }
            } else if rows.isEmpty {
                emptyState
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !model.chatSearch.trimmingCharacters(in: .whitespaces).isEmpty {
            ContentUnavailableView.search(text: model.chatSearch)
        } else {
            switch model.chatScope {
            case .monitored:
                ContentUnavailableView {
                    Label("Nothing is monitored", systemImage: "eye.slash")
                } description: {
                    Text("Tick chats or folders under All.")
                } actions: {
                    Button("Show all") { model.chatScope = .all }
                }
            case .folders:
                ContentUnavailableView("No folders", systemImage: "folder", description: Text("Folders you create in Telegram appear here."))
            case .all:
                ContentUnavailableView("No chats", systemImage: "bubble.left.and.bubble.right", description: Text("This account has no chats."))
            }
        }
    }

    private var bottomBar: some View {
        BottomBar {
            if let error = model.chatsError, !model.chats.isEmpty {
                Text(error)
                    .font(TypeScale.body)
                    .foregroundStyle(Tone.failed.color)
                    .lineLimit(2)
            } else if model.isDraftDirty {
                Text(Wording.count(model.draftChangeCount, "unsaved change"))
                    .font(TypeScale.body)
            } else {
                Text("\(model.draftEffectiveCount.formatted()) monitored")
                    .font(TypeScale.body)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.chatScope == .folders || model.chatScope == .all, !model.folders.isEmpty, !model.isDraftDirty {
                Text("A folder follows what you put in it on your phone.")
                    .font(TypeScale.secondary)
                    .foregroundStyle(.secondary)
            }
            if model.isDraftDirty {
                Button("Revert") { model.revertDraft() }
                    .disabled(model.chatsSaving)
                Button(model.chatsSaving ? "Saving…" : "Save") { Task { await model.saveDraft() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(model.chatsSaving)
            }
        }
    }

    private func checkbox(_ row: ChatTableRow) -> some View {
        Toggle("", isOn: binding(row))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(isLocked(row))
            .help(isLocked(row) ? "Monitored because it is in the \(model.coveringFolder(for: row.rawId)?.title ?? "") folder" : "")
    }

    private func chatCell(_ row: ChatTableRow) -> some View {
        HStack(spacing: 8) {
            Image(systemName: row.symbol)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(row.title)
                    .lineLimit(1)
                if isLocked(row), let folder = model.coveringFolder(for: row.rawId) {
                    Text("via \(folder.title) folder")
                        .font(TypeScale.secondary)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Rows

    /// A chat covered by a ticked folder, and not ticked on its own: checked and locked.
    private func isLocked(_ row: ChatTableRow) -> Bool {
        row.kind == .chat && model.coveringFolder(for: row.rawId) != nil && !model.draft.chatIds.contains(row.rawId)
    }

    private func binding(_ row: ChatTableRow) -> Binding<Bool> {
        switch row.kind {
        case .folder:
            Binding(get: { model.draft.folderIds.contains(row.rawId) }, set: { model.setFolder(row.rawId, monitored: $0) })
        case .chat:
            Binding(get: { model.isChatTicked(row.rawId) }, set: { model.setChat(row.rawId, monitored: $0) })
        }
    }

    /// The scope's rows, filtered by the search. Unsorted, monitored rows come first; their
    /// place follows what is saved, so rows do not jump while ticking.
    private var rows: [ChatTableRow] {
        let savedFolders = Set(model.monitored?.folderIds ?? [])
        let savedEffective = Set(model.monitored?.effectiveChatIds ?? [])
        let query = model.chatSearch.trimmingCharacters(in: .whitespaces).lowercased()
        var result: [ChatTableRow] = []
        for folder in model.folders {
            let monitored = savedFolders.contains(folder.id)
            if model.chatScope == .monitored, !monitored { continue }
            if !query.isEmpty, !folder.title.lowercased().contains(query) { continue }
            result.append(ChatTableRow(
                id: "folder-\(folder.id)", kind: .folder, rawId: folder.id, title: folder.title, symbol: "folder", type: "Folder",
                members: folder.chatIds.count, membersText: Wording.count(folder.chatIds.count, "chat"), username: "", rank: monitored ? 0 : 1))
        }
        if model.chatScope != .folders {
            for chat in model.chats {
                let monitored = savedEffective.contains(chat.id)
                if model.chatScope == .monitored, !monitored { continue }
                if !query.isEmpty, !chat.title.lowercased().contains(query), !(chat.username?.lowercased().contains(query) ?? false) { continue }
                result.append(ChatTableRow(
                    id: "chat-\(chat.id)", kind: .chat, rawId: chat.id, title: chat.title, symbol: chat.type.symbolName, type: Wording.chatKind(chat.type),
                    members: chat.memberCount ?? -1, membersText: chat.memberCount.map { $0.formatted() } ?? "—",
                    username: chat.username ?? "", rank: monitored ? 0 : 1))
            }
        }
        if sortOrder.isEmpty {
            return result.filter { $0.rank == 0 } + result.filter { $0.rank == 1 }
        }
        return result.sorted(using: sortOrder)
    }
}

#Preview("Chats") {
    let model = AppModel.preview(.loggedIn)
    model.section = .chats
    return MainWindowView().environment(model).frame(width: 820, height: 560)
}
