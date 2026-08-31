import Foundation
import FoundationModels
import SheetMCP
import SheetModel

/// The three tools the on-device model gets. Three, not the MCP's twenty-five, on purpose.
///
/// The system model is a ~3B-parameter device model with a context window in the low thousands
/// of tokens, and every tool's name, description and schema is spent from that window before the
/// user has typed a word. Twenty-five tools would drown it. Read, write, find is the irreducible
/// set for "chat with the sheet that is open": everything else the MCP offers — workspace
/// listing, snapshots, file lifecycle — is either meaningless inside the app or belongs to the
/// user's own UI.
///
/// Two contracts are inherited from the MCP surface so the app's two agent doors behave alike:
/// **cell text leaves inside the untrusted envelope** (`UntrustedContent`, PLAN.md §7.3), and
/// **a failed operation is a sentence, not a thrown error** — a throw here aborts the whole
/// respond call, while a returned "Error: …" lets the model read the problem and try a corrected
/// range, which is what it reliably does.
///
/// Every cap in this file (`ChatToolLimits`) is a token budget, not a safety budget — safety
/// caps live behind the `ChatDocument` implementation.
public enum ChatToolLimits {
    /// Rows × columns a single read returns. 30×8 of short cells is roughly 500 tokens, which
    /// leaves room in the window for the answer that reads them.
    public static let readRows = 30
    public static let readColumns = 8
    /// Inline cap per cell, well under the envelope's own 200: one essay-length cell must not
    /// evict the rest of the table from the model's context.
    public static let cellCharacters = 80
    /// Edits per call. Enough for a header row plus a formula column; small enough that a
    /// runaway generation cannot rewrite a sheet.
    public static let editsPerCall = 40
    public static let findMatches = 20
}

// MARK: - read_cells

/// `read_cells` — the values the user is looking at, as a labelled TSV window.
public struct ReadCellsTool: Tool {
    public let name = "read_cells"
    public let description = """
    Read cell values from the open spreadsheet. Returns rows of tab-separated display values \
    with row numbers and column letters. Large ranges are truncated; read narrower ranges.
    """

    @Generable
    public struct Arguments: Sendable {
        @Guide(description: "A1 range to read, e.g. \"B2:D20\" or \"Sales!A1:C10\".")
        public var range: String

        public init(range: String) {
            self.range = range
        }
    }

    let document: any ChatDocument

    public init(document: any ChatDocument) {
        self.document = document
    }

    public func call(arguments: Arguments) async throws -> String {
        // Validated here, not just in the document: the fake in the tests holds this contract
        // too, and the model deserves the correction even when the document would also refuse.
        let parsed = A1Notation.split(arguments.range.trimmingCharacters(in: .whitespaces))
        guard let parsed, CellRange(a1: parsed.rangeText.uppercased()) != nil else {
            return "Error: \"\(UntrustedContent.inlineCell(arguments.range))\" is not an A1 range. Use a form like B2:D20."
        }
        do {
            let slice = try await document.readRange(
                sheetName: parsed.sheetName,
                rangeA1: parsed.rangeText,
                maxRows: ChatToolLimits.readRows,
                maxColumns: ChatToolLimits.readColumns
            )
            return ChatToolText.rendered(slice)
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }
}

// MARK: - write_cells

/// `write_cells` — the one door edits come through.
public struct WriteCellsTool: Tool {
    public let name = "write_cells"
    public let description = """
    Write values or formulas into cells of the open spreadsheet. Content starting with '=' is a \
    formula. Only use this when the user asked for a change. The user can undo it with one ⌘Z.
    """

    @Generable
    public struct Arguments: Sendable {
        @Generable
        public struct Edit: Sendable {
            @Guide(description: "The cell to write, e.g. \"F7\".")
            public var ref: String
            @Guide(
                description: "The new content: text, a number, or a formula starting with '='. Empty clears the cell."
            )
            public var content: String

            public init(ref: String, content: String) {
                self.ref = ref
                self.content = content
            }
        }

        @Guide(description: "The cells to write.")
        public var edits: [Edit]

        public init(edits: [Edit]) {
            self.edits = edits
        }
    }

    let document: any ChatDocument

    public init(document: any ChatDocument) {
        self.document = document
    }

