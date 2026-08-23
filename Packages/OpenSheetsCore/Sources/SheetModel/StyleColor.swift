import Foundation

/// An 8-bit-per-channel colour, stored the way xlsx stores it.
///
/// `SheetModel` has no dependencies, so this is not a `Color` or an `NSColor` — those live in
/// `GlassUI` and `GridKit`, which convert at the boundary. Alpha is honoured on read but Excel
/// itself ignores it almost everywhere; do not build anything that depends on translucent cells.
public struct RGBAColor: Sendable, Hashable, Codable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8
    /// Read from the file and written back, but Excel ignores it almost everywhere. Do not
    /// build anything that depends on a translucent cell.
    public var alpha: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8 = 255) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// Parses xlsx's `ARGB` hex — `"FFFF0000"` is opaque red. Also accepts six digits (`RRGGBB`),
    /// which some producers emit, treating them as fully opaque.
    public init?(argbHex text: some StringProtocol) {
        var digits: [UInt8] = []
        digits.reserveCapacity(8)
        for byte in text.utf8 {
            let nibble: UInt8
            switch byte {
            case UInt8(ascii: "0") ... UInt8(ascii: "9"): nibble = byte - UInt8(ascii: "0")
            case UInt8(ascii: "a") ... UInt8(ascii: "f"): nibble = byte - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A") ... UInt8(ascii: "F"): nibble = byte - UInt8(ascii: "A") + 10
            case UInt8(ascii: "#"): continue
            default: return nil
            }
            if digits.count == 8 { return nil }
            digits.append(nibble)
        }
        switch digits.count {
        case 8:
            alpha = digits[0] << 4 | digits[1]
            red = digits[2] << 4 | digits[3]
            green = digits[4] << 4 | digits[5]
            blue = digits[6] << 4 | digits[7]
        case 6:
            alpha = 255
            red = digits[0] << 4 | digits[1]
            green = digits[2] << 4 | digits[3]
            blue = digits[4] << 4 | digits[5]
        default:
            return nil
        }
    }

    /// The eight-digit `AARRGGBB` form xlsx writes.
    public var argbHex: String {
        String(format: "%02X%02X%02X%02X", alpha, red, green, blue)
    }

    /// Applies OOXML's `tint` to this colour: negative darkens toward black, positive lightens
    /// toward white, `0` leaves it alone.
    ///
    /// The specification defines tint in HSL luminance, not in RGB. Doing it in RGB — which is
    /// tempting and simpler — gives visibly different colours from Excel for saturated theme
    /// accents, so this converts properly and back.
    public func tinted(_ tint: Double) -> RGBAColor {
        guard tint != 0 else { return self }
        var (hue, saturation, luminance) = hsl
        luminance = tint < 0
            ? luminance * (1 + tint)
            : luminance * (1 - tint) + tint
        let (r, g, b) = RGBAColor.rgb(hue: hue, saturation: saturation, luminance: min(max(luminance, 0), 1))
        return RGBAColor(red: r, green: g, blue: b, alpha: alpha)
    }

    private var hsl: (hue: Double, saturation: Double, luminance: Double) {
        let r = Double(red) / 255, g = Double(green) / 255, b = Double(blue) / 255
        let maximum = max(r, g, b), minimum = min(r, g, b)
        let luminance = (maximum + minimum) / 2
        guard maximum != minimum else { return (0, 0, luminance) }
        let delta = maximum - minimum
        let saturation = luminance > 0.5 ? delta / (2 - maximum - minimum) : delta / (maximum + minimum)
        let hue: Double = switch maximum {
        case r: ((g - b) / delta).truncatingRemainder(dividingBy: 6)
        case g: (b - r) / delta + 2
        default: (r - g) / delta + 4
        }
        return (hue < 0 ? hue + 6 : hue, saturation, luminance)
    }

    private static func rgb(hue: Double, saturation: Double, luminance: Double) -> (UInt8, UInt8, UInt8) {
        guard saturation > 0 else {
            let value = UInt8((luminance * 255).rounded())
            return (value, value, value)
        }
        let chroma = (1 - abs(2 * luminance - 1)) * saturation
        let secondary = chroma * (1 - abs(hue.truncatingRemainder(dividingBy: 2) - 1))
        let match = luminance - chroma / 2
        let (r, g, b): (Double, Double, Double) = switch Int(hue) {
        case 0: (chroma, secondary, 0)
        case 1: (secondary, chroma, 0)
        case 2: (0, chroma, secondary)
        case 3: (0, secondary, chroma)
        case 4: (secondary, 0, chroma)
        default: (chroma, 0, secondary)
        }
        return (
            UInt8(min(max((r + match) * 255, 0), 255).rounded()),
            UInt8(min(max((g + match) * 255, 0), 255).rounded()),
            UInt8(min(max((b + match) * 255, 0), 255).rounded())
        )
    }

    /// This colour drawn on top of `background`, which is what the eye actually sees.
    ///
    /// The grid's ink is not opaque — `#FFFFFF` at 91% over `#1C1C1E` — so any judgement about
    /// how readable it is has to be made about the composite, not about the channel values.
    public func composited(over background: RGBAColor) -> RGBAColor {
        guard alpha < 255 else { return self }
        let a = Double(alpha) / 255
        func mix(_ top: UInt8, _ bottom: UInt8) -> UInt8 {
            UInt8((Double(top) * a + Double(bottom) * (1 - a)).rounded())
        }
        return RGBAColor(
            red: mix(red, background.red),
            green: mix(green, background.green),
            blue: mix(blue, background.blue)
        )
    }

    /// WCAG 2.1 relative luminance, `0` for black and `1` for white.
    ///
    /// Alpha is ignored: composite first with ``composited(over:)`` if it matters, because a
    /// translucent colour has no luminance of its own.
    public var relativeLuminance: Double {
        func channel(_ value: UInt8) -> Double {
            let normalised = Double(value) / 255
            return normalised <= 0.040_45
                ? normalised / 12.92
                : pow((normalised + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    /// The WCAG contrast ratio between two colours, from `1` (identical) to `21`
    /// (black on white).
    ///
    /// PLAN.md §3.5 requires 4.5:1 for text. This is the number that checks it, and it is here
    /// rather than in a test helper so the requirement is expressible in the code that has to
    /// meet it.
    public func contrastRatio(against other: RGBAColor) -> Double {
        let a = relativeLuminance
        let b = other.relativeLuminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// Whether this colour reads as a dark surface.
    public var isDark: Bool { relativeLuminance < 0.5 }

    /// Opaque black. Note this is a *literal* colour — the default text colour is
    /// ``StyleColor/automatic``, which resolves against the grid instead.
    public static let black = RGBAColor(red: 0, green: 0, blue: 0)
    /// Opaque white.
    public static let white = RGBAColor(red: 255, green: 255, blue: 255)
    /// Opaque red, as used by `[Red]` in a number format.
    public static let red = RGBAColor(red: 255, green: 0, blue: 0)
}

extension RGBAColor: CustomStringConvertible {
    public var description: String { "#\(argbHex)" }
}

/// How a colour is *specified* in xlsx, which is not always as RGB.
///
/// Excel has four ways to say what colour something is, and they are not interchangeable: a
/// theme colour follows the document theme when the theme changes, and an indexed colour comes
/// from a legacy 56-entry palette. Flattening everything to RGB on read would render correctly
/// today and silently break the file's relationship to its theme on write.
///
/// Resolve to actual pixels at the display boundary with ``resolved(in:)``.
public enum StyleColor: Sendable, Hashable, Codable {
    /// "Whatever the system says" — the default text colour, the automatic border colour.
    /// Resolves against the palette's foreground, which is how it can be black on a light
    /// grid and white on a dark one.
    case automatic
    /// A literal colour.
    case rgb(RGBAColor)
    /// An index into the legacy 56-colour palette.
    case indexed(Int)
    /// A slot in the document theme, optionally lightened or darkened.
    case theme(index: Int, tint: Double)

    /// This colour as actual channel values.
    public func resolved(in palette: ColorPalette = .office) -> RGBAColor {
        switch self {
        case .automatic:
            palette.automatic
        case let .rgb(color):
            color
        case let .indexed(index):
            palette.indexed(index)
        case let .theme(index, tint):
            palette.theme(index).tinted(tint)
        }
    }
}

/// The lookup tables that turn a ``StyleColor`` into pixels.
///
/// The default is Office's standard theme, which is what a workbook uses unless it ships its
/// own `xl/theme/theme1.xml`. The reader can build a custom palette from that part; everything
/// else takes a palette as a parameter rather than assuming.
public struct ColorPalette: Sendable, Hashable {
    /// The 56-entry legacy palette. Indices 64 and 65 are special (system foreground and
    /// background) and are answered from ``automatic`` and ``background``.
    public var indexedColors: [RGBAColor]

    /// The twelve theme slots, in `clrScheme` order: dark1, light1, dark2, light2, accent1…6,
    /// hyperlink, followedHyperlink.
    ///
    /// **Note the order.** OOXML's `theme` attribute indexes a *reordered* list where 0 and 1
    /// are swapped relative to the XML — `theme="0"` is light1, not dark1. ``theme(_:)`` does
    /// that swap so callers do not have to remember it.
    public var themeColors: [RGBAColor]

    /// What ``StyleColor/automatic`` resolves to — the grid's foreground.
    public var automatic: RGBAColor

    /// The grid's background, for indexed colour 65.
    public var background: RGBAColor

    /// Whether theme slots 0–3 follow ``automatic`` and ``background`` instead of the literal
    /// colours in ``themeColors``.
    ///
    /// # Why this is on by default
    ///
    /// The first four theme slots are **semantic**, not literal: OOXML calls them `dk1`/`lt1`
    /// (the major text/background pair) and `dk2`/`lt2` (the minor one). `<color theme="1"/>`
    /// does not mean "black" — it means *"the text colour"*, and Office resolves it against
    /// whatever the application is currently showing. Excel in dark mode keeps theme-1 text
    /// readable for exactly this reason.
    ///
    /// This matters far more than it sounds. `<color theme="1"/>` is what **every** producer
    /// writes for ordinary text — openpyxl, xlsxwriter, pandas and Excel itself — so resolving
    /// it to literal black makes the dark grid unusable for essentially every real workbook,
    /// not for one unlucky file.
    ///
    /// Turn it off to see what the theme part literally says, which is what a colour picker
    /// showing theme swatches wants. It changes nothing about writing: this is a decision made
    /// at resolution time, and the file still says `theme="1"` afterwards.
    public var resolvesSemanticThemeSlots: Bool

    public init(
        indexedColors: [RGBAColor],
        themeColors: [RGBAColor],
        automatic: RGBAColor = .black,
        background: RGBAColor = .white,
        resolvesSemanticThemeSlots: Bool = true
    ) {
        self.indexedColors = indexedColors
        self.themeColors = themeColors
        self.automatic = automatic
        self.background = background
        self.resolvesSemanticThemeSlots = resolvesSemanticThemeSlots
    }

    /// This palette's theme and legacy colours, resolved against a particular appearance.
    ///
    /// `ink` and `canvas` are the grid's own text and background. Everything the file chose for
    /// itself — its accents, its hyperlink colour, its minor pair's hues — is kept; only the
    /// *roles* of the semantic slots follow the appearance.
    public func forAppearance(ink: RGBAColor, canvas: RGBAColor) -> ColorPalette {
        var result = self
        result.automatic = ink
        result.background = canvas
        result.resolvesSemanticThemeSlots = true
        return result
    }

    /// The colour at a legacy palette index, falling back to ``automatic``.
    public func indexed(_ index: Int) -> RGBAColor {
        switch index {
        case 64: automatic
        case 65: background
        case indexedColors.indices: indexedColors[index]
        default: automatic
        }
    }

    /// The colour in a theme slot, translating OOXML's swapped indexing and resolving the
    /// semantic slots against the appearance.
    public func theme(_ index: Int) -> RGBAColor {
        // theme="0" means light1 and theme="1" means dark1 — the XML lists them the other way.
        let slot = switch index {
        case 0: 1
        case 1: 0
        case 2: 3
        case 3: 2
        default: index
        }
        if resolvesSemanticThemeSlots, let semantic = semanticThemeColor(slot) { return semantic }
        return themeColors.indices.contains(slot) ? themeColors[slot] : automatic
    }

    /// The appearance-relative reading of `dk1`, `lt1`, `dk2` and `lt2`, or `nil` for the
    /// accent, hyperlink and followed-hyperlink slots — which are real brand colours and must
    /// never be swapped.
    ///
    /// The major pair becomes the grid's own ink and canvas, which are contrast-tuned. The
    /// minor pair keeps the file's own two hues and only **exchanges their roles**, so a
    /// document's secondary shade is still recognisably its own on either appearance.
    private func semanticThemeColor(_ slot: Int) -> RGBAColor? {
        let onDark = background.relativeLuminance < automatic.relativeLuminance
        switch slot {
        case 0: return automatic                              // dk1 — the major text colour
        case 1: return background                             // lt1 — the major background
        case 2: return literalTheme(onDark ? 3 : 2)           // dk2 — the minor text colour
        case 3: return literalTheme(onDark ? 2 : 3)           // lt2 — the minor background
        default: return nil
        }
    }

    /// A theme slot exactly as the file declares it, with no appearance applied.
    public func literalTheme(_ slot: Int) -> RGBAColor {
        themeColors.indices.contains(slot) ? themeColors[slot] : automatic
    }

    /// Office's standard theme and the legacy palette every producer starts from.
    public static let office = ColorPalette(
        indexedColors: legacyIndexedColors,
        themeColors: [
            RGBAColor(red: 0x00, green: 0x00, blue: 0x00), // dark1
            RGBAColor(red: 0xFF, green: 0xFF, blue: 0xFF), // light1
            RGBAColor(red: 0x44, green: 0x54, blue: 0x6A), // dark2
            RGBAColor(red: 0xE7, green: 0xE6, blue: 0xE6), // light2
            RGBAColor(red: 0x44, green: 0x72, blue: 0xC4), // accent1
            RGBAColor(red: 0xED, green: 0x7D, blue: 0x31), // accent2
            RGBAColor(red: 0xA5, green: 0xA5, blue: 0xA5), // accent3
            RGBAColor(red: 0xFF, green: 0xC0, blue: 0x00), // accent4
            RGBAColor(red: 0x5B, green: 0x9B, blue: 0xD5), // accent5
            RGBAColor(red: 0x70, green: 0xAD, blue: 0x47), // accent6
            RGBAColor(red: 0x05, green: 0x63, blue: 0xC1), // hyperlink
            RGBAColor(red: 0x95, green: 0x4F, blue: 0x72), // followed hyperlink
        ]
    )

    /// The 56-colour palette Excel has carried since 1997. Files still reference it by index,
    /// so it has to be here verbatim rather than approximated.
    private static let legacyIndexedColors: [RGBAColor] = packedLegacyColors.map { packed in
        RGBAColor(
            red: UInt8((packed >> 16) & 0xFF),
            green: UInt8((packed >> 8) & 0xFF),
            blue: UInt8(packed & 0xFF)
        )
    }

    private static let packedLegacyColors: [Int] = [
        0x000000, 0xFFFFFF, 0xFF0000, 0x00FF00, 0x0000FF, 0xFFFF00, 0xFF00FF, 0x00FFFF,
        0x000000, 0xFFFFFF, 0xFF0000, 0x00FF00, 0x0000FF, 0xFFFF00, 0xFF00FF, 0x00FFFF,
        0x800000, 0x008000, 0x000080, 0x808000, 0x800080, 0x008080, 0xC0C0C0, 0x808080,
        0x9999FF, 0x993366, 0xFFFFCC, 0xCCFFFF, 0x660066, 0xFF8080, 0x0066CC, 0xCCCCFF,
        0x000080, 0xFF00FF, 0xFFFF00, 0x00FFFF, 0x800080, 0x800000, 0x008080, 0x0000FF,
        0x00CCFF, 0xCCFFFF, 0xCCFFCC, 0xFFFF99, 0x99CCFF, 0xFF99CC, 0xCC99FF, 0xFFCC99,
        0x3366FF, 0x33CCCC, 0x99CC00, 0xFFCC00, 0xFF9900, 0xFF6600, 0x666699, 0x969696,
        0x003366, 0x339966, 0x003300, 0x333300, 0x993300, 0x993366, 0x333399, 0x333333,
    ]
}
