import Foundation

/// Reads `Sources/GlassUI` off disk and cuts it into reviewable regions.
///
/// The lint in `GlassLintTests` is a **source scan, not an AST pass**, and it is worth being
/// precise about what that buys and what it costs.
///
/// What it buys: the rules it enforces — "one lens per cluster", "no shadow on glass", "colour
/// literals live in one file" — are the rules that get broken by someone adding a component in a
/// hurry, six months from now, in a file nobody re-reads. A `swift-syntax` dependency would make
/// the check exact and would also make it the only external dependency in this target. A grep that
/// runs on every commit catches more real regressions than a perfect analysis that never ships.
///
/// What it costs, stated plainly so nobody trusts it further than it deserves:
/// - It cannot see into a `ViewBuilder` closure passed to another type, so a glass element inside
///   `ToolbarGroup { … }` is attributed to the enclosing view rather than to the group.
/// - It counts *mentions*, not *renders*, so a `switch` that shows one of five glass components
///   looks like five. That is what the `// glass-lint: separated` annotation is for, and the
///   annotated set is pinned by a test so the escape hatch cannot quietly grow.
/// - It splits files by column-0 declarations rather than by braces. That is reliable here because
///   `.swiftformat` runs over this package, and it is much harder to get subtly wrong than a
///   hand-rolled brace counter that has to know about string literals and comments.
enum GlassSource {
    /// One reviewable unit: a top-level type, extension, or `#Preview`.
    ///
    /// Rules run against ``code`` (comments stripped) rather than ``text``. Every doc comment in
    /// this package explains a rule by naming the thing it forbids — `.glassEffect`, `.shadow`,
    /// `.ultraThinMaterial` — so a scan that reads comments flags the documentation for describing
    /// the law. The annotation search deliberately uses ``text``, because the annotation *is* a
    /// comment.
    struct Region {
        let file: String
        let name: String
        let startLine: Int
        let lines: [String]

        var text: String { lines.joined(separator: "\n") }

        /// The lines with comments removed. Doc comments and full-line comments go entirely;
        /// a trailing `//` on a code line is truncated.
        var code: String { GlassSource.stripComments(lines).joined(separator: "\n") }

        var location: String { "\(file):\(startLine) (\(name))" }

        func occurrences(of needle: String) -> Int {
            GlassSource.count(needle, in: code)
        }

        /// Searches the code, not the comments, at a word boundary.
        func contains(_ needle: String) -> Bool { occurrences(of: needle) > 0 }

        /// Searches everything, comments included. Only the lint annotation uses this.
        func containsAnnotation(_ needle: String) -> Bool { text.contains(needle) }
    }

    /// Counts occurrences that start at a **left word boundary**.
    ///
    /// Without this, `case setColor(SheetID, Int?)` matches the banned `Color(` and
    /// `DS.Surface.border(context)` matches the banned `.border(`. Both were real false positives
    /// on the first run, and both are the kind that gets a lint switched off rather than fixed.
    /// A match only counts when the character before it is not part of an identifier.
    static func count(_ needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var search = haystack[...]
        while let range = search.range(of: needle) {
            let boundary: Bool
            if range.lowerBound == haystack.startIndex {
                boundary = true
            } else {
                let previous = haystack[haystack.index(before: range.lowerBound)]
                boundary = !(previous.isLetter || previous.isNumber || previous == "_")
            }
            if boundary { count += 1 }
            search = search[range.upperBound...]
        }
        return count
    }

