import Foundation

/// Every hard cap in OpenSheets, in one place, with the reason it exists.
///
/// Two different kinds of number live here and it matters which is which:
///
/// - **Format limits** (`maxRow`, `maxColumn`, `maxSheetNameLength`) come from the xlsx
///   specification. Exceeding one means the file cannot be written back, so they are
///   correctness boundaries, not tuning knobs.
/// - **Defence limits** (`maxDecompressedBytes`, `maxCompressionRatio`, `maxArchiveEntries`,
///   the XML caps) exist because a spreadsheet is untrusted input (PLAN.md §7.4). A hostile
///   `.xlsx` is a zip bomb with a file extension. These are tuned to be generous for real
///   files and fatal for attacks, and every one of them has a matching `SheetError` case.
///
/// Row and column indices are **0-based** throughout OpenSheets; A1 strings appear only at
/// boundaries. So `maxRow` is 1,048,575 and `rowCount` is 1,048,576 — read the names carefully.
public enum Limits {
    // MARK: - Grid geometry (xlsx format limits)

    /// Highest addressable row index, 0-based. Row 1,048,576 in A1 notation.
    public static let maxRow = 1_048_575

    /// Highest addressable column index, 0-based. Column `XFD` in A1 notation.
    public static let maxColumn = 16_383

    /// Total addressable rows. Use this as an exclusive upper bound.
    public static let rowCount = 1_048_576

    /// Total addressable columns. Use this as an exclusive upper bound.
    public static let columnCount = 16_384

    /// The whole addressable grid, `A1:XFD1048576`.
    public static let entireSheet = CellRange(
        start: CellRef(row: 0, column: 0),
        end: CellRef(row: maxRow, column: maxColumn)
    )

    // MARK: - Content limits (xlsx format limits)

    /// Excel truncates sheet names at 31 characters and so must we, or the file won't open.
    public static let maxSheetNameLength = 31

    /// Characters Excel forbids in a sheet name. A leading or trailing apostrophe is also
    /// forbidden but is a positional rule, so it lives in ``validateSheetName(_:)``.
    public static let forbiddenSheetNameCharacters: Set<Character> = ["[", "]", ":", "*", "?", "/", "\\"]

    /// Longest string a single cell can hold. PLAN.md §9 lists a 32k-character cell as a case
    /// we must handle rather than crash on; this is where "handle" is defined.
    public static let maxCellTextLength = 32_767

    /// Longest formula source text, excluding the leading `=`.
    public static let maxFormulaLength = 8192

    /// Deepest nesting of function calls in one formula. Excel's own limit is 64; matching it
    /// means a formula we accept is a formula Excel accepts.
    public static let maxFormulaNestingDepth = 64

    /// Sheets per workbook. Excel has no documented cap; this one exists so a malformed
    /// `workbook.xml` cannot make us allocate forever.
    public static let maxSheets = 10_000

    /// Defined names per workbook.
    public static let maxDefinedNames = 65_536

    // MARK: - Archive hardening (PLAN.md §7.4)

    /// Total bytes we will ever inflate out of one archive. A zip bomb's whole trick is that
    /// a 40 KB file expands to petabytes; this is the number that stops it.
    public static let maxDecompressedBytes = 500 * 1024 * 1024

    /// Bytes a single entry may inflate to. Catches the bomb that hides in one entry rather
    /// than spreading across many.
    public static let maxEntryDecompressedBytes = 200 * 1024 * 1024

    /// Compressed-to-uncompressed ratio a single entry may claim or achieve. Real XML
    /// compresses around 10:1; 100:1 is comfortably above anything legitimate.
    public static let maxCompressionRatio: Double = 100

    /// Entries per archive. A real `.xlsx` has tens; a thousand means charts and images.
    public static let maxArchiveEntries = 10_000

