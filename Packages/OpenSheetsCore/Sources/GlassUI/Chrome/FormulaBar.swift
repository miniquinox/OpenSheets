import SheetModel
import SwiftUI

/// A defined name, as the name box lists it.
public struct DefinedNameItem: Sendable, Hashable, Identifiable {
    public var name: String
    /// `Sheet1!$A$1:$D$20`, already formatted. Shown as the subtitle so a name is picked by what
    /// it points at, not by remembering.
    public var rangeLabel: String
    /// A name scoped to one sheet rather than the workbook.
    public var scope: String?

    public init(name: String, rangeLabel: String, scope: String? = nil) {
        self.name = name
        self.rangeLabel = rangeLabel
        self.scope = scope
    }

    public var id: String { scope.map { "\($0)!\(name)" } ?? name }
}

/// Everything the formula bar renders from.
public struct FormulaBarState: Sendable, Hashable {
    /// What the name box shows: `A1`, `B2:D9`, or a defined name when the selection matches one.
    public var nameBoxText: String
    /// The workbook's defined names, for the picker.
    public var definedNames: [DefinedNameItem]
    /// The formula source, without the leading `=`. Empty for an empty cell.
    public var text: String
    /// True while the user is typing. Changes the field's ink from "showing" to "editing" and
    /// swaps the trailing controls for commit/cancel.
    public var isEditing: Bool
    /// True when the user has pulled the bar open to see a long formula.
    public var isExpanded: Bool
    /// A problem A3 found, once A3 exists. Shown as a line under the field, never as an alert.
    public var diagnostic: String?
    /// False for a read-only workbook.
    public var isEditable: Bool

    public init(
        nameBoxText: String = "A1",
        definedNames: [DefinedNameItem] = [],
        text: String = "",
        isEditing: Bool = false,
        isExpanded: Bool = false,
        diagnostic: String? = nil,
        isEditable: Bool = true
    ) {
        self.nameBoxText = nameBoxText
        self.definedNames = definedNames
        self.text = text
        self.isEditing = isEditing
        self.isExpanded = isExpanded
        self.diagnostic = diagnostic
        self.isEditable = isEditable
    }
}

/// Everything the formula bar can ask for.
public enum FormulaBarAction: Sendable, Hashable {
    /// The user typed. Sent on every keystroke so A8 can live-highlight the referenced ranges in
    /// the grid, which is the feature that makes a formula bar worth having.
    case textChanged(String)
    /// Return, or clicking the tick.
    case commit(String)
    /// Escape, or clicking the cross.
    case cancel
    /// The field took focus.
    case beginEditing
    /// A name or an address was entered in the name box.
    case navigate(String)
    /// A defined name was picked from the menu.
    case selectDefinedName(String)
    /// The `fx` button.
    case insertFunction
    /// The disclosure chevron at the right end.
    case toggleExpanded
}

/// Name box · `fx` · field.
///
/// One chrome lens, three regions, in the order Excel put them thirty years ago — because every
/// person who will use this app already knows where the name box is, and moving it buys nothing.
///
/// The field is `Text` when idle and `TextField` when editing, rather than a `TextField` that is
/// always live. That is not an optimisation: an idle `TextField` cannot render an
/// `AttributedString`, so the syntax colouring would only ever appear on a cell you are *not*
/// editing, which is precisely backwards. Swapping on focus gives coloured tokens while reading
/// and plain, fast, selectable text while typing.
public struct FormulaBar: View {
    private let state: FormulaBarState
    private let context: AppearanceContext
    private let perform: (FormulaBarAction) -> Void

    @State private var draft: String = ""
    @FocusState private var isFieldFocused: Bool

    public init(
        state: FormulaBarState,
        context: AppearanceContext,
        perform: @escaping (FormulaBarAction) -> Void
    ) {
        self.state = state
        self.context = context
        self.perform = perform
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(spacing: DS.Space.s) {
                nameBox
                divider
                functionButton
                field
                trailingControls
            }
            if let diagnostic = state.diagnostic {
                Label(diagnostic, systemImage: "exclamationmark.circle")
                    .font(DS.Text.caption)
                    .foregroundStyle(DS.Signal.errorInk(context))
                    .padding(.leading, DS.Space.m)
            }
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, DS.Space.s)
        .glassChrome(context: context, radius: DS.Radius.control)
        .onAppear { draft = state.text }
        .onChange(of: state.text) { _, newValue in
            if !isFieldFocused { draft = newValue }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Formula bar")
    }

