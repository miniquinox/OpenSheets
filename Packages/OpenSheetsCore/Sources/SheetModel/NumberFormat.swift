import Foundation

/// An OOXML number-format code, parsed into something a renderer can act on.
///
/// A format code like `$#,##0.00;[Red]($#,##0.00)` is a tiny language: up to four
/// semicolon-separated sections (positive; negative; zero; text), each optionally prefixed
/// with a colour or a condition in brackets, each a pattern of digit placeholders, literals,
/// and date tokens. Parsing it once into a spec beats re-scanning the string per cell, and —
/// more importantly — means the grid, the CSV exporter, the MCP surface, and the inspector all
/// agree on what a format *means*.
///
/// This type **describes**; it does not render. Turning a value plus a spec into glyphs is
/// `GridKit`'s job, because it also needs font metrics to decide when a number becomes `####`.
///
/// # The one genuinely hard part
///
/// `m` means month, except when it means minute. Excel resolves it positionally: an `m`
/// immediately following an hour token, or immediately preceding a second token, is minutes;
/// otherwise it is months. `h:mm` is hours and minutes, `mm-dd-yy` is months and days, and
/// `m/d/yy h:mm` is both — in one string. That disambiguation happens here, once, at parse
/// time, so nothing downstream has to think about it.
public struct NumberFormat: Sendable, Hashable, Codable {
    /// The original code, verbatim. Always what gets written back — the parse is for us, not
    /// for the file.
    public let formatCode: String

    /// One to four sections, in source order.
    public let sections: [Section]

    /// A coarse classification for callers that only need to know "is this money".
    /// Derived from the *first* section, since that is the one a positive value renders through.
    public let kind: Kind

    /// Whether the code parsed cleanly. A malformed code still produces a usable value — the
    /// sections are whatever could be made of it — because one weird format must not stop a
    /// workbook from opening. ``validated(_:)`` is the strict door.
    public let isWellFormed: Bool

    /// Parses leniently: always succeeds, setting ``isWellFormed`` to `false` on a code that
    /// does not add up. Use this on the read path.
    public init(_ code: String) {
        let (rawSections, wellFormed) = NumberFormat.splitSections(code)
        let parsed = rawSections.map(Section.init(raw:))
        formatCode = code
        sections = parsed
        isWellFormed = wellFormed && !parsed.contains { !$0.isWellFormed }
        kind = NumberFormat.classify(parsed)
    }

    /// Parses strictly, throwing on a code that does not add up. Use this where a human or an
    /// agent typed the code — the inspector, `set_format` over MCP.
    public static func validated(_ code: String) throws(SheetError) -> NumberFormat {
        let format = NumberFormat(code)
        guard format.isWellFormed else {
            throw SheetError.invalidNumberFormat(
                code: code,
                reason: "unterminated quote or bracket, or more than four sections"
            )
        }
        return format
    }

    /// `General` — no formatting at all.
    public static let general = NumberFormat("General")

    /// `@` — everything is text.
    public static let text = NumberFormat("@")

    /// Whether this format renders a value as a date, a time, or both.
    ///
    /// This is what makes a number a date: xlsx has no date type, so `45000` is a date only
    /// because the cell's format says so.
    public var isDateTime: Bool {
        kind == .date || kind == .time || kind == .dateTime
    }

    /// Whether every section is `General`.
    public var isGeneral: Bool { kind == .general }

    /// The section that applies to `value`.
    ///
    /// With explicit conditions (`[>=100]…;[<100]…;…`) the first matching one wins and the
    /// last section is the fallback. Without them Excel's positional rules apply: one section
    /// covers everything, two split at zero (positive-and-zero, then negative), three split
    /// positive / negative / zero, and four add a text section that this method never returns.
    public func section(forNumber value: Double) -> Section? {
        // The text section is positional — always the fourth — not "whichever section happens
        // to hold only literals". `0.0;-0.0;"zero"` has three *numeric* sections, the third of
        // which renders as a literal.
        let numeric = sections.prefix(3)
        guard !numeric.isEmpty else { return sections.first }

        if numeric.contains(where: { $0.condition != nil }) {
            for section in numeric {
                guard let condition = section.condition else { return section }
                if condition.matches(value) { return section }
            }
            return numeric.last
        }

        switch numeric.count {
        case 1:
            return numeric[0]
        case 2:
            return value < 0 ? numeric[1] : numeric[0]
        default:
            if value > 0 { return numeric[0] }
            if value < 0 { return numeric[1] }
            return numeric[2]
        }
    }

    /// The section that applies to text values, or `nil` when the format has none — in which
    /// case text is shown unformatted, which is what Excel does.
    ///
    /// Only two shapes produce one: a four-section code, where the fourth section is the text
    /// section by position, and a whole-format text code like `@`.
    public var textSection: Section? {
        if sections.count >= 4 { return sections[3] }
        if sections.count == 1, sections[0].kind == .text { return sections[0] }
        return nil
    }

    /// Whether a negative value renders in red under this format.
    public var showsNegativeInRed: Bool {
        section(forNumber: -1)?.color == .red
    }
}

