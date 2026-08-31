import Foundation
import FoundationModels
import SheetMCP
import SheetModel

/// The six tools the on-device model gets. Six, not the MCP's twenty-five, on purpose.
///
/// The system model is a ~3B-parameter device model with a context window in the low thousands
/// of tokens, and every tool's name, description and schema is spent from that window before the
/// user has typed a word. Twenty-five tools would drown it. Read, write, find, calculate,
/// append, transform is the set for "chat with the sheet that is open" — the last three earned
/// their slots by watching the model fail without them — and everything else the MCP offers is
/// either meaningless inside the app or belongs to the user's own UI.
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
    // Every description below is spent from the model's ~4k-token window on every single
    // message, before the user has typed a word — six fat descriptions were watched pushing a
    // real turn over the edge. One sentence each; the war stories live in the doc comments.
    public let description = "Read cell values from a range of the open sheet."

    @Generable
    public struct Arguments: Sendable {
        @Guide(description: "A1 range, e.g. \"B2:D20\".")
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
        ChatLog.tools.info("read_cells called: \(arguments.range, privacy: .public)")
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
            ChatLog.tools
                .info(
                    "read_cells \(arguments.range, privacy: .public) → \(slice.rows.count, privacy: .public) rows, truncated \(slice.truncatedRowCount, privacy: .public)r/\(slice.truncatedColumnCount, privacy: .public)c"
                )
            let rendered = ChatToolText.rendered(slice)
            ChatLog.payload(ChatLog.tools, "read_cells result", rendered)
            return rendered
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }
}

// MARK: - write_cells

/// `write_cells` — the one door edits come through.
public struct WriteCellsTool: Tool {
    public let name = "write_cells"
    public let description = "Write values or formulas ('=…') into specific cells the user asked to change."

    @Generable
    public struct Arguments: Sendable {
        @Generable
        public struct Edit: Sendable {
            @Guide(description: "The cell, e.g. \"F7\".")
            public var ref: String
            @Guide(description: "Text, a number, or a formula starting with '='.")
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
        ChatLog.tools.info("write_cells called: \(arguments.edits.count, privacy: .public) edits")
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
            ChatLog.tools
                .info(
                    "write_cells \(edits.count, privacy: .public) in → \(outcome.appliedCount, privacy: .public) applied (\(outcome.appliedRangeA1 ?? "—", privacy: .public)), \(outcome.refusals.count, privacy: .public) refused"
                )
            ChatLog.payload(
                ChatLog.tools,
                "write_cells edits",
                edits.map { "\($0.refA1)=\($0.content)" }.joined(separator: " · ")
            )
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
    public let description = "Find cells containing the given text; returns references like B7."

    @Generable
    public struct Arguments: Sendable {
        @Guide(description: "Text to search for.")
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
        ChatLog.tools.info("find_cells called")
        let query = arguments.query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return "Error: empty search text." }
        let result = await document.find(query, maxMatches: ChatToolLimits.findMatches)
        ChatLog.tools
            .info(
                "find_cells → \(result.matches.count, privacy: .public) matches, truncated \(result.truncated, privacy: .public)"
            )
        ChatLog.payload(ChatLog.tools, "find_cells query", query)
        return ChatToolText.rendered(result)
    }
}

// MARK: - append_rows

/// `append_rows` — adding data with no reference to get wrong, and no loop to give up on.
///
/// Two live failures shaped this tool, preserved here so nobody optimises them away. First:
/// asked to "add a region", the model overwrote the A1 header and dropped cells next to the
/// user's selection — reference-picking for new rows is pure inference, so the document picks
/// the rows and columns. Second: as a one-row-per-call tool, "add 20 regions" meant twenty
/// calls, and the model made a few and narrated twenty — a ~3B model does not loop reliably,
/// so the batch travels in one call, lands as one undo step, and the result names exactly
/// which rows exist now.
public struct AppendRowsTool: Tool {
    public let name = "append_rows"
    public let description = "Add rows below the data. Pass ALL requested rows in this ONE call."

    /// Rows per call. Generous enough for "add 20 regions" twice over; small enough that a
    /// runaway generation cannot pave the sheet.
    public static let rowsPerCall = 40

    @Generable
    public struct Arguments: Sendable {
        @Generable
        public struct Row: Sendable {
            @Guide(
                description: "One value per column, in order, e.g. [\"North\", \"120\", \"162005\"]. Use \"\" to leave a column blank."
            )
            public var values: [String]

            public init(values: [String]) {
                self.values = values
            }
        }

        @Guide(description: "Every row to add — 20 rows means 20 entries here.")
        public var rows: [Row]

        public init(rows: [Row]) {
            self.rows = rows
        }
    }

    let document: any ChatDocument

    public init(document: any ChatDocument) {
        self.document = document
    }