    public func call(arguments: Arguments) async throws -> String {
        guard !arguments.edits.isEmpty else { return "Error: no edits given." }
        guard arguments.edits.count <= ChatToolLimits.editsPerCall else {
            return "Error: at most \(ChatToolLimits.editsPerCall) cells per call; split the change up."
        }
        // A sheet-qualified ref on any edit picks the sheet for the whole batch — one batch is
        // one undo step, and an undo step that spans sheets is not a thing the stack models.
        var sheetName: String?
        var edits: [ChatCellEdit] = []
        for edit in arguments.edits {
            guard let split = A1Notation.split(edit.ref.trimmingCharacters(in: .whitespaces)) else {
                return "Error: \"\(UntrustedContent.inlineCell(edit.ref))\" is not a cell reference."
            }
            if let named = split.sheetName {
                if let sheetName, sheetName != named {
                    return "Error: one write_cells call edits one sheet; \(UntrustedContent.inlineCell(named)) and \(UntrustedContent.inlineCell(sheetName)) were both named."
                }
                sheetName = named
            }
            edits.append(ChatCellEdit(refA1: split.rangeText, content: edit.content))
        }
        do {
            let outcome = try await document.applyEdits(edits, sheetName: sheetName)
            return ChatToolText.rendered(outcome)
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }
}

// MARK: - find_cells

/// `find_cells` — where something is, not what it says. References are cheap; contents are not.
public struct FindCellsTool: Tool {
    public let name = "find_cells"
    public let description = """
    Find cells whose value or formula contains the given text. Returns cell references like \
    Sales!B7. Use read_cells afterwards to see the values.
    """

    @Generable
    public struct Arguments: Sendable {
        @Guide(description: "The text to search for, case-insensitive.")
        public var query: String

        public init(query: String) {
            self.query = query
        }
    }

    let document: any ChatDocument

    public init(document: any ChatDocument) {
        self.document = document
    }

    public func call(arguments: Arguments) async throws -> String {
        let query = arguments.query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return "Error: empty search text." }
        let result = await document.find(query, maxMatches: ChatToolLimits.findMatches)
        return ChatToolText.rendered(result)
    }
}

// MARK: - Rendering

/// Tool results as text, in one place so the tests can pin the exact shape the model sees.
enum ChatToolText {
    /// ```
    /// <untrusted-spreadsheet-content sheet="Sales">
    /// Sales!B2:D6
    ///     B   C   D
    /// 2   Region  Units   Revenue
    /// …
    /// </untrusted-spreadsheet-content>
    /// ```
    /// Same shape as the MCP's compact `read_range` — row numbers make the window addressable,
    /// and an agent that spots a bad value needs the row, not the line number of the output.
    static func rendered(_ slice: ChatRangeSlice) -> String {
        var lines: [String] = []
        lines.append("\(A1Notation.quoteIfNeeded(slice.sheetName))!\(slice.rangeA1)")
        lines.append("\t" + slice.columnLetters.joined(separator: "\t"))
        for row in slice.rows {
            let cells = row.cells
                .map { UntrustedContent.inlineCell($0, limit: ChatToolLimits.cellCharacters) }
                .joined(separator: "\t")
            lines.append("\(row.number)\t\(cells)")
        }
        var notes: [String] = []
        if slice.truncatedRowCount > 0 {
            notes.append("\(slice.truncatedRowCount) more rows not shown")
        }
        if slice.truncatedColumnCount > 0 {
            notes.append("\(slice.truncatedColumnCount) more columns not shown")
        }
        if !notes.isEmpty {
            lines.append("… " + notes.joined(separator: "; ") + "; read a narrower range for the rest")
        }
        return UntrustedContent.wrap(
            lines.joined(separator: "\n"),
            sheet: slice.sheetName,
            note: notes.isEmpty ? nil : "truncated"
        )
    }

    /// `Wrote 3 cells (A1:B3).` — plus every refusal, verbatim, because a swallowed refusal
    /// becomes the model telling the user a change happened that did not.
    static func rendered(_ outcome: ChatEditOutcome) -> String {
        var lines: [String] = []
        if outcome.appliedCount > 0 {
            let range = outcome.appliedRangeA1.map { " (\($0))" } ?? ""
            lines.append("Wrote \(outcome.appliedCount) cell\(outcome.appliedCount == 1 ? "" : "s")\(range).")
        } else {
            lines.append("Nothing was written.")
        }
        for refusal in outcome.refusals {
            lines.append("Refused \(refusal)")
        }
        return lines.joined(separator: "\n")
    }

    static func rendered(_ result: ChatFindResult) -> String {
        guard !result.matches.isEmpty else { return "No cells match." }
        var lines = result.matches.map { match in
            "\(A1Notation.quoteIfNeeded(match.sheetName))!\(match.refA1)"
        }
        if result.truncated {
            lines.append("… more matches exist; narrow the search")
        }
        // Sheet names are user- or file-authored text, so the list is wrapped like any other
        // cell-derived output even though the references themselves are structural.
        return UntrustedContent.wrap(lines.joined(separator: "\n"))
    }
}
