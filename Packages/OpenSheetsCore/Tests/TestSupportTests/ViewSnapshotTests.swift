import Foundation
import SwiftUI
import Testing
@testable import TestSupport

@Suite("ViewSnapshot")
@MainActor
struct ViewSnapshotTests {
    private struct Swatch: View {
        var label: String
        var body: some View {
            VStack(spacing: 4) {
                Rectangle().fill(.blue).frame(width: 40, height: 12)
                Text(label)
            }
        }
    }

    @Test("the appearance matrix is the six combinations PLAN.md §10.5 asks for")
    func matrixShape() {
        #expect(SnapshotAppearance.matrix.count == 6)
        #expect(Set(SnapshotAppearance.matrix.map(\.name)).count == 6)
        #expect(SnapshotAppearance.matrix.map(\.name) == [
            "light-normal", "light-reduceTransparency", "light-increaseContrast",
            "dark-normal", "dark-reduceTransparency", "dark-increaseContrast",
        ])
        #expect(SnapshotAppearance.colorSchemesOnly.map(\.name) == ["light-normal", "dark-normal"])
    }

    @Test("a configuration can be resized without losing its other determinism knobs")
    func configurationResize() {
        let resized = SnapshotConfiguration.default.sized(64, 32)
        #expect(resized.size == CGSize(width: 64, height: 32))
        #expect(resized.scale == SnapshotConfiguration.default.scale)
        #expect(resized.locale.identifier == "en_US_POSIX")
        #expect(resized.timeZone.secondsFromGMT() == 0)
    }

    @Test("rendering produces an image at the configured size times the configured scale")
    func rendersAtTheRightSize() throws {
        try #require(ViewSnapshot.isSupported, "no window server in this environment")
        let configuration = SnapshotConfiguration.default.sized(100, 50)
        let image = try #require(ViewSnapshot.image(of: Swatch(label: "hi"), configuration: configuration))
        #expect(image.width == 200)
        #expect(image.height == 100)
    }

    @Test("two renders of the same view agree to the pixel, but not to the byte")
    func renderingIsDeterministic() throws {
        try #require(ViewSnapshot.isSupported, "no window server in this environment")
        let configuration = SnapshotConfiguration.default.sized(80, 40)
        let first = try #require(ViewSnapshot.image(of: Swatch(label: "abc"), configuration: configuration))
        let second = try #require(ViewSnapshot.image(of: Swatch(label: "abc"), configuration: configuration))

        // Measured: the *pixels* are identical — 0% differ, max channel Δ 0 — but the *PNG
        // bytes* are not. Two encodes of the same bitmap came out 1745 and 1744 bytes, because
        // the encoder is free to pick different filters. So a snapshot suite must compare
        // decoded pixels and never file bytes, which is what `verify` does.
        let difference = ViewSnapshot.compare(first, second)
        print("  [snapshot] repeat-render difference: \(difference.fraction * 100)% of pixels, "
            + "max channel Δ \(difference.maximumDelta)")
        #expect(difference.fraction < 0.01, "two renders of one view must agree to within a pixel or two")
    }

    @Test("light and dark render differently, so the colour scheme is really being applied")
    func colorSchemeIsApplied() throws {
        try #require(ViewSnapshot.isSupported, "no window server in this environment")
        let configuration = SnapshotConfiguration.default.sized(60, 30)
        let light = try #require(ViewSnapshot.image(
            of: Swatch(label: "x"),
            appearance: SnapshotAppearance(colorScheme: .light),
            configuration: configuration
        ))
        let dark = try #require(ViewSnapshot.image(
            of: Swatch(label: "x"),
            appearance: SnapshotAppearance(colorScheme: .dark),
            configuration: configuration
        ))
        let difference = ViewSnapshot.compare(light, dark)
        #expect(difference.fraction > 0.1, "a dark render that matches the light one is not applying the scheme")
    }

    @Test("comparison is exact for identical images and total for mismatched sizes")
    func comparisonBoundaries() throws {
        try #require(ViewSnapshot.isSupported, "no window server in this environment")
        let small = try #require(ViewSnapshot.image(
            of: Color.red, configuration: SnapshotConfiguration.default.sized(10, 10)
        ))
        let same = try #require(ViewSnapshot.image(
            of: Color.red, configuration: SnapshotConfiguration.default.sized(10, 10)
        ))
        let bigger = try #require(ViewSnapshot.image(
            of: Color.red, configuration: SnapshotConfiguration.default.sized(20, 20)
        ))

        #expect(ViewSnapshot.compare(small, same).fraction == 0)
        #expect(ViewSnapshot.compare(small, bigger).fraction == 1)
    }

    @Test("a missing reference says how to record it rather than failing obscurely")
    func missingReference() throws {
        try #require(ViewSnapshot.isSupported, "no window server in this environment")
        try #require(!ViewSnapshot.isRecording, "this test only means anything when recording is off")
        let result = ViewSnapshot.verify(
            "there-is-no-such-reference-\(UUID().uuidString)",
            configuration: SnapshotConfiguration.default.sized(8, 8)
        ) { _ in Color.green }

        #expect(result.outcome == .missingReference)
        #expect(!result.passed)
        #expect(result.summary.contains("OPENSHEETS_RECORD_SNAPSHOTS"))
    }

    @Test("the content closure receives the appearance, because SwiftUI will not let us set it")
    func closureReceivesAppearance() throws {
        try #require(ViewSnapshot.isSupported, "no window server in this environment")
        // The accessibility axis cannot be injected through SwiftUI's own environment values —
        // they are get-only key paths. So the caller decorates, and this proves the hook works.
        var seen: [SnapshotAppearance.Accessibility] = []
        for appearance in SnapshotAppearance.matrix {
            _ = ViewSnapshot.image(
                appearance: appearance,
                configuration: SnapshotConfiguration.default.sized(4, 4)
            ) { variant in
                seen.append(variant.accessibility)
                return Color.gray
            }
        }
        #expect(seen == SnapshotAppearance.matrix.map(\.accessibility))
    }
}