    public func call(arguments: Arguments) async throws -> String {
        ChatLog.tools.info("append_rows called: \(arguments.rows.count, privacy: .public) rows")
        guard !arguments.rows.isEmpty else { return "Error: no rows given." }
        guard arguments.rows.count <= Self.rowsPerCall else {
            return "Error: at most \(Self.rowsPerCall) rows per call; add the rest in a second call."
        }
        if arguments.rows.contains(where: { $0.values.count > ChatToolLimits.readColumns * 2 }) {
            return "Error: at most \(ChatToolLimits.readColumns * 2) columns per row."
        }
        do {
            let outcome = try await document.appendRows(arguments.rows.map(\.values))
            ChatLog.tools
                .info(
                    "append_rows \(arguments.rows.count, privacy: .public) rows in → rows \(outcome.firstRow, privacy: .public)+\(outcome.rowCount, privacy: .public), \(outcome.appliedCount, privacy: .public) cells, \(outcome.refusals.count, privacy: .public) refused"
                )
            ChatLog.payload(
                ChatLog.tools,
                "append_rows values",
                arguments.rows.map { $0.values.joined(separator: "|") }.joined(separator: " ; ")
            )
            let lastRow = outcome.firstRow + outcome.rowCount - 1
            var lines = [outcome.rowCount == 1
                ? "Appended row \(outcome.firstRow) (\(outcome.appliedCount) cells)."
                :
                "Appended rows \(outcome.firstRow)–\(lastRow) (\(outcome.rowCount) rows, \(outcome.appliedCount) cells)."]
            for refusal in outcome.refusals {
                lines.append("Refused \(refusal)")
            }
            return lines.joined(separator: "\n")
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }
}

// MARK: - transform_cells

/// `transform_cells` — bulk edits as a rule, not as arithmetic.
///
/// The fourth live failure: "change all revenue to be in the billions" needs nine divisions,
/// so the model — which cannot divide — called the read-only calculator and narrated a
/// conversion while the grid sat unchanged. Here it states the rule once (`x / 1000000000`);
/// the document substitutes every cell's reference for `x`, computes with the engine, and
/// writes the results as one undo step.
public struct TransformCellsTool: Tool {
    public let name = "transform_cells"
    public let description = "Change every cell in a range by one rule of x (each cell's current value), e.g. x / 1000."

    @Generable
    public struct Arguments: Sendable {
        @Guide(description: "A1 range to change, e.g. \"C2:C10\".")
        public var range: String
        @Guide(description: "The rule, using x as the current value, e.g. \"x / 1000\".")
        public var formula: String

        public init(range: String, formula: String) {
            self.range = range
            self.formula = formula
        }
    }

    let document: any ChatDocument

    public init(document: any ChatDocument) {
        self.document = document
    }

    public func call(arguments: Arguments) async throws -> String {
        ChatLog.tools
            .info(
                "transform_cells called: range \(arguments.range, privacy: .public), rule \(arguments.formula, privacy: .public)"
            )
        var formula = arguments.formula.trimmingCharacters(in: .whitespaces)
        if formula.hasPrefix("=") {
            formula = String(formula.dropFirst())
        }
        let parsed = A1Notation.split(arguments.range.trimmingCharacters(in: .whitespaces))
        if !formula.contains(/\b[xX]\b/) {
            // The model was watched writing the rule as a formula for the range's FIRST cell —
            // "=C2*1000000000" for C2:C10 — which is exactly Excel's fill-down mental model,
            // and then retrying that identical call every second, forever, against a rejection
            // it cannot learn from mid-turn. Be liberal: the first cell's own reference means x.
            var rewritten: String?
            if let rangeText = parsed?.rangeText,
               let range = CellRange(a1: rangeText.uppercased()),
               let refToken = try? Regex("\\b\(range.start.a1String)\\b").ignoresCase() {
                let candidate = formula.replacing(refToken, with: "x")
                if candidate.contains(/\b[xX]\b/) {
                    rewritten = candidate
                }
            }
            guard let accepted = rewritten else {
                return "Error: write the rule using x for each cell's current value, e.g. \"x / 1000\"."
            }
            formula = accepted
        }
        do {
            let outcome = try await document.transformCells(
                range: parsed?.rangeText ?? arguments.range, sheetName: parsed?.sheetName, expression: formula
            )
            ChatLog.tools
                .info(
                    "transform_cells \(arguments.range, privacy: .public) by \(formula, privacy: .public) → \(outcome.appliedCount, privacy: .public) applied (\(outcome.appliedRangeA1 ?? "—", privacy: .public)), \(outcome.refusals.count, privacy: .public) refused"
                )
            return ChatToolText.rendered(outcome)
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }
}

// MARK: - calculate

/// `calculate` — the model's calculator, because it does not have one of its own.
///
/// This tool exists because of one live failure, preserved here so nobody optimises it away:
/// asked for a column's total, the on-device model summed six numbers in its head, got it
/// wrong, and then **wrote the wrong answer into a cell** so it would have something to point
/// at. A ~3B model reliably knows *that* it should total a column and reliably cannot do the
/// totalling. Playing to that: any arithmetic becomes a formula, the app's own engine computes
/// it against the live workbook, and nothing is written anywhere.
public struct CalculateTool: Tool {
    public let name = "calculate"
    public let description = "Compute a formula and return the result, changing nothing. Use for ALL arithmetic."

    @Generable
    public struct Arguments: Sendable {
        @Guide(description: "The formula, e.g. \"=SUM(C2:C7)\".")
        public var formula: String

        public init(formula: String) {
            self.formula = formula
        }
    }

    let document: any ChatDocument

    public init(document: any ChatDocument) {
        self.document = document
    }

    public func call(arguments: Arguments) async throws -> String {
        ChatLog.tools.info("calculate called: \(arguments.formula, privacy: .public)")
        let formula = arguments.formula.trimmingCharacters(in: .whitespaces)
        guard !formula.isEmpty else { return "Error: empty formula." }
        do {
            let result = try await document.evaluate(formula)
            ChatLog.tools.info("calculate result ready")
            ChatLog.payload(ChatLog.tools, "calculate result", result)
            // `=A1` computes to whatever text A1 holds, so a result is cell-derived data like
            // any read — enveloped, even though it is usually just a number.
            return UntrustedContent.wrap(
                "\(UntrustedContent.inlineCell(formula)) = \(UntrustedContent.inlineCell(result))"
            )
        } catch {
            return "Error: \(error.localizedDescription)"
        }
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
