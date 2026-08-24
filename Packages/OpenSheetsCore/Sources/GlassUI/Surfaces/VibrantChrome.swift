import SwiftUI

#if canImport(AppKit)
import AppKit
#endif

/// The backdrop a **chrome band** stands on, as opposed to the lens a floating surface *is*.
///
/// # Why this exists next to ``GlassSurface`` rather than inside it
///
/// They answer different questions, and conflating them is what made the assembled app look
/// wrong in two opposite ways within an hour.
///
/// ``GlassSurface`` is Liquid Glass: a *lens*, which refracts *the content of this window* behind
/// it. That is exactly right for a pill floating over the grid — there are cells behind it, and
/// you want to see them bend. It is exactly wrong for a window's edge bands, because there is no
/// window content behind those; there is only the desktop. A lens over nothing shows you nothing,
/// which in practice means it shows you the desktop at full sharpness — a hole, not a surface.
/// That is precisely what the sidebar, the titlebar band and the tab strip each looked like the
/// moment the window stopped painting an opaque rectangle behind everything.
///
/// `NSVisualEffectView` is the other thing: a **material**. Blur, saturation, and a tint layer
/// that keeps most of its own opacity, sampled from *behind the window*. Over a photograph of a
/// mountain it yields a faint cast of the mountain's colour and nothing you could identify. That
/// is the effect Finder, Mail and Xcode have in their sidebars, and it is the one people mean by
/// "it should feel native".
///
/// The rule that falls out, and the reason both are kept:
///
/// - **Edge bands take a material** — sidebar, inspector, the titlebar/toolbar/formula band, the
///   sheet-tab strip. They are the window's boundary with the desktop.
/// - **Floating surfaces take glass** — the stats pill, the sync pill, the palette. They are over
///   the grid, which is opaque, so there is something real for a lens to refract.
/// - **The grid takes neither.** It is the one opaque plane (PLAN.md §3) and nothing goes behind
///   it, because contrast over an arbitrary wallpaper cannot be asserted at all.
///
/// # Legibility is the constraint, not the look
///
/// A material thin enough to read the wallpaper through is a bug even when it is pretty: the
/// labels on these bands are 11pt and they have to clear 4.5:1 against whatever the user's desktop
/// happens to be. The system materials are tuned for exactly that and adapt to the appearance and
/// to reduce-transparency on their own, which is the whole reason to use them rather than a blur
/// with a hand-picked tint over it.
public enum ChromeVibrancy: String, Sendable, Hashable, CaseIterable, Codable {
    /// The leading and trailing columns. The most heavily tinted material AppKit has, because a
    /// sidebar carries the densest small text in the window.
    case sidebar

    /// The titlebar/toolbar/formula band and the sheet-tab strip — the horizontal bands that run
    /// the full width of the window and meet the desktop at the top and bottom edges.
    case band

    #if canImport(AppKit)
    /// The system material this role resolves to.
    ///
    /// Public so a test can drive the *same* material over a backdrop it controls and measure what
    /// a label composites to on it — see `RenderedGridTests.ChromeShot`. A contrast floor asserted
    /// against a material the test picked for itself would prove nothing about this one.
    public var material: NSVisualEffectView.Material {
        switch self {
        case .sidebar: .sidebar
        case .band: .headerView
        }
    }
    #endif
}

public extension View {
    /// Puts a real system material behind an edge-anchored chrome band.
    ///
    /// Use on a band that touches the window's edge. Anything floating over the grid wants
    /// ``SwiftUI/View/glassPill(context:signal:)`` or ``SwiftUI/View/glassCard(context:radius:signal:)``
    /// instead — see ``ChromeVibrancy`` for why the two are not interchangeable.
    ///
    /// Under reduce-transparency there is no material at all, only an opaque ``DS/Surface`` token.
    /// Same discipline as ``GlassSurface``: not a heavier blur, not a darker tint — opaque.
    ///
    /// # `separator`
    ///
    /// The hairline where this band meets what is next to it. Pass the band's **own** edge —
    /// `.trailing` for a leading column, `.leading` for a trailing one.
    ///
    /// It belongs here, and nowhere else, because **a separator is an edge of a surface, not a
    /// surface of its own**. The version of this that shipped was a bare `Rectangle` living as its
    /// own column in the window's `HStack`, filled with `DS.Chrome.separator` — a *semi-transparent*
    /// system colour, which is right when it sits on something and is a window straight through to
    /// the desktop when it does not. It had nothing behind it, so the wallpaper came through as a
    /// bright stripe down the full height of the window.
    ///
    /// Making that colour opaque would have hidden it and left the hole: a free-standing column is
    /// still a region with no material, and a sub-pixel width on a non-integral scale factor puts
    /// the gap straight back. Drawn as an overlay on the band's own edge, the line is composited
    /// over the band's material by construction and there is no region left to leak.
    func vibrantChrome(
        _ role: ChromeVibrancy,
        context: AppearanceContext,
        separator edge: HorizontalEdge? = nil
    ) -> some View {
        modifier(VibrantChrome(role: role, context: context, separator: edge))
    }
}

