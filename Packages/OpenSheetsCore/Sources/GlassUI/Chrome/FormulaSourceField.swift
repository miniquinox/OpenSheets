import AppKit
import SwiftUI

/// The formula bar's field: **a real, visible `NSTextView`**.
///
/// # Why this is not a `TextField`
///
/// The version this replaces was an always-live SwiftUI `TextField` held at `opacity(0)` under a
/// syntax-coloured `Text`, so that a click would fall through to the field and place the caret in
/// it. It focused — keystrokes really did land — and it lost people's formulas, three ways at
/// once, all of them consequences of *editing something you cannot see*:
///
/// 1. **The first keystroke replaced the cell.** An `NSTextField` selects its whole contents when
///    it takes focus. Invisible, that select-all is invisible too, so typing `9` over
///    `=SUM(B2:B14)` looked like the bar had deleted the cell.
/// 2. **There was no caret and no selection**, because both were being drawn in a view at zero
///    opacity. Nothing said where the next character would go, and there was no click-to-position.
/// 3. **The click never started an edit.** `beginEditing` was emitted from a SwiftUI focus
///    *change*; a field that was already focused emitted nothing, so clicking the bar left the
///    document's edit session closed while AppKit quietly held the caret. That is the state the
///    bug was reported from — *"clicking here still does not let me edit"* — and it is also the
///    state in which a keystroke can replace a cell with nothing on screen to warn you.
///
/// So the field is now the thing you look at. There is no second copy of the text, nothing to
/// keep in sync between two layers, and nothing hidden: the caret you see is the caret AppKit is
/// using, and it is where you clicked.
///
/// # Why `NSTextView` rather than `NSTextField`
///
/// An `NSTextField` hands editing to a shared field editor whose select-on-focus behaviour is the
/// first defect above, and it cannot render an `AttributedString`, which is what forced the
/// two-layer arrangement in the first place. An `NSTextView` owns its own text storage, so the
/// syntax colouring is applied to *the characters being edited* — one view, coloured, editable,
/// with a caret in it — and ``FormulaTextView/becomeFirstResponder()`` is a seam where the
/// selection on focus is ours to decide rather than AppKit's.
struct FormulaSourceField: NSViewRepresentable {
    /// What the field should be showing. Pushed in only when it differs from what is already
    /// there, so a redraw never disturbs a caret mid-word.
    var text: String
    /// The bar is pulled open: wrap and grow instead of scrolling sideways.
    var isExpanded: Bool
    var appearance: AppearanceContext
    /// The caret arrived, or a click re-asserted it. Fired on **every** click rather than only on
    /// a focus transition — see defect 3 above.
    var onBeginEditing: () -> Void
    /// The user typed. Not fired for text pushed in through ``text``.
    var onTextChanged: (String) -> Void
    /// Return, Enter, or Tab, with the text as the field holds it.
    var onCommit: (String, FormulaBarAdvance) -> Void
    /// Escape, with the content **already restored** to what it was when the caret arrived.
    var onCancel: (String) -> Void
    var onFocusChange: (Bool) -> Void
    /// Lets the bar's own tick and cross end an edit exactly the way Return and Escape do.
    var handle: FormulaFieldHandle

    func makeNSView(context: Context) -> NSScrollView {
        let field = FormulaTextView(frame: .zero)
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = field
        handle.field = field
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let field = scrollView.documentView as? FormulaTextView else { return }
        handle.field = field
        field.onBeginEditing = onBeginEditing
        field.onTextChanged = onTextChanged
        field.onCommit = onCommit
        field.onCancel = onCancel
        field.onFocusChange = onFocusChange
        field.apply(glass: appearance)
        field.setWrapping(isExpanded, within: scrollView)
        scrollView.hasVerticalScroller = isExpanded
        field.setValue(text)
    }

    /// The row is sized from the face the field draws in. A text view inside a scroller is a
    /// document view — it reports the size of its *content*, which for an empty cell is nothing at
    /// all and for a long formula is the whole formula — so neither number is a row height.
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: NSScrollView,
        context: Context
    ) -> CGSize? {
        CGSize(
            width: proposal.replacingUnspecifiedDimensions().width,
            height: isExpanded ? DS.Metrics.formulaExpandedHeight : DS.Metrics.formulaLineHeight
        )
    }
}

