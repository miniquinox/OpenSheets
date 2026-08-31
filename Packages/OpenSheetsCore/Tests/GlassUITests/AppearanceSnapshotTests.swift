import Foundation
import Testing

@testable import GlassUI

/// Every component × {light, dark} × {normal, reduceTransparency, increaseContrast}, as text.
///
/// **Why not pixels.** PLAN.md §10.5 asks for snapshot tests, and the obvious reading is PNGs. Two
/// things make that dishonest here. Real Liquid Glass is composited by the window server: an
/// offscreen `ImageRenderer` produces the *layout* with the lens missing, so a green PNG suite
/// would be proof that the one thing this project is judged on had not been rendered at all. And
/// pixel goldens of text drift with font rasterisation across OS point releases, which turns a
/// design regression test into a thing people re-record until they stop reading it.
///
/// So these record the **decisions** instead: for each component, which surface tier it asks for,
/// what that tier resolves to in this appearance (real glass and its recipe, or the exact opaque
/// token and hairline), and the full token set behind it. That catches every regression a pixel
/// diff would catch except pure layout — a wrong colour, a missing reduce-transparency path, a
/// hairline that stopped getting heavier under increase-contrast — and it catches them as a
/// readable diff of hex values rather than as "this image changed".
///
/// Layout and the real lens are checked the other way: by looking, in `GlassUIGallery`, with the
/// screenshots in `docs/design/` as the record.
@Suite("Appearance snapshots")
struct AppearanceSnapshotTests {
    /// Set `GLASSUI_RECORD_SNAPSHOTS=1` to rewrite the goldens. They are committed; a diff in one
    /// is a design change and should be read as one in review.
    static var isRecording: Bool {
        ProcessInfo.processInfo.environment["GLASSUI_RECORD_SNAPSHOTS"] == "1"
    }

