import Foundation
import SheetModel
@testable import SheetStore
import Testing

// MARK: - Temporary directories

/// A scratch directory that removes itself.
///
/// Deliberately under `NSTemporaryDirectory()` rather than `/tmp`: `/tmp` is a symlink to
/// `/private/tmp`, and FSEvents reports resolved paths — a watcher test rooted at `/tmp` would
/// be testing the symlink-resolution code by accident instead of on purpose.
final class TemporaryDirectory: @unchecked Sendable {
    let url: URL

    init(_ name: String = "case") {
        url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("opensheets-tests")
            .appendingPathComponent("\(name)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func file(_ name: String, contents: String = "seed") -> URL {
        let target = url.appendingPathComponent(name)
        try? Data(contents.utf8).write(to: target)
        return target
    }

    func directory(_ name: String) -> URL {
        let target = url.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return target
    }
}

// MARK: - Watcher configuration

extension FileWatcher.Configuration {
    /// The production timings scaled down, so a test that needs 100 sequential filesystem
    /// round-trips finishes in seconds.
    ///
    /// The *shape* is unchanged — debounce then stability check then emit — so these tests
    /// exercise the same code path the product does. Only the clock moves.
    static let fast = FileWatcher.Configuration(
        debounce: .milliseconds(5),
        stabilityInterval: .milliseconds(4),
        maximumStabilityRetries: 20,
        rearmInterval: .milliseconds(40),
        fsEventsLatency: 0.004
    )
}

// MARK: - Event collection

/// Collects a watcher's events so a test can wait for the nth one.
///
/// Polling rather than `for await`: the assertions are about *how many* events arrived, and a
/// test that suspends on the stream cannot tell "none yet" from "none ever", which is exactly
/// the distinction the suppression tests turn on.
actor EventCollector {
    private var items: [FileWatcherEvent] = []
    private var task: Task<Void, Never>?

    /// Generous on purpose. Seven agents build on this machine at once (WAVE-1-ADDENDUM §8),
    /// and a watcher assertion that fails under load is a gate everyone learns to ignore.
    static let timeout: TimeInterval = 20

    func attach(_ watcher: FileWatcher) {
        task = Task { [weak self] in
            for await event in watcher.events { await self?.append(event) }
        }
    }

    private func append(_ event: FileWatcherEvent) { items.append(event) }

    var all: [FileWatcherEvent] { items }
    var count: Int { items.count }
    func stop() { task?.cancel() }

    /// Waits for at least `target` events. Returns whether they arrived.
    @discardableResult
    func waitForCount(_ target: Int, timeout: TimeInterval = EventCollector.timeout) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if items.count >= target { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return items.count >= target
    }

    /// Waits `interval`, then reports how many events arrived. For asserting that **none** do.
    func settle(_ interval: Duration = .milliseconds(400)) async -> Int {
        try? await Task.sleep(for: interval)
        return items.count
    }
}

extension FileWatcherEvent {
    var isChanged: Bool { if case .changed = self { true } else { false } }
    var isVanished: Bool { if case .vanished = self { true } else { false } }
    var isReappeared: Bool { if case .reappeared = self { true } else { false } }
    var isUnreadable: Bool { if case .unreadable = self { true } else { false } }
    var isAttributesChanged: Bool { if case .attributesChanged = self { true } else { false } }
}

// MARK: - Workbook fakes

/// A ``WorkbookReading`` that parses a trivial text format.
///
/// A6 develops against this rather than waiting on A1's real reader, exactly as the brief
/// requires. The format is `sheetName|row,col,value` per line, which is enough to make a
/// diff, a reload and a conflict all real without needing an xlsx.
struct FakeWorkbookReader: WorkbookReading {
    /// Set to make the next read throw — for reload-failure paths.
    final class Failure: @unchecked Sendable {
        private let lock = NSLock()
        private var value: SheetError?
        var error: SheetError? {
            get { lock.lock(); defer { lock.unlock() }; return value }
            set { lock.lock(); value = newValue; lock.unlock() }
        }
    }

    var failure = Failure()

    func canRead(_ url: URL) -> Bool { url.pathExtension == "fake" || url.pathExtension == "xlsx" }

    func readWorkbook(at url: URL) throws -> Workbook {
        if let error = failure.error { throw error }
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw SheetError.fileNotReadable(path: url.path(percentEncoded: false), underlying: "\(error)")
        }
        return try FakeWorkbookFormat.decode(text)
    }
}

/// The ``WorkbookWriting`` half of the fake.
struct FakeWorkbookWriter: WorkbookWriting {
    var refuses = false

    func canWrite(_ workbook: Workbook, to url: URL) -> Bool { !refuses }

    func encodeWorkbook(_ workbook: Workbook, for url: URL, originalBytes: Data?) throws -> Data {
        Data(FakeWorkbookFormat.encode(workbook).utf8)
    }
}

enum FakeWorkbookFormat {
    static func encode(_ workbook: Workbook) -> String {
        var lines: [String] = []
        for sheet in workbook.sheets {
            lines.append("#sheet \(sheet.id.rawValue) \(sheet.name)")
            guard let used = sheet.cells.usedRange else { continue }
            sheet.cells.forEachCell(in: used) { ref, cell in
                lines.append("\(sheet.id.rawValue)|\(ref.row),\(ref.column),\(cell.value.description)")
            }
        }
        return lines.joined(separator: "\n")
    }

    static func decode(_ text: String) throws -> Workbook {
        var sheets: [SheetID: Sheet] = [:]
        var order: [SheetID] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("#sheet ") {
                let parts = line.dropFirst(7).split(separator: " ", maxSplits: 1)
                guard let raw = Int32(parts.first ?? "") else { continue }
                let id = SheetID(raw)
                sheets[id] = Sheet(id: id, name: parts.count > 1 ? String(parts[1]) : "Sheet\(raw)")
                order.append(id)
                continue
            }
            let halves = line.split(separator: "|", maxSplits: 1)
            guard halves.count == 2, let raw = Int32(halves[0]) else { continue }
            let fields = halves[1].split(separator: ",", maxSplits: 2)
            guard fields.count == 3, let row = Int(fields[0]), let column = Int(fields[1]) else { continue }
            let id = SheetID(raw)
            if sheets[id] == nil {
                sheets[id] = Sheet(id: id, name: "Sheet\(raw)")
                order.append(id)
            }
            let value = String(fields[2])
            let cell = Cell(value: Double(value).map { CellValue.number($0) } ?? .text(value))
            try sheets[id]?.cells.setCell(cell, at: CellRef(row: row, column: column))
        }
        return Workbook(sheets: order.compactMap { sheets[$0] })
    }
}

/// A workbook with `rows` × `columns` numeric cells on one sheet.
func makeSheet(id: SheetID = 1, name: String = "Data", rows: Int, columns: Int, seed: Double = 0) -> Sheet {
    var sheet = Sheet(id: id, name: name)
    for row in 0 ..< rows {
        for column in 0 ..< columns {
            try? sheet.cells.setCell(
                Cell(value: .number(seed + Double(row * columns + column))),
                at: CellRef(row: row, column: column)
            )
        }
    }
    return sheet
}

// MARK: - Subprocess helpers

enum Shell {
    /// Runs a shell command to completion and returns its exit status.
    @discardableResult
    static func run(_ command: String) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return -1
        }
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// Starts a shell command without waiting, so the caller can signal it.
    static func spawn(_ command: String) -> Process? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        return process
    }
}

/// Bytes of a file, for byte-identity assertions.
func bytes(of url: URL) -> Data? {
    try? Data(contentsOf: url)
}
