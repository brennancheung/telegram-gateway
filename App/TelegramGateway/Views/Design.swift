import SwiftUI

// The visual system shared by the menu bar popover and the main window. Every screen is
// built from these pieces, so the hierarchy reads the same everywhere:
//
//   type     screen title 15 semibold · row title 13 medium · body 13 · secondary 11 ·
//            section label 11 semibold (sentence case, never caps, never underlined)
//   grouping related rows sit in one inset rounded card; dividers only between rows inside
//            a card, inset to the text; 16pt between cards
//   action   at most one prominent button per screen; when a screen scrolls, actions live
//            in a fixed bar at the bottom
//   colour   state only: green fine (a small quiet dot), amber waiting or needs the user,
//            red failed

enum PanelSize {
    /// The menu bar popover: fixed width, as tall as its content.
    static let popoverWidth: CGFloat = 300
    /// The main window's default and minimum content size.
    static let window = CGSize(width: 820, height: 560)
    static let windowMinimum = CGSize(width: 700, height: 460)
    /// The review sheet.
    static let sheet = CGSize(width: 460, height: 540)
    /// Space between cards.
    static let gap: CGFloat = 16
    /// The popover's side margin, and the window content's.
    static let margin: CGFloat = 12
    static let windowMargin: CGFloat = 20
}

enum TypeScale {
    /// The Overview's single state line. The only size above the screen title.
    static let hero = Font.system(size: 20, weight: .semibold)
    static let screenTitle = Font.system(size: 15, weight: .semibold)
    static let rowTitle = Font.system(size: 13, weight: .medium)
    static let body = Font.system(size: 13)
    static let secondary = Font.system(size: 11)
    static let sectionLabel = Font.system(size: 11, weight: .semibold)
}

extension Tone {
    var color: Color {
        switch self {
        case .neutral: .secondary
        case .ok: .green
        case .attention: .orange
        case .failed: .red
        }
    }
}

/// A small dot for a state.
struct StatusDot: View {
    var tone: Tone
    var size: CGFloat = 7

    var body: some View {
        Circle()
            .fill(tone == .neutral ? Color.secondary.opacity(0.5) : tone.color)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// An inset rounded group. Neutral cards are a quiet fill; a tone tints the card, which is
/// how exceptions get weight.
struct Card<Content: View>: View {
    var tone: Tone = .neutral
    var padding: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill, in: RoundedRectangle(cornerRadius: 8))
    }

    private var fill: AnyShapeStyle {
        tone == .neutral ? AnyShapeStyle(.quaternary.opacity(0.6)) : AnyShapeStyle(tone.color.opacity(0.14))
    }
}

/// Rows with a divider between each pair, inset to where the text starts.
struct Rows<Content: View>: View {
    var inset: CGFloat = 0
    var rowPadding: CGFloat = 8
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group(subviews: content) { subviews in
                ForEach(subviews) { subview in
                    if subview.id != subviews.first?.id {
                        Divider().padding(.leading, inset)
                    }
                    subview.padding(.vertical, rowPadding)
                }
            }
        }
    }
}

/// A card whose content is divided rows.
struct RowCard<Content: View>: View {
    var tone: Tone = .neutral
    var inset: CGFloat = 0
    @ViewBuilder var content: Content

    var body: some View {
        Card(tone: tone, padding: 0) {
            Rows(inset: inset) { content }
                .padding(.horizontal, 12)
                .padding(.vertical, 2)
        }
    }
}

/// A section: label, then its card(s), then an optional footer stating a consequence.
struct LabeledSection<Content: View>: View {
    var title: String
    var footer: String?
    @ViewBuilder var content: Content

    init(_ title: String, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(TypeScale.sectionLabel)
                .foregroundStyle(.secondary)
                .padding(.leading, 12)
            content
            if let footer {
                Text(footer)
                    .font(TypeScale.secondary)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 12)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The bar fixed at the bottom of a window section or sheet: a quiet summary on the left,
/// the actions on the right.
struct BottomBar<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) { content }
                .padding(.horizontal, PanelSize.windowMargin)
                .padding(.vertical, 10)
        }
        .background(.bar)
    }
}

/// A chat-type (or folder) icon in a 28pt rounded square.
struct IconTile: View {
    var symbol: String

    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color.primary.opacity(0.07))
            .frame(width: 28, height: 28)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .accessibilityHidden(true)
    }
}

/// "Step 1 of 3", quiet, during first-run setup only.
struct StepIndicator: View {
    var step: Int

    var body: some View {
        Text("Step \(step) of 3")
            .font(TypeScale.secondary)
            .foregroundStyle(.secondary)
    }
}

/// A row title with one secondary line under it.
struct TitleAndDetail: View {
    var title: String
    var detail: String?
    var detailTone: Tone = .neutral

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(TypeScale.rowTitle)
                .lineLimit(1)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(TypeScale.secondary)
                    .foregroundStyle(detailTone == .neutral ? AnyShapeStyle(.secondary) : AnyShapeStyle(detailTone.color))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A label and its value on one line ("Address" … "127.0.0.1:41414").
struct ValueRow<Value: View>: View {
    var label: String
    @ViewBuilder var value: Value

    init(_ label: String, @ViewBuilder value: () -> Value) {
        self.label = label
        self.value = value()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(TypeScale.body)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            value
                .font(TypeScale.body)
                .multilineTextAlignment(.trailing)
        }
    }
}

extension ValueRow where Value == Text {
    init(_ label: String, _ text: String) {
        self.init(label) { Text(text) }
    }
}

/// A labelled fact inside a request card: a narrow secondary label, then the value.
struct FactRow<Value: View>: View {
    var label: String
    @ViewBuilder var value: Value

    init(_ label: String, @ViewBuilder value: () -> Value) {
        self.label = label
        self.value = value()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(TypeScale.secondary)
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            value
                .font(TypeScale.body)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The trailing state of an app: a quiet green dot with a time when fine, amber words when
/// it needs the user.
struct TrailingState: View {
    var tone: Tone
    var text: String

    var body: some View {
        HStack(spacing: 5) {
            if tone == .ok { StatusDot(tone: .ok, size: 6) }
            Text(text)
                .font(TypeScale.secondary)
                .foregroundStyle(tone == .attention || tone == .failed ? AnyShapeStyle(tone.color) : AnyShapeStyle(.secondary))
        }
        .fixedSize()
    }
}

/// The popover's one prominent button: accent fill, white label. Drawn here rather than with
/// `.borderedProminent` because the menu bar popover is not always the key window and AppKit
/// greys prominent buttons in an inactive one. The main window is a normal key window and
/// uses the native `.borderedProminent`.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize

    func makeBody(configuration: Configuration) -> some View {
        let large = controlSize == .large
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, large ? 18 : 12)
            .padding(.vertical, large ? 7 : 4)
            .background(Color.accentColor.opacity(configuration.isPressed ? 0.75 : 1), in: RoundedRectangle(cornerRadius: large ? 8 : 6))
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
}

/// A row in the popover's action list: behaves like a menu item (highlight on hover).
struct MenuRow: View {
    var title: String
    var detail: String?
    var action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(TypeScale.body)
                    if let detail {
                        Text(detail).font(TypeScale.secondary).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(hovering && isEnabled ? AnyShapeStyle(Color.primary.opacity(0.08)) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
