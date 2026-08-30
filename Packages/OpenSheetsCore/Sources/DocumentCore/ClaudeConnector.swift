#if canImport(AppKit)
import AppKit
#endif
import Foundation
import Observation
import SheetModel
import SheetStore

/// Which Claude client a Settings row talks about.
public enum ClaudeClient: String, CaseIterable, Sendable {
    case claudeCode
    case claudeDesktop
}

/// One client's observed relationship to our MCP server. Derived from its config file on every
/// ``ClaudeConnector/refresh()``, never stored — a cached answer about somebody else's file is
/// stale the moment that program rewrites it, which Claude Code does constantly.
public enum ClaudeConnection: Sendable, Equatable {
    /// The client is absent from this Mac (or, for Claude Code, has never run — see D6).
    case notInstalled
    /// The client is present and its config has no `opensheets` entry.
    case notConnected
    /// An `opensheets` entry points at `command`, which exists and is executable.
    case connected(command: String)
    /// An `opensheets` entry exists but `command` is missing or not executable — the moved-app /
    /// cleaned-DerivedData state whose designed recovery is the Reconnect button.
    case stale(command: String)
    /// The config file exists but could not be read as a JSON object. Writes are refused in
    /// this state: a file we could not parse is a file we might clobber.
    case unreadable(reason: String)
}

/// Where a ``ClaudeConnector`` looks. A struct of injected paths rather than calls to
/// `homeDirectoryForCurrentUser`, because that call is not redirectable in-process — a test that
/// wants a scratch home can only get one by handing the connector different URLs (the same seam
/// `ShippedBinaryTests` had to build a whole subprocess to avoid needing).
public struct ClaudeConnectorPaths: Sendable {
    /// `~/.claude.json` — Claude Code's one config file, user scope at the top level.
    public var claudeCodeConfig: URL
    /// `~/Library/Application Support/Claude/claude_desktop_config.json`.
    public var desktopConfig: URL
    /// The directory above, whose existence is one of the two Desktop-installed signals.
    public var desktopSupportDirectory: URL
    /// The other signal: the app registered with LaunchServices under this identifier.
    /// Injectable so a test can make the lookup fail deterministically on any machine.
    public var desktopBundleIdentifier: String
    /// `/usr/local/bin/opensheets-mcp` — the documented manual install, used only when the
    /// bundled binary is absent.
    public var fallbackBinary: URL

    public init(
        claudeCodeConfig: URL,
        desktopConfig: URL,
        desktopSupportDirectory: URL,
        desktopBundleIdentifier: String,
        fallbackBinary: URL
    ) {
        self.claudeCodeConfig = claudeCodeConfig
        self.desktopConfig = desktopConfig
        self.desktopSupportDirectory = desktopSupportDirectory
        self.desktopBundleIdentifier = desktopBundleIdentifier
        self.fallbackBinary = fallbackBinary
    }

    /// The real locations. The bundle identifier was read off an installed Claude Desktop
    /// (`mdls -name kMDItemCFBundleIdentifier /Applications/Claude.app`); if it ever drifts,
    /// the support-directory check keeps detection working.
    public static func standard() -> ClaudeConnectorPaths {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let support = home.appendingPathComponent("Library/Application Support/Claude", isDirectory: true)
        return ClaudeConnectorPaths(
            claudeCodeConfig: home.appendingPathComponent(".claude.json"),
            desktopConfig: support.appendingPathComponent("claude_desktop_config.json"),
            desktopSupportDirectory: support,
            desktopBundleIdentifier: "com.anthropic.claudefordesktop",
            fallbackBinary: URL(fileURLWithPath: "/usr/local/bin/opensheets-mcp")
        )
    }
}

