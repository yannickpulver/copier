import SwiftUI

/// The type, shape and color tokens from the design. Almost everything maps to a
/// system color so the app follows light and dark mode on its own; blue is the only accent.
enum Theme {
    // Type
    static let body = Font.system(size: 13)
    static let bodyMedium = Font.system(size: 13, weight: .medium)
    static let bodySemibold = Font.system(size: 13, weight: .semibold)
    static let secondary = Font.system(size: 12)
    static let caption = Font.system(size: 11, weight: .semibold)
    static let title = Font.system(size: 21, weight: .semibold)
    static let sectionTitle = Font.system(size: 14, weight: .semibold)
    static let mono = Font.system(size: 12, design: .monospaced)
    static let big = Font.system(size: 38, weight: .semibold)

    // Shape
    static let controlRadius: CGFloat = 8
    static let listRadius: CGFloat = 10
    static let fieldRadius: CGFloat = 6

    // Color
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let hairline = Color(nsColor: .separatorColor)
    static let fieldBackground = Color(nsColor: .windowBackgroundColor)
    static let success = Color(nsColor: .systemGreen)
    static let warning = Color(nsColor: .systemOrange)
}

/// A grouped list container: surface fill, hairline border, 10 pt corners, no shadow.
struct GroupedBox<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .background(Theme.surface)
        .clipShape(.rect(cornerRadius: Theme.listRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.listRadius)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        )
    }
}

/// The 11 pt uppercase section label the design uses above groups.
struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(Theme.caption)
            .kerning(0.3)
            .foregroundStyle(.secondary)
    }
}

/// The small grey/blue tag chips: `backed up`, `other`, `existing`.
struct TagChip: View {
    let text: String
    var accented: Bool = false

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(accented ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(accented ? AnyShapeStyle(Color.accentColor.opacity(0.14)) : AnyShapeStyle(.quaternary))
            .clipShape(.rect(cornerRadius: 4))
    }
}

/// The screen header: 21 pt title on the left, a secondary detail on the right.
struct ScreenHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack {
            Text(title).font(Theme.title)
            Spacer(minLength: 12)
            trailing
                .font(Theme.secondary)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 22)
        .frame(height: 52)
        .overlay(alignment: .bottom) { Divider() }
    }
}

extension ScreenHeader where Trailing == Text {
    init(_ title: String, detail: String) {
        self.init(title: title) { Text(detail) }
    }
}

/// An inline warning or error banner, used for unreachable sources and missing space.
struct InlineBanner: View {
    enum Kind { case warning, error }

    let kind: Kind
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    private var tint: Color { kind == .warning ? Theme.warning : Color(nsColor: .systemRed) }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: kind == .warning ? "exclamationmark.triangle" : "exclamationmark.octagon")
                .foregroundStyle(tint)
            Text(message)
                .font(Theme.body)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.link)
                    .font(Theme.secondary)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .background(tint.opacity(0.12))
        .clipShape(.rect(cornerRadius: Theme.controlRadius))
    }
}