// MARK: - Kind

extension NumberFormat {
    /// What a format is *for*, at a glance.
    ///
    /// Used by the MCP `describe` tool to report a column's type, and by the inspector to
    /// preselect a category. Deliberately coarse: the detail lives in ``Section``.
    public enum Kind: String, Sendable, Hashable, Codable, CaseIterable {
        /// No format — Excel picks a representation from the value.
        case general
        case number
        /// A currency symbol with the number.
        case currency
        /// Currency with the symbol pushed to the cell edge and zeros shown as a dash — the
        /// `_(` / `*` patterns in built-in formats 41–44.
        case accounting
        case percentage
        case scientific
        case fraction
        case date
        case time
        case dateTime
        /// `@` — the value is shown as typed.
        case text
        /// Parsed, but not any of the above.
        case custom
    }

    private static func classify(_ sections: [Section]) -> Kind {
        guard let first = sections.first else { return .general }
        switch first.kind {
        case .general:
            return .general
        case .text:
            return .text
        case .date:
            guard let date = first.date else { return .custom }
            if date.hasDate, date.hasTime { return .dateTime }
            return date.hasDate ? .date : .time
        case .blank:
            return sections.dropFirst().first.map { [$0] }.map(classify) ?? .custom
        case .number:
            guard let number = first.number else { return .custom }
            if number.isAccounting { return .accounting }
            if number.currency != nil { return .currency }
            if number.percentCount > 0 { return .percentage }
            if number.isScientific { return .scientific }
            if number.fraction != nil { return .fraction }
            return .number
        }
    }
}

// MARK: - Section splitting

extension NumberFormat {
    /// Splits on `;`, ignoring separators inside quotes, brackets, or after a backslash.
    ///
    /// Reports `false` for an unterminated quote or bracket, or for more than four sections —
    /// the three ways a format code is actually malformed rather than merely unusual.
    static func splitSections(_ code: String) -> (sections: [String], wellFormed: Bool) {
        var sections: [String] = []
        var current = ""
        var inQuote = false
        var inBracket = false
        var escaped = false

        for character in code {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            switch character {
            case "\\" where !inQuote:
                current.append(character)
                escaped = true
            case "\"":
                inQuote.toggle()
                current.append(character)
            case "[" where !inQuote:
                inBracket = true
                current.append(character)
            case "]" where !inQuote:
                inBracket = false
                current.append(character)
            case ";" where !inQuote && !inBracket:
                sections.append(current)
                current = ""
            default:
                current.append(character)
            }
        }
        sections.append(current)

        let wellFormed = !inQuote && !inBracket && !escaped && sections.count <= 4
        return (sections, wellFormed)
    }
}

// MARK: - Section

extension NumberFormat {
    /// One semicolon-separated part of a format code.
    public struct Section: Sendable, Hashable, Codable {
        /// What this section formats.
        public enum Kind: String, Sendable, Hashable, Codable, CaseIterable {
            case general, number, date, text
            /// Nothing at all — an empty section, which is how `0;;` hides zeros.
            case blank
        }

        /// The section's source text, without the surrounding semicolons.
        public let raw: String
        /// What this section formats, which decides whether ``number`` or ``date`` is populated.
        public let kind: Kind
        /// A `[Red]`-style colour override, applied to the whole cell.
        public let color: SectionColor?
        /// A `[>100]`-style guard on when this section applies.
        public let condition: Condition?
        /// The `[$-409]` locale hint, as the raw LCID. We do not localise from it — Excel's
        /// locale rules are deep — but it round-trips and callers can use it.
        public let localeID: Int?
        /// Set when ``kind`` is ``Kind/number``.
        public let number: NumberSpec?
        /// Set when ``kind`` is ``Kind/date``.
        public let date: DateSpec?
        /// Whether this section parsed cleanly.
        public let isWellFormed: Bool

        init(raw: String) {
            self.raw = raw
            var scanner = FormatScanner(raw)
            let atoms = scanner.scan()
            color = scanner.color
            condition = scanner.condition
            localeID = scanner.localeID
            isWellFormed = scanner.isWellFormed

            let hasDateToken = atoms.contains { atom in
                switch atom {
                case .dateLetter, .amPm: true
                default: false
                }
            }
            let hasNumeric = atoms.contains { atom in
                if case .digit = atom { return true }
                return false
            }
            let hasText = atoms.contains { if case .textPlaceholder = $0 { true } else { false } }
            let isGeneral = atoms.contains { if case .general = $0 { true } else { false } }

            if hasDateToken {
                kind = .date
                date = DateSpec(atoms: atoms)
                number = nil
            } else if isGeneral, !hasNumeric {
                kind = .general
                date = nil
                number = nil
            } else if hasNumeric {
                kind = .number
                number = NumberSpec(atoms: atoms)
                date = nil
            } else if hasText {
                kind = .text
                date = nil
                number = nil
            } else if atoms.isEmpty {
                kind = .blank
                date = nil
                number = nil
            } else {
                // Literals only — `"paid"` as a whole section. Renders as its literal text.
                kind = .text
                date = nil
                number = nil
            }
        }

