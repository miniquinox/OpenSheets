import Foundation
import GlassUI
import SheetModel
import Testing

@testable import DocumentCore

/// What the connector may do to a Claude config file, and — mostly — when it must refuse to.
///
/// # Why every path here is injected
///
/// `homeDirectoryForCurrentUser` is not redirectable in-process (Foundation reads the password
/// database, not `HOME` — `ShippedBinaryTests` had to build a whole subprocess to get around
/// that), so ``DocumentCore/ClaudeConnectorPaths`` is the only seam. Every test builds a
/// disposable directory and points all five paths into it; the developer's real `~/.claude.json`
/// is never read, and never, ever written. The Desktop bundle identifier is a UUID so the
/// LaunchServices lookup fails deterministically on any machine, leaving the support-directory
/// check as the sole installed signal — the one a test can control.
@Suite("Claude connector")
@MainActor
struct ClaudeConnectorTests {
    // MARK: - Connect

    @Test("Connecting twice yields byte-identical files and a single entry")
    func connectIsIdempotent() throws {
        let box = try Sandbox()
        try box.seedClaudeCode(#"{"junk": "keep"}"#)
        let connector = box.connector(bundled: box.binary)

        try connector.connect(.claudeCode)
        let first = try Data(contentsOf: box.paths.claudeCodeConfig)
        try connector.connect(.claudeCode)
        let second = try Data(contentsOf: box.paths.claudeCodeConfig)

        #expect(first == second)
        let servers = try #require(parse(second)["mcpServers"] as? [String: Any])
        #expect(servers.count == 1)
        let entry = try #require(servers[ClaudeConnector.serverName] as? [String: Any])
        #expect(entry["command"] as? String == box.binary.path(percentEncoded: false))
        #expect(connector.connections[.claudeCode] == .connected(command: box.binary.path(percentEncoded: false)))
    }

    @Test("Connect preserves every byte of meaning in a config it did not write")
    func connectPreservesUnrelatedContent() throws {
        // The shape of a real ~/.claude.json: junk keys, an OAuth-shaped blob, a projects map,
        // a bare integer, a boolean, and a path with slashes. All of it must survive.
        let golden = """
        {
          "hasCompletedOnboarding": true,
          "installPath": "/usr/local/bin/claude",
          "junkNobodyKnows": {"nested": [1, 2, {"deep": false}]},
          "numberOfStartups": 1,
          "oauthAccount": {"accountUuid": "0f6e2c", "expiry": 1735689600, "scopes": ["read", "write"]},
          "projects": {
            "/Users/example/Code": {
              "history": ["open a.xlsx", "sum column B"],
              "mcpServers": {"other": {"command": "/bin/other"}}
            }
          }
        }
        """
        let box = try Sandbox()
        try box.seedClaudeCode(golden)
        let connector = box.connector(bundled: box.binary)
        try connector.connect(.claudeCode)

        let data = try Data(contentsOf: box.paths.claudeCodeConfig)
        let written = try parse(data)
        let original = try parse(Data(golden.utf8))
        for key in original.keys {
            #expect(jsonEqual(written[key], original[key]), "top-level key \(key) must survive the splice")
        }

        let servers = try #require(written["mcpServers"] as? [String: Any])
        let entry = try #require(servers[ClaudeConnector.serverName] as? [String: Any])
        #expect(entry["command"] as? String == box.binary.path(percentEncoded: false))
        #expect(entry["type"] as? String == "stdio")

        // Type fidelity is asserted on the serialised text, where a lie cannot hide: an integer
        // re-encoded as a double reads "1.0" and a boolean demoted to a number reads "1".
        let condensed = String(decoding: data, as: UTF8.self).filter { !$0.isWhitespace }
        #expect(condensed.contains(#""numberOfStartups":1,"#))
        #expect(condensed.contains(#""hasCompletedOnboarding":true,"#))
        #expect(condensed.contains(#""installPath":"/usr/local/bin/claude""#))
    }

    @Test("A config that does not parse is refused, byte-identical, and never backed up")
    func unparseableConfigRefusesTheWrite() throws {
        let box = try Sandbox()
        try box.seedClaudeCode("{ this is not json")
        let before = try Data(contentsOf: box.paths.claudeCodeConfig)
        let connector = box.connector(bundled: box.binary)

        do {
            try connector.connect(.claudeCode)
            Issue.record("connect must refuse a config it could not parse")
        } catch {
            guard case .fileNotWritable = error else {
                Issue.record("expected fileNotWritable, got \(error)")
                return
            }
        }

        #expect(try Data(contentsOf: box.paths.claudeCodeConfig) == before)
        #expect(!FileManager.default.fileExists(atPath: box.claudeCodeBackup.path(percentEncoded: false)))
    }

    @Test("A successful write over an existing file leaves a backup sibling with the pre-write bytes")
    func backupHoldsThePreviousGeneration() throws {
        let box = try Sandbox()
        try box.seedClaudeCode(#"{"keep": "me"}"#)
        let before = try Data(contentsOf: box.paths.claudeCodeConfig)
        let connector = box.connector(bundled: box.binary)

        try connector.connect(.claudeCode)

        let backup = try Data(contentsOf: box.claudeCodeBackup)
        #expect(backup == before)
        #expect(try Data(contentsOf: box.paths.claudeCodeConfig) != before)
    }

    @Test("An empty config file is unreadable, and connect refuses it")
    func emptyConfigIsUnreadable() throws {
        // The file existing means Claude Code has run; zero bytes means we cannot know what it
        // meant. Honest answer: unreadable, refuse — never "not installed", never a clobber.
        let box = try Sandbox()
        try box.seedClaudeCode("")
        let connector = box.connector(bundled: box.binary)

        guard case .unreadable = connector.connections[.claudeCode] else {
            Issue.record("expected .unreadable, got \(String(describing: connector.connections[.claudeCode]))")
            return
        }
        do {
            try connector.connect(.claudeCode)
            Issue.record("connect must refuse an empty config")
        } catch {
            guard case .fileNotWritable = error else {
                Issue.record("expected fileNotWritable, got \(error)")
                return
            }
        }
        let attributes = try FileManager.default.attributesOfItem(
            atPath: box.paths.claudeCodeConfig.path(percentEncoded: false)
        )
        #expect(attributes[.size] as? Int == 0)
    }

    @Test("Connect refuses a Claude Code that has never run")
    func connectRefusesWithoutTheConfigFile() throws {
        // D6: no ~/.claude.json means the client never ran, and a config Claude Code did not
        // write would register a server with a client that may not exist.
        let box = try Sandbox()
        let connector = box.connector(bundled: box.binary)

        #expect(connector.connections[.claudeCode] == .notInstalled)
        do {
            try connector.connect(.claudeCode)
            Issue.record("connect must refuse when Claude Code has never run")
        } catch {
            guard case .fileNotWritable = error else {
                Issue.record("expected fileNotWritable, got \(error)")
                return
            }
        }
        #expect(!FileManager.default.fileExists(atPath: box.paths.claudeCodeConfig.path(percentEncoded: false)))
    }

    // MARK: - Disconnect

    @Test("Disconnect removes the entry from the top level and from every project scope")
    func disconnectCleansBothScopes() throws {
        let box = try Sandbox()
        try box.seedClaudeCode("""
        {
          "junk": 7,
          "mcpServers": {
            "opensheets": {"args": [], "command": "/old/path", "env": {}, "type": "stdio"},
            "other": {"command": "/bin/other"}
          },
          "projects": {
            "/second/path": {"mcpServers": {"opensheets": {"command": "/x"}}},
            "/some/path": {
              "history": ["h"],
              "mcpServers": {
                "keeper": {"command": "/bin/keeper"},
                "opensheets": {"command": "/older/path"}
              }
            }
          }
        }
        """)
        let connector = box.connector(bundled: box.binary)

        try connector.disconnect(.claudeCode)

        let written = try parse(Data(contentsOf: box.paths.claudeCodeConfig))
        #expect(written["junk"] as? Int == 7)
        let servers = try #require(written["mcpServers"] as? [String: Any])
        #expect(servers[ClaudeConnector.serverName] == nil)
        #expect(jsonEqual(servers["other"], ["command": "/bin/other"]))

        let projects = try #require(written["projects"] as? [String: Any])
        let some = try #require(projects["/some/path"] as? [String: Any])
        let someServers = try #require(some["mcpServers"] as? [String: Any])
        #expect(someServers[ClaudeConnector.serverName] == nil)
        #expect(jsonEqual(someServers["keeper"], ["command": "/bin/keeper"]))
        #expect(jsonEqual(some["history"], ["h"]))
        let second = try #require(projects["/second/path"] as? [String: Any])
        let secondServers = try #require(second["mcpServers"] as? [String: Any])
        #expect(secondServers.isEmpty)
        #expect(connector.connections[.claudeCode] == .notConnected)
    }

    @Test("Disconnect when not connected writes nothing and throws nothing")
    func disconnectWhenAbsentIsANoOp() throws {
        let box = try Sandbox()
        try box.seedClaudeCode("""
        {"mcpServers": {"other": {"command": "/bin/other"}}, "projects": {"/p": {"mcpServers": {"x": {}}}}}
        """)
        let path = box.paths.claudeCodeConfig.path(percentEncoded: false)
        let before = try Data(contentsOf: box.paths.claudeCodeConfig)
        let attributesBefore = try FileManager.default.attributesOfItem(atPath: path)
        let connector = box.connector(bundled: box.binary)

        try connector.disconnect(.claudeCode)

        // Byte equality alone would pass even if the file had been atomically rewritten with
        // the same content; the inode is what proves no replace happened at all.
        let attributesAfter = try FileManager.default.attributesOfItem(atPath: path)
        #expect(try Data(contentsOf: box.paths.claudeCodeConfig) == before)
        #expect(
            attributesBefore[.systemFileNumber] as? NSNumber == attributesAfter[.systemFileNumber] as? NSNumber
        )
        #expect(
            attributesBefore[.modificationDate] as? Date == attributesAfter[.modificationDate] as? Date
        )
        #expect(!FileManager.default.fileExists(atPath: box.claudeCodeBackup.path(percentEncoded: false)))
    }