/// A handle on the live field.
///
/// The tick and the cross are SwiftUI buttons, and a button click does not move the first
/// responder — so without this they would commit or cancel while the caret stayed in a field that
/// still held the abandoned text. They go through the same two methods the keys do instead.
///
/// `@unchecked Sendable` because a `weak var` cannot be expressed as immutable `Sendable` state.
/// Every access is on the main actor: SwiftUI's body, and AppKit's own callbacks.
final class FormulaFieldHandle: @unchecked Sendable {
    weak var field: FormulaTextView?

    /// Gives the caret back without saying anything. For a commit, whose text the caller already
    /// has.
    @MainActor func releaseFocus() { field?.releaseFocus() }

    /// Puts the content back to what it was when the caret arrived and gives the caret back.
    /// Returns the restored text, or `nil` when nothing was being edited.
    @MainActor func restore() -> String? { field?.restoreToFocusValue() }
}

/// The text view itself: the caret, the selection, the colouring, and the four keys that end an
/// edit.
@MainActor
final class FormulaTextView: NSTextView {
    var onBeginEditing: () -> Void = {}
    var onTextChanged: (String) -> Void = { _ in }
    var onCommit: (String, FormulaBarAdvance) -> Void = { _, _ in }
    var onCancel: (String) -> Void = { _ in }
    var onFocusChange: (Bool) -> Void = { _ in }

    /// The content exactly as it stood when the caret arrived. **Escape puts this back**, from
    /// here rather than from the document, so the restore does not depend on a round trip through
    /// the model landing before the next keystroke does.
    private(set) var textAtFocus: String = ""

    /// True while ``setValue(_:)`` is writing, so a push from the document is not reported back to
    /// it as something the user typed.
    private var isPushingValue = false

    private var glass: AppearanceContext = .light

    private static let keyEscape: UInt16 = 53
    private static let keyTab: UInt16 = 48
    private static let keyReturn: UInt16 = 36
    private static let keyEnter: UInt16 = 76

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        configure()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func configure() {
        isEditable = true
        isSelectable = true
        // Plain text, and every substitution off. A formula bar that turns `"` into `"` produces
        // a formula the parser cannot read, and the user cannot see why.
        isRichText = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        smartInsertDeleteEnabled = false
        usesFindBar = false
        usesFontPanel = false
        usesRuler = false
        allowsUndo = true
        drawsBackground = false
        focusRingType = .none
        textContainerInset = .zero
        textContainer?.lineFragmentPadding = 0
        setAccessibilityLabel("Formula")
        setAccessibilityRole(.textField)
        typingAttributes = baseAttributes
    }

    // MARK: - Appearance

    func apply(glass: AppearanceContext) {
        guard self.glass != glass else { return }
        self.glass = glass
        insertionPointColor = .labelColor
        typingAttributes = baseAttributes
        applyHighlight()
    }

    /// Wrapping for the pulled-open bar, sideways scrolling for the collapsed one — which is what
    /// keeps the caret on screen at the end of a formula longer than the window.
    func setWrapping(_ wraps: Bool, within scrollView: NSScrollView) {
        let unlimited = CGFloat.greatestFiniteMagnitude
        minSize = .zero
        maxSize = NSSize(width: unlimited, height: unlimited)
        isVerticallyResizable = true
        guard let container = textContainer else { return }
        if wraps {
            isHorizontallyResizable = false
            autoresizingMask = [.width]
            container.widthTracksTextView = true
            container.containerSize = NSSize(width: scrollView.contentSize.width, height: unlimited)
            setFrameSize(NSSize(width: scrollView.contentSize.width, height: frame.height))
        } else {
            isHorizontallyResizable = true
            autoresizingMask = []
            container.widthTracksTextView = false
            container.containerSize = NSSize(width: unlimited, height: unlimited)
        }
    }

    // MARK: - The value

    /// Writes `newValue` in without telling anyone the user typed it, and without moving the
    /// caret any further than the shorter string forces.
    func setValue(_ newValue: String) {
        guard string != newValue else { return }
        isPushingValue = true
        let caret = selectedRange().location
        string = newValue
        let length = (newValue as NSString).length
        setSelectedRange(NSRange(location: min(caret, length), length: 0))
        isPushingValue = false
        applyHighlight()
    }

    override func didChangeText() {
        super.didChangeText()
        applyHighlight()
        guard !isPushingValue else { return }
        onTextChanged(string)
    }