        /// The literal text this section renders when it has no placeholders — `0;;"—"` shows
        /// an em dash for zero.
        public var literalText: String {
            var scanner = FormatScanner(raw)
            return scanner.scan().reduce(into: "") { result, atom in
                if case let .literal(text) = atom { result += text }
                if case let .currency(symbol, _) = atom { result += symbol }
            }
        }
    }

    /// A `[Red]`-style colour prefix.
    ///
    /// Excel allows eight names plus `[Color1]`…`[Color56]` indexing the legacy palette.
    /// Negative-in-red is far and away the common case, which is why ``showsNegativeInRed``
    /// exists as a shorthand.
    public enum SectionColor: Sendable, Hashable, Codable {
        case black, blue, cyan, green, magenta, red, white, yellow
        case indexed(Int)

        /// Parses the inside of the brackets, case-insensitively. `nil` when it is not a colour.
        public init?(name: some StringProtocol) {
            let lowered = name.lowercased()
            switch lowered {
            case "black": self = .black
            case "blue": self = .blue
            case "cyan": self = .cyan
            case "green": self = .green
            case "magenta": self = .magenta
            case "red": self = .red
            case "white": self = .white
            case "yellow": self = .yellow
            default:
                guard lowered.hasPrefix("color") else { return nil }
                let digits = lowered.dropFirst(5).trimmingCharacters(in: .whitespaces)
                guard let index = Int(digits), index >= 1, index <= 56 else { return nil }
                self = .indexed(index)
            }
        }

        /// This colour as pixels. Indexed colours resolve through the legacy palette, where
        /// index 1 is entry 0.
        public func resolved(in palette: ColorPalette = .office) -> RGBAColor {
            switch self {
            case .black: RGBAColor.black
            case .blue: RGBAColor(red: 0, green: 0, blue: 255)
            case .cyan: RGBAColor(red: 0, green: 255, blue: 255)
            case .green: RGBAColor(red: 0, green: 255, blue: 0)
            case .magenta: RGBAColor(red: 255, green: 0, blue: 255)
            case .red: RGBAColor.red
            case .white: RGBAColor.white
            case .yellow: RGBAColor(red: 255, green: 255, blue: 0)
            case let .indexed(index): palette.indexed(index - 1)
            }
        }
    }

    /// A `[>=100]`-style guard.
    public struct Condition: Sendable, Hashable, Codable {
        /// The six comparisons a `[…]` guard can use. Excel allows no others — no `AND`, no
        /// ranges — which is why three sections is the practical limit for conditional formats.
        public enum Comparison: String, Sendable, Hashable, Codable, CaseIterable {
            case lessThan = "<"
            case lessThanOrEqual = "<="
            case equal = "="
            case notEqual = "<>"
            case greaterThan = ">"
            case greaterThanOrEqual = ">="
        }

        /// How the cell's value is compared against ``value``.
        public let comparison: Comparison
        /// The literal the condition compares against.
        public let value: Double

        public init(comparison: Comparison, value: Double) {
            self.comparison = comparison
            self.value = value
        }

        /// Parses the inside of the brackets. `nil` when it is not a condition.
        public init?(text: some StringProtocol) {
            let operators: [(String, Comparison)] = [
                ("<=", .lessThanOrEqual), (">=", .greaterThanOrEqual), ("<>", .notEqual),
                ("<", .lessThan), (">", .greaterThan), ("=", .equal),
            ]
            for (token, comparison) in operators where text.hasPrefix(token) {
                guard let parsed = Double(text.dropFirst(token.count).trimmingCharacters(in: .whitespaces)) else {
                    return nil
                }
                self.init(comparison: comparison, value: parsed)
                return
            }
            return nil
        }

        /// Whether `candidate` satisfies this condition.
        public func matches(_ candidate: Double) -> Bool {
            switch comparison {
            case .lessThan: candidate < value
            case .lessThanOrEqual: candidate <= value
            case .equal: candidate == value
            case .notEqual: candidate != value
            case .greaterThan: candidate > value
            case .greaterThanOrEqual: candidate >= value
            }
        }
    }
}

// MARK: - Number spec

extension NumberFormat {
    /// A currency symbol and which side of the number it sits on.
    public struct CurrencySpec: Sendable, Hashable, Codable {
        /// Which side of the digits the symbol sits on. Not a locale question — the format
        /// code says so, and the code is what round-trips.
        public enum Position: String, Sendable, Hashable, Codable { case leading, trailing }

        /// The symbol as written: `$`, `€`, `CHF`, or whatever `[$…]` contained.
        public let symbol: String
        /// See ``Position``.
        public let position: Position
        /// The LCID from `[$€-407]`, when the code used that form.
        public let localeID: Int?

        public init(symbol: String, position: Position, localeID: Int? = nil) {
            self.symbol = symbol
            self.position = position
            self.localeID = localeID
        }
    }

    /// A `# ?/?`-style fraction.
    public struct FractionSpec: Sendable, Hashable, Codable {
        /// Digits allowed in the denominator, for `?/?` and `??/??`.
        public let denominatorDigits: Int
        /// A literal denominator, for `?/16`. Mutually exclusive with a digit count.
        public let fixedDenominator: Int?

