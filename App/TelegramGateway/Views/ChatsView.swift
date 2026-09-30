import SwiftUI

/// The chat picker. Three sections — what is monitored now, folders, everything else — each
/// a card of rows. Ticks are a draft until Save, because the gateway replaces the whole
/// monitored set at once.
struct ChatsView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""

    /// A row in any section: a folder or a chat.
    enum Entry: Identifiable {
        case folder(Folder)
        case chat(Chat)

        var id: String {
            switch self {
            case .folder(let folder): "folder-\(folder.id)"
            case .chat(let chat): "chat-\(chat.id)"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
                .padding(.horizontal, PanelSize.margin)
                .padding(.bottom, 8)

            if model.chatsLoading, model.chats.isEmpty {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = model.chatsError, model.chats.isEmpty {
                VStack(spacing: 10) {
                    Card(tone: .failed) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Couldn't load your chats")
                                .font(TypeScale.rowTitle)
                            Text(error)
                                .font(TypeScale.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Button("Try again") { Task { await model.loadChats() } }
                        .buttonStyle(.primary)
                }
                .padding(PanelSize.margin)
                .frame(maxHeight: .infinity, alignment: .top)
            } else {
                list
            }
            footer
        }
        .task { await model.loadChats() }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField("", text: $search, prompt: Text("Search chats"))
                .textFieldStyle(.plain)
                .font(TypeScale.body)
            if !search.isEmpty {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: PanelSize.gap) {
                if !model.onboardingDone, search.isEmpty {
                    Card {
                        HStack(alignment: .top, spacing: 8) {
                            VStack(alignment: .leading, spacing: 3) {
                                StepIndicator(step: 3)
                                Text("Pick the chats to monitor. Nothing else leaves the gateway.")
                                    .font(TypeScale.body)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 4)
                            Button { model.onboardingDone = true } label: {
                                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Dismiss")
                        }
                    }
                }
                let monitored = monitoredEntries
                if !monitored.isEmpty {
                    LabeledSection("Monitored") { EntryCard(entries: monitored) }
                }
                let folders = otherFolders
                if !folders.isEmpty {
                    LabeledSection("Folders", footer: "A folder follows what you put in it on your phone.") {
                        EntryCard(entries: folders)
                    }
                }
                let chats = otherChats
                if !chats.isEmpty {
                    LabeledSection("All chats") { EntryCard(entries: chats) }
                }
                if monitored.isEmpty, folders.isEmpty, chats.isEmpty {
                    Text(search.isEmpty ? "This account has no chats." : "No chats match “\(search)”.")
                        .font(TypeScale.body)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 24)
                }
            }
            .padding(.horizontal, PanelSize.margin)
            .padding(.bottom, PanelSize.margin)
        }
    }

    private var footer: some View {
        FooterBar {
            if let error = model.chatsError, !model.chats.isEmpty {
                Text(error)
                    .font(TypeScale.secondary)
                    .foregroundStyle(Tone.failed.color)
                    .lineLimit(2)
            } else if model.isDraftDirty {
                Text(Wording.count(model.draftChangeCount, "change"))
                    .font(TypeScale.body)
            } else {
                Text("\(model.draftEffectiveCount.formatted()) monitored")
                    .font(TypeScale.body)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.isDraftDirty {
                Button("Revert") { model.revertDraft() }
                    .disabled(model.chatsSaving)
                Button(model.chatsSaving ? "Saving…" : "Save") { Task { await model.saveDraft() } }
                    .buttonStyle(.primary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.chatsSaving)
            }
        }
    }

    // MARK: Sections
    // Membership follows what is saved, so rows do not jump between sections while ticking.

    private var query: String { search.trimmingCharacters(in: .whitespaces).lowercased() }

    private func matches(_ chat: Chat) -> Bool {
        query.isEmpty || chat.title.lowercased().contains(query) || (chat.username?.lowercased().contains(query) ?? false)
    }

    private func matches(_ folder: Folder) -> Bool {
        query.isEmpty || folder.title.lowercased().contains(query)
    }

    private var savedFolderIds: Set<String> { Set(model.monitored?.folderIds ?? []) }
    private var savedEffective: Set<String> { Set(model.monitored?.effectiveChatIds ?? []) }

    private var monitoredEntries: [Entry] {
        model.folders.filter { savedFolderIds.contains($0.id) && matches($0) }.map(Entry.folder)
            + model.chats.filter { savedEffective.contains($0.id) && matches($0) }.map(Entry.chat)
    }

    private var otherFolders: [Entry] {
        model.folders.filter { !savedFolderIds.contains($0.id) && matches($0) }.map(Entry.folder)
    }

    private var otherChats: [Entry] {
        model.chats.filter { !savedEffective.contains($0.id) && matches($0) }.map(Entry.chat)
    }
}

/// A card of folder and chat rows, lazily built (an account can have hundreds of chats).
struct EntryCard: View {
    var entries: [ChatsView.Entry]

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                if index > 0 {
                    // Inset to the text: past the checkbox and the icon.
                    Divider().padding(.leading, 62)
                }
                Group {
                    switch entry {
                    case .folder(let folder): FolderRow(folder: folder)
                    case .chat(let chat): ChatRow(chat: chat)
                    }
                }
                .padding(.vertical, 7)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct ChatRow: View {
    @Environment(AppModel.self) private var model
    var chat: Chat

    var body: some View {
        let covering = model.coveringFolder(for: chat.id)
        let locked = covering != nil && !model.draft.chatIds.contains(chat.id)
        HStack(spacing: 10) {
            RowCheckbox(
                isOn: Binding(get: { model.isChatTicked(chat.id) }, set: { model.setChat(chat.id, monitored: $0) }),
                locked: locked)
            IconTile(symbol: chat.type.symbolName)
            TitleAndDetail(title: chat.title, detail: locked ? "via \(covering?.title ?? "a") folder" : Wording.chatSubtitle(chat))
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if !locked { model.setChat(chat.id, monitored: !model.draft.chatIds.contains(chat.id)) }
        }
        .help(locked ? "Monitored because it is in the \(covering?.title ?? "") folder" : "")
    }
}

struct FolderRow: View {
    @Environment(AppModel.self) private var model
    var folder: Folder

    var body: some View {
        HStack(spacing: 10) {
            RowCheckbox(isOn: Binding(get: { model.draft.folderIds.contains(folder.id) }, set: { model.setFolder(folder.id, monitored: $0) }))
            IconTile(symbol: "folder")
            TitleAndDetail(title: folder.title, detail: "Folder · \(Wording.count(folder.chatIds.count, "chat"))")
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { model.setFolder(folder.id, monitored: !model.draft.folderIds.contains(folder.id)) }
    }
}

#Preview("Chats") {
    let model = AppModel.preview(.loggedIn)
    model.tab = .chats
    return RootView().environment(model)
}

#Preview("Chats, first run") {
    let model = AppModel.preview(.loggedInEmpty, onboarded: false)
    model.tab = .chats
    return RootView().environment(model)
}
