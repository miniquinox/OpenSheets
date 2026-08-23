import Foundation

/// A range that may name the sheet it lives on.
///
/// ``CellRange`` is deliberately sheet-agnostic — it is a rectangle, and most code only ever
/// deals with one sheet. But a defined name, a cross-sheet formula reference, and an MCP
/// argument all have to say *which* sheet, so they use this.
///
/// A `nil` ``sheet`` means "the sheet this reference appears on", which is what an unqualified
/// `A1:B2` means in a formula.
public struct RangeReference: Sendable, Hashable, Codable {
    /// The sheet, or `nil` for "wherever this reference appears".
    public var sheet: SheetID?
    /// The rectangle, in the coordinates of ``sheet``.
    public var range: CellRange

    public init(sheet: SheetID? = nil, range: CellRange) {
        self.sheet = sheet
        self.range = range
    }
}

/// A named range or named constant.
///
/// Excel's model is more awkward than `[String: CellRange]` suggests, in three ways this type
/// has to carry:
///
/// 1. **Names are scoped.** A name can be workbook-global or belong to one sheet, and the same
///    name can exist at both levels. Resolution checks the sheet first, then the workbook.
/// 2. **Names are case-insensitive.** `Total` and `TOTAL` are the same name.
/// 3. **Targets are not always ranges.** `=SUM(Sheet1!A:A)*2` is a legal definition. Anything
///    that is not a plain range keeps its ``formula`` text and leaves ``target`` `nil`, so it
///    round-trips without us pretending to understand it.
public struct DefinedName: Sendable, Hashable, Codable {
    /// The name as written, preserving the author's capitalisation.
    public var name: String

    /// The sheet this name belongs to, or `nil` for workbook scope.
    public var scope: SheetID?

    /// The range this name points at, when the definition is a plain range reference.
    public var target: RangeReference?

    /// The definition exactly as stored, always. This is what gets written back.
    public var formula: String

    /// Hidden names are real and common — Excel uses them for print areas and filter state.
    public var isHidden: Bool

    /// The optional comment Excel's name manager shows.
    public var comment: String?

    public init(
        name: String,
        scope: SheetID? = nil,
        target: RangeReference? = nil,
        formula: String,
        isHidden: Bool = false,
        comment: String? = nil
    ) {
        self.name = name
        self.scope = scope
        self.target = target
        self.formula = formula
        self.isHidden = isHidden
        self.comment = comment
    }

    /// The key this name occupies in ``Workbook/definedNames``.
    ///
    /// Uppercased for case-insensitivity, and prefixed with the sheet id for a scoped name so
    /// a global `Total` and a sheet-local `Total` can coexist. Build it with this rather than
    /// by hand.
    public var storageKey: String { DefinedName.storageKey(name: name, scope: scope) }

    /// See ``storageKey``.
    public static func storageKey(name: String, scope: SheetID?) -> String {
        let upper = name.uppercased()
        guard let scope else { return upper }
        return "\(scope.rawValue)!\(upper)"
    }

    /// Whether `name` follows Excel's identifier rules.
    ///
    /// Must start with a letter, underscore, or backslash; may then hold letters, digits,
    /// underscores, full stops, and backslashes; may not be `R`, `C`, `r`, or `c` (R1C1
    /// notation), may not look like a cell reference (`A1`, `XFD1048576`), and is capped at
    /// 255 characters.
    public static func validate(name: String) throws(SheetError) {
        guard !name.isEmpty else {
            throw SheetError.invalidDefinedName(name: name, reason: "a name cannot be empty")
        }
        guard name.count <= 255 else {
            throw SheetError.invalidDefinedName(name: name, reason: "a name may be at most 255 characters")
        }
        guard let first = name.first, first.isLetter || first == "_" || first == "\\" else {
            throw SheetError.invalidDefinedName(
                name: name, reason: "a name must start with a letter, an underscore, or a backslash"
            )
        }
        for character in name.dropFirst() {
            guard character.isLetter || character.isNumber || character == "_" || character == "."
                || character == "\\" || character == "?"
            else {
                throw SheetError.invalidDefinedName(name: name, reason: "'\(character)' is not allowed in a name")
            }
        }
        let upper = name.uppercased()
        guard upper != "R", upper != "C" else {
            throw SheetError.invalidDefinedName(name: name, reason: "'R' and 'C' are reserved for R1C1 notation")
        }
        guard CellRef(a1: name) == nil else {
            throw SheetError.invalidDefinedName(name: name, reason: "a name cannot look like a cell reference")
        }
    }
}

