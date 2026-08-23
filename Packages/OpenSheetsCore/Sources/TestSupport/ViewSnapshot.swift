//
//  ViewSnapshot.swift
//  TestSupport
//
//  Deterministic SwiftUI snapshots for A5's GlassUI components.
//

import AppKit
import Foundation
import SwiftUI

/// One cell of PLAN.md §10.5's snapshot matrix: a colour scheme crossed with an accessibility
/// setting.
public struct SnapshotAppearance: Sendable, Hashable {
    /// The accessibility axis.
    ///
    /// **SwiftUI will not let a test set these.** In the macOS 26 SDK
    /// `EnvironmentValues.accessibilityReduceTransparency`, `.accessibilityReduceMotion`,
    /// `.accessibilityDifferentiateWithoutColor` and `.colorSchemeContrast` are all *get-only*
    /// key paths — `.environment(\.accessibilityReduceTransparency, true)` does not compile, and
    /// the real values come from `NSWorkspace`, which is a machine-wide setting no test should
    /// be flipping. PLAN.md §10.5 assumes otherwise.
    ///
    /// So this enum names the variant and `GlassUI` has to make it injectable: declare a
    /// `GlassUI`-owned environment key that defaults to the real system value and can be
    /// overridden, read *that* everywhere, and apply the override in the snapshot's `content`
    /// closure. See ``ViewSnapshot/image(appearance:configuration:content:)``.
    public enum Accessibility: String, Sendable, Hashable, CaseIterable {
        case normal
        case reduceTransparency
        case increaseContrast
    }

    public var colorScheme: ColorScheme
    public var accessibility: Accessibility

    public init(colorScheme: ColorScheme, accessibility: Accessibility = .normal) {
        self.colorScheme = colorScheme
        self.accessibility = accessibility
    }

    /// A stable file-name fragment: `light-normal`, `dark-increaseContrast`.
    public var name: String {
        "\(colorScheme == .dark ? "dark" : "light")-\(accessibility.rawValue)"
    }

    /// The six combinations PLAN.md §10.5 asks for, in a stable order.
    public static let matrix: [SnapshotAppearance] = [ColorScheme.light, .dark].flatMap { scheme in
        Accessibility.allCases.map { SnapshotAppearance(colorScheme: scheme, accessibility: $0) }
    }

    /// Just the two colour schemes, for a component with no accessibility behaviour.
    public static let colorSchemesOnly: [SnapshotAppearance] = [
        SnapshotAppearance(colorScheme: .light),
        SnapshotAppearance(colorScheme: .dark),
    ]
}

/// Everything about a snapshot that is not the view.
///
/// Every field exists to remove a source of nondeterminism. A snapshot that renders at the
/// machine's own locale, backing-store scale and type size produces a different image on the
/// next machine, and then somebody deletes the reference images and the suite stops being a test.
public struct SnapshotConfiguration: Sendable {
    /// The exact size to render at. `nil` lets the view size itself, which is only safe for a
    /// view with a hard intrinsic size.
    public var size: CGSize?
    /// Backing-store scale. `2` regardless of the machine's real display.
    public var scale: CGFloat
    /// Whether the rendered image has an opaque background.
    public var isOpaque: Bool
    /// Painted behind the view when ``isOpaque`` is set, so a transparent view does not snapshot
    /// as undefined pixels.
    public var backgroundColor: Color?
    public var layoutDirection: LayoutDirection
    public var dynamicTypeSize: DynamicTypeSize
    public var locale: Locale
    public var calendar: Calendar
    public var timeZone: TimeZone

    public init(
        size: CGSize? = CGSize(width: 320, height: 200),
        scale: CGFloat = 2,
        isOpaque: Bool = true,
        backgroundColor: Color? = nil,
        layoutDirection: LayoutDirection = .leftToRight,
        dynamicTypeSize: DynamicTypeSize = .large,
        locale: Locale = Locale(identifier: "en_US_POSIX"),
        calendar: Calendar = Calendar(identifier: .gregorian),
        timeZone: TimeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
    ) {
        self.size = size
        self.scale = scale
        self.isOpaque = isOpaque
        self.backgroundColor = backgroundColor
        self.layoutDirection = layoutDirection
        self.dynamicTypeSize = dynamicTypeSize
        self.locale = locale
        self.calendar = calendar
        self.timeZone = timeZone
    }

    /// The default: 320 × 200 at 2×, opaque, English, GMT.
    public static let `default` = SnapshotConfiguration()

    /// A configuration sized for one row of a grid.
    public static let cell = SnapshotConfiguration(size: CGSize(width: 160, height: 28))

    /// A copy at a different size.
    public func sized(_ width: CGFloat, _ height: CGFloat) -> SnapshotConfiguration {
        var copy = self
        copy.size = CGSize(width: width, height: height)
        return copy
    }
}

/// How a snapshot compared against its reference.
public struct SnapshotComparison: Sendable, Hashable {
    public enum Outcome: String, Sendable, Hashable {
        case matched
        case recorded
        case differs
        /// No reference image and recording is off.
        case missingReference
        /// The view could not be rendered — no window server, most likely.
        case renderFailed
    }