/// What ``VibrantChrome`` will actually do, as a value.
///
/// The same move ``GlassResolution`` makes and for the same reason: the decision that matters —
/// *is there a material here, and if not, exactly which opaque token* — becomes something a test
/// can print. `AppearanceSnapshotTests` records one of these per band per appearance, so a change
/// to the reduce-transparency path shows up in review as a hex value rather than as
/// "VibrantChrome.swift changed".
///
/// `NSVisualEffectView.Material` is an enum with no useful description, so the real-material branch
/// is *named* rather than captured. That is the same honest limit `GlassResolution` states: the
/// snapshot proves we asked for `.sidebar`, not what the window server did with it.
public struct VibrancyResolution: Sendable, Hashable, CustomStringConvertible {
    public let role: ChromeVibrancy
    public let usesMaterial: Bool
    /// `"sidebar"`, `"headerView"`. `nil` when transparency is reduced.
    public let materialName: String?
    /// The opaque token used when transparency is reduced.
    public let solidFill: RGBA?
    /// The hairline that replaces the material's edge.
    public let borderColor: RGBA?
    public let borderWidth: CGFloat

    public static func resolve(role: ChromeVibrancy, context: AppearanceContext) -> VibrancyResolution {
        guard context.usesRealGlass else {
            return VibrancyResolution(
                role: role,
                usesMaterial: false,
                materialName: nil,
                solidFill: DS.Surface.chromeColor(context),
                borderColor: DS.Surface.borderColor(context),
                borderWidth: DS.Stroke.hairline(context)
            )
        }
        return VibrancyResolution(
            role: role,
            usesMaterial: true,
            materialName: role.rawValue == "sidebar" ? "sidebar" : "headerView",
            solidFill: nil,
            borderColor: nil,
            borderWidth: 0
        )
    }

    public var description: String {
        if usesMaterial {
            return "material NSVisualEffectView.\(materialName ?? "?") behindWindow"
        }
        // Word-for-word the shape ``GlassResolution`` uses for its own fallback. The two paths
        // land on the same token and the same hairline, and a golden that phrased them
        // differently would suggest they had diverged.
        let fill = solidFill?.hexString ?? "—"
        let border = borderColor?.hexString ?? "—"
        return "solid \(fill) border \(border) @ \(String(format: "%.1f", borderWidth))pt"
    }
}

/// The modifier behind ``SwiftUI/View/vibrantChrome(_:context:)``.
public struct VibrantChrome: ViewModifier {
    let role: ChromeVibrancy
    let context: AppearanceContext
    var separator: HorizontalEdge?

    public func body(content: Content) -> some View {
        surfaced(content).overlay(alignment: separator == .leading ? .leading : .trailing) {
            if separator != nil {
                Rectangle()
                    .fill(DS.Chrome.separator(context))
                    .frame(width: DS.Stroke.hairline(context))
            }
        }
    }

    @ViewBuilder
    private func surfaced(_ content: Content) -> some View {
        if VibrancyResolution.resolve(role: role, context: context).usesMaterial {
            #if canImport(AppKit)
            // `.ignoresSafeArea()` on the *backdrop only*, never on the content. A window with a
            // transparent full-size titlebar still reports that strip as safe area, so a plain
            // `.background` stops just below it — which leaves a band of bare window across the
            // top, and bare window means desktop. The content stays inside the safe area so the
            // traffic lights never land on a control.
            content.background(VibrancyBackdrop(role: role).ignoresSafeArea())
            #else
            content.background(DS.Surface.chrome(context))
            #endif
        } else {
            // The one place a border is legal, for the same reason it is legal in `GlassSurface`:
            // there is no material edge left to interfere with, and an opaque band with no edge
            // reads as a gap rather than as a surface.
            content
                .background(DS.Surface.chrome(context))
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(DS.Surface.border(context))
                        .frame(height: DS.Stroke.hairline(context))
                }
        }
    }
}

#if canImport(AppKit)
/// `NSVisualEffectView`, and deliberately nothing else.
///
/// `blendingMode` is `.behindWindow`: these bands sample the desktop, not the window's own
/// content. `.withinWindow` would be the right answer for a band sitting over the grid — but the
/// grid is opaque and flat at rest, so a within-window band over it is indistinguishable from a
/// painted rectangle, which is the state the app was already in and the reason nobody could find
/// any glass in it.
///
/// `state` follows the window: an inactive window's chrome desaturates, the way every other Mac
/// app's does. It is a small thing and its absence is one of the tells of a non-native app.
///
/// # This view is also what makes the titlebar draggable
///
/// The title row draws over the window's titlebar, so the usual AppKit machinery that drags a
/// window by its titlebar no longer gets the click — our content is in front of it. What replaces
/// it is this view: `NSVisualEffectView.mouseDownCanMoveWindow` is `true`, and AppKit drags the
/// window when the hit view says so.
///
/// That is why the backdrop must stay a plain, non-interactive `NSVisualEffectView`. Giving it a
/// gesture, a click target, or an overlay that swallows hits would take the drag away — and a
/// titlebar you cannot drag is a worse regression than the row of wasted space this replaced.
/// SwiftUI hit-tests per point, so the controls in front of it still receive their own clicks:
/// a hit on the file name or the sidebar toggle resolves to the hosting view, and a hit on the
/// empty stretch between them resolves to this one.
private struct VibrancyBackdrop: NSViewRepresentable {
    let role: ChromeVibrancy

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = role.material
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = role.material
        nsView.blendingMode = .behindWindow
        nsView.state = .followsWindowActiveState
    }
}
#endif
