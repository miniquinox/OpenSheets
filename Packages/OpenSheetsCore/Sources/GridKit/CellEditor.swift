import AppKit
import Foundation
import SheetModel

/// The in-cell editor: an `NSTextField` positioned over the active cell.
///
/// # What it does not do
///
/// It does not parse, evaluate, or validate anything. `=SUM(A1:A9)` is a string to it, and stays
/// one until ``GridEvent/commitEdit(ref:text:advance:)`` hands it to the shell, which owns the
/// formula engine. A renderer that started interpreting `=` would end up with a second, subtly
/// different parser — and the two would disagree on exactly the inputs that matter.
///
/// It grows right and down as the text outgrows the cell, the way Excel's does, so a long formula
/// is readable without a separate window. Growth stops at the pane's edge.
@MainActor
public final class CellEditor: NSView {
    /// The field itself. Exposed so the shell can drive selection or install a completion menu.
    public let field = EditorTextField()

    /// The cell being edited, or `nil` when the editor is hidden.
    public private(set) var editingRef: CellRef?

    /// Called when the user commits, with the direction to move afterwards.
    public var onCommit: ((CellRef, String, AdvanceDirection?) -> Void)?
    /// Called on Escape.
    public var onCancel: ((CellRef) -> Void)?
    /// Called on every keystroke, so a formula bar can show what is being typed into the cell.
    ///
    /// Only user typing fires it — assigning ``EditorTextField/stringValue`` does not post
    /// `NSControlTextDidChange`, which is what keeps a two-way mirror from feeding itself.
    public var onTextChanged: ((String) -> Void)?

    private var theme: GridTheme = .light
    private var anchorRect: CGRect = .zero
    private var maximumSize: CGSize = .zero
    /// Remembered from ``begin(at:rect:text:theme:zoom:alignment:maximumSize:takingFocus:)`` so
    /// the font can be re-picked on every keystroke at the zoom the grid is actually drawn at.
    private var zoom: Double = 1

    override public var isFlipped: Bool { true }

    public init() {
        super.init(frame: .zero)
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = true
        field.focusRingType = .none
        field.lineBreakMode = .byClipping
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.target = self
        field.action = #selector(fieldAction)
        field.editorDelegate = self
        addSubview(field)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Whether the editor is on screen.
    public var isEditing: Bool { editingRef != nil }

    /// Opens the editor over `rect`, seeded with `text`.
    ///
    /// `isFormula` picks SF Mono, which is not decoration: a formula is code, and proportional
    /// digits in a nested `INDEX(MATCH(...))` make the parentheses genuinely hard to count.
    ///
    /// `takingFocus: false` opens it as a **mirror**: the cell shows what is being typed, but the
    /// keyboard stays wherever it is. That is the mode the formula bar opens it in — the caret
    /// belongs to the bar the user just clicked, and grabbing it here would both move the caret
    /// off the character they aimed at and end the field editor session they had just started.
    public func begin(
        at ref: CellRef,
        rect: CGRect,
        text: String,
        theme: GridTheme,
        zoom: Double,
        alignment: CellAlignment.Horizontal,
        maximumSize: CGSize,
        takingFocus: Bool = true
    ) {
        editingRef = ref
        self.theme = theme
        anchorRect = rect
        self.maximumSize = maximumSize
        self.zoom = zoom

        field.stringValue = text
        field.alignment = switch alignment {
        case .right: .right
        case .center: .center
        default: .left
        }
        applyFont(for: text, zoom: zoom)
        field.textColor = NSColor(cgColor: theme.cellText.cgColor) ?? .textColor
        field.backgroundColor = NSColor(cgColor: theme.canvasBackground.cgColor) ?? .textBackgroundColor

        isHidden = false
        resize()
        guard takingFocus else { return }
        window?.makeFirstResponder(field)
        if let editor = field.currentEditor() {
            editor.selectedRange = NSRange(location: text.count, length: 0)
        }
    }

    /// Replaces the text without disturbing the editor's identity, for the mirror.
    ///
    /// Not `field.stringValue = …` at the call site: the font follows the leading `=` and the
    /// frame follows the width, so a mirror that only set the string would show a formula in the
    /// body font and clip it at the cell's edge.
    public func mirror(_ text: String) {
        guard editingRef != nil, field.stringValue != text else { return }
        field.stringValue = text
        applyFont(for: text, zoom: zoom)
        resize()
    }

    /// Closes the editor without emitting anything.
    public func dismiss() {
        editingRef = nil
        isHidden = true
        field.stringValue = ""
    }

    /// The text currently typed.
    public var text: String { field.stringValue }

    /// Commits and closes.
    public func commit(advance: AdvanceDirection?) {
        guard let ref = editingRef else { return }
        let value = field.stringValue
        dismiss()
        onCommit?(ref, value, advance)
    }

    /// Cancels and closes.
    public func cancel() {
        guard let ref = editingRef else { return }
        dismiss()
        onCancel?(ref)
    }

    @objc private func fieldAction() {
        commit(advance: .down)
    }

    /// The user typed. Re-picks the font, regrows the frame, and tells whoever is mirroring.
    fileprivate func textWasEdited() {
        applyFont(for: field.stringValue, zoom: zoom)
        resize()
        onTextChanged?(field.stringValue)
    }

    private func applyFont(for text: String, zoom: Double) {
        let size = theme.defaultFontSize * zoom
        if text.hasPrefix("=") {
            field.font = NSFont(name: theme.monospacedFontName, size: size)
                ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        } else {
            field.font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
        }
    }

    /// Grows the editor to fit its text, stopping at the pane edge.
    public func resize() {
        guard editingRef != nil else { return }
        let inset: CGFloat = 2
        let measured = field.attributedStringValue.size().width + 12
        let width = min(max(anchorRect.width, measured), max(anchorRect.width, maximumSize.width))
        let height = anchorRect.height
        frame = CGRect(x: anchorRect.minX, y: anchorRect.minY, width: width, height: height)
        field.frame = bounds.insetBy(dx: inset, dy: inset)
    }

    /// The text field, subclassed so the grid sees the keys that end an edit before the field
    /// swallows them.
    public final class EditorTextField: NSTextField {
        weak var editorDelegate: CellEditor?

        override public func textDidChange(_ notification: Notification) {
            super.textDidChange(notification)
            editorDelegate?.textWasEdited()
        }

        override public func keyDown(with event: NSEvent) {
            // `insertNewline:` and friends arrive through `doCommand`, but Escape and Tab need
            // intercepting here or the field consumes them and the edit never ends.
            switch event.keyCode {
            case 53: // Escape
                editorDelegate?.cancel()
            case 48: // Tab
                editorDelegate?.commit(advance: event.modifierFlags.contains(.shift) ? .backward : .forward)
            case 36, 76: // Return, Enter
                editorDelegate?.commit(advance: event.modifierFlags.contains(.shift) ? .up : .down)
            default:
                super.keyDown(with: event)
            }
        }
    }
}
