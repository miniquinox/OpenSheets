import SwiftUI

/// Which edges of the selection have a border.
public struct BorderEdges: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let top = BorderEdges(rawValue: 1 << 0)
    public static let leading = BorderEdges(rawValue: 1 << 1)
    public static let bottom = BorderEdges(rawValue: 1 << 2)
    public static let trailing = BorderEdges(rawValue: 1 << 3)
    /// Between cells inside a multi-cell selection.
    public static let inner = BorderEdges(rawValue: 1 << 4)

    public static let all: BorderEdges = [.top, .leading, .bottom, .trailing, .inner]
    public static let outline: BorderEdges = [.top, .leading, .bottom, .trailing]
}

/// Vertical alignment inside a cell.
public enum CellVerticalAlign: String, Sendable, Hashable, CaseIterable, Codable {
    case top
    case middle
    case bottom

    public var symbolName: String {
        switch self {
        case .top: "arrow.up.to.line"
        case .middle: "arrow.down.and.line.horizontal.and.arrow.up"
        case .bottom: "arrow.down.to.line"
        }
    }

    public var label: String {
        switch self {
        case .top: "Align top"
        case .middle: "Align middle"
        case .bottom: "Align bottom"
        }
    }
}

public struct InspectorState: Sendable, Hashable {
    /// "B2:D9" — what the panel is describing. Named up front because an inspector with no
    /// subject is the most common way to change the wrong cells.
    public var selectionLabel: String
    public var numberFormat: NumberFormatChoice
    /// `nil` when the selection has cells with different decimal counts. Every field here follows
    /// the same rule: a mixed selection shows blank, not the first cell's value.
    public var decimalPlaces: Int?
    /// A raw OOXML format code, when the cell uses one we have no preset for. Shown read-only
    /// with an explanation rather than hidden, because silently replacing `[$-409]d\ mmm\ yy`
    /// with "Date" would destroy it on the next edit.
    public var customFormatCode: String?
    public var fontName: String
    public var fontSize: Double
    public var isBold: Bool
    public var isItalic: Bool
    public var isUnderline: Bool
    /// Index into ``Palette/tabSwatches``. `nil` is no fill.
    public var fillIndex: Int?
    public var borders: BorderEdges
    public var alignment: CellAlign
    public var verticalAlignment: CellVerticalAlign
    public var wrapsText: Bool
    public var isEditable: Bool

    public init(
        selectionLabel: String,
        numberFormat: NumberFormatChoice = .general,
        decimalPlaces: Int? = 2,
        customFormatCode: String? = nil,
        fontName: String = "Calibri",
        fontSize: Double = 11,
        isBold: Bool = false,
        isItalic: Bool = false,
        isUnderline: Bool = false,
        fillIndex: Int? = nil,
        borders: BorderEdges = [],
        alignment: CellAlign = .general,
        verticalAlignment: CellVerticalAlign = .bottom,
        wrapsText: Bool = false,
        isEditable: Bool = true
    ) {
        self.selectionLabel = selectionLabel
        self.numberFormat = numberFormat
        self.decimalPlaces = decimalPlaces
        self.customFormatCode = customFormatCode
        self.fontName = fontName
        self.fontSize = fontSize
        self.isBold = isBold
        self.isItalic = isItalic
        self.isUnderline = isUnderline
        self.fillIndex = fillIndex
        self.borders = borders
        self.alignment = alignment
        self.verticalAlignment = verticalAlignment
        self.wrapsText = wrapsText
        self.isEditable = isEditable
    }
}

public enum InspectorAction: Sendable, Hashable {
    case setNumberFormat(NumberFormatChoice)
    case setDecimalPlaces(Int)
    case setFontName(String)
    case setFontSize(Double)
    case toggleBold
    case toggleItalic
    case toggleUnderline
    case setFill(Int?)
    case setBorders(BorderEdges)
    case setAlignment(CellAlign)
    case setVerticalAlignment(CellVerticalAlign)
    case toggleWrapText
    case clearFormatting
}

