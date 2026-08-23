import CoreGraphics
import Darwin
import Foundation
import Synchronization
import SheetModel

/// Drives the real drawing path over a simulated fling and reports what each frame cost.
///
/// # Why this exists rather than only an Instruments trace
///
/// A trace is a picture of one run on one machine. This is a number that can be asserted in CI,
/// re-run on a laptop, and compared between two commits — and because it drives
/// ``GridRenderer/draw(_:into:viewRect:sheetOrigin:model:)`` and the header renderer, it measures
/// the same code the window does. What it deliberately leaves out is the compositor and the
/// window server, so it is a **lower bound** on frame cost, not a substitute for a trace.
///
/// # Why the trajectory matters
///
/// Scrolling slowly through row 40 is not the test. The trajectory here accelerates to a fling,
/// covers hundreds of thousands of points, and finishes at the very bottom of a 1,048,576-row
/// sheet — because the failure this component exists to avoid is one that only appears far down.
@MainActor
public enum GridBenchmark {
    /// How much of the viewport a frame repaints.
    public enum RepaintMode: String, Sendable, Codable, CaseIterable {
        /// The whole viewport, every frame. The worst case: what happens when something
        /// invalidates everything, and an upper bound on frame cost.
        case fullViewport
        /// What `NSScrollView` actually does while scrolling — copy the part that is still valid
        /// and repaint only the newly exposed band. The copy is performed for real, so this
        /// includes the cost `AppKit` would pay rather than pretending it is free.
        case exposedBand
    }

    /// What a run measured.
    public struct FrameStatistics: Sendable, Codable {
        /// Frames drawn.
        public var frames: Int
        /// Milliseconds, sorted percentiles.
        public var p50: Double
        public var p95: Double
        public var p99: Double
        public var worst: Double
        public var mean: Double
        /// Frames that exceeded ``budget``.
        public var dropped: Int
        /// The per-frame budget in milliseconds. 8.3 for 120 Hz.
        public var budget: Double
        /// Axis lookups per frame. Constant regardless of scroll position, or the grid is scanning.
        public var axisLookupsPerFrame: Double
        /// Text lines shaped per frame, after warm-up. Should be near zero on a fling.
        public var textShapesPerFrame: Double
        /// Cache hits per frame.
        public var textCacheHitsPerFrame: Double
        /// Resident memory growth over the run, in megabytes.
        ///
        /// **Signed on purpose.** RSS routinely *falls* across a run — the allocator returns pages,
        /// or the kernel reclaims them under pressure from other processes. Computing this on
        /// `UInt64` wraps to roughly 1.76e13 MB (2^44 bytes), and a `< 25` assertion then fails
        /// with a number so large it reads as noise rather than as the underflow it is. Keep the
        /// arithmetic signed.
        public var residentGrowthMB: Double
        /// The most lines any single frame had to shape.
        ///
        /// The number that explains a p99: a fling's fastest frames reveal a whole screen of new
        /// text at once, and shaping is the expensive half of drawing it.
        public var worstFrameShapes: Int
        /// Every frame's time in milliseconds, in order.
        ///
        /// Kept so a report can show a histogram and name *which* frames were slow — a p99 on its
        /// own tells you there is a spike but not where it is, and "where" is the whole
        /// investigation.
        public var frameTimes: [Double]

        /// Whether every frame fitted the budget.
        public var meetsBudget: Bool { p99 < budget && dropped == 0 }

        /// A one-line summary for a log or a report.
        public var summary: String {
            String(
                format: "%d frames · p50 %.2f ms · p95 %.2f ms · p99 %.2f ms · max %.2f ms · %d over budget",
                frames, p50, p95, p99, worst, dropped
            )
        }
    }

