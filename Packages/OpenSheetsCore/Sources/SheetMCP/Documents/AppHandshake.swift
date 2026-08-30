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

    /// The memberwise initialiser, spelled out so it is `public`.
    ///
    /// It has to be. ``AppHandshake/publish(_:)`` is documented as *"the app calls this"*, and the
    /// app is in another module — so while the synthesised initialiser was `internal`, the method
    /// was uncallable from the only place meant to call it, and the app side of the handshake went
    /// unbuilt for exactly as long. Widening this is what lets the app publish through the same
    /// writer the server reads, instead of re-spelling the format alongside it.
    public init(
        path: String,
        sheetName: String,
        selection: String,
        activeCell: String,
        processID: Int,
        updatedAt: Date
    ) {
        self.path = path
        self.sheetName = sheetName
        self.selection = selection
        self.activeCell = activeCell
        self.processID = processID
        self.updatedAt = updatedAt
    }

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
    /// How `open_in_app` starts the app. Defaults to ``systemLaunch``.
    ///
    /// A closure on the handshake rather than a `Process` call at the tool's call site, for one
    /// reason: **tests must never launch a GUI**. The handshake is already the injected
    /// app-facing seam every `ToolContext` carries, so putting the launcher here gives tests a
    /// spy through the same initialiser they already use — no global mutable state for parallel
    /// suites to race on, and no second injection path for the launcher to drift away from.
    let launch: @Sendable (URL) -> Bool

    public init(
        applicationSupport: URL,
        now: @escaping @Sendable () -> Date = { Date() },
        launch: @escaping @Sendable (URL) -> Bool = AppHandshake.systemLaunch
    ) {
        directory = applicationSupport.appendingPathComponent("Handshake")
        self.now = now
        self.launch = launch
    }

    /// The app's bundle identifier — the `-b` argument that pins `/usr/bin/open` to OpenSheets
    /// rather than to whatever application claims the file's extension.
    public static let appBundleID = "com.quino.opensheets"

    /// The real launcher: `/usr/bin/open -b com.quino.opensheets -- <path>`.
    ///
    /// This is the server's first and only subprocess, and every part of it is pinned so it
    /// stays that way in spirit as well as in count: the executable is the literal
    /// `/usr/bin/open`, the bundle id is the constant above, the one variable argument is a
    /// path that has already passed the grant check (behind `--`, so it cannot be read as an
    /// option), and no shell is involved. The child's stdio is routed to `/dev/null`
    /// explicitly — fd 1 is the protocol stream, and while `claimStdout` already redirected it,
    /// the child should not inherit the chance to test that.
    ///
    /// `open` is idempotent, which is why the caller needs no "is it running" detection: a
    /// running app is activated and handed the file as a reopen event, a cold machine gets a
    /// launch, and both funnel into the app's one open path.
    public static let systemLaunch: @Sendable (URL) -> Bool = { url in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-b", AppHandshake.appBundleID, "--", url.path(percentEncoded: false)]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            return true
        } catch {
            return false
        }
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

    /// Asks the app to open a file — and, optionally, to select a sheet and range once it has.
    /// Returns whether the request was written.
    ///
    /// The takeover counterpart to ``requestReveal(url:sheet:range:)``, and deliberately
    /// **without its presence guard**: `open_in_app` writes this immediately before launching
    /// the app, so the normal reader is a process that does not exist yet. The app's startup
    /// sweep consumes requests younger than ninety seconds, which is exactly the window a
    /// just-written file sits in; when the app is already running, the same request arrives
    /// through its live watcher instead. Sheet and range are omitted from the payload when not
    /// given — the consumer parses both as optional, and an absent key is the honest spelling
    /// of "no selection requested".
    @discardableResult
    public func requestOpen(url: URL, sheet: String?, range: String?) -> Bool {
        var members: [String: JSONValue] = [
            "path": .string(url.path(percentEncoded: false)),
            "requestedAt": .number(now().timeIntervalSince1970),
        ]
        if let sheet { members["sheet"] = .string(sheet) }
        if let range { members["range"] = .string(range) }
        let file = directory.appendingPathComponent("\(AppHandshake.key(url)).request.json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(JSONValue.object(members).rendered.utf8).write(to: file, options: [.atomic])
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

    /// Removes the presence record for `url`, if there is one.
    ///
    /// The counterpart to ``publish(_:)``, and the app needs it for the same reason it needs to
    /// publish: a record that merely ages out claims for up to ninety seconds that the user is
    /// looking at a file they closed. Absent is the honest answer the moment the tab goes.
    ///
    /// Silent when there is nothing to remove — withdrawing twice, or withdrawing a file that was
    /// never published, is the normal case at shutdown and is not a failure.
    public func withdraw(_ url: URL) {
        let file = directory.appendingPathComponent("\(AppHandshake.key(url)).json")
        try? FileManager.default.removeItem(at: file)
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
            you are talking about. If the app is running but does not have the file open, it \
            opens it first. Best-effort: the app decides whether to act on it, and if the app is \
            not running nothing happens and the result says so. Use open_in_app instead to \
            launch the app or force the file open.
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
