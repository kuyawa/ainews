import SwiftUI

/// User-adjustable text size, driven by Cmd-+ / Cmd-− / Cmd-0.
///
/// macOS has no Dynamic Type, and SwiftUI's textScale takes a fixed enum
/// rather than a multiplier, so sizes are scaled explicitly. Every size in the
/// reading surface goes through here, which is what makes one setting move the
/// whole UI consistently instead of a few labels drifting apart.
struct ScaledFontModifier: ViewModifier {
    @AppStorage(FontScale.defaultsKey) private var scale = FontScale.defaultValue

    let base: CGFloat
    let weight: Font.Weight
    let monospacedDigits: Bool

    func body(content: Content) -> some View {
        let font = Font.system(size: base * scale, weight: weight)
        content.font(monospacedDigits ? font.monospacedDigit() : font)
    }
}

/// Padding that tracks the text size, so spacing around a title stays in
/// proportion when the reader scales the type up.
struct ScaledPaddingModifier: ViewModifier {
    @AppStorage(FontScale.defaultsKey) private var scale = FontScale.defaultValue

    let base: CGFloat
    let edges: Edge.Set

    func body(content: Content) -> some View {
        content.padding(edges, base * scale)
    }
}

extension View {
    func scaledPadding(_ base: CGFloat, _ edges: Edge.Set = .all) -> some View {
        modifier(ScaledPaddingModifier(base: base, edges: edges))
    }

    /// Base sizes mirror the macOS defaults (body 13, caption 11, caption2 10)
    /// so the app looks native before any adjustment is made.
    func scaledFont(
        _ base: CGFloat,
        weight: Font.Weight = .regular,
        monospacedDigits: Bool = false
    ) -> some View {
        modifier(ScaledFontModifier(base: base, weight: weight, monospacedDigits: monospacedDigits))
    }
}

enum FontScale {
    static let defaultsKey = "fontScale"
    static let defaultValue = 1.0
    static let range: ClosedRange<Double> = 0.8...1.8
    static let step = 0.1

    /// Clamps and rounds to one decimal so repeated steps cannot drift into
    /// 1.3000000000000003.
    static func adjusted(_ current: Double, by delta: Double) -> Double {
        let next = ((current + delta) * 10).rounded() / 10
        return min(max(next, range.lowerBound), range.upperBound)
    }

    static func label(for scale: Double) -> String {
        "\(Int((scale * 100).rounded()))%"
    }
}
