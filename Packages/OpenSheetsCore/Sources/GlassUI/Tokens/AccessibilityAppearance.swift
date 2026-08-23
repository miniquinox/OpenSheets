import SwiftUI

#if canImport(AppKit)
import AppKit
#endif

/// The live bridge between System Settings and ``AppearanceContext``.
///
/// SwiftUI already publishes `\.accessibilityReduceTransparency`, so for a pure-SwiftUI app this
/// class would be redundant. It is not redundant here, for one specific reason: **`GridKit` is
/// AppKit.** A4 draws the grid in an `NSView` with Core Graphics, and an `NSView` has no SwiftUI
/// environment to read. Something has to notice that reduce-transparency changed and hand the
/// renderer a new ``GridTheme``, and that something is this.
///
/// The second reason is the one the brief calls out: reading
/// `accessibilityDisplayShouldReduceTransparency` once at launch is a bug that is invisible until
/// somebody with the setting on relaunches your app to make it work. Toggling the switch in
/// System Settings updates a running OpenSheets window, live, because of the observer below.
///
/// Ownership: A8 creates exactly one of these per process and injects
/// ``AccessibilityAppearance/context(for:)`` at the top of each window. It is `@MainActor`
/// because `NSWorkspace` and `NSColor` are, and `@Observable` so SwiftUI re-renders and the
/// grid can be told at the same time.
@Observable
@MainActor
public final class AccessibilityAppearance {
    /// System Settings ▸ Accessibility ▸ Display ▸ Reduce transparency.
    public private(set) var reduceTransparency: Bool

    /// System Settings ▸ Accessibility ▸ Display ▸ Increase contrast.
    public private(set) var increaseContrast: Bool

    /// System Settings ▸ Accessibility ▸ Display ▸ Reduce motion.
    public private(set) var reduceMotion: Bool

    /// System Settings ▸ Accessibility ▸ Display ▸ Differentiate without colour.
    ///
    /// Not in the brief, but it is the same notification and the same one-line read, and the
    /// conflict banner genuinely needs it: amber-versus-accent is a colour-only distinction
    /// unless we add a glyph.
    public private(set) var differentiateWithoutColor: Bool

    /// The user's accent, resolved for the current appearance.
    ///
    /// Kept here rather than read at each call site because it needs its own notification —
    /// `NSColor.systemColorsDidChangeNotification` fires when the user picks a new accent in
    /// System Settings ▸ Appearance, which is *not* an accessibility change and does not fire
    /// the accessibility notification.
    public private(set) var accent: RGBA

    @ObservationIgnored private var accessibilityObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var systemColorsObserver: (any NSObjectProtocol)?

    /// Starts observing immediately. There is no "start" call to forget.
    public init() {
        #if canImport(AppKit)
        let workspace = NSWorkspace.shared
        reduceTransparency = workspace.accessibilityDisplayShouldReduceTransparency
        increaseContrast = workspace.accessibilityDisplayShouldIncreaseContrast
        reduceMotion = workspace.accessibilityDisplayShouldReduceMotion
        differentiateWithoutColor = workspace.accessibilityDisplayShouldDifferentiateWithoutColor
        accent = Self.resolvedAccent(dark: false)

        accessibilityObserver = workspace.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // `queue: .main` guarantees the main thread; `Notification` is deliberately not
            // captured, so nothing non-`Sendable` crosses the boundary.
            MainActor.assumeIsolated { self?.refreshAccessibilityFlags() }
        }

        systemColorsObserver = NotificationCenter.default.addObserver(
            forName: NSColor.systemColorsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAccent() }
        }
        #else
        reduceTransparency = false
        increaseContrast = false
        reduceMotion = false
        differentiateWithoutColor = false
        accent = .defaultAccent
        #endif
    }

    /// `isolated deinit` (SE-0371), because the alternative is worse.
    ///
    /// A `deinit` on a `@MainActor` class is `nonisolated` by default, and a `NotificationCenter`
    /// token is `any NSObjectProtocol`, which is not `Sendable` — so a plain `deinit` cannot even
    /// *read* the stored tokens under Swift 6. The usual workaround is an `@unchecked Sendable`
    /// box, which trades a real compiler guarantee for a comment. This keeps the guarantee.
    isolated deinit {
        #if canImport(AppKit)
        if let accessibilityObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver)
        }
        #endif
        if let systemColorsObserver {
            NotificationCenter.default.removeObserver(systemColorsObserver)
        }
    }

    /// The context to inject, for a given colour scheme.
    ///
    /// The scheme is a parameter rather than a stored property because SwiftUI already knows it
    /// — read `@Environment(\.colorScheme)` at the top of the window and pass it in. Duplicating
    /// it here would mean two sources of truth that disagree during the appearance transition.
    public func context(for colorScheme: ColorScheme) -> AppearanceContext {
        let scheme = GlassColorScheme(colorScheme)
        return AppearanceContext(
            colorScheme: scheme,
            reduceTransparency: reduceTransparency,
            increaseContrast: increaseContrast,
            reduceMotion: reduceMotion,
            accent: Self.resolvedAccent(dark: scheme == .dark)
        )
    }

    /// Forces a re-read. Only tests need this; the observers cover the app.
    public func refresh() {
        refreshAccessibilityFlags()
        refreshAccent()
    }

    private func refreshAccessibilityFlags() {
        #if canImport(AppKit)
        let workspace = NSWorkspace.shared
        reduceTransparency = workspace.accessibilityDisplayShouldReduceTransparency
        increaseContrast = workspace.accessibilityDisplayShouldIncreaseContrast
        reduceMotion = workspace.accessibilityDisplayShouldReduceMotion
        differentiateWithoutColor = workspace.accessibilityDisplayShouldDifferentiateWithoutColor
        #endif
    }

    private func refreshAccent() {
        accent = Self.resolvedAccent(dark: false)
    }

    private static func resolvedAccent(dark: Bool) -> RGBA {
        #if canImport(AppKit)
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        guard let appearance else { return .defaultAccent }
        return RGBA.resolving(.controlAccentColor, in: appearance)
        #else
        return .defaultAccent
        #endif
    }
}
