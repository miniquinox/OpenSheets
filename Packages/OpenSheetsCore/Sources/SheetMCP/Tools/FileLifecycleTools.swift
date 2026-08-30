import Foundation
import SheetModel
import SheetStore

/// `new_workbook`, `delete_file`, `open_in_app` — the file's lifecycle, from creation to the
/// Trash, plus the one tool that puts it on the user's screen.
///
/// # Why these are one file
///
/// The three tools share a discipline the rest of the surface only needs implicitly: each one's
/// **first act on `path` is the grant check**, before any stat, any snapshot, any request file
/// and — for `open_in_app` — before the launcher closure. Creation and deletion are the two
/// operations where "does the file exist" is part of the answer, which is exactly the question
/// an ungranted caller must not be able to ask; keeping them together keeps the ordering rule
/// in one reviewer's field of view.
///
/// The safety posture, stated once:
///
/// - `new_workbook` **never overwrites**. `write_range` remains the only mutation path for
///   existing bytes.
/// - `delete_file` is double-recoverable — a snapshot first, then the Trash — and never
///   hard-deletes.
/// - `open_in_app` is the server's first and only subprocess, and it is scoped to the bone: the
///   executable is the literal `/usr/bin/open`, the bundle id is a constant, the only variable
///   argument is a path that has already passed the grant check, no shell is involved, and the
///   child's stdio goes to `/dev/null` explicitly (fd 1 is the protocol stream — `claimStdout`
///   protects it, but the child does not get the chance to test that). See
///   ``AppHandshake/systemLaunch``.
public enum FileLifecycleTools {
    // MARK: - new_workbook

    /// The most sheets one call may create. Generous for any real workbook, and small enough
    /// that a runaway argument cannot ask this process to materialise a hundred thousand
    /// `Sheet` values before the write is even attempted.
    static let maximumSheetsPerCreate = 255

