//
//  FixtureLibrary.swift
//  TestSupport
//
//  Finding the golden corpus from inside a test, without SwiftPM resources.
//

import Foundation
import SheetModel

/// Locates `Fixtures/` and reads what is in it.
///
/// The corpus deliberately is **not** a SwiftPM resource bundle. Declaring it as one would copy
/// 2.7 MB into every test target's bundle, make `Package.swift` a file eight agents have to
/// edit, and — worse — hand each target its own copy, so a fixture fixed in one place would
/// still be stale in another. Instead the directory is found on disk by walking up from this
/// source file until a checkout root appears.
///
/// `OPENSHEETS_FIXTURES` overrides the search, which is what a CI job with an unusual layout or
/// a developer testing against a modified corpus needs.
public enum FixtureLibrary {
    /// The corpus categories, matching the directory names.
    public enum Category: String, Sendable, Hashable, CaseIterable {
        case basic
        case formulas
        case formats
        case structure
        case passthrough
        case csv
        case perf
        case hostile
    }

    /// Something went wrong finding or reading a fixture.
    ///
    /// Its own type rather than a ``SheetError``: `SheetError` is the *product's* vocabulary and
    /// "the test corpus is missing" is not a thing the product can ever report.
    public enum FixtureError: Error, CustomStringConvertible {
        case corpusNotFound(searchedFrom: String)
        case missing(path: String, in: String)
        case malformedSidecar(path: String, detail: String)

        public var description: String {
            switch self {
            case let .corpusNotFound(from):
                """
                Could not find the Fixtures/ directory. Walked up from \(from) looking for a \
                directory containing both PLAN.md and Fixtures/README.md. Set OPENSHEETS_FIXTURES \
                to point at the corpus if this checkout has an unusual layout.
                """
            case let .missing(path, root):
                "No fixture at \(path) (looked in \(root))."
            case let .malformedSidecar(path, detail):
                "\(path) is not a valid .expected.json sidecar: \(detail)"
            }
        }
    }

    /// The `Fixtures/` directory.
    ///
    /// Resolved once and cached; the answer cannot change during a process.
    public static let root: URL? = resolveRoot()

    /// The checkout root — the directory holding `PLAN.md`.
    public static let repositoryRoot: URL? = root?.deletingLastPathComponent()

    /// Whether the corpus is reachable. Guard a fixture-driven suite with
    /// `.enabled(if: FixtureLibrary.isAvailable)` rather than letting it fail obscurely.
    public static var isAvailable: Bool { root != nil }

