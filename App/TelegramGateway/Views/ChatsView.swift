import SwiftUI

/// The chat picker: every chat in the account and every folder, with checkboxes for what
/// the gateway monitors. Changes are local until Save (`PUT /v1/admin/monitored-chats`
/// replaces the whole set, so partial saves make no sense).
struct ChatsView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var selectedChats: Set<String> = []
    @State private var selectedFolders: Set<String> = []
    @State private var loadedFrom: MonitoredChats?
    @State private var saving = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search chats", text: $search)
                    .textFieldStyle(.plain)
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(6)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 12)
            .padding(.bottom, 6)

            if model.chatsLoading, model.chats.isEmpty {
                ProgressView("Loading chats…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = model.chatsError, model.chats.isEmpty {
                VStack(spacing: 8) {
                    ErrorLine(message: error)
                    Button("Retry") { Task { await load() } }
                }
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }

            Divider()
            footer
        }
        .task { await load() }
    }

    private var list: some View {
        List {
            if !filteredFolders.isEmpty {
                Section("Folders") {
                    ForEach(filteredFolders) { folder in
                        Toggle(isOn: binding(for: folder.id, in: $selectedFolders)) {
                            HStack(spacing: 8) {
                                Image(systemName: "folder")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 16)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(folder.title)
                                    Text("\(folder.chatIds.count) chats · follows the folder as you edit it on your phone")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }
            Section("Chats") {
                if filteredChats.isEmpty {
                    Text(search.isEmpty ? "No chats in this account." : "No chats match \"\(search)\".")
                        .foregroundStyle(.secondary)
                }
                ForEach(filteredChats) { chat in
                    Toggle(isOn: binding(for: chat.id, in: $selectedChats)) {
                        ChatLabel(chat: chat)
                    }
                    .toggleStyle(.checkbox)
                    .disabled(coveredByFolder(chat.id) && !selectedChats.contains(chat.id))
                    .help(coveredByFolder(chat.id) ? "Monitored through a folder" : "")
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }

    private var footer: some View {
        HStack {
            Text("\(effectiveCount) monitored")
                .font(.callout)
                .foregroundStyle(.secondary)
            if let error = model.chatsError, !model.chats.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .help(error)
            }
            Spacer()
            if isDirty {
                Button("Revert") { resetSelection() }
                    .disabled(saving)
                Button(saving ? "Saving…" : "Save") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving)
            } else {
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Reload from the gateway")
                    .disabled(model.chatsLoading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: Selection

    private var filteredChats: [Chat] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return model.chats }
        return model.chats.filter {
            $0.title.lowercased().contains(query) || ($0.username?.lowercased().contains(query) ?? false) || $0.id.contains(query)
        }
    }

    private var filteredFolders: [Folder] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return model.folders }
        return model.folders.filter { $0.title.lowercased().contains(query) }
    }

    private func coveredByFolder(_ chatId: String) -> Bool {
        model.folders.contains { selectedFolders.contains($0.id) && $0.chatIds.contains(chatId) }
    }

    /// What the effective set would be after saving the current selection.
    private var effectiveCount: Int {
        var ids = selectedChats
        for folder in model.folders where selectedFolders.contains(folder.id) {
            ids.formUnion(folder.chatIds)
        }
        return ids.count
    }

    private var isDirty: Bool {
        guard let loadedFrom else { return false }
        return selectedChats != Set(loadedFrom.chatIds) || selectedFolders != Set(loadedFrom.folderIds)
    }

    private func binding(for id: String, in set: Binding<Set<String>>) -> Binding<Bool> {
        Binding(
            get: { set.wrappedValue.contains(id) },
            set: { on in
                if on { set.wrappedValue.insert(id) } else { set.wrappedValue.remove(id) }
            })
    }

    private func load() async {
        await model.loadChats()
        if !isDirty || loadedFrom == nil { resetSelection() }
    }

    private func resetSelection() {
        loadedFrom = model.monitored
        selectedChats = Set(model.monitored?.chatIds ?? [])
        selectedFolders = Set(model.monitored?.folderIds ?? [])
    }

    private func save() async {
        saving = true
        defer { saving = false }
        if await model.saveMonitored(chatIds: selectedChats.sorted(), folderIds: selectedFolders.sorted()) {
            resetSelection()
        }
    }
}

#Preview("Chats") {
    let model = AppModel.preview(.loggedIn)
    model.tab = .chats
    return RootView().environment(model)
}

#Preview("Chats, nothing monitored") {
    let model = AppModel.preview(.loggedInEmpty)
    model.tab = .chats
    return RootView().environment(model)
}