    /// Runs a fling and reports the frame times.
    ///
    /// - Parameters:
    ///   - workbook: what to draw. ``GridDemoWorkbook/millionCells(frozen:merges:)`` is the one
    ///     the acceptance criteria name.
    ///   - viewport: the visible size in points. A 14-inch MacBook Pro's grid area is about
    ///     1400 × 800.
    ///   - frames: how many frames the fling lasts. 600 is five seconds at 120 Hz.
    ///   - warmUpFrames: frames run before measurement starts, so the first-paint cost of filling
    ///     the text cache does not land in the percentiles. A real fling is preceded by the sheet
    ///     already being on screen.
    public static func fling(
        workbook: Workbook,
        sheetID: SheetID? = nil,
        viewport: CGSize = CGSize(width: 1400, height: 800),
        scale: Double = 2,
        frames: Int = 600,
        warmUpFrames: Int = 30,
        theme: GridTheme = .light,
        zoom: Double = 1,
        options: GridOptions = .default,
        budget: Double = 8.3,
        // The default is deliberately the pessimistic one: `NSScrollView` repaints only the newly
        // exposed band while scrolling, so a benchmark that repaints everything every frame is
        // measuring something strictly harder than the app does.
        mode: RepaintMode = .fullViewport
    ) -> FrameStatistics {
        let sheet = sheetID.flatMap { workbook[$0] } ?? workbook.sheets[0]
        let geometry = GridGeometry(sheet: sheet, zoom: zoom)
        let model = GridRenderModel(
            sheet: sheet,
            styles: workbook.styles,
            dateSystem: workbook.meta.dateSystem,
            theme: theme,
            options: options,
            geometry: geometry,
            merges: MergeIndex(sheet.merges),
            selection: GridSelection(active: CellRef(row: 12, column: 3))
        )

        let renderer = GridRenderer(theme: theme)
        renderer.backingScale = scale
        let headers = GridHeaderRenderer(theme: theme)
        headers.backingScale = scale

        let pixelWidth = Int(viewport.width * scale)
        let pixelHeight = Int(viewport.height * scale)
        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: pixelWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return FrameStatistics(
                frames: 0, p50: 0, p95: 0, p99: 0, worst: 0, mean: 0, dropped: 0, budget: budget,
                axisLookupsPerFrame: 0, textShapesPerFrame: 0, textCacheHitsPerFrame: 0,
                residentGrowthMB: 0, worstFrameShapes: 0, frameTimes: []
            )
        }
        context.translateBy(x: 0, y: CGFloat(pixelHeight))
        context.scaleBy(x: scale, y: -scale)

        let headerRect = CGRect(x: 0, y: 0, width: viewport.width, height: theme.headerHeight)
        let rowHeaderRect = CGRect(x: 0, y: 0, width: theme.headerWidth, height: viewport.height)
        let bodyRect = CGRect(origin: .zero, size: viewport)

        var previousOrigin: CGPoint?

        func drawBody(_ origin: CGPoint, _ rect: CGRect) {
            renderer.draw(
                .body,
                into: context,
                viewRect: rect,
                sheetOrigin: geometry.sheetPoint(
                    fromDocument: CGPoint(x: origin.x + rect.minX, y: origin.y + rect.minY)
                ),
                model: model
            )
        }

        func drawFrame(at origin: CGPoint) {
            switch mode {
            case .fullViewport:
                drawBody(origin, bodyRect)
            case .exposedBand:
                let previous = previousOrigin
                previousOrigin = origin
                guard let previous else {
                    drawBody(origin, bodyRect)
                    break
                }
                let delta = CGPoint(x: origin.x - previous.x, y: origin.y - previous.y)
                if abs(delta.x) >= viewport.width || abs(delta.y) >= viewport.height {
                    drawBody(origin, bodyRect)
                    break
                }
                copyScrolledPixels(context: context, scale: scale, delta: delta)
                for rect in exposedRects(delta: delta, viewport: viewport) {
                    drawBody(origin, rect)
                }
            }
            headers.drawColumnHeader(into: context, viewRect: headerRect, scrollOrigin: origin, model: model)
            headers.drawRowHeader(into: context, viewRect: rowHeaderRect, scrollOrigin: origin, model: model)
        }

        for index in 0 ..< warmUpFrames {
            drawFrame(at: trajectory(frame: index, of: frames, geometry: geometry, viewport: viewport))
        }

        GridInstrumentation.reset()
        let residentBefore = residentBytes()
        var samples: [Double] = []
        samples.reserveCapacity(frames)
        var worstShapes = 0
        var previousShapes = 0

        for index in 0 ..< frames {
            let origin = trajectory(frame: index, of: frames, geometry: geometry, viewport: viewport)
            let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            drawFrame(at: origin)
            let end = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            samples.append(Double(end - start) / 1_000_000)
            let shapes = GridInstrumentation.textShapes.load(ordering: .relaxed)
            worstShapes = max(worstShapes, shapes - previousShapes)
            previousShapes = shapes
        }

        let residentAfter = residentBytes()
        let counters = GridInstrumentation.snapshot()
        let sorted = samples.sorted()
        let divisor = Double(max(1, frames))