    public var outcome: Outcome
    public var name: String
    /// Fraction of pixels that differ by more than the per-channel tolerance.
    public var differingPixelFraction: Double
    /// The largest per-channel difference seen, `0` to `255`.
    public var maximumChannelDelta: Int
    /// Where the reference lives.
    public var referencePath: String?
    /// Where the failing render was written, so it can be looked at.
    public var failurePath: String?

    public var passed: Bool { outcome == .matched || outcome == .recorded }

    public var summary: String {
        switch outcome {
        case .matched:
            "\(name): matched"
        case .recorded:
            "\(name): reference recorded at \(referencePath ?? "?")"
        case .differs:
            String(
                format: "%@: %.3f%% of pixels differ (max channel Δ %d). Reference %@, actual %@",
                name, differingPixelFraction * 100, maximumChannelDelta,
                referencePath ?? "?", failurePath ?? "?"
            )
        case .missingReference:
            "\(name): no reference image. Re-run with OPENSHEETS_RECORD_SNAPSHOTS=1 to create it."
        case .renderFailed:
            "\(name): the view could not be rendered in this environment"
        }
    }
}

/// Renders SwiftUI views deterministically and compares them against recorded references.
///
/// ```swift
/// @MainActor @Test(arguments: SnapshotAppearance.matrix)
/// func pill(_ appearance: SnapshotAppearance) {
///     let result = ViewSnapshot.verify("sync-pill", appearance: appearance) { appearance in
///         SyncPill(state: .refreshed)
///             .environment(\.glassAccessibility, .init(appearance))   // GlassUI's own key
///     }
///     #expect(result.passed, "\(result.summary)")
/// }
/// ```
///
/// The `content` closure takes the appearance rather than the framework applying it, because
/// SwiftUI's accessibility environment values cannot be written — see
/// ``SnapshotAppearance/Accessibility``. Colour scheme, layout direction, type size, locale,
/// calendar, time zone and animation *are* applied here.
@MainActor
public enum ViewSnapshot {
    /// The environment variable that turns recording on.
    public static let recordEnvironmentKey = "OPENSHEETS_RECORD_SNAPSHOTS"

    /// Whether a missing or differing reference should be overwritten instead of failing.
    public static var isRecording: Bool {
        ProcessInfo.processInfo.environment[recordEnvironmentKey] == "1"
    }

    /// Where references live: `Fixtures/snapshots/`.
    public static var referenceDirectory: URL? {
        FixtureLibrary.root?.appendingPathComponent("snapshots", isDirectory: true)
    }