/// How Excel recalculates.
public enum CalculationMode: String, Sendable, Hashable, Codable, CaseIterable {
    case automatic
    /// Automatic except for data tables, which are expensive.
    case automaticExceptTables
    case manual
}

/// Where a workbook came from, which determines what can be written back.
public enum WorkbookFormat: String, Sendable, Hashable, Codable, CaseIterable {
    case xlsx
    /// Macro-enabled. Writable; the macros pass through and are never executed.
    case xlsm
    /// Template.
    case xltx
    case csv
    case tsv
    /// Created in-app, never saved.
    case new
}

/// Why a workbook opened read-only.
///
/// PLAN.md §5.2's rule: refusing to save is always better than corrupting. When this is
/// non-`nil`, the writer throws ``SheetError/writeRefused(reason:)`` and the UI shows a
/// banner explaining which of these it was.
public enum ReadOnlyReason: String, Sendable, Hashable, Codable, CaseIterable {
    /// Password-protected. We cannot decrypt it and will not guess.
    case encrypted
    /// A format we read partially or not at all — `.xlsb`, `.xls`.
    case unsupportedFormat
    /// A part we do not model and cannot safely regenerate around.
    case unknownCriticalPart
    /// The file or its directory is not writable.
    case fileSystemPermissions
    /// The source was incomplete when we read it.
    case truncatedSource
    /// The user asked for read-only.
    case userRequested

    /// One clause explaining this, for ``SheetError/writeRefused(reason:)``'s message.
    public var message: String {
        switch self {
        case .encrypted: "it is password-protected"
        case .unsupportedFormat: "OpenSheets cannot write this format without losing data"
        case .unknownCriticalPart: "it contains a part OpenSheets does not understand, and saving could destroy it"
        case .fileSystemPermissions: "the file is not writable"
        case .truncatedSource: "the file was incomplete when it was read"
        case .userRequested: "it was opened read-only"
        }
    }
}

/// How a delimited text file was laid out, so a save can put it back the same way.
///
/// PLAN.md §5.4 makes preserving the source dialect the default. A file that arrives
/// semicolon-separated in Windows-1252 with CRLF endings should leave that way unless the user
/// asks otherwise; silently normalising is the kind of change that breaks someone's downstream
/// script.
public struct CSVDialect: Sendable, Hashable, Codable {
    /// All three are in the corpus, and a bare `cr` still turns up in files from Classic Mac
    /// era tools.
    public enum LineEnding: String, Sendable, Hashable, Codable, CaseIterable {
        case lf, crlf, cr

        /// The literal characters to write.
        public var characters: String {
            switch self {
            case .lf: "\n"
            case .crlf: "\r\n"
            case .cr: "\r"
            }
        }
    }

    /// The field separator, as a single character.
    public var delimiter: Character
    /// The quote character, normally `"`.
    public var quote: Character
    /// The line ending the source used, which a save preserves by default.
    public var lineEnding: LineEnding
    /// Whether the file started with a byte-order mark.
    public var hasByteOrderMark: Bool
    /// The IANA name of the detected encoding, so the UI can say *"read as Windows-1252"* when
    /// it had to guess.
    public var encodingName: String
    /// Whether the encoding was detected confidently or fallen back to.
    public var encodingWasGuessed: Bool
    /// Whether the first row was treated as headers.
    public var hasHeaderRow: Bool
    /// Whether the file ended without a final line break.
    public var endsWithoutNewline: Bool