    /// How deep a nested archive may go. An `.xlsx` legitimately embeds an `.xlsx` only inside
    /// OLE objects, which we pass through without opening — so anything past the first level
    /// is an attack.
    public static let maxNestedArchiveDepth = 1

    /// Largest file we will open at all, before looking inside it.
    public static let maxFileBytes = 2 * 1024 * 1024 * 1024

    // MARK: - XML hardening (PLAN.md §7.4)

    /// Element nesting depth. "100k-deep XML nesting" is in the hostile corpus; this stops it
    /// before it becomes a stack overflow.
    public static let maxXMLDepth = 256

    /// Attributes on a single element.
    public static let maxXMLAttributesPerElement = 256

    /// Longest single XML attribute value or text node we will accumulate.
    public static let maxXMLTokenBytes = 10 * 1024 * 1024

    // MARK: - Sync and persistence (PLAN.md §5.5, §6.1)

    /// Cell changes a single `SheetDiff` will list before it starts counting instead of
    /// collecting. The diff panel cannot show 100,000 rows anyway, and an unbounded array
    /// here turns a big external edit into a hang.
    public static let maxDiffCellChanges = 5000

    /// Snapshots kept per file, oldest evicted first.
    public static let maxSnapshotsPerFile = 20

    /// Total disk the snapshot store may occupy across all files.
    public static let maxSnapshotStoreBytes = 500 * 1024 * 1024

    /// Debounce before reacting to a filesystem event. Writers emit bursts; reacting to the
    /// first one means reading a half-written file.
    public static let watcherDebounce: Duration = .milliseconds(150)

    /// How long a self-write fingerprint suppresses events. Long enough to cover our own
    /// write, short enough that a genuine external write right after ours is not swallowed.
    public static let selfWriteFingerprintLifetime: Duration = .seconds(5)

    // MARK: - Display defaults

    /// Default row height in points at 100% zoom. Excel's 15pt is cramped on Retina (PLAN.md §3.4).
    public static let defaultRowHeight: Double = 24

    /// Default column width in points at 100% zoom. Excel stores widths in "characters of the
    /// normal font", which is producer-dependent; we normalise to points at parse time.
    public static let defaultColumnWidth: Double = 76

    // MARK: - Predicates

    /// Whether `row` is an addressable 0-based row index.
    public static func isValidRow(_ row: Int) -> Bool {
        row >= 0 && row <= maxRow
    }

    /// Whether `column` is an addressable 0-based column index.
    public static func isValidColumn(_ column: Int) -> Bool {
        column >= 0 && column <= maxColumn
    }

    /// Throws unless `name` is a sheet name Excel will accept: non-empty, at most 31
    /// characters, none of ``forbiddenSheetNameCharacters``, and no leading or trailing
    /// apostrophe (which would break `'My Sheet'!A1` quoting).
    ///
    /// Deliberately *not* checked here: uniqueness. That needs the whole workbook, so it
    /// lives in ``Workbook/validate()``.
    public static func validateSheetName(_ name: String) throws(SheetError) {
        if name.isEmpty {
            throw SheetError.invalidSheetName(name: name, reason: "a sheet name cannot be empty")
        }
        if name.count > maxSheetNameLength {
            throw SheetError.invalidSheetName(
                name: name,
                reason: "a sheet name may be at most \(maxSheetNameLength) characters, this one is \(name.count)"
            )
        }
        if let bad = name.first(where: { forbiddenSheetNameCharacters.contains($0) }) {
            throw SheetError.invalidSheetName(name: name, reason: "'\(bad)' is not allowed in a sheet name")
        }
        if name.hasPrefix("'") || name.hasSuffix("'") {
            throw SheetError.invalidSheetName(name: name, reason: "a sheet name cannot start or end with an apostrophe")
        }
        if name.caseInsensitiveCompare("History") == .orderedSame {
            throw SheetError.invalidSheetName(name: name, reason: "'History' is reserved by Excel")
        }
    }
}
