import SwiftUI

/// The menu bar popover: a glance and three actions. How is it going, does anything need
/// me, open the window. No tabs, no forms, no lists to manage — those are in the main window.
struct PopoverView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let hero = model.hero
        let needs = model.needsYou
        VStack(alignment: .leading, spacing: 12) {
            Card(tone: hero.tone) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(hero.title)
                        .font(TypeScale.hero)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail = hero.detail {
                        Text(detail)
                            .font(TypeScale.secondary)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if !needs.isEmpty {
                LabeledSection("Needs you") {
                    RowCard(tone: .attention) {
                        ForEach(needs) { item in
                            Button {
                                model.open(item)
                            } label: {
                                HStack(spacing: 8) {
                                    TitleAndDetail(title: item.title, detail: item.detail)
                                    Spacer(minLength: 8)
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

            VStack(spacing: 4) {
                Button {
                    model.requestWindow()
                } label: {
                    Text("Open Telegram Gateway…")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.primary)
                .keyboardShortcut(.defaultAction)
                .padding(.bottom, 2)

                MenuRow(title: "Restart gateway", detail: nil) { model.restartGateway() }
                    .disabled(!model.reachable)
                MenuRow(
                    title: "Quit",
                    detail: model.daemon.isForegroundRunning ? "The gateway stops too" : "The gateway keeps running"
                ) {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .padding(PanelSize.margin)
        .frame(width: PanelSize.popoverWidth)
        .onAppear { model.panelOpened() }
        .onDisappear { model.panelClosed() }
    }
}

#Preview("Popover") {
    PopoverView().environment(AppModel.preview(.loggedIn))
}

#Preview("Popover, not signed in") {
    PopoverView().environment(AppModel.preview(.waitingForQR))
}