    /// The goldens live in `docs/design/snapshots/`, not next to this file.
    ///
    /// Two reasons, one practical and one editorial. SwiftPM warns about any file inside a target
    /// directory that is neither source nor a declared resource, and `Package.swift` belongs to
    /// A0 — a `.txt` under `Tests/GlassUITests/` would mean either a manifest edit outside this
    /// agent's scope or a permanent build warning, and the project builds warnings-as-errors.
    /// Editorially they belong there anyway: a golden here is a written record of what the design
    /// system resolves to, and it reads next to the screenshots rather than next to the test.
    static var snapshotDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .resolvingSymlinksInPath()
            .deletingLastPathComponent() // GlassUITests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // OpenSheetsCore
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // <repo root>
            .appendingPathComponent("docs/design/snapshots")
    }

    @Test("Component surfaces resolve identically to the golden", arguments: AppearanceContext.snapshotMatrix)
    func componentSurfaces(_ context: AppearanceContext) throws {
        var lines = ["# \(context.snapshotName)", ""]
        lines.append("## Components")
        for component in ComponentCatalog.all {
            let described = if let vibrancy = component.vibrancy {
                VibrancyResolution.resolve(role: vibrancy, context: context).description
            } else {
                GlassResolution.resolve(
                    tier: component.tier,
                    signal: component.signal,
                    context: context
                ).description
            }
            let name = component.name.padding(toLength: 22, withPad: " ", startingAt: 0)
            let shape = component.shape.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0)
            lines.append("  \(name) \(shape) \(described)")
        }

        lines.append("")
        lines.append("## Signals")
        for kind in DS.SignalKind.allCases {
            let tint = DS.Signal.tintValue(kind, context)?.hexString ?? "—"
            let name = kind.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0)
            lines.append("  \(name) tint \(tint)  glyph \(kind.symbolName)  label \(kind.label)")
        }

        lines.append("")
        lines.append("## Strokes")
        lines.append("  hairline  \(String(format: "%.1f", DS.Stroke.hairline(context)))pt")
        lines.append("  selection \(String(format: "%.1f", DS.Stroke.selection(context)))pt")

        lines.append("")
        lines.append(GridTheme.resolved(context).snapshotDescription)

        try assertMatchesGolden(lines.joined(separator: "\n"), named: context.snapshotName)
    }

    @Test("Every component in the catalog is really wired to the surface it claims")
    func catalogMatchesSource() throws {
        // The catalog is a second description of the components, and a second description drifts.
        // This is the cheap seam that stops it: each entry names the modifier it expects to find
        // in the component's own file. If somebody changes DiffPanel from a card to a pill, the
        // catalog — and therefore the six goldens — has to be updated with it.
        let files = Dictionary(uniqueKeysWithValues: try GlassSource.files())
        for component in ComponentCatalog.all {
            guard let source = files[component.file] else {
                Issue.record("\(component.name): \(component.file) is not in Sources/GlassUI")
                continue
            }
            #expect(
                source.contains(component.expectedModifier),
                """
                \(component.name) claims \(component.expectedModifier) but \(component.file) does \
                not contain it. Either the component changed tier, or the catalog is stale — and \
                a stale catalog means six golden files describing a design that no longer exists.
                """
            )
        }
    }

    @Test("Reduce-transparency removes every lens")
    func reduceTransparencyIsAbsolute() {
        for scheme in [GlassColorScheme.light, .dark] {
            let context = AppearanceContext(colorScheme: scheme, reduceTransparency: true)
            for component in ComponentCatalog.all {
                let resolution = GlassResolution.resolve(
                    tier: component.tier,
                    signal: component.signal,
                    context: context
                )
                #expect(
                    !resolution.usesRealGlass,
                    "\(component.name) still uses glass under reduce-transparency"
                )
                #expect(
                    resolution.solidFill?.alpha == 1,
                    """
                    \(component.name)'s fallback is \(resolution.solidFill?.hexString ?? "nil") — \
                    a translucent fallback is not a fallback. The setting asks for opacity.
                    """
                )
                #expect(
                    resolution.borderWidth > 0,
                    "\(component.name) lost its hairline; with no glass edge there is no edge at all"
                )
            }
        }
    }

    @Test("Increase-contrast never removes contrast", arguments: [GlassColorScheme.light, .dark])
    func increaseContrastOnlyAdds(_ scheme: GlassColorScheme) {
        let plain = AppearanceContext(colorScheme: scheme, reduceTransparency: true)
        let bold = AppearanceContext(
            colorScheme: scheme,
            reduceTransparency: true,
            increaseContrast: true
        )
        let plainBorder = DS.Surface.borderColor(plain)
        let boldBorder = DS.Surface.borderColor(bold)
        let surface = DS.Surface.floatingColor(plain)

        #expect(
            boldBorder.contrastRatio(against: surface) > plainBorder.contrastRatio(against: surface),
            "\(scheme): the hairline did not get stronger under increase-contrast"
        )
        #expect(DS.Stroke.hairline(bold) > DS.Stroke.hairline(plain))
    }

    @Test("Reduce-motion swaps the morph for a cross-fade, and nothing else")
    func reduceMotionOnlyAffectsMotion() {
        let still = AppearanceContext(colorScheme: .dark, reduceMotion: true)
        let moving = AppearanceContext(colorScheme: .dark)

        #expect(DS.Motion.morph(still) == DS.Motion.crossFade)
        #expect(DS.Motion.morph(moving) == DS.Motion.standard)
        // Reduce-motion is a timing setting. If it changed a colour, the snapshot matrix would
        // need a seventh axis and every golden would double.
        #expect(GridTheme.resolved(still) == GridTheme.resolved(moving))
        #expect(
            GlassResolution.resolve(tier: .floating, context: still)
                == GlassResolution.resolve(tier: .floating, context: moving)
        )
    }

    @Test("The snapshot matrix is the six states the plan asks for")
    func matrixIsComplete() {
        let names = AppearanceContext.snapshotMatrix.map(\.snapshotName)
        #expect(
            names == [
                "light-normal", "light-reduceTransparency", "light-increaseContrast",
                "dark-normal", "dark-reduceTransparency", "dark-increaseContrast",
            ]
        )
        #expect(Set(names).count == names.count, "two contexts snapshot to the same filename")
    }

    // MARK: - Golden files

    private func assertMatchesGolden(
        _ actual: String,
        named name: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let directory = Self.snapshotDirectory
        let url = directory.appendingPathComponent("\(name).txt")

        guard !Self.isRecording, FileManager.default.fileExists(atPath: url.path) else {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try actual.write(to: url, atomically: true, encoding: .utf8)
            Issue.record(
                "Recorded \(name).txt. Re-run to compare; commit the file.",
                sourceLocation: sourceLocation
            )
            return
        }

        let expected = try String(contentsOf: url, encoding: .utf8)
        if expected != actual {
            Issue.record(
                Comment(rawValue: firstDifference(expected: expected, actual: actual, name: name)),
                sourceLocation: sourceLocation
            )
        }
    }

    /// The first differing line, rather than a wall of text. A snapshot failure that dumps two
    /// 60-line files is a snapshot failure nobody reads.
    private func firstDifference(expected: String, actual: String, name: String) -> String {
        let expectedLines = expected.components(separatedBy: "\n")
        let actualLines = actual.components(separatedBy: "\n")
        for index in 0 ..< max(expectedLines.count, actualLines.count) {
            let old = index < expectedLines.count ? expectedLines[index] : "<missing>"
            let new = index < actualLines.count ? actualLines[index] : "<missing>"
            if old != new {
                return """
                \(name).txt differs at line \(index + 1):
                  golden: \(old)
                  actual: \(new)
                Re-record with GLASSUI_RECORD_SNAPSHOTS=1 once you have decided the change is right.
                """
            }
        }
        return "\(name).txt differs in trailing whitespace"
    }
}

/// The components, their tier, and where they live.
///
/// One declaration, used by the goldens and cross-checked against the source by
/// ``AppearanceSnapshotTests/catalogMatchesSource()``. It is also the shortest honest answer to
/// "what surfaces does this design system have", which is worth having in one place.
enum ComponentCatalog {
    enum Shape: String {
        case capsule
        case card
        case panel
        case control
        case none
    }

