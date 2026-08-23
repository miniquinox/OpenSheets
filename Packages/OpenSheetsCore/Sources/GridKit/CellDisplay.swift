import Foundation
import SheetModel

/// A cell's value turned into the exact characters that go on screen, plus how to place them.
///
/// Deliberately separate from drawing: the same value formats identically whether it is being
/// painted, measured for auto-fit, read out by VoiceOver, or copied to the pasteboard. Three
/// implementations of "what does this cell say" is three chances for the tooltip to disagree
/// with the pixel.
public struct CellDisplay: Sendable, Equatable {
    /// What the cell says. Empty for a blank cell.
    public var text: String

    /// Alignment with ``CellAlignment/Horizontal/general`` already resolved against the value —
    /// numbers right, text left, booleans and errors centred. Never `general`.
    public var horizontal: CellAlignment.Horizontal

    /// Vertical placement, straight from the style. Excel's default is bottom.
    public var vertical: CellAlignment.Vertical

    /// Text colour, with ``StyleColor/automatic`` and any `[Red]` section colour resolved.
    public var color: RGBAColor

    /// Whether this rendered from a number.
    ///
    /// Decides the two Excel behaviours that differ by type: a number that does not fit becomes
    /// `####` and never spills, while text spills into empty neighbours and is otherwise cut off.
    public var isNumeric: Bool

    /// The character after a `*` in the format code, repeated to fill the cell.
    public var fillCharacter: Character?

    /// Whether the format asked for accounting-style alignment, which pins the currency symbol
    /// to the left edge and the digits to the right.
    public var isAccounting: Bool

    /// Whether this value came out of a `General` format, and may therefore be re-rendered with
    /// fewer decimals to fit a narrow column — which is what Excel does before giving up.
    public var isGeneralNumber: Bool

    /// The unformatted number behind ``text``, kept so the fitting pass can re-render it.
    public var rawNumber: Double?

    public init(
        text: String,
        horizontal: CellAlignment.Horizontal,
        vertical: CellAlignment.Vertical = .bottom,
        color: RGBAColor,
        isNumeric: Bool = false,
        fillCharacter: Character? = nil,
        isAccounting: Bool = false,
        isGeneralNumber: Bool = false,
        rawNumber: Double? = nil
    ) {
        self.text = text
        self.horizontal = horizontal
        self.vertical = vertical
        self.color = color
        self.isNumeric = isNumeric
        self.fillCharacter = fillCharacter
        self.isAccounting = isAccounting
        self.isGeneralNumber = isGeneralNumber
        self.rawNumber = rawNumber
    }

    /// Nothing to draw.
    public var isEmpty: Bool { text.isEmpty && fillCharacter == nil }
}