    /// Where a failing render is written, so it can be opened and looked at.
    public static var failureDirectory: URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("opensheets-snapshot-failures", isDirectory: true)
    }

    /// Whether this process can render a SwiftUI view at all.
    ///
    /// A CI runner without a window server cannot, and a suite that fails for that reason is
    /// telling you about the runner rather than about the code. Gate on this and skip loudly.
    public static var isSupported: Bool {
        image(of: Color.black.frame(width: 4, height: 4), configuration: .default.sized(4, 4)) != nil
    }

    // MARK: - Rendering

    /// Renders a view with every determinism knob applied.
    public static func image(
        of view: some View,
        appearance: SnapshotAppearance = SnapshotAppearance(colorScheme: .light),
        configuration: SnapshotConfiguration = .default
    ) -> CGImage? {
        image(appearance: appearance, configuration: configuration) { _ in view }
    }

    /// Renders a view built per-appearance, so the caller can inject its own accessibility
    /// overrides for the variant.
    public static func image(
        appearance: SnapshotAppearance = SnapshotAppearance(colorScheme: .light),
        configuration: SnapshotConfiguration = .default,
        @ViewBuilder content: (SnapshotAppearance) -> some View
    ) -> CGImage? {
        let decorated = decorate(content(appearance), appearance: appearance, configuration: configuration)
        let renderer = ImageRenderer(content: decorated)
        renderer.scale = configuration.scale
        renderer.isOpaque = configuration.isOpaque
        return renderer.cgImage
    }

    /// The same render, as PNG bytes.
    public static func pngData(
        of view: some View,
        appearance: SnapshotAppearance = SnapshotAppearance(colorScheme: .light),
        configuration: SnapshotConfiguration = .default
    ) -> Data? {
        image(of: view, appearance: appearance, configuration: configuration).flatMap(encodePNG)
    }

    private static func decorate(
        _ view: some View,
        appearance: SnapshotAppearance,
        configuration: SnapshotConfiguration
    ) -> some View {
        view
            .frame(width: configuration.size?.width, height: configuration.size?.height)
            .background(configuration.isOpaque ? (configuration.backgroundColor ?? defaultBackground(appearance)) : .clear)
            .environment(\.colorScheme, appearance.colorScheme)
            .environment(\.layoutDirection, configuration.layoutDirection)
            .environment(\.dynamicTypeSize, configuration.dynamicTypeSize)
            .environment(\.locale, configuration.locale)
            .environment(\.calendar, configuration.calendar)
            .environment(\.timeZone, configuration.timeZone)
            // Animations make a render a race against a clock. Off, always.
            .transaction { $0.disablesAnimations = true }
    }

    private static func defaultBackground(_ appearance: SnapshotAppearance) -> Color {
        appearance.colorScheme == .dark ? .black : .white
    }

    // MARK: - Verification

    /// Renders, compares against the recorded reference, and says what happened.
    ///
    /// Records the reference when `OPENSHEETS_RECORD_SNAPSHOTS=1`, or when there is no reference
    /// yet and recording is on. Never records silently in a normal run: a snapshot suite that
    /// writes its own expectations proves nothing.
    public static func verify(
        _ name: String,
        appearance: SnapshotAppearance = SnapshotAppearance(colorScheme: .light),
        configuration: SnapshotConfiguration = .default,
        pixelTolerance: Double = 0.001,
        channelTolerance: Int = 2,
        @ViewBuilder content: (SnapshotAppearance) -> some View
    ) -> SnapshotComparison {
        let fullName = "\(name).\(appearance.name)"
        guard let rendered = image(appearance: appearance, configuration: configuration, content: content),
              let renderedPNG = encodePNG(rendered)
        else {
            return SnapshotComparison(
                outcome: .renderFailed, name: fullName, differingPixelFraction: 0, maximumChannelDelta: 0
            )
        }
        guard let directory = referenceDirectory else {
            return SnapshotComparison(
                outcome: .missingReference, name: fullName, differingPixelFraction: 0, maximumChannelDelta: 0
            )
        }
        let referenceURL = directory.appendingPathComponent("\(fullName).png")

        guard let referenceData = try? Data(contentsOf: referenceURL),
              let reference = decodePNG(referenceData)
        else {
            guard isRecording else {
                return SnapshotComparison(
                    outcome: .missingReference,
                    name: fullName,
                    differingPixelFraction: 0,
                    maximumChannelDelta: 0,
                    referencePath: referenceURL.path
                )
            }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? renderedPNG.write(to: referenceURL)
            return SnapshotComparison(
                outcome: .recorded,
                name: fullName,
                differingPixelFraction: 0,
                maximumChannelDelta: 0,
                referencePath: referenceURL.path
            )
        }

        let difference = compare(reference, rendered, channelTolerance: channelTolerance)
        if difference.fraction <= pixelTolerance {
            return SnapshotComparison(
                outcome: .matched,
                name: fullName,
                differingPixelFraction: difference.fraction,
                maximumChannelDelta: difference.maximumDelta,
                referencePath: referenceURL.path
            )
        }
        if isRecording {
            try? renderedPNG.write(to: referenceURL)
            return SnapshotComparison(
                outcome: .recorded,
                name: fullName,
                differingPixelFraction: difference.fraction,
                maximumChannelDelta: difference.maximumDelta,
                referencePath: referenceURL.path
            )
        }
        try? FileManager.default.createDirectory(at: failureDirectory, withIntermediateDirectories: true)
        let failureURL = failureDirectory.appendingPathComponent("\(fullName).actual.png")
        try? renderedPNG.write(to: failureURL)
        return SnapshotComparison(
            outcome: .differs,
            name: fullName,
            differingPixelFraction: difference.fraction,
            maximumChannelDelta: difference.maximumDelta,
            referencePath: referenceURL.path,
            failurePath: failureURL.path
        )
    }

    // MARK: - Pixels

    /// Compares two images channel by channel in a fixed RGBA8 space.
    ///
    /// Redrawn into a known bitmap format first: two `CGImage`s of the same picture can differ
    /// in colour space, alpha position and row padding, and comparing their raw buffers would
    /// report a difference that is not there.
    public static func compare(
        _ lhs: CGImage,
        _ rhs: CGImage,
        channelTolerance: Int = 2
    ) -> (fraction: Double, maximumDelta: Int) {
        guard lhs.width == rhs.width, lhs.height == rhs.height else { return (1, 255) }
        guard let left = normalizedPixels(lhs), let right = normalizedPixels(rhs) else { return (1, 255) }
        var differing = 0
        var maximumDelta = 0
        let pixelCount = lhs.width * lhs.height
        for pixel in 0 ..< pixelCount {
            var worst = 0
            for channel in 0 ..< 4 {
                let index = pixel * 4 + channel
                worst = max(worst, abs(Int(left[index]) - Int(right[index])))
            }
            maximumDelta = max(maximumDelta, worst)
            if worst > channelTolerance { differing += 1 }
        }
        return (pixelCount > 0 ? Double(differing) / Double(pixelCount) : 0, maximumDelta)
    }

    private static func normalizedPixels(_ image: CGImage) -> [UInt8]? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let result: Bool = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let context = CGContext(
                      data: base,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: width * 4,
                      space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return result ? buffer : nil
    }

    private static func encodePNG(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    private static func decodePNG(_ data: Data) -> CGImage? {
        NSBitmapImageRep(data: data)?.cgImage
    }
}