/// Detects installed Claude clients, reads their registration state, and — on the user's click
/// in Settings ▸ Claude, and only there — edits their config files to connect or disconnect the
/// bundled `opensheets-mcp` server.
///
/// # The policy line
///
/// `~/.claude.json` is on the MCP server's deny list and stays there: the *agent* can never touch
/// Claude's config. This class is the other side of the line the docs drew — "registration is a
/// user action, not an agent action" — and its two writers run only from a labelled button in
/// Settings. Nothing here spawns the binary either; verification is an existence-and-executable
/// check, because probing a server that Claude spawns would just start a second copy.
///
/// # How writes stay safe
///
/// Read-modify-write through `JSONSerialization` (never `JSONValue`, which compacts a
/// multi-megabyte file the user may diff to one line): parse the whole file, splice one entry,
/// re-serialise. Content is fully preserved — unknown keys, integers as integers, booleans as
/// booleans — while formatting normalises to sorted pretty-printed keys, which is accepted
/// because Claude Code machine-manages and rewrites this file constantly. A file that does not
/// parse is never written, and never backed up either — a backup of a file we did not understand
/// would overwrite the previous good one. Before every write to an existing file its bytes are
/// copied to a `<name>.opensheets-backup` sibling, then the replacement goes through
/// ``SheetStore/AtomicWriter`` (mode-preserving, fsync'd, refuses empty overwrites). If Claude
/// Code rewrites the file in the microseconds between our read and our rename, last writer wins
/// on the whole file — accepted, because the write is rare, user-initiated and sub-millisecond.
@MainActor
@Observable
public final class ClaudeConnector {
    /// The key both clients' `mcpServers` maps know us by.
    public static let serverName = "opensheets"

    /// What each client's config file said the last time ``refresh()`` ran.
    public private(set) var connections: [ClaudeClient: ClaudeConnection] = [:]

    private let paths: ClaudeConnectorPaths
    private let bundledBinary: URL?

    /// `bundledBinary` is `Bundle.main.url(forAuxiliaryExecutable: "opensheets-mcp")` in the
    /// app and a temp file (or `nil`) in tests — passed in rather than looked up here so a test
    /// process, whose main bundle is the test runner, exercises the same resolution the app runs.
    public init(paths: ClaudeConnectorPaths = .standard(), bundledBinary: URL?) {
        self.paths = paths
        self.bundledBinary = bundledBinary
        refresh()
    }

    /// The binary a Connect click would register: the bundled copy when it exists and is
    /// executable, else the documented `/usr/local/bin` install when that exists, else `nil`
    /// (Connect stays disabled). The bundled copy always wins because it is the one this app
    /// version shipped with — a stale manual install answering for it would pin users to
    /// whatever they last copied by hand.
    public var serverBinary: URL? {
        if let bundledBinary,
           FileManager.default.isExecutableFile(atPath: bundledBinary.path(percentEncoded: false)) {
            return bundledBinary
        }
        if FileManager.default.fileExists(atPath: paths.fallbackBinary.path(percentEncoded: false)) {
            return paths.fallbackBinary
        }
        return nil
    }

    /// Re-reads both config files. Small synchronous I/O on purpose — a spinner for a stat and
    /// a sub-megabyte read would be ceremony, and every mutation below ends by calling this so
    /// ``connections`` can never describe a file state the mutation just changed.
    public func refresh() {
        connections = [
            .claudeCode: readClaudeCode(),
            .claudeDesktop: readDesktop(),
        ]
    }

    /// Splices the user-scope `opensheets` entry into `client`'s config (D1–D3). Idempotent:
    /// connecting when already connected rewrites the same entry, byte for byte.
    public func connect(_ client: ClaudeClient) throws(SheetError) {
        defer { refresh() }
        guard let binary = serverBinary else {
            // Re-checked here rather than trusted from the UI's disabled button: the binary can
            // vanish between the pane appearing and the click (a clean of DerivedData does it).
            throw SheetError.fileNotWritable(
                path: (bundledBinary ?? paths.fallbackBinary).path(percentEncoded: false),
                underlying: "the opensheets-mcp server binary is missing from this build"
            )
        }
        let command = binary.path(percentEncoded: false)
        switch client {
        case .claudeCode: try connectClaudeCode(command: command)
        case .claudeDesktop: try connectDesktop(command: command)
        }
    }