    public init(
        delimiter: Character = ",",
        quote: Character = "\"",
        lineEnding: LineEnding = .lf,
        hasByteOrderMark: Bool = false,
        encodingName: String = "utf-8",
        encodingWasGuessed: Bool = false,
        hasHeaderRow: Bool = false,
        endsWithoutNewline: Bool = false
    ) {
        self.delimiter = delimiter
        self.quote = quote
        self.lineEnding = lineEnding
        self.hasByteOrderMark = hasByteOrderMark
        self.encodingName = encodingName
        self.encodingWasGuessed = encodingWasGuessed
        self.hasHeaderRow = hasHeaderRow
        self.endsWithoutNewline = endsWithoutNewline
    }

    /// Comma-separated, UTF-8, LF.
    public static let standard = CSVDialect()

    /// Tab-separated, UTF-8, LF.
    public static let tsv = CSVDialect(delimiter: "\t")

    private enum CodingKeys: String, CodingKey {
        case delimiter, quote, lineEnding, hasByteOrderMark, encodingName
        case encodingWasGuessed, hasHeaderRow, endsWithoutNewline
    }

    /// `Character` has no `Codable` conformance, so the two character fields go through
    /// single-character strings.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(String(delimiter), forKey: .delimiter)
        try container.encode(String(quote), forKey: .quote)
        try container.encode(lineEnding, forKey: .lineEnding)
        try container.encode(hasByteOrderMark, forKey: .hasByteOrderMark)
        try container.encode(encodingName, forKey: .encodingName)
        try container.encode(encodingWasGuessed, forKey: .encodingWasGuessed)
        try container.encode(hasHeaderRow, forKey: .hasHeaderRow)
        try container.encode(endsWithoutNewline, forKey: .endsWithoutNewline)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let delimiterText = try container.decode(String.self, forKey: .delimiter)
        let quoteText = try container.decode(String.self, forKey: .quote)
        guard let delimiter = delimiterText.first, let quote = quoteText.first else {
            throw DecodingError.dataCorruptedError(
                forKey: .delimiter, in: container, debugDescription: "delimiter and quote must be single characters"
            )
        }
        self.init(
            delimiter: delimiter,
            quote: quote,
            lineEnding: try container.decodeIfPresent(LineEnding.self, forKey: .lineEnding) ?? .lf,
            hasByteOrderMark: try container.decodeIfPresent(Bool.self, forKey: .hasByteOrderMark) ?? false,
            encodingName: try container.decodeIfPresent(String.self, forKey: .encodingName) ?? "utf-8",
            encodingWasGuessed: try container.decodeIfPresent(Bool.self, forKey: .encodingWasGuessed) ?? false,
            hasHeaderRow: try container.decodeIfPresent(Bool.self, forKey: .hasHeaderRow) ?? false,
            endsWithoutNewline: try container.decodeIfPresent(Bool.self, forKey: .endsWithoutNewline) ?? false
        )
    }
}

/// Workbook-level facts that are not sheets, styles, or names.
public struct WorkbookMeta: Sendable, Hashable, Codable {
    /// The application that wrote the file, from `docProps/app.xml`.
    public var application: String?
    /// The producer's version string, verbatim.
    public var applicationVersion: String?
    /// From `docProps/core.xml`. Round-trip only — we never set it.
    public var creator: String?
    /// From `docProps/core.xml`. Round-trip only: writing our own name here would be a
    /// surprising edit to someone else's document metadata.
    public var lastModifiedBy: String?
    /// The document title from `docProps/core.xml`, which is not the filename.
    public var title: String?
    /// Creation timestamp from the document properties, not from the filesystem.
    public var created: Date?
    /// Modification timestamp from the document properties, not from the filesystem. The
    /// watcher compares the filesystem's mtime; this is only what the producer claimed.
    public var modified: Date?