    public static let newWorkbook = ToolDefinition(
        schema: ToolSchema(
            name: "new_workbook",
            title: "Create a workbook",
            summary: """
            Creates a new workbook file — the way to start a spreadsheet from scratch, and the \
            answer to add_sheet's refusal: instead of mutating an existing package's sheet \
            list, generate a fresh file with the sheets you need. Refuses to overwrite an \
            existing file; write_range edits the file that is there. `sheets` names the tabs \
            in order (xlsx family only — a .csv or .tsv is single-sheet by nature and takes \
            its name from the file); omit it for one sheet named Sheet1.
            """,
            properties: [
                ToolSchema.pathProperty,
                ToolProperty(
                    name: "sheets",
                    kind: .array,
                    summary: "Sheet names for the new workbook, in tab order. xlsx/xlsm/xltx "
                        + "only; omit for a single sheet named Sheet1.",
                    items: .object(["type": .string("string")])
                ),
                ToolSchema.previewProperty,
            ],
            isReadOnly: false
        ),
        handler: { call in
            let path = try call.arguments.string("path")
            let preview = try call.isPreview()
            // The grant check, before anything else — including before the existence check
            // below, so a refusal cannot tell an ungranted caller whether a file is there.
            let url = try call.broker.resolve(path)
            let ext = url.pathExtension.lowercased()
            // `resolve` accepted every *readable* extension; creation is narrower (.txt is
            // read-only, for example), so the writable set is checked on top rather than
            // instead.
            guard WorkbookFormatSupport.writable.contains(ext) else {
                throw SheetError.unsupportedFileFormat(
                    detail: "OpenSheets creates .xlsx, .xlsm, .xltx, .csv and .tsv files; it cannot create a .\(ext)"
                )
            }
            let names = try sheetNames(call.arguments, delimited: WorkbookFormatSupport.isDelimited(url))
            guard !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
                throw SheetError.fileNotWritable(
                    path: url.path(percentEncoded: false),
                    underlying: "the file already exists — new_workbook never overwrites; "
                        + "write_range edits the file that is there"
                )
            }

            let listed = names.map { UntrustedContent.inlineCell($0, limit: 60) }.joined(separator: ", ")
            let count = "\(names.count) sheet\(names.count == 1 ? "" : "s")"
            guard !preview else {
                return ToolOutput("preview only, nothing created · would create \(path) · \(count) (\(listed))")
            }

            let workbook = Workbook(
                sheets: names.enumerated().map { Sheet(id: SheetID(Int32($0.offset + 1)), name: $0.element) }
            )
            // The same writer every save goes through, so a created file is indistinguishable
            // from a saved one; with no edit tracker recorded it regenerates from the model,
            // which is the only option a file with no original bytes has. The write itself goes
            // through the store's suppressor — atomic, and invisible to the app's watcher the
            // way our own saves are.
            let bytes = try call.broker.writer.encodeWorkbook(workbook, for: url, originalBytes: nil)
            _ = try call.context.store.suppressor.write(bytes, to: url)
            return ToolOutput("created \(path) · \(count) (\(listed))")
        }
    )

    /// The validated sheet list: `Sheet1` when absent, refused outright for delimited formats,
    /// every name held to Excel's rules and to case-insensitive uniqueness — the same collapse
    /// Excel itself performs, caught here so the workbook is never built with a collision it
    /// would have to repair.
    private static func sheetNames(
        _ arguments: ToolArguments,
        delimited: Bool
    ) throws(SheetError) -> [String] {
        guard let supplied = try arguments.optionalArray("sheets") else { return ["Sheet1"] }
        guard !delimited else {
            throw SheetError.invalidToolArguments(
                tool: arguments.tool,
                detail: "a .csv or .tsv holds exactly one sheet and its name comes from the file "
                    + "name; omit `sheets`, or create an .xlsx"
            )
        }
        guard !supplied.isEmpty else {
            throw SheetError.invalidToolArguments(
                tool: arguments.tool,
                detail: "`sheets` is empty; omit it for the default single sheet named Sheet1"
            )
        }
        guard supplied.count <= maximumSheetsPerCreate else {
            throw SheetError.invalidToolArguments(
                tool: arguments.tool,
                detail: "`sheets` may name at most \(maximumSheetsPerCreate) sheets — got \(supplied.count)"
            )
        }
        var names: [String] = []
        var seen: Set<String> = []
        for value in supplied {
            guard let name = value.stringValue else {
                throw SheetError.invalidToolArguments(
                    tool: arguments.tool, detail: "`sheets` must be an array of sheet-name strings"
                )
            }
            try Limits.validateSheetName(name)
            guard seen.insert(name.lowercased()).inserted else {
                throw SheetError.invalidToolArguments(
                    tool: arguments.tool,
                    detail: "duplicate sheet name '\(UntrustedContent.inlineCell(name, limit: 60))' — "
                        + "sheet names must be distinct, and Excel compares them case-insensitively"
                )
            }
            names.append(name)
        }
        return names
    }

    // MARK: - delete_file

    public static let deleteFile = ToolDefinition(
        schema: ToolSchema(
            name: "delete_file",
            title: "Delete a workbook",
            summary: """
            Moves a workbook to the macOS Trash. Double-recoverable by design: a snapshot of \
            the file's bytes is taken first, so `restore` can resurrect the file even after it \
            is gone, and the Trash keeps the file itself. Never hard-deletes. Only files inside \
            a granted folder, in a format this server reads, can be deleted.
            """,
            properties: [
                ToolSchema.pathProperty,
                ToolSchema.previewProperty,
            ],
            isReadOnly: false,
            isDestructive: true
        ),
        handler: { call in
            let path = try call.arguments.string("path")
            let preview = try call.isPreview()
            // Grant first; existence second, and only after the grant has passed — the same
            // non-leak ordering as new_workbook, in the other direction.
            let url = try call.broker.resolve(path)
            let canonical = url.path(percentEncoded: false)
            guard FileManager.default.fileExists(atPath: canonical) else {
                throw SheetError.fileNotFound(path: canonical)
            }

            if preview {
                let attributes = try? FileManager.default.attributesOfItem(atPath: canonical)
                let byteCount = (attributes?[.size] as? Int) ?? 0
                let document = try await call.broker.document(at: path)
                let sheets = document.workbook.sheets.count
                return ToolOutput(
                    "preview only, nothing trashed · would trash \(path) "
                        + "(\(CellText.count(byteCount)) bytes, \(sheets) sheet\(sheets == 1 ? "" : "s"))"
                )
            }

            // The snapshot precedes the trash — bytes first, then the file, so there is never
            // a moment where the only copy is the one being removed.
            let record = try await call.broker.snapshot(path: path, summary: "before delete_file")
            // Close our own session before the file goes: a live session holds an FSEvents
            // stream on the path and an in-memory workbook that would shadow the file's
            // absence from every later call.
            await call.broker.close(url)
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            } catch {
                throw SheetError.fileNotWritable(path: canonical, underlying: "\(error)")
            }

            var lines = ["trashed \(path) (recoverable from the Trash)"]
            if let record {
                lines.append("undo: restore(path, \"\(record.id.rawValue)\")")
            } else {
                lines.append(
                    "no snapshot was taken (the file exceeds the snapshot size limit); recover it from the Trash"
                )
            }
            if call.context.handshake.presence(for: url) != nil {
                lines.append("the OpenSheets app has this file open; its tab will show the file as missing")
            }
            return ToolOutput(lines.joined(separator: "\n"))
        }
    )

    // MARK: - open_in_app

    public static let openInApp = ToolDefinition(
        schema: ToolSchema(
            name: "open_in_app",
            title: "Open the file in the app",
            summary: """
            Opens the file in the OpenSheets app — launching the app if it is not running — \
            fronts its window, and optionally selects a sheet and range. The takeover \
            counterpart to reveal_range's polite request: use reveal_range to point at cells \
            when the app may already be showing the file, and open_in_app when the user should \
            be looking at the file and the app may not even be running. The selection request \
            expires in 90 seconds if the app does not consume it.
            """,
            properties: [
                ToolSchema.pathProperty,
                ToolSchema.sheetProperty(required: false),
                ToolProperty(
                    name: "range",
                    kind: .string,
                    summary: "A1 range to select once the file is open. Optional."
                ),
                ToolSchema.previewProperty,
            ],
            // Read-only for the same reason reveal_range is: it changes what is on screen,
            // never any file.
            isReadOnly: true
        ),
        handler: { call in
            let path = try call.arguments.string("path")
            let preview = try call.isPreview()
            // `document(at:)` runs the grant check as its first act, so a refused path never
            // reaches the request write below, and never reaches the launcher.
            let document = try await call.broker.document(at: path)

            var sheet: String?
            var range: String?
            if call.arguments.has("range") {
                let target = try RangeSelector.target(
                    in: document.workbook,
                    sheet: call.arguments.optionalString("sheet"),
                    range: try call.arguments.string("range"),
                    tool: "open_in_app"
                )
                sheet = target.sheetName
                range = target.range.a1String(collapseSingleCell: false)
            } else if let name = call.arguments.optionalString("sheet") {
                sheet = try RangeSelector.sheet(in: document.workbook, named: name, tool: "open_in_app").sheet.name
            }

            var label = "\(preview ? "preview only: would ask" : "asked") OpenSheets to open \(path)"
            if let sheet { label += " · sheet \(UntrustedContent.inlineCell(sheet, limit: 60))" }
            if let range { label += " · range \(range)" }
            guard !preview else { return ToolOutput(label) }

            // Request first, launch second: on a cold machine the app's startup sweep is the
            // reader, so the request has to be on disk before the process it is for exists.
            let requested = call.context.handshake.requestOpen(url: document.url, sheet: sheet, range: range)
            guard call.context.handshake.launch(document.url) else {
                throw SheetError.internalInconsistency(
                    detail: "/usr/bin/open could not be run; the app was not launched"
                )
            }
            var lines = [label]
            lines.append("the app fronts within a few seconds; the request expires in 90 seconds if it does not")
            if !requested, sheet != nil || range != nil {
                lines.append("(the selection request could not be written; the file will open without a selection)")
            }
            return ToolOutput(lines.joined(separator: "\n"))
        }
    )
}
