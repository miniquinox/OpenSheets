import AppKit
import Foundation
import QuartzCore
import SheetModel

/// Which cells an agent just changed, and how strongly each is still tinted.
///
/// Pure and testable: the decay curve is arithmetic over a timestamp, so a test can drive it to
/// any point without waiting six seconds.
public struct FlashState: Sendable, Equatable {
    /// When each cell was flashed, on a monotonic clock.
    private var starts: [CellRef: Double]
    /// Seconds from full tint to nothing.
    public var duration: Double
    private var bounds: CellRange?

    public init(duration: Double = 6) {
        starts = [:]
        self.duration = max(0.001, duration)
        bounds = nil
    }

    /// Whether any cell is still tinted. When this goes false, the display link must stop.
    public var isActive: Bool { !starts.isEmpty }

    /// How many cells are still decaying.
    public var count: Int { starts.count }

    /// The rectangle covering every decaying cell, for a targeted invalidation.
    ///
    /// Redrawing the whole grid sixty times a second for one tinted cell is exactly the kind of
    /// waste that keeps the GPU awake.
    public var affectedRange: CellRange? { bounds }

    /// Starts, or restarts, the flash on these cells.
    public mutating func flash(_ refs: some Sequence<CellRef>, at now: Double) {
        for ref in refs where ref.isValid {
            starts[ref] = now
            bounds = bounds.map { $0.union(CellRange(ref)) } ?? CellRange(ref)
        }
    }

    /// Tint strength at `ref`, `0 ... 1`.
    ///
    /// Quadratic ease-out: bright immediately so the change is noticed, then fading fast enough
    /// that a screenful of changes does not stay lit for the whole six seconds.
    public func intensity(of ref: CellRef, at now: Double) -> Double {
        guard let start = starts[ref] else { return 0 }
        let elapsed = now - start
        guard elapsed >= 0 else { return 1 }
        guard elapsed < duration else { return 0 }
        let remaining = 1 - elapsed / duration
        return remaining * remaining
    }

    /// Drops cells whose flash has finished. Returns whether anything is still decaying.
    @discardableResult
    public mutating func prune(at now: Double) -> Bool {
        let before = starts.count
        starts = starts.filter { now - $0.value < duration }
        if starts.isEmpty {
            bounds = nil
        } else if starts.count != before {
            bounds = starts.keys.dropFirst().reduce(CellRange(starts.keys.first ?? .origin)) {
                $0.union(CellRange($1))
            }
        }
        return !starts.isEmpty
    }

    /// Clears every flash at once.
    public mutating func clear() {
        starts.removeAll(keepingCapacity: true)
        bounds = nil
    }
}

/// What drives the decay. Abstracted so a test can step time without a screen.
@MainActor
public protocol FlashTicker: AnyObject {
    /// Begins calling `tick` once per displayed frame. A second call while running replaces the
    /// handler rather than starting a second link.
    func start(_ tick: @escaping () -> Void)
    /// Stops calling back and releases the underlying link.
    func stop()
    /// Whether callbacks are currently scheduled.
    var isRunning: Bool { get }
}

/// A `CADisplayLink` bound to a view's screen, which **stops** when nothing is left to animate.
///
/// The stopping is the whole point. A repeating `Timer` that fires forever keeps the display
/// pipeline and the GPU awake, shows up as a wakeup every 16 ms in Activity Monitor, and costs
/// real battery for a tint that finished five minutes ago. The acceptance criterion — idle CPU
/// eight seconds after a flash — is a test for exactly that mistake.
@MainActor
public final class DisplayLinkTicker: NSObject, FlashTicker {
    private weak var view: NSView?
    private var link: CADisplayLink?
    private var handler: (() -> Void)?

    public init(view: NSView) {
        self.view = view
        super.init()
    }

    public var isRunning: Bool { link != nil }

    public func start(_ tick: @escaping () -> Void) {
        handler = tick
        guard link == nil, let view, view.window != nil else { return }
        let created = view.displayLink(target: self, selector: #selector(step))
        created.add(to: .main, forMode: .common)
        link = created
    }

    public func stop() {
        link?.invalidate()
        link = nil
        handler = nil
    }

    @objc private func step() {
        handler?()
    }
}

/// A ticker a test drives by hand.
@MainActor
public final class ManualFlashTicker: FlashTicker {
    private var handler: (() -> Void)?
    /// How many times ``start(_:)`` has been called since the last ``stop()``.
    public private(set) var startCount = 0
    /// How many times ``stop()`` has been called.
    public private(set) var stopCount = 0

    public init() {}

    public var isRunning: Bool { handler != nil }

    public func start(_ tick: @escaping () -> Void) {
        if handler == nil { startCount += 1 }
        handler = tick
    }

    public func stop() {
        if handler != nil { stopCount += 1 }
        handler = nil
    }

    /// Fires one frame.
    public func fire() { handler?() }
}

/// Owns a ``FlashState`` and the timer that decays it.
///
/// The invariant this class exists to hold: **the ticker runs if and only if something is
/// decaying.** Every path that empties the state stops the ticker in the same breath.
@MainActor
public final class FlashController {
    /// Cells and their remaining tint.
    public private(set) var state: FlashState

    /// Called on every tick with the rectangle that needs repainting, and once more with the
    /// final rectangle when the last flash expires.
    public var onInvalidate: ((CellRange?) -> Void)?

    /// Monotonic seconds. Injectable so a test can jump forward.
    public var now: @MainActor () -> Double

    private var ticker: (any FlashTicker)?

    public init(
        duration: Double = 6,
        ticker: (any FlashTicker)? = nil,
        now: @escaping @MainActor () -> Double = { CACurrentMediaTime() }
    ) {
        state = FlashState(duration: duration)
        self.ticker = ticker
        self.now = now
    }

    /// Attaches the thing that drives the decay. Replacing it stops the old one.
    public func setTicker(_ newTicker: (any FlashTicker)?) {
        if ticker !== newTicker { ticker?.stop() }
        ticker = newTicker
        if state.isActive { startTicking() }
    }

    /// Whether the display link is currently scheduled.
    public var isRunning: Bool { ticker?.isRunning ?? false }

    /// Tints these cells and starts the decay.
    ///
    /// This is the API the app shell calls when a diff is applied: `grid.flash(changedRefs)`.
    public func flash(_ refs: Set<CellRef>) {
        guard !refs.isEmpty else { return }
        state.flash(refs, at: now())
        onInvalidate?(state.affectedRange)
        startTicking()
    }

    /// Advances the decay by one frame, stopping the ticker when nothing is left.
    public func tick() {
        let stillActive = state.prune(at: now())
        onInvalidate?(state.affectedRange)
        if !stillActive {
            ticker?.stop()
            onInvalidate?(nil)
        }
    }

    /// Cancels every flash immediately and stops the ticker.
    public func cancel() {
        state.clear()
        ticker?.stop()
        onInvalidate?(nil)
    }

    /// Tint strength at a cell right now.
    public func intensity(of ref: CellRef) -> Double {
        state.intensity(of: ref, at: now())
    }

    private func startTicking() {
        ticker?.start { [weak self] in self?.tick() }
    }
}
