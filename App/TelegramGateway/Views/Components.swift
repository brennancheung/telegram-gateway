import SwiftUI

/// The panel's fixed size (docs/app.md).
enum PanelSize {
    static let width: CGFloat = 360
    static let height: CGFloat = 520
}

/// A coloured dot for a state: green ok, orange waiting, red failed, grey unknown.
struct StatusDot: View {
    enum Tone { case ok, waiting, failed, off }
    var tone: Tone

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .accessibilityLabel(label)
    }

    private var color: Color {
        switch tone {
        case .ok: .green
        case .waiting: .orange
        case .failed: .red
        case .off: .secondary.opacity(0.5)
        }
    }

    private var label: String {
        switch tone {
        case .ok: "ok"
        case .waiting: "waiting"
        case .failed: "failed"
        case .off: "off"
        }
    }
}

/// A scope name as a small capsule, with its meaning as a tooltip.
struct ScopeChip: View {
    var scope: String
    var dimmed = false

    var body: some View {
        Text(scope)
            .font(.caption.monospaced())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
            .foregroundStyle(dimmed ? .secondary : .primary)
            .help(Scope.explanation(scope))
    }
}

/// A wrapping row of chips.
struct ChipRow<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        // Simple wrapping layout: enough for a handful of scopes.
        WrappingHStack(spacing: 4) { content }
    }
}

/// Lays subviews out left to right, wrapping to new lines as needed.
struct WrappingHStack: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width == .infinity ? x : width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// A row in a key/value list: label on the left, value on the right.
struct InfoRow<Value: View>: View {
    var label: String
    @ViewBuilder var value: Value

    init(_ label: String, @ViewBuilder value: () -> Value) {
        self.label = label
        self.value = value()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            value
                .multilineTextAlignment(.trailing)
        }
        .font(.callout)
    }
}

extension InfoRow where Value == Text {
    init(_ label: String, _ text: String) {
        self.init(label) { Text(text) }
    }
}

/// An inline error line with an icon.
struct ErrorLine: View {
    var message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.red)
            .textSelection(.enabled)
    }
}

/// Section title in the panel's style.
struct PanelSectionHeader: View {
    var title: String
    var trailing: String?

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 8)
    }
}

/// A chat's type icon, title and handle, shared by the chat picker and the approval screen.
struct ChatLabel: View {
    var chat: Chat

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: chat.type.symbolName)
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .help(chat.type.label)
            VStack(alignment: .leading, spacing: 1) {
                Text(chat.title)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let username = chat.username {
                        Text("@\(username)")
                    }
                    if let count = chat.memberCount {
                        Text(count.formatted(.number.notation(.compactName)) + " members")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
    }
}

extension Date {
    /// "3m ago", "2h ago", "yesterday" — relative, for last-seen / last-delivery values.
    var relativeDescription: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: self, relativeTo: Date())
    }
}
