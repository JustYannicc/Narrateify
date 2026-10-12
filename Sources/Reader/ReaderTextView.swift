import SwiftUI
import AppKit

/// The section's text with the spoken word highlighted, in a fixed-height
/// viewport that glides to keep the highlighted line on the second row.
///
/// Pure SwiftUI (no NSTextView) so it renders in ImageRenderer snapshots. The
/// highlighted line is located by laying out a hidden copy of the text up to
/// the current word and reading its height.
struct ReaderTextView: View {
    let text: String
    let highlight: NSRange?
    var dimmed = false
    var visibleLines = 4

    static let fontSize: CGFloat = 15
    static let lineSpacing: CGFloat = 4

    @State private var prefixHeight: CGFloat = 0
    @State private var fullHeight: CGFloat = 0
    /// Height of one rendered line (no spacing), measured from SwiftUI itself
    /// so scrolling snaps to whole lines. Seeded with TextKit's estimate.
    @State private var glyphLineHeight: CGFloat =
        NSLayoutManager().defaultLineHeight(for: .systemFont(ofSize: fontSize))

    private var pitch: CGFloat { glyphLineHeight + Self.lineSpacing }

    private var viewportHeight: CGFloat {
        pitch * CGFloat(visibleLines) - Self.lineSpacing
    }

    /// n lines of text measure n·pitch − spacing; invert that.
    private func lines(in height: CGFloat) -> Int {
        height > 0 ? Int(((height + Self.lineSpacing) / pitch).rounded()) : 0
    }

    /// Scroll by whole lines so the word's line sits on row 2 (a line of
    /// context above, the rest for what's coming).
    private var scrollOffset: CGFloat {
        guard highlight != nil else { return 0 }
        let wordLine = lines(in: prefixHeight)               // 1-based
        let maxTop = max(0, lines(in: fullHeight) - visibleLines)
        return CGFloat(min(max(0, wordLine - 2), maxTop)) * pitch
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            styled(Text("Ag")).opacity(0)
                .measure(LineHeightKey.self)
            styled(prefixText).opacity(0)
                .measure(PrefixHeightKey.self)
            styled(Text(attributed))
                .measure(FullHeightKey.self)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .offset(y: -scrollOffset)
        .frame(height: viewportHeight, alignment: .top)
        .clipped()
        .mask(edgeFade)
        .opacity(dimmed ? 0.55 : 1)
        .animation(.easeInOut(duration: 0.3), value: scrollOffset)
        .animation(.easeOut(duration: 0.2), value: dimmed)
        .onPreferenceChange(LineHeightKey.self) { if $0 > 0 { glyphLineHeight = $0 } }
        .onPreferenceChange(PrefixHeightKey.self) { prefixHeight = $0 }
        .onPreferenceChange(FullHeightKey.self) { fullHeight = $0 }
        .accessibilityElement()
        .accessibilityLabel(text)
    }

    private func styled(_ t: Text) -> some View {
        t.font(.system(size: Self.fontSize))
            // A concrete label color, not the hierarchical `.primary`: over a
            // material that one turns vibrant, and vibrancy inside a mask
            // composites to washed-out white in light mode.
            .foregroundStyle(Color(nsColor: .labelColor))
            .lineSpacing(Self.lineSpacing)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var attributed: AttributedString {
        var s = AttributedString(text)      // inherit the foreground (light/dark aware)
        guard let highlight, let r = Range(highlight, in: s) else { return s }
        s[r].backgroundColor = Color.accentColor.opacity(0.38)
        return s
    }

    /// Text up to the end of the highlighted word, extended to the next space
    /// so trailing punctuation wraps the same way as in the full text.
    private var prefixText: Text {
        guard let highlight else { return Text("") }
        let ns = text as NSString
        var end = min(NSMaxRange(highlight), ns.length)
        let spaces = CharacterSet.whitespacesAndNewlines
        while end < ns.length,
              let scalar = UnicodeScalar(ns.character(at: end)),
              !spaces.contains(scalar) {
            end += 1
        }
        return Text(ns.substring(to: end))
    }

    /// Soft fade on whichever edge has more text beyond it.
    private var edgeFade: some View {
        let fade: CGFloat = 5
        let top = scrollOffset > 1
        let bottom = fullHeight - scrollOffset > viewportHeight + 1
        return VStack(spacing: 0) {
            LinearGradient(colors: [top ? .clear : .black, .black], startPoint: .top, endPoint: .bottom)
                .frame(height: fade)
            Color.black
            LinearGradient(colors: [.black, bottom ? .clear : .black], startPoint: .top, endPoint: .bottom)
                .frame(height: fade)
        }
    }
}

private struct LineHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct PrefixHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct FullHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private extension View {
    func measure<K: PreferenceKey>(_ key: K.Type) -> some View where K.Value == CGFloat {
        background(GeometryReader { Color.clear.preference(key: key, value: $0.size.height) })
    }
}