    /// The `Fixtures/`-relative URL, whether or not the file exists.
    public static func url(_ relativePath: String) throws -> URL {
        guard let root else { throw FixtureError.corpusNotFound(searchedFrom: #filePath) }
        return root.appendingPathComponent(relativePath)
    }

    /// Whether a fixture is present. `perf/1m-cells.xlsx` and `perf/2gb.csv` are generated on
    /// demand and git-ignored, so this is a real question.
    public static func exists(_ relativePath: String) -> Bool {
        guard let url = try? url(relativePath) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// A fixture's bytes.
    public static func data(_ relativePath: String) throws -> Data {
        let url = try url(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw FixtureError.missing(path: relativePath, in: root?.path ?? "?")
        }
        return try Data(contentsOf: url)
    }

    /// A text fixture's contents, decoded as UTF-8.
    ///
    /// Only for the fixtures that *are* UTF-8. `csv/utf16le.csv` exists precisely so a reader
    /// has to detect its encoding; read that one with ``data(_:)``.
    public static func text(_ relativePath: String) throws -> String {
        String(decoding: try data(relativePath), as: UTF8.self)
    }

    /// The `.expected.json` sidecar for a fixture.
    ///
    /// `relativePath` is the fixture itself — `basic/minimal.xlsx` — not the sidecar.
    public static func expected(for relativePath: String) throws -> ExpectedWorkbook {
        let sidecarPath = relativePath + ".expected.json"
        let bytes = try data(sidecarPath)
        do {
            return try JSONDecoder().decode(ExpectedWorkbook.self, from: bytes)
        } catch {
            throw FixtureError.malformedSidecar(path: sidecarPath, detail: "\(error)")
        }
    }

    /// Every fixture in a category that has a sidecar, as `Fixtures/`-relative paths, sorted.
    ///
    /// Driven by the sidecars rather than by the data files so that a fixture added without
    /// ground truth is invisible here — a file nobody wrote an expectation for cannot be
    /// asserted against, and silently iterating over it would prove nothing.
    public static func fixtures(in category: Category) -> [String] {
        guard let root else { return [] }
        let directory = root.appendingPathComponent(category.rawValue)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .filter { $0.hasSuffix(".expected.json") }
            .map { "\(category.rawValue)/\($0.replacingOccurrences(of: ".expected.json", with: ""))" }
            .sorted()
    }

    /// Every fixture in the corpus that has a sidecar, across all categories.
    public static var allFixtures: [String] {
        Category.allCases.flatMap { fixtures(in: $0) }
    }

    /// Every fixture that exists on disk *and* has a sidecar — what a corpus-wide test should
    /// iterate, since the three big `perf/` files are generated rather than committed.
    public static var availableFixtures: [String] {
        allFixtures.filter(exists)
    }

    /// The hostile corpus's error expectations.
    public static func hostileExpectations() throws -> HostileExpectations {
        let bytes = try data("hostile/expected-errors.json")
        do {
            return try JSONDecoder().decode(HostileExpectations.self, from: bytes)
        } catch {
            throw FixtureError.malformedSidecar(path: "hostile/expected-errors.json", detail: "\(error)")
        }
    }

    // MARK: - Finding the corpus

    private static func resolveRoot() -> URL? {
        if let override = ProcessInfo.processInfo.environment["OPENSHEETS_FIXTURES"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let manager = FileManager.default
        // Two starting points, because `#filePath` is baked in at compile time and a package
        // consumed from a cache directory would have a stale one. The working directory is the
        // fallback for exactly that case.
        let starts = [URL(fileURLWithPath: #filePath), URL(fileURLWithPath: manager.currentDirectoryPath)]
        for start in starts {
            var directory = start.deletingLastPathComponent()
            // 12 is deeper than any plausible checkout nesting, and bounded so a symlink loop
            // cannot turn a missing corpus into a hang.
            for _ in 0 ..< 12 {
                let candidate = directory.appendingPathComponent("Fixtures")
                let marker = candidate.appendingPathComponent("README.md")
                if manager.fileExists(atPath: marker.path) {
                    return candidate
                }
                let parent = directory.deletingLastPathComponent()
                if parent.path == directory.path { break }
                directory = parent
            }
        }
        return nil
    }
}

/// `Fixtures/hostile/expected-errors.json`, decoded.
///
/// Wave 1 addendum §6: A0's `SheetError.code` strings are the source of truth and A1 owns
/// reconciling this file to them. That makes ``HostileExpectations/Case/expectedError`` a
/// `String`, not an enum — it has to be able to name a code this build does not yet produce, or
/// the reconciliation could never be tested.
public struct HostileExpectations: Sendable, Codable {
    /// One hostile fixture and the defence it must trigger.
    public struct Case: Sendable, Codable, Hashable {
        /// `Fixtures/`-relative path.
        public var file: String
        /// The ``SheetError/code`` the reader must produce, or `nil` when the file must open.
        public var expectedError: String?
        /// `throw`, or a description of the required success behaviour.
        public var expectedBehavior: String?
        /// Codes that indicate the same defence firing at a different layer.
        public var alsoAcceptable: [String]?
        /// Outcomes that are failures regardless of the error code.
        public var mustNotHappen: [String]?
        public var limit: String?
        public var proves: String?
        public var notes: String?

        /// Whether `code` satisfies this case.
        public func accepts(code: String) -> Bool {
            code == expectedError || (alsoAcceptable ?? []).contains(code)
        }

        /// Whether this file is expected to open rather than throw.
        public var expectsSuccess: Bool { expectedError == nil }
    }

    public var count: Int?
    public var cases: [Case]

    /// The expectation for one fixture path, e.g. `hostile/zip-bomb.xlsx`.
    public func expectation(for file: String) -> Case? {
        cases.first { $0.file == file }
    }
}
