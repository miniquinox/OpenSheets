import SwiftUI

/// Light or dark, as a value we can put in a golden file.
///
/// `SwiftUI.ColorScheme` would do, but it is not `Codable` and it gains cases; the snapshot
/// matrix has to mean the same thing in five years as it does today.
public enum GlassColorScheme: String, Sendable, Hashable, Codable, CaseIterable {
    case light
    case dark

    public init(_ scheme: ColorScheme) {
        self = scheme == .dark ? .dark : .light
    }

    public var colorScheme: ColorScheme { self == .dark ? .dark : .light }
}

/// Everything the look depends on, as one value.
///
/// This is the central move of the whole design system. `DS` does not read ambient state: every
/// colour, stroke width and surface decision is a *function of this struct*. Three things fall
/// out of that, and all three are load-bearing:
///
/// - **The accessibility matrix is testable.** `GlassUITests` builds all six contexts by hand
///   and asserts against them. Nothing has to be toggled in System Settings for a test to run.
/// - **`GridKit` can be told the theme.** A4 draws in AppKit, which has no SwiftUI environment.
///   It gets a ``GridTheme`` built from a context, and a new one whenever the context changes.
/// - **Reduce-transparency is not a special case bolted on later.** It is one field, read by the
///   same code path that reads the colour scheme, so it cannot be forgotten in one component.
///
/// The live value comes from ``AccessibilityAppearance``; ``AppearanceContext/snapshotMatrix``
/// is the fixed set the tests and the gallery use.
public struct AppearanceContext: Sendable, Hashable, Codable {
    /// Light or dark. Explicitly a value, not `@Environment(\.colorScheme)`, so the gallery can
    /// show both at once.
    public var colorScheme: GlassColorScheme

    /// System Settings ▸ Accessibility ▸ Display ▸ Reduce transparency.
    ///
    /// When this is on, **every** glass surface becomes an opaque `DS` token with a hairline
    /// border. Not a heavier blur, not a darker tint — opaque. The setting exists because
    /// translucency makes text hard to read, and half-honouring it is worse than ignoring it.
    public var reduceTransparency: Bool

    /// System Settings ▸ Accessibility ▸ Display ▸ Increase contrast.
    ///
    /// Separators and the selection stroke get heavier, inks move toward the ends of the range,
    /// and — the part that is easy to miss — **no signal may be carried by tint alone**. The
    /// conflict banner keeps its amber, but it also grows a glyph and a word.
    public var increaseContrast: Bool

    /// System Settings ▸ Accessibility ▸ Display ▸ Reduce motion. The pill→panel morph
    /// cross-fades instead, and the agent dot stops pulsing.
    public var reduceMotion: Bool

    /// The user's accent (`NSColor.controlAccentColor`), already resolved.
    ///
    /// Carried in the context rather than read from `Color.accentColor` because ``GridTheme``
    /// has to hand A4 a concrete `CGColor` for the selection stroke. SwiftUI chrome still uses
    /// `Color.accentColor` directly — see ``DS/Chrome/accent`` — so it keeps the system's own
    /// key-window and vibrancy behaviour.
    ///
    /// Pinned to ``RGBA/defaultAccent`` in the snapshot matrix, because the machine running the
    /// tests has an accent colour and we do not want to know what it is.
    public var accent: RGBA

    public init(
        colorScheme: GlassColorScheme,
        reduceTransparency: Bool = false,
        increaseContrast: Bool = false,
        reduceMotion: Bool = false,
        accent: RGBA = .defaultAccent
    ) {
        self.colorScheme = colorScheme
        self.reduceTransparency = reduceTransparency
        self.increaseContrast = increaseContrast
        self.reduceMotion = reduceMotion
        self.accent = accent
    }

    /// True when real Liquid Glass should be used. The single question every surface asks.
    public var usesRealGlass: Bool { !reduceTransparency }

    public var isDark: Bool { colorScheme == .dark }

    /// Picks between an explicitly-authored light value and an explicitly-authored dark value.
    ///
    /// There is no `.darkened()` anywhere in this package. Deriving dark mode from light mode is
    /// how you end up with a grid canvas that is muddy brown and inks that all collapse to the
    /// same grey. Both schemes are drawn by hand; this function is just the switch.
    public func pick(light: RGBA, dark: RGBA) -> RGBA {
        isDark ? dark : light
    }

    // MARK: - Named contexts

    public static let light = AppearanceContext(colorScheme: .light)
    public static let dark = AppearanceContext(colorScheme: .dark)

    /// A short, stable, filename-safe name. This is what the golden files are keyed by.
    public var snapshotName: String {
        var name = colorScheme.rawValue
        if reduceTransparency { name += "-reduceTransparency" }
        if increaseContrast { name += "-increaseContrast" }
        if reduceMotion { name += "-reduceMotion" }
        if name == colorScheme.rawValue { name += "-normal" }
        return name
    }

    /// {light, dark} × {normal, reduceTransparency, increaseContrast} — the six states every
    /// component is snapshotted in, per PLAN.md §10.5.
    ///
    /// Reduce-motion is deliberately *not* a seventh axis: it changes timing, not pixels, and a
    /// still frame cannot show it. It is covered by ``DS/Motion`` unit tests instead.
    public static let snapshotMatrix: [AppearanceContext] = GlassColorScheme.allCases.flatMap {
        scheme in
        [
            AppearanceContext(colorScheme: scheme),
            AppearanceContext(colorScheme: scheme, reduceTransparency: true),
            AppearanceContext(colorScheme: scheme, increaseContrast: true),
        ]
    }
}

// MARK: - Environment

private struct AppearanceContextKey: EnvironmentKey {
    /// Light, plain, default accent. Nothing here reads the system — a default that consults
    /// `NSWorkspace` would make previews depend on the developer's System Settings, and a
    /// preview that looks different on two machines is not a preview.
    ///
    /// The real value is injected once, at the top of the window, by
    /// ``SwiftUI/View/glassAppearance(_:)``.
    static let defaultValue = AppearanceContext.light
}

public extension EnvironmentValues {
    /// The resolved appearance every `GlassUI` component reads.
    var glassAppearance: AppearanceContext {
        get { self[AppearanceContextKey.self] }
        set { self[AppearanceContextKey.self] = newValue }
    }
}

public extension View {
    /// Injects the appearance context, and pins SwiftUI's own colour scheme to match.
    ///
    /// Both halves matter: our tokens follow `context.colorScheme`, and the system's semantic
    /// colours and real glass follow `\.colorScheme`. Setting one without the other gives you a
    /// dark toolbar with light system separators, which looks exactly as broken as it sounds.
    func glassAppearance(_ context: AppearanceContext) -> some View {
        environment(\.glassAppearance, context)
            .environment(\.colorScheme, context.colorScheme.colorScheme)
    }
}

public extension RGBA {
    /// macOS's factory accent (`#007AFF`), used only where a real accent is unavailable: the
    /// snapshot matrix, previews, and the doc examples.
    ///
    /// This value is never used at runtime. If you find yourself reaching for it in a component,
    /// you want `Color.accentColor` or `context.accent` instead.
    static let defaultAccent = RGBA(hex: "#007AFF")
}