        public init(denominatorDigits: Int, fixedDenominator: Int? = nil) {
            self.denominatorDigits = denominatorDigits
            self.fixedDenominator = fixedDenominator
        }
    }

    /// Everything needed to turn a `Double` into digits.
    ///
    /// Apply ``scale`` **before** rounding to ``maximumFractionDigits``: `0.5` under `0%` is
    /// `50%`, not `1%`. That ordering is the most common way a formatter gets percentages wrong.
    public struct NumberSpec: Sendable, Hashable, Codable {
        /// Minimum digits left of the decimal point — the count of `0` placeholders there.
        /// `#,##0` is 1, so `0.5` renders as `1` and not `.5`.
        public let minimumIntegerDigits: Int
        /// Minimum digits right of the decimal point — the count of `0` placeholders there.
        public let minimumFractionDigits: Int
        /// Maximum digits right of the decimal point — every `0`, `#`, and `?` there.
        public let maximumFractionDigits: Int
        /// Fraction positions written as `?`, which pad with spaces rather than zeros so
        /// decimal points line up in a column.
        public let alignedFractionDigits: Int
        /// Whether the pattern groups thousands — a `,` between digit placeholders.
        public let usesThousandsSeparator: Bool
        /// Multiply the value by this before rendering. `100` per `%`, `0.001` per trailing
        /// comma, and both compose.
        public let scale: Double
        /// How many `%` signs the pattern has. They are also literal output.
        public let percentCount: Int
        /// Whether the pattern carries an `E+`/`E-` exponent.
        public let isScientific: Bool
        /// Digits in the exponent, for `0.00E+00`.
        public let exponentDigits: Int
        /// Whether the exponent always carries a sign (`E+`) or only when negative (`E-`).
        public let exponentAlwaysSigned: Bool
        /// Set when the pattern uses `/` to render a fraction rather than a decimal.
        public let fraction: FractionSpec?
        /// Set when a currency symbol was found, whether bracketed as `[$€-407]` or written
        /// literally. Also reflected in ``prefix`` or ``suffix``, so a renderer that only walks
        /// those still produces the right text.
        public let currency: CurrencySpec?
        /// Literal text before the first digit placeholder, currency symbol included.
        public let prefix: String
        /// Literal text after the last digit placeholder.
        public let suffix: String
        /// The character after a `*`, repeated to fill the cell's width.
        public let fillCharacter: String?
        /// Whether the pattern uses `_(` width-skipping, the giveaway for accounting formats.
        public let isAccounting: Bool

        init(
            minimumIntegerDigits: Int, minimumFractionDigits: Int, maximumFractionDigits: Int,
            alignedFractionDigits: Int, usesThousandsSeparator: Bool, scale: Double,
            percentCount: Int, isScientific: Bool, exponentDigits: Int, exponentAlwaysSigned: Bool,
            fraction: FractionSpec?, currency: CurrencySpec?, prefix: String, suffix: String,
            fillCharacter: String?, isAccounting: Bool
        ) {
            self.minimumIntegerDigits = minimumIntegerDigits
            self.minimumFractionDigits = minimumFractionDigits
            self.maximumFractionDigits = maximumFractionDigits
            self.alignedFractionDigits = alignedFractionDigits
            self.usesThousandsSeparator = usesThousandsSeparator
            self.scale = scale
            self.percentCount = percentCount
            self.isScientific = isScientific
            self.exponentDigits = exponentDigits
            self.exponentAlwaysSigned = exponentAlwaysSigned
            self.fraction = fraction
            self.currency = currency
            self.prefix = prefix
            self.suffix = suffix
            self.fillCharacter = fillCharacter
            self.isAccounting = isAccounting
        }
    }
}

// MARK: - Date spec

extension NumberFormat {
    /// How `AM/PM` is spelled in the pattern, which is also how it renders.
    public enum AmPmStyle: String, Sendable, Hashable, Codable, CaseIterable {
        /// `AM/PM`
        case upperLong
        /// `am/pm`
        case lowerLong
        /// `A/P`
        case upperShort
        /// `a/p`
        case lowerShort
    }

    /// One element of a date pattern, in render order.
    public enum DateToken: Sendable, Hashable, Codable {
        /// `yy` (2) or `yyyy` (4).
        case year(digits: Int)
        /// `m` (1) `mm` (2) `mmm` (3, abbreviated name) `mmmm` (4, full name) `mmmmm` (5, first letter).
        case month(digits: Int)
        /// `d` (1) `dd` (2) `ddd` (3, abbreviated weekday) `dddd` (4, full weekday).
        case day(digits: Int)
        case hour(digits: Int)
        case minute(digits: Int)
        case second(digits: Int)
        /// `[h]` — hours as a running total rather than wrapping at 24. Same for the others.
        case elapsedHours(digits: Int)
        case elapsedMinutes(digits: Int)
        case elapsedSeconds(digits: Int)
        /// The `.00` after a seconds token.
        case fractionalSeconds(digits: Int)
        case amPm(AmPmStyle)
        /// `g`/`gg`/`ggg` — Japanese era. Preserved so the code round-trips; we do not render it.
        case era(digits: Int)
        /// Anything not a pattern token: separators, quoted text, escaped characters.
        case literal(String)
    }

