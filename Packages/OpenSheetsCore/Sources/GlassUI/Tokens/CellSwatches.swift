import SheetModel
import SwiftUI

/// The colours the toolbar offers for cell text and cell fill.
///
/// # These are not chrome
///
/// Everything else in `Tokens/` describes the app: what a panel is made of, what a signal means,
/// what the grid's lines look like. These describe the **document** — they end up in the user's
/// `.xlsx` as `<fgColor rgb="…"/>` and get opened in Excel on somebody else's machine. They live
/// here anyway because `GlassLintTests` allows a colour literal in exactly one directory, and one
/// exemption that is easy to find beats a second one that is easy to widen.
///
/// # Why a fixed set and not a colour well
///
/// `ColorPicker` would offer sixteen million colours and no opinion, and a spreadsheet that has
/// been coloured from the system picker is a spreadsheet nobody can make consistent afterwards.
/// Ten hues at two lightnesses is the range a person actually uses to mark up a sheet, and every
/// one of them stays legible with the default text colour on top — which a freely picked colour
/// does not.
///
/// The values are Excel's own standard palette rather than this app's, because the file is going
/// to be opened in Excel and a fill that matches its swatches reads as deliberate there.
public enum CellSwatches {
    /// One offered colour: what it puts in the file, and what to call it out loud.
    public struct Swatch: Sendable, Hashable, Identifiable {
        public var id: String { name }
        public var name: String
        public var color: RGBAColor

        public var style: StyleColor { .rgb(color) }

        /// The swatch as SwiftUI sees it, for the chip in the menu.
        public var display: Color {
            Color(
                .sRGB,
                red: Double(color.red) / 255,
                green: Double(color.green) / 255,
                blue: Double(color.blue) / 255,
                opacity: 1
            )
        }
    }

    private static func swatch(_ name: String, _ red: UInt8, _ green: UInt8, _ blue: UInt8) -> Swatch {
        Swatch(name: name, color: RGBAColor(red: red, green: green, blue: blue))
    }

    /// Strong colours: for text, and for fills that want to be seen from across the room.
    public static let strong: [Swatch] = [
        swatch("Black", 0, 0, 0),
        swatch("Grey", 89, 89, 89),
        swatch("Red", 192, 0, 0),
        swatch("Orange", 197, 90, 17),
        swatch("Yellow", 191, 143, 0),
        swatch("Green", 55, 125, 34),
        swatch("Teal", 49, 133, 156),
        swatch("Blue", 31, 78, 121),
        swatch("Purple", 112, 48, 160),
        swatch("Brown", 132, 60, 12),
    ]

    /// The same hues, pale enough to read black text on. These are what a fill usually wants: a
    /// row highlighted in strong red is a row nobody can read.
    public static let pale: [Swatch] = [
        swatch("White", 255, 255, 255),
        swatch("Light grey", 217, 217, 217),
        swatch("Light red", 255, 199, 206),
        swatch("Light orange", 252, 228, 214),
        swatch("Light yellow", 255, 235, 156),
        swatch("Light green", 198, 239, 206),
        swatch("Light teal", 218, 238, 243),
        swatch("Light blue", 189, 215, 238),
        swatch("Light purple", 228, 223, 236),
        swatch("Light brown", 244, 225, 213),
    ]

    /// Both rows, in the order the grid draws them.
    public static let all: [[Swatch]] = [strong, pale]
}