    struct Entry {
        let name: String
        let file: String
        let tier: GlassTier
        let signal: DS.SignalKind
        let shape: Shape
        let expectedModifier: String
        /// Non-`nil` when this surface is a **material** rather than a lens — an edge band that
        /// borders the desktop. Those resolve through ``VibrancyResolution`` instead of
        /// ``GlassResolution``, and the golden has to say which, or it describes a lens that is
        /// not there. See ``ChromeVibrancy``.
        var vibrancy: ChromeVibrancy?

        init(
            name: String,
            file: String,
            tier: GlassTier,
            signal: DS.SignalKind,
            shape: Shape,
            expectedModifier: String,
            vibrancy: ChromeVibrancy? = nil
        ) {
            self.name = name
            self.file = file
            self.tier = tier
            self.signal = signal
            self.shape = shape
            self.expectedModifier = expectedModifier
            self.vibrancy = vibrancy
        }
    }

    static let all: [Entry] = [
        Entry(
            name: "ToolbarSurface", file: "Chrome/ToolbarSurface.swift",
            tier: .chrome, signal: .neutral, shape: .none, expectedModifier: ".buttonStyle(.glass)"
        ),
        Entry(
            name: "FormulaBar", file: "Chrome/FormulaBar.swift",
            tier: .chrome, signal: .neutral, shape: .control, expectedModifier: ".glassChrome("
        ),
        Entry(
            name: "SheetTabBar", file: "Chrome/SheetTabBar.swift",
            tier: .chrome, signal: .neutral, shape: .control, expectedModifier: ".glassChrome("
        ),
        // The two side columns are **materials**, not lenses. They border the desktop rather than
        // the grid, and a lens with no window content behind it shows the wallpaper at full
        // sharpness — see ``ChromeVibrancy``. `.none` shape because a flush band has no radius.
        Entry(
            name: "Sidebar", file: "Chrome/Sidebar.swift",
            tier: .chrome, signal: .neutral, shape: .none,
            expectedModifier: ".vibrantChrome(", vibrancy: .sidebar
        ),
        Entry(
            name: "Inspector", file: "Chrome/Inspector.swift",
            tier: .chrome, signal: .neutral, shape: .none,
            expectedModifier: ".vibrantChrome(", vibrancy: .sidebar
        ),
        Entry(
            name: "SelectionStatsPill", file: "Floating/SelectionStatsPill.swift",
            tier: .floating, signal: .neutral, shape: .capsule, expectedModifier: ".glassPill("
        ),
        Entry(
            name: "CommandPalette", file: "Floating/CommandPalette.swift",
            tier: .floating, signal: .neutral, shape: .card, expectedModifier: ".glassCard("
        ),
        Entry(
            name: "SnapshotBrowser", file: "Floating/SnapshotBrowser.swift",
            tier: .floating, signal: .neutral, shape: .card, expectedModifier: ".glassCard("
        ),
        // The chat pair morphs like the sync surface's, and takes the plain floating tier at
        // both sizes — the stats pill's own glass. A frosted `hud` tier was tried here and
        // removed: tinting the lens read as paint, and the volume HUD it chased turned out to
        // be exactly this untinted glass.
        Entry(
            name: "ChatBubble", file: "Floating/ChatSurface.swift",
            tier: .floating, signal: .neutral, shape: .capsule, expectedModifier: ".glassPill("
        ),
        Entry(
            name: "ChatPanel", file: "Floating/ChatSurface.swift",
            tier: .floating, signal: .neutral, shape: .panel, expectedModifier: ".glassCard("
        ),
        // `.none` because the launcher card is flush: it fills its window, so the corners are the
        // window's and it has no radius of its own. Same reason the toolbar and sidebar are `.none`.
        Entry(
            name: "LauncherWindow", file: "Launcher/LauncherWindow.swift",
            tier: .floating, signal: .neutral, shape: .none, expectedModifier: ".glassCard("
        ),
        Entry(
            name: "RefreshPill", file: "Sync/SyncSurface.swift",
            tier: .signal, signal: .agent, shape: .capsule, expectedModifier: ".glassPill("
        ),
        Entry(
            name: "RefreshPill/conflict", file: "Sync/SyncSurface.swift",
            tier: .signal, signal: .conflict, shape: .capsule, expectedModifier: ".glassPill("
        ),
        Entry(
            name: "RefreshPill/failure", file: "Sync/SyncSurface.swift",
            tier: .signal, signal: .failure, shape: .capsule, expectedModifier: ".glassPill("
        ),
        Entry(
            name: "DiffPanel", file: "Sync/SyncSurface.swift",
            tier: .floating, signal: .neutral, shape: .card, expectedModifier: ".glassCard("
        ),
        Entry(
            name: "ConflictBanner", file: "Sync/ConflictBanner.swift",
            tier: .signal, signal: .conflict, shape: .panel, expectedModifier: ".glassCard("
        ),
    ]
}
