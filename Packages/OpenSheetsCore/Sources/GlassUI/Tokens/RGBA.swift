import CoreGraphics
import SwiftUI

#if canImport(AppKit)
import AppKit
#endif

/// A colour that has already been resolved — four numbers in sRGB, nothing dynamic left in it.
///
/// `Color` and `NSColor` are *recipes*: they resolve differently depending on which appearance
/// happens to be current when you draw. That is exactly what you want for chrome, and exactly
/// what you cannot have for the grid, for two reasons.
///
/// 1. `GridKit` draws tens of thousands of gridline segments per frame with Core Graphics.
///    Pushing a dynamic `NSColor` through `usingColorSpace(.sRGB)` inside that loop is a real
///    cost, and a `CGColor` handed across the `NSViewRepresentable` boundary must already be
///    concrete anyway.
/// 2. A token you cannot print is a token you cannot test. Every contrast assertion in
///    `GlassUITests` is arithmetic over these four `Double`s. If the palette drifts, a number
///    moves and a test fails — which is the only kind of design review that runs on every commit.
///
/// So `RGBA` is the currency of ``GridTheme`` and of every `DS` colour that has to be *opaque*.
/// Chrome deliberately does **not** use it — see ``DS/Chrome`` — because chrome should keep
/// drifting with the OS.
///
/// Components are stored unclamped so that `opacity(_:)` and `composited(over:)` compose without
/// rounding at every step; ``clamped`` is applied at the boundary where a real colour is made.
public struct RGBA: Sendable, Hashable, Codable, CustomStringConvertible {
    /// Red, 0…1 in sRGB.
    public var red: Double
    /// Green, 0…1 in sRGB.
    public var green: Double
    /// Blue, 0…1 in sRGB.
    public var blue: Double
    /// Alpha, 0…1. `1` for every token that lands on the grid plane — see ``GridTheme``.
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// Neutral grey, for the handful of tokens that genuinely are grey and read better as one number.
    public init(white: Double, alpha: Double = 1) {
        self.init(red: white, green: white, blue: white, alpha: alpha)
    }

    /// `"#1C1C1E"` or `"#1C1C1E80"`. Traps on a malformed literal on purpose: these are source
    /// constants written by a designer, not input, and a silently-black token is worse than a crash
    /// during development.
    public init(hex: StaticString) {
        let text = hex.withUTF8Buffer { buffer in
            String(decoding: buffer, as: UTF8.self)
        }
        guard let parsed = RGBA(parsingHex: text) else {
            preconditionFailure("Malformed colour literal '\(text)'. Expected #RRGGBB or #RRGGBBAA.")
        }
        self = parsed
    }

    /// Non-trapping hex parse, for tests and for anything that reads a colour from a file.
    public init?(parsingHex text: some StringProtocol) {
        var digits = Substring(text)
        if digits.hasPrefix("#") { digits = digits.dropFirst() }
        guard digits.count == 6 || digits.count == 8,
              let value = UInt32(digits, radix: 16) else { return nil }
        let hasAlpha = digits.count == 8
        let shift = hasAlpha ? 8 : 0
        self.init(
            red: Double((value >> (16 + shift)) & 0xFF) / 255,
            green: Double((value >> (8 + shift)) & 0xFF) / 255,
            blue: Double((value >> shift) & 0xFF) / 255,
            alpha: hasAlpha ? Double(value & 0xFF) / 255 : 1
        )
    }

    // MARK: - Derivation

    /// The same hue at a different alpha. Used for fills and washes; never for text.
    public func opacity(_ alpha: Double) -> RGBA {
        RGBA(red: red, green: green, blue: blue, alpha: self.alpha * alpha)
    }

    /// This colour flattened onto an opaque backdrop.
    ///
    /// The grid plane has no transparency to composite against at draw time, so a "6% accent
    /// selection fill" has to be resolved into an actual opaque pixel value before it reaches
    /// Core Graphics. This is that resolution, and it is also what makes the contrast tests
    /// meaningful: they measure the pixel the user sees, not the token we wrote down.
    public func composited(over backdrop: RGBA) -> RGBA {
        guard alpha < 1 else { return self }
        let a = alpha
        let b = backdrop.alpha * (1 - a)
        let outAlpha = a + b
        guard outAlpha > 0 else { return RGBA(white: 0, alpha: 0) }
        return RGBA(
            red: (red * a + backdrop.red * b) / outAlpha,
            green: (green * a + backdrop.green * b) / outAlpha,
            blue: (blue * a + backdrop.blue * b) / outAlpha,
            alpha: outAlpha
        )
    }

