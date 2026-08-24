import Foundation
import GlassUI
import SheetModel
import Testing

@testable import DocumentCore

/// A shadow darkens. It never lightens.
///
/// The regression this pins: `frozenDividerShadow` was derived as a tint of `gridlineMajor`, which
/// is a *light* grey in dark mode. Painted on both sides of the frozen-pane divider that reads as a
/// glow, and column A looked lit from its right edge rather than raised above the scrolling pane.
@Suite("Frozen divider shadow")
struct FrozenDividerShadowTests {
    private func context(_ scheme: GlassColorScheme) -> AppearanceContext {
        AppearanceContext(
            colorScheme: scheme,
            reduceTransparency: false,
            increaseContrast: false,
            reduceMotion: false,
            accent: RGBA(red: 0, green: 0.478, blue: 1, alpha: 1)
        )
    }

    @Test("The shadow is darker than the canvas in both themes")
    func theShadowDarkens() {
        for scheme in [GlassColorScheme.light, .dark] {
            let theme = GridThemeBridge.resolved(context(scheme))
            let shadow = theme.frozenDividerShadow
            let canvas = theme.canvasBackground

            // Composite the shadow over the canvas at full strength, which is what the renderer
            // does at the divider's edge, and compare luminance.
            let alpha = Double(shadow.alpha) / 255
            func blend(_ s: UInt8, _ c: UInt8) -> Double {
                (Double(s) * alpha + Double(c) * (1 - alpha)) / 255
            }
            let composited = 0.2126 * blend(shadow.red, canvas.red)
                + 0.7152 * blend(shadow.green, canvas.green)
                + 0.0722 * blend(shadow.blue, canvas.blue)
            let canvasLuminance = 0.2126 * Double(canvas.red) / 255
                + 0.7152 * Double(canvas.green) / 255
                + 0.0722 * Double(canvas.blue) / 255

            #expect(
                composited < canvasLuminance,
                "\(scheme): the frozen divider's shadow lightens the canvas — that is a glow, not a shadow"
            )
        }
    }

    @Test("The shadow is neutral, so it cannot pick up a hue from the gridline")
    func theShadowIsNeutral() {
        for scheme in [GlassColorScheme.light, .dark] {
            let shadow = GridThemeBridge.resolved(context(scheme)).frozenDividerShadow
            #expect(shadow.red == shadow.green && shadow.green == shadow.blue)
            #expect(shadow.red == 0, "a shadow is black at some opacity, not a tinted grey")
        }
    }

    @Test("The divider itself still reads against the canvas")
    func theDividerIsVisible() {
        for scheme in [GlassColorScheme.light, .dark] {
            let theme = GridThemeBridge.resolved(context(scheme))
            #expect(
                theme.frozenDivider != theme.canvasBackground,
                "\(scheme): the frozen divider is invisible"
            )
        }
    }
}