    /// Removes the `opensheets` entry everywhere it can live (D4): the top level of either
    /// client's config and — for Claude Code — every `projects.<path>.mcpServers`, because old
    /// manual `claude mcp add` runs leave project-scope entries that would make "Disconnected" a
    /// lie. Nothing else is touched; emptied containers are left in place. Disconnecting when
    /// not connected is a silent no-op with no write at all.
    public func disconnect(_ client: ClaudeClient) throws(SheetError) {
        defer { refresh() }
        let url = client == .claudeCode ? paths.claudeCodeConfig : paths.desktopConfig
        var root: [String: Any]
        switch load(url) {
        case .missing:
            return
        case let .invalid(reason):
            throw ClaudeConnector.writeRefusal(url, reason: reason)
        case let .object(existing):
            root = existing
        }

        var changed = false
        if var servers = root["mcpServers"] as? [String: Any],
           servers.removeValue(forKey: ClaudeConnector.serverName) != nil {
            root["mcpServers"] = servers
            changed = true
        }
        if client == .claudeCode, let projects = root["projects"] as? [String: Any] {
            var cleaned = projects
            var cleanedAny = false
            for (path, value) in projects {
                guard var project = value as? [String: Any],
                      var servers = project["mcpServers"] as? [String: Any],
                      servers.removeValue(forKey: ClaudeConnector.serverName) != nil
                else { continue }
                project["mcpServers"] = servers
                cleaned[path] = project
                cleanedAny = true
            }
            if cleanedAny {
                root["projects"] = cleaned
                changed = true
            }
        }
        guard changed else { return }

        try backUp(url)
        try write(root, to: url)
    }

    // MARK: - Reading

    private enum ConfigRead {
        case missing
        case invalid(reason: String)
        case object([String: Any])
    }