    /// A date pattern, resolved.
    public struct DateSpec: Sendable, Hashable, Codable {
        /// The pattern's tokens in order, literals included.
        public let tokens: [DateToken]
        /// Whether an `AM/PM` token is present, which also makes hours render 1–12.
        public let usesTwelveHourClock: Bool
        /// Whether any `[h]`-style elapsed token is present. Elapsed formats describe a
        /// duration, so the serial value is not a date at all and must not be converted to one.
        public let hasElapsedComponents: Bool
        /// Whether any year, month, day, or era token is present.
        public let hasDate: Bool
        /// Whether any hour, minute, second, or AM/PM token is present.
        public let hasTime: Bool
    }
}

// MARK: - Scanner

/// Left-to-right scan of one format section into atoms.
///
/// Separate from ``NumberFormat/Section`` so the bracket handling — which pulls colours,
/// conditions, locales, and currency symbols out of the same `[…]` syntax — lives in one place.
private struct FormatScanner {
    enum Atom {
        /// `0`, `#`, or `?`.
        case digit(Character)
        case decimalPoint
        /// A `,` between digit placeholders (grouping) or trailing (scaling).
        case comma
        case percent
        case exponent(signed: Bool)
        case fractionSlash
        /// A date pattern letter with its repeat count. `elapsed` for the `[h]` bracket form.
        case dateLetter(Character, count: Int, elapsed: Bool)
        case amPm(NumberFormat.AmPmStyle)
        case literal(String)
        case currency(String, localeID: Int?)
        case textPlaceholder
        /// `*x` — repeat `x` to fill the cell.
        case fill(Character)
        /// `_x` — a gap the width of `x`.
        case skipWidth(Character)
        case general
    }

    private let source: [Character]
    private var position = 0

    private(set) var color: NumberFormat.SectionColor?
    private(set) var condition: NumberFormat.Condition?
    private(set) var localeID: Int?
    private(set) var isWellFormed = true

    init(_ raw: some StringProtocol) {
        source = Array(raw)
    }

    mutating func scan() -> [Atom] {
        var atoms: [Atom] = []
        position = 0

        while position < source.count {
            let character = source[position]
            switch character {
            case "[":
                scanBracket(into: &atoms)
            case "\"":
                scanQuotedLiteral(into: &atoms)
            case "\\":
                position += 1
                if position < source.count {
                    atoms.append(.literal(String(source[position])))
                    position += 1
                } else {
                    isWellFormed = false
                }
            case "_":
                position += 1
                if position < source.count {
                    atoms.append(.skipWidth(source[position]))
                    position += 1
                } else {
                    isWellFormed = false
                }
            case "*":
                position += 1
                if position < source.count {
                    atoms.append(.fill(source[position]))
                    position += 1
                } else {
                    isWellFormed = false
                }
            case "0", "#", "?":
                atoms.append(.digit(character))
                position += 1
            case ".":
                atoms.append(.decimalPoint)
                position += 1
            case ",":
                atoms.append(.comma)
                position += 1
            case "%":
                atoms.append(.percent)
                position += 1
            case "/":
                atoms.append(.fractionSlash)
                position += 1
            case "E", "e":
                scanExponentOrLiteral(character, into: &atoms)
            case "y", "Y", "m", "M", "d", "D", "h", "H", "s", "S", "g", "G":
                scanDateRunOrGeneral(into: &atoms)
            case "A", "a", "P", "p":
                if !scanAmPm(into: &atoms) {
                    atoms.append(.literal(String(character)))
                    position += 1
                }
            case "@":
                atoms.append(.textPlaceholder)
                position += 1
            default:
                atoms.append(.literal(String(character)))
                position += 1
            }
        }
        return atoms
    }

    private mutating func scanBracket(into atoms: inout [Atom]) {
        guard let close = source[position...].firstIndex(of: "]") else {
            isWellFormed = false
            position = source.count
            return
        }
        let body = String(source[(position + 1) ..< close])
        position = close + 1

        if body.hasPrefix("$") {
            // `[$€-407]` — currency symbol, then an optional LCID.
            let rest = body.dropFirst()
            if let dash = rest.firstIndex(of: "-") {
                let symbol = String(rest[..<dash])
                localeID = Int(rest[rest.index(after: dash)...], radix: 16)
                if !symbol.isEmpty { atoms.append(.currency(symbol, localeID: localeID)) }
            } else if !rest.isEmpty {
                atoms.append(.currency(String(rest), localeID: nil))
            }
            return
        }
        if body.hasPrefix("-") {
            // `[-409]` — a bare locale hint.
            localeID = Int(body.dropFirst(), radix: 16)
            return
        }
        // `[h]`, `[mm]`, `[ss]` — elapsed time.
        let lowered = body.lowercased()
        if !lowered.isEmpty, lowered.allSatisfy({ $0 == "h" || $0 == "m" || $0 == "s" }),
           Set(lowered).count == 1, let letter = lowered.first {
            atoms.append(.dateLetter(letter, count: lowered.count, elapsed: true))
            return
        }
        if let parsed = NumberFormat.SectionColor(name: body) {
            color = parsed
            return
        }
        if let parsed = NumberFormat.Condition(text: body) {
            condition = parsed
            return
        }
        // Anything else in brackets is a modifier we do not model. Dropping it is correct:
        // the original code round-trips regardless.
    }