    // MARK: Name box

    private var nameBox: some View {
        Menu {
            if state.definedNames.isEmpty {
                Text("No defined names")
            } else {
                ForEach(state.definedNames) { item in
                    Button {
                        perform(.selectDefinedName(item.name))
                    } label: {
                        Text("\(item.name)   \(item.rangeLabel)")
                    }
                }
            }
        } label: {
            HStack(spacing: DS.Space.xs) {
                Text(state.nameBoxText)
                    .font(DS.Text.formula)
                    .foregroundStyle(DS.Chrome.primary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(DS.Chrome.tertiary)
            }
            .frame(minWidth: 76, alignment: .leading)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Cell reference or defined name")
        .accessibilityLabel("Name box, \(state.nameBoxText)")
    }

    private var divider: some View {
        Rectangle()
            .fill(DS.Chrome.separator(context))
            .frame(width: DS.Stroke.hairline(context), height: 16)
            .accessibilityHidden(true)
    }

    private var functionButton: some View {
        Button { perform(.insertFunction) } label: {
            Text("fx")
                .font(.system(size: 12, weight: .semibold, design: .serif))
                .italic()
                .foregroundStyle(DS.Chrome.accent)
                .frame(width: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!state.isEditable)
        .help("Insert function")
        .accessibilityLabel("Insert function")
    }

    // MARK: Field

    @ViewBuilder
    private var field: some View {
        if state.isEditing || isFieldFocused {
            TextField("", text: $draft, axis: state.isExpanded ? .vertical : .horizontal)
                .textFieldStyle(.plain)
                .font(DS.Text.formula)
                .foregroundStyle(DS.Chrome.primary)
                .lineLimit(state.isExpanded ? 5 : 1)
                .focused($isFieldFocused)
                .onChange(of: draft) { _, newValue in perform(.textChanged(newValue)) }
                .onSubmit { perform(.commit(draft)) }
                .onExitCommand { perform(.cancel) }
                .accessibilityLabel("Formula")
        } else {
            Button {
                perform(.beginEditing)
                isFieldFocused = true
            } label: {
                Text(FormulaSyntax.highlight(displayText, context: context))
                    .font(DS.Text.formula)
                    .lineLimit(state.isExpanded ? 5 : 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!state.isEditable)
            .accessibilityLabel(state.text.isEmpty ? "Formula, empty" : "Formula, \(state.text)")
        }
    }

    /// The leading `=` is stored out of the model (matching `Cell.formula`) and put back for
    /// display, because a formula bar that does not show the `=` is showing you a string.
    private var displayText: String {
        state.text.isEmpty ? "" : "=" + state.text
    }

    // MARK: Trailing

    @ViewBuilder
    private var trailingControls: some View {
        HStack(spacing: DS.Space.xs) {
            if state.isEditing || isFieldFocused {
                Button { perform(.cancel) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DS.Chrome.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel edit")

                Button { perform(.commit(draft)) } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DS.Chrome.accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Commit edit")
            }

            Button { perform(.toggleExpanded) } label: {
                Image(systemName: state.isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(DS.Chrome.tertiary)
            }
            .buttonStyle(.plain)
            .help(state.isExpanded ? "Collapse formula bar" : "Expand formula bar")
            .accessibilityLabel(state.isExpanded ? "Collapse formula bar" : "Expand formula bar")
        }
    }
}

/// Turns a selection into the string the name box shows.
///
/// Lives here rather than in A8 because the rule — a single cell shows as `A1`, a range as
/// `A1:D9`, and a range that exactly matches a defined name shows the *name* — is a presentation
/// rule, and getting it wrong is a design bug rather than a data bug.
public enum NameBoxLabel {
    public static func text(for range: CellRange, definedNames: [DefinedNameItem] = []) -> String {
        let formatted = A1Notation.format(sheetName: nil, range: range)
        if let match = definedNames.first(where: { $0.rangeLabel == formatted }) {
            return match.name
        }
        return formatted
    }
}