    /// A straight linear mix in sRGB. Deliberately *not* perceptual: it is only used to nudge a
    /// token a few percent toward black or white for the increase-contrast variants, where the
    /// difference between sRGB and OKLab is smaller than the rounding to 8 bits.
    public func mixed(with other: RGBA, amount: Double) -> RGBA {
        let t = min(max(amount, 0), 1)
        return RGBA(
            red: red + (other.red - red) * t,
            green: green + (other.green - green) * t,
            blue: blue + (other.blue - blue) * t,
            alpha: alpha + (other.alpha - alpha) * t
        )
    }

    /// Every component pulled back into 0…1.
    public var clamped: RGBA {
        RGBA(
            red: min(max(red, 0), 1),
            green: min(max(green, 0), 1),
            blue: min(max(blue, 0), 1),
            alpha: min(max(alpha, 0), 1)
        )
    }

    // MARK: - Contrast

    /// WCAG 2.1 relative luminance. Alpha is ignored — composite first, then measure.
    public var relativeLuminance: Double {
        func channel(_ value: Double) -> Double {
            let c = min(max(value, 0), 1)
            return c <= 0.040_45 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    /// WCAG 2.1 contrast ratio, 1…21.
    ///
    /// The receiver is composited over `backdrop` first, so calling this with a translucent ink
    /// gives the ratio you would actually measure off the screen rather than the one the token
    /// implies. `backdrop` is expected to be opaque — on the grid plane it always is, which is
    /// the whole reason the grid plane is opaque. Body text must clear 4.5; a stroke or a large
    /// bold label must clear 3.
    public func contrastRatio(against backdrop: RGBA) -> Double {
        let front = composited(over: backdrop).relativeLuminance
        let back = backdrop.relativeLuminance
        let lighter = max(front, back)
        let darker = min(front, back)
        return (lighter + 0.05) / (darker + 0.05)
    }

    // MARK: - Bridges

    /// `#RRGGBB`, or `#RRGGBBAA` when translucent. This is what the snapshot goldens record.
    public var hexString: String {
        let c = clamped
        func byte(_ value: Double) -> Int { Int((value * 255).rounded()) }
        let base = String(format: "#%02X%02X%02X", byte(c.red), byte(c.green), byte(c.blue))
        return c.alpha >= 1 ? base : base + String(format: "%02X", byte(c.alpha))
    }

    public var description: String { hexString }

    /// SwiftUI. Always built in `.sRGB`, never `.sRGBLinear` — the numbers above are gamma-encoded.
    public var color: Color {
        let c = clamped
        return Color(.sRGB, red: c.red, green: c.green, blue: c.blue, opacity: c.alpha)
    }

    /// Core Graphics, for `GridKit`'s draw loop.
    public var cgColor: CGColor {
        let c = clamped
        return CGColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: c.alpha)
    }

    #if canImport(AppKit)
    /// AppKit, for the places `GridKit` needs an `NSColor` (text attributes, focus rings).
    public var nsColor: NSColor {
        let c = clamped
        return NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: c.alpha)
    }

    /// Reads a live system colour into a fixed value.
    ///
    /// Only two things go through here: the user's accent (`controlAccentColor`, which we are
    /// forbidden to hardcode) and, in tooling, the system colours we quote in doc comments.
    /// Everything else in the palette is written down explicitly, because a palette that changes
    /// under you is a palette nobody can review.
    public static func resolving(_ nsColor: NSColor, in appearance: NSAppearance) -> RGBA {
        var result = RGBA(hex: "#000000")
        appearance.performAsCurrentDrawingAppearance {
            guard let srgb = nsColor.usingColorSpace(.sRGB) else { return }
            result = RGBA(
                red: srgb.redComponent,
                green: srgb.greenComponent,
                blue: srgb.blueComponent,
                alpha: srgb.alphaComponent
            )
        }
        return result
    }
    #endif
}