    /// Drops comments. Not a lexer: it does not know about `/* */` (this package has none) or
    /// about `//` inside a string literal (likewise). Both are asserted absent by
    /// ``GlassLintTests/scanIsNotSilentlyEmpty()``'s sibling checks staying green — if either ever
    /// appears, a rule will fire on a line that looks innocent and this comment is the first place
    /// to look.
    static func stripComments(_ lines: [String]) -> [String] {
        lines.map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") { return "" }
            guard let range = line.range(of: "//") else { return line }
            // `https://` inside a code line is the one legitimate double slash.
            if line[..<range.lowerBound].hasSuffix(":") { return line }
            return String(line[..<range.lowerBound])
        }
    }

    /// `Sources/GlassUI`, found by walking up from this test file.
    ///
    /// `resolvingSymlinksInPath()` is not decoration. `FileManager`'s directory enumerator will
    /// not descend through a symlinked root, and a scan that quietly reads zero files passes every
    /// rule below — which is the failure mode of every source-scanning test ever written. That is
    /// also why ``GlassLintTests/scanIsNotSilentlyEmpty()`` exists: it is the test that tests the
    /// tests, and it is the one that caught this.
    static var sourceDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .resolvingSymlinksInPath()
            .deletingLastPathComponent() // GlassUITests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // OpenSheetsCore
            .appendingPathComponent("Sources/GlassUI")
            .resolvingSymlinksInPath()
    }

    /// Every `.swift` file under `Sources/GlassUI`, as (relative path, contents).
    static func files() throws -> [(path: String, contents: String)] {
        let root = sourceDirectory
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey]
        )
        var result: [(String, String)] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let relative = url.resolvingSymlinksInPath().path
                .replacingOccurrences(of: root.path + "/", with: "")
            result.append((relative, try String(contentsOf: url, encoding: .utf8)))
        }
        return result.sorted { $0.0 < $1.0 }
    }

    /// A declaration that starts a new region: column 0, and one of the shapes we care about.
    private static func regionName(for line: String) -> String? {
        guard let first = line.first, !first.isWhitespace else { return nil }
        if line.hasPrefix("#Preview") {
            // `#Preview("Toolbar · light") {` → `#Preview Toolbar · light`
            let title = line
                .drop(while: { $0 != "\"" })
                .dropFirst()
                .prefix(while: { $0 != "\"" })
            return title.isEmpty ? "#Preview" : "#Preview \(title)"
        }
        var words = line.split(separator: " ").map(String.init)
        let modifiers: Set<String> = ["public", "internal", "private", "fileprivate", "final", "@MainActor"]
        while let head = words.first, modifiers.contains(head) { words.removeFirst() }
        guard let kind = words.first, ["struct", "class", "enum", "extension"].contains(kind),
              words.count > 1 else { return nil }
        let name = words[1]
            .prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." }
        guard !name.isEmpty else { return nil }
        return kind == "extension" ? "extension \(name)" : String(name)
    }

    /// Cuts every file into regions. Lines before the first declaration (imports, file-level doc
    /// comments) are attributed to a `<header>` region so nothing is silently unscanned.
    static func regions() throws -> [Region] {
        var result: [Region] = []
        for (path, contents) in try files() {
            let lines = contents.components(separatedBy: "\n")
            var currentName = "<header>"
            var currentStart = 1
            var buffer: [String] = []

            func flush(endingAt index: Int) {
                guard !buffer.isEmpty else { return }
                result.append(
                    Region(file: path, name: currentName, startLine: currentStart, lines: buffer)
                )
                buffer = []
                _ = index
            }

            for (offset, line) in lines.enumerated() {
                if let name = regionName(for: line) {
                    flush(endingAt: offset)
                    currentName = name
                    currentStart = offset + 1
                }
                buffer.append(line)
            }
            flush(endingAt: lines.count)
        }
        return result
    }

    // MARK: - Vocabulary

    /// Everything that puts a lens on screen. `.buttonStyle(.glass)` counts: a glass button *is*
    /// a glass element, and three of them in a row without a container is exactly the stacked-blur
    /// look the rule exists to prevent.
    static let glassApplications = [
        ".glassEffect(",
        ".glassSurface(",
        ".glassPill(",
        ".glassCard(",
        ".glassChrome(",
        ".buttonStyle(.glass)",
        ".buttonStyle(.glassProminent)",
    ]

    /// The raw SwiftUI glass API. Allowed in exactly one file.
    static let rawGlassAPIs = [
        ".glassEffect(",
        ".glassEffectID(",
        ".glassEffectTransition(",
        ".glassEffectUnion(",
        "GlassEffectContainer(",
    ]

    static let clusterConstructs = ["GlassCluster(", "GlassEffectContainer("]

    /// Materials are banned outright. The reduce-transparency fallback is a **solid** token plus a
    /// hairline, not a thinner blur — see ``GlassSurface``. A material anywhere in this package is
    /// either fake glass or glass behind data, and both are the thing PLAN.md §3 forbids.
    static let bannedMaterials = [
        ".ultraThinMaterial", ".thinMaterial", ".regularMaterial",
        ".thickMaterial", ".ultraThickMaterial", "Material.",
    ]

    /// Named hues. `Color.primary`, `.secondary`, `.accentColor` and `.clear` are semantic and
    /// stay legal everywhere; these are decisions, and decisions live in ``Palette``.
    static let bannedNamedColors = [
        "Color.blue", "Color.red", "Color.green", "Color.orange", "Color.yellow",
        "Color.purple", "Color.pink", "Color.mint", "Color.teal", "Color.indigo",
        "Color.brown", "Color.cyan", "Color.gray", "Color.black",
    ]

    static let colorConstructors = ["Color(", "RGBA(hex:", "RGBA(red:", "RGBA(white:"]

    /// The file that owns the raw glass API. Also exempt from the cluster rule: the four
    /// `extension View` entry points in it each apply glass once, which is a definition rather
    /// than an arrangement, and there is nothing there to merge.
    static let glassSurfaceFile = "Surfaces/GlassSurface.swift"

    /// The directory that owns colour literals.
    static let tokensDirectory = "Tokens/"

    /// Regions that render one glass element at a time, or place them at opposite ends of a
    /// window, and therefore do not want a shared container.
    ///
    /// **This list is asserted exactly.** Adding an entry is a visible diff with a reason next to
    /// it in the source, which is the only thing that keeps an escape hatch from becoming a
    /// habit.
    /// One entry. The gallery was the second candidate and turned out not to need it — clustering
    /// the two demo arrangements that genuinely wanted a shared lens made the rule pass honestly,
    /// which is the outcome an escape hatch is supposed to make you look for first.
    static let separatedAllowList: Set<String> = [
        "DocumentScene",
    ]

    static let separatedMarker = "// glass-lint: separated"
}
