import SwiftUI
import AppKit
import MelaCore

extension Color {
    /// The app's accent: tomato. Controls keep the system accent; this marks content.
    static let tomato = Color(red: 0.706, green: 0.255, blue: 0.047)
    /// Tomato for text and small marks, lighter in Dark Mode so it stays readable.
    static let tomatoText = Color(light: 0xB4410C, dark: 0xEC8A5E)
    static let approvedGreen = Color(light: 0x1F6B35, dark: 0x6FCB8A)
    static let reviewAmber = Color(light: 0x7A4A00, dark: 0xF0B85A)
    static let failedRed = Color(light: 0xA31F14, dark: 0xFF8A7A)

    /// The reading pane: a sheet of paper on a quiet gray.
    static let pane = Color(light: 0xF5F5F7, dark: 0x1C1C1E)
    static let paper = Color(light: 0xFBF8F2, dark: 0x27241F)
    static let paperEdge = Color(light: 0xE8E1D3, dark: 0x3B3630)
    static let ink = Color(light: 0x2A2620, dark: 0xEEE7DB)
    static let inkSoft = Color(light: 0x4A4238, dark: 0xC8BFB1)
    static let eyebrow = Color(light: 0x8A6A3D, dark: 0xCDAA78)

    /// A color with its own Light and Dark Mode values, as 0xRRGGBB.
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

/// A checkbox with a mixed state. The checkbox means "import this", separate from row selection.
struct TriStateCheckbox: View {
    let state: BookModel.TriState
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(state == .off ? Color.secondary : Color.tomato)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(state == .on ? "ticked" : state == .mixed ? "partly ticked" : "not ticked")
    }

    private var symbol: String {
        switch state {
        case .off: return "square"
        case .mixed: return "minus.square.fill"
        case .on: return "checkmark.square.fill"
        }
    }
}

struct StatePill: View {
    let state: RowState

    var body: some View {
        if state != .none {
            HStack(spacing: 4) {
                if state == .parsing { ProgressView().controlSize(.mini) }
                Text(state.label)
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(background, in: Capsule())
            .foregroundStyle(foreground)
        }
    }

    private var background: Color {
        switch state {
        case .approved: return Color.approvedGreen.opacity(0.14)
        case .needsReview: return Color.orange.opacity(0.18)
        case .failed: return Color.failedRed.opacity(0.12)
        default: return Color.secondary.opacity(0.12)
        }
    }

    private var foreground: Color {
        switch state {
        case .approved: return .approvedGreen
        case .needsReview: return .reviewAmber
        case .failed: return .failedRed
        default: return .secondary
        }
    }
}

struct Badge: View {
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .background(tint.opacity(0.13), in: Capsule())
            .foregroundStyle(tint == .secondary ? Color.secondary : tint)
            .lineLimit(1)
    }
}

/// A book cover: the real image when there is one, else a typeset placeholder.
struct BookCover: View {
    let title: String
    let author: String
    let image: NSImage?

    var body: some View {
        Color.clear
            .aspectRatio(3 / 4, contentMode: .fit)
            .overlay { face }
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 3, bottomLeadingRadius: 3, bottomTrailingRadius: 8, topTrailingRadius: 8))
            .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
    }

    @ViewBuilder
    private var face: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                let hue = Double(title.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 360 }) / 360
                Rectangle().fill(Color(hue: hue, saturation: 0.45, brightness: 0.45))
                VStack(alignment: .leading) {
                    Text(title).font(.system(.title3, design: .serif).weight(.bold))
                    Spacer()
                    Text(author.uppercased()).font(.caption2).tracking(1)
                }
                .foregroundStyle(.white)
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }
}

/// Wraps chips onto as many lines as needed.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > width, x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
    }
}

/// Editable list of words shown as chips.
struct ChipField: View {
    @Binding var values: [String]
    let placeholder: String
    @State private var draft = ""

    var body: some View {
        FlowLayout {
            ForEach(values, id: \.self) { v in
                HStack(spacing: 2) {
                    Text(v)
                    Button {
                        values.removeAll { $0 == v }
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove \(v)")
                }
                .font(.callout)
                .padding(.leading, 9)
                .padding(.trailing, 6)
                .padding(.vertical, 2)
                .background(Color.tomato.opacity(0.14), in: Capsule())
            }
            TextField(placeholder, text: $draft)
                .textFieldStyle(.plain)
                .frame(minWidth: 90)
                .onSubmit(add)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.secondary.opacity(0.3)))
    }

    private func add() {
        for part in draft.split(separator: ",") {
            let v = part.trimmingCharacters(in: .whitespaces)
            if !v.isEmpty, !values.contains(where: { $0.caseInsensitiveCompare(v) == .orderedSame }) { values.append(v) }
        }
        draft = ""
    }
}

extension View {
    /// Animations that respect Reduce Motion.
    func gentleAnimation<V: Equatable>(value: V) -> some View {
        modifier(GentleAnimation(value: value))
    }
}

private struct GentleAnimation<V: Equatable>: ViewModifier {
    let value: V
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : .spring(duration: 0.3), value: value)
    }
}