        return FrameStatistics(
            frames: frames,
            p50: percentile(sorted, 0.50),
            p95: percentile(sorted, 0.95),
            p99: percentile(sorted, 0.99),
            worst: sorted.last ?? 0,
            mean: samples.reduce(0, +) / divisor,
            dropped: samples.count { $0 > budget },
            budget: budget,
            axisLookupsPerFrame: Double(counters.axisLookups) / divisor,
            textShapesPerFrame: Double(counters.textShapes) / divisor,
            textCacheHitsPerFrame: Double(counters.textCacheHits) / divisor,
            residentGrowthMB: Double(Int64(bitPattern: residentAfter) - Int64(bitPattern: residentBefore))
                / (1024 * 1024),
            worstFrameShapes: worstShapes,
            frameTimes: samples
        )
    }

    /// The scroll position at a given frame of the fling.
    ///
    /// # Why the trajectory is written around the data, not around the sheet
    ///
    /// A sheet is 1,048,576 rows tall and its data is not. A trajectory defined as a fraction of
    /// the *scroll range* spends ninety-eight per cent of its frames painting empty rows, which
    /// measures the cheapest thing the renderer does and reports it as the median. The first
    /// version of this benchmark did exactly that, and its p50 of 1.3 ms was the cost of drawing
    /// nothing.
    ///
    /// So: four phases, three of them inside the data. A hard flick down through the populated
    /// rows, a horizontal sweep, a flick back up, and finally a jump to row 1,048,575 and back —
    /// which is the case the acceptance criteria name and the one a linear scan would fail.
    public static func trajectory(
        frame: Int,
        of total: Int,
        geometry: GridGeometry,
        viewport: CGSize,
        dataRows: Int = 20_000
    ) -> CGPoint {
        let scrollable = geometry.scrollableSize
        let maximumY = max(0, scrollable.height - viewport.height)
        let maximumX = max(0, scrollable.width - viewport.width)
        let dataBottom = min(maximumY, max(0, geometry.rows.offset(ofIndex: dataRows) - viewport.height))
        let progress = Double(frame) / Double(max(1, total - 1))

        switch progress {
        case ..<0.40:
            // The flick: cubic ease-out from the top to the bottom of the data.
            let local = progress / 0.40
            return CGPoint(x: 0, y: (1 - pow(1 - local, 3)) * dataBottom)
        case ..<0.60:
            // Sideways across the columns, still inside the data.
            let local = (progress - 0.40) / 0.20
            return CGPoint(x: local * maximumX, y: dataBottom * 0.6)
        case ..<0.85:
            // Back up, decelerating into the header row.
            let local = (progress - 0.60) / 0.25
            return CGPoint(x: maximumX * (1 - local), y: dataBottom * pow(1 - local, 2))
        default:
            // And out to the very bottom of the sheet and back. Empty rows, a million down.
            let local = (progress - 0.85) / 0.15
            let sweep = local < 0.5 ? local * 2 : (1 - local) * 2
            return CGPoint(x: 0, y: dataBottom + sweep * (maximumY - dataBottom))
        }
    }

    /// The rectangles a scroll of `delta` newly exposes: a horizontal band, a vertical band, or
    /// both when the scroll was diagonal.
    static func exposedRects(delta: CGPoint, viewport: CGSize) -> [CGRect] {
        var rects: [CGRect] = []
        if delta.y > 0 {
            rects.append(CGRect(x: 0, y: viewport.height - delta.y, width: viewport.width, height: delta.y))
        } else if delta.y < 0 {
            rects.append(CGRect(x: 0, y: 0, width: viewport.width, height: -delta.y))
        }
        if delta.x > 0 {
            rects.append(CGRect(x: viewport.width - delta.x, y: 0, width: delta.x, height: viewport.height))
        } else if delta.x < 0 {
            rects.append(CGRect(x: 0, y: 0, width: -delta.x, height: viewport.height))
        }
        return rects
    }

    /// Moves the still-valid pixels, the way `NSScrollView`'s copy-on-scroll does.
    ///
    /// Performed for real rather than assumed free: a copy of a 2,800 × 1,600 backing store is
    /// not nothing, and a benchmark that skipped it would be flattering itself.
    private static func copyScrolledPixels(context: CGContext, scale: Double, delta: CGPoint) {
        guard let data = context.data, delta != .zero else { return }
        let bytesPerRow = context.bytesPerRow
        let height = context.height
        let width = context.width
        let shiftY = Int(delta.y * scale)
        let shiftX = Int(delta.x * scale)
        guard abs(shiftY) < height, abs(shiftX) < width else { return }

        let bytes = data.assumingMemoryBound(to: UInt8.self)
        let rowBytes = (width - abs(shiftX)) * 4
        guard rowBytes > 0 else { return }
        let sourceColumn = max(0, shiftX) * 4
        let targetColumn = max(0, -shiftX) * 4

        // The bitmap is flipped, so scrolling down moves pixels toward lower row indices.
        if shiftY >= 0 {
            for row in shiftY ..< height {
                memmove(
                    bytes + (row - shiftY) * bytesPerRow + targetColumn,
                    bytes + row * bytesPerRow + sourceColumn,
                    rowBytes
                )
            }
        } else {
            for row in stride(from: height - 1 + shiftY, through: 0, by: -1) {
                memmove(
                    bytes + (row - shiftY) * bytesPerRow + targetColumn,
                    bytes + row * bytesPerRow + sourceColumn,
                    rowBytes
                )
            }
        }
    }

    private static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let position = fraction * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = min(sorted.count - 1, lower + 1)
        let weight = position - Double(lower)
        return sorted[lower] * (1 - weight) + sorted[upper] * weight
    }

    /// Resident memory, for the "memory stays flat while scrolling" criterion.
    public static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }
}