    private mutating func scanQuotedLiteral(into atoms: inout [Atom]) {
        position += 1
        var text = ""
        while position < source.count, source[position] != "\"" {
            text.append(source[position])
            position += 1
        }
        if position < source.count {
            position += 1
        } else {
            isWellFormed = false
        }
        if !text.isEmpty { atoms.append(.literal(text)) }
    }

    private mutating func scanExponentOrLiteral(_ character: Character, into atoms: inout [Atom]) {
        let next = position + 1 < source.count ? source[position + 1] : nil
        if next == "+" || next == "-" {
            atoms.append(.exponent(signed: next == "+"))
            position += 2
        } else {
            atoms.append(.literal(String(character)))
            position += 1
        }
    }

    /// Consumes a run of one date letter. `General` is spelled with `g`, so it is caught here.
    private mutating func scanDateRunOrGeneral(into atoms: inout [Atom]) {
        if matchesGeneral() {
            atoms.append(.general)
            position += 7
            return
        }
        let letter = FormatScanner.asciiLowercased(source[position])
        var count = 0
        while position < source.count, FormatScanner.asciiLowercased(source[position]) == letter {
            count += 1
            position += 1
        }
        atoms.append(.dateLetter(letter, count: count, elapsed: false))
    }

    /// `Character.lowercased()` can produce more than one scalar, and `Character(String)`
    /// traps when it does. Format codes are ASCII, so fold only that.
    private static func asciiLowercased(_ character: Character) -> Character {
        guard let ascii = character.asciiValue, ascii >= 65, ascii <= 90 else { return character }
        return Character(UnicodeScalar(ascii + 32))
    }

    private func matchesGeneral() -> Bool {
        guard position + 7 <= source.count else { return false }
        return String(source[position ..< (position + 7)]).lowercased() == "general"
    }

    /// `AM/PM` and `A/P`, in either case. Returns `false` when the text is something else
    /// starting with `a` or `p`.
    private mutating func scanAmPm(into atoms: inout [Atom]) -> Bool {
        let remaining = String(source[position...])
        if remaining.count >= 5 {
            let candidate = String(remaining.prefix(5))
            if candidate.uppercased() == "AM/PM" {
                atoms.append(.amPm(candidate.first == "A" ? .upperLong : .lowerLong))
                position += 5
                return true
            }
        }
        if remaining.count >= 3 {
            let candidate = String(remaining.prefix(3))
            if candidate.uppercased() == "A/P" {
                atoms.append(.amPm(candidate.first == "A" ? .upperShort : .lowerShort))
                position += 3
                return true
            }
        }
        return false
    }
}

// MARK: - Building the specs from atoms