    /// What the file asks Excel to do on open. We preserve it; recalculation policy inside
    /// OpenSheets is the formula engine's business.
    public var calculationMode: CalculationMode

    /// Set on save whenever we wrote a formula we could not evaluate ourselves, so Excel
    /// recalculates on open rather than trusting our cached value (PLAN.md §5.2).
    public var fullCalculationOnLoad: Bool

    /// **Which epoch this workbook's dates count from.** Not a preference — reading a 1904
    /// file as 1900 shifts every date by four years and a day.
    public var dateSystem: DateSystem

    /// What this was read from, which decides what it can be written back as. A CSV has no
    /// formula storage, so saving one stores evaluated results (PLAN.md §5.4).
    public var sourceFormat: WorkbookFormat

    /// Non-`nil` means saving is refused. See ``ReadOnlyReason``.
    public var readOnlyReason: ReadOnlyReason?

    /// Whether `vbaProject.bin` is present. It passes through untouched and is **never
    /// executed** (PLAN.md §7.3); the UI shows a "contains macros, not executed" chip.
    public var containsMacros: Bool

    /// How the source text file was laid out, for CSV and TSV. `nil` for xlsx.
    public var csvDialect: CSVDialect?

    /// Rows the CSV reader had to pad because they were short. Surfaced once, inline.
    public var raggedRowCount: Int

    public init(
        application: String? = nil,
        applicationVersion: String? = nil,
        creator: String? = nil,
        lastModifiedBy: String? = nil,
        title: String? = nil,
        created: Date? = nil,
        modified: Date? = nil,
        calculationMode: CalculationMode = .automatic,
        fullCalculationOnLoad: Bool = false,
        dateSystem: DateSystem = .excel1900,
        sourceFormat: WorkbookFormat = .new,
        readOnlyReason: ReadOnlyReason? = nil,
        containsMacros: Bool = false,
        csvDialect: CSVDialect? = nil,
        raggedRowCount: Int = 0
    ) {
        self.application = application
        self.applicationVersion = applicationVersion
        self.creator = creator
        self.lastModifiedBy = lastModifiedBy
        self.title = title
        self.created = created
        self.modified = modified
        self.calculationMode = calculationMode
        self.fullCalculationOnLoad = fullCalculationOnLoad
        self.dateSystem = dateSystem
        self.sourceFormat = sourceFormat
        self.readOnlyReason = readOnlyReason
        self.containsMacros = containsMacros
        self.csvDialect = csvDialect
        self.raggedRowCount = raggedRowCount
    }

    /// Whether saving is allowed.
    public var isWritable: Bool { readOnlyReason == nil }
}

/// A whole workbook: the top of the model, and the value every layer passes around.
///
/// Entirely `Sendable` value types, so a snapshot can cross an actor boundary for parsing or
/// evaluation and come back without a lock anywhere (PLAN.md §2.3). A million-cell workbook is
/// a large value, but copy-on-write means passing one around costs a retain until somebody
/// writes.
public struct Workbook: Sendable, Equatable, Codable {
    /// Sheets in tab order.
    public var sheets: [Sheet]

    /// Named ranges, keyed by ``DefinedName/storageKey`` — **not** by the raw name.
    ///
    /// The key folds case and encodes scope, because Excel allows a workbook-global `Total`
    /// and a sheet-local `Total` at the same time. Look names up with
    /// ``definedName(_:scope:)`` rather than subscripting directly, and add them with
    /// ``setDefinedName(_:)``.
    public var definedNames: [String: DefinedName]

    /// Every style the sheets reference.
    public var styles: StyleTable

    /// Everything about the workbook that is not cells.
    public var meta: WorkbookMeta

    /// Every byte of the original archive, so a save can put back what we never modelled.
    /// See ``OpaqueParts``.
    public var passthrough: OpaqueParts