    // MARK: - Claude Desktop

    @Test("Desktop connect with no config and no directory creates both, and only the entry")
    func desktopConnectCreatesFromNothing() throws {
        let box = try Sandbox()
        let connector = box.connector(bundled: box.binary)
        #expect(connector.connections[.claudeDesktop] == .notInstalled)

        try connector.connect(.claudeDesktop)

        var isDirectory: ObjCBool = false
        let supportPath = box.paths.desktopSupportDirectory.path(percentEncoded: false)
        #expect(FileManager.default.fileExists(atPath: supportPath, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)

        let written = try parse(Data(contentsOf: box.paths.desktopConfig))
        #expect(written.count == 1)
        let servers = try #require(written["mcpServers"] as? [String: Any])
        #expect(servers.count == 1)
        let entry = try #require(servers[ClaudeConnector.serverName] as? [String: Any])
        #expect(entry.count == 2)
        #expect(entry["command"] as? String == box.binary.path(percentEncoded: false))
        #expect(entry["args"] as? [String] == [])

        // No pre-existing file, so nothing to back up — a zero-byte "backup" would be a trap.
        let backup = box.paths.desktopConfig.appendingPathExtension("opensheets-backup")
        #expect(!FileManager.default.fileExists(atPath: backup.path(percentEncoded: false)))
        #expect(connector.connections[.claudeDesktop] == .connected(command: box.binary.path(percentEncoded: false)))
    }