extension NumberFormat.NumberSpec {
    fileprivate init(atoms: [FormatScanner.Atom]) {
        var minimumInteger = 0
        var minimumFraction = 0
        var maximumFraction = 0
        var alignedFraction = 0
        var grouping = false
        var trailingCommas = 0
        var percents = 0
        var scientific = false
        var exponentDigits = 0
        var exponentSigned = false
        var fractionDigits = 0
        var fixedDenominatorDigits = ""
        var sawSlash = false
        var currencySymbol: String?
        var currencyLocale: Int?
        var currencyLeading = true
        var prefix = ""
        var suffix = ""
        var fillCharacter: String?
        var accounting = false

        var seenDigit = false
        var afterDecimalPoint = false
        var afterExponent = false
        // A `,` only scales when it trails the last digit placeholder, so commas are counted
        // provisionally and discarded the moment another digit shows up.
        var pendingCommas = 0

        for atom in atoms {
            switch atom {
            case let .digit(character):
                if pendingCommas > 0, seenDigit, !afterDecimalPoint { grouping = true }
                pendingCommas = 0
                seenDigit = true
                if afterExponent {
                    exponentDigits += 1
                } else if sawSlash {
                    if character == "?" || character == "#" { fractionDigits += 1 }
                } else if afterDecimalPoint {
                    maximumFraction += 1
                    if character == "0" { minimumFraction += 1 }
                    if character == "?" { alignedFraction += 1 }
                } else if character == "0" {
                    minimumInteger += 1
                }
            case .decimalPoint:
                if seenDigit { afterDecimalPoint = true } else { prefix += "." }
            case .comma:
                if seenDigit { pendingCommas += 1 } else { prefix += "," }
            case .percent:
                percents += 1
                if seenDigit { suffix += "%" } else { prefix += "%" }
            case let .exponent(signed):
                scientific = true
                exponentSigned = signed
                afterExponent = true
            case .fractionSlash:
                sawSlash = true
            case let .literal(text):
                // Digits following the slash spell a literal denominator: `# ?/16`. They arrive
                // one atom at a time, so collect the run rather than reading only the first.
                if sawSlash, !text.isEmpty, text.allSatisfy(\.isNumber) {
                    fixedDenominatorDigits += text
                } else if seenDigit {
                    suffix += text
                } else {
                    prefix += text
                }
            case let .currency(symbol, locale):
                currencySymbol = symbol
                currencyLocale = locale
                currencyLeading = !seenDigit
                if seenDigit { suffix += symbol } else { prefix += symbol }
            case let .fill(character):
                fillCharacter = String(character)
                accounting = true
            case .skipWidth:
                accounting = true
            default:
                break
            }
        }

        trailingCommas = pendingCommas

        // A symbol that arrived as a plain literal rather than in `[$…]` still means currency.
        if currencySymbol == nil {
            let candidates = Set("$€£¥₹₽¢₩₪₫₺₴₦₱฿₡₲₵₸₼₾")
            if let symbol = prefix.last(where: { candidates.contains($0) }) {
                currencySymbol = String(symbol)
                currencyLeading = true
            } else if let symbol = suffix.first(where: { candidates.contains($0) }) {
                currencySymbol = String(symbol)
                currencyLeading = false
            }
        }

        self.init(
            minimumIntegerDigits: minimumInteger,
            minimumFractionDigits: minimumFraction,
            maximumFractionDigits: maximumFraction,
            alignedFractionDigits: alignedFraction,
            usesThousandsSeparator: grouping,
            scale: pow(100, Double(percents)) * pow(0.001, Double(trailingCommas)),
            percentCount: percents,
            isScientific: scientific,
            exponentDigits: exponentDigits,
            exponentAlwaysSigned: exponentSigned,
            fraction: sawSlash ? NumberFormat.FractionSpec(
                denominatorDigits: fractionDigits,
                fixedDenominator: Int(fixedDenominatorDigits)
            ) : nil,
            currency: currencySymbol.map {
                NumberFormat.CurrencySpec(
                    symbol: $0,
                    position: currencyLeading ? .leading : .trailing,
                    localeID: currencyLocale
                )
            },
            prefix: prefix,
            suffix: suffix,
            fillCharacter: fillCharacter,
            isAccounting: accounting
        )
    }
}

extension NumberFormat.DateSpec {
    fileprivate init(atoms: [FormatScanner.Atom]) {
        // First pass: turn atoms into tokens, leaving every `m` provisionally a month.
        var tokens: [NumberFormat.DateToken] = []
        var twelveHour = false
        var elapsed = false

        for (index, atom) in atoms.enumerated() {
            switch atom {
            case let .dateLetter(letter, count, isElapsed):
                if isElapsed { elapsed = true }
                switch letter {
                case "y":
                    tokens.append(.year(digits: count))
                case "d":
                    tokens.append(.day(digits: count))
                case "g":
                    tokens.append(.era(digits: count))
                case "h":
                    tokens.append(isElapsed ? .elapsedHours(digits: count) : .hour(digits: count))
                case "s":
                    tokens.append(isElapsed ? .elapsedSeconds(digits: count) : .second(digits: count))
                case "m":
                    tokens.append(isElapsed ? .elapsedMinutes(digits: count) : .month(digits: count))
                default:
                    tokens.append(.literal(String(letter)))
                }
            case let .amPm(style):
                twelveHour = true
                tokens.append(.amPm(style))
            case let .literal(text):
                tokens.append(.literal(text))
            case let .currency(symbol, _):
                tokens.append(.literal(symbol))
            case .decimalPoint:
                tokens.append(.literal("."))
            case .comma:
                tokens.append(.literal(","))
            case let .digit(character):
                // Digits inside a date pattern are the `.00` of fractional seconds, or stray
                // literals. Resolved in the fix-up pass below.
                tokens.append(.literal(String(character)))
            case let .skipWidth(character), let .fill(character):
                tokens.append(.literal(String(character)))
            case .percent:
                tokens.append(.literal("%"))
            case .fractionSlash:
                tokens.append(.literal("/"))
            case .textPlaceholder, .exponent, .general:
                _ = index
            }
        }

        NumberFormat.DateSpec.resolveMonthVersusMinute(in: &tokens)
        NumberFormat.DateSpec.foldFractionalSeconds(in: &tokens)

        var sawDate = false
        var sawTime = false
        for token in tokens {
            switch token {
            case .year, .month, .day, .era: sawDate = true
            case .hour, .minute, .second, .elapsedHours, .elapsedMinutes, .elapsedSeconds,
                 .fractionalSeconds, .amPm: sawTime = true
            case .literal: break
            }
        }

        self.init(
            tokens: tokens,
            usesTwelveHourClock: twelveHour,
            hasElapsedComponents: elapsed,
            hasDate: sawDate,
            hasTime: sawTime
        )
    }

