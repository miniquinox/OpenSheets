import Foundation
import SheetModel

/// `add_sheet`, `rename_sheet`, `delete_sheet`.
///
/// Two of these refuse, on purpose, and say so in their descriptions rather than only in their
/// errors — an agent that reads `tools/list` should never spend a call discovering a refusal it
/// could have read about.
///
/// The reason is Wave 2 addendum §4 and PLAN.md §5.2: adding or removing a sheet in an existing
/// `.xlsx` means a new part, a new content-type override and a new relationship, all consistent
/// with each other *and* with `workbook.xml`. A2's writer refuses that in v0.1 rather than
/// producing a package Excel calls damaged — and a file Excel refuses to open is worse than a
/// feature it does not have.
public enum SheetTools {
    public static let addSheet = ToolDefinition(
        schema: ToolSchema(
            name: "add_sheet",
            title: "Add a sheet",
            summary: """
            **Not supported in v0.1 — this tool always refuses.** Adding a sheet to an existing \
            workbook means rewriting the package's part structure, and a partial job produces a \
            file Excel reports as damaged, so OpenSheets refuses rather than risking it. To add \
            data to a workbook, write to an existing sheet; to start from scratch with exactly \
            the sheets you need, create a fresh file with new_workbook; or have the user add \
            the sheet in Excel or in the OpenSheets app first.
            """,
            properties: [
                ToolSchema.pathProperty,
                ToolProperty(name: "name", kind: .string, summary: "Name for the new sheet.", isRequired: true),
                ToolProperty(name: "at", kind: .integer, summary: "1-based tab position."),
                ToolSchema.previewProperty,
            ],
            isReadOnly: false
        ),
        handler: { call in
            let path = try call.arguments.string("path")
            _ = try call.arguments.string("name")
            // The grant is still checked. A refusal must not be a way to test whether a path
            // exists outside the workspace.
            _ = try call.broker.resolve(path)
            return ResultFormatter.refusal(
                "adding a sheet to an existing workbook",
                alternative:
                "Write to a sheet that already exists, create a fresh workbook with the sheets "
                    + "you need using new_workbook, or ask the user to add the sheet in Excel "
                    + "or the OpenSheets app and then call this server again."
            )
        }
    )

    public static let deleteSheet = ToolDefinition(
        schema: ToolSchema(
            name: "delete_sheet",
            title: "Delete a sheet",
            summary: """
            **Not supported in v0.1 — this tool always refuses.** Removing a sheet means \
            rewriting the package's part structure and every reference to it; OpenSheets refuses \
            rather than producing a workbook Excel calls damaged. To empty a sheet instead, use \
            `delete_rows` over its used range; to start over with a different sheet list, \
            create a fresh file with new_workbook.
            """,
            properties: [
                ToolSchema.pathProperty,
                ToolSchema.sheetProperty(required: true, summary: "Sheet to delete."),
                ToolSchema.previewProperty,
            ],
            isReadOnly: false,
            isDestructive: true
        ),
        handler: { call in
            let path = try call.arguments.string("path")
            _ = try call.arguments.string("sheet")
            _ = try call.broker.resolve(path)
            return ResultFormatter.refusal(
                "deleting a sheet from an existing workbook",
                alternative:
                "To clear its contents instead, call delete_rows over the sheet's used range. "
                    + "To start over with a different sheet list, create a fresh workbook with "
                    + "new_workbook."
            )
        }
    )

    public static let renameSheet = ToolDefinition(
        schema: ToolSchema(
            name: "rename_sheet",
            title: "Rename a sheet",
            summary: """
            Renames a sheet. Formulas that reference it by name keep working — the name lives in \
            `workbook.xml` and formulas refer to the sheet by id, so nothing else has to change. \
            Excel's rules apply: 31 characters, and none of `[ ] : * ? / \\`.
            """,
            properties: [
                ToolSchema.pathProperty,
                ToolSchema.sheetProperty(required: true, summary: "Sheet to rename."),
                ToolProperty(name: "name", kind: .string, summary: "The new name.", isRequired: true),
                ToolSchema.previewProperty,
            ],
            isReadOnly: false
        ),
        handler: { call in
            let path = try call.arguments.string("path")
            let preview = try call.isPreview()
            let newName = try call.arguments.string("name")
            let document = try await call.broker.document(at: path)
            let resolved = try RangeSelector.sheet(
                in: document.workbook, named: try call.arguments.string("sheet"), tool: "rename_sheet"
            )
            try Limits.validateSheetName(newName)
            let sheetID = resolved.sheet.id
            let oldName = resolved.sheet.name

            let outcome = try await call.broker.edit(
                path: path, preview: preview, tool: "rename_sheet"
            ) { workbook, edits in
                try workbook.renameSheet(sheetID, to: newName)
                edits.noteWorkbookMetadataChanged()
                return newName
            }
            return ToolOutput([
                "\(preview ? "would rename" : "renamed") '\(oldName)' to '\(outcome.value)'",
                ResultFormatter.diffSummary(outcome),
            ].joined(separator: "\n"))
        }
    )
}
