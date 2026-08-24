import Foundation
import SheetModel
import SheetStore

/// `snapshot`, `list_snapshots`, `restore` — the agent's own undo.
///
/// Every write this server makes already takes a snapshot first, so these tools are not the
/// safety net; they are the *handle* on it. An agent about to do something it is unsure of can
/// mark the spot with a name it will recognise, and an agent that got it wrong can put the file
/// back without involving the user.
public enum SnapshotTools {
    public static let snapshot = ToolDefinition(
        schema: ToolSchema(
            name: "snapshot",
            title: "Take a snapshot",
            summary: """
            Stores a copy of the file's current bytes and returns an id to restore it by. Every \
            write already snapshots automatically, so use this to mark a point you have named \
            — before a multi-step edit, say — rather than before each individual write. Copies \
            are kept per file (the last 20) and are the raw bytes, so a restore is exact even \
            for parts OpenSheets does not model.
            """,
            properties: [
                ToolSchema.pathProperty,
                ToolProperty(
                    name: "label",
                    kind: .string,
                    summary: "A note shown in the snapshot list, e.g. \"before restructuring Q4\"."
                ),
                ToolSchema.previewProperty,
            ],
            isReadOnly: false
        ),
        handler: { call in
            let path = try call.arguments.string("path")
            let label = call.arguments.optionalString("label")
            guard try !call.isPreview() else {
                _ = try call.broker.resolve(path)
                return ToolOutput("preview only: would snapshot \(path)")
            }
            guard let record = try await call.broker.snapshot(path: path, summary: label) else {
                return ToolOutput(
                    "nothing to snapshot: the file does not exist yet, or is larger than the snapshot limit",
                    isError: true
                )
            }
            return ToolOutput(
                "snapshot \(record.id.rawValue) · \(CellText.count(record.byteCount)) bytes"
                    + " · restore with restore(path, \"\(record.id.rawValue)\")"
            )
        }
    )

    public static let listSnapshots = ToolDefinition(
        schema: ToolSchema(
            name: "list_snapshots",
            title: "List snapshots",
            summary: """
            Snapshots of a file, newest first, with the reason each was taken (before a save, \
            before a refresh, before a restore, or manual). Ids sort chronologically, so the \
            first row is always the most recent.
            """,
            properties: [
                ToolSchema.pathProperty,
                ToolProperty(
                    name: "limit", kind: .integer, summary: "How many to list.", defaultValue: .integer(20)
                ),
                ToolSchema.previewProperty,
            ],
            isReadOnly: true
        ),
        handler: { call in
            _ = try call.isPreview()
            let path = try call.arguments.string("path")
            let limit = try call.arguments.integer("limit", default: 20, atLeast: 1)
            let records = try await call.broker.snapshots(path: path)
            guard !records.isEmpty else { return ToolOutput("no snapshots for this file yet") }
            let formatter = ISO8601DateFormatter()
            var lines = ["\(records.count) snapshot\(records.count == 1 ? "" : "s")"]
            for record in records.prefix(max(1, limit)) {
                var line = "\(record.id.rawValue)  \(formatter.string(from: record.takenAt))  \(record.reason.label)"
                if record.byteCount > 0 { line += "  \(CellText.count(record.byteCount))B" }
                if let summary = record.summary {
                    line += "  \(UntrustedContent.inlineCell(summary, limit: 60))"
                }
                lines.append(line)
            }
            return ToolOutput(lines.joined(separator: "\n"))
        }
    )

    public static let restore = ToolDefinition(
        schema: ToolSchema(
            name: "restore",
            title: "Restore a snapshot",
            summary: """
            Puts a snapshot's bytes back, atomically. A snapshot of the *current* state is taken \
            first, so a restore can itself be undone. With `preview: true` it reports what would \
            change without touching the file — do that first if you are unsure which id you want. \
            Omit `id` to use the most recent snapshot.
            """,
            properties: [
                ToolSchema.pathProperty,
                ToolProperty(
                    name: "id",
                    kind: .string,
                    summary: "Snapshot id from `snapshot` or `list_snapshots`. Omit for the newest."
                ),
                ToolSchema.previewProperty,
            ],
            isReadOnly: false,
            isDestructive: true
        ),
        handler: { call in
            let path = try call.arguments.string("path")
            let preview = try call.isPreview()
            let identifier = try await resolveIdentifier(call, path: path)

            if preview {
                let current = try await call.broker.document(at: path)
                let stored = try await call.broker.snapshotWorkbook(path: path, id: identifier)
                let diff = call.broker.diff(before: current.workbook, after: stored)
                return ToolOutput(
                    "preview only, nothing written · restoring \(identifier.rawValue) would change: \(diff.summary)"
                )
            }
            let document = try await call.broker.restore(path: path, id: identifier)
            return ToolOutput(
                "restored \(identifier.rawValue) · \(document.workbook.sheets.count) sheets, "
                    + "\(CellText.count(document.workbook.cellCount)) cells"
                    + "\n(a snapshot of the previous contents was taken first, so this is undoable)"
            )
        }
    )

    private static func resolveIdentifier(_ call: ToolCall, path: String) async throws -> ULID {
        if let text = call.arguments.optionalString("id") {
            guard let identifier = ULID(rawValue: text) else {
                throw SheetError.invalidToolArguments(
                    tool: "restore", detail: "'\(text)' is not a snapshot id; list them with list_snapshots"
                )
            }
            return identifier
        }
        let records = try await call.broker.snapshots(path: path)
        guard let newest = records.first else {
            throw SheetError.snapshotNotFound(id: "(newest)")
        }
        return newest.id
    }
}