    // MARK: - Stale entries

    @Test("An entry pointing at a missing binary is stale, and reconnect heals it")
    func staleEntryHealsOnReconnect() throws {
        let box = try Sandbox()
        try box.seedClaudeCode("""
        {"mcpServers": {"opensheets": {"command": "/nowhere/opensheets-mcp"}}}
        """)
        let connector = box.connector(bundled: box.binary)
        #expect(connector.connections[.claudeCode] == .stale(command: "/nowhere/opensheets-mcp"))

        try connector.connect(.claudeCode)
        #expect(connector.connections[.claudeCode] == .connected(command: box.binary.path(percentEncoded: false)))
    }

    // MARK: - Binary resolution

    @Test("The bundled binary beats the fallback, the fallback stands in, and neither means nil")
    func serverBinaryResolutionOrder() throws {
        let box = try Sandbox()
        try Sandbox.plantExecutable(at: box.paths.fallbackBinary)

        #expect(box.connector(bundled: box.binary).serverBinary == box.binary)
        #expect(box.connector(bundled: nil).serverBinary == box.paths.fallbackBinary)

        // A bundled file without the executable bit is not a server; the fallback answers.
        let dud = box.root.appendingPathComponent("dud-binary")
        try Data("not executable".utf8).write(to: dud)
        #expect(box.connector(bundled: dud).serverBinary == box.paths.fallbackBinary)

        try FileManager.default.removeItem(at: box.paths.fallbackBinary)
        try box.seedClaudeCode(#"{"junk": "keep"}"#)
        let connector = box.connector(bundled: nil)
        #expect(connector.serverBinary == nil)
        do {
            try connector.connect(.claudeCode)
            Issue.record("connect must refuse when no server binary exists")
        } catch {
            guard case .fileNotWritable = error else {
                Issue.record("expected fileNotWritable, got \(error)")
                return
            }
        }
    }

    // MARK: - The sidebar mapping

    @Test("The sidebar status is D8's table: registered means idle, never a claimed live session")
    func mcpStatusMappingFollowsD8() {
        #expect(AppModel.mcpStatus(for: .connected(command: "/x")) == .idle)
        #expect(
            AppModel.mcpStatus(for: .stale(command: "/x"))
                == .failing("the registered server binary is missing — reconnect in Settings")
        )
        #expect(AppModel.mcpStatus(for: .unreadable(reason: "why")) == .failing("why"))
        #expect(AppModel.mcpStatus(for: .notConnected) == .notConfigured)
        #expect(AppModel.mcpStatus(for: .notInstalled) == .notConfigured)
    }
}

