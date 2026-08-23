import CryptoKit
import Foundation
import SheetModel

/// What the app publishes about a document it has open.
public struct AppPresence: Sendable, Hashable {
    /// The file, canonicalised.
    public var path: String
    /// The sheet the user is looking at.
    public var sheetName: String
    /// Their selection, in A1.
    public var selection: String
    /// Their active cell.
    public var activeCell: String
    /// The app's process id, so a stale file from a crashed app can be recognised.
    public var processID: Int
    public var updatedAt: Date

    /// Whether this record is recent enough to believe.
    ///
    /// A handshake file outlives the process that wrote it — a crash, a force quit, a machine
    /// that lost power — so age is the only honest test. Ninety seconds is comfortably longer
    /// than the app's refresh interval and far shorter than a session.
    public func isFresh(now: Date = Date(), tolerance: TimeInterval = 90) -> Bool {
        now.timeIntervalSince(updatedAt) < tolerance && kill(pid_t(processID), 0) == 0
    }
}

/// The optional bridge between `opensheets-mcp` and the app (A9 brief §4).
///
/// # Everything here degrades to nothing
///
/// The app may not be running. It may be running and not have this file open. It may be a
/// version that predates the handshake. Every one of those is normal, and none of them is an
/// error: ``presence(for:)`` returns `nil` and the tools say *"the OpenSheets app is not open
/// on this file"*. Nothing else in the server depends on it.
///
/// The transport is two small JSON files in the shared application-support directory, named by
/// the SHA-256 of the canonical path — the same trick ``SheetStore/SnapshotStore`` uses, and
/// for the same two reasons: a file called `../../etc/passwd` cannot escape the directory, and
/// a 300-character path cannot exceed `NAME_MAX`.
///
/// - `Handshake/<hash>.json` — written by the app, read here.
/// - `Handshake/<hash>.request.json` — written here, read by the app.
///
/// A request is a *suggestion*. The app decides whether to act on it, which is the right
/// direction for the trust to flow: an agent should be able to ask the user's window to scroll
/// somewhere, and should not be able to drive it.
public struct AppHandshake: Sendable {
    /// The directory the two files live in.
    public let directory: URL
    private let now: @Sendable () -> Date

    public init(applicationSupport: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        directory = applicationSupport.appendingPathComponent("Handshake")
        self.now = now
    }

    /// What the app says about `url`, or `nil` when it is not there or not fresh.
    public func presence(for url: URL) -> AppPresence? {
        let file = directory.appendingPathComponent("\(AppHandshake.key(url)).json")
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONValue.parse(data),
              let path = json["path"]?.stringValue,
              let updated = json["updatedAt"]?.doubleValue
        else { return nil }
        let presence = AppPresence(
            path: path,
            sheetName: json["sheet"]?.stringValue ?? "",
            selection: json["selection"]?.stringValue ?? "",
            activeCell: json["activeCell"]?.stringValue ?? "",
            processID: json["pid"]?.integerValue ?? 0,
            updatedAt: Date(timeIntervalSince1970: updated)
        )
        return presence.isFresh(now: now()) ? presence : nil
    }

    /// Asks the app to scroll to and select a range. Returns whether the request was written.
    ///
    /// Writing the request is not the same as the app honouring it, and the tool result says so
    /// — promising an agent that a window moved when nothing was listening would be a lie it
    /// cannot check.
    @discardableResult
    public func requestReveal(url: URL, sheet: String, range: String) -> Bool {
        guard presence(for: url) != nil else { return false }
        let payload = JSONValue.object([
            "path": .string(url.path(percentEncoded: false)),
            "sheet": .string(sheet),
            "range": .string(range),
            "requestedAt": .number(now().timeIntervalSince1970),
        ])
        let file = directory.appendingPathComponent("\(AppHandshake.key(url)).request.json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(payload.rendered.utf8).write(to: file, options: [.atomic])
            return true
        } catch {
            return false
        }
    }

    /// Publishes a presence record. The app calls this; it lives here so both sides share one
    /// definition of the format rather than agreeing on one in a document.
    public func publish(_ presence: AppPresence) throws(SheetError) {
        let payload = JSONValue.object([
            "path": .string(presence.path),
            "sheet": .string(presence.sheetName),
            "selection": .string(presence.selection),
            "activeCell": .string(presence.activeCell),
            "pid": .integer(presence.processID),
            "updatedAt": .number(presence.updatedAt.timeIntervalSince1970),
        ])
        let file = directory.appendingPathComponent(
            "\(AppHandshake.key(URL(fileURLWithPath: presence.path))).json"
        )
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(payload.rendered.utf8).write(to: file, options: [.atomic])
        } catch {
            throw SheetError.fileNotWritable(path: file.path(percentEncoded: false), underlying: "\(error)")
        }
    }

    static func key(_ url: URL) -> String {
        let canonical = url.resolvingSymlinksInPath().standardized.path(percentEncoded: false)
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// `get_selection` and `reveal_range` — the two tools that talk to the app, when it is there.
public enum HandshakeTools {
    public static let getSelection = ToolDefinition(
        schema: ToolSchema(
            name: "get_selection",
            title: "Get the user's selection",
            summary: """
            Reports what the user has selected in the OpenSheets app, if the app is running with \
            this file open. Lets "sum this column" mean the column they are looking at. Returns \
            a plain "not open" message when the app is not running — that is normal, not an \
            error, and every other tool works without it.
            """,
            properties: [ToolSchema.pathProperty, ToolSchema.previewProperty],
            isReadOnly: true
        ),
        handler: { call in
            _ = try call.isPreview()
            let path = try call.arguments.string("path")
            let url = try call.broker.resolve(path)
            guard let presence = call.context.handshake.presence(for: url) else {
                return ToolOutput("the OpenSheets app is not open on this file; there is no selection to report")
            }
            return ToolOutput(UntrustedContent.wrap(
                "sheet: \(presence.sheetName)\nselection: \(presence.selection)\nactive: \(presence.activeCell)",
                source: url.path(percentEncoded: false),
                sheet: presence.sheetName
            ))
        }
    )

    public static let revealRange = ToolDefinition(
        schema: ToolSchema(
            name: "reveal_range",
            title: "Reveal a range in the app",
            summary: """
            Asks the OpenSheets app to scroll to and select a range, so the user can see what \
            you are talking about. Best-effort: the app decides whether to act on it, and if the \
            app is not running nothing happens and the result says so.
            """,
            properties: [
                ToolSchema.pathProperty,
                ToolSchema.sheetProperty(required: false),
                ToolProperty(
                    name: "range", kind: .string, summary: "A1 range to reveal.", isRequired: true
                ),
                ToolSchema.previewProperty,
            ],
            isReadOnly: true
        ),
        handler: { call in
            let path = try call.arguments.string("path")
            let preview = try call.isPreview()
            let document = try await call.broker.document(at: path)
            let target = try RangeSelector.target(
                in: document.workbook,
                sheet: call.arguments.optionalString("sheet"),
                range: try call.arguments.string("range"),
                tool: "reveal_range"
            )
            guard !preview else {
                return ToolOutput("preview only: would ask the app to reveal \(target.label)")
            }
            let sent = call.context.handshake.requestReveal(
                url: document.url,
                sheet: target.sheetName,
                range: target.range.a1String(collapseSingleCell: false)
            )
            return ToolOutput(
                sent
                    ? "asked the app to reveal \(target.label) (the app decides whether to act on it)"
                    : "the OpenSheets app is not open on this file; nothing was revealed"
            )
        }
    )
}
