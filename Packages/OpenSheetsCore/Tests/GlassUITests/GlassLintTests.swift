import Foundation
import Testing

@testable import GlassUI

/// The rules that make this look like glass instead of like translucent rectangles, enforced.
///
/// Every one of these is a rule a person would break by accident, at speed, while adding a
/// feature — and none of them produces a compiler error, a runtime crash, or a wrong number. They
/// produce something that looks *slightly* cheap, which is the hardest kind of regression to
/// catch in review and the exact thing this project is judged on.
///
/// See ``GlassSource`` for what the scan can and cannot see. It is a smoke alarm, not a fire
/// marshal, and it is calibrated to fire on the real failure modes rather than to be exhaustive.
@Suite("Glass discipline")
struct GlassLintTests {
    @Test("The raw SwiftUI glass API lives in exactly one file")
    func rawGlassAPIIsContained() throws {
        var violations: [String] = []
        for region in try GlassSource.regions() where region.file != GlassSource.glassSurfaceFile {
            for api in GlassSource.rawGlassAPIs where region.contains(api) {
                violations.append("\(region.location) uses \(api)")
            }
        }
        #expect(
            violations.isEmpty,
            """
            `\(GlassSource.glassSurfaceFile)` is the only file allowed to call the raw glass API. \
            Everything else goes through glassSurface/glassPill/glassCard/glassChrome so that the \
            reduce-transparency fallback cannot be forgotten in one component.
            \(violations.joined(separator: "\n"))
            """
        )
    }

    @Test("Every cluster of two or more glass elements has a container")
    func everyGlassClusterHasAContainer() throws {
        let regions = try GlassSource.regions()

        // Which component types put glass on screen, and which already wrap it.
        var appliesGlass: Set<String> = []
        var isClustered: Set<String> = []
        for region in regions {
            let direct = GlassSource.glassApplications
                .reduce(0) { $0 + region.occurrences(of: $1) }
            if direct > 0 { appliesGlass.insert(region.name) }
            if GlassSource.clusterConstructs.contains(where: region.contains) {
                isClustered.insert(region.name)
            }
        }
        let loose = appliesGlass.subtracting(isClustered)

        var violations: [String] = []
        for region in regions {
            guard !region.containsAnnotation(GlassSource.separatedMarker) else { continue }
            guard region.file != GlassSource.glassSurfaceFile else { continue }

            var count = GlassSource.glassApplications.reduce(0) { $0 + region.occurrences(of: $1) }
            for type in loose where type != region.name {
                count += region.occurrences(of: "\(type)(")
            }
            guard count >= 2 else { continue }

            // A container of its own, or a component that already brings one.
            let covered = GlassSource.clusterConstructs.contains(where: region.contains)
                || isClustered.contains(where: { region.contains("\($0)(") || region.contains("\($0) {") })
            if !covered {
                violations.append("\(region.location) has \(count) glass elements and no container")
            }
        }

        #expect(
            violations.isEmpty,
            """
            Two adjacent .glassEffect views are two independent blurs with a seam between them — \
            the single clearest tell of fake glass. Wrap them in GlassCluster, or annotate the \
            type with `\(GlassSource.separatedMarker) — <reason>` if they genuinely must not merge.
            \(violations.joined(separator: "\n"))
            """
        )
    }

    @Test("The separated-glass escape hatch has not grown")
    func separatedAnnotationsAreOnTheAllowList() throws {
        let annotated = Set(
            try GlassSource.regions()
                .filter { $0.containsAnnotation(GlassSource.separatedMarker) }
                .map(\.name)
                .filter { !$0.hasPrefix("<") }
        )
        #expect(
            annotated == GlassSource.separatedAllowList,
            """
            The set of types opting out of the cluster rule changed.
            Expected: \(GlassSource.separatedAllowList.sorted())
            Found:    \(annotated.sorted())
            Each opt-out needs a reason on the annotation and an entry in \
            GlassSource.separatedAllowList — that pairing is what stops the hatch becoming a habit.
            """
        )
    }

    @Test("Nothing layers a shadow, a border, or a material on glass")
    func nothingIsLayeredOnGlass() throws {
        var violations: [String] = []
        for region in try GlassSource.regions() {
            if region.contains(".shadow(") {
                violations.append("\(region.location) applies .shadow(")
            }
            if region.contains(".border(") {
                violations.append("\(region.location) applies .border(")
            }
            for material in GlassSource.bannedMaterials where region.contains(material) {
                violations.append("\(region.location) uses \(material)")
            }
        }
        #expect(
            violations.isEmpty,
            """
            Real Liquid Glass has its own lighting model, its own edge and its own shadow. Adding \
            to it muddies it: a stroked edge over a glass edge reads as a seam, and a second \
            shadow doubles the penumbra. The reduce-transparency fallback is a solid token plus a \
            hairline, drawn inside GlassSurface, precisely because there is no glass there to \
            interfere with.
            \(violations.joined(separator: "\n"))
            """
        )
    }

    @Test("No glass button sits on a glass surface")
    func glassIsNotNestedInGlass() throws {
        var violations: [String] = []
        for region in try GlassSource.regions() {
            let surfaces = [".glassSurface(", ".glassPill(", ".glassCard(", ".glassChrome("]
                .reduce(0) { $0 + region.occurrences(of: $1) }
            let glassButtons = [".buttonStyle(.glass)", ".buttonStyle(.glassProminent)"]
                .reduce(0) { $0 + region.occurrences(of: $1) }
            if surfaces > 0, glassButtons > 0 {
                violations.append(
                    "\(region.location) has \(surfaces) glass surfaces and \(glassButtons) glass buttons"
                )
            }
        }
        #expect(
            violations.isEmpty,
            """
            A container merges *siblings*; it does nothing for a lens stacked on a lens. Buttons \
            inside a glass panel are .bordered / .borderedProminent / .plain. .buttonStyle(.glass) \
            is for controls floating directly over the grid.
            \(violations.joined(separator: "\n"))
            """
        )
    }

    @Test("Glass button styles are conditioned on the appearance context")
    func glassButtonsHonourReduceTransparency() throws {
        // The bug this pins: `.buttonStyle(.glass)` is a *system* style. It does not consult our
        // AppearanceContext, so a toolbar built from glass buttons kept its lenses while every
        // surface around it went opaque — a half-honoured accessibility setting, which the brief
        // calls out by name. Any region that reaches for a glass button style has to ask whether
        // there should be glass at all.
        var violations: [String] = []
        for region in try GlassSource.regions() {
            let usesGlassButton = [".buttonStyle(.glass)", ".buttonStyle(.glassProminent)"]
                .contains(where: region.contains)
            guard usesGlassButton else { continue }
            if !region.contains("usesRealGlass") {
                violations.append("\(region.location) uses a glass button style unconditionally")
            }
        }
        #expect(
            violations.isEmpty,
            """
            Branch on `context.usesRealGlass` and fall back to `.bordered`. The promise is that \
            every glass surface goes opaque when the user asks for less transparency — not every \
            glass surface we happen to own the code for.
            \(violations.joined(separator: "\n"))
            """
        )
    }

    @Test("Colour literals live only in Tokens/")
    func colourLiteralsAreCentralised() throws {
        var violations: [String] = []
        for region in try GlassSource.regions()
            where !region.file.hasPrefix(GlassSource.tokensDirectory) {
            for constructor in GlassSource.colorConstructors where region.contains(constructor) {
                violations.append("\(region.location) constructs a colour with \(constructor)")
            }
            for named in GlassSource.bannedNamedColors where region.contains(named) {
                violations.append("\(region.location) uses the named colour \(named)")
            }
        }
        #expect(
            violations.isEmpty,
            """
            The fastest way to lose a palette is a Color(red:…) added inside a component "just for \
            this one badge". New colours go in Palette.swift with both schemes and a sentence \
            saying what they are for. Color.primary / .secondary / .accentColor / .clear are \
            semantic and stay legal.
            \(violations.joined(separator: "\n"))
            """
        )
    }

    @Test("The accent is never hardcoded")
    func accentIsNeverHardcoded() throws {
        var violations: [String] = []
        for region in try GlassSource.regions() {
            // #007AFF is macOS's factory accent. It is legal exactly once, as the documented
            // fallback for tests, previews and the snapshot matrix.
            if region.contains("007AFF"), region.file != "Tokens/AppearanceContext.swift" {
                violations.append("\(region.location) hardcodes #007AFF")
            }
            if region.contains("NSColor.controlAccentColor"),
               region.file != "Tokens/AccessibilityAppearance.swift" {
                violations.append("\(region.location) reads controlAccentColor directly")
            }
        }
        #expect(
            violations.isEmpty,
            """
            The accent belongs to the user. Chrome uses Color.accentColor; anything that needs a \
            concrete value takes it from AppearanceContext.accent, which AccessibilityAppearance \
            resolves and keeps up to date.
            \(violations.joined(separator: "\n"))
            """
        )
    }

    @Test("Springs only, outside the motion tokens")
    func motionIsSpringsOnly() throws {
        var violations: [String] = []
        let easings = [".easeInOut(", ".easeIn(", ".easeOut(", ".bouncy", ".smooth", ".snappy("]
        for (path, contents) in try GlassSource.files() where path != "Tokens/DS.swift" {
            for line in GlassSource.stripComments(contents.components(separatedBy: "\n")) {
                let code = line.trimmingCharacters(in: .whitespaces)
                guard !code.isEmpty else { continue }
                for easing in easings where code.contains(easing) {
                    violations.append("\(path): \(code)")
                }
                // A spring cannot loop forever; a linear ramp that does is the one exception,
                // and it is what makes the agent dot breathe.
                if code.contains(".linear("), !code.contains("repeatForever") {
                    violations.append("\(path): \(code)")
                }
            }
        }
        #expect(
            violations.isEmpty,
            """
            PLAN.md §3.3: springs only, response 0.35 / damping 0.85. Use DS.Motion. The single \
            non-spring is DS.Motion.crossFade, which replaces the morph under reduce-motion, and \
            it lives in DS.swift with its justification.
            \(violations.joined(separator: "\n"))
            """
        )
    }

    @Test("Numeric type roles go through dsNumeric")
    func numbersAreTabular() throws {
        var violations: [String] = []
        for (path, contents) in try GlassSource.files() where path != "Tokens/Typography.swift" {
            let stripped = GlassSource.stripComments(contents.components(separatedBy: "\n"))
            for (index, line) in stripped.enumerated() {
                guard line.contains("DS.Text.numeric") else { continue }
                guard !line.contains("dsNumeric(") else { continue }
                violations.append("\(path):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        #expect(
            violations.isEmpty,
            """
            PLAN.md §3.4: tabular figures, always. `.font(DS.Text.numeric)` sets the size but not \
            the figure style — use `.dsNumeric(DS.Text.numeric)`, which also adds the numeric \
            content transition so a changing value ticks rather than jumps.
            \(violations.joined(separator: "\n"))
            """
        )
    }

    @Test("No component reads global state")
    func componentsTakeValuesNotSingletons() throws {
        var violations: [String] = []
        let banned = ["@EnvironmentObject", "@StateObject", ".shared."]
        for (path, contents) in try GlassSource.files() {
            // The gallery is an app, not a component: it owns the one AccessibilityAppearance.
            let isGallery = path.hasPrefix("Gallery/")
            let isObserver = path == "Tokens/AccessibilityAppearance.swift"
            let code = GlassSource.stripComments(contents.components(separatedBy: "\n"))
                .joined(separator: "\n")
            for token in banned where code.contains(token) {
                if token == ".shared.", isObserver || isGallery { continue }
                violations.append("\(path) uses \(token)")
            }
        }
        #expect(
            violations.isEmpty,
            """
            Every component takes a plain value in and emits actions through a closure. A8 wires \
            them up; nothing here reaches for a singleton or an environment object, which is what \
            makes the gallery and the snapshot matrix possible in the first place.
            \(violations.joined(separator: "\n"))
            """
        )
    }

    @Test("The scan actually found the source")
    func scanIsNotSilentlyEmpty() throws {
        // A lint that reads zero files passes every rule. This is the guard against a green
        // suite that is checking nothing — the failure mode of every source-scanning test.
        let files = try GlassSource.files()
        #expect(files.count >= 20, "Expected the whole GlassUI target, found \(files.count) files")
        let regions = try GlassSource.regions()
        #expect(regions.count >= 60, "Expected many regions, found \(regions.count)")
        #expect(
            files.contains { $0.path == GlassSource.glassSurfaceFile },
            "GlassSurface.swift was not found — the path in GlassSource is stale"
        )
    }
}