    // MARK: - Taking the caret

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        textAtFocus = string
        // **Never a select-all.** AppKit's convention for a field taking focus is to select its
        // whole contents, which is defensible for a one-word form field and catastrophic here: it
        // makes the next character replace the cell. A mouse click overrides this a moment later
        // with the character that was actually clicked, which is the whole point of the exercise.
        setSelectedRange(NSRange(location: (string as NSString).length, length: 0))
        onFocusChange(true)
        onBeginEditing()
        return true
    }

    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        onFocusChange(false)
        return true
    }

    /// A click **always** announces an edit, focused or not.
    ///
    /// This is the half of the bug the user reported. `becomeFirstResponder` fires once; a field
    /// that already holds the caret does not fire it again, so every click after the first told
    /// the document nothing and the edit session stayed closed. One click, one edit — that is the
    /// requirement, and it cannot be met by a transition alone.
    override func mouseDown(with event: NSEvent) {
        let wasFocused = window?.firstResponder === self
        super.mouseDown(with: event)
        if wasFocused { onBeginEditing() }
    }

    func releaseFocus() {
        guard let window, window.firstResponder === self else { return }
        window.makeFirstResponder(nil)
    }

    /// Puts back what was there when the caret arrived, and gives the caret back.
    @discardableResult
    func restoreToFocusValue() -> String {
        let restored = textAtFocus
        setValue(restored)
        releaseFocus()
        return restored
    }

    // MARK: - The keys that end an edit

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case Self.keyEscape:
            cancel()
        case Self.keyTab:
            commit(event.modifierFlags.contains(.shift) ? .backward : .forward)
        case Self.keyReturn, Self.keyEnter:
            // Option-Return breaks the line inside a formula, as Excel's bar does. Plain Return
            // commits, in every mode — a pulled-open bar is a taller field, not a text editor.
            if event.modifierFlags.contains(.option) {
                insertText("\n", replacementRange: selectedRange())
            } else {
                commit(event.modifierFlags.contains(.shift) ? .up : .down)
            }
        default:
            super.keyDown(with: event)
        }
    }

    /// Escape does not reach ``keyDown(with:)`` when it arrives as a `cancelOperation:` through
    /// the responder chain — a menu key equivalent, or `NSApp` closing a popover — so it is
    /// claimed here as well.
    override func cancelOperation(_ sender: Any?) {
        cancel()
    }

    private func commit(_ advance: FormulaBarAdvance) {
        let value = string
        // Focus goes first: the shell answers a commit by moving the caret into the grid, and a
        // field that resigned afterwards would take it straight back out again.
        releaseFocus()
        onCommit(value, advance)
    }

    private func cancel() {
        let restored = restoreToFocusValue()
        onCancel(restored)
    }

    // MARK: - Colour

    private var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: Self.font(weight: .regular), .foregroundColor: NSColor.labelColor]
    }

    private static func font(weight: NSFont.Weight) -> NSFont {
        .monospacedSystemFont(ofSize: DS.Text.formulaSize, weight: weight)
    }

    /// Recolours the characters in place.
    ///
    /// Attributes only — never `replaceCharacters` — because the storage being recoloured is the
    /// storage the caret is sitting in. Rebuilding it on every keystroke would collapse the
    /// selection and undo the click that placed it.
    private func applyHighlight() {
        guard let storage = textStorage else { return }
        let whole = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: whole)
        if FormulaSyntax.isFormula(storage.string) {
            var location = 0
            for token in FormulaSyntax.tokenize(storage.string) {
                let length = (token.text as NSString).length
                let range = NSRange(location: location, length: length)
                location += length
                guard NSMaxRange(range) <= storage.length else { break }
                storage.addAttributes(attributes(for: token.kind), range: range)
            }
        }
        storage.endEditing()
    }

    /// The same three colours ``FormulaSyntax/highlight(_:context:)`` gives the reading copy, in
    /// AppKit's currency. `DS.Chrome.primary` and `.secondary` are `Color.primary` and
    /// `.secondary`, which are these two system inks.
    private func attributes(for kind: FormulaSyntax.Token.Kind) -> [NSAttributedString.Key: Any] {
        switch kind {
        case .reference:
            [.foregroundColor: glass.accent.nsColor]
        case .function:
            [.font: Self.font(weight: .semibold)]
        case .string:
            [.foregroundColor: NSColor(DS.Signal.connected(glass))]
        case .error:
            [
                .foregroundColor: NSColor(DS.Signal.errorInk(glass)),
                .font: Self.font(weight: .semibold),
            ]
        case .name:
            [.underlineStyle: NSUnderlineStyle.single.rawValue]
        case .oper:
            [.foregroundColor: NSColor.secondaryLabelColor]
        case .number, .plain:
            [:]
        }
    }
}
