import Synchronization

/// Counters the grid keeps about its own work, so a test can assert on *work done* rather
/// than on wall-clock seconds.
///
/// Seven agents build on this machine at once (Wave 1 addendum §8), so a timing assertion
/// flakes. A lookup counter does not: "scrolling to row 1,048,576 performs the same number of
/// axis lookups as scrolling to row 3" is true on a loaded machine and on an idle one, and it
/// is the property that actually matters — it is what proves there is no linear scan.
///
/// Counting is unconditional and costs a relaxed atomic add per lookup, which is far below the
/// noise floor of the drawing it accompanies.
public enum GridInstrumentation {
    /// Every call into ``AxisMetrics/offset(ofIndex:)`` or ``AxisMetrics/index(atOffset:)``.
    ///
    /// Both are O(log bands) — the count is what tells you the *caller* is not looping.
    public static let axisLookups = Atomic<Int>(0)

    /// Cell rectangles asked for by the renderer. Proportional to what is on screen.
    public static let cellLookups = Atomic<Int>(0)

    /// `CTLine`s built. The expensive one: text shaping, not drawing, is the real cost.
    public static let textShapes = Atomic<Int>(0)

    /// `CTLine`s served from the cache instead of being shaped.
    public static let textCacheHits = Atomic<Int>(0)

    /// Frames drawn by ``GridCanvasView``.
    public static let frames = Atomic<Int>(0)

    /// A snapshot of every counter, taken one at a time — near enough for a test, and
    /// deliberately not a consistent cut across all five.
    public struct Snapshot: Sendable, Equatable {
        public var axisLookups: Int
        public var cellLookups: Int
        public var textShapes: Int
        public var textCacheHits: Int
        public var frames: Int

        /// Counter-by-counter difference, for measuring one frame or one gesture.
        public func delta(since earlier: Snapshot) -> Snapshot {
            Snapshot(
                axisLookups: axisLookups - earlier.axisLookups,
                cellLookups: cellLookups - earlier.cellLookups,
                textShapes: textShapes - earlier.textShapes,
                textCacheHits: textCacheHits - earlier.textCacheHits,
                frames: frames - earlier.frames
            )
        }
    }

    /// Reads all five counters.
    public static func snapshot() -> Snapshot {
        Snapshot(
            axisLookups: axisLookups.load(ordering: .relaxed),
            cellLookups: cellLookups.load(ordering: .relaxed),
            textShapes: textShapes.load(ordering: .relaxed),
            textCacheHits: textCacheHits.load(ordering: .relaxed),
            frames: frames.load(ordering: .relaxed)
        )
    }

    /// Zeroes every counter. Tests call this; the app never does.
    public static func reset() {
        axisLookups.store(0, ordering: .relaxed)
        cellLookups.store(0, ordering: .relaxed)
        textShapes.store(0, ordering: .relaxed)
        textCacheHits.store(0, ordering: .relaxed)
        frames.store(0, ordering: .relaxed)
    }

    @inline(__always)
    static func count(_ counter: borrowing Atomic<Int>, _ amount: Int = 1) {
        counter.wrappingAdd(amount, ordering: .relaxed)
    }
}