    /// The one parser both directions share, so status and write-refusal can never disagree
    /// about what counts as readable. "Readable" means: a JSON object at the top level whose
    /// `mcpServers`, if present, is also an object — the two shapes a write would have to
    /// preserve blind if we accepted them broken.
    private func load(_ url: URL) -> ConfigRead {
        let path = url.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path) else { return .missing }
        let name = url.lastPathComponent
        guard let data = try? Data(contentsOf: url) else {
            return .invalid(reason: "\(name) exists but could not be read")
        }
        guard let parsed = try? JSONSerialization.jsonObject(with: data),
              let root = parsed as? [String: Any]
        else {
            return .invalid(reason: "\(name) is not valid JSON")
        }
        if root["mcpServers"] != nil, !(root["mcpServers"] is [String: Any]) {
            return .invalid(reason: "the mcpServers entry in \(name) is not an object")
        }
        return .object(root)
    }

    /// Claude Code is installed exactly when `~/.claude.json` exists — the client writes it on
    /// first run, so its absence means "never ran", and creating it ourselves would register a
    /// server with a client that may not exist.
    private func readClaudeCode() -> ClaudeConnection {
        switch load(paths.claudeCodeConfig) {
        case .missing: .notInstalled
        case let .invalid(reason): .unreadable(reason: reason)
        case let .object(root): ClaudeConnector.connection(in: root)
        }
    }

    /// Claude Desktop is installed when LaunchServices knows its bundle identifier *or* its
    /// support directory exists — two signals because either alone lies: the directory survives
    /// an uninstall, and the identifier lookup fails if Anthropic ever renames the bundle. Its
    /// config file may legitimately not exist yet, so a missing file is `.notConnected`, not
    /// `.notInstalled`.
    private func readDesktop() -> ClaudeConnection {
        guard desktopIsInstalled else { return .notInstalled }
        return switch load(paths.desktopConfig) {
        case .missing: .notConnected
        case let .invalid(reason): .unreadable(reason: reason)
        case let .object(root): ClaudeConnector.connection(in: root)
        }
    }

    private var desktopIsInstalled: Bool {
        #if canImport(AppKit)
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: paths.desktopBundleIdentifier) != nil {
            return true
        }
        #endif
        var isDirectory: ObjCBool = false
        let path = paths.desktopSupportDirectory.path(percentEncoded: false)
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Targeted parsing — `mcpServers[serverName]["command"]` and nothing else. The old
    /// whole-document substring search reported "registered" for any config that merely
    /// *mentioned* an OpenSheets path, which every granted project entry does.
    ///
    /// An entry that exists but has no usable command string is `.stale("")` rather than
    /// `.notConnected`: an entry is present, whatever its shape, and the honest offer is
    /// Reconnect (which rewrites it whole), not Connect (which claims there was nothing).
    private static func connection(in root: [String: Any]) -> ClaudeConnection {
        guard let servers = root["mcpServers"] as? [String: Any],
              let entry = servers[serverName]
        else { return .notConnected }
        let command = ((entry as? [String: Any])?["command"] as? String) ?? ""
        if !command.isEmpty, FileManager.default.isExecutableFile(atPath: command) {
            return .connected(command: command)
        }
        return .stale(command: command)
    }

    // MARK: - Writing

    private func connectClaudeCode(command: String) throws(SheetError) {
        let url = paths.claudeCodeConfig
        var root: [String: Any]
        switch load(url) {
        case .missing:
            // D6: we do not create the file for a client that has never run — a config Claude
            // Code did not write is a claim about a client we cannot see.
            throw SheetError.fileNotWritable(
                path: url.path(percentEncoded: false),
                underlying: "Claude Code has never run on this Mac — there is no \(url.lastPathComponent) to register in"
            )
        case let .invalid(reason):
            throw ClaudeConnector.writeRefusal(url, reason: reason)
        case let .object(existing):
            root = existing
        }
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        // `type`/`env` for parity with what `claude mcp add` writes, so a user comparing the
        // two paths sees one shape.
        servers[ClaudeConnector.serverName] = [
            "type": "stdio",
            "command": command,
            "args": [String](),
            "env": [String: String](),
        ] as [String: Any]
        root["mcpServers"] = servers
        try backUp(url)
        try write(root, to: url)
    }

    private func connectDesktop(command: String) throws(SheetError) {
        let url = paths.desktopConfig
        var root: [String: Any]
        switch load(url) {
        case .missing:
            // Unlike Claude Code's file, this one is legitimately ours to create: Desktop reads
            // it at launch and ships without it. That is also why there is no installed-guard
            // here — the config is the connection, and the UI already disables the button for a
            // client detection cannot see.
            root = [:]
        case let .invalid(reason):
            throw ClaudeConnector.writeRefusal(url, reason: reason)
        case let .object(existing):
            root = existing
        }
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        servers[ClaudeConnector.serverName] = [
            "command": command,
            "args": [String](),
        ] as [String: Any]
        root["mcpServers"] = servers
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            throw SheetError.fileNotWritable(
                path: url.deletingLastPathComponent().path(percentEncoded: false),
                underlying: "the configuration folder could not be created: \(error)"
            )
        }
        try backUp(url)
        try write(root, to: url)
    }

    /// Copies the current file to its `<name>.opensheets-backup` sibling before every write to
    /// an existing file — a durable copy, unlike `AtomicWriter`'s own backup hook, which deletes
    /// the backup the moment the replace succeeds. The previous backup is replaced: one
    /// known-good generation is the promise, not an archive. No file, no backup — there is
    /// nothing to lose yet.
    private func backUp(_ url: URL) throws(SheetError) {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return }
        let sibling = url.appendingPathExtension("opensheets-backup")
        try? FileManager.default.removeItem(at: sibling)
        do {
            try FileManager.default.copyItem(at: url, to: sibling)
        } catch {
            throw SheetError.fileNotWritable(
                path: sibling.path(percentEncoded: false),
                underlying: "the pre-write backup could not be created: \(error)"
            )
        }
    }

    private func write(_ root: [String: Any], to url: URL) throws(SheetError) {
        let data: Data
        do {
            // `.sortedKeys` + `.prettyPrinted` makes the output deterministic — the reason
            // "connect twice" can promise byte-identical files. `.withoutEscapingSlashes`
            // because every value in sight is a path, and `\/` in a diff reads as damage.
            data = try JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
        } catch {
            throw SheetError.fileNotWritable(
                path: url.path(percentEncoded: false),
                underlying: "the updated configuration could not be encoded: \(error)"
            )
        }
        try AtomicWriter().write(data, to: url, options: .init())
    }

    private static func writeRefusal(_ url: URL, reason: String) -> SheetError {
        .fileNotWritable(
            path: url.path(percentEncoded: false),
            underlying: "\(reason); refusing to rewrite it"
        )
    }
}