    /// Rewrites months to minutes where position says so.
    ///
    /// An `m` is minutes when the nearest date token before it is an hour, or the nearest one
    /// after it is a second. Literals in between — the `:` in `h:mm` — do not break the
    /// association, which is exactly why this cannot be decided while scanning.
    private static func resolveMonthVersusMinute(in tokens: inout [NumberFormat.DateToken]) {
        func isTemporalNeighbour(_ token: NumberFormat.DateToken) -> Bool {
            if case .literal = token { return false }
            return true
        }

        for index in tokens.indices {
            guard case let .month(digits) = tokens[index] else { continue }
            // `mmm` and longer are always month names; only `m` and `mm` are ambiguous.
            guard digits <= 2 else { continue }

            var previous: NumberFormat.DateToken?
            var cursor = index - 1
            while cursor >= 0 {
                if isTemporalNeighbour(tokens[cursor]) { previous = tokens[cursor]
                    break
                }
                cursor -= 1
            }

            var next: NumberFormat.DateToken?
            cursor = index + 1
            while cursor < tokens.count {
                if isTemporalNeighbour(tokens[cursor]) { next = tokens[cursor]
                    break
                }
                cursor += 1
            }

            let followsHour = switch previous {
            case .hour, .elapsedHours: true
            default: false
            }
            let precedesSecond = switch next {
            case .second, .elapsedSeconds: true
            default: false
            }

            if followsHour || precedesSecond {
                tokens[index] = .minute(digits: digits)
            }
        }
    }

    /// Turns `ss` followed by a literal `.` and zeros into a fractional-seconds token.
    private static func foldFractionalSeconds(in tokens: inout [NumberFormat.DateToken]) {
        var index = 0
        while index < tokens.count {
            guard case .second = tokens[index], index + 1 < tokens.count,
                  case .literal(".") = tokens[index + 1]
            else {
                index += 1
                continue
            }
            var digits = 0
            var cursor = index + 2
            while cursor < tokens.count, case let .literal(text) = tokens[cursor], text == "0" {
                digits += 1
                cursor += 1
            }
            guard digits > 0 else {
                index += 1
                continue
            }
            tokens.replaceSubrange((index + 1) ..< cursor, with: [.fractionalSeconds(digits: digits)])
            index += 2
        }
    }
}

// MARK: - Built-in formats

extension NumberFormat {
    /// The implicit format codes for ids 0–49, which never appear in a file.
    ///
    /// Excel assumes every reader already knows them, so a cell with `numFmtId="2"` and no
    /// matching `<numFmt>` element means `0.00`. A reader that does not carry this table
    /// renders every built-in format as `General`, which looks like "all my dates turned into
    /// numbers" — a very common first bug.
    ///
    /// Ids 23–36 and 50–58 are locale-specific East Asian formats and are deliberately absent:
    /// guessing them produces confidently wrong dates. They fall through to `General`, and
    /// their `numFmtId` still round-trips.
    public static func builtInCode(id: Int32) -> String? {
        switch id {
        case 0: "General"
        case 1: "0"
        case 2: "0.00"
        case 3: "#,##0"
        case 4: "#,##0.00"
        case 5: "\"$\"#,##0_);(\"$\"#,##0)"
        case 6: "\"$\"#,##0_);[Red](\"$\"#,##0)"
        case 7: "\"$\"#,##0.00_);(\"$\"#,##0.00)"
        case 8: "\"$\"#,##0.00_);[Red](\"$\"#,##0.00)"
        case 9: "0%"
        case 10: "0.00%"
        case 11: "0.00E+00"
        case 12: "# ?/?"
        case 13: "# ??/??"
        case 14: "mm-dd-yy"
        case 15: "d-mmm-yy"
        case 16: "d-mmm"
        case 17: "mmm-yy"
        case 18: "h:mm AM/PM"
        case 19: "h:mm:ss AM/PM"
        case 20: "h:mm"
        case 21: "h:mm:ss"
        case 22: "m/d/yy h:mm"
        case 37: "#,##0 ;(#,##0)"
        case 38: "#,##0 ;[Red](#,##0)"
        case 39: "#,##0.00 ;(#,##0.00)"
        case 40: "#,##0.00 ;[Red](#,##0.00)"
        case 41: "_(* #,##0_);_(* (#,##0);_(* \"-\"_);_(@_)"
        case 42: "_(\"$\"* #,##0_);_(\"$\"* (#,##0);_(\"$\"* \"-\"_);_(@_)"
        case 43: "_(* #,##0.00_);_(* (#,##0.00);_(* \"-\"??_);_(@_)"
        case 44: "_(\"$\"* #,##0.00_);_(\"$\"* (#,##0.00);_(\"$\"* \"-\"??_);_(@_)"
        case 45: "mm:ss"
        case 46: "[h]:mm:ss"
        case 47: "mmss.0"
        case 48: "##0.0E+0"
        case 49: "@"
        default: nil
        }
    }

    /// The ids Excel reserves for built-in formats. A custom `<numFmt>` must use an id at or
    /// above 164; anything lower that appears in a file is a producer bug.
    public static let firstCustomFormatID: Int32 = 164
}

extension NumberFormat: CustomStringConvertible {
    public var description: String { "NumberFormat(\(formatCode), \(kind.rawValue))" }
}