    public init(
        sheets: [Sheet] = [],
        definedNames: [String: DefinedName] = [:],
        styles: StyleTable = .empty,
        meta: WorkbookMeta = WorkbookMeta(),
        passthrough: OpaqueParts = .empty
    ) {
        self.sheets = sheets
        self.definedNames = definedNames
        self.styles = styles
        self.meta = meta
        self.passthrough = passthrough
    }

    /// An empty workbook with one sheet, for `New Sheet`.
    public static func blank(sheetName: String = "Sheet1") -> Workbook {
        Workbook(sheets: [Sheet(id: SheetID(1), name: sheetName)])
    }

    // MARK: - Sheet access

    /// The sheet with this id.
    public subscript(id: SheetID) -> Sheet? {
        sheets.first { $0.id == id }
    }

    /// The sheet with this name, compared case-insensitively as Excel does.
    public func sheet(named name: String) -> Sheet? {
        sheets.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// The sheet with this name, or a thrown ``SheetError/sheetNotFound(reference:)``.
    public func requireSheet(named name: String) throws(SheetError) -> Sheet {
        guard let sheet = sheet(named: name) else { throw SheetError.sheetNotFound(reference: name) }
        return sheet
    }

    /// The sheet with this id, or a thrown ``SheetError/sheetNotFound(reference:)``.
    public func requireSheet(id: SheetID) throws(SheetError) -> Sheet {
        guard let sheet = self[id] else { throw SheetError.sheetNotFound(reference: id.description) }
        return sheet
    }

    /// This sheet's position in tab order.
    public func index(of id: SheetID) -> Int? {
        sheets.firstIndex { $0.id == id }
    }

    /// Sheets the user can see in the tab bar.
    public var visibleSheets: [Sheet] {
        sheets.filter { $0.visibility == .visible }
    }

    /// Replaces a sheet in place, matched by id. Does nothing if the id is not present.
    public mutating func update(_ sheet: Sheet) {
        guard let position = index(of: sheet.id) else { return }
        sheets[position] = sheet
    }

    /// Mutates a sheet in place, matched by id.
    ///
    /// The shape most edits want: `try workbook.withSheet(id) { $0.cells.setCell(…) }` without
    /// a copy-modify-write-back dance that is easy to get subtly wrong.
    ///
    /// This is the one place in `SheetModel` that uses untyped `throws`. Swift will not infer a
    /// typed thrown error into a closure parameter that is also generic over its result, so
    /// spelling it `throws(SheetError)` would force every caller to annotate the closure. Its
    /// *own* failure is still a ``SheetError/sheetNotFound(reference:)``.
    public mutating func withSheet<Result>(
        _ id: SheetID,
        _ body: (inout Sheet) throws -> Result
    ) throws -> Result {
        guard let position = index(of: id) else { throw SheetError.sheetNotFound(reference: id.description) }
        return try body(&sheets[position])
    }

    /// The lowest unused ``SheetID``, for adding a sheet.
    public var nextSheetID: SheetID {
        SheetID(rawValue: (sheets.map(\.id.rawValue).max() ?? 0) + 1)
    }

    /// Adds a sheet, checking its name is legal and unique.
    ///
    /// Inserts at `position`, or appends when that is `nil`.
    public mutating func addSheet(_ sheet: Sheet, at position: Int? = nil) throws(SheetError) {
        try Limits.validateSheetName(sheet.name)
        if self.sheet(named: sheet.name) != nil {
            throw SheetError.duplicateSheetName(name: sheet.name)
        }
        guard sheets.count < Limits.maxSheets else {
            throw SheetError.workbookTooComplex(detail: "a workbook may hold at most \(Limits.maxSheets) sheets")
        }
        if let position, position >= 0, position <= sheets.count {
            sheets.insert(sheet, at: position)
        } else {
            sheets.append(sheet)
        }
    }

    /// Renames a sheet, checking the new name is legal and unique.
    public mutating func renameSheet(_ id: SheetID, to name: String) throws(SheetError) {
        try Limits.validateSheetName(name)
        if let existing = sheet(named: name), existing.id != id {
            throw SheetError.duplicateSheetName(name: name)
        }
        guard let position = index(of: id) else { throw SheetError.sheetNotFound(reference: id.description) }
        sheets[position].name = name
    }

    /// Removes a sheet. Refuses to remove the last one — a workbook with no sheets is a state
    /// Excel cannot represent.
    @discardableResult
    public mutating func removeSheet(_ id: SheetID) throws(SheetError) -> Sheet {
        guard let position = index(of: id) else { throw SheetError.sheetNotFound(reference: id.description) }
        guard sheets.count > 1 else {
            throw SheetError.invalidArgument(name: "sheet", reason: "a workbook must keep at least one sheet")
        }
        return sheets.remove(at: position)
    }

    // MARK: - Defined names

    /// Looks a name up the way Excel resolves it: the sheet's own scope first, then the
    /// workbook's. Case-insensitive.
    public func definedName(_ name: String, scope: SheetID? = nil) -> DefinedName? {
        if let scope, let scoped = definedNames[DefinedName.storageKey(name: name, scope: scope)] {
            return scoped
        }
        return definedNames[DefinedName.storageKey(name: name, scope: nil)]
    }

    /// Adds or replaces a name, validating the identifier.
    public mutating func setDefinedName(_ definedName: DefinedName) throws(SheetError) {
        try DefinedName.validate(name: definedName.name)
        guard definedNames.count < Limits.maxDefinedNames || definedNames[definedName.storageKey] != nil else {
            throw SheetError.workbookTooComplex(detail: "a workbook may hold at most \(Limits.maxDefinedNames) names")
        }
        definedNames[definedName.storageKey] = definedName
    }

    /// Removes a name.
    @discardableResult
    public mutating func removeDefinedName(_ name: String, scope: SheetID? = nil) -> DefinedName? {
        definedNames.removeValue(forKey: DefinedName.storageKey(name: name, scope: scope))
    }

    /// Names visible from `sheet` — its own, plus every workbook-scoped one — sorted by name.
    public func definedNames(visibleFrom sheet: SheetID?) -> [DefinedName] {
        definedNames.values
            .filter { $0.scope == nil || $0.scope == sheet }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Validation

    /// Checks everything PLAN.md §8 requires of a workbook before it is written.
    ///
    /// Runs every sheet's own ``Sheet/validate()``, plus the checks that need the whole
    /// workbook: name uniqueness across sheets, defined-name identifiers, and that every
    /// referenced style exists.
    public func validate() throws(SheetError) {
        guard !sheets.isEmpty else {
            throw SheetError.invalidArgument(name: "sheets", reason: "a workbook must have at least one sheet")
        }

        var seenNames: Set<String> = []
        for sheet in sheets {
            try sheet.validate()
            let folded = sheet.name.uppercased()
            guard seenNames.insert(folded).inserted else {
                throw SheetError.duplicateSheetName(name: sheet.name)
            }
        }

        for definedName in definedNames.values {
            try DefinedName.validate(name: definedName.name)
            if let scope = definedName.scope, self[scope] == nil {
                throw SheetError.sheetNotFound(reference: scope.description)
            }
        }

        let styleCount = Int32(styles.count)
        for sheet in sheets {
            var thrown: SheetError?
            sheet.cells.forEachCell(in: .entireSheet) { _, cell in
                if thrown == nil, cell.styleID.rawValue < 0 || cell.styleID.rawValue >= styleCount {
                    thrown = SheetError.unknownStyleID(rawValue: cell.styleID.rawValue)
                }
            }
            if let thrown { throw thrown }
        }
    }

    /// Total populated cells across every sheet.
    public var cellCount: Int {
        sheets.reduce(0) { $0 + $1.cells.count }
    }
}

extension Workbook: CustomStringConvertible {
    public var description: String {
        "Workbook(\(sheets.count) sheets, \(cellCount) cells, \(meta.sourceFormat.rawValue))"
    }
}