// MARK: - Harness

/// A scratch home: every path the connector can touch, under one disposable root.
@MainActor
private struct Sandbox {
    let root: URL
    let paths: ClaudeConnectorPaths
    /// A real executable file standing in for the bundled `opensheets-mcp`.
    let binary: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeConnectorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let support = root.appendingPathComponent("Library/Application Support/Claude", isDirectory: true)
        paths = ClaudeConnectorPaths(
            claudeCodeConfig: root.appendingPathComponent(".claude.json"),
            desktopConfig: support.appendingPathComponent("claude_desktop_config.json"),
            desktopSupportDirectory: support,
            // A UUID nothing on any machine registers, so LaunchServices always says no and the
            // support directory alone decides "installed" — the signal the test controls.
            desktopBundleIdentifier: "com.example.opensheets-tests.\(UUID().uuidString)",
            fallbackBinary: root.appendingPathComponent("usr-local-bin-opensheets-mcp")
        )
        binary = root.appendingPathComponent("opensheets-mcp")
        try Sandbox.plantExecutable(at: binary)
    }

    var claudeCodeBackup: URL {
        paths.claudeCodeConfig.appendingPathExtension("opensheets-backup")
    }

    func connector(bundled: URL?) -> ClaudeConnector {
        ClaudeConnector(paths: paths, bundledBinary: bundled)
    }

    func seedClaudeCode(_ json: String) throws {
        try Data(json.utf8).write(to: paths.claudeCodeConfig)
    }

    static func plantExecutable(at url: URL) throws {
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path(percentEncoded: false)
        )
    }
}

private func parse(_ data: Data) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

/// `NSObject.isEqual` over the bridged JSON values — the only equality that answers "did the
/// splice change anything it should not have" across nested dictionaries, arrays and numbers.
private func jsonEqual(_ lhs: Any?, _ rhs: Any?) -> Bool {
    guard let lhs = lhs as? NSObject, let rhs = rhs as? NSObject else { return false }
    return lhs.isEqual(rhs)
}