/// ⌘⌥1 — number format, font, fill, border, alignment for the selection.
///
/// The inspector is the toolbar's long form, and it deliberately duplicates it rather than
/// replacing it. The toolbar is for the four things you do constantly; this is for everything
/// else, and for seeing what a cell's formatting *currently is*, which the toolbar can only hint
/// at with a highlighted button.
public struct Inspector: View {
    private let state: InspectorState
    private let context: AppearanceContext
    private let perform: (InspectorAction) -> Void

    /// The font list. Supplied by the caller rather than read from `NSFontManager` here, because
    /// enumerating fonts is slow enough to want caching and that cache does not belong in a view.
    private let availableFonts: [String]

    /// How much anchored chrome floats over the top of this column. See ``Sidebar`` — the
    /// material runs up behind the band, the content starts below it, and the height is measured
    /// by the caller rather than guessed here.
    private let topInset: CGFloat

    public init(
        state: InspectorState,
        availableFonts: [String] = [],
        context: AppearanceContext,
        topInset: CGFloat = 0,
        perform: @escaping (InspectorAction) -> Void
    ) {
        self.state = state
        self.availableFonts = availableFonts
        self.context = context
        self.topInset = topInset
        self.perform = perform
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.xl) {
                subject
                numberSection
                fontSection
                alignmentSection
                fillSection
                borderSection
                Button("Clear formatting") { perform(.clearFormatting) }
                    .buttonStyle(.plain)
                    .font(DS.Text.control)
                    .foregroundStyle(DS.Chrome.accent)
                    .disabled(!state.isEditable)
            }
            .padding(DS.Space.l)
        }
        .safeAreaPadding(.top, topInset)
        .frame(width: DS.Metrics.inspectorWidth)
        .vibrantChrome(.sidebar, context: context)
        .disabled(!state.isEditable)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Inspector for \(state.selectionLabel)")
    }

    private var subject: some View {
        HStack(spacing: DS.Space.s) {
            Text(state.selectionLabel)
                .font(DS.Text.formula)
                .foregroundStyle(DS.Chrome.primary)
            Spacer(minLength: 0)
            if !state.isEditable {
                Label("Read-only", systemImage: "lock")
                    .font(DS.Text.caption)
                    .foregroundStyle(DS.Signal.calmInk(context))
            }
        }
    }

    private var numberSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            SectionHeader("Number")
            Picker("Format", selection: formatBinding) {
                ForEach(NumberFormatChoice.allCases) { choice in
                    Text(choice.label).tag(choice)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)

            if let code = state.customFormatCode {
                VStack(alignment: .leading, spacing: DS.Space.hair) {
                    Text(code)
                        .font(DS.Text.mono)
                        .foregroundStyle(DS.Chrome.primary)
                        .textSelection(.enabled)
                    Text("Custom format from the file. Kept as-is.")
                        .font(DS.Text.caption)
                        .foregroundStyle(DS.Chrome.tertiary)
                }
            }

            HStack {
                Text("Decimals")
                    .font(DS.Text.control)
                    .foregroundStyle(DS.Chrome.secondary)
                Spacer(minLength: 0)
                if let places = state.decimalPlaces {
                    Stepper(
                        value: Binding(
                            get: { places },
                            set: { perform(.setDecimalPlaces($0)) }
                        ),
                        in: 0 ... 15
                    ) {
                        Text("\(places)").dsNumeric()
                    }
                    .labelsHidden()
                    Text("\(places)").dsNumeric().foregroundStyle(DS.Chrome.primary)
                } else {
                    Text("Mixed")
                        .font(DS.Text.control)
                        .foregroundStyle(DS.Chrome.tertiary)
                }
            }
        }
    }

    private var fontSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            SectionHeader("Font")
            HStack(spacing: DS.Space.s) {
                Picker("Family", selection: fontNameBinding) {
                    if availableFonts.isEmpty {
                        Text(state.fontName).tag(state.fontName)
                    } else {
                        ForEach(availableFonts, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)

                TextField(
                    "",
                    value: Binding(
                        get: { state.fontSize },
                        set: { perform(.setFontSize($0)) }
                    ),
                    format: .number
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 48)
                .monospacedDigit()
                .accessibilityLabel("Font size")
            }

            HStack(spacing: DS.Space.xs) {
                inspectorToggle("bold", "Bold", state.isBold) { perform(.toggleBold) }
                inspectorToggle("italic", "Italic", state.isItalic) { perform(.toggleItalic) }
                inspectorToggle("underline", "Underline", state.isUnderline) {
                    perform(.toggleUnderline)
                }
            }
        }
    }

    private var alignmentSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            SectionHeader("Alignment")
            HStack(spacing: DS.Space.xs) {
                ForEach([CellAlign.leading, .center, .trailing], id: \.self) { align in
                    inspectorToggle(align.symbolName, align.label, state.alignment == align) {
                        perform(.setAlignment(align))
                    }
                }
                Rectangle()
                    .fill(DS.Chrome.separator(context))
                    .frame(width: DS.Stroke.hairline(context), height: 16)
                ForEach(CellVerticalAlign.allCases, id: \.self) { align in
                    inspectorToggle(
                        align.symbolName, align.label, state.verticalAlignment == align
                    ) { perform(.setVerticalAlignment(align)) }
                }
            }
            Toggle("Wrap text", isOn: Binding(get: { state.wrapsText }, set: { _ in perform(.toggleWrapText) }))
                .toggleStyle(.checkbox)
                .font(DS.Text.control)
        }
    }

    private var fillSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            SectionHeader("Fill")
            HStack(spacing: DS.Space.xs) {
                fillSwatch(nil)
                ForEach(Array(Palette.tabSwatches.enumerated()), id: \.offset) { index, _ in
                    fillSwatch(index)
                }
            }
        }
    }

    private func fillSwatch(_ index: Int?) -> some View {
        let isSelected = state.fillIndex == index
        let color: Color = index.map {
            let entry = Palette.tabSwatches[$0]
            return context.pick(light: entry.light, dark: entry.dark).color
        } ?? Color.clear
        let name = index.map { Palette.tabSwatches[$0].name } ?? "No fill"

        return Button { perform(.setFill(index)) } label: {
            ZStack {
                Circle().fill(color)
                if index == nil {
                    Image(systemName: "slash.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(DS.Chrome.secondary)
                }
                if isSelected {
                    Circle()
                        .stroke(DS.Chrome.accent, lineWidth: 2)
                        .frame(width: 22, height: 22)
                }
            }
            .frame(width: 18, height: 18)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel(name)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var borderSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            SectionHeader("Border")
            HStack(spacing: DS.Space.xs) {
                borderButton("square", "All borders", .all)
                borderButton("square.dashed", "Outline only", .outline)
                borderButton("rectangle.split.3x3", "Inner only", .inner)
                borderButton("square.slash", "None", [])
            }
        }
    }

    private func borderButton(_ symbol: String, _ label: String, _ edges: BorderEdges) -> some View {
        inspectorToggle(symbol, label, state.borders == edges) { perform(.setBorders(edges)) }
    }

    private func inspectorToggle(
        _ symbol: String,
        _ label: String,
        _ isOn: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isOn ? DS.Chrome.onAccent : DS.Chrome.primary)
                .frame(width: 24, height: 20)
                .background {
                    DS.Radius.shape(DS.Radius.chip)
                        .fill(isOn ? DS.Chrome.accent : DS.Chrome.separator)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }

    private var formatBinding: Binding<NumberFormatChoice> {
        Binding(get: { state.numberFormat }, set: { perform(.setNumberFormat($0)) })
    }

    private var fontNameBinding: Binding<String> {
        Binding(get: { state.fontName }, set: { perform(.setFontName($0)) })
    }
}
